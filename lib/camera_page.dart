import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'ble_heart_rate.dart';

/// 一次心率采样:相对录像开始的时间(毫秒)+ 心率值
class _HrSample {
  final int ms;
  final int bpm;
  _HrSample(this.ms, this.bpm);
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

  @override
  void initState() {
    super.initState();
    _initCamera();
    // 订阅心率:录像中记录时间线;屏幕历史始终累积
    widget.ble.bpmStream.listen((bpm) {
      _history.add(bpm);
      if (_history.length > 120) _history.removeAt(0);
      if (_recording) {
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
    final c = CameraController(desc, ResolutionPreset.high, enableAudio: true);
    await c.initialize();
    if (!mounted) {
      await c.dispose();
      return;
    }
    setState(() {
      _cam = c;
      _camIndex = index;
      _zoom = 1.0; // 切换镜头后变焦回到 1x
    });
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
                      backgroundColor: Colors.white10,
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
                        ? Colors.white12
                        : (active ? Colors.redAccent : Colors.white24);
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

  Future<void> _toggleRecord() async {
    final cam = _cam;
    if (cam == null || !cam.value.isInitialized || _busy) return;
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
        await _burnAndSave(file); // 烧录 + 保存,内部自带 try/catch
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

  /// ① 用 FFmpeg 把心率烧进视频右上角 ② 保存到文件目录 ③ 弹分享面板
  Future<void> _burnAndSave(XFile raw) async {
    // 分享面板锚点:在首个 await 前从 context 取好,避免跨 async 使用
    final renderBox = context.findRenderObject() as RenderBox?;
    final shareOrigin = renderBox != null
        ? renderBox.localToGlobal(Offset.zero) & renderBox.size
        : null;
    try {
      // 1) 解析原视频尺寸与时长(字幕坐标需要像素尺寸)
      final info = await FFprobeKit.getMediaInformation(raw.path);
      final mi = info.getMediaInformation();
      if (mi == null) throw Exception('无法读取视频信息');
      int width = 1920, height = 1080;
      double? durationSec;
      for (final s in mi.getStreams()) {
        if (s.getType() == 'video') {
          width = s.getWidth() ?? width;
          height = s.getHeight() ?? height;
        }
      }
      final durStr = mi.getDuration(); // 形如 "12.345"
      durationSec = durStr != null ? double.tryParse(durStr) : null;
      if (durationSec == null || durationSec <= 0) {
        durationSec = _timer.elapsedMilliseconds / 1000.0;
      }

      // 2) 生成 ASS 字幕(右上角 ♥ bpm)+ 心率曲线 PNG(文字正下方)
      final docs = await getApplicationDocumentsDirectory();
      final workDir = Directory('${docs.path}/work');
      if (!workDir.existsSync()) workDir.createSync(recursive: true);
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final assPath = '${workDir.path}/$stamp.ass';
      final hasCurve = _samples.where((s) => s.bpm > 0).length >= 2;

      // 曲线区域尺寸:与心率文字一致(MarginR=30、MarginV=40、字号=高4.5%)
      final fontSize = (height * 0.045).round().clamp(24, 200);
      const marginRight = 30.0;
      const marginTop = 40.0;
      // 心率文字高度≈fontSize,曲线放在其下方:宽≈字号*2.6,高≈字号*1.0
      final curW = (fontSize * 2.6).round().clamp(60, 600);
      final curH = (fontSize * 1.0).round().clamp(24, 240);
      final curX = (width - marginRight - curW).round();
      final curY = (marginTop + fontSize * 1.15).round();

      _writeAss(assPath, width, height, durationSec);
      String? curvePath;
      if (hasCurve) {
        if (mounted) setState(() => _hint = '正在生成心率曲线…');
        final img = await _renderCurveImage(curW, curH, durationSec);
        final data = await img.toByteData(format: ui.ImageByteFormat.png);
        curvePath = '${workDir.path}/$stamp.png';
        File(curvePath).writeAsBytesSync(data!.buffer.asUint8List());
      }

      // 3) FFmpeg 烧录:字幕滤镜 + (曲线 PNG overlay)+ 重新编码为 mp4
      if (mounted) setState(() => _hint = '正在合成心率到视频…');
      final outPath = '${workDir.path}/$stamp.mp4';
      String cmd;
      if (curvePath != null) {
        // 双输入:0=原始视频(先烧字幕),1=曲线透明PNG(overlay)
        cmd =
            '-y -i "${raw.path}" -i "$curvePath" '
            '-filter_complex '
            '"[0:v]ass=$assPath[base];'
            '[1:v]format=rgba,scale=$curW:$curH[ov];'
            '[base][ov]overlay=x=$curX:y=$curY[outv]" '
            '-map "[outv]" -map 0:a? '
            '-c:v libx264 -preset veryfast -crf 22 '
            '-c:a aac -b:a 128k "$outPath"';
      } else {
        cmd =
            '-y -i "${raw.path}" -vf "ass=$assPath" '
            '-c:v libx264 -preset veryfast -crf 22 '
            '-c:a aac -b:a 128k "$outPath"';
      }
      final session = await FFmpegKit.execute(cmd);
      final rc = await session.getReturnCode();
      if (!ReturnCode.isSuccess(rc)) {
        throw Exception('FFmpeg 合成失败 (rc=$rc)');
      }

      // 4) 保存到"文件"目录(带 .mp4)
      final folder = Directory('${docs.path}/录像');
      if (!folder.existsSync()) folder.createSync(recursive: true);
      final saved = '${folder.path}/$stamp.mp4';
      await File(outPath).copy(saved);
      // 清理工作文件
      try {
        File(assPath).deleteSync();
        if (curvePath != null) File(curvePath).deleteSync();
        File(outPath).deleteSync();
        File(raw.path).deleteSync();
      } catch (_) {}

      // 5) 弹出系统分享面板(可"存储视频"到相册/发给微信等)
      if (mounted) setState(() => _hint = '合成完成,弹出分享…');
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(saved)],
          text: '心率录像',
          sharePositionOrigin: shareOrigin,
        ),
      );
      if (mounted) {
        setState(() => _hint = '已保存(带心率),可在"文件"App→本App→录像 查看');
      }
    } catch (e) {
      if (mounted) setState(() => _hint = '合成保存失败: $e');
    }
  }

  /// 生成 ASS 字幕文件:右上角显示 ♥ bpm,文本红色、黑描边
  void _writeAss(String path, int width, int height, double durationSec) {
    // 心率采样点若为空,用局部占位(不污染 _samples)
    final eff = _samples.isEmpty ? [_HrSample(0, 0)] : _samples;
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
      final endMs = (i + 1 < eff.length)
          ? eff[i + 1].ms
          : (durationSec * 1000).round();
      // 至少显示 0.8 秒,防止过快闪没
      var e = endMs;
      if (e <= s.ms) e = s.ms + 800;
      sb.writeln(
        'Dialogue: 0,${_assTime(s.ms / 1000)},${_assTime(e / 1000)},HR,,0,0,0,,'
        '${s.bpm > 0 ? '♥ ${s.bpm}' : '♥ --'}',
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

  /// 生成"心率曲线"透明 PNG:画面右上角心率文字的正下方,大小与文字相近
  Future<ui.Image> _renderCurveImage(int w, int h, double durationSec) async {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    const pad = 4.0;

    // 有效采样(去掉占位的 0)
    final pts = _samples.where((s) => s.bpm > 0).toList();
    // 黑色半透明圆角底,保证亮背景上也清晰
    final bg = Paint()..color = const Color(0x99000000);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        const Radius.circular(6),
      ),
      bg,
    );

    if (pts.length >= 2) {
      var minB = pts.first.bpm;
      var maxB = pts.first.bpm;
      for (final p in pts) {
        if (p.bpm < minB) minB = p.bpm;
        if (p.bpm > maxB) maxB = p.bpm;
      }
      if (maxB - minB < 8) {
        minB = minB - 4 < 30 ? 30 : minB - 4;
        maxB = maxB + 4;
      }
      final durMs = durationSec * 1000;
      // 先画黑色粗线做描边,再画红线,视觉与 ASS 文本描边一致
      Paint line(Color c, double width) => Paint()
        ..color = c
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final ptsPath = Path();
      for (var i = 0; i < pts.length; i++) {
        final x = pad + (pts[i].ms / durMs) * (w - pad * 2);
        final y =
            (h - pad) - ((pts[i].bpm - minB) / (maxB - minB)) * (h - pad * 2);
        if (i == 0) {
          ptsPath.moveTo(x.clamp(0, w).toDouble(), y.clamp(0, h).toDouble());
        } else {
          ptsPath.lineTo(x.clamp(0, w).toDouble(), y.clamp(0, h).toDouble());
        }
      }
      canvas.drawPath(ptsPath, line(Colors.black, 3.4));
      canvas.drawPath(ptsPath, line(const Color(0xFFFF3B30), 1.8));

      // 端点圆点
      final last = pts.last;
      final lx = pad + (last.ms / durMs) * (w - pad * 2);
      final ly =
          (h - pad) - ((last.bpm - minB) / (maxB - minB)) * (h - pad * 2);
      canvas.drawCircle(
        Offset(lx.clamp(0, w).toDouble(), ly.clamp(0, h).toDouble()),
        (w * 0.02).clamp(1.5, 4.0),
        Paint()..color = const Color(0xFFFF3B30),
      );
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
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (cam != null && cam.value.isInitialized)
            Positioned.fill(child: CameraPreview(cam))
          else
            const Center(child: CircularProgressIndicator()),

          // ── 心率叠加层(右上角实时数字)──
          StreamBuilder<int>(
            stream: widget.ble.bpmStream,
            initialData: bpmNow,
            builder: (context, snap) {
              final bpm = snap.data ?? 0;
              return Positioned(
                top: 60,
                right: 20,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.favorite, color: Colors.red, size: 22),
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

          // ── 镜头/变焦按钮(左上角,录制中禁用)──
          Positioned(
            top: 60,
            left: 16,
            child: IconButton(
              onPressed: (_recording || _busy) ? null : _showLensSheet,
              icon: const Icon(Icons.camera_alt, color: Colors.white, size: 26),
              style: IconButton.styleFrom(
                backgroundColor: Colors.black38,
                disabledBackgroundColor: Colors.black12,
              ),
            ),
          ),

          // 当前等效焦距显示(左上角按钮下方)
          Positioned(
            top: 100,
            left: 16,
            child: Text(
              '${(_zoom * 26).round()}mm',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 11,
                backgroundColor: Colors.black38,
              ),
            ),
          ),

          // 状态/错误提示
          if (_hint.isNotEmpty)
            Positioned(
              top: 110,
              left: 20,
              right: 60,
              child: Text(
                _hint,
                style: const TextStyle(
                  color: Colors.yellowAccent,
                  fontSize: 12,
                ),
              ),
            ),

          // ── 实时心率曲线(录制中,底部按钮上方)──
          if (_recording && _history.length >= 2)
            Positioned(
              left: 12,
              right: 12,
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

          // ── 录像按钮 ──
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
                  FloatingActionButton.large(
                    backgroundColor: _recording ? Colors.red : Colors.white,
                    onPressed: _toggleRecord,
                    child: Icon(
                      _recording ? Icons.stop : Icons.circle,
                      color: _recording ? Colors.white : Colors.red,
                      size: 36,
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

  @override
  void dispose() {
    _ticker?.cancel();
    _timer.stop();
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
