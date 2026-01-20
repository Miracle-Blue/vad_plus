import 'dart:async';

import 'package:flutter/material.dart';
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

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _stopAndDispose();
    super.dispose();
  }

  Future<void> _initializeVad() async {
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
      setState(() {
        _statusMessage = 'Error: $e';
        _addLog('❌ Init error: $e');
      });
    }
  }

  Future<void> _startListening() async {
    if (!_isInitialized || _vad == null) return;

    // Request microphone permission
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      setState(() {
        _statusMessage = 'Microphone permission denied';
        _addLog('❌ Microphone permission denied');
      });
      return;
    }

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
    }
  }

  void _stopListening() {
    if (_vad == null) return;

    _vad!.stop();
    setState(() {
      _isListening = false;
      _isSpeaking = false;
      _currentProbability = 0.0;
      _statusMessage = 'Stopped - Ready to start';
      _addLog('⏹️ Stopped listening');
    });
  }

  void _stopAndDispose() {
    _eventSubscription?.cancel();
    _vad?.dispose();
    _vad = null;
  }

  void _handleVadEvent(VadEvent event) {
    switch (event) {
      case VadInitializedEvent():
        _addLog('📢 Event: Initialized');
        break;

      case VadSpeechStartEvent():
        setState(() {
          _isSpeaking = true;
          _statusMessage = '🗣️ Speech detected...';
        });
        _addLog('🗣️ Speech started');
        break;

      case VadSpeechEndEvent():
        setState(() {
          _isSpeaking = false;
          _speechSegmentCount++;
          _statusMessage = '✅ Speech ended (${event.durationMs}ms, ${event.audioData.length} samples)';
        });
        _addLog('🔇 Speech ended: ${event.durationMs}ms, ${event.audioData.length} samples');
        break;

      case VadFrameProcessedEvent():
        setState(() {
          _currentProbability = event.probability;
        });
        // Don't log every frame to avoid spam
        break;

      case VadRealSpeechStartEvent():
        _addLog('✨ Real speech confirmed');
        break;

      case VadMisfireEvent():
        setState(() {
          _isSpeaking = false;
          _statusMessage = '⚡ Misfire (too short)';
        });
        _addLog('⚡ Misfire - speech too short');
        break;

      case VadErrorEvent():
        setState(() {
          _statusMessage = '❌ Error: ${event.message}';
        });
        _addLog('❌ Error: ${event.message} (code: ${event.code})');
        break;

      case VadStoppedEvent():
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
                      onPressed: _isInitialized ? null : _initializeVad,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Initialize'),
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
