import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// 小米手环心率读取模块(标准 BLE 0x180D / 2A37)
class BleHeartRate {
  static final hrService = Guid('180D');
  static final hrChar = Guid('2A37');

  BluetoothDevice? _device;
  StreamSubscription? _notifySub;
  StreamSubscription? _scanSub;

  int _currentBpm = 0;
  int get currentBpm => _currentBpm;

  /// 每次收到新心率时推送(约每秒 1 次)
  final _bpmController = StreamController<int>.broadcast();
  Stream<int> get bpmStream => _bpmController.stream;

  bool _connected = false;
  bool get isConnected => _connected;

  /// 连接手环:全量扫描 -> 按名字找小米设备 -> 找 180D 服务
  Future<void> connect() async {
    // 1) 全量扫描 12 秒,期间持续收集发现到的设备
    final found = <BluetoothDevice>[];
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        if (!found.contains(r.device)) found.add(r.device);
      }
    });
    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 12));
    } finally {
      await _scanSub?.cancel();
      _scanSub = null;
    }

    // 2) 按名字挑小米手环(广播里不一定带 180D,所以按名字找)
    BluetoothDevice? target;
    for (final d in found) {
      final name = d.platformName.toLowerCase();
      if (name.contains('xiaomi') ||
          name.contains('mi band') ||
          name.contains('smart band')) {
        target = d;
        break;
      }
    }
    if (target == null) {
      throw Exception('未发现小米手环,请确认已开启"心率广播"且靠近手机');
    }

    // 3) 连接(个人使用,选择 nonprofit 许可)
    await target.connect(
      timeout: const Duration(seconds: 15),
      license: License.nonprofit,
    );
    _device = target;
    _connected = true;

    // 4) 发现服务与特征
    final services = await target.discoverServices();
    BluetoothService? hrSvc;
    for (final s in services) {
      if (s.uuid == hrService) hrSvc = s;
    }
    if (hrSvc == null) {
      throw Exception('该设备上没有心率服务(180D),可能不是标准广播模式');
    }

    BluetoothCharacteristic? hrCh;
    for (final c in hrSvc.characteristics) {
      if (c.uuid == hrChar) hrCh = c;
    }
    if (hrCh == null) throw Exception('未找到心率特征(2A37)');

    // 5) 订阅心率通知
    await hrCh.setNotifyValue(true);
    _notifySub = hrCh.onValueReceived.listen(_parse);
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
    await _scanSub?.cancel();
    _notifySub = null;
    _scanSub = null;
    if (_device != null && _device!.isConnected) {
      await _device!.disconnect();
    }
    _connected = false;
    _device = null;
  }

  void dispose() {
    _bpmController.close();
  }
}
