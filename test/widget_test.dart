// 基础测试:仅验证 BleHeartRate 类基础状态
import 'package:flutter_test/flutter_test.dart';

import 'package:heart_rate_camera/ble_heart_rate.dart';

void main() {
  test('BleHeartRate 初始状态', () {
    final ble = BleHeartRate();
    expect(ble.isConnected, false);
    expect(ble.currentBpm, 0);
  });
}
