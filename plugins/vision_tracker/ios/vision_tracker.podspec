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
  # ONNX Runtime:让同一份 .onnx 模型也能在 iOS 上跑(安卓侧用同一份)。
  # 代价:IPA 增大约几十 MB,而且预处理要自己写(不像 Core ML 那样由
  # VNCoreMLRequest 代劳)。这里固定大版本,避免上游破坏性变更。
  s.dependency 'onnxruntime-objc', '~> 1.11'
  s.platform         = :ios, '13.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version    = '5.0'
end
