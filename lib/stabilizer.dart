import 'dart:math' as math;

/// 四元数(姿态积分用)
class Quat {
  final double w, x, y, z;
  const Quat(this.w, this.x, this.y, this.z);
  static const identity = Quat(1, 0, 0, 0);

  Quat operator *(Quat o) => Quat(
    w * o.w - x * o.x - y * o.y - z * o.z,
    w * o.x + x * o.w + y * o.z - z * o.y,
    w * o.y - x * o.z + y * o.w + z * o.x,
    w * o.z + x * o.y - y * o.x + z * o.w,
  );

  Quat get normalized {
    final n = math.sqrt(w * w + x * x + y * y + z * z);
    return n == 0 ? identity : Quat(w / n, x / n, y / n, z / n);
  }

  /// 由旋转向量(弧度)构造
  static Quat fromRotVec(double rx, double ry, double rz) {
    final angle = math.sqrt(rx * rx + ry * ry + rz * rz);
    if (angle < 1e-9) return Quat(1, rx / 2, ry / 2, rz / 2).normalized;
    final s = math.sin(angle / 2) / angle;
    return Quat(math.cos(angle / 2), rx * s, ry * s, rz * s);
  }

  /// 转回旋转向量(弧度)
  List<double> toRotVec() {
    final q = normalized;
    final s = math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z);
    if (s < 1e-9) return <double>[0, 0, 0];
    final angle = 2 * math.atan2(s, q.w.clamp(-1.0, 1.0));
    return <double>[q.x / s * angle, q.y / s * angle, q.z / s * angle];
  }
}

/// 离线稳定方案(录像结束后分析整段陀螺仪数据得到)
class StabPlan {
  /// 横向补偿曲线 [t秒, 原图像素]
  final List<List<double>> dx;

  /// 纵向补偿曲线 [t秒, 原图像素]
  final List<List<double>> dy;

  /// 固定裁切放大倍率(由余量决定,与抖动幅度无关)
  final double zoom;

  /// 实际用到的最大位移(像素,诊断用)
  final double maxShiftX;
  final double maxShiftY;

  /// 使用的裁切余量(比例)
  final double margin;

  const StabPlan({
    required this.dx,
    required this.dy,
    required this.zoom,
    required this.maxShiftX,
    required this.maxShiftY,
    required this.margin,
  });

  bool get usable => dx.length >= 2 && dy.length >= 2;

  static const empty = StabPlan(
    dx: [],
    dy: [],
    zoom: 1,
    maxShiftX: 0,
    maxShiftY: 0,
    margin: 0,
  );
}

/// 陀螺仪稳定核心。
/// 算法思路参考 Gyroflow(四元数姿态积分 → 平滑虚拟相机路径 → 裁切取景框),
/// 但为手机端实时/导出场景用 Dart 重新实现,并省略镜头畸变与卷帘快门校正。
///
/// 与第一版的区别(修 "大幅晃动后卡在 3x / 渲染没效果"):
///   * 裁切余量是**固定常量**,只由"稳定强度"决定;
///   * 补偿位移被**硬限制**在余量以内,抖得再大也不会把画面越放越大;
///   * 平滑窗更长(默认 1.2s),让持续晃动也进入补偿范围,补偿更"激烈"。
class GyroStabilizer {
  /// 由视场角估算焦距(像素)。
  /// 关键:竖屏成片的宽高是**转置**过的,而焦距(像素)是转置不变量。
  /// 视场角 fovDeg 描述的是原始横向捕获的长边,所以必须用长边反推,
  /// 两个轴才能得到同一个正确的 f(否则补偿量会小 1.7 倍以上)。
  static double focalPx(double frameW, double frameH, double fovDeg) =>
      (math.max(frameW, frameH) / 2) /
      math.tan(fovDeg * math.pi / 180 / 2);

  /// 稳定强度 → 裁切余量(画面每边可移动的比例)
  /// 柔和 0.6→4.2% / 标准 1.0→7% / 强 1.6→11.2%
  static double marginFor(double strength) => (0.07 * strength).clamp(0.04, 0.12);

  /// 余量 → 固定裁切放大倍率。余量恒定 ⇒ 画面永远不会越挪越放大。
  static double zoomForMargin(double margin) =>
      (1 / (1 - 2 * margin)).clamp(1.0, 1.4);

  /// 离线分析:用整段陀螺仪数据算出"平滑虚拟相机路径"的补偿曲线
  static StabPlan analyze({
    required List<List<double>> samples, // [t(epoch秒), gx, gy, gz]
    required double startEpoch,
    required double endEpoch,
    required double frameW,
    required double frameH,
    double fovDeg = 66,
    double smoothSec = 1.2,
    double strength = 1.0,
    double curveStep = 0.2,
    double? margin,
  }) {
    final m = (margin ?? marginFor(strength)).clamp(0.02, 0.16);
    final zoom = zoomForMargin(m);
    final maxShiftXPx = m * frameW;
    final maxShiftYPx = m * frameH;

    // 1) 积分姿态(取旋转向量的 x=pitch、y=yaw 作为相机指向)
    final ts = <double>[];
    final rawX = <double>[];
    final rawY = <double>[];
    var q = Quat.identity;
    double? prev;
    for (final s in samples) {
      final t = s[0];
      if (t < startEpoch || t > endEpoch) continue;
      final dt = prev == null ? 0.0 : (t - prev);
      prev = t;
      if (dt > 0 && dt < 0.2) {
        q = (q * Quat.fromRotVec(s[1] * dt, s[2] * dt, s[3] * dt)).normalized;
      }
      final rv = q.toRotVec();
      ts.add(t - startEpoch);
      rawX.add(rv[0]);
      rawY.add(rv[1]);
    }
    if (ts.length < 4) return StabPlan.empty;

    // 2) 对称移动平均平滑(离线用对称窗,不会引入滞后)
    final smX = List<double>.filled(ts.length, 0);
    final smY = List<double>.filled(ts.length, 0);
    var lo = 0, hi = 0;
    var sumX = 0.0, sumY = 0.0;
    for (var i = 0; i < ts.length; i++) {
      final tLo = ts[i] - smoothSec / 2;
      final tHi = ts[i] + smoothSec / 2;
      while (hi < ts.length && ts[hi] <= tHi) {
        sumX += rawX[hi];
        sumY += rawY[hi];
        hi++;
      }
      while (lo < hi && ts[lo] < tLo) {
        sumX -= rawX[lo];
        sumY -= rawY[lo];
        lo++;
      }
      final n = hi - lo;
      smX[i] = n > 0 ? sumX / n : rawX[i];
      smY[i] = n > 0 ? sumY / n : rawY[i];
    }

    // 3) 修正角 → 像素位移,并硬限制在裁切余量内
    final f = focalPx(frameW, frameH, fovDeg);
    final dxs = List<double>.filled(ts.length, 0);
    final dys = List<double>.filled(ts.length, 0);
    var maxX = 0.0, maxY = 0.0;
    for (var i = 0; i < ts.length; i++) {
      final cx = ((rawX[i] - smX[i]) * strength).clamp(-1.0, 1.0);
      final cy = ((rawY[i] - smY[i]) * strength).clamp(-1.0, 1.0);
      // X 增大 → 画面下移(纵向);横向取反以匹配镜面关系
      final dyPx = (f * math.tan(cx)).clamp(-maxShiftYPx, maxShiftYPx);
      final dxPx = (-f * math.tan(cy)).clamp(-maxShiftXPx, maxShiftXPx);
      dys[i] = dyPx;
      dxs[i] = dxPx;
      maxX = math.max(maxX, dxPx.abs());
      maxY = math.max(maxY, dyPx.abs());
    }

    // 4) 按固定间隔采样成曲线(供 FFmpeg 表达式使用)
    final dxCurve = <List<double>>[];
    final dyCurve = <List<double>>[];
    var nextT = 0.0;
    for (var i = 0; i < ts.length; i++) {
      if (ts[i] >= nextT) {
        dxCurve.add(<double>[ts[i], dxs[i]]);
        dyCurve.add(<double>[ts[i], dys[i]]);
        nextT = ts[i] + curveStep;
      }
    }
    // 保证覆盖到结尾
    if (dxCurve.isNotEmpty && ts.isNotEmpty) {
      dxCurve.add(<double>[ts.last, dxs.last]);
      dyCurve.add(<double>[ts.last, dys.last]);
    }

    return StabPlan(
      dx: dxCurve,
      dy: dyCurve,
      zoom: zoom,
      maxShiftX: maxX,
      maxShiftY: maxY,
      margin: m,
    );
  }

  /// 把曲线转成 FFmpeg crop 的位移表达式(节点数受限,避免表达式过深)
  static String? toCropExpr(List<List<double>> curve, {int maxKnots = 60}) {
    if (curve.length < 2) return null;
    final step = (curve.length / maxKnots).ceil();
    final knots = <List<double>>[];
    for (var i = 0; i < curve.length; i += step) {
      knots.add(curve[i]);
    }
    if (knots.last[0] != curve.last[0]) knots.add(curve.last);
    if (knots.length < 2) return null;

    final ts = knots.map((k) => k[0]).toList();
    final vs = knots.map((k) => k[1]).toList();
    var expr = vs.last.toStringAsFixed(2);
    for (var i = ts.length - 2; i >= 0; i--) {
      final t0 = ts[i], t1 = ts[i + 1], v0 = vs[i], v1 = vs[i + 1];
      final slope = (v1 - v0) / (t1 - t0);
      expr =
          'if(lt(t,${t1.toStringAsFixed(2)}),'
          '${v0.toStringAsFixed(2)}+${slope.toStringAsFixed(3)}'
          '*(t-${t0.toStringAsFixed(2)}),$expr)';
    }
    return expr;
  }
}

/// 在线稳定器(预览用):实时积分为姿态,EMA 平滑出低频路径,得到角修正
class OnlineStabilizer {
  Quat _q = Quat.identity;
  double _sx = 0, _sy = 0;
  double corrX = 0; // pitch 修正(弧度)
  double corrY = 0; // yaw 修正(弧度)

  void reset() {
    _q = Quat.identity;
    _sx = 0;
    _sy = 0;
    corrX = 0;
    corrY = 0;
  }

  /// [dt] 秒;[gx]/[gy]/[gz] 为 rad/s;[tau] 为平滑时间常数(越大越稳、跟随越慢)
  void update(double dt, double gx, double gy, double gz, {double tau = 0.9}) {
    if (dt <= 0 || dt > 0.2) return;
    _q = (_q * Quat.fromRotVec(gx * dt, gy * dt, gz * dt)).normalized;
    final rv = _q.toRotVec();
    final a = 1 - math.exp(-dt / tau);
    _sx += (rv[0] - _sx) * a;
    _sy += (rv[1] - _sy) * a;
    corrX = rv[0] - _sx;
    corrY = rv[1] - _sy;
  }

  /// 角修正 → 像素位移,并按裁切余量硬限制(抖得再大也不会越界)
  List<double> shifts(
    double frameW,
    double frameH,
    double fovDeg,
    double strength,
    double margin,
  ) {
    final f = GyroStabilizer.focalPx(frameW, frameH, fovDeg);
    final limX = margin * frameW;
    final limY = margin * frameH;
    final dyPx = (f * math.tan((corrX * strength).clamp(-1.0, 1.0))).clamp(
      -limY,
      limY,
    );
    final dxPx = (-f * math.tan((corrY * strength).clamp(-1.0, 1.0))).clamp(
      -limX,
      limX,
    );
    return <double>[dxPx, dyPx];
  }
}
