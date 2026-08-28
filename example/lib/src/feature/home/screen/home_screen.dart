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
  const HomeScreen({super.key});

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
    body: ListView(
      shrinkWrap: true,
      children: [
        _StatusCard(
          isListening: _isListening,
          isSpeaking: _isSpeaking,
          statusMessage: _statusMessage,
          segmentCount: _speechSegmentCount,
          probability: _probability,
        ),
        _ControlButtons(
          isInitialized: _isInitialized,
          isListening: _isListening,
          onInitializeOrDispose: _isInitialized ? _stopAndDispose : _initializeVad,
          onStartOrStop: !_isInitialized
              ? null
              : _isListening
              ? _stopListening
              : _startListening,
        ),
        const SizedBox(height: 16),
        ElevatedButton(onPressed: _toggleMusic, child: const Text('Play/Stop Music')),
        const SizedBox(height: 16),
        SizedBox(
          height: 400,
          child: _RecordedVoicesPanel(
            voices: _recordedVoices,
            playingVoice: _playingVoice,
            onPlay: _playRecordedVoice,
            onDelete: _deleteRecordedVoice,
            onClearAll: _clearRecordedVoices,
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(height: 200, child: _EventLogPanel(entries: _eventLog)),
      ],
    ),
  );
}

/// Mic indicator, status message, and — while listening — the live
/// speech-probability bar and segment counter.
class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.isListening,
    required this.isSpeaking,
    required this.statusMessage,
    required this.segmentCount,
    required this.probability,
  });

  final bool isListening;
  final bool isSpeaking;
  final String statusMessage;
  final int segmentCount;
  final ValueListenable<double> probability;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.all(16),
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: Colors.grey[850],
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: isSpeaking ? Colors.green : Colors.grey.shade700, width: 2),
    ),
    child: Column(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isSpeaking
                ? Colors.green.withValues(alpha: 0.3)
                : isListening
                ? Colors.blue.withValues(alpha: 0.2)
                : Colors.grey.withValues(alpha: 0.2),
          ),
          child: Icon(
            isListening ? Icons.mic : Icons.mic_off,
            size: 40,
            color: isSpeaking
                ? Colors.green
                : isListening
                ? Colors.blue
                : Colors.grey,
          ),
        ),
        const SizedBox(height: 16),
        Text(statusMessage, style: const TextStyle(fontSize: 16), textAlign: TextAlign.center),
        const SizedBox(height: 16),
        if (isListening) ...[
          // Rebuilds only this row on each VadFrameProcessed (~31×/s).
          ValueListenableBuilder<double>(
            valueListenable: probability,
            builder: (context, value, _) => Row(
              children: [
                const Text('Speech: '),
                Expanded(
                  child: LinearProgressIndicator(
                    value: value,
                    backgroundColor: Colors.grey[800],
                    valueColor: AlwaysStoppedAnimation<Color>(value >= 0.5 ? Colors.green : Colors.grey),
                  ),
                ),
                const SizedBox(width: 8),
                Text('${(value * 100).toStringAsFixed(0)}%'),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text('Speech segments detected: $segmentCount', style: TextStyle(color: Colors.grey[400], fontSize: 12)),
        ],
      ],
    ),
  );
}

/// Initialize/Dispose and Start/Stop buttons.
class _ControlButtons extends StatelessWidget {
  const _ControlButtons({
    required this.isInitialized,
    required this.isListening,
    required this.onInitializeOrDispose,
    required this.onStartOrStop,
  });

  final bool isInitialized;
  final bool isListening;
  final VoidCallback onInitializeOrDispose;
  final VoidCallback? onStartOrStop;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed: onInitializeOrDispose,
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
            onPressed: onStartOrStop,
            icon: Icon(isListening ? Icons.stop : Icons.mic),
            label: Text(isListening ? 'Stop' : 'Start'),
            style: ElevatedButton.styleFrom(
              backgroundColor: isListening ? Colors.red : Colors.blue,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
      ],
    ),
  );
}

/// Captured speech segments with per-item play/delete and clear-all.
class _RecordedVoicesPanel extends StatelessWidget {
  const _RecordedVoicesPanel({
    required this.voices,
    required this.playingVoice,
    required this.onPlay,
    required this.onDelete,
    required this.onClearAll,
  });

  final List<RecordedVoice> voices;
  final RecordedVoice? playingVoice;
  final ValueChanged<RecordedVoice> onPlay;
  final ValueChanged<RecordedVoice> onDelete;
  final VoidCallback onClearAll;

  @override
  Widget build(BuildContext context) => Container(
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
                  child: Text('${voices.length}', style: const TextStyle(color: Colors.tealAccent, fontSize: 12)),
                ),
              ],
            ),
            if (voices.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.delete_sweep, color: Colors.redAccent, size: 20),
                onPressed: onClearAll,
                tooltip: 'Clear all recordings',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
          ],
        ),
        const Divider(color: Colors.grey),
        Expanded(
          child: voices.isEmpty
              ? Center(
                  child: Text(
                    'No recordings yet.\nSpeak while listening to capture audio.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey[500], fontSize: 13),
                  ),
                )
              : ListView.builder(
                  itemCount: voices.length,
                  itemBuilder: (context, index) {
                    final voice = voices[index];
                    return _VoiceTile(
                      voice: voice,
                      label: 'Voice #${voices.length - index}',
                      playing: identical(voice, playingVoice),
                      onPlay: () => onPlay(voice),
                      onDelete: () => onDelete(voice),
                    );
                  },
                ),
        ),
      ],
    ),
  );
}

/// One recorded segment: play/stop toggle, capture time, durations, delete.
class _VoiceTile extends StatelessWidget {
  const _VoiceTile({
    required this.voice,
    required this.label,
    required this.playing,
    required this.onPlay,
    required this.onDelete,
  });

  final RecordedVoice voice;
  final String label;
  final bool playing;
  final VoidCallback onPlay;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: playing ? Colors.tealAccent.withValues(alpha: 0.15) : Colors.black45,
        borderRadius: BorderRadius.circular(8),
        border: playing ? Border.all(color: Colors.tealAccent.withValues(alpha: 0.5)) : null,
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: onPlay,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: playing ? Colors.tealAccent : Colors.teal.withValues(alpha: 0.3),
              ),
              child: Icon(
                playing ? Icons.stop : Icons.play_arrow,
                color: playing ? Colors.black : Colors.tealAccent,
                size: 20,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(color: playing ? Colors.tealAccent : Colors.white, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 2),
                Text(
                  '${HomeScreenState._hhmmss(voice.timestamp)} • ${voice.durationMs}ms • ${voice.audioMs}ms',
                  style: TextStyle(color: Colors.grey[400], fontSize: 11),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.close, color: Colors.grey[500], size: 18),
            onPressed: onDelete,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            tooltip: 'Delete',
          ),
        ],
      ),
    ),
  );
}

/// Scrollable, timestamped event log.
class _EventLogPanel extends StatelessWidget {
  const _EventLogPanel({required this.entries});

  final List<String> entries;

  @override
  Widget build(BuildContext context) => Container(
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
            itemCount: entries.length,
            itemBuilder: (context, index) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                entries[index],
                style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.grey[300]),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
