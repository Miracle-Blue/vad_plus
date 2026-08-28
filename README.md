# vad_plus

[![pub package](https://img.shields.io/pub/v/vad_plus.svg)](https://pub.dev/packages/vad_plus)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[Silero VAD v6](https://github.com/snakers4/silero-vad) voice activity detection for Flutter via `dart:ffi` — real-time microphone detection or push-your-own-audio, with speech segments delivered as ready-to-use PCM16.

The ONNX model (~2.3 MB) is bundled with the plugin, inference runs on native threads via ONNX Runtime, and events arrive on the main isolate as a typed stream.

## Features

- **Silero VAD v6 bundled** — no model download, no asset setup.
- **Two modes**: built-in native mic capture (`start()`) or push your own audio (`processAudio()`).
- **Ready-to-use segments** — speech delivered as `Int16List` PCM16 mono + duration.
- **Eager + debounced detection** — instant `VadSpeechStart`, confirmed `VadRealSpeechStart`, retraction via `VadMisfire`, per-frame probabilities (~31/s).
- **Pre-speech padding** (~64 ms of lead-in at defaults) so segments don't clip the first syllable.
- **Off the UI thread** — native inference; events via `NativeCallable.listener` on the main isolate.
- **Android zero-setup** — auto-initialized via ContentProvider; 16 KB page-size ready.
- **Plays nice with audio playback** — iOS session uses `.playAndRecord` + `mixWithOthers`, so you can duck music while listening.

## Platform support

| Platform | Minimum | Inference runtime | Notes |
|---|---|---|---|
| Android | minSdk 24 | ONNX Runtime Android 1.24.1 | ABIs: armeabi-v7a, arm64-v8a, x86, x86_64; 16 KB page-size ready |
| iOS | 15.0 | onnxruntime-objc 1.18.x | model ships in the `vad_plus_assets` resource bundle |
| macOS | 13.4 | onnxruntime-objc 1.18.x | model ships in the `vad_plus_assets` resource bundle |

Web, Windows, and Linux are not supported. Inference is CPU-only on every platform (no CoreML / NNAPI / GPU).

## Installation

```sh
flutter pub add vad_plus
```

No further native setup is needed — the model and native libraries ship with the plugin. The only per-platform work is microphone permissions (next section), and only if you use the built-in mic mode.

## Permissions

### Android

`RECORD_AUDIO` and `MODIFY_AUDIO_SETTINGS` are already merged in from the plugin's manifest — no manifest edits needed. Your app must still request the runtime permission, e.g. with [`permission_handler`](https://pub.dev/packages/permission_handler):

```dart
final status = await Permission.microphone.request();
if (!status.isGranted) return;
```

### iOS

Add to `ios/Runner/Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Microphone access is required for voice activity detection.</string>
```

### macOS

Add the same `NSMicrophoneUsageDescription` key to `macos/Runner/Info.plist`, **and** the audio-input entitlement to **both** `DebugProfile.entitlements` and `Release.entitlements`:

```xml
<key>com.apple.security.device.audio-input</key>
<true/>
```

> **Note:** `permission_handler` does not handle the macOS microphone — skip the runtime request there. With the entitlement in place, macOS shows its own system prompt on first mic access.

If you only use `processAudio()` (bring your own audio), no permissions are needed at all.

## Quick start

```dart
import 'package:vad_plus/vad_plus.dart';

final vad = VadPlus();

// 1. Subscribe BEFORE initialize() — events is a broadcast stream with no
//    replay, so a late listener misses VadInitialized.
final sub = vad.events.listen((event) {
  switch (event) {
    case VadInitialized():
      print('VAD ready');
    case VadSpeechStart():
      print('Speech started (eager — may be retracted by VadMisfire)');
    case VadRealSpeechStart():
      print('Speech confirmed');
    case VadSpeechEnd(:final audioData, :final durationMs):
      print('Segment: ${durationMs}ms, ${audioData.length} PCM16 samples');
    case VadMisfire():
      print('Too short — retract the eager start');
    case VadFrameProcessed(:final probability):
      updateMeter(probability); // ~31×/s — throttle heavy UI work
    case VadError(:final message, :final code):
      print('Error $code: $message');
    case VadStopped():
      print('Stopped');
  }
});

// 2. Initialize (loads the bundled model) and start the native mic.
await vad.initialize(config: const VadConfig());
await vad.start();

// ...later:
vad.stop();      // synchronous; VAD can be started again
sub.cancel();
vad.dispose();   // instance is dead after this — create a new VadPlus to reuse
```

**Subscribe to `events` before calling `initialize()`**, and note that **only one `VadPlus` instance can be active at a time**: `initialize()` on a new instance automatically disposes the previous one (this is what makes hot reload safe).

## Events

All detection results arrive on `events`. Inference runs on native threads; delivery happens on the main isolate.

| Event | Payload | Fires when |
|---|---|---|
| `VadInitialized` | — | `initialize()` completed |
| `VadSpeechStart` | — | eagerly, on the first frame ≥ `positiveSpeechThreshold` (may be retracted) |
| `VadRealSpeechStart` | — | speech confirmed after `minSpeechFrames` (~288 ms) — the debounced signal |
| `VadSpeechEnd` | `Int16List audioData` (PCM16 mono), `int durationMs` | segment ends after the redemption window; includes pre-pad + trailing silence |
| `VadMisfire` | — | fewer than `minSpeechFrames` speech frames accumulated — retracts the eager start |
| `VadFrameProcessed` | `double probability`, `bool isSpeech`, `Float32List audioData` | every frame, ~31×/s at defaults |
| `VadError` | `String message`, `int code` | a native error occurred |
| `VadStopped` | — | after `stop()` |

Practical notes:

- Use `VadSpeechStart` for instant UI reactions (ducking music, showing an indicator) and treat `VadRealSpeechStart` / `VadMisfire` as the confirm/retract pair for anything with side effects.
- `VadFrameProcessed` fires roughly 31 times per second at default settings — throttle UI updates driven by it rather than rebuilding on every frame.
- `VadSpeechEnd.audioData` is 16 kHz (or 8 kHz) mono s16le, ready for playback or upload as-is. At defaults it carries at least ~768 ms of trailing silence (see [How it works](#how-it-works)). The [example app](example/) shows a full playback implementation.

## Configuration

`VadConfig` is a const class. `VadConfig.kHz16()` is identical to the default constructor; `VadConfig.kHz8()` sets `sampleRate: 8000, frameSamples: 256`. **One frame is 32 ms at both sample rates**, so any frame count × 32 = milliseconds.

| Field | Default | ≈ time | Meaning |
|---|---|---|---|
| `positiveSpeechThreshold` | `0.5` | — | probability ≥ this starts / continues speech |
| `negativeSpeechThreshold` | `0.35` | — | probability < this counts as silence (the band between the two is hysteresis: neither) |
| `preSpeechPadFrames` | `3` | ~64 ms lead-in | ring of frames prepended at speech start — the ring includes the trigger frame, so (N−1) × 32 ms precedes it |
| `redemptionFrames` | `24` | ~768 ms | silence frames before a segment ends |
| `minSpeechFrames` | `9` | ~288 ms | shorter segments become `VadMisfire` |
| `sampleRate` | `16000` | — | 16000 or 8000 |
| `frameSamples` | `512` | 32 ms | 512 @ 16 kHz, 256 @ 8 kHz |
| `endSpeechPadFrames` | `3` | ~96 ms | **currently has no effect** — the full buffer is always kept |
| `isDebug` | `false` | — | native debug logging |

The knob most apps turn is `redemptionFrames` — for example `VadConfig(redemptionFrames: 12)` ends segments after ~384 ms of silence instead of ~768 ms.

## How it works

Every 32 ms frame runs through the Silero model, producing a speech probability that is always emitted as `VadFrameProcessed`. When idle, a frame with probability ≥ `positiveSpeechThreshold` opens a segment: the pre-speech ring buffer (~64 ms of true lead-in at defaults) is prepended and `VadSpeechStart` fires immediately. While speaking, frames ≥ the positive threshold count toward `minSpeechFrames` (crossing it fires `VadRealSpeechStart` once); frames below `negativeSpeechThreshold` count toward `redemptionFrames`; frames in between are hysteresis — they extend the segment but count as neither. When the silence counter reaches `redemptionFrames`, the segment closes: `VadSpeechEnd` if enough speech frames accumulated, `VadMisfire` otherwise. The emitted segment contains pre-pad + speech + the trailing redemption window (~768 ms or more at defaults — frames in the hysteresis band extend it without resetting the silence counter).

```
prob ──────╥─ ≥ 0.5 ─────────────╥─ < 0.35 for 24 frames ─╥
           ║                     ║                        ║
 [pre-pad] ║ SPEECH_START        ║ (redemption counting)  ║ SPEECH_END
   ~64ms   ║ ...9 frames...      ║        ~768ms          ║ or MISFIRE
           ║ REAL_SPEECH_START   ║                        ║ if < 9 frames
           ╨─────────────────────╨────────────────────────╨
segment = [ pre-pad ][ speech ][ trailing redemption silence ]
```

Under the hood, each inference takes the frame plus a context window of the previous input's last samples (64 @ 16 kHz, 32 @ 8 kHz), and the model's RNN state (`[2, 1, 128]`) is carried across frames. `reset()` zeroes both.

## Bring your own audio

`processAudio()` feeds your own audio through the same detector — an existing capture pipeline, decoded files, a network stream. It is independent of `start()` and needs no permissions.

Requirements:

- `Float32List`, samples normalized to −1.0…1.0
- mono, at `config.sampleRate`
- any chunk size — internal buffering drains in `frameSamples` chunks

```dart
final vad = VadPlus();
vad.events.listen(handleEvent);
await vad.initialize(); // don't call start()

for (final Float32List chunk in myAudioSource) {
  vad.processAudio(chunk);
}
```

For PCM16 sources, convert first with the top-level `pcm16ToFloat()` helper.

Two methods matter most in this mode (they work in mic mode too):

- `reset()` — clears buffers and model state; call between unrelated streams.
- `forceEndSpeech()` — ends the current segment immediately instead of waiting ~768 ms of redemption (e.g. on a push-to-talk release). Emits `VadSpeechEnd` only if the segment reached `minSpeechFrames`; shorter segments are silently dropped (no `VadMisfire`).

## API overview

| Member | Description |
|---|---|
| `Stream<VadEvent> events` | broadcast stream of all events — subscribe before `initialize()` |
| `initialize({VadConfig config, String? modelPath})` | loads the model; `modelPath: null` (default) uses the bundled `silero_vad_v6.onnx`. A custom path bypasses it — but on Android only if the file exists, otherwise it silently falls back to the bundled model |
| `start()` | starts built-in native mic capture (async) |
| `stop()` | stops capture (sync); the instance can be started again |
| `processAudio(Float32List samples)` | push-mode detection with your own audio |
| `reset()` | clears audio buffers, model state, and speech state |
| `forceEndSpeech()` | ends the current segment now (see above) |
| `dispose()` | releases everything; the instance cannot be reused |
| `isInitialized` / `isRunning` / `isSpeaking` | state getters (`isSpeaking` queries native directly) |

**Utilities:** top-level `floatToPcm16(Float32List)` and `pcm16ToFloat(Int16List)` converters. Each call crosses FFI — convenient for occasional conversions, not for hot per-frame loops.

## Architecture

| | Apple (iOS / macOS) | Android |
|---|---|---|
| Implementation | Swift, exported as C symbols via `@_cdecl`, statically linked (`DynamicLibrary.process()`) | Kotlin behind a JNI bridge (`libvad_plus.so`) |
| Inference | ONNX Runtime (onnxruntime-objc 1.18.x), CPU | ONNX Runtime Android 1.24.1 (Maven), CPU |
| Mic capture | `AVAudioEngine` input tap; auto resample/downmix to mono at `sampleRate` | `AudioRecord` on a dedicated thread, raw `MIC` source |
| Model location | `vad_plus_assets` resource bundle | APK assets, copied to `cacheDir` on first init |
| Setup | podspec preserves symbols (dead-code stripping disabled) | ContentProvider auto-captures the app context and loads the `.so`; JNI classes cached in `JNI_OnLoad` |

Events cross the boundary through a C callback into a `NativeCallable.listener`, which queues delivery onto the main Dart isolate — the UI thread never runs inference. On iOS the audio session is configured as `.playAndRecord` with `mixWithOthers`, `defaultToSpeaker`, and Bluetooth options at `initialize()` time, which is why the example app can keep music playing (and duck it) while the VAD listens.

## Notes & limitations

- **Single active instance.** The native callback targets one static instance; `initialize()` on a new `VadPlus` disposes the previous one. This is deliberate — it makes hot reload safe.
- **Subscribe before `initialize()`.** `events` is a broadcast stream with no replay.
- **`endSpeechPadFrames` currently has no effect** — the implementation always keeps the full buffer.
- **The trigger frame appears twice at the segment head** — the pre-speech ring already contains it and it is appended again, so each segment starts with a ~32 ms stutter (also counted in `durationMs`), and the true lead-in is (`preSpeechPadFrames` − 1) × 32 ms ≈ 64 ms at defaults.
- **Segments include at least ~768 ms of trailing silence** at defaults (hysteresis-band frames can extend it). Lower `redemptionFrames` or trim the tail yourself.
- **CPU-only inference** — no CoreML, NNAPI, or GPU execution providers.
- **Don't block the main isolate for long (> ~0.5 s) while listening.** On Apple platforms, native event payloads are freed on a short timer after delivery; a blocked event loop can read freed memory.
- **`VadFrameProcessed` fires ~31×/s** — throttle UI updates instead of rebuilding per frame.
- **Raw mic input** — no echo cancellation, noise suppression, or AGC is applied on any platform.
- **For contributors: do not re-run `dart run ffigen`.** The header (`src/vad_plus.h`) declares `VADEvent` as a tagged union, but the actual ABI emitted by the Swift and JNI implementations is a flat struct. The checked-in `lib/vad_plus_bindings_generated.dart` was hand-adjusted to match the real layout; regenerating it produces the union layout and breaks event decoding.

## Example app

The [example app](example/) is a complete demo: it handles all 8 events, ducks background music (via `flutter_soloud`) on `VadSpeechStart` and restores it on end/misfire, stores every `VadSpeechEnd` segment and replays it through a SoLoud buffer stream (16 kHz mono s16le), and drives a live speech-probability bar.

## License & credits

MIT — see [LICENSE](LICENSE).

Built on [Silero VAD](https://github.com/snakers4/silero-vad) and [ONNX Runtime](https://onnxruntime.ai/).
