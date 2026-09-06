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

/// 相机页:预览 + 实时心率叠加 + 录像 + FFmpeg 烧录心率进成片
class CameraPage extends StatefulWidget {
  final BleHeartRate ble;
  const CameraPage({super.key, required this.ble});

  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> {
  CameraController? _cam;
  bool _recording = false;
  bool _busy = false;
  final Stopwatch _timer = Stopwatch();
  String _hint = '';

  // 录像期间的心率时间线
  final List<_HrSample> _samples = [];
  int _recordStartMs = 0; // 录像开始时 Stopwatch 的读数

  @override
  void initState() {
    super.initState();
    _initCamera();
    // 订阅心率:录像中则记录 (时间, bpm)
    widget.ble.bpmStream.listen((bpm) {
      if (_recording) {
        _samples.add(
          _HrSample(_timer.elapsedMilliseconds - _recordStartMs, bpm),
        );
      }
    });
  }

  Future<void> _initCamera() async {
    try {
      final cams = await availableCameras();
      _cam = CameraController(
        cams.first,
        ResolutionPreset.high,
        enableAudio: true,
      );
      await _cam!.initialize();
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => _hint = '相机初始化失败: $e');
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
        _recordStartMs = 0;
        _samples.clear();
        if (mounted) {
          setState(() {
            _recording = true;
            _hint = '';
          });
        }
      } else {
        // ── 停止录像 ──
        _timer.stop();

        // 保护:iOS 上录像过短(<1秒)时 stopVideoRecording 可能原生崩溃
        if (_timer.elapsedMilliseconds < 1000) {
          _timer.start();
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

      // 2) 生成 ASS 字幕:每个心率采样一条,右上角显示 ❤ bpm
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

  /// 生成 ASS 字幕文件:右上角显示 ♥ 和 bpm
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
      ..writeln(
        'Style: HR,Helvetica,$fontSize,&H00FFFFFF,&H000000FF,&H00000000,'
        '&H80000000,1,0,0,0,100,100,0,0,1,3,1,9,0,30,40,1',
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
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (cam != null && cam.value.isInitialized)
            Positioned.fill(child: CameraPreview(cam))
          else
            const Center(child: CircularProgressIndicator()),

          // ── 心率叠加层(每次收到心率自动刷新)──
          StreamBuilder<int>(
            stream: widget.ble.bpmStream,
            initialData: widget.ble.currentBpm,
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

          // 状态/错误提示
          if (_hint.isNotEmpty)
            Positioned(
              top: 60,
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
    _timer.stop();
    _cam?.dispose();
    super.dispose();
  }
}
