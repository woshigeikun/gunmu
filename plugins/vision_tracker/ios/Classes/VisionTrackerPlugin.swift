import Flutter
import UIKit
import Vision
import CoreGraphics
import CoreImage
import CoreMedia
import ReplayKit

/// 用 iOS Vision 框架跟踪一个框选目标。
///
/// 为什么交给系统做:Vision 的 VNTrackObjectRequest 是苹果硬件/系统级实现,
/// 自带尺度与外观模型的自适应,比手写的 SAD 块匹配稳得多,而且不增加任何
/// 第三方依赖(只要 iOS 13+)。
///
/// 坐标系注意:Vision 的 boundingBox 是**归一化且原点在左下角**,
/// 而入参给出的框是"跟踪帧像素、原点左上角",两边要互相换算。
public class VisionTrackerPlugin: NSObject, FlutterPlugin {  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "vision_tracker", binaryMessenger: registrar.messenger())
    let instance = VisionTrackerPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)

    // 实时跟踪的事件通道:只回传**框坐标**(每帧 4~5 个数),
    // 不传图像 —— 抓屏一帧 1170×2532 约 3MB,传图像平台通道撑不住。
    let live = FlutterEventChannel(
      name: "vision_tracker/live", binaryMessenger: registrar.messenger())
    live.setStreamHandler(LiveTrackerStreamHandler(plugin: instance))
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "trackGray":
      handleTrack(call, result: result)
    case "detectTargets":
      handleDetect(call, result: result)
    case "probeReplay":
      handleProbeReplay(result: result)
    case "startLiveTracking":
      handleStartLive(call, result: result)
    case "stopLiveTracking":
      stopLive()
      result(nil)
    case "updateLiveBox":
      handleUpdateLiveBox(call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // ─────────────── 录制中实时跟踪(ReplayKit 抓屏)───────────────

  var liveSink: FlutterEventSink?
  private var liveHandler: VNSequenceRequestHandler?
  private var liveRequest: VNTrackObjectRequest?
  /// 预览区域在**整屏**里的归一化位置(0~1);把用户画的框换算到整屏坐标要用它
  private var liveRegion = CGRect(x: 0, y: 0, width: 1, height: 1)
  private var liveLastTick: CFAbsoluteTime = 0

  /// 用户框(相对预览,0~1、左上原点) → Vision 框(相对整屏,0~1、左下原点)
  private func toScreenVision(_ b: CGRect) -> CGRect {
    let sx = liveRegion.minX + b.minX * liveRegion.width
    let syTop = liveRegion.minY + b.minY * liveRegion.height
    let sw = b.width * liveRegion.width
    let sh = b.height * liveRegion.height
    return CGRect(x: sx, y: 1 - (syTop + sh), width: sw, height: sh)
  }

  /// Vision 框(整屏) → 用户框(相对预览,左上原点),Dart 侧直接拿去画
  private func fromScreenVision(_ v: CGRect) -> [String: Any] {
    let x = (v.minX - liveRegion.minX) / max(liveRegion.width, 1e-6)
    let y = (1 - v.maxY - liveRegion.minY) / max(liveRegion.height, 1e-6)
    let w = v.width / max(liveRegion.width, 1e-6)
    let h = v.height / max(liveRegion.height, 1e-6)
    return ["x": x, "y": y, "w": w, "h": h]
  }

  private func handleStartLive(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let a = call.arguments as? [String: Any] ?? [:]
    guard let bm = a["box"] as? [String: Any],
      let rm = a["region"] as? [String: Any]
    else {
      result(FlutterError(code: "bad_args", message: "缺少 box / region", details: nil))
      return
    }
    func num(_ m: [String: Any], _ k: String) -> Double {
      (m[k] as? NSNumber)?.doubleValue ?? 0
    }
    liveRegion = CGRect(
      x: num(rm, "x"), y: num(rm, "y"),
      width: num(rm, "w"), height: num(rm, "h"))
    let userBox = CGRect(
      x: num(bm, "x"), y: num(bm, "y"),
      width: num(bm, "w"), height: num(bm, "h"))
    liveHandler = VNSequenceRequestHandler()
    let req = VNTrackObjectRequest(
      detectedObjectObservation: VNDetectedObjectObservation(
        boundingBox: toScreenVision(userBox)))
    req.trackingLevel = .fast
    liveRequest = req
    liveLastTick = 0

    let rec = RPScreenRecorder.shared()
    guard rec.isAvailable else {
      result(FlutterError(code: "unavailable", message: "ReplayKit 不可用", details: nil))
      return
    }
    if rec.isRecording {
      result(nil)
      return
    }
    rec.isMicrophoneEnabled = false
    rec.startCapture(
      handler: { [weak self] sample, type, _ in
        guard let self, type == .video,
          let px = CMSampleBufferGetImageBuffer(sample)
        else { return }
        self.tickLive(px)
      },
      completionHandler: { [weak self] err in
        if let e = err {
          DispatchQueue.main.async {
            self?.liveSink?(
              FlutterError(code: "start_failed", message: e.localizedDescription, details: nil))
          }
        }
      })
    result(nil)
  }

  private func handleUpdateLiveBox(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let a = call.arguments as? [String: Any] ?? [:]
    guard let bm = a["box"] as? [String: Any] else {
      result(nil)
      return
    }
    func num(_ m: [String: Any], _ k: String) -> Double {
      (m[k] as? NSNumber)?.doubleValue ?? 0
    }
    let userBox = CGRect(
      x: num(bm, "x"), y: num(bm, "y"),
      width: num(bm, "w"), height: num(bm, "h"))
    let req = VNTrackObjectRequest(
      detectedObjectObservation: VNDetectedObjectObservation(
        boundingBox: toScreenVision(userBox)))
    req.trackingLevel = .fast
    liveRequest = req
    result(nil)
  }

  private func stopLive() {
    guard RPScreenRecorder.shared().isRecording else { return }
    RPScreenRecorder.shared().stopCapture { _ in }
  }

  /// 每帧回调:节流到约 15fps,只跑跟踪,把结果回传
  private func tickLive(_ px: CVPixelBuffer) {
    guard let req = liveRequest, let handler = liveHandler else { return }
    let now = CFAbsoluteTimeGetCurrent()
    if now - liveLastTick < 0.06 { return }
    liveLastTick = now
    do {
      try handler.perform([req], on: px)
    } catch {
      return
    }
    guard let obs = req.results?.first as? VNDetectedObjectObservation else { return }
    // 置信度够才更新观测;不够就保持上一次,避免跟踪器被噪声带跑
    if obs.confidence > 0.3 {
      req.inputObservation = obs
    }
    var payload = fromScreenVision(obs.boundingBox)
    payload["c"] = obs.confidence
    DispatchQueue.main.async { [weak self] in
      self?.liveSink?(payload)
    }
  }

  // ─────────────── 抓屏可行性探针 ───────────────

  /// 用 ReplayKit 抓一帧屏幕,统计整帧与中心区域的平均亮度。
  /// 目的:验证"相机预览层能不能被 ReplayKit 抓到" —— 某些机型/系统上
  /// 预览层是硬件合成的,抓出来可能是纯黑,那就说明这条路不通。
  private func handleProbeReplay(result: @escaping FlutterResult) {
    let rec = RPScreenRecorder.shared()
    guard rec.isAvailable else {
      result(FlutterError(code: "unavailable", message: "ReplayKit 不可用", details: nil))
      return
    }
    var finished = false
    rec.isMicrophoneEnabled = false
    rec.startCapture { sample, type, _ in
      guard !finished, type == .video,
        let px = CMSampleBufferGetImageBuffer(sample)
      else { return }
      finished = true
      CVPixelBufferLockBaseAddress(px, .readOnly)
      let w = CVPixelBufferGetWidth(px)
      let h = CVPixelBufferGetHeight(px)
      let stride = CVPixelBufferGetBytesPerRow(px)
      var sum = 0.0, cnt = 0.0, csum = 0.0, ccnt = 0.0
      if let base = CVPixelBufferGetBaseAddress(px) {
        let p = base.assumingMemoryBound(to: UInt8.self)
        var y = 0
        while y < h {
          var x = 0
          while x < w {
            let o = y * stride + x * 4
            let b = Double(p[o]), g = Double(p[o + 1]), r = Double(p[o + 2])
            let l = 0.299 * r + 0.587 * g + 0.114 * b
            sum += l
            cnt += 1
            if x > w / 4 && x < w * 3 / 4 && y > h / 4 && y < h * 3 / 4 {
              csum += l
              ccnt += 1
            }
            x += 8
          }
          y += 8
        }
      }
      CVPixelBufferUnlockBaseAddress(px, .readOnly)
      rec.stopCapture { _ in }
      DispatchQueue.main.async {
        result([
          "w": w, "h": h,
          "mean": cnt > 0 ? sum / cnt : 0.0,
          "center": ccnt > 0 ? csum / ccnt : 0.0,
        ])
      }
    } completionHandler: { err in
      if let e = err {
        result(FlutterError(code: "start_failed", message: e.localizedDescription, details: nil))
      }
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
      let out = self.detect(
        bytes: typed.data, w: w, h: h, rotation: rot,
        textOnly: (args["textOnly"] as? Bool) ?? false)
      DispatchQueue.main.async { result(out) }
    }
  }

  /// CIContext 创建开销大,全局复用一个
  private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

  /// OCR 前的图像增强:提对比度 + 轻度锐化。
  /// 这是提升文字检出率最有效的一步:低对比度/背光/暗光/轻微运动模糊的文字,
  /// 原图上 Vision 经常整段漏检,增强后就能稳定认出。
  private func enhanceForOCR(_ img: CGImage) -> CGImage? {
    let ci = CIImage(cgImage: img)
    let out =
      ci
      .applyingFilter(
        "CIColorControls",
        parameters: [
          kCIInputContrastKey: 1.45,
          kCIInputBrightnessKey: 0.02,
          kCIInputSaturationKey: 0,
        ]
      )
      .applyingFilter(
        "CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.5])
    return VisionTrackerPlugin.ciContext.createCGImage(out, from: ci.extent)
  }

  /// 放大 2 倍(用 Lanczos,比直接插值锐利)。只在首轮没找到文字时用。
  private func upscale2x(_ img: CGImage) -> CGImage? {
    let ci = CIImage(cgImage: img)
    let out = ci.applyingFilter(
      "CILanczosScaleTransform",
      parameters: [kCIInputScaleKey: 2.0, kCIInputAspectRatioKey: 1.0])
    return VisionTrackerPlugin.ciContext.createCGImage(out, from: ci.extent)
  }

  /// 旋转圈数 → Vision 图像方向(1 = 顺时针 90°,与转置录制一致)
  private func cgOrientation(_ q: Int) -> CGImagePropertyOrientation {    switch ((q % 4) + 4) % 4 {
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
  /// [textOnly] 只跑文字检测:渲染时要按 0.1 秒跑上千次,只跑文字能省掉三分之二耗时。
  private func detect(
    bytes: Data, w: Int, h: Int, rotation: Int, textOnly: Bool = false
  ) -> [Double] {
    guard w > 8, h > 8, bytes.count >= w * h,
      let provider = CGDataProvider(data: bytes as CFData),
      let rawImg = CGImage(
        width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false,
        intent: .defaultIntent)
    else { return [] }

    // OCR 前先做图像增强:提对比 + 轻微锐化。
    // 实测这是提升文字检出率最有效的一步 —— 低对比度、背光、暗光、糊字
    // 在原图上 Vision 往往整段漏掉,增强后就能认出来。
    let img = enhanceForOCR(rawImg) ?? rawImg

    // 关键:把旋转交给 Vision(orientation),返回的坐标就自动落在"旋转后"的画面里,
    // 和 App 显示的竖屏预览一致,不需要 Dart 侧再换算。
    let handler = VNImageRequestHandler(
      cgImage: img, orientation: cgOrientation(rotation), options: [:])

    let textReq = VNRecognizeTextRequest()
    textReq.recognitionLevel = .accurate
    // 关掉语言纠错:目标通常是数字,纠错会把"10"往单词上掰,反而降低准确率
    textReq.usesLanguageCorrection = false
    // 限定英文:数字与拉丁字母都在这一套里,避免中英混识分散注意力
    textReq.recognitionLanguages = ["en-US"]
    // 允许很小的字(0.4% 画面高度),但不让噪点参与
    textReq.minimumTextHeight = 0.004

    let salReq = VNGenerateAttentionBasedSaliencyImageRequest()

    let rectReq = VNDetectRectanglesRequest()
    rectReq.maximumObservations = 8
    rectReq.minimumConfidence = 0.55
    rectReq.minimumAspectRatio = 0.2

    do {
      try handler.perform(textOnly ? [textReq] : [textReq, salReq, rectReq])
    } catch {
      return []
    }

    var textObs: [VNRecognizedTextObservation] = textReq.results ?? []
    // 兜底:首轮一个文字都没认出来时,把图放大 2 倍再试一次。
    // 只在失败时才付这个代价,所以平均成本很小,但能救回一部分小字/糊字。
    if textObs.isEmpty, let big = upscale2x(img) {
      let h2 = VNImageRequestHandler(
        cgImage: big, orientation: cgOrientation(rotation), options: [:])
      let r2 = VNRecognizeTextRequest()
      r2.recognitionLevel = .accurate
      r2.usesLanguageCorrection = false
      r2.recognitionLanguages = ["en-US"]
      r2.minimumTextHeight = 0.002
      if (try? h2.perform([r2])) != nil {
        textObs = r2.results ?? []
      }
    }

    var cands: [(CGRect, Double, Int)] = []

    for o in textObs {
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
      // 锚点:每 5 个一组 [帧序号, x, y, w, h](已是归一化坐标)
      var anchors: [Int: CGRect] = [:]
      if let flat = args["anchors"] as? [Double], flat.count >= 5 {
        var i = 0
        while i + 4 < flat.count {
          let f = Int(flat[i].rounded())
          anchors[f] = CGRect(
            x: flat[i + 1], y: flat[i + 2], width: flat[i + 3], height: flat[i + 4])
          i += 5
        }
      }
      let out = self.track(
        path: path, w: w, h: h, frames: frames, fps: fps,
        box: CGRect(x: boxX, y: boxY, width: boxW, height: boxH),
        anchors: anchors)
      DispatchQueue.main.async { result(out) }
    }
  }

  /// 返回扁平数组,每帧 5 个值:[t, cx, cy, confidence, ok]
  ///
  /// [anchors] 是"重新捕获点":键为帧序号,值为归一化框(左上原点)。
  /// 到了这些帧就用识别出来的新位置把跟踪器重新初始化 —— 长视频里
  /// Vision 跟踪器也会慢慢飘,每 10 秒拉回来一次能显著延长可用时长。
  private func track(
    path: String, w: Int, h: Int, frames: Int, fps: Double, box: CGRect,
    anchors: [Int: CGRect] = [:]
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

      // 重新捕获点:用识别出来的新位置重建观测,把跟踪器拉回正确位置
      if let a = anchors[f], f > 0 {
        last = VNDetectedObjectObservation(
          boundingBox: CGRect(
            x: a.minX, y: 1.0 - a.maxY, width: a.width, height: a.height))
        lostStreak = 0
      }

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

/// 事件通道的 StreamHandler:把 sink 交给插件,让每帧跟踪结果能推给 Dart
public class LiveTrackerStreamHandler: NSObject, FlutterStreamHandler {
  private weak var plugin: VisionTrackerPlugin?
  init(plugin: VisionTrackerPlugin) {
    self.plugin = plugin
  }
  public func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    plugin?.liveSink = events
    return nil
  }
  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    plugin?.liveSink = nil
    return nil
  }
}
