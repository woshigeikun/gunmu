import Flutter
import UIKit
import Vision
import CoreGraphics

/// 用 iOS Vision 框架跟踪一个框选目标。
///
/// 为什么交给系统做:Vision 的 VNTrackObjectRequest 是苹果硬件/系统级实现,
/// 自带尺度与外观模型的自适应,比手写的 SAD 块匹配稳得多,而且不增加任何
/// 第三方依赖(只要 iOS 13+)。
///
/// 坐标系注意:Vision 的 boundingBox 是**归一化且原点在左下角**,
/// 而入参给出的框是"跟踪帧像素、原点左上角",两边要互相换算。
public class VisionTrackerPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "vision_tracker", binaryMessenger: registrar.messenger())
    let instance = VisionTrackerPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "trackGray":
      handleTrack(call, result: result)
    case "detectTargets":
      handleDetect(call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // ─────────────── 候选目标检测 ───────────────

  private func handleDetect(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let w = args["w"] as? Int,
      let h = args["h"] as? Int,
      let rot = args["rotation"] as? Int,
      let typed = args["bytes"] as? FlutterStandardTypedData
    else {
      result(FlutterError(code: "bad_args", message: "缺少参数", details: nil))
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let out = self.detect(bytes: typed.data, w: w, h: h, rotation: rot)
      DispatchQueue.main.async { result(out) }
    }
  }

  /// 旋转圈数 → Vision 图像方向(1 = 顺时针 90°,与转置录制一致)
  private func cgOrientation(_ q: Int) -> CGImagePropertyOrientation {
    switch ((q % 4) + 4) % 4 {
    case 1: return .right
    case 2: return .down
    case 3: return .left
    default: return .up
    }
  }

  /// 在单帧灰度图上找"值得锁定的候选目标"。
  /// 用了三种系统检测器,因为它们各自擅长不同目标:
  ///   * VNRecognizeTextRequest —— 文字/数字(用户说的"画框的数字"就是这类)
  ///   * VNGenerateAttentionBasedSaliencyImageRequest —— 人眼会注意到的醒目区域
  ///   * VNDetectRectanglesRequest —— 屏幕/牌子/纸面等矩形物体
  /// 返回扁平数组,每个候选 6 个值:[x, y, w, h, score, kind](归一化、左上原点)。
  /// kind: 0=文字 1=醒目区域 2=矩形
  private func detect(bytes: Data, w: Int, h: Int, rotation: Int) -> [Double] {
    guard w > 8, h > 8, bytes.count >= w * h,
      let provider = CGDataProvider(data: bytes as CFData),
      let img = CGImage(
        width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false,
        intent: .defaultIntent)
    else { return [] }

    // 关键:把旋转交给 Vision(orientation),返回的坐标就自动落在"旋转后"的画面里,
    // 和 App 显示的竖屏预览一致,不需要 Dart 侧再换算。
    let handler = VNImageRequestHandler(
      cgImage: img, orientation: cgOrientation(rotation), options: [:])

    let textReq = VNRecognizeTextRequest()
    textReq.recognitionLevel = .fast
    textReq.usesLanguageCorrection = false

    let salReq = VNGenerateAttentionBasedSaliencyImageRequest()

    let rectReq = VNDetectRectanglesRequest()
    rectReq.maximumObservations = 8
    rectReq.minimumConfidence = 0.55
    rectReq.minimumAspectRatio = 0.2

    do {
      try handler.perform([textReq, salReq, rectReq])
    } catch {
      return []
    }

    var cands: [(CGRect, Double, Int)] = []

    for o in textReq.results ?? [] {
      cands.append((o.boundingBox, Double(o.confidence), 0))
    }
    if let sal = salReq.results?.first as? VNSaliencyImageObservation,
      let objs = sal.salientObjects
    {
      for o in objs {
        cands.append((o.boundingBox, Double(o.confidence) * 0.95, 1))
      }
    }
    for o in rectReq.results ?? [] {
      cands.append((o.boundingBox, Double(o.confidence) * 0.85, 2))
    }

    // Vision 归一化坐标是"原点左下" → 换成"原点左上"
    var norm: [(CGRect, Double, Int)] = []
    for (bb, sc, kind) in cands {
      let x = bb.minX
      let y = 1.0 - bb.maxY
      let r = CGRect(x: x, y: y, width: bb.width, height: bb.height)
      let area = r.width * r.height
      // 太小没意义;太大(超过画面 45%)等于"整幅画面都是目标",
      // 锁它没有任何意义,只会把真正想选的小目标挡住。
      if area < 0.015 || area > 0.45 { continue }
      norm.append((r, sc, kind))
    }
    // 按分数降序,重叠的只留分高的
    norm.sort { $0.1 > $1.1 }
    var kept: [(CGRect, Double, Int)] = []
    for c in norm {
      var dup = false
      for k in kept where iou(k.0, c.0) > 0.4 {
        dup = true
        break
      }
      if !dup { kept.append(c) }
      if kept.count >= 6 { break }
    }

    // 输出顺序:**面积从小到大**。
    // 这样编号 1 永远是最精确的框,用户不必在几个套在一起的大框里猜哪个是哪个。
    kept.sort { ($0.0.width * $0.0.height) < ($1.0.width * $1.0.height) }

    var out: [Double] = []
    for (r, sc, kind) in kept {
      out.append(Double(r.minX))
      out.append(Double(r.minY))
      out.append(Double(r.width))
      out.append(Double(r.height))
      out.append(sc)
      out.append(Double(kind))
    }
    return out
  }

  private func iou(_ a: CGRect, _ b: CGRect) -> Double {
    let inter = a.intersection(b)
    if inter.isNull { return 0 }
    let ia = Double(inter.width * inter.height)
    let ua = Double(a.width * a.height + b.width * b.height) - ia
    return ua <= 0 ? 0 : ia / ua
  }

  // ─────────────── 逐帧跟踪 ───────────────

  private func handleTrack(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let path = args["path"] as? String,
      let w = args["w"] as? Int,
      let h = args["h"] as? Int,
      let frames = args["frames"] as? Int,
      let fps = args["fps"] as? Double,
      let boxX = args["boxX"] as? Double,
      let boxY = args["boxY"] as? Double,
      let boxW = args["boxW"] as? Double,
      let boxH = args["boxH"] as? Double
    else {
      result(FlutterError(code: "bad_args", message: "缺少参数", details: nil))
      return
    }

    // 跟踪放在后台队列:上千帧要跑好几秒,不能占着主线程
    DispatchQueue.global(qos: .userInitiated).async {
      let out = self.track(
        path: path, w: w, h: h, frames: frames, fps: fps,
        box: CGRect(x: boxX, y: boxY, width: boxW, height: boxH))
      DispatchQueue.main.async { result(out) }
    }
  }

  /// 返回扁平数组,每帧 5 个值:[t, cx, cy, confidence, ok]
  private func track(
    path: String, w: Int, h: Int, frames: Int, fps: Double, box: CGRect
  ) -> [Double] {
    var out: [Double] = []
    guard w > 0, h > 0, frames > 0,
      let data = try? Data(contentsOf: URL(fileURLWithPath: path))
    else { return out }

    let frameBytes = w * h
    let handler = VNSequenceRequestHandler()

    // 首帧观测:像素(左上原点) → Vision 归一化(左下原点)
    var last = VNDetectedObjectObservation(
      boundingBox: CGRect(
        x: box.minX / Double(w),
        y: 1.0 - (box.maxY / Double(h)),
        width: box.width / Double(w),
        height: box.height / Double(h)))

    var lostStreak = 0
    for f in 0..<frames {
      let off = f * frameBytes
      if off + frameBytes > data.count { break }
      guard let img = grayImage(data: data, offset: off, w: w, h: h) else { break }

      let req = VNTrackObjectRequest(detectedObjectObservation: last)
      req.trackingLevel = .accurate
      var obs: VNDetectedObjectObservation? = nil
      do {
        try handler.perform([req], on: img)
        if let r = req.results?.first as? VNDetectedObjectObservation {
          obs = r
        }
      } catch {
        obs = nil
      }

      let conf = obs?.confidence ?? 0
      if let o = obs, conf > 0.25 {
        last = o
        lostStreak = 0
        let bb = o.boundingBox
        out.append(Double(f) / fps)
        out.append(bb.midX * Double(w))
        out.append((1.0 - bb.midY) * Double(h))
        out.append(Double(conf))
        out.append(1.0)
      } else {
        // 跟丢:沿用上一次位置并标记不可信,连续跟丢太多就提前结束
        lostStreak += 1
        let bb = last.boundingBox
        out.append(Double(f) / fps)
        out.append(bb.midX * Double(w))
        out.append((1.0 - bb.midY) * Double(h))
        out.append(Double(conf))
        out.append(0.0)
        if lostStreak > 60 { break }
      }
    }
    return out
  }

  /// 从整段灰度数据里切一帧出来构造成 CGImage(8bit 灰度)
  private func grayImage(data: Data, offset: Int, w: Int, h: Int) -> CGImage? {
    let sub = data.subdata(in: offset..<(offset + w * h))
    guard let provider = CGDataProvider(data: sub as CFData) else { return nil }
    return CGImage(
      width: w, height: h,
      bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
      space: CGColorSpaceCreateDeviceGray(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false,
      intent: .defaultIntent)
  }
}
