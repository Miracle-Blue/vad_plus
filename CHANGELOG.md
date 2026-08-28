## 0.3.1

- Re-publish of 0.3.0 (no functional changes).

## 0.3.0

- Fix pre-speech padding: segments now start with the full `preSpeechPadFrames` (~96 ms) of lead-in and no longer duplicate the triggering frame.
- Implement `endSpeechPadFrames`: emitted segments keep a short silence tail after the last voiced frame instead of the whole ~768 ms redemption window (previously the parameter had no effect).
- Fix per-event native memory leak on Android — event payloads are now freed on a short grace timer after delivery, mirroring the iOS/macOS cleanup.
- Fail with an error when a provided `modelPath` does not exist on Android (previously fell back to the bundled model silently).
- Re-extract the bundled model on every Android init so a plugin update is never shadowed by a stale cached copy.
- Release the native handle when `initialize()` fails, so a failed instance no longer leaks and can be retried.
- Align `VADEvent` in `src/vad_plus.h` with the actual native ABI (flat struct) and regenerate the FFI bindings — `dart run ffigen` is now safe to re-run.

## 0.2.1

- Complete README: quick start, events, configuration, VAD algorithm, `processAudio` mode, per-platform permissions, architecture, and known limitations.
- Restructure the example app into feature-based modules.

## 0.2.0

- Require Dart SDK ^3.9.0

## 0.1.2

- Update `ffi` dependency to ^2.2.0

## 0.1.1

- Code quality optimization

## 0.1.0

- Add support for 16KB memory page size on Android.

## 0.0.1

- Initial release.
