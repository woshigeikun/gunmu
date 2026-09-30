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
    guard call.method == "trackGray" else {
      result(FlutterMethodNotImplemented)
      return
    }
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
