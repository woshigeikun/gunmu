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
  s.platform         = :ios, '13.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version    = '5.0'
end
