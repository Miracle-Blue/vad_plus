// Golden check of the native pipeline. Run it on each platform, from example/:
//
//   flutter test integration_test/vad_golden_test.dart -d <device>
//
// assets/test/speech_16k.pcm is the first 12 s of tests/data/test.wav from
// https://github.com/snakers4/silero-vad (MIT), as raw 16 kHz mono PCM16.
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vad_plus/vad_plus.dart';

const _chunkSamples = 320;

// Recorded from the unmodified 0.3.1 Android implementation.
const _goldenEvents = <String>[
  'VadInitialized',
  'VadSpeechStart',
  'VadRealSpeechStart',
  'end 111104 6944ms 1cf32b39',
  'VadSpeechStart',
  'VadRealSpeechStart',
  'end 44032 2752ms 32e94f02',
];
const _goldenFrames = 375;
const _goldenProbabilitySum = 261.0054;

/// FNV-1a over the samples, so a segment compares as one short value.
String _checksum(Int16List pcm) {
  var hash = 0x811c9dc5;
  for (final sample in pcm) {
    hash = ((hash ^ (sample & 0xffff)) * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('speech clip matches the golden run', (_) async {
    final bytes = await rootBundle.load('assets/test/speech_16k.pcm');
    final pcm = bytes.buffer.asInt16List(
      bytes.offsetInBytes,
      bytes.lengthInBytes ~/ 2,
    );
    final samples = Float32List(pcm.length);
    for (var i = 0; i < pcm.length; i++) {
      samples[i] = pcm[i] / 32768;
    }

    final events = <String>[];
    var frames = 0;
    var probabilitySum = 0.0;

    final vad = VadPlus();
    final subscription = vad.events.listen((event) {
      switch (event) {
        case VadFrameProcessed(:final probability):
          frames++;
          probabilitySum += probability;
        case VadSpeechEnd(:final audioData, :final durationMs):
          events.add(
            'end ${audioData.length} ${durationMs}ms ${_checksum(audioData)}',
          );
        case VadError(:final message, :final code):
          events.add('error $code $message');
        case VadInitialized() ||
            VadSpeechStart() ||
            VadRealSpeechStart() ||
            VadMisfire() ||
            VadStopped():
          events.add('${event.runtimeType}');
      }
    });

    await vad.initialize();
    for (var i = 0; i < samples.length; i += _chunkSamples) {
      final end = min(i + _chunkSamples, samples.length);
      vad.processAudio(Float32List.sublistView(samples, i, end));
      // Yield so events are drained before native frees their payloads.
      await Future<void>.delayed(Duration.zero);
    }
    vad.forceEndSpeech();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await subscription.cancel();
    vad.dispose();

    debugPrint('golden events: $events');
    debugPrint('golden frames: $frames, probability sum: $probabilitySum');

    expect(events, _goldenEvents);
    expect(frames, _goldenFrames);
    // Tolerance covers float rounding across ONNX Runtime builds.
    expect(probabilitySum, closeTo(_goldenProbabilitySum, 1e-3));
  });
}
