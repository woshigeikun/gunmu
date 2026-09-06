import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

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
  double _zoom = 1.0; // 当前变焦倍数(等效 35mm 主摄按 26mm 起算)

  // 录制画质与帧率设置
  // 默认 medium:iPhone 该档输出 4:3 画幅(480p 级别),即"默认预览 4:3"
  ResolutionPreset _quality = ResolutionPreset.medium;
  int _fps = 30; // 默认 30 帧

  // 手环连接面板状态
  bool _connecting = false;
  String _bleStatus = '未连接手环';

  /// 画质档位(供设置面板展示)
  static const List<(ResolutionPreset, String, String)> _qualityOptions = [
    (ResolutionPreset.low, '标清', '≈480p'),
    (ResolutionPreset.medium, '普通', '≈540p'),
    (ResolutionPreset.high, '高清', '≈720p'),
    (ResolutionPreset.veryHigh, '超清', '≈1080p'),
    (ResolutionPreset.ultraHigh, '4K', '≈2160p'),
    (ResolutionPreset.max, '最高', '设备上限'),
  ];

  /// 常用变焦档位:倍数 + 等效焦距文案(26mm × 倍数)
  static const List<(double, String)> _zoomPresets = [
    (0.5, '0.5x · 13mm 超广'),
    (1.0, '1x · 26mm 主摄'),
    (2.0, '2x · 52mm'),
    (3.0, '3x · 78mm'),
    (5.0, '5x · 130mm'),
    (10.0, '10x · 260mm'),
  ];

  // 录像期间的心率时间线(用于烧录)
  final List<_HrSample> _samples = [];
  // 实时心率历史(用于屏幕曲线,最多保留 120 个点)
  final List<int> _history = [];
  // 当前这段录像开始时手环是否已连接(未连接则整段不带心率 UI)
  bool _recordHadBle = false;

  @override
  void initState() {
    super.initState();
    _initCamera();
    // 订阅心率:录像中记录时间线;屏幕历史始终累积
    widget.ble.bpmStream.listen((bpm) {
      _history.add(bpm);
      if (_history.length > 120) _history.removeAt(0);
      // 仅当"本段录像开始时就已连接"才采样烧录;连接后才录的段照常
      if (_recording && _recordHadBle) {
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
    final c = CameraController(desc, _quality, enableAudio: true, fps: _fps);
    try {
      await c.initialize();
    } catch (e) {
      // 该质量/帧率组合可能不被支持,回退默认质量再试一次
      if (mounted) setState(() => _hint = '所选画质不支持,使用默认画质: $e');
      final c2 = CameraController(
        desc,
        ResolutionPreset.high,
        enableAudio: true,
        fps: 30,
      );
      await c2.initialize();
      if (!mounted) {
        await c.dispose();
        await c2.dispose();
        return;
      }
      setState(() {
        _cam = c2;
        _camIndex = index;
        _zoom = 1.0;
        _quality = ResolutionPreset.high;
        _fps = 30;
      });
      return;
    }
    if (!mounted) {
      await c.dispose();
      return;
    }
    setState(() {
      _cam = c;
      _camIndex = index;
      _zoom = 1.0; // 切换镜头后变焦回到 1x
    });
  }

  /// 打开"连接手环"半页面板(自下而上,占屏幕 2/3)
  Future<void> _showBleSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final sheetHeight = MediaQuery.of(ctx).size.height * 2 / 3;
        return StatefulBuilder(
          builder: (context2, setSheetState) {
            final connected = widget.ble.isConnected;
            return SizedBox(
              height: sheetHeight,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.white24,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        '连接手环',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '先在小米运动健康 App 中开启手环"心率广播",再连接',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      const SizedBox(height: 20),

                      // ── 连接状态与按钮 ──
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white10,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                Icon(
                                  connected
                                      ? Icons.favorite
                                      : Icons.bluetooth_disabled,
                                  color: connected
                                      ? Colors.redAccent
                                      : Colors.white38,
                                  size: 28,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    connected
                                        ? '已连接 · 心率 ${widget.ble.currentBpm} bpm'
                                        : _connecting
                                        ? '正在扫描手环…(约 12 秒)'
                                        : _bleStatus,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 15,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (connected) ...[
                              const SizedBox(height: 12),
                              Text(
                                '${widget.ble.currentBpm}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 56,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),

                      const Spacer(),

                      // 主操作按钮
                      SizedBox(
                        width: double.infinity,
                        child: connected
                            ? OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.white70,
                                  side: const BorderSide(color: Colors.white24),
                                ),
                                onPressed: () async {
                                  await widget.ble.disconnect();
                                  setSheetState(() {});
                                  if (mounted) {
                                    setState(() {
                                      _bleStatus = '未连接手环';
                                      _history.clear();
                                      _samples.clear();
                                    });
                                  }
                                },
                                icon: const Icon(Icons.link_off),
                                label: const Text('断开连接'),
                              )
                            : FilledButton.icon(
                                style: FilledButton.styleFrom(
                                  backgroundColor: Colors.redAccent,
                                ),
                                onPressed: _connecting
                                    ? null
                                    : () => _connectBle(setSheetState),
                                icon: const Icon(Icons.bluetooth_searching),
                                label: Text(_connecting ? '连接中…' : '连接手环'),
                              ),
                      ),
                      const SizedBox(height: 8),
                      if (widget.ble.currentBpm > 0 && !connected)
                        Center(
                          child: Text(
                            '上次心率:${widget.ble.currentBpm}',
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 执行连接;结果刷新面板与主界面状态
  Future<void> _connectBle(StateSetter setSheetState) async {
    setState(() {
      _connecting = true;
      _bleStatus = '正在扫描手环…(约 12 秒)';
    });
    if (mounted) setSheetState(() {});
    try {
      await widget.ble.connect();
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _bleStatus = '已连接';
      });
      setSheetState(() {});
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _bleStatus = '连接失败,请确认已开启心率广播';
      });
      setSheetState(() {});
    }
  }

  /// 打开镜头选择面板:平铺所有摄像头方向与可用变焦档位(含等效 mm)
  Future<void> _showLensSheet() async {
    final cam = _cam;
    if (cam == null || !cam.value.isInitialized) return;
    if (_recording || _busy) return; // 录制/处理中禁止切换
    double minZ = 1, maxZ = 1;
    try {
      minZ = await cam.getMinZoomLevel();
      maxZ = await cam.getMaxZoomLevel();
    } catch (_) {}
    if (!mounted) return;

    // 过滤当前可达的档位(±0.01 容差)
    final reachable = _zoomPresets
        .where((p) => p.$1 >= minZ - 0.01 && p.$1 <= maxZ + 0.01)
        .toList();
    final isFront =
        _cameras[_camIndex].lensDirection == CameraLensDirection.front;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '镜头与变焦',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '等效 35mm 焦距(主摄 26mm 起算)',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                const SizedBox(height: 14),

                // ── 摄像头方向 ──
                Wrap(
                  spacing: 10,
                  children: List.generate(_cameras.length, (i) {
                    final d = _cameras[i];
                    final sel = i == _camIndex;
                    final label = d.lensDirection == CameraLensDirection.front
                        ? '前置摄像头'
                        : '后置摄像头';
                    return ChoiceChip(
                      label: Text(
                        label,
                        style: TextStyle(
                          color: sel ? Colors.black : Colors.white,
                        ),
                      ),
                      selected: sel,
                      selectedColor: Colors.white,
                      backgroundColor: Colors.white10,
                      onSelected: (_) async {
                        Navigator.pop(ctx);
                        if (i != _camIndex) {
                          await _openCamera(i); // 会重置 zoom 为 1x
                        }
                      },
                    );
                  }),
                ),
                const SizedBox(height: 16),

                // ── 变焦档位 ──
                Text(
                  isFront ? '前置摄像头通常为 1x' : '变焦档位',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _zoomPresets.map((p) {
                    final ok = p.$1 >= minZ - 0.01 && p.$1 <= maxZ + 0.01;
                    final active = (_zoom - p.$1).abs() < 0.01;
                    final color = !ok
                        ? Colors.white12
                        : (active ? Colors.redAccent : Colors.white24);
                    return InkWell(
                      onTap: ok
                          ? () async {
                              try {
                                await cam.setZoomLevel(p.$1);
                                if (mounted) setState(() => _zoom = p.$1);
                              } catch (_) {}
                              if (ctx.mounted) Navigator.pop(ctx);
                            }
                          : null,
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          p.$2,
                          style: TextStyle(
                            color: ok
                                ? (active ? Colors.black : Colors.white)
                                : Colors.white30,
                            fontSize: 13,
                            fontWeight: active ? FontWeight.bold : null,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                if (reachable.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      '当前镜头无可选变焦档位',
                      style: TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 画质/帧率设置面板;选好后重新打开相机使设置生效(需未在录像)
  Future<void> _showSettingsSheet() async {
    if (_recording || _busy) {
      if (mounted) {
        setState(() => _hint = '录像中不可修改画质,请先停止录像');
      }
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context2, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '录制设置',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      '画质',
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _qualityOptions.map((q) {
                        final sel = q.$1 == _quality;
                        return ChoiceChip(
                          label: Text(
                            '${q.$2} ${q.$3}',
                            style: TextStyle(
                              fontSize: 12,
                              color: sel ? Colors.black : Colors.white,
                            ),
                          ),
                          selected: sel,
                          selectedColor: Colors.redAccent,
                          backgroundColor: Colors.white10,
                          onSelected: (_) =>
                              setSheetState(() => _quality = q.$1),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      '帧率',
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [24, 30, 60].map((f) {
                        final sel = f == _fps;
                        return ChoiceChip(
                          label: Text(
                            '$f fps',
                            style: TextStyle(
                              color: sel ? Colors.black : Colors.white,
                            ),
                          ),
                          selected: sel,
                          selectedColor: Colors.redAccent,
                          backgroundColor: Colors.white10,
                          onSelected: (_) => setSheetState(() => _fps = f),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      '修改后需要重新启动相机预览生效。若设备不支持所选组合,将自动回退到 高清/30fps。',
                      style: TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _applySettings();
                        },
                        child: const Text('应用并重启预览'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 应用画质/帧率:重开当前镜头
  Future<void> _applySettings() async {
    if (_busy) return;
    _busy = true;
    _refresh();
    try {
      await _openCamera(_camIndex);
      if (mounted) {
        setState(() => _hint = '已应用画质设置,请开始录像');
      }
    } catch (e) {
      if (mounted) setState(() => _hint = '应用设置失败: $e');
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
        // 录制开始时刻是否已连手环:决定本段是否显示/烧录心率
        _recordHadBle = widget.ble.isConnected;
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

    // 本段录像开始时未连接手环 → 无心率数据,直接保存原视频(不烧任何 UI)
    if (!_recordHadBle) {
      try {
        final docs = await getApplicationDocumentsDirectory();
        final folder = Directory('${docs.path}/录像');
        if (!folder.existsSync()) folder.createSync(recursive: true);
        final stamp = DateTime.now().millisecondsSinceEpoch;
        final saved = '${folder.path}/$stamp.mp4';
        await raw.saveTo(saved);
        if (mounted) {
          setState(() => _hint = '已保存录像(未连接手环,无心率)');
        }
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(saved)],
            text: '录像',
            sharePositionOrigin: shareOrigin,
          ),
        );
      } catch (e) {
        if (mounted) setState(() => _hint = '保存失败: $e');
      }
      return;
    }

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

      // 2) 生成 ASS 字幕(右上角 ♥ bpm)+ 心率曲线 PNG(文字正下方)
      final docs = await getApplicationDocumentsDirectory();
      final workDir = Directory('${docs.path}/work');
      if (!workDir.existsSync()) workDir.createSync(recursive: true);
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final assPath = '${workDir.path}/$stamp.ass';
      final hasCurve = _samples.where((s) => s.bpm > 0).length >= 2;

      // 曲线区域尺寸:与心率文字一致(MarginR=30、MarginV=40、字号=高4.5%)
      final fontSize = (height * 0.045).round().clamp(24, 200);
      const marginRight = 30.0;
      const marginTop = 40.0;
      // 心率文字高度≈fontSize,曲线放其下方;加右侧数字列与上下限标注,略加高
      final curW = (fontSize * 3.0).round().clamp(80, 720);
      final curH = (fontSize * 1.35).round().clamp(32, 320);
      final curX = (width - marginRight - curW).round();
      final curY = (marginTop + fontSize * 1.12).round();

      _writeAss(assPath, width, height, durationSec);
      String? seqDir;
      if (hasCurve && durationSec > 1) {
        if (mounted) setState(() => _hint = '正在生成心率曲线动画…');
        // 有效采样(升序时间)
        final pts = _samples.where((s) => s.bpm > 0).toList();
        seqDir = '${workDir.path}/${stamp}_seq';
        final seq = Directory(seqDir);
        if (seq.existsSync()) seq.deleteSync(recursive: true);
        seq.createSync(recursive: true);

        final frameCount = durationSec.ceil() + 1; // 每秒一帧,含起始与结束
        var idx = 0; // pts 中最后一个 <= nowMs 的下标
        for (var f = 0; f < frameCount; f++) {
          final nowMs = (f * 1000).clamp(0, (durationSec * 1000).round());
          // 该帧"当前心率":时间 <= nowMs 的最近一次采样
          while (idx + 1 < pts.length && pts[idx + 1].ms <= nowMs) {
            idx++;
          }
          final cur = pts[idx].bpm.toDouble();
          final img = await _renderCurveFrame(curW, curH, nowMs, curBpm: cur);
          final data = await img.toByteData(format: ui.ImageByteFormat.png);
          final name = '${seq.path}/curve_${f.toString().padLeft(4, '0')}.png';
          File(name).writeAsBytesSync(data!.buffer.asUint8List());
        }
      }

      // 3) FFmpeg 烧录:字幕滤镜 + (曲线动画序列 overlay)+ 重新编码
      if (mounted) setState(() => _hint = '正在合成心率到视频…');
      final outPath = '${workDir.path}/$stamp.mp4';
      String cmd;
      if (seqDir != null) {
        // 输入0=原始视频(先烧字幕),输入1=曲线动画序列(1帧/秒)
        cmd =
            '-y -i "${raw.path}" -framerate 1 -i "$seqDir/curve_%04d.png" '
            '-filter_complex '
            '"[0:v]ass=$assPath[base];'
            '[1:v]scale=$curW:$curH,format=rgba,fps=30[ov];'
            '[base][ov]overlay=x=$curX:y=$curY:eof_action=repeat[outv]" '
            '-map "[outv]" -map 0:a? '
            '-c:v libx264 -preset veryfast -crf 22 '
            '-c:a aac -b:a 128k "$outPath"';
      } else {
        cmd =
            '-y -i "${raw.path}" -vf "ass=$assPath" '
            '-c:v libx264 -preset veryfast -crf 22 '
            '-c:a aac -b:a 128k "$outPath"';
      }
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
        if (seqDir != null) {
          Directory(seqDir).deleteSync(recursive: true);
        }
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
    // 心率采样点若为空,用局部占位(不污染 _samples)
    final eff = _samples.isEmpty ? [_HrSample(0, 0)] : _samples;
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
    for (var i = 0; i < eff.length; i++) {
      final s = eff[i];
      if (s.bpm <= 0) continue; // 跳过无数据点
      final endMs = (i + 1 < eff.length)
          ? eff[i + 1].ms
          : (durationSec * 1000).round();
      // 至少显示 0.8 秒,防止过快闪没
      var e = endMs;
      if (e <= s.ms) e = s.ms + 800;
      sb.writeln(
        'Dialogue: 0,${_assTime(s.ms / 1000)},${_assTime(e / 1000)},HR,,0,0,0,,'
        '♥ ${s.bpm}',
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

  /// 渲染"最近10秒滑动窗口"心率曲线帧。
  /// 窗口右端 = nowMs,横轴为最近 10 秒;纵轴固定为 [cur-30, cur+10](cur=当前心率);
  /// 曲线区带边框,框内左上/左下标注上下限(cur+10 / cur-30),
  /// 曲线右端红点,右侧窄列用缩小字号显示当前心率。
  Future<ui.Image> _renderCurveFrame(
    int w,
    int h,
    int nowMs, {
    required double curBpm,
  }) async {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    const winMs = 10000; // 10 秒窗口

    // 有效采样
    final pts = _samples.where((s) => s.bpm > 0).toList();
    // 该帧取 [nowMs-10s, nowMs] 内的点
    final inWin = pts
        .where((s) => s.ms <= nowMs && s.ms >= nowMs - winMs)
        .toList();
    // 纵轴中心 = 该帧当前心率
    final cur = curBpm <= 0
        ? (pts.isEmpty ? 90.0 : pts.last.bpm.toDouble())
        : curBpm;

    // 半透明黑圆角底
    final bg = Paint()..color = const Color(0x99000000);
    final outer = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      const Radius.circular(6),
    );
    canvas.drawRRect(outer, bg);
    // 边框(白色细线)
    final border = Paint()
      ..color = const Color(0xCCFFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawRRect(outer, border);

    // 纵轴范围:上 cur+10,下 cur-30
    var topV = cur + 10;
    var botV = cur - 30;
    if (botV < 0) botV = 0;
    if (topV - botV < 10) topV = botV + 10;
    final rangeV = topV - botV;

    // 右侧留一窄列给当前心率数字
    final labelW = (w * 0.24).clamp(18.0, 90.0).toDouble();
    final plotR = (w - labelW - 1).toDouble(); // 曲线绘图右边界
    final pad = 3.0;

    double px(int ms) =>
        (pad + (ms - (nowMs - winMs)) / winMs * (plotR - pad * 2))
            .clamp(pad, plotR)
            .toDouble();
    double py(double bpm) => ((h - pad) - (bpm - botV) / rangeV * (h - pad * 2))
        .clamp(pad, h - pad)
        .toDouble();

    // ── 上下限标注(小字,叠在绘图区上/下沿)──
    double labelFont = (h * 0.24).clamp(7.0, 22.0).toDouble();
    void drawLabel(String s, double x, double y, {bool top = true}) {
      final tp = TextPainter(
        text: TextSpan(
          text: s,
          style: TextStyle(
            color: const Color(0xCCFFFFFF),
            fontSize: labelFont,
            fontWeight: FontWeight.w600,
            shadows: const [Shadow(color: Colors.black, blurRadius: 1.5)],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x, y));
    }

    // 上限值画在绘图区左上角,下限值画在左下角(绘图区内,不与曲线打架时用对角)
    drawLabel(topV.round().toString(), pad, 1.5);
    final botTxt = botV.round().toString();
    final botTP = TextPainter(
      text: TextSpan(
        text: botTxt,
        style: TextStyle(
          color: const Color(0xCCFFFFFF),
          fontSize: labelFont,
          fontWeight: FontWeight.w600,
          shadows: const [Shadow(color: Colors.black, blurRadius: 1.5)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    botTP.paint(canvas, Offset(pad, h - botTP.height - 1));

    if (inWin.length >= 2) {
      Paint line(Color c, double width) => Paint()
        ..color = c
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final p = Path();
      for (var i = 0; i < inWin.length; i++) {
        final x = px(inWin[i].ms);
        final y = py(inWin[i].bpm.toDouble());
        if (i == 0) {
          p.moveTo(x, y);
        } else {
          p.lineTo(x, y);
        }
      }
      canvas.drawPath(p, line(Colors.black, 3.2));
      canvas.drawPath(p, line(const Color(0xFFFF3B30), 1.8));
    }

    // ── 末端红点(绘图区右边界)+ 右侧窄列:当前心率(缩小字号)──
    if (inWin.isNotEmpty) {
      final last = inWin.last;
      final lx = px(last.ms);
      final ly = py(last.bpm.toDouble());
      canvas.drawCircle(
        Offset(lx, ly),
        (w * 0.016).clamp(1.4, 3.2),
        Paint()..color = const Color(0xFFFF3B30),
      );

      final fs = (h * 0.34).clamp(7.0, 26.0).toDouble(); // 缩小后的字号
      final txt = TextPainter(
        text: TextSpan(
          text: last.bpm.toString(),
          style: TextStyle(
            color: const Color(0xFFFF3B30),
            fontSize: fs,
            fontWeight: FontWeight.bold,
            shadows: const [Shadow(color: Colors.black, blurRadius: 2)],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      // 数字固定在右侧窄列,垂直居中于红点高度
      final tx = (w - labelW + (labelW - txt.width) / 2)
          .clamp(plotR + 1.0, w - txt.width - 1.0)
          .toDouble();
      final ty = (ly - txt.height / 2).clamp(0.0, (h - txt.height).toDouble());
      txt.paint(canvas, Offset(tx, ty));
    }

    final pic = rec.endRecording();
    return pic.toImage(w, h);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cam = _cam;
    final bpmNow = widget.ble.currentBpm;
    // 是否横屏(UI 元素随方向重新摆放)
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    // 上边距:避开状态栏/刘海
    final topPad = MediaQuery.of(context).padding.top + 12;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── 相机预览:保持相机原始比例居中,不拉伸 ──
          if (cam != null && cam.value.isInitialized)
            Positioned.fill(
              child: Center(
                child: AspectRatio(
                  aspectRatio: cam.value.aspectRatio,
                  child: CameraPreview(cam),
                ),
              ),
            )
          else
            const Center(child: CircularProgressIndicator()),

          // ── 顶部控制排 ──
          Positioned(
            top: topPad,
            left: isLandscape ? 24 : 16,
            right: isLandscape ? 24 : 16,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 左侧:镜头 + 设置按钮(纯黑圆底)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    IconButton(
                      onPressed: (_recording || _busy) ? null : _showLensSheet,
                      icon: const Icon(
                        Icons.camera_alt,
                        color: Colors.white,
                        size: 26,
                      ),
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black,
                        disabledBackgroundColor: Colors.black26,
                      ),
                    ),
                    IconButton(
                      onPressed: (_recording || _busy)
                          ? null
                          : _showSettingsSheet,
                      icon: const Icon(
                        Icons.settings,
                        color: Colors.white,
                        size: 22,
                      ),
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black,
                        disabledBackgroundColor: Colors.black26,
                      ),
                    ),
                    // 当前等效焦距 + 画质/帧率
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${(_zoom * 26).round()}mm',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                              backgroundColor: Colors.black,
                            ),
                          ),
                          Text(
                            '$_qualityLabel  $_fps fps',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                              backgroundColor: Colors.black,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                // 右侧:未连接(或本段无心率)→蓝牙按钮;已连接→实时心率胶囊
                if (!(_recording ? _recordHadBle : widget.ble.isConnected) ||
                    !widget.ble.isConnected)
                  IconButton(
                    onPressed: _showBleSheet,
                    icon: const Icon(
                      Icons.bluetooth_disabled,
                      color: Colors.white,
                      size: 24,
                    ),
                    style: IconButton.styleFrom(backgroundColor: Colors.black),
                  )
                else
                  StreamBuilder<int>(
                    stream: widget.ble.bpmStream,
                    initialData: bpmNow,
                    builder: (context, snap) {
                      final bpm = snap.data ?? 0;
                      return GestureDetector(
                        onTap: _showBleSheet,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: Colors.white12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.favorite,
                                color: Colors.red,
                                size: 22,
                              ),
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
              ],
            ),
          ),

          // 状态/错误提示(顶部控制排下方)
          if (_hint.isNotEmpty)
            Positioned(
              top: topPad + (isLandscape ? 66 : 92),
              left: 20,
              right: 20,
              child: Text(
                _hint,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.yellowAccent,
                  fontSize: 12,
                  backgroundColor: Colors.black45,
                ),
              ),
            ),

          // ── 实时心率曲线(仅本段有心率数据时显示)──
          if (_recording &&
              _recordHadBle &&
              widget.ble.isConnected &&
              _history.length >= 2)
            Positioned(
              left: isLandscape ? 90 : 12,
              right: isLandscape ? 90 : 12,
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

          // ── 录像按钮(底部中央)──
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

  /// 当前画质档位的中文名(供顶栏显示)
  String get _qualityLabel {
    for (final q in _qualityOptions) {
      if (q.$1 == _quality) return q.$2;
    }
    return '高清';
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
