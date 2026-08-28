part of '../screen/home_screen.dart';

/// An immutable speech segment captured by the VAD.
class RecordedVoice {
  const RecordedVoice({required this.audioData, required this.durationMs, required this.timestamp});

  final Int16List audioData;
  final int durationMs;
  final DateTime timestamp;

  /// Audio length in ms (samples ÷ 16 kHz).
  int get audioMs => audioData.length ~/ 16;
}

/// State for widget HomeScreen.
abstract class HomeScreenState extends State<HomeScreen> {
  static const int _maxLogEntries = 50;

  // VAD
  VadPlus? _vad;
  StreamSubscription<VadEvent>? _eventSubscription;

  // Low-frequency UI state (setState-driven)
  bool _isInitialized = false;
  bool _isListening = false;
  bool _isSpeaking = false;
  String _statusMessage = 'Not initialized';
  int _speechSegmentCount = 0;
  final List<String> _eventLog = [];

  /// Speech probability, updated ~31×/s — a [ValueNotifier] so only the
  /// probability bar rebuilds per frame, not the whole screen.
  final ValueNotifier<double> _probability = ValueNotifier<double>(0);

  // Background music
  SoundHandle? _musicHandle;
  bool _isMusicPlaying = false;

  // Voice playback (single slot — only one voice plays at a time)
  RecordedVoice? _playingVoice;
  AudioSource? _voiceSource;
  SoundHandle? _voiceHandle;

  final List<RecordedVoice> _recordedVoices = [];

  @override
  void initState() {
    super.initState();
    _initSoLoud();
  }

  @override
  void dispose() {
    _disposeVad();
    _probability.dispose();
    super.dispose();
  }

  /* #region VAD */

  Future<void> _initSoLoud() async {
    // On macOS sandboxed apps, ensure the cache directory exists before
    // SoLoud.init() because flutter_soloud doesn't create parent dirs.
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
    try {
      _vad = VadPlus();

      // Subscribe before initialize() so no event is missed.
      _eventSubscription = _vad!.events.listen(_handleVadEvent);

      // Default v6 16 kHz configuration.
      await _vad!.initialize(
        config: const VadConfig(isDebug: true, positiveSpeechThreshold: 0.5, negativeSpeechThreshold: 0.35),
      );

      setState(() {
        _isInitialized = true;
        _statusMessage = 'Initialized - Ready to start';
      });
      _addLog('✅ VAD initialized');
    } catch (e) {
      log(e.toString());
      setState(() => _statusMessage = 'Error: $e');
      _addLog('❌ Init error: $e');
    }
  }

  Future<void> _startListening() async {
    if (!_isInitialized || _vad == null) return;

    // Request microphone permission (macOS prompts automatically via its entitlement).
    if (!kIsWeb && !Platform.isMacOS) {
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        setState(() => _statusMessage = 'Microphone permission denied');
        _addLog('❌ Microphone permission denied');
        return;
      }
    }

    try {
      await _vad!.start();
      setState(() {
        _isListening = true;
        _statusMessage = 'Listening for speech...';
      });
      _addLog('🎤 Started listening');
    } catch (e) {
      setState(() => _statusMessage = 'Start error: $e');
      _addLog('❌ Start error: $e');
    }
  }

  void _stopListening() {
    if (_vad == null) return;

    _vad!.stop();
    _probability.value = 0;
    setState(() {
      _isListening = false;
      _isSpeaking = false;
      _statusMessage = 'Stopped - Ready to start';
    });
    _addLog('⏹️ Stopped listening');
  }

  /// Pure teardown — safe to call from [dispose] (no setState, no logging).
  void _disposeVad() {
    _eventSubscription?.cancel();
    _eventSubscription = null;
    _vad?.dispose();
    _vad = null;
  }

  void _stopAndDispose() {
    _disposeVad();
    _probability.value = 0;
    setState(() {
      _isInitialized = false;
      _isListening = false;
      _isSpeaking = false;
      _statusMessage = 'Not initialized';
    });
    _addLog('❌ VAD stopped and disposed');
  }

  void _handleVadEvent(VadEvent event) {
    switch (event) {
      case VadInitialized():
        _addLog('📢 Event: Initialized');

      case VadSpeechStart():
        setState(() {
          _isSpeaking = true;
          _statusMessage = '🗣️ Speech detected...';
        });
        _addLog('🗣️ Speech started');
        _duckMusic();

      case VadSpeechEnd(:final audioData, :final durationMs):
        setState(() {
          _isSpeaking = false;
          _speechSegmentCount++;
          _statusMessage = '✅ Speech ended (${durationMs}ms, ${audioData.length} samples)';
          _recordedVoices.insert(
            0,
            RecordedVoice(audioData: audioData, durationMs: durationMs, timestamp: DateTime.now()),
          );
        });
        _addLog('🔇 Speech ended: ${durationMs}ms, ${audioData.length} samples');
        _restoreMusic();

      case VadFrameProcessed(:final probability):
        _probability.value = probability;

      case VadRealSpeechStart():
        _addLog('✨ Real speech confirmed');

      case VadMisfire():
        setState(() {
          _isSpeaking = false;
          _statusMessage = '⚡ Misfire (too short)';
        });
        _addLog('⚡ Misfire - speech too short');
        _restoreMusic();

      case VadError(:final message, :final code):
        setState(() => _statusMessage = '❌ Error: $message');
        _addLog('❌ Error: $message (code: $code)');

      case VadStopped():
        _addLog('⏹️ VAD stopped');
    }
  }

  /* #endregion */

  /* #region Music */

  Future<void> _toggleMusic() async {
    try {
      if (_isMusicPlaying) {
        if (_musicHandle case final handle?) {
          await SoLoud.instance.stop(handle);
        }
        _musicHandle = null;
        setState(() => _isMusicPlaying = false);
      } else {
        final source = await SoLoud.instance.loadAsset('assets/music/skyfall.mp3');
        _musicHandle = await SoLoud.instance.play(source);
        setState(() => _isMusicPlaying = true);
      }
    } on Object catch (error, stackTrace) {
      log('Error: $error, stackTrace: $stackTrace', name: 'play music', level: 100);
    }
  }

  void _duckMusic() {
    if (_musicHandle case final handle?) {
      SoLoud.instance.fadeVolume(handle, 0.3, const Duration(milliseconds: 100));
    }
  }

  void _restoreMusic() {
    if (_musicHandle case final handle?) {
      SoLoud.instance.fadeVolume(handle, 1.0, const Duration(milliseconds: 500));
    }
  }

  /* #endregion */

  /* #region Recorded voices */

  Future<void> _playRecordedVoice(RecordedVoice voice) async {
    if (!SoLoud.instance.isInitialized) {
      _addLog('❌ SoLoud not initialized');
      return;
    }

    // Tapping the playing voice stops it; tapping another switches to it.
    final wasPlaying = identical(voice, _playingVoice);
    await _stopPlayback();
    if (wasPlaying) return;

    try {
      // 16 kHz mono PCM16 — matches the VAD segment format.
      final source = SoLoud.instance.setBufferStream(
        bufferingTimeNeeds: 1,
        bufferingType: BufferingType.released,
        sampleRate: 16000,
        channels: Channels.mono,
        format: BufferType.s16le,
      );
      SoLoud.instance.addAudioDataStream(source, voice.audioData.buffer.asUint8List());
      SoLoud.instance.setDataIsEnded(source);
      final handle = await SoLoud.instance.play(source);

      setState(() {
        _playingVoice = voice;
        _voiceSource = source;
        _voiceHandle = handle;
      });
      _addLog('▶️ Playing recorded voice (${voice.durationMs}ms)');

      // Auto-stop when playback finishes. The stream closes without an event
      // when the source is disposed by a manual stop — hence the empty onError.
      unawaited(
        source.allInstancesFinished.first.then((_) {
          if (mounted && identical(_playingVoice, voice)) _stopPlayback();
        }, onError: (Object _) {}),
      );
    } catch (e, stackTrace) {
      log('Error playing recorded voice: $e\n$stackTrace');
      _addLog('❌ Playback error: $e');
    }
  }

  Future<void> _stopPlayback() async {
    final handle = _voiceHandle;
    final source = _voiceSource;
    if (_playingVoice == null && handle == null && source == null) return;

    // Clear the slot first so the finished-event callback can't re-enter.
    if (mounted) {
      setState(() {
        _playingVoice = null;
        _voiceHandle = null;
        _voiceSource = null;
      });
    } else {
      _playingVoice = null;
      _voiceHandle = null;
      _voiceSource = null;
    }

    try {
      if (handle != null) await SoLoud.instance.stop(handle);
      if (source != null) await SoLoud.instance.disposeSource(source);
    } catch (e) {
      log('Error stopping recorded voice: $e');
    }
  }

  void _deleteRecordedVoice(RecordedVoice voice) {
    if (identical(voice, _playingVoice)) unawaited(_stopPlayback());
    setState(() => _recordedVoices.remove(voice));
    _addLog('🗑️ Deleted recorded voice');
  }

  void _clearRecordedVoices() {
    unawaited(_stopPlayback());
    setState(() => _recordedVoices.clear());
    _addLog('🗑️ Cleared all recorded voices');
  }

  /* #endregion */

  /* #region Event log */

  static String _hhmmss(DateTime time) => time.toString().substring(11, 19);

  void _addLog(String message) {
    if (!mounted) return;
    setState(() {
      _eventLog.insert(0, '[${_hhmmss(DateTime.now())}] $message');
      if (_eventLog.length > _maxLogEntries) {
        _eventLog.removeLast();
      }
    });
  }

  void _clearLog() => setState(_eventLog.clear);

  /* #endregion */
}
