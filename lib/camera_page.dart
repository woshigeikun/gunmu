import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
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

import 'package:vision_tracker/vision_tracker.dart';

import 'ble_heart_rate.dart';
import 'gyro_test_page.dart';
import 'stabilizer.dart';
import 'target_tracker.dart';

/// 画面锁定的跟踪帧宽度。
/// iOS 走系统 Vision(算力不在 Dart 侧),可以用更大分辨率换精度;
/// 其他平台退回 Dart 的 SAD 块匹配,小一点才跑得动。
const int kTrackWidthVision = 320;
const int kTrackWidthSad = 128;
int get kTrackWidth =>
    VisionTracker.isSupported ? kTrackWidthVision : kTrackWidthSad;

/// 跟踪抽帧帧率
const double kTrackFps = 10;

/// 一次心率采样:相对录像开始的时间(毫秒)+ 心率值
class _HrSample {
  final int ms;
  final int bpm;
  _HrSample(this.ms, this.bpm);
}

/// 导出(渲染)任务进度
/// 构建标记:用来在手机上确认装的到底是哪一版(显示在导出进度窗底部)
const String kBuildTag = 'v38-speedup';

class RenderJob extends ChangeNotifier {
  double _progress = 0;
  String _stage = '准备中…';
  double? _etaSec;
  bool _done = false;
  String? _error;
  String? _stabInfo; // 运动稳定实际参数(尽早填,弹窗立刻可见)
  String? _encoderText; // 使用的视频编码器
  double? _speedNow; // 实时渲染速度(倍速)

  double get progress => _progress;
  String get stage => _stage;
  double? get etaSec => _etaSec;
  bool get done => _done;
  String? get error => _error;
  String? get stabInfo => _stabInfo;
  String? get encoderText => _encoderText;
  double? get speedNow => _speedNow;

  set stabInfo(String? v) {
    _stabInfo = v;
    notifyListeners();
  }

  set encoderText(String? v) {
    _encoderText = v;
    notifyListeners();
  }

  set speedNow(double? v) {
    _speedNow = v;
    notifyListeners();
  }

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
  // 本段录像开始时的相机放大倍数(稳定算法用它换算等效焦距)
  double _recordZoom = 1.0;

  // ── 画面锁定(目标跟踪稳定)──
  bool _lockEnabled = false; // 开关:是否启用画面识别锁定
  // 用户画的框,归一化到"预览里显示的那幅图"的坐标(0~1)。
  // 该图与成片是同一幅画面(同比例、同朝向),所以能直接映射到成片中。
  Rect? _lockBox;
  Rect? _lockBoxSnapshot; // 本段录像开始时的框(录制期间可继续改,不影响已录段)
  // 拖拽画框过程(屏幕坐标)
  Offset? _dragFrom;
  Offset? _dragTo;
  bool _dragging = false;
  // 诊断:上一次跟踪结果
  int _trackFrames = 0;
  int _trackOkFrames = 0;

  /// 预览里那幅图的映射参数 [显示宽, 显示高, 平移x, 平移y](由 LayoutBuilder 写入),
  /// 用于在"屏幕坐标 ⇄ 图像归一化坐标"之间换算锁定框。
  List<double> _imgMap = const [1, 1, 0, 0];

  /// 自动识别出的候选目标(点一下即可锁定)
  List<TargetCandidate> _candidates = const [];
  bool _detecting = false;

  // ── 实时候选识别(开关形式,每 0.1 秒刷新一次)──
  bool _liveDetect = false;
  Timer? _liveTimer;
  CameraImage? _liveFrame;

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
    // 启动就清一次临时文件:导出中途失败/被杀掉会留下几百 MB 的抽帧文件,
    // 不主动清就会一直在手机里堆积(实测能堆到几个 GB)。
    unawaited(_purgeWork(quiet: true));
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

  // ─────────────── 临时文件清理(缓存)───────────────

  /// 工作目录:导出过程的所有临时文件都放这里
  Future<Directory> _workDir() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/work');
  }

  /// 统计并清理临时文件。返回释放的字节数。
  /// [quiet] = true 时不改提示条(启动时静默清理)。
  Future<int> _purgeWork({bool quiet = false}) async {
    var freed = 0;
    try {
      final work = await _workDir();
      if (work.existsSync()) {
        for (final e in work.listSync()) {
          try {
            if (e is File) {
              freed += e.lengthSync();
              e.deleteSync();
            } else if (e is Directory) {
              for (final f in e.listSync(recursive: true)) {
                if (f is File) freed += f.lengthSync();
              }
              e.deleteSync(recursive: true);
            }
          } catch (_) {}
        }
      }
      // 相机插件录的原始视频也在临时目录里,导出成功才删;顺手一起清
      final tmp = await getTemporaryDirectory();
      if (tmp.existsSync()) {
        for (final e in tmp.listSync()) {
          if (e is File &&
              (e.path.endsWith('.mp4') ||
                  e.path.endsWith('.mov') ||
                  e.path.endsWith('.gray'))) {
            try {
              freed += e.lengthSync();
              e.deleteSync();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    if (!quiet && mounted) {
      setState(
        () => _hint = freed <= 0
            ? '缓存已经是干净的'
            : '已清理缓存,释放 ${(freed / 1048576).toStringAsFixed(1)} MB',
      );
    }
    return freed;
  }

  /// 当前缓存占用(供按钮显示)
  Future<int> _cacheBytes() async {
    var total = 0;
    try {
      final work = await _workDir();
      if (work.existsSync()) {
        for (final e in work.listSync(recursive: true)) {
          if (e is File) {
            try {
              total += e.lengthSync();
            } catch (_) {}
          }
        }
      }
      final tmp = await getTemporaryDirectory();
      if (tmp.existsSync()) {
        for (final e in tmp.listSync()) {
          if (e is File &&
              (e.path.endsWith('.mp4') ||
                  e.path.endsWith('.mov') ||
                  e.path.endsWith('.gray'))) {
            try {
              total += e.lengthSync();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    return total;
  }

  // ─────────────── 画面锁定:候选目标自动识别 ───────────────

  /// 抓一帧预览画面并转成灰度 + 缩放,供候选目标识别使用。
  /// 返回 (灰度数据, 宽, 高, 顺时针90°圈数)。
  Future<(Uint8List, int, int, int)?> _grabGrayFrame() async {
    final cam = _cam;
    if (cam == null || !cam.value.isInitialized) return null;
    // 朝向要在任何 await 之前读,避免跨异步使用 context
    final portrait = MediaQuery.of(context).orientation == Orientation.portrait;
    final c = Completer<CameraImage?>();
    try {
      await cam.startImageStream((f) {
        if (!c.isCompleted) c.complete(f);
      });
      final img = await c.future.timeout(
        const Duration(seconds: 4),
        onTimeout: () => null,
      );
      try {
        await cam.stopImageStream();
      } catch (_) {}
      if (img == null) return null;
      // 朝向:竖屏且传感器画面是横向 → 需要顺时针转 90°,
      // 与成片用的 transpose=1 保持一致。
      final turns = (portrait && img.width > img.height) ? 1 : 0;
      final g = _frameToGray(img, turns, 1024);
      if (g == null) return null;
      return (g.$1, g.$2, g.$3, turns);
    } catch (_) {
      try {
        await cam.stopImageStream();
      } catch (_) {}
      return null;
    }
  }

  /// 相机帧 → 灰度(带旋转与缩放)。BGRA 取 G 通道当灰度,YUV 取 Y 平面。
  (Uint8List, int, int)? _frameToGray(CameraImage img, int q, int maxDim) {
    final planes = img.planes;
    if (planes.isEmpty) return null;
    final sw = img.width, sh = img.height;
    if (sw <= 0 || sh <= 0) return null;
    final src = planes[0].bytes;
    final rowStride = planes[0].bytesPerRow;
    // 单平面 = BGRA(每像素 4 字节);多平面 = YUV420,平面 0 就是亮度
    final bgra = planes.length == 1;
    final pxStride = bgra ? 4 : 1;
    final base = bgra ? 1 : 0;

    final swap = q % 2 == 1;
    final rw = swap ? sh : sw;
    final rh = swap ? sw : sh;
    final rot = Uint8List(rw * rh);
    for (var y = 0; y < sh; y++) {
      final rowOff = y * rowStride;
      for (var x = 0; x < sw; x++) {
        final v = src[rowOff + x * pxStride + base];
        int rx, ry;
        switch (q) {
          case 1:
            rx = sh - 1 - y;
            ry = x;
          case 2:
            rx = sw - 1 - x;
            ry = sh - 1 - y;
          case 3:
            rx = y;
            ry = sw - 1 - x;
          default:
            rx = x;
            ry = y;
        }
        rot[ry * rw + rx] = v;
      }
    }

    final long = rw > rh ? rw : rh;
    if (long <= maxDim) return (rot, rw, rh);
    final scale = maxDim / long;
    final fw = (rw * scale).round().clamp(8, rw);
    final fh = (rh * scale).round().clamp(8, rh);
    final out = Uint8List(fw * fh);
    for (var y = 0; y < fh; y++) {
      final srow = (y * rh ~/ fh) * rw;
      final orow = y * fw;
      for (var x = 0; x < fw; x++) {
        out[orow + x] = rot[srow + (x * rw ~/ fw)];
      }
    }
    return (out, fw, fh);
  }

  /// 开关:实时识别候选目标(每 0.1 秒刷新一次)
  ///
  /// 为什么用开关而不是按钮:取景时目标是会动、会进出画面的,
  /// 一次性识别出来的框几秒后就对不上了。保持图像流常开、每 0.1 秒重识别,
  /// 候选框才能跟着画面走。
  /// 注意:iOS 不允许"录像 + 取图像流"并存,所以录像开始时必须暂停。
  Future<void> _setLiveDetect(bool on) async {
    if (on == _liveDetect) return;
    final cam = _cam;
    if (on) {
      if (cam == null || !cam.value.isInitialized) {
        if (mounted) {
          setState(() {
            _liveDetect = false;
            _hint = '相机未就绪,无法开启实时识别';
          });
        }
        return;
      }
      setState(() {
        _liveDetect = true;
        _hint = '实时识别中:每 0.1 秒刷新候选目标';
      });
      await _resumeLive();
    } else {
      setState(() {
        _liveDetect = false;
        _candidates = const [];
        _hint = '';
      });
      await _pauseLive();
    }
  }

  /// 启动图像流与 0.1 秒定时器
  Future<void> _resumeLive() async {
    final cam = _cam;
    if (cam == null || !cam.value.isInitialized) return;
    try {
      await cam.startImageStream((f) => _liveFrame = f);
    } catch (e) {
      if (mounted) {
        setState(() {
          _liveDetect = false;
          _hint = '无法开启实时识别: $e';
        });
      }
      return;
    }
    _liveTimer?.cancel();
    _liveTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _liveTick(),
    );
  }

  /// 停掉图像流与定时器(录像前必须调用)
  Future<void> _pauseLive() async {
    _liveTimer?.cancel();
    _liveTimer = null;
    _liveFrame = null;
    try {
      await _cam?.stopImageStream();
    } catch (_) {}
  }

  /// 每 0.1 秒跑一次:取最新帧 → 灰度 → Vision 检测 → 刷新候选框
  Future<void> _liveTick() async {
    if (!_liveDetect || _detecting || _recording || _busy) return;
    final f = _liveFrame;
    if (f == null || !mounted) return;
    // 跨 await 前先读上下文
    final portrait = MediaQuery.of(context).orientation == Orientation.portrait;
    _detecting = true;
    try {
      final turns = (portrait && f.width > f.height) ? 1 : 0;
      final g = _frameToGray(f, turns, 1024);
      if (g == null) return;
      final list = await VisionTracker.detectTargets(
        bytes: g.$1,
        w: g.$2,
        h: g.$3,
        rotationQuarterTurns: turns,
      );
      if (!mounted || !_liveDetect) return;
      setState(() => _candidates = list);
    } catch (_) {
      // 单帧识别失败不影响下一帧
    } finally {
      _detecting = false;
    }
  }

  /// 识别候选目标:单次识别(实时候选开关关闭时的备用入口)
  // ignore: unused_element
  Future<void> _detectCandidates() async {
    if (_detecting || _recording || _busy) return;
    if (!VisionTracker.isSupported) {
      setState(() => _hint = '当前平台不支持自动识别,请在预览上拖拽手动画框');
      return;
    }
    setState(() {
      _detecting = true;
      _candidates = const [];
      _hint = '正在识别画面中的候选目标…';
    });
    try {
      final f = await _grabGrayFrame();
      if (f == null) {
        if (mounted) {
          setState(() {
            _detecting = false;
            _hint = '未能获取预览画面,请稍后重试或手动画框';
          });
        }
        return;
      }
      final (bytes, w, h, turns) = f;
      final list = await VisionTracker.detectTargets(
        bytes: bytes,
        w: w,
        h: h,
        rotationQuarterTurns: turns,
      );
      if (!mounted) return;
      setState(() {
        _detecting = false;
        _candidates = list;
        _hint = list.isEmpty
            ? '没有找到明显的候选目标,请在预览上拖拽手动画框'
            : '找到 ${list.length} 个候选目标:点一下即可锁定,也可以直接拖拽手动画框';
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _detecting = false;
          _hint = '识别失败: $e';
        });
      }
    }
  }

  /// 点击预览:命中候选框就锁定它,否则忽略(拖动仍然是手动画框)
  bool _tryPickCandidate(Offset local) {
    if (_candidates.isEmpty) return false;
    final p = _screenToImage(local);
    // 命中多个时**取面积最小的那个**:
    // "醒目区域"常常输出一个几乎覆盖整幅画面的大框,它会包含屏幕上的每一个点。
    // 如果按顺序取第一个命中的,用户就永远只能选中那个大框,永远点不到想选的小框。
    TargetCandidate? best;
    var bestArea = double.infinity;
    for (final c in _candidates) {
      if (!c.box.contains(p)) continue;
      final a = c.box.width * c.box.height;
      if (a < bestArea) {
        bestArea = a;
        best = c;
      }
    }
    if (best == null) return false;
    final picked = best;
    setState(() {
      _lockBox = picked.box;
      _hint = '已锁定「${picked.label}」;开始稳定后导出时把它钉在画面正中';
    });
    // 选中候选就自动开始稳定,不必再回弹窗点一次「开始稳定」
    _autoStartStabilize();
    return true;
  }

  /// 选中目标后就地开始稳定(等价于用户点了「开始稳定」)
  void _autoStartStabilize() {
    if (_stabRunning || _recording || _busy) return;
    setState(() {
      _stabilizeEnabled = true;
      _onlineStab.reset();
      _stabOffsetX = 0;
      _stabOffsetY = 0;
      _stabAutoZoom = GyroStabilizer.zoomForMargin(
        GyroStabilizer.marginFor(_stabStrength),
      );
      _stabCorrDeg = 0;
      _stabLog.clear();
      _stabLast = DateTime.now();
      _stabRunning = true;
      _hint = '${_hint.isEmpty ? '' : '$_hint '}稳定已自动开启,可以直接录制';
    });
    _startGyroSession();
  }

  // ─────────────── 画面锁定:画框与坐标换算 ───────────────

  /// 屏幕坐标 → 预览图像归一化坐标(0~1)。图像在预览区里永远居中,
  /// 显示尺寸与位移取自 [_imgMap]。
  Offset _screenToImage(Offset p) {
    final sw = _previewSize.width;
    final sh = _previewSize.height;
    final iw = _imgMap[0];
    final ih = _imgMap[1];
    if (sw <= 0 || sh <= 0 || iw <= 0 || ih <= 0) return Offset.zero;
    final x = ((p.dx - _imgMap[2]) - sw / 2) / iw + 0.5;
    final y = ((p.dy - _imgMap[3]) - sh / 2) / ih + 0.5;
    return Offset(x.clamp(0.0, 1.0), y.clamp(0.0, 1.0));
  }

  /// 预览图像归一化坐标 → 屏幕坐标(把框画出来用)
  Rect _imageRectToScreen(Rect r) {
    final sw = _previewSize.width;
    final sh = _previewSize.height;
    final iw = _imgMap[0];
    final ih = _imgMap[1];
    if (iw <= 0 || ih <= 0) return Rect.zero;
    double sx(double x) => (x - 0.5) * iw + _imgMap[2] + sw / 2;
    double sy(double y) => (y - 0.5) * ih + _imgMap[3] + sh / 2;
    return Rect.fromLTRB(sx(r.left), sy(r.top), sx(r.right), sy(r.bottom));
  }

  /// 拖拽结束:把屏幕矩形换算成归一化图像坐标并保存为锁定框
  void _commitLockBox() {
    final from = _dragFrom;
    final to = _dragTo;
    _dragFrom = null;
    _dragTo = null;
    if (from == null || to == null) {
      setState(() {});
      return;
    }
    // 位移极小 = 这是一次点击:优先命中候选目标,命中就锁定它(不必手画)
    if ((from - to).distance < 14 && _tryPickCandidate(to)) return;
    final a = _screenToImage(from);
    final b = _screenToImage(to);
    final l = math.min(a.dx, b.dx);
    final t = math.min(a.dy, b.dy);
    final r = math.max(a.dx, b.dx);
    final btm = math.max(a.dy, b.dy);
    // 框太小当误触:忽略这次拖拽
    if ((r - l) < 0.03 || (btm - t) < 0.03) {
      setState(() {});
      return;
    }
    setState(() {
      _lockBox = Rect.fromLTRB(l, t, r, btm);
      _hint = '已锁定目标框;开始稳定后导出时会把框内目标钉在画面正中';
    });
    // 手动画框同样自动开始稳定
    _autoStartStabilize();
  }

  /// 锁定框的屏幕矩形(拖拽中显示临时框)
  Rect? get _lockBoxScreen {
    if (_dragging && _dragFrom != null && _dragTo != null) {
      return Rect.fromPoints(_dragFrom!, _dragTo!);
    }
    final box = _lockBox;
    if (box == null) return null;
    return _imageRectToScreen(box);
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
        // iOS 不允许"取图像流 + 录像"并存,必须先把实时识别停掉,
        // 否则 startVideoRecording 会直接抛错。
        final wasLive = _liveDetect;
        if (wasLive) await _pauseLive();
        try {
          await cam.startVideoRecording();
        } catch (e) {
          if (wasLive) await _resumeLive();
          rethrow;
        }
        _timer
          ..reset()
          ..start();
        _samples.clear();
        // 录制开始时刻是否已连手环:决定本段是否显示/烧录心率
        _recordHadBle = widget.ble.isConnected;
        // 记录本段录制方向:竖屏则成片需要旋转为竖向
        _recordPortrait = isPortraitNow;
        // 记录本段录制时的相机放大倍数:放大后等效焦距按倍数增长,
        // 补偿量必须跟着放大,否则放大后稳定会明显变弱。
        _recordZoom = _zoom <= 0 ? 1.0 : _zoom;
        // 快照本段的画面锁定目标框(录制中可以继续调,不影响这一段)
        _lockBoxSnapshot = _lockEnabled ? _lockBox : null;
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
        // 录像结束,恢复实时识别
        if (_liveDetect) unawaited(_resumeLive());
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
            lockBox: _lockBoxSnapshot,
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
    Rect? lockBox,
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
        lockBox: lockBox,
      );
      job
        ..progress = 1.0
        ..stage = '完成'
        ..etaSec = null
        ..done = true;
      await _loadExports();
      if (mounted) {
        // 把编码器与实际速度留在常驻提示里:进度窗关掉后也还能看到
        final sp = job.speedNow;
        final hw = (job.encoderText ?? '').contains('软件') ? '软件编码' : '硬件编码';
        setState(
          () => _hint =
              '导出完成 · $hw'
              '${sp == null ? '' : ' · ${sp.toStringAsFixed(1)}x'}'
              ' · 点顶部文件夹查看',
        );
      }
    } catch (e) {
      job
        ..stage = '失败'
        ..error = '$e'
        ..done = true;
      if (mounted) setState(() => _hint = '导出失败: $e');
    } finally {
      _popRenderDialog();
      // 无论成功、失败还是转为后台渲染,都清一次临时文件:
      // 抽帧文件动辄几百 MB,留着就是存储泄漏。
      unawaited(_purgeWork(quiet: true));
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
                            '${job.speedNow == null ? '' : ' · ${job.speedNow!.toStringAsFixed(1)}x 速度'}'
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
                if (job.stabInfo != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    job.stabInfo!,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 12,
                    ),
                  ),
                ],
                if (job.encoderText != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    job.encoderText!,
                    style: const TextStyle(
                      color: Colors.greenAccent,
                      fontSize: 12,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  '构建 $kBuildTag',
                  style: const TextStyle(color: Colors.white24, fontSize: 10),
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
  /// 材料模式导出:原始视频 + 陀螺仪数据 CSV(+ 心率透明视频)
  Future<void> _exportMaterials({
    required XFile raw,
    required int stamp,
    required String folderPath,
    required bool hadBle,
    required List<_HrSample> samples,
    required List<List<double>> stabGyro,
    required double stabStartEpoch,
    required double stabEndEpoch,
    required double fallbackDuration,
    required RenderJob job,
  }) async {
    // 1) 原始视频原样保存(不重编码 → 秒级完成,也不会有二次压缩损失)
    job
      ..stage = '保存原始视频…'
      ..progress = 0.15;
    await raw.saveTo('$folderPath/${stamp}_原始.mp4');

    // 2) 陀螺仪数据 CSV:Gyroflow 等工具可直接导入
    job
      ..stage = '写出陀螺仪数据…'
      ..progress = 0.4;
    final csv = File('$folderPath/${stamp}_gyro.csv');
    final sb = StringBuffer()
      ..writeln('# 心率相机 陀螺仪数据')
      ..writeln('# 时间从视频第 0 帧起算(秒);角速度单位 rad/s;轴为设备轴 x=右 y=上 z=朝屏外')
      ..writeln('time,gx,gy,gz');
    final dur = stabEndEpoch - stabStartEpoch;
    for (final s in stabGyro) {
      final t = s[0] - stabStartEpoch;
      if (t < -0.2 || t > dur + 0.2) continue;
      sb.writeln(
        '${t.toStringAsFixed(5)},'
        '${s[1].toStringAsFixed(6)},${s[2].toStringAsFixed(6)},'
        '${s[3].toStringAsFixed(6)}',
      );
    }
    csv.writeAsStringSync(sb.toString());

    // 3) 心率透明视频:数字 + 曲线,透明背景,整帧分辨率,30fps
    String? hrPath;
    if (hadBle && samples.where((s) => s.bpm > 0).length >= 2) {
      job
        ..stage = '生成心率透明视频…'
        ..progress = 0.45;
      hrPath = await _renderHrOverlayVideo(
        folderPath: folderPath,
        stamp: stamp,
        fallbackDuration: fallbackDuration,
        samples: samples,
        rawPath: raw.path,
        job: job,
      );
    }

    job.progress = 1.0;
    if (mounted) {
      setState(
        () => _hint =
            '已输出素材:原始视频 + 陀螺仪数据'
            '${hrPath != null ? ' + 心率透明视频' : ''}'
            ' · 点顶部文件夹查看',
      );
    }
  }

  /// 渲染心率透明视频:逐秒画一张**透明背景**的整帧 PNG,再编码成带 alpha 的 MOV。
  /// 用 ProRes 4444 是因为它是剪辑软件(剪映/达芬奇/Premiere)对透明通道
  /// 支持最可靠的格式;H.264 无法承载 alpha 通道。
  Future<String?> _renderHrOverlayVideo({
    required String folderPath,
    required int stamp,
    required double fallbackDuration,
    required List<_HrSample> samples,
    required String rawPath,
    required RenderJob job,
  }) async {
    // 尺寸与朝向:和成片保持一致(竖屏录制则转成竖向)
    var width = 1080, height = 1920;
    double durationSec = fallbackDuration <= 0 ? 1.0 : fallbackDuration;
    try {
      final info = await FFprobeKit.getMediaInformation(rawPath);
      final mi = info.getMediaInformation();
      for (final s in mi?.getStreams() ?? const []) {
        if (s.getType() == 'video') {
          width = s.getWidth() ?? width;
          height = s.getHeight() ?? height;
        }
      }
      final d = mi?.getDuration();
      final parsed = d != null ? double.tryParse(d) : null;
      if (parsed != null && parsed > 0) durationSec = parsed;
    } catch (_) {}
    if (_recordPortrait && width > height) {
      final t = width;
      width = height;
      height = t;
    }

    final docs = await getApplicationDocumentsDirectory();
    final work = Directory('${docs.path}/work/${stamp}_hr');
    if (work.existsSync()) work.deleteSync(recursive: true);
    work.createSync(recursive: true);
    final pts = samples.where((s) => s.bpm > 0).toList();
    if (pts.isEmpty) return null;
    final frames = durationSec.ceil() + 1;
    var idx = 0;
    for (var f = 0; f < frames; f++) {
      final ms = (f * 1000).clamp(0, (durationSec * 1000).round());
      while (idx + 1 < pts.length && pts[idx + 1].ms <= ms) {
        idx++;
      }
      final img = await _renderHrOverlayFrame(
        width,
        height,
        ms,
        curBpm: pts[idx].bpm.toDouble(),
        samples: samples,
      );
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      File('${work.path}/hr_${f.toString().padLeft(4, '0')}.png')
          .writeAsBytesSync(data!.buffer.asUint8List());
      job.progress = 0.45 + 0.35 * (f + 1) / frames;
    }

    final out = '$folderPath/${stamp}_心率.mov';
    final ok = await _runFfmpeg(
      '-y -loglevel error -framerate 1 -i "${work.path}/hr_%04d.png" '
      '-vf "fps=30" -c:v prores_ks -profile:v 4444 -pix_fmt yuva444p10le '
      '"$out"',
      durationSec,
      job,
    );
    try {
      work.deleteSync(recursive: true);
    } catch (_) {}
    return ok ? out : null;
  }

  /// 画一张透明背景的整帧:心率数字(红字黑描边)+ 心率曲线
  Future<ui.Image> _renderHrOverlayFrame(
    int w,
    int h,
    int ms, {
    required double curBpm,
    required List<_HrSample> samples,
  }) async {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    // 故意不填背景 → 输出带 alpha 通道的透明帧
    final fontSize = (h * 0.045).round().clamp(24, 200);
    const marginRight = 30.0;
    const marginTop = 40.0;
    final curW = (fontSize * 3.0).round().clamp(80, 720);
    final curH = (fontSize * 1.35).round().clamp(32, 320);
    final curX = (w - marginRight - curW).round();
    final curY = (marginTop + fontSize * 1.12).round();
    final curveImg = await _renderCurveFrame(
      curW,
      curH,
      ms,
      curBpm: curBpm,
      samples: samples,
    );
    canvas.drawImage(
      curveImg,
      Offset(curX.toDouble(), curY.toDouble()),
      Paint(),
    );
    // 数字:先黑描边后红填充(和烧录版观感一致)
    final label = '♥ ${curBpm.round()}';
    final outline = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          fontSize: fontSize.toDouble(),
          fontWeight: FontWeight.bold,
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 4
            ..color = Colors.black,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final fill = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          fontSize: fontSize.toDouble(),
          fontWeight: FontWeight.bold,
          color: const Color(0xFFFF3B30),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final tx = (w - marginRight - fill.width).clamp(0.0, w - fill.width);
    outline.paint(canvas, Offset(tx, marginTop));
    fill.paint(canvas, Offset(tx, marginTop));
    return rec.endRecording().toImage(w, h);
  }

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
    Rect? lockBox,
  }) async {
    final docs = await getApplicationDocumentsDirectory();
    final folder = Directory('${docs.path}/录像');
    if (!folder.existsSync()) folder.createSync(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    String saved = '${folder.path}/$stamp.mp4';

    // ── 材料模式(开启稳定时)─────────────────────────────
    // 开启稳定 = 采集端模式:只输出素材,稳定与合成交给外部工具
    // (Gyroflow 桌面版 / 剪映)。理由:Gyroflow 有相机配置(畸变、卷帘、
    // 轴向、时间对齐)、用 GPU 逐帧重投影,精度不是应用内简化模型能比的;
    // 我们把自己定位在"采集 + 心率渲染"更实在。
    //   只开稳定        → 原始视频 + 陀螺仪数据 CSV
    //   稳定 + 心率      → 上面两份 + 心率透明视频(ProRes 4444 带 alpha)
    //   只开心率        → 走下面原有逻辑(直接烧录),不变
    // 另外:开启了稳定时**仍然继续生成一份应用内稳定的成片**,
    // 方便你直接把两边结果对比(代价是导出时间变长)。
    final bool materialMode =
        stabGyro.length >= 4 && stabEndEpoch > stabStartEpoch;
    if (materialMode) {
      await _exportMaterials(
        raw: raw,
        stamp: stamp,
        folderPath: folder.path,
        hadBle: hadBle,
        samples: samples,
        stabGyro: stabGyro,
        stabStartEpoch: stabStartEpoch,
        stabEndEpoch: stabEndEpoch,
        fallbackDuration: fallbackDuration,
        job: job,
      );
      // 材料已出,接着生成应用内稳定成片(换一个文件名,不覆盖原始视频)
      saved = '${folder.path}/${stamp}_稳定.mp4';
      job
        ..stage = '生成稳定成片…'
        ..progress = 0.02;
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

    final workDir = Directory('${docs.path}/work');
    if (!workDir.existsSync()) workDir.createSync(recursive: true);

    // 1.5) 运动稳定分析:**尽早**算出来,这样进度窗一出现就能看到稳定参数,
    //      不用等心率曲线生成完(曲线阶段可能要好几秒)。
    //      四元数姿态积分 → 平滑虚拟相机路径 → 双轴补偿曲线 + 固定裁切余量。
    //
    //      位移是怎么施加的(关键改动):
    //      原来把曲线塞进 crop 的 x/y 表达式里,节点数被限制在 60 个 ——
    //      3 分钟的视频算下来每 3 秒才一个节点,而手抖是 1~8Hz,
    //      裁切框根本跟不上,等于没做稳定。
    //      现在改成 sendcmd 逐帧命令(60Hz),crop 的 x/y 每帧都被改写,
    //      分辨率提升两个数量级。expression 版本保留为首选失败时的退路。
    String stabPrefix = ''; // sendcmd 逐帧方案(首选),末尾带逗号以接 ass=
    String stabPrefixExpr = ''; // 表达式方案(退路)
    String? cmdsPath; // 逐帧命令文件(临时,出片后删除)

    // 1.45) 先算陀螺仪方案 —— 画面识别要拿它当"运动先验":
    //       陀螺仪测的是相机真实转动,高频非常准,有了它,画面识别只需要在
    //       很小的窗口里找目标,几乎不可能跳到附近相似的纹理上。
    final bool hasGyro = stabGyro.length >= 4 && stabEndEpoch > stabStartEpoch;
    StabPlan? plan;
    if (hasGyro) {
      job.stage = '分析陀螺仪数据…';
      plan = GyroStabilizer.analyze(
        samples: stabGyro,
        startEpoch: stabStartEpoch,
        endEpoch: stabEndEpoch,
        frameW: width.toDouble(),
        frameH: height.toDouble(),
        fovDeg: stabFov,
        strength: stabStrength,
        camZoom: _recordZoom, // 放大倍数:等效焦距要跟着放大
        curveStep: 1 / 60, // 60Hz 逐帧
        roll: stabStrength >= 1.6, // 「强」「激进」档启用地平线锁定(横滚校正)
      );
    }

    // 1.35) 多遍识别:检查点重新识别(每 10 秒一次)+ 用户没选时在 5 秒自动选目标
    List<List<double>>? anchors;
    var effBox = lockBox;
    var ckInfo = '';
    if (plan != null && plan.usable) {
      job
        ..stage = '检查点重新识别…'
        ..progress = 0.02;
      try {
        final ck = await _detectCheckpoints(
          rawPath: raw.path,
          vfPrefix: vfPrefix,
          refBox: lockBox,
          trackW: kTrackWidth,
          trackH: ((kTrackWidth * height) / width / 2).round() * 2,
          workDir: workDir,
          stamp: stamp,
          job: job,
        );
        if (ck != null) {
          effBox ??= ck.autoBox;
          anchors = ck.anchors;
          ckInfo = ck.info;
          if (ck.autoBox != null && mounted) {
            setState(() => _hint = '开头未选目标,已自动锁定画面中的「文字/数字」目标');
          }
        }
      } catch (_) {}
    }

    // 1.45) 时空对齐:用画面识别的**绝对轨迹**检验并校正陀螺仪
    //   * 时间偏移 τ:两条时间线没对齐时,高频补偿会施加在错误的时刻,
    //     不只是"补不够",而是可能把抖动放大 —— 这是最容易被忽略的误差源
    //   * 焦距尺度 s:陀螺仪测角度、视觉测像素,相除等于用拍摄过程自身标定焦距
    var alignInfo = '';
    if (anchors != null && anchors.isNotEmpty && plan != null && plan.usable) {
      try {
        final fit = _alignGyroToVision(
          anchors: anchors,
          plan: plan,
          trackW: kTrackWidth,
          outW: width,
        );
        if (fit != null) {
          alignInfo = fit.info;
          // 偏移或尺度明显偏离,就用修正后的参数重算整套方案
          if (fit.tau.abs() >= 0.005 || (fit.scale - 1).abs() >= 0.02) {
            final corrected = GyroStabilizer.analyze(
              samples: stabGyro,
              startEpoch: stabStartEpoch + fit.tau,
              endEpoch: stabEndEpoch,
              frameW: width.toDouble(),
              frameH: height.toDouble(),
              fovDeg: stabFov,
              strength: stabStrength,
              curveStep: 1 / 60,
              roll: stabStrength >= 1.6,
              camZoom: _recordZoom * fit.scale,
            );
            if (corrected.usable) plan = corrected;
          }
        }
      } catch (_) {}
    }

    // 1.4) 画面锁定:跟踪出目标轨迹(必须在方向判定之后,因为抽帧要跟着转置;
    //      也必须在陀螺仪分析之后,因为要用它当先验)
    List<List<double>>? lockXY;
    if (effBox != null && plan != null && plan.usable) {
      job
        ..stage = '画面识别(目标锁定)…'
        ..progress = 0.02;
      try {
        // 把陀螺仪曲线换算成"跟踪帧里的目标预测位置":
        // 陀螺仪给的是"需要施加的画面位移 D",而画面本身在录制时移动了 -D,
        // 所以目标在原始帧里的位置 = 初始位置 - D。
        final priorX = <double>[];
        final priorY = <double>[];
        final k = kTrackWidth / width;
        final gyroX = plan.dx.map((e) => <double>[e[0], e[1]]).toList();
        final gyroY = plan.dy.map((e) => <double>[e[0], e[1]]).toList();
        final nFrames = (durationSec * kTrackFps).round().clamp(2, 200000);
        for (var f = 0; f < nFrames; f++) {
          final t = f / kTrackFps;
          priorX.add(-TargetTracker.interp(gyroX, t) * k);
          priorY.add(-TargetTracker.interp(gyroY, t) * k);
        }
        lockXY = await _trackTargetPath(
          rawPath: raw.path,
          vfPrefix: vfPrefix,
          outW: width,
          outH: height,
          box: effBox,
          workDir: workDir,
          stamp: stamp,
          job: job,
          priorDx: priorX,
          priorDy: priorY,
          anchors: anchors,
        );
      } catch (e) {
        lockXY = null;
        if (mounted) setState(() => _hint = '画面识别失败,已退回纯陀螺仪稳定: $e');
      }
      if (lockXY == null && mounted) {
        setState(() => _hint = '画面识别未取得可信轨迹($logTrack),已退回纯陀螺仪稳定');
      }
    }

    if (plan != null && plan.usable) {
      {
        final zoom = plan.zoom;
        final scaledW = ((width * zoom) / 2).floor() * 2;
        final scaledH = ((height * zoom) / 2).floor() * 2;
        final baseX = (scaledW - width) / 2;
        final baseY = (scaledH - height) / 2;
        final maxX = scaledW - width;
        final maxY = scaledH - height;
        final bx = baseX.round().clamp(0, maxX);
        final by = baseY.round().clamp(0, maxY);

        // ── sendcmd 逐帧命令文件 ──
        // 注意符号:预览用 Transform.translate(+d) 平移画面,内容位移 = +d;
        // 而这里是移动**裁切窗口**,窗口右移 ⇒ 内容在成片里左移,
        // 所以成片的位移是 -d。两处必须相反,否则成片方向和预览是镜像的。
        final sb = StringBuffer();
        final n = plan.dx.length < plan.dy.length
            ? plan.dx.length
            : plan.dy.length;
        // 融合:低频用画面识别(把目标死死钉在正中,且不会像陀螺仪那样漂移),
        //       高频用陀螺仪(10fps 的跟踪看不到高频抖动,那部分只能靠陀螺仪)。
        // 关键:两个频段必须**互补且不重叠**。视觉曲线本身也含 5Hz 以内的信息,
        // 如果直接整体相加,1.7~5Hz 那一段会被补偿两次 → 过补偿、画面来回甩。
        // 所以视觉只取低频、陀螺仪只取高频,同一段动作永远只被补偿一次。
        List<List<double>>? lockX;
        List<List<double>>? lockY;
        List<double>? ghpX;
        List<double>? ghpY;
        if (lockXY != null && lockXY.length >= 2) {
          const win = 0.6;
          lockX = _lowPassCurve(
            lockXY.map((e) => <double>[e[0], e[1]]).toList(),
            win,
            kTrackFps,
          );
          lockY = _lowPassCurve(
            lockXY.map((e) => <double>[e[0], e[2]]).toList(),
            win,
            kTrackFps,
          );
          ghpX = _highPass(plan.dx, win, 60);
          ghpY = _highPass(plan.dy, win, 60);
        }
        final limX = plan.margin * width;
        final limY = plan.margin * height;
        for (var i = 0; i < n; i++) {
          final t = plan.dx[i][0];
          var dxPx = plan.dx[i][1];
          var dyPx = plan.dy[i][1];
          if (lockX != null && lockY != null && ghpX != null && ghpY != null) {
            dxPx = TargetTracker.interp(lockX, t) + ghpX[i];
            dyPx = TargetTracker.interp(lockY, t) + ghpY[i];
            dxPx = dxPx.clamp(-limX, limX);
            dyPx = dyPx.clamp(-limY, limY);
          }
          final ts = t.toStringAsFixed(4);
          final x = (baseX - zoom * dxPx).round().clamp(0, maxX);
          final y = (baseY - zoom * dyPx).round().clamp(0, maxY);
          sb.writeln('$ts crop@c x $x;');
          sb.writeln('$ts crop@c y $y;');
        }
        final cmdsFile = File('${workDir.path}/${stamp}_cmds.txt');
        cmdsFile.writeAsStringSync(sb.toString());
        cmdsPath = cmdsFile.path;
        stabPrefix =
            'sendcmd=f=$cmdsPath,'
            'scale=$scaledW:$scaledH:flags=bilinear,'
            'crop@c=$width:$height:$bx:$by,';

        // ── 退路:表达式方案(分辨率受限,只在 sendcmd 不可用时用)──
        final exprX = GyroStabilizer.toCropExpr(plan.dx, maxKnots: 160);
        final exprY = GyroStabilizer.toCropExpr(plan.dy, maxKnots: 160);
        // 地平线锁定:用 rotate 逐帧把画面转回来(角度可逐帧表达式)。
        // 注意 rotate 的 a 是弧度、正值 = 顺时针。
        final exprRoll = plan.hasRoll
            ? GyroStabilizer.toCropExpr(plan.roll, maxKnots: 160)
            : null;
        if (exprRoll != null) {
          stabPrefix =
              'sendcmd=f=$cmdsPath,'
              'scale=$scaledW:$scaledH:flags=bilinear,'
              "rotate=a='$exprRoll':ow=iw:oh=ih,"
              'crop@c=$width:$height:$bx:$by,';
        }
        if (exprX != null && exprY != null) {
          stabPrefixExpr =
              'scale=$scaledW:$scaledH:flags=bilinear,'
              'crop=$width:$height:'
              "'(${baseX.toStringAsFixed(1)}-$zoom*($exprX))':"
              "'(${baseY.toStringAsFixed(1)}-$zoom*($exprY))',";
        }
        job.stabInfo =
            '运动稳定 ×${zoom.toStringAsFixed(2)} · 位移≤'
            '${plan.maxShiftX.toStringAsFixed(0)},'
            '${plan.maxShiftY.toStringAsFixed(0)}px · '
            '逐帧 60Hz($n 点) · '
            '陀螺仪 ${stabGyro.length} 条'
            '${lockX != null ? ' · $logTrack' : ''}'
            '${ckInfo.isEmpty ? '' : ' · $ckInfo'}'
            '${alignInfo.isEmpty ? '' : ' · $alignInfo'}';
      }
      if (stabPrefix.isEmpty && stabPrefixExpr.isEmpty) {
        job.stabInfo = '陀螺仪数据不足(${stabGyro.length} 条),未应用运动稳定';
      }
      if (mounted) setState(() => _hint = job.stabInfo ?? '');
    }

    // 1.6) 编码器:直接上硬件编码(iPhone=VideoToolbox / 安卓=MediaCodec),
    //      通常比 libx264 快 5~10 倍;不支持时下面会自动回退软件编码。
    //      这一行是同步赋值的,所以进度窗一出现就能看到,不用等任何探测。
    final encHw = _videoEncArgs(width, height);
    final encSw = _videoEncArgs(width, height, forceSw: true);
    job.encoderText = '编码器 $_hwEncoderName(硬件加速)';
    final threads = Platform.numberOfProcessors.clamp(2, 8);

    // 2) 字幕 + 曲线参数(workDir 已在 1.5 步建好)
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

    // 2.6) 本段开始时未连手环 → 不烧心率 UI,但**仍然**应用运动稳定
    //      (stabPrefix 已在 1.5 步算好)
    if (!hadBle) {
      job
        ..stage = '保存视频…'
        ..progress = 0.6;
      if (stabPrefix.isEmpty) {
        await raw.saveTo(saved);
      } else {
        final stabOnly = stabPrefix.substring(0, stabPrefix.length - 1);
        final tmpOut = '${workDir.path}/${stamp}_stab.mp4';
        String stabCmd(String enc) =>
            '-y -i "${raw.path}" -vf "$vfPrefix$stabOnly" '
            '$enc -c:a aac -b:a 128k "$tmpOut"';
        var stabOk = await _runFfmpeg(stabCmd(encHw), durationSec, job);
        if (!stabOk) {
          job
            ..stage = '改用软件编码重试…'
            ..encoderText = '软件编码 libx264(硬件编码不可用)';
          stabOk = await _runFfmpeg(stabCmd(encSw), durationSec, job);
        }
        if (!stabOk) throw Exception('FFmpeg 稳定处理失败');
        await File(tmpOut).copy(saved);
        try {
          File(tmpOut).deleteSync();
        } catch (_) {}
      }
      try {
        File(assPath).deleteSync();
        if (cmdsPath != null) File(cmdsPath).deleteSync();
      } catch (_) {}
      job.progress = 1.0;
      return;
    }

    // 3) FFmpeg 合成(进度由 statistics 回调上报)
    job
      ..stage = '合成中…'
      ..progress = 0.40;
    final outPath = '${workDir.path}/$stamp.mp4';

    // 提速要点:
    //   * 全局多线程:scale/transpose/overlay 都支持切片并行,-filter_threads
    //     让它们真正用满多核;
    //   * 缩放用 bilinear(原来是 bicubic):1080p 逐帧上采样便宜一大截;
    //   * 编码走硬件(见上面 1.6 步)。
    String buildCmd(String stab, String enc) {
      if (seqDir != null) {
        // 输入0=原始视频(先旋转/稳定再烧字幕),输入1=曲线动画序列(1帧/秒)
        return '-y -filter_threads $threads -filter_complex_threads $threads '
            '-i "${raw.path}" -framerate 1 -i "$seqDir/curve_%04d.png" '
            '-filter_complex '
            '"[0:v]$vfPrefix${stab}ass=$assPath[base];'
            '[1:v]format=rgba,fps=30[ov];'
            '[base][ov]overlay=x=$curX:y=$curY:eof_action=repeat[outv]" '
            '-map "[outv]" -map 0:a? '
            '$enc -c:a aac -b:a 128k "$outPath"';
      }
      return '-y -filter_threads $threads '
          '-i "${raw.path}" -vf "$vfPrefix${stab}ass=$assPath" '
          '$enc -c:a aac -b:a 128k "$outPath"';
    }

    // 尝试顺序:
    //   ① sendcmd 逐帧位移(首选,分辨率最高)
    //   ② 表达式位移(退路;若该 ffmpeg 包没编入 sendcmd 就走这里)
    //   ③ 软件编码重试(硬件编码不可用时)
    //   ④ 完全不加稳定(至少保证能出片)
    job.stage = '合成中…';
    var ok = false;
    var stabApplied = false;
    if (stabPrefix.isNotEmpty && _sendcmdOk) {
      ok = await _runFfmpeg(buildCmd(stabPrefix, encHw), durationSec, job);
      stabApplied = ok;
      if (!ok) {
        _sendcmdOk = false;
        job
          ..stage = '换用兼容稳定方案重试…'
          ..progress = 0.40;
      }
    }
    if (!ok) {
      final st = stabPrefixExpr;
      ok = await _runFfmpeg(buildCmd(st, encHw), durationSec, job);
      stabApplied = ok && st.isNotEmpty;
      if (!ok) {
        // 硬件编码失败(该 ffmpeg 包未编入硬件编码器等)→ 退回软件编码
        job
          ..stage = '改用软件编码重试…'
          ..progress = 0.40
          ..encoderText = '软件编码 libx264(硬件编码不可用)';
        ok = await _runFfmpeg(buildCmd(st, encSw), durationSec, job);
        stabApplied = ok && st.isNotEmpty;
      }
    }
    if (!ok && (stabPrefix.isNotEmpty || stabPrefixExpr.isNotEmpty)) {
      job
        ..stage = '稳定处理失败,改为普通合成…'
        ..progress = 0.40;
      ok = await _runFfmpeg(buildCmd('', encSw), durationSec, job);
      stabApplied = false;
    }
    if (!ok) throw Exception('FFmpeg 合成失败');
    if (mounted && !stabApplied && stabGyro.isNotEmpty) {
      setState(() => _hint = '运动稳定未能应用,已导出普通视频');
    }

    // 4) 保存到录像目录 + 清理临时文件
    job
      ..stage = '保存中…'
      ..progress = 0.99;
    await File(outPath).copy(saved);
    try {
      File(assPath).deleteSync();
      if (cmdsPath != null) File(cmdsPath).deleteSync();
      if (seqDir != null) {
        Directory(seqDir).deleteSync(recursive: true);
      }
      File(outPath).deleteSync();
      File(raw.path).deleteSync();
    } catch (_) {}
    job.progress = 1.0;
  }

  // ─────────────── 编码器选择(渲染提速)───────────────

  /// 本平台该用的硬件 H.264 编码器名
  static String get _hwEncoderName =>
      Platform.isIOS ? 'h264_videotoolbox' : 'h264_mediacodec';

  /// 画面识别的诊断文字
  String get logTrack =>
      '画面锁定($_trackEngine) $_trackOkFrames/$_trackFrames 帧可信';

  /// 上一次用的跟踪器(Vision / SAD)
  String _trackEngine = '-';

  /// sendcmd 是否可用(首次失败后本次运行不再尝试,避免每次导出都白跑一遍)
  bool _sendcmdOk = true;

  /// 视频编码参数。
  /// 默认用硬件编码器(iPhone 的 VideoToolbox / 安卓的 MediaCodec,由 SoC 里
  /// 的专用编码单元完成,通常比 libx264 快 5~10 倍);不支持时由调用处
  /// 自动回退到 forceSw 的软件编码。
  /// 注:不再预先用 `ffmpeg -encoders` 探测 —— 那要先跑一个 ffmpeg 进程,
  /// 会让界面上的编码器提示晚好几秒才出现,而且探测本身也可能失败。
  String _videoEncArgs(int w, int h, {bool forceSw = false}) {
    // 码率按像素数给:1080p30 ≈ 7.5 Mbps,画质与原来 crf22 相当
    final kbps = (w * h * 30 * 0.12 / 1000).round().clamp(4000, 20000);
    if (!forceSw) {
      final hw = _hwEncoderName;
      final extra = hw == 'h264_videotoolbox' ? ' -allow_sw 1' : '';
      return '-c:v $hw -b:v ${kbps}k -maxrate ${kbps * 2}k '
          '-bufsize ${kbps * 4}k$extra';
    }
    return '-c:v libx264 -preset ultrafast -crf 23 -threads 0';
  }

  /// 多遍识别:每隔 5 秒抽一帧做一次候选识别,
  ///   * 用户没选目标 → 在 5 秒处自动选一个"文字/数字"候选当参考;
  ///   * 以后每 10 秒用外观相似度(NCC)找一次"同一个目标",找到就作为锚点,
  ///     让跟踪器在那个时间点重新初始化 —— 长视频里跟踪器难免慢慢飘走,
  ///     这就是把它拉回来的机制。
  Future<({Rect? autoBox, List<List<double>> anchors, String info})?>
  _detectCheckpoints({
    required String rawPath,
    required String vfPrefix,
    required Rect? refBox,
    required int trackW,
    required int trackH,
    required Directory workDir,
    required int stamp,
    required RenderJob job,
  }) async {
    if (!VisionTracker.isSupported) return null;
    // 按 0.1 秒(10fps)抽帧,和跟踪用同一套分辨率 —— 这样每个跟踪帧
    // 都有一份文字候选,目标的中心位置就是 0.1 秒级的。
    final cw = trackW;
    var ch = trackH;
    if (ch < 8) ch = 8;
    final path = '${workDir.path}/${stamp}_check.gray';
    final ok = await _runFfmpeg(
      '-y -loglevel error -i "$rawPath" '
      '-vf "${vfPrefix}fps=$kTrackFps,scale=$cw:$ch,format=gray" '
      '-f rawvideo -pix_fmt gray "$path"',
      0,
      job,
    );
    final f = File(path);
    if (!ok || !f.existsSync()) return null;
    final bytes = await f.readAsBytes();
    try {
      f.deleteSync();
    } catch (_) {}
    final fb = cw * ch;
    final count = bytes.length ~/ fb;
    if (count < 2) return null;
    Uint8List fr(int i) =>
        Uint8List.view(bytes.buffer, bytes.offsetInBytes + i * fb, fb);

    // 参考目标:优先用户选的框;否则在 5 秒那一帧自动找"文字/数字"
    var ref = refBox;
    var refIdx = 0;
    Rect? autoBox;
    if (ref == null) {
      // 开头没选目标:在 5 秒处(第 50 帧)找文字/数字候选当参考
      final idx5 = (5 * kTrackFps).round().clamp(0, count - 1);
      final cands = await VisionTracker.detectTargets(
        bytes: fr(idx5),
        w: cw,
        h: ch,
        textOnly: true,
      );
      TargetCandidate? pick;
      for (final c in cands) {
        if (c.label.startsWith('文字')) {
          pick = c;
          break;
        }
      }
      if (pick == null && cands.isNotEmpty) pick = cands.first;
      if (pick == null) return null;
      ref = pick.box;
      refIdx = idx5;
      autoBox = pick.box;
    }
    // 取样块的物理边长:取参考框长边的 1.25 倍,且不小于 24px
    final patchPx = math.max(
      24.0,
      math.max(ref.width * cw, ref.height * ch) * 1.25,
    );
    var refPatch = TargetTracker.patchCentered(
      bytes,
      cw,
      ch,
      (ref.left + ref.width / 2) * cw,
      (ref.top + ref.height / 2) * ch,
      patchPx,
    );

    final anchors = <List<double>>[];
    final refAr = ref.width / ref.height;
    var ckFrames = 0; // 有候选的帧数
    var bestSeen = 0.0; // 全程最高相似度(诊断用)
    for (var i = 0; i < count; i++) {
      if (i == refIdx) continue;
      // 每一帧都做文字候选(0.1 秒一次),命中就成为锚点:
      // 跟踪器每个锚点都会重新初始化,于是目标位置就是 0.1 秒级的
      // "文字框中心",而不是靠累计跟踪漂出来的。
      final t = i / kTrackFps;
      final frame = fr(i);
      final cands = await VisionTracker.detectTargets(
        bytes: frame,
        w: cw,
        h: ch,
        textOnly: true,
      );
      if (cands.isNotEmpty) ckFrames++;
      TargetCandidate? best;
      var bestScore = 0.55; // 相似度阈值:低于这个值宁可不用锚点
      for (final c in cands) {
        // 长宽比差太多就不是同一个东西
        if ((math.log(refAr / (c.box.width / c.box.height))).abs() > 0.35) {
          continue;
        }
        final p = TargetTracker.patchCentered(
          frame,
          cw,
          ch,
          (c.box.left + c.box.width / 2) * cw,
          (c.box.top + c.box.height / 2) * ch,
          patchPx,
        );
        final s = TargetTracker.ncc(refPatch, p);
        if (s > bestSeen) bestSeen = s;
        if (s > bestScore) {
          bestScore = s;
          best = c;
        }
      }
      if (best != null) {
        anchors.add(<double>[
          t * kTrackFps,
          best.box.left * trackW,
          best.box.top * trackH,
          best.box.width * trackW,
          best.box.height * trackH,
        ]);
        ref = best.box;
        refPatch = TargetTracker.patchCentered(
          frame,
          cw,
          ch,
          (ref.left + ref.width / 2) * cw,
          (ref.top + ref.height / 2) * ch,
          patchPx,
        );
      }
    }
    return (
      autoBox: autoBox,
      anchors: anchors,
      info:
          '逐帧候选 $count 帧 · 命中 $ckFrames · '
          '最高相似 ${bestSeen.toStringAsFixed(2)} · 锚点 ${anchors.length}',
    );
  }

  /// 陀螺仪 ↔ 画面 自动对齐:求**时间偏移**与**焦距尺度**。
  ///
  /// 为什么必须用"画面识别"的轨迹来标定,而不能用跟踪器的输出:
  /// 跟踪器每帧的搜索窗口是被"陀螺仪先验"约束住的(±3px)。拿一个被先验
  /// 约束出来的轨迹去拟合先验,结果必然是 τ=0、尺度=1 —— 自我实现,毫无信息。
  /// 而每 0.1 秒的文字候选重检测只看画面、不看陀螺仪,是**绝对测量**,
  /// 才能反过来检验陀螺仪。
  ///
  /// 做法:把"视觉测出的目标位移"与"陀螺仪算出的位移"做互相关求时间偏移,
  /// 再用最小二乘拟合两者幅度比 —— 比值就是焦距的修正系数
  /// (陀螺仪测角度、视觉测像素,两者相除等于用拍摄过程本身做标定)。
  ({double tau, double scale, double corr, String info})? _alignGyroToVision({
    required List<List<double>> anchors,
    required StabPlan plan,
    required int trackW,
    required int outW,
  }) {
    if (anchors.length < 8 || plan.dx.length < 4) return null;
    final k = outW / trackW; // 跟踪帧像素 → 成片像素
    final vs = <List<double>>[];
    double? x0, y0;
    for (final a in anchors) {
      if (a.length < 5) continue;
      final t = a[0] / kTrackFps;
      final cx = (a[1] + a[3] / 2) * k;
      final cy = (a[2] + a[4] / 2) * k;
      x0 ??= cx;
      y0 ??= cy;
      vs.add(<double>[t, cx - x0, cy - y0]);
    }
    if (vs.length < 8) return null;
    // 陀螺仪:目标在原始帧里的位移 = -D(画面内容移动了 -D)
    final gx = plan.dx.map((e) => <double>[e[0], -e[1]]).toList();

    var bestTau = 0.0;
    var bestR = -2.0;
    for (var i = -50; i <= 50; i++) {
      final tau = i * 0.01; // ±0.5 秒,10ms 步进
      final n = vs.length;
      var sa = 0.0, sb = 0.0, sab = 0.0, saa = 0.0, sbb = 0.0;
      for (final v in vs) {
        final a = v[1];
        final b = TargetTracker.interp(gx, v[0] + tau);
        sa += a;
        sb += b;
        sab += a * b;
        saa += a * a;
        sbb += b * b;
      }
      final num = n * sab - sa * sb;
      final den = math.sqrt((n * saa - sa * sa) * (n * sbb - sb * sb));
      final r = den < 1e-9 ? 0.0 : num / den;
      if (r > bestR) {
        bestR = r;
        bestTau = tau;
      }
    }
    // 尺度:最小二乘 V ≈ s·G(负值说明方向反了,是重要发现)
    var sgv = 0.0, sgg = 0.0;
    for (final v in vs) {
      final b = TargetTracker.interp(gx, v[0] + bestTau);
      sgv += v[1] * b;
      sgg += b * b;
    }
    final scale = sgg < 1e-6 ? 1.0 : (sgv / sgg).clamp(0.25, 4.0);
    return (
      tau: bestTau,
      scale: scale,
      corr: bestR,
      info:
          '对齐 τ=${(bestTau * 1000).round()}ms · 相关 ${bestR.toStringAsFixed(2)}'
          ' · 焦距×${scale.toStringAsFixed(2)}',
    );
  }

  /// 画面识别:把成片抽成低分辨率灰度帧,在独立 isolate 里用 SAD 块匹配
  /// 逐帧跟踪用户框住的目标,返回"把目标拉到画面正中"所需的画面位移曲线
  /// [t秒, vx, vy](成片像素)。
  ///
  /// 注意抽帧一定要带上 [vfPrefix](transpose):跟踪用的画面朝向必须和成片一致,
  /// 否则框的坐标会整体转 90°。
  Future<List<List<double>>?> _trackTargetPath({
    required String rawPath,
    required String vfPrefix,
    required int outW,
    required int outH,
    required Rect box,
    required Directory workDir,
    required int stamp,
    required RenderJob job,
    List<double>? priorDx,
    List<double>? priorDy,
    List<List<double>>? anchors,
  }) async {
    final tw = kTrackWidth;
    var th = ((tw * outH) / outW / 2).round() * 2;
    if (th < 8) th = 8;
    final grayPath = '${workDir.path}/${stamp}_track.gray';
    final ok = await _runFfmpeg(
      '-y -loglevel error -i "$rawPath" '
      '-vf "${vfPrefix}fps=$kTrackFps,scale=$tw:$th,format=gray" '
      '-f rawvideo -pix_fmt gray "$grayPath"',
      0, // 传 0 表示不上报进度,避免污染主进度条
      job,
    );
    final f = File(grayPath);
    if (!ok || !f.existsSync()) {
      try {
        f.deleteSync();
      } catch (_) {}
      return null;
    }
    final bytes = await f.readAsBytes();
    final frameBytes = tw * th;
    final frames = bytes.length ~/ frameBytes;
    if (frames < 4) {
      try {
        f.deleteSync();
      } catch (_) {}
      return null;
    }

    // 用户的框(归一化) → 跟踪帧像素
    final bw = (box.width * tw).round().clamp(6, tw);
    final bh = (box.height * th).round().clamp(6, th);
    final bx = (box.left * tw).round().clamp(0, tw - bw);
    final by = (box.top * th).round().clamp(0, th - bh);

    // 跟踪器选择:
    //   * iOS → 系统 Vision 框架(VNTrackObjectRequest):硬件/系统级实现,
    //     自带尺度与外观自适应,比手写的块匹配稳得多,也不引入第三方依赖。
    //   * 其他平台 → Dart 的 SAD 块匹配(独立 isolate,不卡界面)。
    List<TrackPoint>? pts;
    if (VisionTracker.isSupported) {
      final v = await VisionTracker.trackGray(
        path: grayPath,
        w: tw,
        h: th,
        frames: frames,
        fps: kTrackFps,
        boxX: bx.toDouble(),
        boxY: by.toDouble(),
        boxW: bw.toDouble(),
        boxH: bh.toDouble(),
        anchors: anchors,
      );
      if (v != null) {
        pts = v
            .map(
              (e) => TrackPoint(e[0], e[1], e[2], (1 - e[3]) * 100, e[4] > 0.5),
            )
            .toList();
        _trackEngine = 'Vision';
      }
    }
    if (pts == null) {
      final raw = await Isolate.run(() {
        final r = TargetTracker.track(
          gray: bytes,
          w: tw,
          h: th,
          frames: frames,
          boxX: bx,
          boxY: by,
          boxW: bw,
          boxH: bh,
          fps: kTrackFps,
          priorDx: priorDx,
          priorDy: priorDy,
          anchors: anchors,
        );
        return r
            .map((p) => <double>[p.t, p.cx, p.cy, p.mad, p.ok ? 1 : 0])
            .toList();
      });
      pts = raw
          .map((e) => TrackPoint(e[0], e[1], e[2], e[3], e[4] > 0.5))
          .toList();
      _trackEngine = 'SAD';
    }
    _trackFrames = pts.length;
    _trackOkFrames = pts.where((p) => p.ok).length;
    try {
      f.deleteSync();
    } catch (_) {}
    // 可信帧太少就当作跟踪失败,退回纯陀螺仪
    if (pts.length < 4 || _trackOkFrames < pts.length * 0.5) return null;
    return TargetTracker.lockCurve(
      pts: pts,
      frameW: outW.toDouble(),
      frameH: outH.toDouble(),
      trackW: tw,
      trackH: th,
    );
  }

  /// 对曲线做对称滑动平均(零相位低通)
  List<List<double>> _lowPassCurve(
    List<List<double>> curve,
    double winSec,
    double hz,
  ) {
    if (curve.length < 3) return curve;
    final half = math.max(1, (winSec * hz / 2).round());
    final out = <List<double>>[];
    for (var i = 0; i < curve.length; i++) {
      var s = 0.0;
      var c = 0;
      for (var k = -half; k <= half; k++) {
        final j = i + k;
        if (j < 0 || j >= curve.length) continue;
        s += curve[j][1];
        c++;
      }
      out.add(<double>[curve[i][0], s / c]);
    }
    return out;
  }

  /// 取曲线的高频分量(原曲线 - 低频)。画面识别只有 10fps,看不到高频抖动,
  /// 所以低频交给它、高频留给陀螺仪。
  List<double> _highPass(List<List<double>> curve, double winSec, double hz) {
    final n = curve.length;
    final half = math.max(1, (winSec * hz / 2).round());
    final out = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      var s = 0.0;
      var c = 0;
      for (var k = -half; k <= half; k++) {
        final j = i + k;
        if (j < 0 || j >= n) continue;
        s += curve[j][1];
        c++;
      }
      out[i] = curve[i][1] - (c > 0 ? s / c : curve[i][1]);
    }
    return out;
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
          job.speedNow = speed;
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
          .where(
            (f) =>
                f.path.toLowerCase().endsWith('.mp4') ||
                f.path.toLowerCase().endsWith('.mov'),
          )
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
                    // 缓存清理:导出过程的抽帧文件可能有几百 MB,而且导出失败时
                    // 不会自动删除,必须给用户一个手动清理的入口。
                    FutureBuilder<int>(
                      future: _cacheBytes(),
                      builder: (_, snap) {
                        final mb = ((snap.data ?? 0) / 1048576);
                        return TextButton.icon(
                          onPressed: () async {
                            final freed = await _purgeWork();
                            if (ctx.mounted) Navigator.pop(ctx);
                            if (mounted && freed > 0) {
                              setState(
                                () => _hint =
                                    '已清理缓存,释放 '
                                    '${(freed / 1048576).toStringAsFixed(1)} MB',
                              );
                            }
                          },
                          icon: const Icon(
                            Icons.cleaning_services,
                            size: 16,
                            color: Colors.white70,
                          ),
                          label: Text(
                            mb < 0.05
                                ? '清理缓存'
                                : '清理缓存 ${mb.toStringAsFixed(0)}MB',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        );
                      },
                    ),
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
    // 已经在稳定中:立刻把固定裁切放大就位,别等第一个样本
    if (_stabRunning && mounted) {
      setState(() {
        _stabAutoZoom = GyroStabilizer.zoomForMargin(
          GyroStabilizer.marginFor(_stabStrength),
        );
      });
    }
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

          // 角修正 → 像素位移(按焦距换算),并硬限制在固定裁切余量内
          final fov = _stabFov;
          final wPx = _previewSize.width <= 0 ? 1080.0 : _previewSize.width;
          final hPx = _previewSize.height <= 0 ? 1920.0 : _previewSize.height;
          final margin = GyroStabilizer.marginFor(_stabStrength);
          final shifts = _onlineStab.shifts(
            wPx,
            hPx,
            fov,
            _stabStrength,
            margin,
          );
          _stabOffsetX = shifts[0];
          _stabOffsetY = shifts[1];
          _stabCorrDeg = _onlineStab.corrX * 180 / math.pi;
          // 固定裁切放大:只由"稳定强度"决定,不随抖动幅度变化
          // (否则大幅晃一下就会永久顶到镜头最大倍数)
          _stabAutoZoom = GyroStabilizer.zoomForMargin(margin);

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
                            style: TextStyle(
                              color: Colors.white38,
                              fontSize: 11,
                            ),
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
                        const Divider(color: Colors.white12, height: 1),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _lockEnabled,
                          activeThumbColor: Colors.redAccent,
                          title: const Text(
                            '画面识别锁定',
                            style: TextStyle(color: Colors.white, fontSize: 15),
                          ),
                          subtitle: Text(
                            !_lockEnabled
                                ? '关闭(需先开启运动稳定并点开始稳定)'
                                : (_lockBox == null
                                      ? '请在预览里单指拖拽,画框圈住目标'
                                      : '已锁定目标框 · 导出时钉在画面正中'),
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 11,
                            ),
                          ),
                          onChanged: (v) {
                            setState(() {
                              _lockEnabled = v;
                              if (!v) {
                                _lockBox = null;
                                _candidates = const [];
                                _dragFrom = null;
                                _dragTo = null;
                              }
                            });
                            setSheetState(() {});
                            if (v) {
                              // 打开锁定就直接进实时识别,省一次点击
                              Navigator.pop(ctx);
                              _setLiveDetect(true);
                            }
                          },
                        ),
                        if (_lockEnabled)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _liveDetect
                                        ? '实时识别中 · 每 0.1 秒刷新(${_candidates.length} 个候选)'
                                        : (_detecting
                                              ? '正在识别候选目标…'
                                              : (_trackFrames > 0
                                                    ? '上次识别:$logTrack'
                                                    : (_candidates.isNotEmpty
                                                          ? '识别到 ${_candidates.length} 个候选:点预览里的青色框'
                                                          : (_lockBox == null
                                                                ? '打开实时识别自动找,或直接拖拽画框'
                                                                : '目标框已就绪(双指仍可缩放)')))),
                                    style: const TextStyle(
                                      color: Colors.white38,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                                if (_lockBox != null)
                                  TextButton(
                                    onPressed: () {
                                      setState(() => _lockBox = null);
                                      setSheetState(() {});
                                    },
                                    child: const Text(
                                      '清除框',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                  ),
                                const Text(
                                  '实时',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                  ),
                                ),
                                Switch(
                                  value: _liveDetect,
                                  activeThumbColor: Colors.redAccent,
                                  onChanged: (v) {
                                    setSheetState(() {});
                                    _setLiveDetect(v);
                                  },
                                ),
                              ],
                            ),
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
                                  '① 切到最广 → ② 点开始稳定 → ③ 正常拍摄'
                                  '(裁切放大固定,抖得再大也不会变)',
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
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(width: 10),
                              ...[(0.6, '柔和'), (1.0, '标准'), (1.6, '强')].map((
                                o,
                              ) {
                                final sel = (_stabStrength - o.$1).abs() < 0.01;
                                return Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: ChoiceChip(
                                    label: Text(
                                      o.$2,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: sel
                                            ? Colors.black
                                            : Colors.white,
                                      ),
                                    ),
                                    selected: sel,
                                    selectedColor: Colors.redAccent,
                                    backgroundColor: Colors.black,
                                    side: BorderSide(
                                      color: sel
                                          ? Colors.redAccent
                                          : Colors.white24,
                                    ),
                                    onSelected: (_) => setSheetState(
                                      () => _stabStrength = o.$1,
                                    ),
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
                              label: Text(
                                '切到最广 ${_minZoom.toStringAsFixed(1)}x',
                              ),
                            ),
                          ),
                        ] else ...[
                          const SizedBox(height: 12),
                          const Text(
                            '开启后可:双指缩放画面留出余量、实时记录陀螺仪并补偿画面位移。',
                            style: TextStyle(
                              color: Colors.white38,
                              fontSize: 11,
                            ),
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
                                  // 立刻生效:裁切放大这一帧就位,不等第一个陀螺仪样本
                                  // (否则会先空等几秒才看到画面被裁切)
                                  _stabAutoZoom = GyroStabilizer.zoomForMargin(
                                    GyroStabilizer.marginFor(_stabStrength),
                                  );
                                  _stabCorrDeg = 0;
                                  _stabLog.clear();
                                  _stabLast = DateTime.now();
                                  _stabRunning = true;
                                }
                              });
                              // 确保陀螺仪订阅此刻就是活的,避免几秒空档
                              if (_stabRunning) _startGyroSession();
                              setSheetState(() {});
                              if (_stabRunning) Navigator.pop(ctx);
                            },
                            icon: Icon(
                              _stabRunning ? Icons.stop : Icons.play_arrow,
                            ),
                            label: Text(_stabRunning ? '停止稳定(并关闭设置)' : '开始稳定'),
                          ),
                        ),
                        const SizedBox(height: 6),
                        ValueListenableBuilder<int>(
                          valueListenable: _stabTick,
                          builder: (context3, _, _) => Text(
                            '陀螺仪:${_gyroCount == 0 ? "无数据(请检查权限)" : "${_gyroHz.toStringAsFixed(0)} Hz · gx=${_gxNow.toStringAsFixed(2)}"}'
                            '\n角修正 ${_stabCorrDeg.toStringAsFixed(1)}° · 位移 '
                            '${_stabOffsetX.toStringAsFixed(0)},${_stabOffsetY.toStringAsFixed(0)}px'
                            ' · 裁切放大 ${_stabAutoZoom.toStringAsFixed(2)}x'
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
                // 单击 = 选中候选目标(自动识别出来的青色框);
                // 单指拖拽 = 手动画框;双指 = 缩放画面留出余量。
                onTapUp: (!_recording && !_busy && _lockEnabled)
                    ? (d) => _tryPickCandidate(d.localPosition)
                    : null,
                // 注意:录像/处理中不接管手势,否则会抢走录像按钮的点击
                onScaleStart:
                    (!_recording &&
                        !_busy &&
                        (_stabilizeEnabled || _lockEnabled))
                    ? (d) {
                        if (d.pointerCount >= 2) {
                          _dragging = false;
                          _zoomAtGestureStart = _zoom;
                        } else if (_lockEnabled) {
                          _dragging = true;
                          _dragFrom = d.localFocalPoint;
                          _dragTo = d.localFocalPoint;
                          setState(() {});
                        }
                      }
                    : null,
                onScaleUpdate:
                    (!_recording &&
                        !_busy &&
                        (_stabilizeEnabled || _lockEnabled))
                    ? (d) async {
                        if (_dragging) {
                          setState(() => _dragTo = d.localFocalPoint);
                          return;
                        }
                        if (!_stabilizeEnabled) return;
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
                onScaleEnd: (!_recording && !_busy && _lockEnabled)
                    ? (_) {
                        if (_dragging) {
                          _dragging = false;
                          _commitLockBox();
                        }
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
                      _imgMap = [iw, ih, dx, dy];
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
                    _imgMap = [iw, ih, dx, dy];
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

          // ── 锁定框(画面识别目标)+ 候选目标 + 画面正中十字 ──
          if (cam != null && cam.value.isInitialized && _lockEnabled)
            Positioned.fill(
              child: IgnorePointer(
                child: Builder(
                  builder: (_) {
                    final r = _lockBoxScreen;
                    final cands = <(Rect, String)>[];
                    for (final c in _candidates) {
                      cands.add((_imageRectToScreen(c.box), c.label));
                    }
                    return CustomPaint(
                      painter: _LockBoxPainter(r, _stabRunning, cands),
                      size: Size.infinite,
                    );
                  },
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
    _liveTimer?.cancel();
    _liveTimer = null;
    try {
      _cam?.stopImageStream();
    } catch (_) {}
    _timer.stop();
    _stopGyroSession();
    _stabTick.dispose();
    _cam?.dispose();
    super.dispose();
  }
}

/// 锁定框画笔:四角括线 + 画面正中十字。
/// 十字表示"目标会被钉在这个位置",框表示"要锁的是这个目标"。
class _LockBoxPainter extends CustomPainter {
  final Rect? rect;
  final bool running;

  /// 候选目标(屏幕矩形 + 标签),点一下即可锁定
  final List<(Rect, String)> candidates;
  _LockBoxPainter(this.rect, this.running, [this.candidates = const []]);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    // 画面正中十字(锁定目标会被移动到这里)
    final cross = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = running ? const Color(0xFFFF3B30) : const Color(0x88FF3B30);
    const arm = 12.0;
    canvas.drawLine(
      center - const Offset(arm, 0),
      center + const Offset(arm, 0),
      cross,
    );
    canvas.drawLine(
      center - const Offset(0, arm),
      center + const Offset(0, arm),
      cross,
    );

    // 候选目标:青色细框 + 序号角标
    for (var i = 0; i < candidates.length; i++) {
      final (r, label) = candidates[i];
      canvas.drawRRect(
        RRect.fromRectAndRadius(r, const Radius.circular(3)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0xFF4DD0E1),
      );
      final tag = '${i + 1} $label';
      final tp = TextPainter(
        text: TextSpan(
          text: tag,
          style: const TextStyle(
            color: Colors.black,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final bg = Rect.fromLTWH(
        r.left,
        (r.top - tp.height - 4).clamp(0.0, size.height),
        tp.width + 8,
        tp.height + 4,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(bg, const Radius.circular(3)),
        Paint()..color = const Color(0xFF4DD0E1),
      );
      tp.paint(canvas, Offset(bg.left + 4, bg.top + 2));
    }

    final r = rect;
    if (r == null) return;
    canvas.drawRect(
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = const Color(0x99FF3B30),
    );
    final thick = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFFFF3B30);
    final len = math.min(r.width, r.height) * 0.22;
    void corner(Offset o, double sx, double sy) {
      canvas.drawLine(o, o + Offset(len * sx, 0), thick);
      canvas.drawLine(o, o + Offset(0, len * sy), thick);
    }

    corner(r.topLeft, 1, 1);
    corner(r.topRight, -1, 1);
    corner(r.bottomLeft, 1, -1);
    corner(r.bottomRight, -1, -1);
  }

  @override
  bool shouldRepaint(covariant _LockBoxPainter old) =>
      old.rect != rect ||
      old.running != running ||
      old.candidates.length != candidates.length;
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
