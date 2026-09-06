import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'ble_heart_rate.dart';

/// 相机页:预览 + 实时心率叠加 + 录像
/// 【诊断版 v3】:停止后只保存到"文件"App 目录,不调用任何相册原生代码,
/// 用于二分定位闪退来源(camera 停止 vs 相册保存)。
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

  @override
  void initState() {
    super.initState();
    _initCamera();
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
        _timer..reset()..start();
        if (mounted) {
          setState(() {
            _recording = true;
            _hint = '';
          });
        }
      } else {
        // ── 停止录像 ──
        _timer.stop();

        // 保护:iOS 上录像过短(<1秒)时 stopVideoRecording 可能原生崩溃,
        // 因此太短时直接忽略本次停止,继续录制
        if (_timer.elapsedMilliseconds < 1000) {
          _timer.start();
          if (mounted) {
            setState(() => _hint = '录像太短,请继续录满 1 秒再停止');
          }
          return;
        }

        final XFile file = await cam.stopVideoRecording();
        if (mounted) setState(() => _recording = false);

        await _saveToDocuments(file); // 纯 Dart 保存,不碰相册
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

  /// 保存到 App 文档目录(iPhone"文件"App 可见),纯 Dart 无原生崩溃风险
  Future<void> _saveToDocuments(XFile file) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final folder = Directory('${dir.path}/录像');
      if (!folder.existsSync()) folder.createSync(recursive: true);
      final stamp = DateTime.now().millisecondsSinceEpoch;
      // 保留原扩展名(.mov 或 .mp4),避免改容器格式
      final dot = file.path.lastIndexOf('.');
      final ext = dot >= 0 ? file.path.substring(dot) : '.mov';
      final saved = '${folder.path}/$stamp$ext';
      await file.saveTo(saved);
      if (mounted) {
        setState(() => _hint = '已保存,可在iPhone"文件"App→本App→录像 中查看');
      }
    } catch (e) {
      if (mounted) setState(() => _hint = '保存失败: $e');
    }
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
                style: const TextStyle(color: Colors.yellowAccent, fontSize: 12),
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
