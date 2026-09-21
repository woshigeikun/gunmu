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

  /// 自适应缩放(保证裁切框不出画面)
  final double zoom;

  final double maxShiftX;
  final double maxShiftY;

  const StabPlan({
    required this.dx,
    required this.dy,
    required this.zoom,
    required this.maxShiftX,
    required this.maxShiftY,
  });

  bool get usable => dx.length >= 2 && dy.length >= 2;

  static const empty = StabPlan(
    dx: [],
    dy: [],
    zoom: 1,
    maxShiftX: 0,
    maxShiftY: 0,
  );
}

/// 陀螺仪稳定核心。
/// 算法思路参考 Gyroflow(四元数姿态积分 → 平滑虚拟相机路径 → 自适应缩放),
/// 但为手机端实时/导出场景用 Dart 重新实现,并省略镜头畸变与卷帘快门校正。
class GyroStabilizer {
  /// 由视场角估算焦距(像素)
  static double focalPx(double frameW, double fovDeg) =>
      (frameW / 2) / math.tan(fovDeg * math.pi / 180 / 2);

  /// 离线分析:用整段陀螺仪数据算出"平滑虚拟相机路径"的补偿曲线
  static StabPlan analyze({
    required List<List<double>> samples, // [t(epoch秒), gx, gy, gz]
    required double startEpoch,
    required double endEpoch,
    required double frameW,
    required double frameH,
    double fovDeg = 66,
    double smoothSec = 0.6,
    double strength = 1.0,
    double safety = 0.06,
    double curveStep = 0.2,
  }) {
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

    // 3) 修正角 → 像素位移
    final f = focalPx(frameW, fovDeg);
    final dxs = List<double>.filled(ts.length, 0);
    final dys = List<double>.filled(ts.length, 0);
    var maxX = 0.0, maxY = 0.0;
    for (var i = 0; i < ts.length; i++) {
      final cx = ((rawX[i] - smX[i]) * strength).clamp(-0.6, 0.6);
      final cy = ((rawY[i] - smY[i]) * strength).clamp(-0.6, 0.6);
      // X 增大 → 画面下移(纵向);横向取反以匹配镜面关系
      final dyPx = f * math.tan(cx);
      final dxPx = -f * math.tan(cy);
      dys[i] = dyPx;
      dxs[i] = dxPx;
      maxX = math.max(maxX, dxPx.abs());
      maxY = math.max(maxY, dyPx.abs());
    }

    // 4) 自适应缩放:裁切窗口始终留在画面内
    final need = math.max(2 * maxX / frameW, 2 * maxY / frameH);
    var zoom = need >= 0.98 ? 3.0 : 1 / (1 - need);
    zoom = (zoom * (1 + safety)).clamp(1.0, 3.0);

    // 5) 按固定间隔采样成曲线(供 FFmpeg 表达式使用)
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
    );
  }

  /// 把曲线转成 FFmpeg crop 的位移表达式(节点数受限,避免表达式过深)
  static String? toCropExpr(List<List<double>> curve, {int maxKnots = 34}) {
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
  double _maxX = 0, _maxY = 0;
  double corrX = 0; // pitch 修正(弧度)
  double corrY = 0; // yaw 修正(弧度)

  void reset() {
    _q = Quat.identity;
    _sx = 0;
    _sy = 0;
    _maxX = 0;
    _maxY = 0;
    corrX = 0;
    corrY = 0;
  }

  /// [dt] 秒;[gx]/[gy]/[gz] 为 rad/s;[tau] 为平滑时间常数(越大越稳、跟随越慢)
  void update(double dt, double gx, double gy, double gz, {double tau = 0.6}) {
    if (dt <= 0 || dt > 0.2) return;
    _q = (_q * Quat.fromRotVec(gx * dt, gy * dt, gz * dt)).normalized;
    final rv = _q.toRotVec();
    final a = 1 - math.exp(-dt / tau);
    _sx += (rv[0] - _sx) * a;
    _sy += (rv[1] - _sy) * a;
    corrX = rv[0] - _sx;
    corrY = rv[1] - _sy;
    _maxX = math.max(_maxX * 0.9995, corrX.abs());
    _maxY = math.max(_maxY * 0.9995, corrY.abs());
  }

  /// 当前需要的自适应缩放(按已出现过的最大修正量估算)
  double adaptiveZoom(
    double frameW,
    double frameH,
    double fovDeg,
    double strength, {
    double safety = 0.06,
  }) {
    final f = GyroStabilizer.focalPx(frameW, fovDeg);
    final needX =
        2 *
        f *
        math.tan((_maxX * strength).clamp(-0.6, 0.6)) /
        math.max(1.0, frameW);
    final needY =
        2 *
        f *
        math.tan((_maxY * strength).clamp(-0.6, 0.6)) /
        math.max(1.0, frameH);
    final need = math.max(needX, needY);
    if (need >= 0.98) return 3.0;
    return ((1 / (1 - need)) * (1 + safety)).clamp(1.0, 3.0);
  }

  /// 角修正 → 像素位移(与原图像素同尺度)
  List<double> shifts(double frameW, double fovDeg, double strength) {
    final f = GyroStabilizer.focalPx(frameW, fovDeg);
    final dxPx = -f * math.tan((corrY * strength).clamp(-0.6, 0.6));
    final dyPx = f * math.tan((corrX * strength).clamp(-0.6, 0.6));
    return <double>[dxPx, dyPx];
  }
}
