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
    /// Enable debug logging
    bool is_debug;
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
// VAD Event Data Structures
// ============================================================================

/// Frame processed event data
typedef struct VADFrameData
{
    /// Speech probability (0.0 - 1.0)
    float probability;
    /// Whether current frame is speech
    bool is_speech;
    /// Pointer to frame audio data (float32)
    const float *frame_data;
    /// Number of samples in frame
    int32_t frame_length;
} VADFrameData;

/// Speech end event data
typedef struct VADSpeechEndData
{
    /// Pointer to PCM16 audio data
    const int16_t *audio_data;
    /// Number of samples
    int32_t audio_length;
    /// Duration in milliseconds
    int32_t duration_ms;
} VADSpeechEndData;

/// Error event data
typedef struct VADErrorData
{
    /// Error message
    const char *message;
    /// Error code
    int32_t code;
} VADErrorData;

/// Union for event data
typedef union VADEventData
{
    VADFrameData frame;
    VADSpeechEndData speech_end;
    VADErrorData error;
} VADEventData;

/// VAD Event structure
typedef struct VADEvent
{
    VADEventType type;
    VADEventData data;
} VADEvent;

// ============================================================================
// Callback Types
// ============================================================================

/// Callback function type for VAD events
typedef void (*VADEventCallback)(VADEvent event, void *user_data);

// ============================================================================
// Opaque Handle
// ============================================================================

/// Opaque handle to VAD instance
typedef struct VADHandle VADHandle;

// ============================================================================
// VAD API Functions
// ============================================================================

/// Create default VAD configuration for Silero VAD
/// @return Default VADConfig for v6 model
FFI_PLUGIN_EXPORT VADConfig vad_config_default(void);

/// Create a new VAD instance
/// @return Pointer to new VAD handle, or NULL on failure
FFI_PLUGIN_EXPORT VADHandle *vad_create(void);

/// Destroy a VAD instance and free resources
/// @param handle VAD handle to destroy
FFI_PLUGIN_EXPORT void vad_destroy(VADHandle *handle);

/// Initialize VAD with configuration and model
/// @param handle VAD handle
/// @param config VAD configuration
/// @param model_path Path to ONNX model file (can be NULL for bundled model)
/// @return 0 on success, negative error code on failure
FFI_PLUGIN_EXPORT int32_t vad_init(VADHandle *handle, VADConfig config, const char *model_path);

/// Set the event callback for VAD events
/// @param handle VAD handle
/// @param callback Event callback function
/// @param user_data User data passed to callback
FFI_PLUGIN_EXPORT void vad_set_callback(VADHandle *handle, VADEventCallback callback, void *user_data);

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
/// @return true if speech is being detected
FFI_PLUGIN_EXPORT bool vad_is_speaking(VADHandle *handle);

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
