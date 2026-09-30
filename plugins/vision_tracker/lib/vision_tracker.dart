import 'dart:io';

import 'package:flutter/services.dart';

/// iOS Vision 目标跟踪(本地插件)。
/// Android 上没有实现,会返回 null,由调用方退回 Dart 的 SAD 跟踪。
class VisionTracker {
  static const MethodChannel _ch = MethodChannel('vision_tracker');

  static bool get isSupported => Platform.isIOS;

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
