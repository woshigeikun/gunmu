import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'ble_heart_rate.dart';

/// 一次心率采样:相对录像开始的时间(毫秒)+ 心率值
class _HrSample {
  final int ms;
  final int bpm;
  _HrSample(this.ms, this.bpm);
}

/// 相机页:预览 + 实时心率 + 心率曲线 + 前后摄切换 + 录像烧录
class CameraPage extends StatefulWidget {
  final BleHeartRate ble;
  const CameraPage({super.key, required this.ble});

  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> {
  CameraController? _cam;
  List<CameraDescription> _cameras = [];
  int _camIndex = 0;
  bool _recording = false;
  bool _busy = false;
  final Stopwatch _timer = Stopwatch();
  Timer? _ticker; // 录制期间每秒刷新界面(修复计时不动 bug)
  String _hint = '';

  // 录像期间的心率时间线(用于烧录)
  final List<_HrSample> _samples = [];
  // 实时心率历史(用于屏幕曲线,最多保留 120 个点)
  final List<int> _history = [];

  @override
  void initState() {
    super.initState();
    _initCamera();
    // 订阅心率:录像中记录时间线;屏幕历史始终累积
    widget.ble.bpmStream.listen((bpm) {
      _history.add(bpm);
      if (_history.length > 120) _history.removeAt(0);
      if (_recording) {
        _samples.add(_HrSample(_timer.elapsedMilliseconds, bpm));
      }
      _refresh();
    });
  }

  Future<void> _initCamera() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) throw Exception('没有可用摄像头');
      _cameras = cams;
      _camIndex = 0;
      await _openCamera(0);
    } catch (e) {
      if (mounted) setState(() => _hint = '相机初始化失败: $e');
    }
  }

  Future<void> _openCamera(int index) async {
    final old = _cam;
    _cam = null;
    await old?.dispose().catchError((_) {});
    final desc = _cameras[index];
    final c = CameraController(desc, ResolutionPreset.high, enableAudio: true);
    await c.initialize();
    if (!mounted) {
      await c.dispose();
      return;
    }
    setState(() {
      _cam = c;
      _camIndex = index;
    });
  }

  /// 切换前后摄像头(录制/处理中禁止)
  Future<void> _switchCamera() async {
    if (_recording || _busy || _cameras.length < 2) return;
    _busy = true;
    _refresh();
    try {
      await _openCamera((_camIndex + 1) % _cameras.length);
    } catch (e) {
      if (mounted) setState(() => _hint = '切换摄像头失败: $e');
    } finally {
      _busy = false;
      _refresh();
    }
  }

  Future<void> _toggleRecord() async {
    final cam = _cam;
    if (cam == null || !cam.value.isInitialized || _busy) return;
    _busy = true;
    _refresh();
    try {
      if (!_recording) {
        // ── 开始录像 ──
        await cam.startVideoRecording();
        _timer
          ..reset()
          ..start();
        _samples.clear();
        // 每秒刷新一次界面,让计时数字走动
        _ticker?.cancel();
        _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
          if (_recording && mounted) setState(() {});
        });
        if (mounted) {
          setState(() {
            _recording = true;
            _hint = '';
          });
        }
      } else {
        // ── 停止录像 ──
        _ticker?.cancel();
        _timer.stop();

        // 保护:iOS 上录像过短(<1秒)时 stopVideoRecording 可能原生崩溃
        if (_timer.elapsedMilliseconds < 1000) {
          _timer.start();
          _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
            if (_recording && mounted) setState(() {});
          });
          if (mounted) {
            setState(() => _hint = '录像太短,请继续录满 1 秒再停止');
          }
          return;
        }

        final XFile file = await cam.stopVideoRecording();
        if (mounted) setState(() => _recording = false);
        await _burnAndSave(file); // 烧录 + 保存,内部自带 try/catch
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _recording = false;
          _hint = '录像出错: $e';
        });
      }
    } finally {
      _busy = false;
      _refresh();
    }
  }

  /// ① 用 FFmpeg 把心率烧进视频右上角 ② 保存到文件目录 ③ 弹分享面板
  Future<void> _burnAndSave(XFile raw) async {
    // 分享面板锚点:在首个 await 前从 context 取好,避免跨 async 使用
    final renderBox = context.findRenderObject() as RenderBox?;
    final shareOrigin = renderBox != null
        ? renderBox.localToGlobal(Offset.zero) & renderBox.size
        : null;
    try {
      // 1) 解析原视频尺寸与时长(字幕坐标需要像素尺寸)
      final info = await FFprobeKit.getMediaInformation(raw.path);
      final mi = info.getMediaInformation();
      if (mi == null) throw Exception('无法读取视频信息');
      int width = 1920, height = 1080;
      double? durationSec;
      for (final s in mi.getStreams()) {
        if (s.getType() == 'video') {
          width = s.getWidth() ?? width;
          height = s.getHeight() ?? height;
        }
      }
      final durStr = mi.getDuration(); // 形如 "12.345"
      durationSec = durStr != null ? double.tryParse(durStr) : null;
      if (durationSec == null || durationSec <= 0) {
        durationSec = _timer.elapsedMilliseconds / 1000.0;
      }

      // 2) 生成 ASS 字幕:每个心率采样一条,右上角显示 ❤ bpm(红色)
      final docs = await getApplicationDocumentsDirectory();
      final workDir = Directory('${docs.path}/work');
      if (!workDir.existsSync()) workDir.createSync(recursive: true);
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final assPath = '${workDir.path}/$stamp.ass';
      _writeAss(assPath, width, height, durationSec);

      // 3) FFmpeg 烧录:字幕滤镜 + 重新编码为 mp4
      if (mounted) setState(() => _hint = '正在合成心率到视频…');
      final outPath = '${workDir.path}/$stamp.mp4';
      final cmd =
          '-y -i "${raw.path}" -vf "ass=$assPath" '
          '-c:v libx264 -preset veryfast -crf 22 '
          '-c:a aac -b:a 128k "$outPath"';
      final session = await FFmpegKit.execute(cmd);
      final rc = await session.getReturnCode();
      if (!ReturnCode.isSuccess(rc)) {
        throw Exception('FFmpeg 合成失败 (rc=$rc)');
      }

      // 4) 保存到"文件"目录(带 .mp4)
      final folder = Directory('${docs.path}/录像');
      if (!folder.existsSync()) folder.createSync(recursive: true);
      final saved = '${folder.path}/$stamp.mp4';
      await File(outPath).copy(saved);
      // 清理工作文件
      try {
        File(assPath).deleteSync();
        File(outPath).deleteSync();
        File(raw.path).deleteSync();
      } catch (_) {}

      // 5) 弹出系统分享面板(可"存储视频"到相册/发给微信等)
      if (mounted) setState(() => _hint = '合成完成,弹出分享…');
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(saved)],
          text: '心率录像',
          sharePositionOrigin: shareOrigin,
        ),
      );
      if (mounted) {
        setState(() => _hint = '已保存(带心率),可在"文件"App→本App→录像 查看');
      }
    } catch (e) {
      if (mounted) setState(() => _hint = '合成保存失败: $e');
    }
  }

  /// 生成 ASS 字幕文件:右上角显示 ♥ bpm,文本红色、黑描边
  void _writeAss(String path, int width, int height, double durationSec) {
    // 心率采样点若为空,给个占位值
    if (_samples.isEmpty) {
      _samples.add(_HrSample(0, 0));
    }
    // 字体大小按画面高度约 4%
    final fontSize = (height * 0.045).round().clamp(24, 200);

    final sb = StringBuffer()
      ..writeln('[Script Info]')
      ..writeln('ScriptType: v4.00+')
      ..writeln('PlayResX: $width')
      ..writeln('PlayResY: $height')
      ..writeln()
      ..writeln('[V4+ Styles]')
      ..writeln(
        'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, '
        'OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, '
        'ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, '
        'Alignment, MarginL, MarginR, MarginV, Encoding',
      )
      // ASS 颜色格式 &HAABBGGRR:主色纯红 = &H000000FF,黑描边 &H00000000
      ..writeln(
        'Style: HR,Helvetica,$fontSize,&H000000FF,&H000000FF,&H00000000,'
        '&H64000000,1,0,0,0,100,100,0,0,1,4,2,9,0,30,40,1',
      )
      ..writeln()
      ..writeln('[Events]')
      ..writeln(
        'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, '
        'Effect, Text',
      );

    // 逐条字幕:每条从采样时间点持续到下一个采样点(或视频末尾)
    for (var i = 0; i < _samples.length; i++) {
      final s = _samples[i];
      final endMs = (i + 1 < _samples.length)
          ? _samples[i + 1].ms
          : (durationSec * 1000).round();
      // 至少显示 0.8 秒,防止过快闪没
      var e = endMs;
      if (e <= s.ms) e = s.ms + 800;
      sb.writeln(
        'Dialogue: 0,${_assTime(s.ms / 1000)},${_assTime(e / 1000)},HR,,0,0,0,,'
        '${s.bpm > 0 ? '♥ ${s.bpm}' : '♥ --'}',
      );
    }
    File(path).writeAsStringSync(sb.toString());
  }

  /// 秒 → ASS 时间格式 H:MM:SS.cc
  String _assTime(double sec) {
    if (sec < 0) sec = 0;
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    final s = (sec % 60).floor();
    final cs = ((sec - sec.floorToDouble()) * 100).round();
    String two(int v) => v.toString().padLeft(2, '0');
    return '$h:${two(m)}:${two(s)}.${two(cs)}';
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cam = _cam;
    final bpmNow = widget.ble.currentBpm;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (cam != null && cam.value.isInitialized)
            Positioned.fill(child: CameraPreview(cam))
          else
            const Center(child: CircularProgressIndicator()),

          // ── 心率叠加层(右上角实时数字)──
          StreamBuilder<int>(
            stream: widget.ble.bpmStream,
            initialData: bpmNow,
            builder: (context, snap) {
              final bpm = snap.data ?? 0;
              return Positioned(
                top: 60,
                right: 20,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.favorite, color: Colors.red, size: 22),
                      const SizedBox(width: 8),
                      Text(
                        '$bpm',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Text(
                        ' bpm',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),

          // ── 切换摄像头按钮(左上角,录制中禁用)──
          Positioned(
            top: 60,
            left: 16,
            child: IconButton(
              onPressed: (_recording || _busy || _cameras.length < 2)
                  ? null
                  : _switchCamera,
              icon: const Icon(
                Icons.cameraswitch,
                color: Colors.white,
                size: 28,
              ),
              style: IconButton.styleFrom(
                backgroundColor: Colors.black38,
                disabledBackgroundColor: Colors.black12,
              ),
            ),
          ),

          // 状态/错误提示
          if (_hint.isNotEmpty)
            Positioned(
              top: 110,
              left: 20,
              right: 60,
              child: Text(
                _hint,
                style: const TextStyle(
                  color: Colors.yellowAccent,
                  fontSize: 12,
                ),
              ),
            ),

          // ── 实时心率曲线(录制中,底部按钮上方)──
          if (_recording && _history.length >= 2)
            Positioned(
              left: 12,
              right: 12,
              bottom: 150,
              height: 90,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black38,
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.favorite, color: Colors.red, size: 14),
                        const SizedBox(width: 4),
                        Text(
                          '心率曲线  $bpmNow bpm',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Expanded(
                      child: CustomPaint(
                        painter: _HrCurvePainter(_history),
                        size: Size.infinite,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // ── 录像按钮 ──
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _busy
                        ? '处理中…'
                        : (_recording
                              ? '● ${_timer.elapsed.inSeconds}s 点此停止'
                              : '点击开始录像'),
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton.large(
                    backgroundColor: _recording ? Colors.red : Colors.white,
                    onPressed: _toggleRecord,
                    child: Icon(
                      _recording ? Icons.stop : Icons.circle,
                      color: _recording ? Colors.white : Colors.red,
                      size: 36,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _timer.stop();
    _cam?.dispose();
    super.dispose();
  }
}

/// 心率曲线画笔:横轴为最近的心率历史,纵轴按数据范围自适应
class _HrCurvePainter extends CustomPainter {
  final List<int> data;
  _HrCurvePainter(this.data);

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    int minV = data.reduce((a, b) => a < b ? a : b);
    int maxV = data.reduce((a, b) => a > b ? a : b);
    if (maxV - minV < 10) {
      // 太平时人为扩出上下界,曲线不至于拍平
      minV = minV - 5 < 30 ? 30 : minV - 5;
      maxV = maxV + 5;
    }
    final range = (maxV - minV).toDouble();

    final line = Paint()
      ..color = Colors.redAccent
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final n = data.length;
    final path = Path();
    for (var i = 0; i < n; i++) {
      final x = size.width * i / (n - 1);
      final y =
          size.height - ((data[i] - minV) / range) * size.height * 0.9 - 2;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, line);

    // 最后一个点画个圆点
    final lastX = size.width;
    final lastY =
        size.height - ((data.last - minV) / range) * size.height * 0.9 - 2;
    canvas.drawCircle(Offset(lastX, lastY), 4, Paint()..color = Colors.red);
  }

  @override
  bool shouldRepaint(covariant _HrCurvePainter old) =>
      old.data != data || old.data.length != data.length;
}
