import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vad_plus/vad_plus.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

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

class _MyAppState extends State<MyApp> {
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

  @override
  void initState() {
    super.initState();

    _isPlaying = false;

    _initSoLoud();
  }

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

  @override
  void dispose() {
    _stopAndDispose();
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark().copyWith(
        colorScheme: ColorScheme.dark(primary: Colors.teal, secondary: Colors.tealAccent, surface: Colors.grey[900]!),
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('VAD Plus Demo'),
          backgroundColor: Colors.grey[850],
          actions: [IconButton(icon: const Icon(Icons.delete_outline), onPressed: _clearLog, tooltip: 'Clear log')],
        ),
        body: Column(
          children: [
            // Status Card
            Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.grey[850],
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _isSpeaking ? Colors.green : Colors.grey[700]!, width: 2),
              ),
              child: Column(
                children: [
                  // Microphone indicator
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _isSpeaking
                          ? Colors.green.withValues(alpha: 0.3)
                          : _isListening
                          ? Colors.blue.withValues(alpha: 0.2)
                          : Colors.grey.withValues(alpha: 0.2),
                    ),
                    child: Icon(
                      _isListening ? Icons.mic : Icons.mic_off,
                      size: 40,
                      color: _isSpeaking
                          ? Colors.green
                          : _isListening
                          ? Colors.blue
                          : Colors.grey,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Status message
                  Text(_statusMessage, style: const TextStyle(fontSize: 16), textAlign: TextAlign.center),
                  const SizedBox(height: 16),

                  // Probability bar
                  if (_isListening) ...[
                    Row(
                      children: [
                        const Text('Speech: '),
                        Expanded(
                          child: LinearProgressIndicator(
                            value: _currentProbability,
                            backgroundColor: Colors.grey[800],
                            valueColor: AlwaysStoppedAnimation<Color>(
                              _currentProbability >= 0.5 ? Colors.green : Colors.grey,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text('${(_currentProbability * 100).toStringAsFixed(0)}%'),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Speech segments detected: $_speechSegmentCount',
                      style: TextStyle(color: Colors.grey[400], fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),

            // Control buttons
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _isInitialized ? _stopAndDispose : _initializeVad,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Initialize/Dispose'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.teal,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: !_isInitialized
                          ? null
                          : _isListening
                          ? _stopListening
                          : _startListening,
                      icon: Icon(_isListening ? Icons.stop : Icons.mic),
                      label: Text(_isListening ? 'Stop' : 'Start'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isListening ? Colors.red : Colors.blue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            ElevatedButton(
              onPressed: () async {
                try {
                  if (_isPlaying) {
                    log('Stopping music...', name: 'play music', level: 100);
                    await SoLoud.instance.stop(musicHandle!);
                    musicHandle = null;
                    setState(() {
                      _isPlaying = false;
                    });
                  } else {
                    log('Loading music...', name: 'play music', level: 100);
                    final musicSource = await SoLoud.instance.loadAsset('assets/music/skyfall.mp3');
                    musicHandle = await SoLoud.instance.play(musicSource);
                    setState(() {
                      _isPlaying = true;
                    });
                  }
                } on Object catch (error, stackTrace) {
                  log('Error: $error, stackTrace: $stackTrace', name: 'play music', level: 100);
                }
              },
              child: const Text('Play/Stop Music'),
            ),

            const SizedBox(height: 16),

            // Recorded Voices Section
            Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.grey[850], borderRadius: BorderRadius.circular(12)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.record_voice_over, color: Colors.tealAccent, size: 20),
                            const SizedBox(width: 8),
                            const Text(
                              'Recorded Voices',
                              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.tealAccent),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.tealAccent.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '${_recordedVoices.length}',
                                style: const TextStyle(color: Colors.tealAccent, fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                        if (_recordedVoices.isNotEmpty)
                          IconButton(
                            icon: const Icon(Icons.delete_sweep, color: Colors.redAccent, size: 20),
                            onPressed: _clearRecordedVoices,
                            tooltip: 'Clear all recordings',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                      ],
                    ),
                    const Divider(color: Colors.grey),
                    Expanded(
                      child: _recordedVoices.isEmpty
                          ? Center(
                              child: Text(
                                'No recordings yet.\nSpeak while listening to capture audio.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.grey[500], fontSize: 13),
                              ),
                            )
                          : ListView.builder(
                              itemCount: _recordedVoices.length,
                              itemBuilder: (context, index) {
                                final voice = _recordedVoices[index];
                                final timeStr =
                                    '${voice.timestamp.hour.toString().padLeft(2, '0')}:'
                                    '${voice.timestamp.minute.toString().padLeft(2, '0')}:'
                                    '${voice.timestamp.second.toString().padLeft(2, '0')}';
                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 4),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: voice.isPlaying
                                          ? Colors.tealAccent.withValues(alpha: 0.15)
                                          : Colors.black45,
                                      borderRadius: BorderRadius.circular(8),
                                      border: voice.isPlaying
                                          ? Border.all(color: Colors.tealAccent.withValues(alpha: 0.5))
                                          : null,
                                    ),
                                    child: Row(
                                      children: [
                                        // Play/Stop button
                                        GestureDetector(
                                          onTap: () => _playRecordedVoice(voice),
                                          child: AnimatedContainer(
                                            duration: const Duration(milliseconds: 200),
                                            width: 36,
                                            height: 36,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              color: voice.isPlaying
                                                  ? Colors.tealAccent
                                                  : Colors.teal.withValues(alpha: 0.3),
                                            ),
                                            child: Icon(
                                              voice.isPlaying ? Icons.stop : Icons.play_arrow,
                                              color: voice.isPlaying ? Colors.black : Colors.tealAccent,
                                              size: 20,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        // Voice info
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                'Voice #${_recordedVoices.length - index}',
                                                style: TextStyle(
                                                  color: voice.isPlaying ? Colors.tealAccent : Colors.white,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                '$timeStr • ${voice.durationMs}ms • ${(voice.audioData.length / 16).toStringAsFixed(0)}ms',
                                                style: TextStyle(color: Colors.grey[400], fontSize: 11),
                                              ),
                                            ],
                                          ),
                                        ),
                                        // Delete button
                                        IconButton(
                                          icon: Icon(Icons.close, color: Colors.grey[500], size: 18),
                                          onPressed: () => _deleteRecordedVoice(voice),
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(),
                                          tooltip: 'Delete',
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 8),

            // Event log
            Expanded(
              child: Container(
                margin: const EdgeInsets.all(16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(12)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Event Log',
                      style: TextStyle(fontWeight: FontWeight.bold, color: Colors.tealAccent),
                    ),
                    const Divider(color: Colors.grey),
                    Expanded(
                      child: ListView.builder(
                        itemCount: _eventLog.length,
                        itemBuilder: (context, index) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text(
                              _eventLog[index],
                              style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.grey[300]),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
