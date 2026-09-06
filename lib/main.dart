import 'package:flutter/material.dart';

import 'ble_heart_rate.dart';
import 'camera_page.dart';

void main() {
  runApp(HeartRateCameraApp(ble: BleHeartRate()));
}

class HeartRateCameraApp extends StatefulWidget {
  final BleHeartRate ble;
  const HeartRateCameraApp({super.key, required this.ble});

  @override
  State<HeartRateCameraApp> createState() => _HeartRateCameraAppState();
}

class _HeartRateCameraAppState extends State<HeartRateCameraApp> {
  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    widget.ble.disconnect();
    widget.ble.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '心率相机',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.red, useMaterial3: true),
      // 启动直接进入相机界面;手环连接改为相机页内的半页面板
      home: CameraPage(ble: widget.ble),
    );
  }
}
