import 'dart:io';

import 'package:flutter/services.dart';

/// 一个候选目标(归一化坐标,原点左上)
class TargetCandidate {
  final Rect box;
  final double score;
  final String label;

  const TargetCandidate(this.box, this.score, this.label);
}

/// iOS Vision 目标跟踪 + 候选目标检测(本地插件)。
/// Android 上没有实现,会返回 null / 空列表,由调用方退回 Dart 的 SAD 跟踪
/// 与手动画框。
class VisionTracker {
  static const MethodChannel _ch = MethodChannel('vision_tracker');

  static bool get isSupported => Platform.isIOS;

  /// 实时跟踪事件通道:每帧推回 {'x','y','w','h','c'}(相对预览的 0~1 归一化)
  static const EventChannel _liveCh = EventChannel('vision_tracker/live');
  static Stream<Map<String, double>> get liveStream => _liveCh
      .receiveBroadcastStream()
      .where((e) => e is Map)
      .map(
        (e) => (e as Map).map(
          (k, v) => MapEntry(k.toString(), (v as num).toDouble()),
        ),
      );

  /// 开始"录制中实时跟踪"(ReplayKit 抓屏 + Vision 逐帧跟踪,只回传框坐标)。
  /// [box]:用户框,相对**预览**的 0~1 归一化;
  /// [region]:预览画面在**整屏**里的 0~1 位置 —— 抓屏抓的是整屏,
  ///          需要它才能把框换算过去。
  static Future<bool> startLive({
    required Rect box,
    required Rect region,
  }) async {
    if (!isSupported) return false;
    try {
      await _ch.invokeMethod<void>('startLiveTracking', {
        'box': {'x': box.left, 'y': box.top, 'w': box.width, 'h': box.height},
        'region': {
          'x': region.left,
          'y': region.top,
          'w': region.width,
          'h': region.height,
        },
      });
      return true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 换目标(重新画框)时更新跟踪器的初始观测
  static Future<void> updateLiveBox(Rect box) async {
    if (!isSupported) return;
    try {
      await _ch.invokeMethod<void>('updateLiveBox', {
        'box': {'x': box.left, 'y': box.top, 'w': box.width, 'h': box.height},
      });
    } catch (_) {}
  }

  static Future<void> stopLive() async {
    if (!isSupported) return;
    try {
      await _ch.invokeMethod<void>('stopLiveTracking');
    } catch (_) {}
  }

  /// 列出 Documents 目录里可导入的 YOLO 模型(.mlmodelc / .mlpackage / .mlmodel)
  static Future<List<Map<String, String>>> listYoloModels() async {
    if (!isSupported) return const [];
    try {
      final raw = await _ch.invokeMethod<List<dynamic>>('listYoloModels');
      return (raw ?? const [])
          .whereType<Map>()
          .map((m) => m.map((k, v) => MapEntry(k.toString(), v.toString())))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 加载模型;返回 {'ok':bool,'message':String}
  static Future<Map<String, String>> loadYoloModel(String path) async {
    if (!isSupported) return {'ok': 'false', 'message': '仅 iOS 支持'};
    try {
      final raw = await _ch.invokeMethod<Map<dynamic, dynamic>>(
        'loadYoloModel',
        {'path': path},
      );
      if (raw == null) return {'ok': 'false', 'message': '空返回'};
      return raw.map((k, v) => MapEntry(k.toString(), v.toString()));
    } on PlatformException catch (e) {
      return {'ok': 'false', 'message': e.message ?? '加载失败'};
    } catch (e) {
      return {'ok': 'false', 'message': '$e'};
    }
  }

  /// 在一帧灰度图上跑 YOLO。返回扁平数组,每 6 个值一组:
  /// [x, y, w, h, score, class](归一化,原点左上)。
  static Future<List<double>> detectYolo({
    required Uint8List bytes,
    required int w,
    required int h,
    double threshold = 0.25,
  }) async {
    if (!isSupported) return const [];
    try {
      final raw = await _ch.invokeMethod<List<dynamic>>('detectYolo', {
        'bytes': bytes,
        'w': w,
        'h': h,
        'threshold': threshold,
      });
      return (raw ?? const []).map((e) => (e as num).toDouble()).toList();
    } catch (_) {
      return const [];
    }
  }

  /// 抓屏可行性探针:用 ReplayKit 抓一帧,返回整帧与中心区域的平均亮度。
  /// 目的:验证 iOS 能否通过抓屏拿到**相机预览画面**。
  /// (某些机型上预览层是硬件合成的,抓出来可能是纯黑 → 这条路不通)
  /// 返回 {'w','h','mean','center'};平台不支持或失败返回 null。
  static Future<Map<String, double>?> probeReplay() async {
    if (!isSupported) return null;
    try {
      final raw = await _ch.invokeMethod<Map<dynamic, dynamic>>('probeReplay');
      if (raw == null) return null;
      return raw.map((k, v) => MapEntry(k.toString(), (v as num).toDouble()));
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 在一帧灰度图里找候选目标(文字/数字、醒目区域、矩形)。
  /// [bytes] 是 w*h 的灰度数据;[rotationQuarterTurns] 是顺时针 90° 的圈数,
  /// 用于把传感器方向的画面转成和预览一致的朝向(返回的坐标也随之生效)。
  /// 返回按可信度降序排列的候选(最多 6 个)。
  static Future<List<TargetCandidate>> detectTargets({
    required Uint8List bytes,
    required int w,
    required int h,
    int rotationQuarterTurns = 0,
    bool textOnly = false,
  }) async {
    if (!isSupported) return const [];
    try {
      final raw = await _ch.invokeMethod<List<dynamic>>('detectTargets', {
        'bytes': bytes,
        'w': w,
        'h': h,
        'rotation': rotationQuarterTurns,
        'textOnly': textOnly,
      });
      if (raw == null || raw.isEmpty) return const [];
      const labels = ['文字/数字', '醒目区域', '矩形物体'];
      final out = <TargetCandidate>[];
      for (var i = 0; i + 5 < raw.length; i += 6) {
        final x = (raw[i] as num).toDouble();
        final y = (raw[i + 1] as num).toDouble();
        final bw = (raw[i + 2] as num).toDouble();
        final bh = (raw[i + 3] as num).toDouble();
        final sc = (raw[i + 4] as num).toDouble();
        final kind = (raw[i + 5] as num).toInt();
        out.add(
          TargetCandidate(
            Rect.fromLTWH(x, y, bw, bh),
            sc,
            kind >= 0 && kind < labels.length ? labels[kind] : '目标',
          ),
        );
      }
      return out;
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  /// 在一段连续灰度帧里跟踪一个框选目标。
  ///
  /// [path] 是 rawvideo 灰度序列文件(每帧 w*h 字节,行优先);
  /// 返回每帧 [t秒, 目标中心x, 目标中心y, 置信度, 是否可信];
  /// 失败或平台不支持时返回 null。
  static Future<List<List<double>>?> trackGray({
    required String path,
    required int w,
    required int h,
    required int frames,
    required double fps,
    required double boxX,
    required double boxY,
    required double boxW,
    required double boxH,
    List<List<double>>? anchors,
  }) async {
    if (!isSupported) return null;
    try {
      // 锚点:每 5 个值 [帧序号, x, y, w, h](像素)→ 归一化后传给原生
      final anc = <double>[];
      if (anchors != null) {
        for (final a in anchors) {
          if (a.length < 5) continue;
          anc.addAll(<double>[a[0], a[1] / w, a[2] / h, a[3] / w, a[4] / h]);
        }
      }
      final raw = await _ch.invokeMethod<List<dynamic>>('trackGray', {
        'path': path,
        'w': w,
        'h': h,
        'frames': frames,
        'fps': fps,
        'boxX': boxX,
        'boxY': boxY,
        'boxW': boxW,
        'boxH': boxH,
        'anchors': anc,
      });
      if (raw == null || raw.isEmpty) return null;
      final out = <List<double>>[];
      for (var i = 0; i + 4 < raw.length; i += 5) {
        out.add(<double>[
          (raw[i] as num).toDouble(),
          (raw[i + 1] as num).toDouble(),
          (raw[i + 2] as num).toDouble(),
          (raw[i + 3] as num).toDouble(),
          (raw[i + 4] as num).toDouble(),
        ]);
      }
      return out.isEmpty ? null : out;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
