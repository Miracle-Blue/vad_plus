part of '../screen/home_screen.dart';

/// Represents a recorded voice segment
class RecordedVoice {
  RecordedVoice({required this.audioData, required this.durationMs, required this.timestamp});

  final Int16List audioData;
  final int durationMs;
  final DateTime timestamp;
  bool isPlaying = false;
  AudioSource? audioSource;
  SoundHandle? soundHandle;
}

/// State for widget HomeScreen.
abstract class HomeScreenState extends State<HomeScreen> {
  VadPlus? _vad;
  StreamSubscription<VadEvent>? _eventSubscription;

  bool _isInitialized = false;
  bool _isListening = false;
  bool _isSpeaking = false;
  double _currentProbability = 0.0;
  String _statusMessage = 'Not initialized';
  final List<String> _eventLog = [];
  int _speechSegmentCount = 0;

  bool _isPlaying = false;
  SoundHandle? musicHandle;

  // Recorded voices storage
  final List<RecordedVoice> _recordedVoices = [];

  Future<void> _initSoLoud() async {
    // On macOS sandboxed apps, we need to ensure the cache directory exists
    // before SoLoud.init() because flutter_soloud doesn't create parent dirs
    if (Platform.isMacOS) {
      try {
        final cacheDir = await getApplicationCacheDirectory();
        if (!await cacheDir.exists()) {
          await cacheDir.create(recursive: true);
        }
      } catch (e) {
        log('Failed to create cache directory: $e');
      }
    }

    try {
      await SoLoud.instance.init();
    } catch (e) {
      log('Failed to initialize SoLoud: $e');
    }
  }

  Future<void> _initializeVad() async {
    final stopwatch = Stopwatch()..start();
    try {
      _vad = VadPlus();

      // Subscribe to VAD events
      _eventSubscription = _vad!.events.listen(_handleVadEvent);

      // Initialize with default v6 16kHz configuration
      await _vad!.initialize(
        config: const VadConfig(isDebug: true, positiveSpeechThreshold: 0.5, negativeSpeechThreshold: 0.35),
      );

      setState(() {
        _isInitialized = true;
        _statusMessage = 'Initialized - Ready to start';
        _addLog('✅ VAD initialized');
      });
    } catch (e) {
      log(e.toString());
      setState(() {
        _statusMessage = 'Error: $e';
        _addLog('❌ Init error: $e');
      });
    } finally {
      log('${(stopwatch..stop()).elapsedMicroseconds} μs', name: 'initialize VAD', level: 100);
    }
  }

  Future<void> _startListening() async {
    if (!_isInitialized || _vad == null) return;

    // Request microphone permission (not supported on macOS - permission is requested automatically)
    if (!kIsWeb && !Platform.isMacOS) {
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        setState(() {
          _statusMessage = 'Microphone permission denied';
          _addLog('❌ Microphone permission denied');
        });
        return;
      }
    }

    final stopwatch = Stopwatch()..start();
    try {
      await _vad!.start();
      setState(() {
        _isListening = true;
        _statusMessage = 'Listening for speech...';
        _addLog('🎤 Started listening');
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Start error: $e';
        _addLog('❌ Start error: $e');
      });
    } finally {
      log('${(stopwatch..stop()).elapsedMicroseconds} μs', name: 'start VAD', level: 100);
    }
  }

  void _stopListening() {
    final stopwatch = Stopwatch()..start();
    try {
      if (_vad == null) return;

      _vad!.stop();
      setState(() {
        _isListening = false;
        _isSpeaking = false;
        _currentProbability = 0.0;
        _statusMessage = 'Stopped - Ready to start';
        _addLog('⏹️ Stopped listening');
      });
    } finally {
      log('${(stopwatch..stop()).elapsedMicroseconds} μs', name: 'stop VAD', level: 100);
    }
  }

  void _stopAndDispose() {
    final stopwatch = Stopwatch()..start();
    try {
      _eventSubscription?.cancel();
      _vad?.dispose();
      _vad = null;

      _isInitialized = false;
      _isListening = false;
      _isSpeaking = false;
      _currentProbability = 0.0;
      _statusMessage = 'Not initialized';
      _addLog('❌ VAD stopped and disposed');
    } finally {
      log('${(stopwatch..stop()).elapsedMicroseconds} μs', name: 'stop and dispose VAD', level: 100);
    }
  }

  void _handleVadEvent(VadEvent event) {
    switch (event) {
      case VadInitialized():
        _addLog('📢 Event: Initialized');
        break;

      case VadSpeechStart():
        setState(() {
          _isSpeaking = true;
          _statusMessage = '🗣️ Speech detected...';
        });
        _addLog('🗣️ Speech started');

        if (musicHandle != null) {
          SoLoud.instance.fadeVolume(musicHandle!, 0.3, Duration(milliseconds: 100));
        }

        break;

      case VadSpeechEnd():
        setState(() {
          _isSpeaking = false;
          _speechSegmentCount++;
          _statusMessage = '✅ Speech ended (${event.durationMs}ms, ${event.audioData.length} samples)';

          // Store the recorded voice segment
          _recordedVoices.insert(
            0,
            RecordedVoice(audioData: event.audioData, durationMs: event.durationMs, timestamp: DateTime.now()),
          );
        });
        _addLog('🔇 Speech ended: ${event.durationMs}ms, ${event.audioData.length} samples');

        if (musicHandle != null) {
          SoLoud.instance.fadeVolume(musicHandle!, 1.0, Duration(milliseconds: 500));
        }

        break;

      case VadFrameProcessed():
        setState(() {
          _currentProbability = event.probability;
          // _addLog('📢 Frame processed: ${event.probability}, ${event.audioData.length} samples');
        });
        break;

      case VadRealSpeechStart():
        _addLog('✨ Real speech confirmed');
        break;

      case VadMisfire():
        setState(() {
          _isSpeaking = false;
          _statusMessage = '⚡ Misfire (too short)';
        });
        _addLog('⚡ Misfire - speech too short');

        if (musicHandle != null) {
          SoLoud.instance.fadeVolume(musicHandle!, 1.0, Duration(milliseconds: 500));
        }

        break;

      case VadError():
        setState(() {
          _statusMessage = '❌ Error: ${event.message}';
        });
        _addLog('❌ Error: ${event.message} (code: ${event.code})');
        break;

      case VadStopped():
        _addLog('⏹️ VAD stopped');
        break;
    }
  }

  void _addLog(String message) {
    setState(() {
      final timestamp = DateTime.now().toString().substring(11, 19);
      _eventLog.insert(0, '[$timestamp] $message');
      if (_eventLog.length > 50) {
        _eventLog.removeLast();
      }
    });
  }

  void _clearLog() {
    setState(() {
      _eventLog.clear();
    });
  }

  Future<void> _playRecordedVoice(RecordedVoice voice) async {
    log('_playRecordedVoice called, audioData length: ${voice.audioData.length}');

    // Check if SoLoud is initialized
    if (!SoLoud.instance.isInitialized) {
      _addLog('❌ SoLoud not initialized');
      log('SoLoud not initialized');
      return;
    }

    try {
      // Stop any currently playing recorded voice
      for (final v in _recordedVoices) {
        if (v.isPlaying && v != voice) {
          await _stopRecordedVoice(v);
        }
      }

      if (voice.isPlaying) {
        await _stopRecordedVoice(voice);
        return;
      }

      // Create a buffer stream for the audio data (16kHz mono PCM16)
      // Add extra buffer space to avoid "buffer full" errors due to internal overhead
      final bufferSize = voice.audioData.lengthInBytes + 4096;
      log('Creating buffer stream with size: $bufferSize bytes');

      final audioSource = SoLoud.instance.setBufferStream(
        bufferingTimeNeeds: 1,
        bufferingType: BufferingType.released,
        sampleRate: 16000,
        channels: Channels.mono,
        format: BufferType.s16le,
      );
      log('Buffer stream created: $audioSource');

      // Add the audio data to the stream
      final audioBytes = voice.audioData.buffer.asUint8List();
      log('Adding ${audioBytes.length} bytes to stream');
      SoLoud.instance.addAudioDataStream(audioSource, audioBytes);
      log('Audio data added');

      // Mark the stream as complete
      SoLoud.instance.setDataIsEnded(audioSource);
      log('Stream marked as ended');

      // Play the audio
      final handle = await SoLoud.instance.play(audioSource);
      log('Playing with handle: $handle');

      setState(() {
        voice.audioSource = audioSource;
        voice.soundHandle = handle;
        voice.isPlaying = true;
      });

      _addLog('▶️ Playing recorded voice (${voice.durationMs}ms)');

      // Auto-stop when playback finishes
      Future.delayed(Duration(milliseconds: voice.durationMs + 100), () {
        if (voice.isPlaying && mounted) {
          _stopRecordedVoice(voice);
        }
      });
    } catch (e, stackTrace) {
      log('Error playing recorded voice: $e\n$stackTrace');
      _addLog('❌ Playback error: $e');
    }
  }

  Future<void> _stopRecordedVoice(RecordedVoice voice) async {
    try {
      if (voice.soundHandle != null) {
        await SoLoud.instance.stop(voice.soundHandle!);
      }
      if (voice.audioSource != null) {
        await SoLoud.instance.disposeSource(voice.audioSource!);
      }
    } catch (e) {
      log('Error stopping recorded voice: $e');
    } finally {
      if (mounted) {
        setState(() {
          voice.isPlaying = false;
          voice.soundHandle = null;
          voice.audioSource = null;
        });
      }
    }
  }

  void _clearRecordedVoices() {
    // Stop all playing voices first
    for (final voice in _recordedVoices) {
      if (voice.isPlaying) {
        _stopRecordedVoice(voice);
      }
    }
    setState(() {
      _recordedVoices.clear();
    });
    _addLog('🗑️ Cleared all recorded voices');
  }

  void _deleteRecordedVoice(RecordedVoice voice) {
    if (voice.isPlaying) {
      _stopRecordedVoice(voice);
    }
    setState(() {
      _recordedVoices.remove(voice);
    });
    _addLog('🗑️ Deleted recorded voice');
  }

  /* #region Lifecycle */
  @override
  void initState() {
    super.initState();

    _isPlaying = false;

    _initSoLoud();
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Widget configuration changed
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The configuration of InheritedWidgets has changed
    // Also called after initState but before build
  }

  @override
  void dispose() {
    _stopAndDispose();
    super.dispose();
  }

  /* #endregion */
}
