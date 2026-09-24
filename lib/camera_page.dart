import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import 'ble_heart_rate.dart';
import 'gyro_test_page.dart';
import 'stabilizer.dart';

/// 一次心率采样:相对录像开始的时间(毫秒)+ 心率值
class _HrSample {
  final int ms;
  final int bpm;
  _HrSample(this.ms, this.bpm);
}

/// 导出(渲染)任务进度
class RenderJob extends ChangeNotifier {
  double _progress = 0;
  String _stage = '准备中…';
  double? _etaSec;
  bool _done = false;
  String? _error;

  double get progress => _progress;
  String get stage => _stage;
  double? get etaSec => _etaSec;
  bool get done => _done;
  String? get error => _error;

  set progress(double v) {
    _progress = v.clamp(0.0, 1.0);
    notifyListeners();
  }

  set stage(String v) {
    _stage = v;
    notifyListeners();
  }

  set etaSec(double? v) {
    _etaSec = v;
    notifyListeners();
  }

  set done(bool v) {
    _done = v;
    notifyListeners();
  }

  set error(String? v) {
    _error = v;
    notifyListeners();
  }
}

/// 已导出的作品(保存在应用"录像"目录)
class ExportItem {
  final String path;
  final DateTime time;
  final int sizeBytes;

  ExportItem({required this.path, required this.time, required this.sizeBytes});

  String get displayName {
    final t = time;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  String get sizeText {
    final mb = sizeBytes / 1024 / 1024;
    return mb >= 1
        ? '${mb.toStringAsFixed(1)} MB'
        : '${(sizeBytes / 1024).toStringAsFixed(0)} KB';
  }
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
  // 默认 超清(≈1080p)/60fps
  ResolutionPreset _quality = ResolutionPreset.veryHigh;
  int _fps = 60; // 默认 60 帧

  // 手环连接面板状态
  bool _connecting = false;
  bool _scanning = false;
  bool _showAllDevices = false; // 是否展示全部设备(含非穿戴设备)
  String _bleStatus = '未连接';

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
  // 本段录像是否为竖屏(竖屏则成片需旋转为竖向)
  bool _recordPortrait = true;

  // ── 导出/渲染状态 ──
  RenderJob? _job; // 当前渲染任务(用于进度弹窗与后台进度条)
  bool _renderBackground = false; // 用户是否选择"后台渲染"
  bool _renderDialogOpen = false; // 进度弹窗是否打开
  final List<ExportItem> _exports = []; // 已导出作品

  // ── 运动稳定(陀螺仪防抖,Gyroflow 式算法)──
  bool _stabilizeEnabled = false; // 开关(在弹窗里控制)
  bool _stabRunning = false; // 是否已点"开始稳定"
  final OnlineStabilizer _onlineStab = OnlineStabilizer();
  double _stabOffsetX = 0; // 画面横向补偿(像素,预览坐标)
  double _stabOffsetY = 0; // 画面纵向补偿(像素,预览坐标)
  double _stabAutoZoom = 1.0; // 自适应缩放(保证裁切不出画面)
  double _stabStrength = 1.0; // 稳定强度(0.5 柔和 / 1.0 标准 / 1.6 强)
  final double _stabFov = 66; // 估算视场角(度),用于焦距换算
  double _stabCorrDeg = 0; // 当前角修正(度,仅显示用)
  final List<List<double>> _stabLog = []; // 陀螺仪数据 [t(epoch秒), gx, gy, gz]
  DateTime _stabLast = DateTime.now();
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  // 诊断:确认陀螺仪是否真的有数据
  double _gxNow = 0;
  int _gyroCount = 0;
  double _gyroHz = 0;
  DateTime _gyroHzWin = DateTime.now();
  int _gyroHzSamples = 0;
  // 弹窗内实时数据显示用的轻量通知器(不依赖页面 setState)
  final ValueNotifier<int> _stabTick = ValueNotifier<int>(0);
  double _recordStartEpochSec = 0; // 本段录像开始时刻(用于切分陀螺仪数据)
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _zoomAtGestureStart = 1.0;
  Size _previewSize = Size.zero; // 当前预览显示区尺寸(用于计算可移动余量)

  @override
  void initState() {
    super.initState();
    _initCamera();
    _loadExports(); // 启动时载入已有作品
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

    // 候选组合:当前设置 → 降帧率 → 降画质(逐级尝试,直到初始化成功)
    final attempts = <(ResolutionPreset, int)>[
      (_quality, _fps),
      (_quality, 30),
      if (_quality != ResolutionPreset.high)
        (ResolutionPreset.high, 30)
      else
        (ResolutionPreset.medium, 30),
      (ResolutionPreset.medium, 30),
    ];

    CameraController? okCam;
    (ResolutionPreset, int)? used;
    String? lastErr;
    for (final a in attempts) {
      final cand = CameraController(desc, a.$1, enableAudio: true, fps: a.$2);
      try {
        await cand.initialize();
        okCam = cand;
        used = a;
        break;
      } catch (e) {
        lastErr = '$e';
        await cand.dispose().catchError((_) {});
      }
    }

    if (okCam == null) {
      if (mounted) {
        setState(() => _hint = '相机初始化失败: $lastErr');
      }
      return;
    }
    if (!mounted) {
      await okCam.dispose();
      return;
    }
    final (rPreset, rFps) = used!;
    // 若发生降级,提示并把状态同步为实际值
    final degraded = (rPreset != _quality) || (rFps != _fps);
    _quality = rPreset;
    _fps = rFps;
    setState(() {
      _cam = okCam;
      _camIndex = index;
      _zoom = 1.0; // 切换镜头后变焦回到 1x
      if (degraded) {
        _hint = '设备不支持所选画质,已自动调整为 $_qualityLabel/$rFps fps';
      }
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
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
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
                      const SizedBox(height: 14),
                      const Text(
                        '连接心率设备',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        '支持所有开启心率广播的设备:手环 / 手表 / 心率带(标准 0x180D)',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      const SizedBox(height: 16),

                      if (connected) ...[
                        // ── 已连接:状态与大号心率 ──
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
                                  const Icon(
                                    Icons.favorite,
                                    color: Colors.redAccent,
                                    size: 26,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      widget.ble.connectedName.isEmpty
                                          ? '已连接'
                                          : '已连接 · ${widget.ble.connectedName}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Text(
                                '${widget.ble.currentBpm}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 56,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const Text(
                                'bpm',
                                style: TextStyle(
                                  color: Colors.white54,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Spacer(),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white70,
                              side: const BorderSide(color: Colors.white24),
                            ),
                            onPressed: () async {
                              await widget.ble.disconnect();
                              if (mounted) {
                                setState(() {
                                  _bleStatus = '未连接';
                                  _history.clear();
                                  _samples.clear();
                                });
                              }
                              setSheetState(() {});
                            },
                            icon: const Icon(Icons.link_off),
                            label: const Text('断开连接'),
                          ),
                        ),
                      ] else ...[
                        // ── 未连接:扫描 + 设备列表 ──
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: Colors.redAccent,
                            ),
                            onPressed: _scanning
                                ? null
                                : () => _startScan(setSheetState),
                            icon: const Icon(Icons.bluetooth_searching),
                            label: Text(_scanning ? '扫描中…' : '扫描设备'),
                          ),
                        ),
                        const SizedBox(height: 10),
                        if (_bleStatus.isNotEmpty)
                          Text(
                            _bleStatus,
                            style: const TextStyle(
                              color: Colors.yellowAccent,
                              fontSize: 12,
                            ),
                          ),
                        const SizedBox(height: 6),
                        Expanded(
                          child: StreamBuilder<List<BleDeviceInfo>>(
                            stream: widget.ble.deviceList,
                            initialData: widget.ble.devicesNow,
                            builder: (context3, snap) {
                              final all = snap.data ?? const <BleDeviceInfo>[];
                              // 默认只显示"穿戴设备/明确广播心率"的设备,其余折叠
                              final shown = _showAllDevices
                                  ? all
                                  : all.where((d) => d.showByDefault).toList();
                              final hiddenCount = all.length - shown.length;

                              Widget toggle() {
                                if (!_showAllDevices && hiddenCount == 0) {
                                  return const SizedBox.shrink();
                                }
                                return TextButton.icon(
                                  onPressed: () => setSheetState(
                                    () => _showAllDevices = !_showAllDevices,
                                  ),
                                  icon: Icon(
                                    _showAllDevices
                                        ? Icons.expand_less
                                        : Icons.expand_more,
                                    size: 18,
                                    color: Colors.white54,
                                  ),
                                  label: Text(
                                    _showAllDevices
                                        ? '收起其他设备'
                                        : '显示全部设备(+$hiddenCount)',
                                    style: const TextStyle(
                                      color: Colors.white54,
                                      fontSize: 12,
                                    ),
                                  ),
                                );
                              }

                              if (shown.isEmpty) {
                                return Column(
                                  children: [
                                    Expanded(
                                      child: Center(
                                        child: Text(
                                          _scanning
                                              ? '正在搜索附近设备…'
                                              : (all.isEmpty
                                                    ? '点上方"扫描设备"开始搜索'
                                                    : '未发现穿戴设备,\n可展开查看全部 ${all.length} 个设备'),
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            color: Colors.white38,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                                    ),
                                    toggle(),
                                  ],
                                );
                              }

                              return Column(
                                children: [
                                  Expanded(
                                    child: ListView.separated(
                                      itemCount: shown.length,
                                      separatorBuilder: (_, _) => const Divider(
                                        height: 1,
                                        color: Colors.white12,
                                      ),
                                      itemBuilder: (context4, i) {
                                        final d = shown[i];
                                        return ListTile(
                                          contentPadding: EdgeInsets.zero,
                                          leading: Icon(
                                            d.advertisesHeartRate
                                                ? Icons.favorite
                                                : Icons.bluetooth,
                                            color: d.advertisesHeartRate
                                                ? Colors.redAccent
                                                : Colors.white38,
                                          ),
                                          title: Text(
                                            d.displayName,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 15,
                                            ),
                                          ),
                                          subtitle: Text(
                                            d.advertisesHeartRate
                                                ? '支持心率广播 · 信号 ${d.rssi} dBm'
                                                : '信号 ${d.rssi} dBm',
                                            style: TextStyle(
                                              color: d.advertisesHeartRate
                                                  ? Colors.redAccent
                                                  : Colors.white38,
                                              fontSize: 11,
                                            ),
                                          ),
                                          trailing: _connecting
                                              ? const SizedBox(
                                                  width: 16,
                                                  height: 16,
                                                  child:
                                                      CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                      ),
                                                )
                                              : const Icon(
                                                  Icons.chevron_right,
                                                  color: Colors.white38,
                                                ),
                                          onTap: () => _connectDevice(
                                            d.remoteId,
                                            setSheetState,
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                  toggle(),
                                ],
                              );
                            },
                          ),
                        ),
                      ],
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

  /// 扫描附近可连接设备
  Future<void> _startScan(StateSetter setSheetState) async {
    // Android:扫描 BLE 需要定位权限
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final loc = await Permission.locationWhenInUse.request();
        if (!loc.isGranted) {
          if (mounted) setState(() => _bleStatus = '需要定位权限才能扫描设备');
          if (mounted) setSheetState(() {});
          return;
        }
      } catch (_) {}
    }
    setState(() {
      _scanning = true;
      _showAllDevices = false; // 每次重新扫描先折叠非穿戴设备
      _bleStatus = '正在搜索附近设备…';
    });
    if (mounted) setSheetState(() {});
    try {
      await widget.ble.scan();
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _bleStatus = widget.ble.devicesNow.isEmpty
            ? '未发现设备,请确认设备已开启心率广播并靠近手机'
            : '发现 ${widget.ble.devicesNow.length} 个设备,点击即可连接';
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _scanning = false;
          _bleStatus = '扫描失败: $e';
        });
      }
    }
    if (mounted) setSheetState(() {});
  }

  /// 连接所选设备并订阅心率
  Future<void> _connectDevice(
    String remoteId,
    StateSetter setSheetState,
  ) async {
    setState(() {
      _connecting = true;
      _bleStatus = '正在连接…';
    });
    if (mounted) setSheetState(() {});
    try {
      await widget.ble.connectTo(remoteId);
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _bleStatus = '已连接';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _bleStatus = '连接失败:${e.toString().replaceAll('Exception: ', '')}';
      });
    }
    if (mounted) setSheetState(() {});
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
                      backgroundColor: Colors.black,
                      side: BorderSide(
                        color: sel ? Colors.white : Colors.white24,
                      ),
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
                        ? Colors.black26
                        : (active ? Colors.redAccent : Colors.black);
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
                          border: Border.all(
                            color: active ? Colors.redAccent : Colors.white24,
                          ),
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
                          backgroundColor: Colors.black,
                          side: BorderSide(
                            color: sel ? Colors.redAccent : Colors.white24,
                          ),
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
                          backgroundColor: Colors.black,
                          side: BorderSide(
                            color: sel ? Colors.redAccent : Colors.white24,
                          ),
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
    // 相机未就绪(如刚渲染完、恢复失败):先尝试恢复,不要静默无反应
    if (cam == null || !cam.value.isInitialized) {
      if (_busy) return;
      if (mounted) setState(() => _hint = '相机未就绪,正在恢复…');
      await _restoreCamera();
      return;
    }
    if (_busy) return;
    // 在 await 之前取当前方向(避免跨 async 使用 context)
    final isPortraitNow =
        MediaQuery.of(context).orientation == Orientation.portrait;
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
        // 记录本段录制方向:竖屏则成片需要旋转为竖向
        _recordPortrait = isPortraitNow;
        // 记录本段开始时刻(用于切分陀螺仪数据)
        _recordStartEpochSec = DateTime.now().millisecondsSinceEpoch / 1000.0;
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
        // 快照本段数据:后台渲染期间可以继续拍摄,不能被下一段覆盖
        final samplesSnapshot = List<_HrSample>.from(_samples);
        final hadBleSnapshot = _recordHadBle;
        final fallbackDuration = _timer.elapsedMilliseconds / 1000.0;
        // 运动稳定:快照本段陀螺仪原始数据(导出时用 Gyroflow 式算法分析)
        final stabOn = _stabilizeEnabled && _stabRunning;
        final stabGyro = stabOn
            ? List<List<double>>.from(_stabLog)
            : <List<double>>[];
        // 不等待导出结束:否则 _busy 会一直占用,导致无法继续拍摄
        unawaited(
          _startExport(
            raw: file,
            samples: samplesSnapshot,
            hadBle: hadBleSnapshot,
            fallbackDuration: fallbackDuration,
            stabGyro: stabGyro,
            stabStartEpoch: _recordStartEpochSec,
            stabEndEpoch: DateTime.now().millisecondsSinceEpoch / 1000.0,
            stabStrength: _stabStrength,
            stabFov: _stabFov,
          ),
        );
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

  // ─────────────── 导出流程:进度弹窗 + 后台渲染 ───────────────

  /// 开始导出:关闭摄像头 → 弹进度窗 → 渲染(可转后台继续拍摄)
  Future<void> _startExport({
    required XFile raw,
    required List<_HrSample> samples,
    required bool hadBle,
    required double fallbackDuration,
    List<List<double>> stabGyro = const [],
    double stabStartEpoch = 0,
    double stabEndEpoch = 0,
    double stabStrength = 1.0,
    double stabFov = 66,
  }) async {
    final job = RenderJob();
    setState(() {
      _job = job;
      _renderBackground = false;
    });

    // 关闭摄像头(渲染期间不用相机,省电降温)
    await _releaseCamera();

    // 弹出进度窗(不等待,渲染并行进行)
    _renderDialogOpen = true;
    unawaited(_showRenderDialog(job));

    try {
      await _renderVideo(
        raw: raw,
        samples: samples,
        hadBle: hadBle,
        fallbackDuration: fallbackDuration,
        job: job,
        stabGyro: stabGyro,
        stabStartEpoch: stabStartEpoch,
        stabEndEpoch: stabEndEpoch,
        stabStrength: stabStrength,
        stabFov: stabFov,
      );
      job
        ..progress = 1.0
        ..stage = '完成'
        ..etaSec = null
        ..done = true;
      await _loadExports();
      if (mounted) {
        setState(() => _hint = '导出完成,可点顶部文件夹按钮查看并保存');
      }
    } catch (e) {
      job
        ..stage = '失败'
        ..error = '$e'
        ..done = true;
      if (mounted) setState(() => _hint = '导出失败: $e');
    } finally {
      _popRenderDialog();
      await _restoreCamera();
      if (mounted) setState(() {});
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted && identical(_job, job)) setState(() => _job = null);
      });
    }
  }

  /// 渲染进度弹窗(含进度条与预计剩余时间,可切后台渲染)
  Future<void> _showRenderDialog(RenderJob job) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      // 允许点弹窗外关闭,避免遮罩卡住导致整个界面点不动
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        title: const Text(
          '正在导出视频',
          style: TextStyle(color: Colors.white, fontSize: 18),
        ),
        content: ListenableBuilder(
          listenable: job,
          builder: (context2, _) {
            final pct = (job.progress * 100).round();
            final etaText = job.error != null
                ? '失败:${job.error}'
                : job.done
                ? '已完成'
                : (job.etaSec != null && job.etaSec! > 0
                      ? '预计剩余约 ${_fmtDuration(job.etaSec!.round())}'
                      : '正在估算剩余时间…');
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: job.progress,
                    minHeight: 8,
                    backgroundColor: Colors.white12,
                    valueColor: const AlwaysStoppedAnimation(Colors.redAccent),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '$pct%  ${job.stage}',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 4),
                Text(
                  etaText,
                  style: TextStyle(
                    color: job.error != null
                        ? Colors.yellowAccent
                        : Colors.white38,
                    fontSize: 12,
                  ),
                ),
              ],
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () {
              // 后台渲染:关弹窗 + 恢复摄像头,渲染继续在后台进行
              setState(() => _renderBackground = true);
              _popRenderDialog();
              _restoreCamera();
            },
            child: const Text(
              '后台渲染(返回拍摄)',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    _renderDialogOpen = false;
    // 若是用户点了弹窗外部关闭(渲染还没结束),自动转为后台渲染并恢复相机,
    // 避免出现"界面像卡住、按钮点不动"的观感
    if (!job.done && !_renderBackground) {
      if (mounted) {
        setState(() => _renderBackground = true);
      }
      _restoreCamera();
    }
  }

  void _popRenderDialog() {
    if (!_renderDialogOpen) return;
    _renderDialogOpen = false;
    try {
      final nav = Navigator.of(context, rootNavigator: true);
      if (nav.canPop()) nav.pop();
    } catch (_) {}
  }

  /// 点击后台进度条时重新打开进度窗
  void _reopenRenderDialog() {
    final job = _job;
    if (job == null || _renderDialogOpen) return;
    _renderBackground = false;
    _renderDialogOpen = true;
    // 正在录像时不释放摄像头,避免打断当前拍摄
    if (!_recording) _releaseCamera();
    unawaited(_showRenderDialog(job));
  }

  Future<void> _releaseCamera() async {
    final c = _cam;
    _cam = null;
    if (mounted) setState(() {});
    try {
      await c?.dispose();
    } catch (_) {}
  }

  Future<void> _restoreCamera() async {
    if (_cam != null || _cameras.isEmpty) return;
    if (mounted) setState(() => _hint = '正在恢复相机预览…');
    try {
      await _openCamera(_camIndex);
      if (mounted) setState(() => _hint = '');
    } catch (e) {
      if (mounted) setState(() => _hint = '相机恢复失败,请重启应用: $e');
    }
  }

  String _fmtDuration(int sec) {
    if (sec < 60) return '$sec 秒';
    return '${sec ~/ 60} 分 ${sec % 60} 秒';
  }

  /// 实际渲染:无心率直接保存原视频;有心率则烧字幕 + 曲线
  Future<void> _renderVideo({
    required XFile raw,
    required List<_HrSample> samples,
    required bool hadBle,
    required double fallbackDuration,
    required RenderJob job,
    List<List<double>> stabGyro = const [],
    double stabStartEpoch = 0,
    double stabEndEpoch = 0,
    double stabStrength = 1.0,
    double stabFov = 66,
  }) async {
    final docs = await getApplicationDocumentsDirectory();
    final folder = Directory('${docs.path}/录像');
    if (!folder.existsSync()) folder.createSync(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final saved = '${folder.path}/$stamp.mp4';

    // 本段开始时未连接手环 → 直接保存原视频(不烧任何心率 UI)
    if (!hadBle) {
      job
        ..stage = '保存视频…'
        ..progress = 0.5;
      await raw.saveTo(saved);
      job.progress = 1.0;
      return;
    }

    // 1) 解析原视频尺寸与时长(字幕坐标需要像素尺寸)
    job
      ..stage = '读取视频信息…'
      ..progress = 0.02;
    final info = await FFprobeKit.getMediaInformation(raw.path);
    final mi = info.getMediaInformation();
    if (mi == null) throw Exception('无法读取视频信息');
    int width = 1920, height = 1080;
    for (final s in mi.getStreams()) {
      if (s.getType() == 'video') {
        width = s.getWidth() ?? width;
        height = s.getHeight() ?? height;
      }
    }
    final durStr = mi.getDuration(); // 形如 "12.345"
    var durationSec = durStr != null ? double.tryParse(durStr) : null;
    if (durationSec == null || durationSec <= 0) {
      durationSec = fallbackDuration <= 0 ? 1.0 : fallbackDuration;
    }

    // 方向处理:竖屏录制但文件仍为横向(宽>高)时,成片旋转为竖向。
    // 旋转后宽高互换,后续字幕/曲线坐标一律按旋转后的尺寸计算。
    // transpose=1 顺时针90°;若方向相反改为 2(逆时针90°)。
    final bool needRotate = _recordPortrait && width > height;
    const int transposeMode = 1;
    if (needRotate) {
      final t = width;
      width = height;
      height = t;
    }
    final String vfPrefix = needRotate ? 'transpose=$transposeMode,' : '';

    // 2) 字幕 + 曲线参数
    final workDir = Directory('${docs.path}/work');
    if (!workDir.existsSync()) workDir.createSync(recursive: true);
    final assPath = '${workDir.path}/$stamp.ass';
    final hasCurve = samples.where((s) => s.bpm > 0).length >= 2;

    // 曲线区域尺寸:与心率文字一致(MarginR=30、MarginV=40、字号=高4.5%)
    final fontSize = (height * 0.045).round().clamp(24, 200);
    const marginRight = 30.0;
    const marginTop = 40.0;
    // 心率文字高度≈fontSize,曲线放其下方;加右侧数字列与上下限标注,略加高
    final curW = (fontSize * 3.0).round().clamp(80, 720);
    final curH = (fontSize * 1.35).round().clamp(32, 320);
    final curX = (width - marginRight - curW).round();
    final curY = (marginTop + fontSize * 1.12).round();

    _writeAss(assPath, width, height, durationSec, samples);
    String? seqDir;
    if (hasCurve && durationSec > 1) {
      job.stage = '生成心率曲线…';
      // 有效采样(升序时间)
      final pts = samples.where((s) => s.bpm > 0).toList();
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
        final img = await _renderCurveFrame(
          curW,
          curH,
          nowMs,
          curBpm: cur,
          samples: samples,
        );
        final data = await img.toByteData(format: ui.ImageByteFormat.png);
        final name = '${seq.path}/curve_${f.toString().padLeft(4, '0')}.png';
        File(name).writeAsBytesSync(data!.buffer.asUint8List());
        // 曲线阶段占总进度 0.05 ~ 0.40
        job.progress = 0.05 + 0.35 * (f + 1) / frameCount;
        job.etaSec = (frameCount - f - 1) * 0.08;
      }
    }

    // 2.5) 运动稳定(Gyroflow 式):四元数姿态积分 → 平滑虚拟相机路径
    //      → 双轴补偿曲线 + 自适应缩放 → 放大后按曲线移动裁切框。
    //      输出尺寸与原视频一致,因此字幕/曲线坐标无需改变。
    String stabPrefix = '';
    if (stabGyro.length >= 4 && stabEndEpoch > stabStartEpoch) {
      job.stage = '分析陀螺仪数据…';
      final plan = GyroStabilizer.analyze(
        samples: stabGyro,
        startEpoch: stabStartEpoch,
        endEpoch: stabEndEpoch,
        frameW: width.toDouble(),
        frameH: height.toDouble(),
        fovDeg: stabFov,
        strength: stabStrength,
      );
      if (plan.usable) {
        final zoom = plan.zoom;
        final scaledW = ((width * zoom) / 2).floor() * 2;
        final scaledH = ((height * zoom) / 2).floor() * 2;
        final baseX = (scaledW - width) / 2;
        final baseY = (scaledH - height) / 2;
        final exprX = GyroStabilizer.toCropExpr(plan.dx);
        final exprY = GyroStabilizer.toCropExpr(plan.dy);
        if (exprX != null && exprY != null) {
          stabPrefix =
              'scale=$scaledW:$scaledH,'
              'crop=$width:$height:'
              "'(${baseX.toStringAsFixed(1)}+$zoom*($exprX))':"
              "'(${baseY.toStringAsFixed(1)}+$zoom*($exprY))',";
        }
      }
    }

    // 3) FFmpeg 合成(进度由 statistics 回调上报)
    job
      ..stage = '合成中…'
      ..progress = 0.40;
    final outPath = '${workDir.path}/$stamp.mp4';

    String buildCmd(String stab) {
      if (seqDir != null) {
        // 输入0=原始视频(先旋转/稳定再烧字幕),输入1=曲线动画序列(1帧/秒)
        return '-y -i "${raw.path}" -framerate 1 -i "$seqDir/curve_%04d.png" '
            '-filter_complex '
            '"[0:v]$vfPrefix${stab}ass=$assPath[base];'
            '[1:v]scale=$curW:$curH,format=rgba,fps=30[ov];'
            '[base][ov]overlay=x=$curX:y=$curY:eof_action=repeat[outv]" '
            '-map "[outv]" -map 0:a? '
            '-c:v libx264 -preset veryfast -crf 22 '
            '-c:a aac -b:a 128k "$outPath"';
      }
      return '-y -i "${raw.path}" -vf "$vfPrefix${stab}ass=$assPath" '
          '-c:v libx264 -preset veryfast -crf 22 '
          '-c:a aac -b:a 128k "$outPath"';
    }

    var ok = await _runFfmpeg(buildCmd(stabPrefix), durationSec, job);
    if (!ok && stabPrefix.isNotEmpty) {
      // 稳定滤镜失败时自动回退(至少保证出片)
      job
        ..stage = '稳定处理失败,改为普通合成…'
        ..progress = 0.40;
      ok = await _runFfmpeg(buildCmd(''), durationSec, job);
      if (ok && mounted) {
        setState(() => _hint = '运动稳定未能应用,已导出普通视频');
      }
    }
    if (!ok) throw Exception('FFmpeg 合成失败');

    // 4) 保存到录像目录 + 清理临时文件
    job
      ..stage = '保存中…'
      ..progress = 0.99;
    await File(outPath).copy(saved);
    try {
      File(assPath).deleteSync();
      if (seqDir != null) {
        Directory(seqDir).deleteSync(recursive: true);
      }
      File(outPath).deleteSync();
      File(raw.path).deleteSync();
    } catch (_) {}
    job.progress = 1.0;
  }

  /// 执行 FFmpeg,并用 statistics 回调上报进度与速度(预计剩余时间)
  Future<bool> _runFfmpeg(String cmd, double durationSec, RenderJob job) async {
    final done = Completer<bool>();
    await FFmpegKit.executeAsync(
      cmd,
      (session) async {
        final rc = await session.getReturnCode();
        if (!done.isCompleted) done.complete(ReturnCode.isSuccess(rc));
      },
      null,
      (stats) {
        final tMs = stats.getTime();
        if (durationSec <= 0 || tMs <= 0) return;
        final p = (tMs / (durationSec * 1000)).clamp(0.0, 1.0);
        job.progress = 0.40 + 0.58 * p;
        job.stage = '合成中 ${(p * 100).round()}%';
        final speed = stats.getSpeed();
        if (speed > 0) {
          job.etaSec = ((durationSec * 1000 - tMs) / 1000) / speed;
        }
      },
    );
    return done.future;
  }

  // ─────────────── 作品(已导出视频)───────────────

  /// 载入录像目录中的作品列表
  Future<void> _loadExports() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final folder = Directory('${docs.path}/录像');
      if (!folder.existsSync()) return;
      final files = folder
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.mp4'))
          .toList();
      files.sort(
        (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
      );
      final items = files.take(100).map((f) {
        final stat = f.statSync();
        final name = f.uri.pathSegments.last;
        final ts = int.tryParse(name.split('.').first);
        return ExportItem(
          path: f.path,
          time: ts != null
              ? DateTime.fromMillisecondsSinceEpoch(ts)
              : stat.modified,
          sizeBytes: stat.size,
        );
      }).toList();
      if (!mounted) return;
      setState(() {
        _exports
          ..clear()
          ..addAll(items);
      });
    } catch (_) {}
  }

  /// 作品面板:列表 + 查看(应用内播放) + 保存
  Future<void> _showExportsSheet() async {
    await _loadExports();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 2 / 3,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
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
                const SizedBox(height: 14),
                Row(
                  children: [
                    const Icon(
                      Icons.video_library,
                      color: Colors.white,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      '作品',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${_exports.length} 个',
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: _exports.isEmpty
                      ? const Center(
                          child: Text(
                            '还没有导出的视频\n录像结束后会自动生成',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white38,
                              fontSize: 13,
                            ),
                          ),
                        )
                      : ListView.separated(
                          itemCount: _exports.length,
                          separatorBuilder: (_, _) =>
                              const Divider(height: 1, color: Colors.white12),
                          itemBuilder: (context2, i) {
                            final item = _exports[i];
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(
                                Icons.movie,
                                color: Colors.white70,
                              ),
                              title: Text(
                                item.displayName,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                ),
                              ),
                              subtitle: Text(
                                item.sizeText,
                                style: const TextStyle(
                                  color: Colors.white38,
                                  fontSize: 11,
                                ),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: '查看',
                                    onPressed: () => _playExport(item),
                                    icon: const Icon(
                                      Icons.play_circle_outline,
                                      color: Colors.white,
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: '保存',
                                    onPressed: () => _saveExport(item),
                                    icon: const Icon(
                                      Icons.ios_share,
                                      color: Colors.redAccent,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 打开陀螺仪测试页
  Future<void> _openGyroTest() async {
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const GyroTestPage()));
  }

  // ─────────────── 运动稳定(陀螺仪补偿)───────────────

  /// 读取当前镜头可用变焦范围
  Future<void> _loadZoomRange() async {
    final cam = _cam;
    if (cam == null || !cam.value.isInitialized) return;
    try {
      _minZoom = await cam.getMinZoomLevel();
      _maxZoom = await cam.getMaxZoomLevel();
    } catch (_) {}
  }

  /// 切到最广视角(有超广角时为 0.5x,否则为该镜头最小变焦)
  Future<void> _switchToWidest() async {
    final cam = _cam;
    if (cam == null) return;
    try {
      await cam.setZoomLevel(_minZoom);
      if (mounted) setState(() => _zoom = _minZoom);
    } catch (_) {}
  }

  /// 订阅陀螺仪:持续统计(诊断),运行中积分并换算为画面位移
  void _startGyroSession() {
    _gyroSub?.cancel();
    _stabLast = DateTime.now();
    _gyroHzWin = DateTime.now();
    _gyroHzSamples = 0;
    _gyroSub = gyroscopeEventStream(samplingPeriod: SensorInterval.gameInterval)
        .listen((e) {
          final now = DateTime.now();
          final dt = now.difference(_stabLast).inMicroseconds / 1e6;
          _stabLast = now;

          // 诊断:无条件统计,即使未开始稳定也能确认是否有数据
          _gyroCount++;
          _gyroHzSamples++;
          _gxNow = e.x;
          final winMs = now.difference(_gyroHzWin).inMilliseconds;
          if (winMs >= 500) {
            _gyroHz = _gyroHzSamples * 1000 / winMs;
            _gyroHzSamples = 0;
            _gyroHzWin = now;
          }

          if (dt <= 0 || dt > 0.2) return;

          // 记录陀螺仪数据[t(epoch秒), gx, gy, gz]
          _stabLog.add([now.millisecondsSinceEpoch / 1000.0, e.x, e.y, e.z]);
          if (_stabLog.length > 60000) _stabLog.removeAt(0);

          if (!_stabRunning) return;

          // 四元数姿态积分 + EMA 平滑虚拟相机路径 → 角修正(Gyroflow 式)
          _onlineStab.update(dt, e.x, e.y, e.z);

          // 角修正 → 像素位移(按焦距换算),并给出自适应缩放
          final fov = _stabFov;
          final wPx = _previewSize.width <= 0 ? 1080.0 : _previewSize.width;
          final hPx = _previewSize.height <= 0 ? 1920.0 : _previewSize.height;
          final shifts = _onlineStab.shifts(wPx, fov, _stabStrength);
          _stabOffsetX = shifts[0];
          _stabOffsetY = shifts[1];
          _stabCorrDeg = _onlineStab.corrX * 180 / math.pi;
          _stabAutoZoom = _onlineStab.adaptiveZoom(
            wPx,
            hPx,
            fov,
            _stabStrength,
          );

          if (mounted) {
            setState(() {});
            _stabTick.value++;
          }
        }, onError: (_) {});
  }

  void _stopGyroSession() {
    _gyroSub?.cancel();
    _gyroSub = null;
  }

  /// 运动稳定弹窗(开关 + 陀螺仪测试 + 开始稳定)
  Future<void> _showStabilizeSheet() async {
    await _loadZoomRange();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (context2, setSheetState) {
          final zoomText = _zoom <= 1.001
              ? '1.0x'
              : '${_zoom.toStringAsFixed(1)}x';
          final hasWide = _minZoom < 0.999;
          final bottomInset = MediaQuery.of(context2).padding.bottom;

          // 录制中不允许改稳定:给明确提示,而不是点了没反应
          void lockedHint() {
            if (mounted) setState(() => _hint = '录制中无法调整运动稳定,请先停止录像');
            ScaffoldMessenger.of(context2).showSnackBar(
              const SnackBar(
                content: Text('录制中无法调整运动稳定,请先停止录像'),
                duration: Duration(seconds: 2),
              ),
            );
          }

          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context2).size.height * 0.88,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                  const Text(
                    '运动稳定',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '用陀螺仪补偿手抖:先用超广角并把画面放大留出余量,再开始稳定',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _stabilizeEnabled,
                    activeThumbColor: Colors.redAccent,
                    title: const Text(
                      '运动稳定',
                      style: TextStyle(color: Colors.white, fontSize: 15),
                    ),
                    subtitle: Text(
                      _stabilizeEnabled ? '已开启 · 可双指缩放画面' : '关闭',
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 12,
                      ),
                    ),
                    onChanged: (v) {
                      // 先同步更新 UI,再去做异步的变焦查询:避免开关看起来"点不动"
                      setState(() {
                        _stabilizeEnabled = v;
                        if (!v) {
                          _stabRunning = false;
                          _stabOffsetY = 0;
                          _stabOffsetX = 0;
                        }
                      });
                      if (v) {
                        _startGyroSession();
                        unawaited(
                          _loadZoomRange().then((_) {
                            if (mounted) setSheetState(() {});
                          }),
                        );
                      } else {
                        _stopGyroSession();
                      }
                      setSheetState(() {});
                    },
                  ),
                  const Divider(color: Colors.white12, height: 1),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(
                      Icons.screen_rotation,
                      color: Colors.white70,
                    ),
                    title: const Text(
                      '陀螺仪测试',
                      style: TextStyle(color: Colors.white, fontSize: 15),
                    ),
                    subtitle: const Text(
                      '立方体随陀螺仪旋转,显示 XYZ 数据',
                      style: TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                    trailing: const Icon(
                      Icons.chevron_right,
                      color: Colors.white38,
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      _openGyroTest();
                    },
                  ),
                  if (_stabilizeEnabled) ...[
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white10,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '当前变焦 $zoomText'
                            '${hasWide ? '(支持超广角)' : '(镜头最小变焦)'}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            '① 切到最广 → ② 点开始稳定(缩放会自适应,可双指微调) → ③ 正常拍摄',
                            style: TextStyle(
                              color: Colors.white38,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        const Text(
                          '稳定强度',
                          style: TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                        const SizedBox(width: 10),
                        ...[(0.6, '柔和'), (1.0, '标准'), (1.6, '强')].map((o) {
                          final sel = (_stabStrength - o.$1).abs() < 0.01;
                          return Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ChoiceChip(
                              label: Text(
                                o.$2,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: sel ? Colors.black : Colors.white,
                                ),
                              ),
                              selected: sel,
                              selectedColor: Colors.redAccent,
                              backgroundColor: Colors.black,
                              side: BorderSide(
                                color: sel ? Colors.redAccent : Colors.white24,
                              ),
                              onSelected: (_) =>
                                  setSheetState(() => _stabStrength = o.$1),
                            ),
                          );
                        }),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white70,
                          side: const BorderSide(color: Colors.white24),
                        ),
                        onPressed: () async {
                          if (_recording) {
                            lockedHint();
                            return;
                          }
                          await _switchToWidest();
                          setSheetState(() {});
                        },
                        icon: const Icon(Icons.zoom_out_map, size: 18),
                        label: Text('切到最广 ${_minZoom.toStringAsFixed(1)}x'),
                      ),
                    ),
                  ] else ...[
                    const SizedBox(height: 12),
                    const Text(
                      '开启后可:双指缩放画面留出余量、实时记录陀螺仪并补偿画面位移。',
                      style: TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                  ],
                      ],
                    ),
                  ),
                ),
                // ── 固定底栏:开始/停止稳定始终可见、可点 ──
                if (_stabilizeEnabled)
                  Padding(
                    padding: EdgeInsets.fromLTRB(20, 2, 20, 16 + bottomInset),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: _stabRunning
                                  ? Colors.white24
                                  : Colors.redAccent,
                            ),
                            onPressed: () {
                              if (_recording) {
                                lockedHint();
                                return;
                              }
                              setState(() {
                                if (_stabRunning) {
                                  _stabRunning = false;
                                  _stabOffsetX = 0;
                                  _stabOffsetY = 0;
                                } else {
                                  _onlineStab.reset();
                                  _stabOffsetX = 0;
                                  _stabOffsetY = 0;
                                  _stabAutoZoom = 1.0;
                                  _stabCorrDeg = 0;
                                  _stabLog.clear();
                                  _stabLast = DateTime.now();
                                  _stabRunning = true;
                                }
                              });
                              setSheetState(() {});
                              if (_stabRunning) Navigator.pop(ctx);
                            },
                            icon: Icon(
                              _stabRunning ? Icons.stop : Icons.play_arrow,
                            ),
                            label: Text(
                              _stabRunning ? '停止稳定(并关闭设置)' : '开始稳定',
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        ValueListenableBuilder<int>(
                          valueListenable: _stabTick,
                          builder: (context3, _, _) => Text(
                            '陀螺仪:${_gyroCount == 0 ? "无数据(请检查权限)" : "${_gyroHz.toStringAsFixed(0)} Hz · gx=${_gxNow.toStringAsFixed(2)}"}'
                            '\n角修正 ${_stabCorrDeg.toStringAsFixed(1)}° · 位移 '
                            '${_stabOffsetX.toStringAsFixed(0)},${_stabOffsetY.toStringAsFixed(0)}px'
                            ' · 自适应缩放 ${_stabAutoZoom.toStringAsFixed(2)}x'
                            ' · 记录 ${_stabLog.length} 条',
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 应用内播放导出的视频
  Future<void> _playExport(ExportItem item) async {
    final controller = VideoPlayerController.file(File(item.path));
    try {
      await controller.initialize();
      await controller.setLooping(true);
      await controller.play();
    } catch (e) {
      await controller.dispose();
      if (mounted) setState(() => _hint = '无法播放该视频: $e');
      return;
    }
    if (!mounted) {
      await controller.dispose();
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(
              aspectRatio: controller.value.aspectRatio == 0
                  ? 9 / 16
                  : controller.value.aspectRatio,
              child: VideoPlayer(controller),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton.icon(
                    onPressed: () => _saveExport(item),
                    icon: const Icon(
                      Icons.ios_share,
                      size: 16,
                      color: Colors.redAccent,
                    ),
                    label: const Text(
                      '保存',
                      style: TextStyle(color: Colors.redAccent),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text(
                      '关闭',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    await controller.dispose();
  }

  /// 保存作品(走系统分享面板:可存相册/发送)
  Future<void> _saveExport(ExportItem item) async {
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(item.path)],
        text: '心率录像',
        sharePositionOrigin: box != null
            ? box.localToGlobal(Offset.zero) & box.size
            : null,
      ),
    );
  }

  /// 生成 ASS 字幕文件:右上角显示 ♥ bpm,文本红色、黑描边
  void _writeAss(
    String path,
    int width,
    int height,
    double durationSec,
    List<_HrSample> samples,
  ) {
    // 心率采样点若为空,用局部占位
    final eff = samples.isEmpty ? [_HrSample(0, 0)] : samples;
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
    required List<_HrSample> samples,
  }) async {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    const winMs = 10000; // 10 秒窗口

    // 有效采样
    final pts = samples.where((s) => s.bpm > 0).toList();
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
          // ── 相机预览 ──
          // iOS 相机插件会把输出画面随设备方向旋转,但 value.aspectRatio 始终返回
          // 捕获格式的原始比例(横向)。故竖屏时纹理实际是竖向,必须用 1/aspectRatio。
          // 运动稳定开启时:画面按自适应缩放放大形成余量,再按陀螺仪位移取景框。
          if (cam != null && cam.value.isInitialized)
            Positioned.fill(
              child: GestureDetector(
                // 运动稳定开启后:双指缩放画面(留出可移动余量)
                // 注意:录像/处理中不接管手势,否则会抢走录像按钮的点击
                onScaleStart: (_stabilizeEnabled && !_recording && !_busy)
                    ? (_) => _zoomAtGestureStart = _zoom
                    : null,
                onScaleUpdate: (_stabilizeEnabled && !_recording && !_busy)
                    ? (d) async {
                        final camNow = _cam;
                        if (camNow == null) return;
                        final z = (_zoomAtGestureStart * d.scale).clamp(
                          _minZoom <= 0 ? 1.0 : _minZoom,
                          _maxZoom <= 0 ? 1.0 : _maxZoom,
                        );
                        if ((z - _zoom).abs() < 0.01) return;
                        try {
                          await camNow.setZoomLevel(z);
                        } catch (_) {}
                        if (mounted) setState(() => _zoom = z);
                      }
                    : null,
                child: LayoutBuilder(
                  builder: (context, cons) {
                    final sw = cons.maxWidth;
                    final sh = cons.maxHeight;
                    // 记录显示区尺寸(供计算稳定可移动范围)
                    _previewSize = Size(sw, sh);
                    final rawA = cam.value.aspectRatio <= 0
                        ? 4.0 / 3.0
                        : cam.value.aspectRatio;
                    // 稳定运行中:按自适应缩放放大(留出余量),并做双轴补偿
                    final over = _stabRunning ? _stabAutoZoom : 1.0;
                    final dx = _stabRunning ? _stabOffsetX : 0.0;
                    final dy = _stabRunning ? _stabOffsetY : 0.0;

                    // 竖屏:纹理已竖置 → 用竖比例 cover 铺满全屏
                    if (!isLandscape) {
                      final a = 1.0 / rawA;
                      double iw, ih;
                      if (a > sw / sh) {
                        ih = sh;
                        iw = ih * a;
                      } else {
                        iw = sw;
                        ih = iw / a;
                      }
                      iw *= over;
                      ih *= over;
                      return Center(
                        child: SizedBox(
                          width: sw,
                          height: sh,
                          child: ClipRect(
                            child: OverflowBox(
                              alignment: Alignment.center,
                              minWidth: iw,
                              maxWidth: iw,
                              minHeight: ih,
                              maxHeight: ih,
                              child: Transform.translate(
                                offset: Offset(dx, dy),
                                child: SizedBox(
                                  width: iw,
                                  height: ih,
                                  child: CameraPreview(cam),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    }

                    // 横屏:4:3 取景框(纹理为横向,比例一致,不拉伸)
                    const tA = 4.0 / 3.0;
                    double tw, th;
                    if (sw / sh > tA) {
                      th = sh;
                      tw = th * tA;
                    } else {
                      tw = sw;
                      th = tw / tA;
                    }
                    double iw = th * rawA, ih = th;
                    if (iw < tw) {
                      iw = tw;
                      ih = tw / rawA;
                    }
                    iw *= over;
                    ih *= over;
                    return Center(
                      child: SizedBox(
                        width: tw,
                        height: th,
                        child: ClipRect(
                          child: OverflowBox(
                            alignment: Alignment.center,
                            minWidth: iw,
                            maxWidth: iw,
                            minHeight: ih,
                            maxHeight: ih,
                            child: Transform.translate(
                              offset: Offset(dx, dy),
                              child: SizedBox(
                                width: iw,
                                height: ih,
                                child: CameraPreview(cam),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            )
          else
            GestureDetector(
              onTap: _restoreCamera,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 32,
                      height: 32,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                    SizedBox(height: 12),
                    Text(
                      '相机未就绪,点击重试',
                      style: TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),

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
                    // 作品(已导出视频)入口
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        IconButton(
                          tooltip: '作品',
                          onPressed: _showExportsSheet,
                          icon: const Icon(
                            Icons.folder,
                            color: Colors.white,
                            size: 24,
                          ),
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.black,
                          ),
                        ),
                        if (_exports.isNotEmpty)
                          Positioned(
                            right: 2,
                            top: 2,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.redAccent,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '${_exports.length}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                      ],
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

          // ── 后台渲染进度条(点一下可重新打开进度窗)──
          if (_job != null && _renderBackground)
            Positioned(
              top: topPad + (isLandscape ? 66 : 120),
              left: 20,
              right: 20,
              child: GestureDetector(
                onTap: _reopenRenderDialog,
                child: ListenableBuilder(
                  listenable: _job!,
                  builder: (context2, _) {
                    final job = _job!;
                    final pct = (job.progress * 100).round();
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.72),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              value: job.progress,
                              strokeWidth: 2.5,
                              backgroundColor: Colors.white12,
                              valueColor: const AlwaysStoppedAnimation(
                                Colors.redAccent,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              job.done
                                  ? '导出完成,可在"作品"中查看'
                                  : '后台渲染中 $pct%  ${job.stage}',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          const Icon(
                            Icons.open_in_full,
                            size: 14,
                            color: Colors.white38,
                          ),
                        ],
                      ),
                    );
                  },
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

          // ── 运动稳定按钮(录像按钮左侧)──
          Positioned(
            bottom: 56,
            left: isLandscape ? 40 : 28,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _stabRunning
                        ? Colors.redAccent
                        : Colors.black.withValues(alpha: 0.55),
                    border: Border.all(
                      color: _stabilizeEnabled
                          ? Colors.redAccent
                          : Colors.white24,
                      width: 1.5,
                    ),
                  ),
                  child: IconButton(
                    tooltip: '运动稳定',
                    // 始终可点:录制/处理中的限制在弹窗内用提示表达,避免"点了没反应"
                    onPressed: _showStabilizeSheet,
                    icon: Icon(
                      Icons.screen_rotation,
                      size: 22,
                      color: _stabRunning
                          ? Colors.white
                          : (_stabilizeEnabled
                                ? Colors.redAccent
                                : Colors.white70),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _stabRunning ? '稳定中' : (_stabilizeEnabled ? '已开启' : '运动稳定'),
                  style: TextStyle(
                    color: _stabRunning ? Colors.redAccent : Colors.white54,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),

          // ── 稳定运行中的状态提示(点一下可调整)──
          if (_stabRunning)
            Positioned(
              bottom: 150,
              left: 16,
              child: GestureDetector(
                onTap: _showStabilizeSheet,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.redAccent, width: 0.8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.screen_rotation,
                        color: Colors.redAccent,
                        size: 14,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '稳定中 角修正 ${_stabCorrDeg.toStringAsFixed(1)}° · '
                        '位移 ${_stabOffsetX.toStringAsFixed(0)},'
                        '${_stabOffsetY.toStringAsFixed(0)}px · '
                        '${_stabAutoZoom.toStringAsFixed(2)}x',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _gyroCount == 0
                            ? '陀螺仪无数据'
                            : '${_gyroHz.toStringAsFixed(0)}Hz',
                        style: TextStyle(
                          color: _gyroCount == 0
                              ? Colors.redAccent
                              : Colors.greenAccent,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
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
                  // 拍摄按钮:白圆环包裹内部红圆(录制中:红圆环+内部白圆)
                  GestureDetector(
                    onTap: _toggleRecord,
                    child: Container(
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _recording ? Colors.redAccent : Colors.white,
                        border: Border.all(color: Colors.white, width: 5),
                      ),
                      child: Center(
                        child: Container(
                          width: 54,
                          height: 54,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _recording ? Colors.white : Colors.redAccent,
                          ),
                        ),
                      ),
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
    _stopGyroSession();
    _stabTick.dispose();
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
