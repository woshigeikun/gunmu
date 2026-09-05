import 'package:flutter/material.dart';

import 'ble_heart_rate.dart';
import 'camera_page.dart';

void main() => runApp(const HeartRateCameraApp());

class HeartRateCameraApp extends StatelessWidget {
  const HeartRateCameraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '心率录像',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.red, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

/// 首页:连接手环 -> 显示实时心率 -> 进入相机
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final BleHeartRate _ble = BleHeartRate();
  bool _connecting = false;
  String _status = '未连接手环';

  @override
  void initState() {
    super.initState();
    _ble.bpmStream.listen((_) {
      if (mounted) setState(() {}); // 心率变化时刷新界面
    });
  }

  Future<void> _connect() async {
    setState(() {
      _connecting = true;
      _status = '正在扫描手环…(约 12 秒)';
    });
    try {
      await _ble.connect();
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _status = '已连接,心率 ${_ble.currentBpm} bpm';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _status = '连接失败: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.favorite, color: Colors.red, size: 56),
                const SizedBox(height: 12),
                Text(
                  _status,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 8),
                if (_ble.isConnected)
                  Text(
                    '${_ble.currentBpm}',
                    style: const TextStyle(
                      fontSize: 72,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                const SizedBox(height: 32),
                if (!_ble.isConnected)
                  FilledButton.icon(
                    onPressed: _connecting ? null : _connect,
                    icon: const Icon(Icons.bluetooth_searching),
                    label: Text(_connecting ? '连接中…' : '连接手环'),
                  ),
                if (_ble.isConnected)
                  FilledButton.icon(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => CameraPage(ble: _ble),
                        ),
                      );
                    },
                    icon: const Icon(Icons.videocam),
                    label: const Text('开始录像'),
                  ),
                const SizedBox(height: 24),
                Text(
                  '提示:录像前先在小米运动健康 App 中开启手环"心率广播"',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey[600], fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _ble.disconnect();
    _ble.dispose();
    super.dispose();
  }
}
