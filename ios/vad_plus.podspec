#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint vad_plus.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'vad_plus'
  s.version          = '0.0.1'
  s.summary          = 'Silero VAD ONNX voice activity detection FFI plugin.'
  s.description      = <<-DESC
A Flutter FFI plugin for voice activity detection using Silero VAD ONNX model.
Provides real-time speech detection with configurable thresholds and callbacks.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  
  # Include the ONNX model file
  s.resources        = ['../onnx/*.onnx']
  
  s.dependency 'Flutter'
  s.dependency 'onnxruntime-objc', '~> 1.18.0'
  
  s.platform = :ios, '15.0'

  # Enable modules and proper build settings
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES' => 'YES',
    'OTHER_SWIFT_FLAGS' => '-enable-experimental-feature Extern'
  }
  
  s.swift_version = '5.0'
  
  # Required for ONNX Runtime
  s.frameworks = 'Accelerate', 'AVFoundation'
end
