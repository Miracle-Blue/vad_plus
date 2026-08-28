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

part '../state/home_state.dart';

/// {@template home_screen}
/// HomeScreen widget.
/// {@endtemplate}
class HomeScreen extends StatefulWidget {
  /// {@macro home_screen}
  const HomeScreen({
    super.key, // ignore: unused_element
  });

  /// The state from the closest instance of this class
  /// that encloses the given context, if any.
  @internal
  static HomeScreenState? maybeOf(BuildContext context) => context.findAncestorStateOfType<_HomeScreenState>();

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends HomeScreenState {
  @override
  Widget build(BuildContext context) => Scaffold(
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
            border: Border.all(color: _isSpeaking ? Colors.green : Colors.grey.shade700, width: 2),
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
                                  color: voice.isPlaying ? Colors.tealAccent.withValues(alpha: 0.15) : Colors.black45,
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
  );
}
