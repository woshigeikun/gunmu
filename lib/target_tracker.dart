import 'dart:math' as math;
import 'dart:typed_data';

/// 一帧的目标跟踪结果
class TrackPoint {
  /// 时间(秒,相对成片起点)
  final double t;

  /// 目标中心(跟踪帧像素坐标)
  final double cx;
  final double cy;

  /// 匹配残差(平均绝对差,0~255 尺度,越小越可信)
  final double mad;

  /// 是否可信
  final bool ok;

  const TrackPoint(this.t, this.cx, this.cy, this.mad, this.ok);

  @override
  String toString() =>
      't=${t.toStringAsFixed(2)} c=(${cx.toStringAsFixed(1)},'
      '${cy.toStringAsFixed(1)}) mad=${mad.toStringAsFixed(1)} ok=$ok';
}

/// 目标跟踪:纯 Dart 的 SAD 块匹配 + 抛物线亚像素细化。
///
/// 为什么不用光流/特征点:手机端要在可接受时间内处理上千帧低分辨率灰度图,
/// 块匹配是最稳、最省事的一种 —— 对"用户画框圈住的某个物体"这种场景足够,
/// 而且不会像特征点法那样在纹理少的区域直接失效。
class TargetTracker {
  /// 距离惩罚系数:匹配残差(MAD,0~255 尺度)每偏离预测位置 1 像素加多少分。
  /// 调大 = 更保守(更相信运动连续性),调小 = 更相信灰度相似度。
  /// 取 4.0 是偏保守的一侧:遇到重复纹理(条纹、格子、文字行)时,
  /// 宁可少跟一点,也不要跳到隔壁那一片一模一样的纹理上。
  static const double _distPenalty = 4.0;

  /// 在灰度帧序列里跟踪第一帧给定的目标框。
  ///
  /// [gray] 连续 [frames] 帧灰度数据(每帧 w*h 字节,行优先);
  /// [boxX]/[boxY]/[boxW]/[boxH] 第一帧里的初始目标框(像素);
  /// [search] 每帧在上一帧位置附近搜索的半径(像素);
  /// [anchors] 中途重新捕获的锚点,每个元素是
  /// [帧序号, 框x, 框y, 框w, 框h](跟踪帧像素)。
  /// 长视频里跟踪器难免会慢慢飘走,锚点允许在每 10 秒的检查点上
  /// 用"重新识别出来的同一目标"把跟踪器重新初始化一次。
  static List<TrackPoint> track({
    required Uint8List gray,
    required int w,
    required int h,
    required int frames,
    required int boxX,
    required int boxY,
    required int boxW,
    required int boxH,
    double fps = 10,
    int search = 14,
    List<double>? priorDx,
    List<double>? priorDy,
    List<List<double>>? anchors,
  }) {
    var out = <TrackPoint>[];
    // 累计重捕获次数(诊断:反映锚点有没有起作用)
    var reacquired = 0;
    if (w <= 0 || h <= 0 || frames <= 0) return out;
    final frameBytes = w * h;
    if (gray.length < frameBytes) return out;
    if (boxW < 4 || boxH < 4) return out;

    // 锚点表:帧序号 → 框
    final anchorMap = <int, List<double>>{};
    if (anchors != null) {
      for (final a in anchors) {
        if (a.length >= 5) anchorMap[a[0].round()] = a;
      }
    }

    var bw = boxW, bh = boxH;
    var bx = boxX.clamp(0, w - bw < 0 ? 0 : w - bw);
    var by = boxY.clamp(0, h - bh < 0 ? 0 : h - bh);

    var rel = <int>[];
    var tpl = <int>[];
    var n = 0;

    /// 用当前帧的某个框重建模板(锚点重捕获时调用)
    void seed(int f, int sx, int sy, int sw, int sh) {
      bw = sw;
      bh = sh;
      bx = sx.clamp(0, w - bw < 0 ? 0 : w - bw);
      by = sy.clamp(0, h - bh < 0 ? 0 : h - bh);
      final step = math.max(1, ((bw * bh) / 700).ceil());
      rel = <int>[];
      tpl = <int>[];
      final base = f * frameBytes;
      for (var y = 0; y < bh; y += step) {
        for (var x = 0; x < bw; x += step) {
          rel.add(y * w + x);
          tpl.add(gray[base + (by + y) * w + bx + x]);
        }
      }
      n = rel.length;
    }

    seed(0, bx, by, bw, bh);
    if (n < 9) return out;

    int sadAt(int base, int tx, int ty) {
      final p = base + ty * w + tx;
      var s = 0;
      for (var i = 0; i < n; i++) {
        s += (tpl[i] - gray[p + rel[i]]).abs();
      }
      return s;
    }

    // 初始位置 = 用户框的位置
    var cx = bx + bw / 2.0;
    var cy = by + bh / 2.0;
    var boxCx0 = cx, boxCy0 = cy;
    var lastX = cx, lastY = cy;
    var velX = 0.0, velY = 0.0;
    // 视觉测得的偏差累积量(见下面的"绝对预测 + 累积修正")
    var accX = 0.0, accY = 0.0;

    for (var f = 0; f < frames; f++) {
      final base = f * frameBytes;
      if (base + frameBytes > gray.length) break;

      // ── 锚点重捕获 ──
      // 到了检查点且这一帧重新识别出了同一目标:用它把跟踪器重新初始化。
      // 关键是同时把"绝对预测"的基准也跟着平移,否则陀螺仪先验会把
      // 重新捕获到的新位置又拉回旧位置上去。
      final anc = anchorMap[f];
      if (anc != null && f > 0) {
        final aw = anc[3].round().clamp(6, w - 2);
        final ah = anc[4].round().clamp(6, h - 2);
        seed(f, anc[1].round(), anc[2].round(), aw, ah);
        if (n >= 9) {
          cx = bx + bw / 2.0;
          cy = by + bh / 2.0;
          lastX = cx;
          lastY = cy;
          velX = 0;
          velY = 0;
          accX = 0;
          accY = 0;
          final px = (priorDx != null && f < priorDx.length) ? priorDx[f] : 0.0;
          final py = (priorDy != null && f < priorDy.length) ? priorDy[f] : 0.0;
          boxCx0 = cx - px;
          boxCy0 = cy - py;
          reacquired++;
        }
      }

      // 运动预测:
      //   * 有陀螺仪先验时(推荐):预测 = 初始位置 + 陀螺仪算出的累计位移 + 累积修正。
      //     为什么用"绝对预测"而不是"上一帧 + 帧间增量":增量会把跟踪器自己的
      //     误差一路带下去,一旦真值跑出小窗口就再也回不来(实测会累积到十几像素)。
      //     绝对预测每帧都重新对齐陀螺仪基准,不会累积误差。
      //   * 累积修正:把视觉测到的偏差以一半的权重慢慢并入预测,这样陀螺仪的
      //     低频漂移能被视觉纠正,而视觉的测量噪声又不会被放大。
      //   * 没有先验时:退回"上一帧速度外推"。
      // 纯 SAD 只找"最像"的位置,遇到重复纹理(条纹、格子、马赛克)就会跳走,
      // 预测点 + 距离惩罚正是为了压住这种情况。
      final bool usePri =
          priorDx != null &&
          priorDy != null &&
          f < priorDx.length &&
          f < priorDy.length;
      final double predX0;
      final double predY0;
      if (usePri) {
        predX0 = boxCx0 + priorDx[f] + accX;
        predY0 = boxCy0 + priorDy[f] + accY;
      } else {
        predX0 = lastX + velX;
        predY0 = lastY + velY;
      }
      // 有先验时收紧搜索半径:陀螺仪已经把相机运动解释掉了,剩下要搜的
      // 只是"目标自身的位移 + 先验误差"。窗口小,重复纹理就不可能抢走匹配。
      final effSearch = usePri
          ? math.min(search, math.max(3, search ~/ 4))
          : search;
      final mx = w - bw;
      final my = h - bh;
      final predX = predX0;
      final predY = predY0;
      final wantX = (predX - bw / 2.0).round();
      final wantY = (predY - bh / 2.0).round();
      final sx0 = (wantX - effSearch).clamp(0, mx);
      final sx1 = (wantX + effSearch).clamp(0, mx);
      final sy0 = (wantY - effSearch).clamp(0, my);
      final sy1 = (wantY + effSearch).clamp(0, my);

      var bestScore = double.infinity;
      var bestSad = 0;
      var bestX = sx0, bestY = sy0;
      for (var ty = sy0; ty <= sy1; ty++) {
        for (var tx = sx0; tx <= sx1; tx++) {
          final s = sadAt(base, tx, ty);
          final mad = s / n;
          final dx = (tx + bw / 2.0 - predX).abs();
          final dy = (ty + bh / 2.0 - predY).abs();
          final score = mad + _distPenalty * (dx + dy);
          if (score < bestScore) {
            bestScore = score;
            bestSad = s;
            bestX = tx;
            bestY = ty;
          }
        }
      }

      // 亚像素细化:在极小值两侧做抛物线拟合,亚像素精度能让曲线平滑、
      // 不出整像素的台阶(台阶会在成片里表现为细微的跳动)
      var subX = 0.0, subY = 0.0;
      if (bestX > sx0 && bestX < sx1) {
        final l = sadAt(base, bestX - 1, bestY).toDouble();
        final r = sadAt(base, bestX + 1, bestY).toDouble();
        final d = l - 2.0 * bestSad + r;
        if (d.abs() > 1e-6) {
          subX = (0.5 * (l - r) / d).clamp(-1.0, 1.0);
        }
      }
      if (bestY > sy0 && bestY < sy1) {
        final u = sadAt(base, bestX, bestY - 1).toDouble();
        final v = sadAt(base, bestX, bestY + 1).toDouble();
        final d = u - 2.0 * bestSad + v;
        if (d.abs() > 1e-6) {
          subY = (0.5 * (u - v) / d).clamp(-1.0, 1.0);
        }
      }

      cx = bestX + subX + bw / 2.0;
      cy = bestY + subY + bh / 2.0;
      if (usePri) {
        // 把"实测位置与预测位置的差"以一半权重并入累积修正:
        // 陀螺仪的缓慢漂移能被纠正,而单帧的测量噪声不会直接进入预测
        accX += (cx - predX0) * 0.5;
        accY += (cy - predY0) * 0.5;
        // 累积修正本身也要限幅,避免被一次误匹配带偏
        final cap = search * 4.0;
        accX = accX.clamp(-cap, cap);
        accY = accY.clamp(-cap, cap);
      }
      // 速度用带阻尼的更新,避免一次误匹配把预测甩飞
      velX = velX * 0.5 + (cx - lastX) * 0.5;
      velY = velY * 0.5 + (cy - lastY) * 0.5;
      // 限制单帧速度,防止连续误匹配越跑越偏
      velX = velX.clamp(-search / 2.0, search / 2.0);
      velY = velY.clamp(-search / 2.0, search / 2.0);
      lastX = cx;
      lastY = cy;
      final mad = bestSad / n;
      // 残差过大 = 目标被遮挡/丢失;此时仍给出位置(沿用当前最佳),但标记不可信
      out.add(TrackPoint(f / fps, cx, cy, mad, mad < 45));
    }
    _lastReacquired = reacquired;
    return out;
  }

  /// 上次跟踪里实际生效的锚点重捕获次数(诊断用)
  static int _lastReacquired = 0;
  static int get lastReacquired => _lastReacquired;

  /// 把一个归一化框里的小块采样成固定的 24×24 灰度,用于跨帧比较外观。
  /// 固定在同一个尺寸上比较,才能容忍目标的远近/大小变化。
  static List<double> patchOf(
    Uint8List gray,
    int w,
    int h,
    double left,
    double top,
    double width,
    double height,
  ) {
    const n = kNccSize;
    final out = List<double>.filled(n * n, 0);
    final x0 = left * w, y0 = top * h;
    final bw = width * w, bh = height * h;
    if (bw < 2 || bh < 2) return out;
    for (var j = 0; j < n; j++) {
      final sy = (y0 + bh * (j + 0.5) / n).round().clamp(0, h - 1);
      for (var i = 0; i < n; i++) {
        final sx = (x0 + bw * (i + 0.5) / n).round().clamp(0, w - 1);
        out[j * n + i] = gray[sy * w + sx].toDouble();
      }
    }
    return out;
  }

  /// 归一化互相关(-1~1,越大越像)。
  /// 用 NCC 而不是直接比灰度:目标在录像过程中亮度/对比度会变(自动曝光),
  /// 直接比会误判成"不是同一个目标"。
  static double ncc(List<double> a, List<double> b) {
    final n = a.length < b.length ? a.length : b.length;
    if (n == 0) return 0;
    var ma = 0.0, mb = 0.0;
    for (var i = 0; i < n; i++) {
      ma += a[i];
      mb += b[i];
    }
    ma /= n;
    mb /= n;
    var sa = 0.0, sb = 0.0, sab = 0.0;
    for (var i = 0; i < n; i++) {
      final da = a[i] - ma;
      final db = b[i] - mb;
      sa += da * da;
      sb += db * db;
      sab += da * db;
    }
    final d = math.sqrt(sa * sb);
    return d < 1e-6 ? 0 : sab / d;
  }

  static const int kNccSize = 24;

  /// 线性插值取曲线在 [t] 时刻的值
  static double interp(List<List<double>> curve, double t) {
    if (curve.isEmpty) return 0;
    if (t <= curve.first[0]) return curve.first[1];
    if (t >= curve.last[0]) return curve.last[1];
    var lo = 0, hi = curve.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (curve[mid][0] <= t) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final t0 = curve[lo][0], t1 = curve[hi][0];
    if (t1 - t0 < 1e-9) return curve[hi][1];
    final k = (t - t0) / (t1 - t0);
    return curve[lo][1] + (curve[hi][1] - curve[lo][1]) * k;
  }

  /// 由跟踪点算出"把目标拉到画面正中"所需的画面位移曲线 [t, vx, vy]。
  /// 单位与 [frameW]/[frameH] 一致(成片像素),时间基准与跟踪点相同。
  /// [trackW]/[trackH] 是跟踪帧的尺寸。
  static List<List<double>> lockCurve({
    required List<TrackPoint> pts,
    required double frameW,
    required double frameH,
    required int trackW,
    required int trackH,
    int smooth = 3,
  }) {
    final raw = <List<double>>[];
    for (final p in pts) {
      // 目标中心归一化 → 需要把画面朝哪边移动多少像素
      final nx = p.cx / trackW;
      final ny = p.cy / trackH;
      raw.add(<double>[p.t, (0.5 - nx) * frameW, (0.5 - ny) * frameH]);
    }
    if (raw.length < 2 || smooth <= 1) return raw;
    // 轻度滑动平均:只用来压掉跟踪噪声,不影响锁定强度
    final half = smooth ~/ 2;
    final out = <List<double>>[];
    for (var i = 0; i < raw.length; i++) {
      var sx = 0.0, sy = 0.0;
      var c = 0;
      for (var k = -half; k <= half; k++) {
        final j = i + k;
        if (j < 0 || j >= raw.length) continue;
        sx += raw[j][1];
        sy += raw[j][2];
        c++;
      }
      out.add(<double>[raw[i][0], sx / c, sy / c]);
    }
    return out;
  }
}
