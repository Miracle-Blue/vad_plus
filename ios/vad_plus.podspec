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

  # Include the ONNX model file as a resource bundle
  s.resource_bundles = { 'vad_plus_assets' => ['Resources/*.onnx'] }

  s.dependency 'Flutter'
  s.dependency 'onnxruntime-objc', '~> 1.18.0'

  s.platform = :ios, '15.0'
  s.static_framework = true

  # Enable modules and proper build settings
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES' => 'YES',
    'OTHER_SWIFT_FLAGS' => '-enable-experimental-feature Extern',
    # Preserve @_cdecl Swift FFI symbols - prevent dead code stripping
    'OTHER_LDFLAGS' => '-all_load -ObjC',
    'DEAD_CODE_STRIPPING' => 'NO',
    'STRIP_INSTALLED_PRODUCT' => 'NO',
    'PRESERVE_DEAD_CODE_INITS_AND_TERMS' => 'YES'
  }

  # Also set user_target_xcconfig to ensure flags are applied to the app target
  s.user_target_xcconfig = {
    'DEAD_CODE_STRIPPING' => 'NO',
    'STRIP_INSTALLED_PRODUCT' => 'NO'
  }

  s.swift_version = '5.0'

  # Required for ONNX Runtime
  s.frameworks = 'Accelerate', 'AVFoundation'
end