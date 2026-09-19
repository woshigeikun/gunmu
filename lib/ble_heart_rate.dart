import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// 扫描到的可连接设备信息
class BleDeviceInfo {
  final String remoteId;
  final String name;
  final int rssi;

  /// 是否在广播里声明了标准心率服务(0x180D),即"明确支持心率广播"
  final bool advertisesHeartRate;

  const BleDeviceInfo({
    required this.remoteId,
    required this.name,
    required this.rssi,
    required this.advertisesHeartRate,
  });

  String get displayName => name.isEmpty ? '未命名设备' : name;
}

/// 通用 BLE 心率读取模块。
/// 不限定品牌:任何提供标准心率服务(0x180D)+ 心率测量特征(0x2A37)的设备
/// (手环 / 手表 / 心率带 / 臂带)均可连接并读取心率。
class BleHeartRate {
  static final hrService = Guid('180D');
  static final hrChar = Guid('2A37');

  BluetoothDevice? _device;
  StreamSubscription? _notifySub;
  StreamSubscription? _scanSub;
  StreamSubscription? _connSub;

  // 扫描发现(remoteId 为键)
  final Map<String, BluetoothDevice> _devices = {};
  final Map<String, BleDeviceInfo> _found = {};

  int _currentBpm = 0;
  int get currentBpm => _currentBpm;

  /// 每次收到新心率时推送(约每秒 1 次)
  final _bpmController = StreamController<int>.broadcast();
  Stream<int> get bpmStream => _bpmController.stream;

  /// 扫描到的设备列表(实时更新)
  final _listController = StreamController<List<BleDeviceInfo>>.broadcast();
  Stream<List<BleDeviceInfo>> get deviceList => _listController.stream;

  /// 当前已发现的设备(立即取值)
  List<BleDeviceInfo> get devicesNow => _sorted();

  bool _connected = false;
  bool get isConnected => _connected;

  String _connectedName = '';
  String get connectedName => _connectedName;

  /// 已连接的设备名(用于界面显示)
  List<BleDeviceInfo> _sorted() {
    final list = _found.values.toList();
    list.sort((a, b) {
      // 明确支持心率广播的排前面,其次按信号强度
      if (a.advertisesHeartRate != b.advertisesHeartRate) {
        return a.advertisesHeartRate ? -1 : 1;
      }
      return b.rssi.compareTo(a.rssi);
    });
    return list;
  }

  void _emit() {
    if (!_listController.isClosed) _listController.add(_sorted());
  }

  /// 扫描设备。
  /// 1) 先按标准心率服务过滤扫一轮 —— 直接标出"支持心率广播"的设备;
  /// 2) 再全量扫一轮 —— 列出附近所有可连设备(含只在连接后才暴露 180D 的手环)。
  Future<void> scan({
    Duration hrScan = const Duration(seconds: 4),
    Duration allScan = const Duration(seconds: 6),
  }) async {
    _found.clear();
    _devices.clear();
    _emit();
    await stopScan();

    // ① 只扫广播标准心率服务的设备(这些设备一定支持心率广播)
    _scanSub = FlutterBluePlus.scanResults.listen(
      (rs) => _absorb(rs, forceHeartRate: true),
    );
    try {
      await FlutterBluePlus.startScan(
        timeout: hrScan,
        withServices: [hrService],
      );
    } catch (_) {}
    await _scanSub?.cancel();
    _scanSub = null;

    // ② 全量扫描,列出所有设备(手环可能只在连接后才暴露 180D)
    _scanSub = FlutterBluePlus.scanResults.listen(
      (rs) => _absorb(rs, forceHeartRate: false),
    );
    try {
      await FlutterBluePlus.startScan(timeout: allScan);
    } catch (_) {}
    await _scanSub?.cancel();
    _scanSub = null;
    _emit();
  }

  void _absorb(List<ScanResult> results, {required bool forceHeartRate}) {
    for (final r in results) {
      final id = r.device.remoteId.str;
      final name = r.device.platformName.isNotEmpty
          ? r.device.platformName
          : r.advertisementData.advName;
      final advHr = r.advertisementData.serviceUuids.any((u) => u == hrService);
      final prev = _found[id];
      _devices[id] = r.device;
      _found[id] = BleDeviceInfo(
        remoteId: id,
        name: name.isNotEmpty ? name : (prev?.name ?? ''),
        rssi: r.rssi,
        advertisesHeartRate:
            (prev?.advertisesHeartRate ?? false) || advHr || forceHeartRate,
      );
    }
    _emit();
  }

  Future<void> stopScan() async {
    try {
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }
    } catch (_) {}
  }

  /// 连接指定设备(remoteId 来自设备列表),并订阅标准心率通知
  Future<void> connectTo(String remoteId) async {
    final target = _devices[remoteId];
    if (target == null) {
      throw Exception('设备已失效,请重新扫描');
    }
    await stopScan();
    await disconnect();

    await target.connect(
      timeout: const Duration(seconds: 15),
      license: License.nonprofit,
    );
    _device = target;

    // 监听断线,及时更新状态
    _connSub = target.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected) {
        _connected = false;
        _currentBpm = 0;
      }
    });

    final services = await target.discoverServices();
    BluetoothService? hrSvc;
    for (final s in services) {
      if (s.uuid == hrService) hrSvc = s;
    }
    if (hrSvc == null) {
      await disconnect();
      throw Exception('该设备没有心率服务(0x180D),可能未开启心率广播');
    }

    BluetoothCharacteristic? hrCh;
    for (final c in hrSvc.characteristics) {
      if (c.uuid == hrChar) hrCh = c;
    }
    if (hrCh == null) {
      await disconnect();
      throw Exception('未找到心率测量特征(0x2A37)');
    }

    await hrCh.setNotifyValue(true);
    _notifySub = hrCh.onValueReceived.listen(_parse);
    _connected = true;
    _connectedName = _found[remoteId]?.displayName ?? '';
  }

  /// 解析 BLE 心率数据包(标准 Heart Rate Measurement 格式)
  void _parse(List<int> b) {
    if (b.isEmpty) return;
    final flags = b[0];
    final isUint16 = (flags & 0x01) == 0x01; // bit0: 0=8位 1=16位
    int bpm = 0;
    if (isUint16 && b.length >= 3) {
      bpm = b[1] | (b[2] << 8);
    } else if (b.length >= 2) {
      bpm = b[1];
    }
    if (bpm > 0 && bpm != _currentBpm) {
      _currentBpm = bpm;
      _bpmController.add(bpm);
    }
  }

  Future<void> disconnect() async {
    await _notifySub?.cancel();
    await _connSub?.cancel();
    await _scanSub?.cancel();
    _notifySub = null;
    _connSub = null;
    _scanSub = null;
    try {
      if (_device != null && _device!.isConnected) {
        await _device!.disconnect();
      }
    } catch (_) {}
    _connected = false;
    _connectedName = '';
    _device = null;
  }

  void dispose() {
    _bpmController.close();
    _listController.close();
  }
}
