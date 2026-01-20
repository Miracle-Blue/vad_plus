import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'vad_plus_bindings_generated.dart';

// ============================================================================
// VAD Configuration
// ============================================================================

/// Configuration options for the Voice Activity Detection.
class VadConfig {
  /// Create default VAD configuration.
  const VadConfig({
    this.positiveSpeechThreshold = 0.5,
    this.negativeSpeechThreshold = 0.35,
    this.preSpeechPadFrames = 3,
    this.redemptionFrames = 24,
    this.minSpeechFrames = 9,
    this.sampleRate = 16000,
    this.frameSamples = 512,
    this.endSpeechPadFrames = 3,
    this.isDebug = false,
  });

  /// Create configuration optimized for Silero VAD at 16kHz.
  const VadConfig.kHz16({
    this.positiveSpeechThreshold = 0.5,
    this.negativeSpeechThreshold = 0.35,
    this.preSpeechPadFrames = 3,
    this.redemptionFrames = 24,
    this.minSpeechFrames = 9,
    this.sampleRate = 16000,
    this.frameSamples = 512,
    this.endSpeechPadFrames = 3,
    this.isDebug = false,
  });

  /// Create configuration optimized for Silero VAD at 8kHz.
  const VadConfig.kHz8({
    this.positiveSpeechThreshold = 0.5,
    this.negativeSpeechThreshold = 0.35,
    this.preSpeechPadFrames = 3,
    this.redemptionFrames = 24,
    this.minSpeechFrames = 9,
    this.sampleRate = 8000,
    this.frameSamples = 256,
    this.endSpeechPadFrames = 3,
    this.isDebug = false,
  });

  /// Threshold for detecting speech start (0.0 - 1.0).
  /// Default: 0.5
  final double positiveSpeechThreshold;

  /// Threshold for detecting speech end (0.0 - 1.0).
  /// Default: 0.35
  final double negativeSpeechThreshold;

  /// Number of frames to prepend before speech start.
  /// Default: 3 (for v6 model)
  final int preSpeechPadFrames;

  /// Number of silence frames before ending speech.
  /// Default: 24 (for v6 model)
  final int redemptionFrames;

  /// Minimum speech frames for valid speech segment.
  /// Default: 9 (for v6 model)
  final int minSpeechFrames;

  /// Audio sample rate in Hz (16000 or 8000).
  /// Default: 16000
  final int sampleRate;

  /// Number of samples per frame.
  /// Default: 512 (for 16kHz v6 model)
  final int frameSamples;

  /// Number of padding frames after speech end.
  /// Default: 3 (for v6 model)
  final int endSpeechPadFrames;

  /// Enable debug logging.
  /// Default: false
  final bool isDebug;
}

// ============================================================================
// VAD Events
// ============================================================================

/// Base class for all VAD events.
sealed class VadEvent {
  const VadEvent();
}

/// Emitted when VAD is initialized successfully.
class VadInitializedEvent extends VadEvent {
  /// Emitted when VAD is initialized successfully.
  const VadInitializedEvent();
}

/// Emitted when speech starts (initial detection).
class VadSpeechStartEvent extends VadEvent {
  /// Emitted when speech starts (initial detection).
  const VadSpeechStartEvent();
}

/// Emitted when speech ends with recorded audio.
class VadSpeechEndEvent extends VadEvent {
  /// Emitted when speech ends with recorded audio.
  const VadSpeechEndEvent({required this.audioData, required this.durationMs});

  /// PCM16 audio data of the speech segment.
  final Int16List audioData;

  /// Duration of the speech segment in milliseconds.
  final int durationMs;
}

/// Emitted for each processed audio frame.
class VadFrameProcessedEvent extends VadEvent {
  /// Emitted for each processed audio frame.
  const VadFrameProcessedEvent({
    required this.probability,
    required this.isSpeech,
  });

  /// Speech probability (0.0 - 1.0).
  final double probability;

  /// Whether the frame is classified as speech.
  final bool isSpeech;
}

/// Emitted when real speech is confirmed (after minSpeechFrames).
class VadRealSpeechStartEvent extends VadEvent {
  /// Emitted when real speech is confirmed (after minSpeechFrames).
  const VadRealSpeechStartEvent();
}

/// Emitted when detected speech was too short (misfire).
class VadMisfireEvent extends VadEvent {
  /// Emitted when detected speech was too short (misfire).
  const VadMisfireEvent();
}

/// Emitted when an error occurs.
class VadErrorEvent extends VadEvent {
  /// Emitted when an error occurs.
  const VadErrorEvent({required this.message, required this.code});

  /// Error message.
  final String message;

  /// Error code.
  final int code;
}

/// Emitted when VAD is stopped.
class VadStoppedEvent extends VadEvent {
  /// Emitted when VAD is stopped.
  const VadStoppedEvent();
}

// ============================================================================
// VAD Plus - Main API
// ============================================================================

/// Voice Activity Detection using Silero VAD ONNX model.
///
/// Example usage:
/// ```dart
/// final vad = VadPlus();
///
/// // Listen to events
/// vad.events.listen((event) {
///   if (event is VadSpeechEndEvent) {
///     print('Speech detected: ${event.durationMs}ms');
///     // Process event.audioData
///   }
/// });
///
/// // Initialize with config
/// await vad.initialize(config: VadConfig.v6_16kHz());
///
/// // Start listening from microphone
/// await vad.start();
///
/// // Later, stop and dispose
/// vad.stop();
/// vad.dispose();
/// ```
class VadPlus {
  Pointer<VADHandle>? _handle;
  final StreamController<VadEvent> _eventController =
      StreamController<VadEvent>.broadcast();

  bool _isInitialized = false;
  bool _isRunning = false;

  /// Stream of VAD events.
  Stream<VadEvent> get events => _eventController.stream;

  /// Whether VAD is initialized.
  bool get isInitialized => _isInitialized;

  /// Whether VAD is currently running.
  bool get isRunning => _isRunning;

  /// Whether speech is currently being detected.
  bool get isSpeaking {
    if (_handle == null) return false;
    return _bindings.vad_is_speaking(_handle!);
  }

  /// Initialize the VAD with the given configuration.
  ///
  /// [config] - VAD configuration options.
  /// [modelPath] - Optional path to custom ONNX model file.
  Future<void> initialize({
    VadConfig config = const VadConfig(),
    String? modelPath,
  }) async {
    if (_isInitialized) {
      throw StateError('VAD is already initialized. Call dispose() first.');
    }

    // Create handle
    _handle = _bindings.vad_create();
    if (_handle == null || _handle == nullptr) {
      throw Exception('Failed to create VAD handle');
    }

    // Set up callback
    _setupCallback();

    // Prepare native config
    final nativeConfig = calloc<VADConfig>();
    nativeConfig.ref.positive_speech_threshold = config.positiveSpeechThreshold;
    nativeConfig.ref.negative_speech_threshold = config.negativeSpeechThreshold;
    nativeConfig.ref.pre_speech_pad_frames = config.preSpeechPadFrames;
    nativeConfig.ref.redemption_frames = config.redemptionFrames;
    nativeConfig.ref.min_speech_frames = config.minSpeechFrames;
    nativeConfig.ref.sample_rate = config.sampleRate;
    nativeConfig.ref.frame_samples = config.frameSamples;
    nativeConfig.ref.end_speech_pad_frames = config.endSpeechPadFrames;
    nativeConfig.ref.is_debug = config.isDebug ? 1 : 0;

    // Prepare model path
    final Pointer<Char> nativeModelPath;
    if (modelPath != null) {
      nativeModelPath = modelPath.toNativeUtf8().cast<Char>();
    } else {
      nativeModelPath = nullptr;
    }

    try {
      final result = _bindings.vad_init(
        _handle!,
        nativeConfig,
        nativeModelPath,
      );
      if (result != 0) {
        final error = _getLastError();
        throw Exception('Failed to initialize VAD (code: $result): $error');
      }
      _isInitialized = true;
    } finally {
      calloc.free(nativeConfig);
      if (modelPath != null) {
        calloc.free(nativeModelPath);
      }
    }
  }

  /// Start audio capture and VAD processing.
  Future<void> start() async {
    _ensureInitialized();
    if (_isRunning) {
      throw StateError('VAD is already running');
    }

    final result = _bindings.vad_start(_handle!);
    if (result != 0) {
      final error = _getLastError();
      throw Exception('Failed to start VAD (code: $result): $error');
    }
    _isRunning = true;
  }

  /// Stop audio capture and VAD processing.
  void stop() {
    if (_handle != null && _isRunning) {
      _bindings.vad_stop(_handle!);
      _isRunning = false;
    }
  }

  /// Process audio samples directly (without microphone capture).
  ///
  /// Use this when you have your own audio source.
  /// [samples] - Float32 audio samples normalized to -1.0 to 1.0.
  void processAudio(Float32List samples) {
    _ensureInitialized();

    final nativeSamples = calloc<Float>(samples.length);
    try {
      for (var i = 0; i < samples.length; i++) {
        nativeSamples[i] = samples[i];
      }
      _bindings.vad_process_audio(_handle!, nativeSamples, samples.length);
    } finally {
      calloc.free(nativeSamples);
    }
  }

  /// Reset VAD state (clear buffers and speech detection state).
  void reset() {
    if (_handle != null) {
      _bindings.vad_reset(_handle!);
    }
  }

  /// Force end current speech segment if any.
  void forceEndSpeech() {
    if (_handle != null) {
      _bindings.vad_force_end_speech(_handle!);
    }
  }

  /// Dispose of the VAD instance and release resources.
  void dispose() {
    stop();
    if (_handle != null) {
      _bindings.vad_destroy(_handle!);
      _handle = null;
    }
    _isInitialized = false;
    _eventController.close();
  }

  // ===========================================================================
  // Private Methods
  // ===========================================================================

  void _ensureInitialized() {
    if (!_isInitialized || _handle == null) {
      throw StateError('VAD is not initialized. Call initialize() first.');
    }
  }

  String _getLastError() {
    if (_handle == null) return 'Unknown error';
    final errorPtr = _bindings.vad_get_last_error(_handle!);
    if (errorPtr == nullptr) return 'Unknown error';
    return errorPtr.cast<Utf8>().toDartString();
  }

  void _setupCallback() {
    // Note: For proper callback handling with native code,
    // we use NativeCallable.
    // The Swift implementation handles events and
    // dispatches them to the main thread.
    // This callback bridge allows native code to notify Dart of VAD events.

    // TODO: Implement proper NativeCallable for callback handling
    // For now, the Swift side manages its own callback mechanism
  }

  /// Handle native VAD events and dispatch to the Dart stream.
  /// This is called from the native callback bridge.
  void handleNativeEvent(VADEvent event) {
    switch (event.type) {
      case VADEventType.initialized:
        _eventController.add(const VadInitializedEvent());
        break;
      case VADEventType.speechStart:
        _eventController.add(const VadSpeechStartEvent());
        break;
      case VADEventType.speechEnd:
        final audioLength = event.speech_end_audio_length;
        final audioPtr = event.speech_end_audio_data;
        if (audioPtr != nullptr && audioLength > 0) {
          final audioData = Int16List(audioLength);
          for (var i = 0; i < audioLength; i++) {
            audioData[i] = audioPtr[i];
          }
          _eventController.add(
            VadSpeechEndEvent(
              audioData: audioData,
              durationMs: event.speech_end_duration_ms,
            ),
          );
        }
        break;
      case VADEventType.frameProcessed:
        _eventController.add(
          VadFrameProcessedEvent(
            probability: event.frame_probability,
            isSpeech: event.frame_is_speech != 0,
          ),
        );
        break;
      case VADEventType.realSpeechStart:
        _eventController.add(const VadRealSpeechStartEvent());
        break;
      case VADEventType.misfire:
        _eventController.add(const VadMisfireEvent());
        break;
      case VADEventType.error:
        final messagePtr = event.error_message;
        final message = messagePtr != nullptr
            ? messagePtr.cast<Utf8>().toDartString()
            : 'Unknown error';
        _eventController.add(
          VadErrorEvent(message: message, code: event.error_code),
        );
        break;
      case VADEventType.stopped:
        _eventController.add(const VadStoppedEvent());
        break;
    }
  }
}

// ============================================================================
// Utility Functions
// ============================================================================

/// Convert float32 audio samples to PCM16.
Int16List floatToPcm16(Float32List floatSamples) {
  final pcm16Samples = calloc<Int16>(floatSamples.length);
  final floatPtr = calloc<Float>(floatSamples.length);

  try {
    for (var i = 0; i < floatSamples.length; i++) {
      floatPtr[i] = floatSamples[i];
    }

    _bindings.vad_float_to_pcm16(floatPtr, pcm16Samples, floatSamples.length);

    final result = Int16List(floatSamples.length);
    for (var i = 0; i < floatSamples.length; i++) {
      result[i] = pcm16Samples[i];
    }
    return result;
  } finally {
    calloc
      ..free(pcm16Samples)
      ..free(floatPtr);
  }
}

/// Convert PCM16 audio samples to float32.
Float32List pcm16ToFloat(Int16List pcm16Samples) {
  final floatSamples = calloc<Float>(pcm16Samples.length);
  final pcm16Ptr = calloc<Int16>(pcm16Samples.length);

  try {
    for (var i = 0; i < pcm16Samples.length; i++) {
      pcm16Ptr[i] = pcm16Samples[i];
    }

    _bindings.vad_pcm16_to_float(pcm16Ptr, floatSamples, pcm16Samples.length);

    final result = Float32List(pcm16Samples.length);
    for (var i = 0; i < pcm16Samples.length; i++) {
      result[i] = floatSamples[i];
    }
    return result;
  } finally {
    calloc
      ..free(floatSamples)
      ..free(pcm16Ptr);
  }
}

// ============================================================================
// Library Loading
// ============================================================================

const String _libName = 'vad_plus';

/// The dynamic library in which the symbols for [VadPlusBindings] can be found.
final DynamicLibrary _dylib = () {
  if (Platform.isMacOS || Platform.isIOS) {
    // On iOS/macOS, the Swift FFI functions are statically linked into
    // the main app binary, so we use process() to look up symbols.
    return DynamicLibrary.process();
  }
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('lib$_libName.so');
  }
  if (Platform.isWindows) {
    return DynamicLibrary.open('$_libName.dll');
  }
  throw UnsupportedError('Unknown platform: ${Platform.operatingSystem}');
}();

/// The bindings to the native functions in [_dylib].
final VadPlusBindings _bindings = VadPlusBindings(_dylib);
