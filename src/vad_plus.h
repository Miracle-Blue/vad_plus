#ifndef VAD_PLUS_H
#define VAD_PLUS_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>

#if _WIN32
#include <windows.h>
#define FFI_PLUGIN_EXPORT __declspec(dllexport)
#else
#include <pthread.h>
#include <unistd.h>
#define FFI_PLUGIN_EXPORT __attribute__((visibility("default")))
#endif

// ============================================================================
// VAD Configuration
// ============================================================================

/// Configuration structure for VAD parameters
typedef struct VADConfig
{
    /// Threshold for detecting speech start (default: 0.5)
    float positive_speech_threshold;
    /// Threshold for detecting speech end (default: 0.35)
    float negative_speech_threshold;
    /// Number of frames to prepend before speech start (default: 3 for v6)
    int32_t pre_speech_pad_frames;
    /// Number of silence frames before ending speech (default: 24 for v6)
    int32_t redemption_frames;
    /// Minimum speech frames for valid speech (default: 9 for v6)
    int32_t min_speech_frames;
    /// Audio sample rate in Hz (16000 or 8000)
    int32_t sample_rate;
    /// Number of samples per frame (512 for 16kHz v6, 256 for 8kHz v6)
    int32_t frame_samples;
    /// Number of padding frames after speech end (default: 3 for v6)
    int32_t end_speech_pad_frames;
    /// Enable debug logging (0 = false, 1 = true, using int32_t for FFI compatibility)
    int32_t is_debug;
} VADConfig;

// ============================================================================
// VAD Event Types
// ============================================================================

/// Event types emitted by VAD
typedef enum VADEventType
{
    VAD_EVENT_INITIALIZED = 0,
    VAD_EVENT_SPEECH_START = 1,
    VAD_EVENT_SPEECH_END = 2,
    VAD_EVENT_FRAME_PROCESSED = 3,
    VAD_EVENT_REAL_SPEECH_START = 4,
    VAD_EVENT_MISFIRE = 5,
    VAD_EVENT_ERROR = 6,
    VAD_EVENT_STOPPED = 7
} VADEventType;

// ============================================================================
// VAD Event Structure
// ============================================================================

/// VAD Event structure.
///
/// Flat layout — this must match the structs actually emitted by the native
/// implementations (`VADEventCStruct` in ios/macos VadPlusFFI.swift and
/// `VADEventC` in android vad_plus_jni.cpp) and the generated Dart bindings.
/// Only the fields relevant to the current `type` are populated; the rest
/// are zero/NULL.
typedef struct VADEvent
{
    /// One of the VADEventType values
    int32_t type;

    // VAD_EVENT_FRAME_PROCESSED
    /// Speech probability (0.0 - 1.0)
    float frame_probability;
    /// Whether current frame is speech (0 = false, 1 = true)
    int32_t frame_is_speech;
    /// Pointer to frame audio data (float32)
    const float *frame_data;
    /// Number of samples in frame
    int32_t frame_length;

    // VAD_EVENT_SPEECH_END
    /// Pointer to PCM16 audio data
    const int16_t *speech_end_audio_data;
    /// Number of samples
    int32_t speech_end_audio_length;
    /// Duration in milliseconds
    int32_t speech_end_duration_ms;

    // VAD_EVENT_ERROR
    /// Error message
    const char *error_message;
    /// Error code
    int32_t error_code;
} VADEvent;

// ============================================================================
// Callback Types
// ============================================================================

/// Callback function type for VAD events
/// Note: Event is passed by pointer for C/Swift FFI compatibility
typedef void (*VADEventCallback)(const VADEvent *event, void *user_data);

// ============================================================================
// Opaque Handle
// ============================================================================

/// Opaque handle to VAD instance
typedef struct VADHandle VADHandle;

// ============================================================================
// VAD API Functions
// ============================================================================

/// Create default VAD configuration for Silero VAD
/// @param config_out Pointer to VADConfig struct to fill with default values
FFI_PLUGIN_EXPORT void vad_config_default(VADConfig *config_out);

/// Create a new VAD instance
/// @return Pointer to new VAD handle, or NULL on failure
FFI_PLUGIN_EXPORT VADHandle *vad_create(void);

/// Destroy a VAD instance and free resources
/// @param handle VAD handle to destroy
FFI_PLUGIN_EXPORT void vad_destroy(VADHandle *handle);

/// Initialize VAD with configuration and model
/// @param handle VAD handle
/// @param config Pointer to VAD configuration
/// @param model_path Path to ONNX model file (can be NULL for bundled model)
/// @return 0 on success, negative error code on failure
FFI_PLUGIN_EXPORT int32_t vad_init(VADHandle *handle, const VADConfig *config, const char *model_path);

/// Set the event callback for VAD events
/// @param handle VAD handle
/// @param callback Event callback function
/// @param user_data User data passed to callback
FFI_PLUGIN_EXPORT void vad_set_callback(VADHandle *handle, VADEventCallback callback, void *user_data);

/// Invalidate the callback to prevent it from being invoked
/// This MUST be called before closing the Dart NativeCallable to prevent crashes.
/// Uses synchronous dispatch to ensure all pending callbacks complete first.
/// @param handle VAD handle
FFI_PLUGIN_EXPORT void vad_invalidate_callback(VADHandle *handle);

/// Start audio capture and VAD processing
/// @param handle VAD handle
/// @return 0 on success, negative error code on failure
FFI_PLUGIN_EXPORT int32_t vad_start(VADHandle *handle);

/// Stop audio capture and VAD processing
/// @param handle VAD handle
FFI_PLUGIN_EXPORT void vad_stop(VADHandle *handle);

/// Process audio samples directly (without microphone capture)
/// Use this when you have your own audio source
/// @param handle VAD handle
/// @param samples Pointer to float32 audio samples (normalized -1.0 to 1.0)
/// @param sample_count Number of samples
/// @return 0 on success, negative error code on failure
FFI_PLUGIN_EXPORT int32_t vad_process_audio(VADHandle *handle, const float *samples, int32_t sample_count);

/// Reset VAD state (clear buffers and speech detection state)
/// @param handle VAD handle
FFI_PLUGIN_EXPORT void vad_reset(VADHandle *handle);

/// Force end current speech segment if any
/// @param handle VAD handle
FFI_PLUGIN_EXPORT void vad_force_end_speech(VADHandle *handle);

/// Check if VAD is currently detecting speech
/// @param handle VAD handle
/// @return 1 if speech is being detected, 0 otherwise
FFI_PLUGIN_EXPORT int32_t vad_is_speaking(VADHandle *handle);

/// Get the last error message
/// @param handle VAD handle
/// @return Error message string (do not free)
FFI_PLUGIN_EXPORT const char *vad_get_last_error(VADHandle *handle);

// ============================================================================
// Utility Functions
// ============================================================================

/// Convert float32 audio samples to PCM16
/// @param float_samples Input float32 samples (-1.0 to 1.0)
/// @param pcm16_samples Output PCM16 buffer (must be allocated)
/// @param sample_count Number of samples
FFI_PLUGIN_EXPORT void vad_float_to_pcm16(const float *float_samples, int16_t *pcm16_samples, int32_t sample_count);

/// Convert PCM16 audio samples to float32
/// @param pcm16_samples Input PCM16 samples
/// @param float_samples Output float32 buffer (must be allocated)
/// @param sample_count Number of samples
FFI_PLUGIN_EXPORT void vad_pcm16_to_float(const int16_t *pcm16_samples, float *float_samples, int32_t sample_count);

#endif /* VAD_PLUS_H */
