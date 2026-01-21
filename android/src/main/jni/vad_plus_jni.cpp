#include <jni.h>
#include <string>
#include <cstring>
#include <cstdlib>
#include <pthread.h>
#include <android/log.h>

#define TAG "VadPlusJNI"
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

// ============================================================================
// VAD Event Structure (matching iOS/Dart expectations)
// ============================================================================

struct VADEventC
{
    int32_t type;

    // Frame data
    float frame_probability;
    int32_t frame_is_speech;
    const float *frame_data;
    int32_t frame_length;

    // Speech end data
    const int16_t *speech_end_audio_data;
    int32_t speech_end_audio_length;
    int32_t speech_end_duration_ms;

    // Error data
    const char *error_message;
    int32_t error_code;
};

struct VADConfig
{
    float positive_speech_threshold;
    float negative_speech_threshold;
    int32_t pre_speech_pad_frames;
    int32_t redemption_frames;
    int32_t min_speech_frames;
    int32_t sample_rate;
    int32_t frame_samples;
    int32_t end_speech_pad_frames;
    int32_t is_debug;
};

// Callback type
typedef void (*VADEventCallback)(const void *event, void *user_data);

// ============================================================================
// Global State
// ============================================================================

static JavaVM *g_jvm = nullptr;
static jclass g_handleManagerClass = nullptr;
static jclass g_handleInternalClass = nullptr;
static jclass g_configInternalClass = nullptr;

// ============================================================================
// JNI OnLoad
// ============================================================================

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved)
{
    g_jvm = vm;

    JNIEnv *env;
    if (vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK)
    {
        LOGE("Failed to get JNIEnv in JNI_OnLoad");
        return JNI_ERR;
    }

    // Cache class references - CRITICAL: This must succeed for FFI to work
    // When called from Dart FFI, FindClass uses the boot class loader which
    // cannot find application classes. We MUST cache them here.

    jclass localHandleManager = env->FindClass("dev/miracle/vad_plus/VadPlusHandleManager");
    if (localHandleManager != nullptr)
    {
        g_handleManagerClass = reinterpret_cast<jclass>(env->NewGlobalRef(localHandleManager));
        env->DeleteLocalRef(localHandleManager);
        LOGD("Cached VadPlusHandleManager class");
    }
    else
    {
        LOGE("Failed to find VadPlusHandleManager class in JNI_OnLoad");
        // Clear the exception so we don't leave it pending
        if (env->ExceptionCheck())
        {
            env->ExceptionDescribe();
            env->ExceptionClear();
        }
    }

    jclass localHandleInternal = env->FindClass("dev/miracle/vad_plus/VADHandleInternal");
    if (localHandleInternal != nullptr)
    {
        g_handleInternalClass = reinterpret_cast<jclass>(env->NewGlobalRef(localHandleInternal));
        env->DeleteLocalRef(localHandleInternal);
        LOGD("Cached VADHandleInternal class");
    }
    else
    {
        LOGE("Failed to find VADHandleInternal class in JNI_OnLoad");
        if (env->ExceptionCheck())
        {
            env->ExceptionDescribe();
            env->ExceptionClear();
        }
    }

    jclass localConfigInternal = env->FindClass("dev/miracle/vad_plus/VADConfigInternal");
    if (localConfigInternal != nullptr)
    {
        g_configInternalClass = reinterpret_cast<jclass>(env->NewGlobalRef(localConfigInternal));
        env->DeleteLocalRef(localConfigInternal);
        LOGD("Cached VADConfigInternal class");
    }
    else
    {
        LOGE("Failed to find VADConfigInternal class in JNI_OnLoad");
        if (env->ExceptionCheck())
        {
            env->ExceptionDescribe();
            env->ExceptionClear();
        }
    }

    LOGD("JNI_OnLoad completed (HandleManager: %s, HandleInternal: %s, ConfigInternal: %s)",
         g_handleManagerClass != nullptr ? "OK" : "FAILED",
         g_handleInternalClass != nullptr ? "OK" : "FAILED",
         g_configInternalClass != nullptr ? "OK" : "FAILED");

    return JNI_VERSION_1_6;
}

extern "C" JNIEXPORT void JNICALL JNI_OnUnload(JavaVM *vm, void *reserved)
{
    JNIEnv *env;
    if (vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) == JNI_OK)
    {
        if (g_handleManagerClass != nullptr)
        {
            env->DeleteGlobalRef(g_handleManagerClass);
            g_handleManagerClass = nullptr;
        }
        if (g_handleInternalClass != nullptr)
        {
            env->DeleteGlobalRef(g_handleInternalClass);
            g_handleInternalClass = nullptr;
        }
        if (g_configInternalClass != nullptr)
        {
            env->DeleteGlobalRef(g_configInternalClass);
            g_configInternalClass = nullptr;
        }
    }
    g_jvm = nullptr;
}

// ============================================================================
// Helper Functions
// ============================================================================

// Helper to clear any pending JNI exception
static void clearException(JNIEnv *env)
{
    if (env->ExceptionCheck())
    {
        env->ExceptionClear();
    }
}

static JNIEnv *getEnv()
{
    JNIEnv *env = nullptr;
    if (g_jvm != nullptr)
    {
        int status = g_jvm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6);
        if (status == JNI_EDETACHED)
        {
            if (g_jvm->AttachCurrentThread(&env, nullptr) != JNI_OK)
            {
                return nullptr;
            }
        }
    }
    return env;
}

static jobject getHandle(JNIEnv *env, jlong handleId)
{
    // Always clear any pending exception first
    clearException(env);

    // If class wasn't cached in JNI_OnLoad, we cannot use FindClass here
    // because Dart FFI calls come from the boot class loader which cannot
    // find application classes. The class MUST be cached during JNI_OnLoad.
    if (g_handleManagerClass == nullptr)
    {
        LOGE("VadPlusHandleManager class not cached - JNI_OnLoad may have failed");
        return nullptr;
    }

    jmethodID getHandleMethod = env->GetStaticMethodID(
        g_handleManagerClass,
        "getHandle",
        "(J)Ldev/miracle/vad_plus/VADHandleInternal;");

    if (env->ExceptionCheck())
    {
        LOGE("Exception while getting getHandle method");
        clearException(env);
        return nullptr;
    }

    if (getHandleMethod == nullptr)
        return nullptr;

    jobject result = env->CallStaticObjectMethod(g_handleManagerClass, getHandleMethod, handleId);

    if (env->ExceptionCheck())
    {
        LOGE("Exception while calling getHandle");
        clearException(env);
        return nullptr;
    }

    return result;
}

// ============================================================================
// Native Event Sending (Called from Kotlin)
// ============================================================================

extern "C" JNIEXPORT void JNICALL
Java_dev_miracle_vad_1plus_VADHandleInternal_nativeSendEvent(
    JNIEnv *env,
    jclass clazz,
    jlong callbackPtr,
    jlong userDataPtr,
    jint type)
{
    if (callbackPtr == 0)
        return;

    VADEventCallback callback = reinterpret_cast<VADEventCallback>(callbackPtr);
    void *userData = reinterpret_cast<void *>(userDataPtr);

    // Allocate event on heap
    VADEventC *event = new VADEventC();
    memset(event, 0, sizeof(VADEventC));
    event->type = type;

    callback(event, userData);

    // Schedule cleanup (in a real implementation, Dart should handle this)
    // For now, we'll let Dart manage the memory through the callback contract
}

extern "C" JNIEXPORT void JNICALL
Java_dev_miracle_vad_1plus_VADHandleInternal_nativeSendFrameEvent(
    JNIEnv *env,
    jclass clazz,
    jlong callbackPtr,
    jlong userDataPtr,
    jfloat probability,
    jboolean isSpeech,
    jint frameLength)
{
    if (callbackPtr == 0)
        return;

    VADEventCallback callback = reinterpret_cast<VADEventCallback>(callbackPtr);
    void *userData = reinterpret_cast<void *>(userDataPtr);

    VADEventC *event = new VADEventC();
    memset(event, 0, sizeof(VADEventC));
    event->type = 3; // FRAME_PROCESSED
    event->frame_probability = probability;
    event->frame_is_speech = isSpeech ? 1 : 0;
    event->frame_length = frameLength;

    callback(event, userData);
}

extern "C" JNIEXPORT void JNICALL
Java_dev_miracle_vad_1plus_VADHandleInternal_nativeSendSpeechEndEvent(
    JNIEnv *env,
    jclass clazz,
    jlong callbackPtr,
    jlong userDataPtr,
    jshortArray audioData,
    jint audioLength,
    jint durationMs)
{
    if (callbackPtr == 0)
        return;

    VADEventCallback callback = reinterpret_cast<VADEventCallback>(callbackPtr);
    void *userData = reinterpret_cast<void *>(userDataPtr);

    // Copy audio data
    jshort *audioElements = env->GetShortArrayElements(audioData, nullptr);
    int16_t *audioCopy = new int16_t[audioLength];
    memcpy(audioCopy, audioElements, audioLength * sizeof(int16_t));
    env->ReleaseShortArrayElements(audioData, audioElements, JNI_ABORT);

    VADEventC *event = new VADEventC();
    memset(event, 0, sizeof(VADEventC));
    event->type = 2; // SPEECH_END
    event->speech_end_audio_data = audioCopy;
    event->speech_end_audio_length = audioLength;
    event->speech_end_duration_ms = durationMs;

    callback(event, userData);

    // Note: audioCopy should be freed by Dart after processing
    // For safety, schedule deletion after a delay
    // In production, this should be managed more carefully
}

extern "C" JNIEXPORT void JNICALL
Java_dev_miracle_vad_1plus_VADHandleInternal_nativeSendErrorEvent(
    JNIEnv *env,
    jclass clazz,
    jlong callbackPtr,
    jlong userDataPtr,
    jstring message,
    jint code)
{
    if (callbackPtr == 0)
        return;

    VADEventCallback callback = reinterpret_cast<VADEventCallback>(callbackPtr);
    void *userData = reinterpret_cast<void *>(userDataPtr);

    // Copy message
    const char *msgChars = env->GetStringUTFChars(message, nullptr);
    char *msgCopy = strdup(msgChars);
    env->ReleaseStringUTFChars(message, msgChars);

    VADEventC *event = new VADEventC();
    memset(event, 0, sizeof(VADEventC));
    event->type = 6; // ERROR
    event->error_message = msgCopy;
    event->error_code = code;

    callback(event, userData);
}

// ============================================================================
// FFI Exports (Called from Dart via FFI)
// ============================================================================

extern "C"
{

    __attribute__((visibility("default"))) void vad_config_default(VADConfig *config_out)
    {
        if (config_out == nullptr)
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

    __attribute__((visibility("default"))) void *vad_create()
    {
        JNIEnv *env = getEnv();
        if (env == nullptr)
        {
            LOGE("Failed to get JNIEnv");
            return nullptr;
        }

        // Clear any pending exception
        clearException(env);

        // Class must be cached during JNI_OnLoad - we cannot use FindClass here
        // because Dart FFI calls use the boot class loader
        if (g_handleManagerClass == nullptr)
        {
            LOGE("VadPlusHandleManager class not cached - native library may not have been loaded via System.loadLibrary");
            return nullptr;
        }

        jmethodID createMethod = env->GetStaticMethodID(g_handleManagerClass, "createHandle", "()J");
        if (env->ExceptionCheck())
        {
            LOGE("Exception while getting createHandle method");
            clearException(env);
            return nullptr;
        }
        if (createMethod == nullptr)
        {
            LOGE("Failed to find createHandle method");
            return nullptr;
        }

        jlong handleId = env->CallStaticLongMethod(g_handleManagerClass, createMethod);
        if (env->ExceptionCheck())
        {
            LOGE("Exception while calling createHandle");
            clearException(env);
            return nullptr;
        }

        LOGD("Created handle with ID: %lld", (long long)handleId);

        return reinterpret_cast<void *>(handleId);
    }

    __attribute__((visibility("default"))) void vad_destroy(void *handle)
    {
        if (handle == nullptr)
            return;

        JNIEnv *env = getEnv();
        if (env == nullptr)
            return;

        clearException(env);

        if (g_handleManagerClass == nullptr)
            return;

        jmethodID removeMethod = env->GetStaticMethodID(g_handleManagerClass, "removeHandle", "(J)V");
        if (removeMethod == nullptr || env->ExceptionCheck())
        {
            clearException(env);
            return;
        }

        jlong handleId = reinterpret_cast<jlong>(handle);
        env->CallStaticVoidMethod(g_handleManagerClass, removeMethod, handleId);
        if (env->ExceptionCheck())
        {
            clearException(env);
            return;
        }
        LOGD("Destroyed handle with ID: %lld", (long long)handleId);
    }

    __attribute__((visibility("default")))
    int32_t
    vad_init(void *handle, const VADConfig *config, const char *model_path)
    {
        if (handle == nullptr || config == nullptr)
            return -1;

        JNIEnv *env = getEnv();
        if (env == nullptr)
            return -1;

        // Clear any pending exception
        clearException(env);

        jlong handleId = reinterpret_cast<jlong>(handle);
        jobject handleObj = getHandle(env, handleId);
        if (handleObj == nullptr)
        {
            LOGE("Failed to get handle object for ID: %lld", (long long)handleId);
            return -1;
        }

        // Get VADHandleInternal class
        jclass handleClass = env->GetObjectClass(handleObj);
        if (handleClass == nullptr || env->ExceptionCheck())
        {
            clearException(env);
            env->DeleteLocalRef(handleObj);
            return -1;
        }

        // Use cached config class - FindClass won't work from Dart FFI context
        if (g_configInternalClass == nullptr)
        {
            env->DeleteLocalRef(handleObj);
            env->DeleteLocalRef(handleClass);
            LOGE("VADConfigInternal class not cached - JNI_OnLoad may have failed");
            return -1;
        }
        jclass configClass = g_configInternalClass;

        // Signature: (FFIIIIIIZ)V = 2 floats + 6 ints + 1 boolean
        // Matches VADConfigInternal(Float, Float, Int, Int, Int, Int, Int, Int, Boolean)
        jmethodID configConstructor = env->GetMethodID(configClass, "<init>",
                                                       "(FFIIIIIIZ)V");
        if (configConstructor == nullptr || env->ExceptionCheck())
        {
            clearException(env);
            env->DeleteLocalRef(handleObj);
            env->DeleteLocalRef(handleClass);
            // Note: configClass is a global ref, don't delete it
            return -1;
        }

        jobject configObj = env->NewObject(configClass, configConstructor,
                                           config->positive_speech_threshold,
                                           config->negative_speech_threshold,
                                           config->pre_speech_pad_frames,
                                           config->redemption_frames,
                                           config->min_speech_frames,
                                           config->sample_rate,
                                           config->frame_samples,
                                           config->end_speech_pad_frames,
                                           config->is_debug != 0);

        if (configObj == nullptr || env->ExceptionCheck())
        {
            clearException(env);
            env->DeleteLocalRef(handleObj);
            env->DeleteLocalRef(handleClass);
            LOGE("Failed to create VADConfigInternal object");
            return -1;
        }

        // Get application context
        if (g_handleManagerClass == nullptr)
        {
            env->DeleteLocalRef(handleObj);
            env->DeleteLocalRef(handleClass);
            env->DeleteLocalRef(configObj);
            LOGE("HandleManager class not cached");
            return -1;
        }

        jmethodID getContextMethod = env->GetStaticMethodID(g_handleManagerClass,
                                                            "getApplicationContext", "()Landroid/content/Context;");
        if (getContextMethod == nullptr || env->ExceptionCheck())
        {
            clearException(env);
            env->DeleteLocalRef(handleObj);
            env->DeleteLocalRef(handleClass);
            env->DeleteLocalRef(configObj);
            LOGE("Failed to find getApplicationContext method");
            return -1;
        }

        jobject context = env->CallStaticObjectMethod(g_handleManagerClass, getContextMethod);
        if (env->ExceptionCheck())
        {
            clearException(env);
            env->DeleteLocalRef(handleObj);
            env->DeleteLocalRef(handleClass);
            env->DeleteLocalRef(configObj);
            LOGE("Exception calling getApplicationContext");
            return -1;
        }
        if (context == nullptr)
        {
            LOGE("Application context is null");
            env->DeleteLocalRef(handleObj);
            env->DeleteLocalRef(handleClass);
            env->DeleteLocalRef(configObj);
            return -1;
        }

        // Call initialize method
        jmethodID initMethod = env->GetMethodID(handleClass, "initialize",
                                                "(Ldev/miracle/vad_plus/VADConfigInternal;Ljava/lang/String;Landroid/content/Context;)I");
        if (initMethod == nullptr || env->ExceptionCheck())
        {
            clearException(env);
            env->DeleteLocalRef(handleObj);
            env->DeleteLocalRef(handleClass);
            env->DeleteLocalRef(configObj);
            env->DeleteLocalRef(context);
            LOGE("Failed to find initialize method");
            return -1;
        }

        jstring modelPathStr = (model_path != nullptr && strlen(model_path) > 0)
                                   ? env->NewStringUTF(model_path)
                                   : nullptr;

        jint result = env->CallIntMethod(handleObj, initMethod, configObj, modelPathStr, context);

        if (env->ExceptionCheck())
        {
            // Log the exception details before clearing
            jthrowable exception = env->ExceptionOccurred();
            env->ExceptionDescribe(); // This prints to logcat
            env->ExceptionClear();

            if (exception != nullptr)
            {
                jclass throwableClass = env->FindClass("java/lang/Throwable");
                jmethodID getMessageMethod = env->GetMethodID(throwableClass, "getMessage", "()Ljava/lang/String;");
                if (getMessageMethod != nullptr)
                {
                    jstring message = (jstring)env->CallObjectMethod(exception, getMessageMethod);
                    if (message != nullptr)
                    {
                        const char *messageChars = env->GetStringUTFChars(message, nullptr);
                        LOGE("Exception during initialize call: %s", messageChars);
                        env->ReleaseStringUTFChars(message, messageChars);
                        env->DeleteLocalRef(message);
                    }
                }
                env->DeleteLocalRef(throwableClass);
                env->DeleteLocalRef(exception);
            }
            result = -1;
        }

        // Cleanup (note: configClass is a global ref, don't delete it)
        if (modelPathStr != nullptr)
        {
            env->DeleteLocalRef(modelPathStr);
        }
        env->DeleteLocalRef(handleObj);
        env->DeleteLocalRef(handleClass);
        env->DeleteLocalRef(configObj);
        env->DeleteLocalRef(context);

        return result;
    }

    __attribute__((visibility("default"))) void vad_set_callback(void *handle, VADEventCallback callback, void *user_data)
    {
        if (handle == nullptr)
            return;

        JNIEnv *env = getEnv();
        if (env == nullptr)
            return;

        clearException(env);

        jlong handleId = reinterpret_cast<jlong>(handle);
        jobject handleObj = getHandle(env, handleId);
        if (handleObj == nullptr)
            return;

        jclass handleClass = env->GetObjectClass(handleObj);
        if (handleClass == nullptr || env->ExceptionCheck())
        {
            clearException(env);
            env->DeleteLocalRef(handleObj);
            return;
        }

        jmethodID setCallbackMethod = env->GetMethodID(handleClass, "setCallback", "(JJ)V");
        if (setCallbackMethod != nullptr && !env->ExceptionCheck())
        {
            env->CallVoidMethod(handleObj, setCallbackMethod,
                                reinterpret_cast<jlong>(callback),
                                reinterpret_cast<jlong>(user_data));
            clearException(env);
        }
        else
        {
            clearException(env);
        }

        env->DeleteLocalRef(handleObj);
        env->DeleteLocalRef(handleClass);
    }

    __attribute__((visibility("default"))) void vad_invalidate_callback(void *handle)
    {
        if (handle == nullptr)
            return;

        JNIEnv *env = getEnv();
        if (env == nullptr)
            return;

        clearException(env);

        jlong handleId = reinterpret_cast<jlong>(handle);
        jobject handleObj = getHandle(env, handleId);
        if (handleObj == nullptr)
            return;

        jclass handleClass = env->GetObjectClass(handleObj);
        if (handleClass == nullptr || env->ExceptionCheck())
        {
            clearException(env);
            env->DeleteLocalRef(handleObj);
            return;
        }

        jmethodID invalidateMethod = env->GetMethodID(handleClass, "invalidateCallback", "()V");
        if (invalidateMethod != nullptr && !env->ExceptionCheck())
        {
            env->CallVoidMethod(handleObj, invalidateMethod);
            clearException(env);
        }
        else
        {
            clearException(env);
        }

        env->DeleteLocalRef(handleObj);
        env->DeleteLocalRef(handleClass);
    }

    __attribute__((visibility("default")))
    int32_t
    vad_start(void *handle)
    {
        if (handle == nullptr)
            return -1;

        JNIEnv *env = getEnv();
        if (env == nullptr)
            return -1;

        clearException(env);

        jlong handleId = reinterpret_cast<jlong>(handle);
        jobject handleObj = getHandle(env, handleId);
        if (handleObj == nullptr)
            return -1;

        jclass handleClass = env->GetObjectClass(handleObj);
        if (handleClass == nullptr || env->ExceptionCheck())
        {
            clearException(env);
            env->DeleteLocalRef(handleObj);
            return -1;
        }

        jmethodID startMethod = env->GetMethodID(handleClass, "startListening", "()I");
        if (startMethod == nullptr || env->ExceptionCheck())
        {
            clearException(env);
            env->DeleteLocalRef(handleObj);
            env->DeleteLocalRef(handleClass);
            return -1;
        }

        jint result = env->CallIntMethod(handleObj, startMethod);
        if (env->ExceptionCheck())
        {
            clearException(env);
            result = -1;
        }

        env->DeleteLocalRef(handleObj);
        env->DeleteLocalRef(handleClass);

        return result;
    }

    __attribute__((visibility("default"))) void vad_stop(void *handle)
    {
        if (handle == nullptr)
            return;

        JNIEnv *env = getEnv();
        if (env == nullptr)
            return;

        clearException(env);

        jlong handleId = reinterpret_cast<jlong>(handle);
        jobject handleObj = getHandle(env, handleId);
        if (handleObj == nullptr)
            return;

        jclass handleClass = env->GetObjectClass(handleObj);
        if (handleClass == nullptr || env->ExceptionCheck())
        {
            clearException(env);
            env->DeleteLocalRef(handleObj);
            return;
        }

        jmethodID stopMethod = env->GetMethodID(handleClass, "stopListening", "()V");
        if (stopMethod != nullptr && !env->ExceptionCheck())
        {
            env->CallVoidMethod(handleObj, stopMethod);
            clearException(env);
        }
        else
        {
            clearException(env);
        }

        env->DeleteLocalRef(handleObj);
        env->DeleteLocalRef(handleClass);
    }

    __attribute__((visibility("default")))
    int32_t
    vad_process_audio(void *handle, const float *samples, int32_t sample_count)
    {
        if (handle == nullptr || samples == nullptr || sample_count <= 0)
            return -1;

        JNIEnv *env = getEnv();
        if (env == nullptr)
            return -1;

        clearException(env);

        jlong handleId = reinterpret_cast<jlong>(handle);
        jobject handleObj = getHandle(env, handleId);
        if (handleObj == nullptr)
            return -1;

        jclass handleClass = env->GetObjectClass(handleObj);
        if (handleClass == nullptr || env->ExceptionCheck())
        {
            clearException(env);
            env->DeleteLocalRef(handleObj);
            return -1;
        }

        jmethodID processMethod = env->GetMethodID(handleClass, "processAudioData", "([F)V");
        if (processMethod == nullptr || env->ExceptionCheck())
        {
            clearException(env);
            env->DeleteLocalRef(handleObj);
            env->DeleteLocalRef(handleClass);
            return -1;
        }

        jfloatArray floatArray = env->NewFloatArray(sample_count);
        if (floatArray == nullptr || env->ExceptionCheck())
        {
            clearException(env);
            env->DeleteLocalRef(handleObj);
            env->DeleteLocalRef(handleClass);
            return -1;
        }

        env->SetFloatArrayRegion(floatArray, 0, sample_count, samples);

        env->CallVoidMethod(handleObj, processMethod, floatArray);
        clearException(env);

        env->DeleteLocalRef(floatArray);
        env->DeleteLocalRef(handleObj);
        env->DeleteLocalRef(handleClass);

        return 0;
    }

    __attribute__((visibility("default"))) void vad_reset(void *handle)
    {
        if (handle == nullptr)
            return;

        JNIEnv *env = getEnv();
        if (env == nullptr)
            return;

        clearException(env);

        jlong handleId = reinterpret_cast<jlong>(handle);
        jobject handleObj = getHandle(env, handleId);
        if (handleObj == nullptr)
            return;

        jclass handleClass = env->GetObjectClass(handleObj);
        if (handleClass == nullptr || env->ExceptionCheck())
        {
            clearException(env);
            env->DeleteLocalRef(handleObj);
            return;
        }

        jmethodID resetMethod = env->GetMethodID(handleClass, "resetStates", "()V");
        if (resetMethod != nullptr && !env->ExceptionCheck())
        {
            env->CallVoidMethod(handleObj, resetMethod);
            clearException(env);
        }
        else
        {
            clearException(env);
        }

        env->DeleteLocalRef(handleObj);
        env->DeleteLocalRef(handleClass);
    }

    __attribute__((visibility("default"))) void vad_force_end_speech(void *handle)
    {
        if (handle == nullptr)
            return;

        JNIEnv *env = getEnv();
        if (env == nullptr)
            return;

        clearException(env);

        jlong handleId = reinterpret_cast<jlong>(handle);
        jobject handleObj = getHandle(env, handleId);
        if (handleObj == nullptr)
            return;

        jclass handleClass = env->GetObjectClass(handleObj);
        if (handleClass == nullptr || env->ExceptionCheck())
        {
            clearException(env);
            env->DeleteLocalRef(handleObj);
            return;
        }

        jmethodID forceEndMethod = env->GetMethodID(handleClass, "forceEndSpeech", "()V");
        if (forceEndMethod != nullptr && !env->ExceptionCheck())
        {
            env->CallVoidMethod(handleObj, forceEndMethod);
            clearException(env);
        }
        else
        {
            clearException(env);
        }

        env->DeleteLocalRef(handleObj);
        env->DeleteLocalRef(handleClass);
    }

    __attribute__((visibility("default")))
    int32_t
    vad_is_speaking(void *handle)
    {
        if (handle == nullptr)
            return 0;

        JNIEnv *env = getEnv();
        if (env == nullptr)
            return 0;

        clearException(env);

        jlong handleId = reinterpret_cast<jlong>(handle);
        jobject handleObj = getHandle(env, handleId);
        if (handleObj == nullptr)
            return 0;

        jclass handleClass = env->GetObjectClass(handleObj);
        if (handleClass == nullptr || env->ExceptionCheck())
        {
            clearException(env);
            env->DeleteLocalRef(handleObj);
            return 0;
        }

        jmethodID isSpeakingMethod = env->GetMethodID(handleClass, "isSpeaking", "()Z");
        if (isSpeakingMethod == nullptr || env->ExceptionCheck())
        {
            clearException(env);
            env->DeleteLocalRef(handleObj);
            env->DeleteLocalRef(handleClass);
            return 0;
        }

        jboolean result = env->CallBooleanMethod(handleObj, isSpeakingMethod);
        if (env->ExceptionCheck())
        {
            clearException(env);
            result = JNI_FALSE;
        }

        env->DeleteLocalRef(handleObj);
        env->DeleteLocalRef(handleClass);

        return result ? 1 : 0;
    }

    static char g_lastErrorBuffer[1024] = {0};

    __attribute__((visibility("default")))
    const char *
    vad_get_last_error(void *handle)
    {
        if (handle == nullptr)
            return "Invalid handle";

        JNIEnv *env = getEnv();
        if (env == nullptr)
            return "JNI error";

        // Clear any pending exception first - this is critical!
        clearException(env);

        jlong handleId = reinterpret_cast<jlong>(handle);
        jobject handleObj = getHandle(env, handleId);
        if (handleObj == nullptr)
            return "Handle not found";

        jclass handleClass = env->GetObjectClass(handleObj);
        if (handleClass == nullptr || env->ExceptionCheck())
        {
            clearException(env);
            env->DeleteLocalRef(handleObj);
            return "Failed to get handle class";
        }

        jmethodID getErrorMethod = env->GetMethodID(handleClass, "getLastError", "()Ljava/lang/String;");
        if (getErrorMethod == nullptr || env->ExceptionCheck())
        {
            clearException(env);
            env->DeleteLocalRef(handleObj);
            env->DeleteLocalRef(handleClass);
            return "Method not found";
        }

        jstring errorStr = (jstring)env->CallObjectMethod(handleObj, getErrorMethod);
        if (env->ExceptionCheck())
        {
            clearException(env);
            env->DeleteLocalRef(handleObj);
            env->DeleteLocalRef(handleClass);
            return "Exception getting error";
        }

        if (errorStr == nullptr)
        {
            env->DeleteLocalRef(handleObj);
            env->DeleteLocalRef(handleClass);
            return "";
        }

        const char *errorChars = env->GetStringUTFChars(errorStr, nullptr);
        if (errorChars != nullptr)
        {
            strncpy(g_lastErrorBuffer, errorChars, sizeof(g_lastErrorBuffer) - 1);
            g_lastErrorBuffer[sizeof(g_lastErrorBuffer) - 1] = '\0';
            env->ReleaseStringUTFChars(errorStr, errorChars);
        }
        else
        {
            g_lastErrorBuffer[0] = '\0';
        }

        env->DeleteLocalRef(errorStr);
        env->DeleteLocalRef(handleObj);
        env->DeleteLocalRef(handleClass);

        return g_lastErrorBuffer;
    }

    __attribute__((visibility("default"))) void vad_float_to_pcm16(const float *float_samples, int16_t *pcm16_samples, int32_t sample_count)
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

    __attribute__((visibility("default"))) void vad_pcm16_to_float(const int16_t *pcm16_samples, float *float_samples, int32_t sample_count)
    {
        for (int32_t i = 0; i < sample_count; i++)
        {
            float_samples[i] = (float)pcm16_samples[i] / 32768.0f;
        }
    }

} // extern "C"
