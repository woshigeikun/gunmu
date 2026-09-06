import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

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
  bool _busy = false; // 防止录像开始/停止过程中重复点击
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
    try {
      if (!_recording) {
        // ── 开始录像 ──
        await cam.startVideoRecording();
        if (mounted) {
          setState(() {
            _recording = true;
            _hint = '';
          });
        }
      } else {
        // ── 停止录像 ──
        final XFile file = await cam.stopVideoRecording();
        if (mounted) setState(() => _recording = false);
        await _saveVideo(file); // 单独处理,内部自带 try/catch,不会崩
      }
    } catch (e) {
      // 关键修复:任何录像异常都显示出来,而不是让 App 闪退
      if (mounted) {
        setState(() {
          _recording = false;
          _hint = '录像出错: $e';
        });
      }
    } finally {
      _busy = false;
    }
  }

  /// 保存录像:① 复制到 App 文档目录(兜底,文件App可见)② 存相册
  Future<void> _saveVideo(XFile file) async {
    String docPath = '';
    try {
      // ① 先复制一份到 Documents/录像 目录 —— 即使相册失败视频也不丢
      final dir = await getApplicationDocumentsDirectory();
      final folder = Directory('${dir.path}/录像');
      if (!folder.existsSync()) folder.createSync(recursive: true);
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final saved = '${folder.path}/$stamp.mp4';
      await file.saveTo(saved);
      docPath = saved;
    } catch (_) {
      // 文档兜底失败不致命,继续尝试相册
    }

    // ② 保存到系统相册
    try {
      final ok = await Gal.requestAccess(toAlbum: true);
      if (ok) {
        await Gal.putVideo(file.path);
        if (mounted) {
          setState(() =>
              _hint = docPath.isEmpty ? '已保存到相册' : '已保存到相册与文件');
        }
      } else {
        if (mounted) {
          setState(() =>
              _hint = docPath.isEmpty ? '相册权限被拒绝' : '相册权限被拒,已存到"文件"App');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() =>
            _hint = docPath.isEmpty ? '保存失败: $e' : '相册保存失败: $e,已存到"文件"App');
      }
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
                        : (_recording ? '● 录制中,点此停止' : '点击开始录像'),
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
