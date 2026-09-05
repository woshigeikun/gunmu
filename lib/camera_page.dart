import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';

import 'ble_heart_rate.dart';

/// 相机页:预览 + 实时心率叠加 + 录像
class CameraPage extends StatefulWidget {
  final BleHeartRate ble;
  const CameraPage({super.key, required this.ble});

  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> {
  CameraController? _cam;
  bool _recording = false;
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
    if (_cam == null) return;
    if (!_recording) {
      await _cam!.startVideoRecording();
      if (mounted) setState(() => _recording = true);
    } else {
      final XFile file = await _cam!.stopVideoRecording();
      if (mounted) setState(() => _recording = false);
      await _save(file);
    }
  }

  Future<void> _save(XFile file) async {
    try {
      final ok = await Gal.requestAccess(toAlbum: true);
      if (ok) {
        await Gal.putVideo(file.path);
        if (mounted) setState(() => _hint = '已保存到相册');
      } else {
        if (mounted) setState(() => _hint = '相册权限被拒绝');
      }
    } catch (e) {
      if (mounted) setState(() => _hint = '保存失败: $e');
    }
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

          // 状态提示
          if (_hint.isNotEmpty)
            Positioned(
              top: 60,
              left: 20,
              child: Text(
                _hint,
                style: const TextStyle(color: Colors.yellowAccent),
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
                    _recording ? '● 录制中' : '点击开始录像',
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
    _cam?.dispose();
    super.dispose();
  }
}
