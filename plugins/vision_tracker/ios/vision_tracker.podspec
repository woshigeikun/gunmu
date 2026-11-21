Pod::Spec.new do |s|
  s.name             = 'vision_tracker'
  s.version          = '0.0.1'
  s.summary          = 'iOS Vision framework object tracking for the heart-rate camera app'
  s.description      = 'Tracks a user-drawn box across a sequence of grayscale frames using VNTrackObjectRequest.'
  s.homepage         = 'https://github.com/woshigeikun/gunmu'
  s.license          = { :type => 'MIT' }
  s.author           = { 'hrc' => 'hrc@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  # ONNX Runtime(可选):让同一份 .onnx 也能在 iOS 上跑。
  # 暂时关闭 —— CI 上安装失败:
  #   [!] Error installing onnxruntime-c
  #   curl failed to verify the legitimacy of the server
  #   https://download.onnxruntime.ai/pod-archive-onnxruntime-c-*.zip
  # 代码里的 ONNX 路径用 #if canImport(onnxruntime_objc) 保护,
  # 所以在本地把下面这行取消注释、且网络能访问该域名时,会自动启用。
  # s.dependency 'onnxruntime-objc', '~> 1.11'
  s.platform         = :ios, '13.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version    = '5.0'
end
