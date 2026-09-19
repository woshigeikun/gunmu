import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// 陀螺仪测试页:立方体随陀螺仪旋转,并显示 X / Y / Z
class GyroTestPage extends StatefulWidget {
  const GyroTestPage({super.key});

  @override
  State<GyroTestPage> createState() => _GyroTestPageState();
}

class _GyroTestPageState extends State<GyroTestPage> {
  StreamSubscription<GyroscopeEvent>? _sub;

  // 当前角速度(rad/s)
  double _gx = 0, _gy = 0, _gz = 0;
  // 累计旋转角度(度)
  double _ax = 0, _ay = 0, _az = 0;
  // 采样率(Hz)
  double _hz = 0;
  int _samples = 0;
  DateTime _hzWindow = DateTime.now();

  // 立方体姿态矩阵(3x3,行主序)
  List<double> _m = <double>[1, 0, 0, 0, 1, 0, 0, 0, 1];

  DateTime _last = DateTime.now();

  @override
  void initState() {
    super.initState();
    _last = DateTime.now();
    _sub = gyroscopeEventStream(samplingPeriod: SensorInterval.gameInterval)
        .listen(_onGyro, onError: (_) {});
  }

  void _onGyro(GyroscopeEvent e) {
    final now = DateTime.now();
    final dt = now.difference(_last).inMicroseconds / 1e6;
    _last = now;
    // 过滤异常间隔(切后台、卡顿)
    if (dt <= 0 || dt > 0.2) return;

    // 用角速度积分更新姿态;取负号使立方体像"固定在世界中"
    final rx = -e.x * dt;
    final ry = -e.y * dt;
    final rz = -e.z * dt;
    _m = _mul(_rotX(rx), _mul(_rotY(ry), _mul(_rotZ(rz), _m)));

    // 采样率统计
    _samples++;
    final win = now.difference(_hzWindow).inMilliseconds;
    if (win >= 500) {
      _hz = _samples * 1000 / win;
      _samples = 0;
      _hzWindow = now;
    }

    if (!mounted) return;
    setState(() {
      _gx = e.x;
      _gy = e.y;
      _gz = e.z;
      _ax += e.x * dt * 180 / math.pi;
      _ay += e.y * dt * 180 / math.pi;
      _az += e.z * dt * 180 / math.pi;
    });
  }

  // ── 3x3 旋转矩阵工具 ──
  static List<double> _rotX(double a) {
    final c = math.cos(a), s = math.sin(a);
    return <double>[1, 0, 0, 0, c, -s, 0, s, c];
  }

  static List<double> _rotY(double a) {
    final c = math.cos(a), s = math.sin(a);
    return <double>[c, 0, s, 0, 1, 0, -s, 0, c];
  }

  static List<double> _rotZ(double a) {
    final c = math.cos(a), s = math.sin(a);
    return <double>[c, -s, 0, s, c, 0, 0, 0, 1];
  }

  static List<double> _mul(List<double> a, List<double> b) {
    final r = List<double>.filled(9, 0);
    for (var i = 0; i < 3; i++) {
      for (var j = 0; j < 3; j++) {
        var s = 0.0;
        for (var k = 0; k < 3; k++) {
          s += a[i * 3 + k] * b[k * 3 + j];
        }
        r[i * 3 + j] = s;
      }
    }
    return r;
  }

  void _reset() {
    setState(() {
      _m = <double>[1, 0, 0, 0, 1, 0, 0, 0, 1];
      _ax = _ay = _az = 0;
      _last = DateTime.now();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('陀螺仪测试'),
        actions: [
          TextButton(
            onPressed: _reset,
            child: const Text('重置', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
      body: Column(
        children: [
          // ── 立方体 ──
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: CustomPaint(
                  painter: _CubePainter(_m),
                  size: Size.infinite,
                ),
              ),
            ),
          ),
          // ── XYZ 数据 ──
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            decoration: const BoxDecoration(
              color: Color(0xFF141416),
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.screen_rotation,
                      color: Colors.white70,
                      size: 16,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '采样率 ${_hz.toStringAsFixed(1)} Hz',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _axisRow('X', _gx, _ax, Colors.redAccent),
                const SizedBox(height: 8),
                _axisRow('Y', _gy, _ay, Colors.greenAccent),
                const SizedBox(height: 8),
                _axisRow('Z', _gz, _az, Colors.lightBlueAccent),
                const SizedBox(height: 12),
                const Text(
                  '单位:角速度 rad/s(左) · 累计角度 °(右)',
                  style: TextStyle(color: Colors.white30, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _axisRow(String axis, double rate, double deg, Color color) {
    return Row(
      children: [
        Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            axis,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 96,
          child: Text(
            rate.toStringAsFixed(3),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '${deg.toStringAsFixed(1)}°',
            style: TextStyle(
              color: color,
              fontSize: 15,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

/// 立方体绘制:手工做 3D 投影(不依赖额外 3D 库)
class _CubePainter extends CustomPainter {
  final List<double> m; // 旋转矩阵
  _CubePainter(this.m);

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final half = size.shortestSide * 0.26; // 立方体半边长(像素)

    // 8 个顶点:索引 i 的位含义 (x:4, y:2, z:1),1 = 正方向
    final verts = <List<double>>[];
    for (var i = 0; i < 8; i++) {
      final x = (i & 4) != 0 ? 1.0 : -1.0;
      final y = (i & 2) != 0 ? 1.0 : -1.0;
      final z = (i & 1) != 0 ? 1.0 : -1.0;
      verts.add(<double>[x * half, y * half, z * half]);
    }

    // 旋转 + 透视投影
    Offset project(List<double> p, [double? outZ]) {
      final rx = m[0] * p[0] + m[1] * p[1] + m[2] * p[2];
      final ry = m[3] * p[0] + m[4] * p[1] + m[5] * p[2];
      final rz = m[6] * p[0] + m[7] * p[1] + m[8] * p[2];
      const camDist = 3.2; // 相机距离(以半边长计)
      final depth = rz / half; // -1 ~ 1
      final f = camDist / (camDist + depth);
      return Offset(cx + rx * f, cy - ry * f);
    }

    // 6 个面(顶点索引,逆时针)
    const faces = <List<int>>[
      [1, 3, 7, 5], // z+
      [0, 4, 6, 2], // z-
      [4, 5, 7, 6], // x+
      [0, 2, 3, 1], // x-
      [2, 6, 7, 3], // y+
      [0, 1, 5, 4], // y-
    ];

    // 面法线(模型空间)
    const normals = <List<double>>[
      [0, 0, 1],
      [0, 0, -1],
      [1, 0, 0],
      [-1, 0, 0],
      [0, 1, 0],
      [0, -1, 0],
    ];

    // 光照方向(视图空间)
    const light = <double>[0.35, 0.55, 0.75];

    // 计算每个面的平均深度,远的先画(painter's algorithm)
    final order = List<int>.generate(6, (i) => i);
    double faceDepth(int fi) {
      var s = 0.0;
      for (final vi in faces[fi]) {
        final p = verts[vi];
        s += m[6] * p[0] + m[7] * p[1] + m[8] * p[2];
      }
      return s / 4;
    }

    order.sort((a, b) => faceDepth(a).compareTo(faceDepth(b)));

    final edgePaint = Paint()
      ..color = const Color(0xCCFFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeJoin = StrokeJoin.round;

    for (final fi in order) {
      final idx = faces[fi];
      final path = Path();
      for (var k = 0; k < idx.length; k++) {
        final o = project(verts[idx[k]]);
        if (k == 0) {
          path.moveTo(o.dx, o.dy);
        } else {
          path.lineTo(o.dx, o.dy);
        }
      }
      path.close();

      // 旋转法线 → 简单漫反射着色
      final n = normals[fi];
      final nx = m[0] * n[0] + m[1] * n[1] + m[2] * n[2];
      final ny = m[3] * n[0] + m[4] * n[1] + m[5] * n[2];
      final nz = m[6] * n[0] + m[7] * n[1] + m[8] * n[2];
      final diff = (nx * light[0] + ny * light[1] + nz * light[2]).abs();
      final shade = (0.22 + 0.62 * diff).clamp(0.15, 0.95);

      canvas.drawPath(
        path,
        Paint()
          ..color = Color.lerp(
            const Color(0xFF1B1B1F),
            const Color(0xFFFF3B30),
            shade,
          )!
          ..style = PaintingStyle.fill,
      );
      canvas.drawPath(path, edgePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _CubePainter old) => old.m != m;
}
