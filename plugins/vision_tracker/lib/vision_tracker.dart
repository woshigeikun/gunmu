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

  /// 在一帧灰度图里找候选目标(文字/数字、醒目区域、矩形)。
  /// [bytes] 是 w*h 的灰度数据;[rotationQuarterTurns] 是顺时针 90° 的圈数,
  /// 用于把传感器方向的画面转成和预览一致的朝向(返回的坐标也随之生效)。
  /// 返回按可信度降序排列的候选(最多 6 个)。
  static Future<List<TargetCandidate>> detectTargets({
    required Uint8List bytes,
    required int w,
    required int h,
    int rotationQuarterTurns = 0,
  }) async {
    if (!isSupported) return const [];
    try {
      final raw = await _ch.invokeMethod<List<dynamic>>('detectTargets', {
        'bytes': bytes,
        'w': w,
        'h': h,
        'rotation': rotationQuarterTurns,
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
  }) async {
    if (!isSupported) return null;
    try {
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
