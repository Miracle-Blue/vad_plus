#include "vad_plus.h"

// ============================================================================
// Platform-specific Implementation
// ============================================================================

#if defined(__APPLE__)
// iOS/macOS: Implementation is in Swift (VadPlusFFI.swift)
// These stubs are only compiled if Swift implementation is not available

#include <TargetConditionals.h>

#if !TARGET_OS_IOS && !TARGET_OS_MAC
// Stub implementations for non-Apple platforms or testing
#define IMPLEMENT_STUBS 1
#endif

#else
// Non-Apple platforms: Use stub implementations
#define IMPLEMENT_STUBS 1
#endif

#ifdef IMPLEMENT_STUBS

// ============================================================================
// Stub Implementations (for platforms without native support)
// ============================================================================

static const char *stub_error = "VAD not supported on this platform";

FFI_PLUGIN_EXPORT void vad_config_default(VADConfig *config_out)
{
  if (config_out == NULL)
    return;
  config_out->positive_speech_threshold = 0.5f;
  config_out->negative_speech_threshold = 0.35f;
  config_out->pre_speech_pad_frames = 3;
  config_out->redemption_frames = 24;
  config_out->min_speech_frames = 9;
  config_out->sample_rate = 16000;
  config_out->frame_samples = 512;
  config_out->end_speech_pad_frames = 3;
  config_out->is_debug = 0;
}

FFI_PLUGIN_EXPORT VADHandle *vad_create(void)
{
  // Return a dummy non-null pointer for error handling
  return (VADHandle *)1;
}

FFI_PLUGIN_EXPORT void vad_destroy(VADHandle *handle)
{
  (void)handle;
}

FFI_PLUGIN_EXPORT int32_t vad_init(VADHandle *handle, const VADConfig *config, const char *model_path)
{
  (void)handle;
  (void)config;
  (void)model_path;
  return -100; // Platform not supported
}

FFI_PLUGIN_EXPORT void vad_set_callback(VADHandle *handle, VADEventCallback callback, void *user_data)
{
  (void)handle;
  (void)callback;
  (void)user_data;
}

FFI_PLUGIN_EXPORT void vad_invalidate_callback(VADHandle *handle)
{
  (void)handle;
}

FFI_PLUGIN_EXPORT int32_t vad_start(VADHandle *handle)
{
  (void)handle;
  return -100; // Platform not supported
}

FFI_PLUGIN_EXPORT void vad_stop(VADHandle *handle)
{
  (void)handle;
}

FFI_PLUGIN_EXPORT int32_t vad_process_audio(VADHandle *handle, const float *samples, int32_t sample_count)
{
  (void)handle;
  (void)samples;
  (void)sample_count;
  return -100; // Platform not supported
}

FFI_PLUGIN_EXPORT void vad_reset(VADHandle *handle)
{
  (void)handle;
}

FFI_PLUGIN_EXPORT void vad_force_end_speech(VADHandle *handle)
{
  (void)handle;
}

FFI_PLUGIN_EXPORT int32_t vad_is_speaking(VADHandle *handle)
{
  (void)handle;
  return 0;
}

FFI_PLUGIN_EXPORT const char *vad_get_last_error(VADHandle *handle)
{
  (void)handle;
  return stub_error;
}

FFI_PLUGIN_EXPORT void vad_float_to_pcm16(const float *float_samples, int16_t *pcm16_samples, int32_t sample_count)
{
  for (int32_t i = 0; i < sample_count; i++)
  {
    float clamped = float_samples[i];
    if (clamped > 1.0f)
      clamped = 1.0f;
    if (clamped < -1.0f)
      clamped = -1.0f;
    pcm16_samples[i] = (int16_t)(clamped * 32767.0f);
  }
}

FFI_PLUGIN_EXPORT void vad_pcm16_to_float(const int16_t *pcm16_samples, float *float_samples, int32_t sample_count)
{
  for (int32_t i = 0; i < sample_count; i++)
  {
    float_samples[i] = (float)pcm16_samples[i] / 32768.0f;
  }
}

#endif // IMPLEMENT_STUBS
