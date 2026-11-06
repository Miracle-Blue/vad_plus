package dev.miracle.vad_plus

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Log
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import java.io.File
import java.io.FileOutputStream
import java.nio.Buffer
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * VAD Configuration matching the C struct
 */
data class VADConfigInternal(
    var positiveSpeechThreshold: Float = 0.5f,
    var negativeSpeechThreshold: Float = 0.35f,
    var preSpeechPadFrames: Int = 3,
    var redemptionFrames: Int = 24,
    var minSpeechFrames: Int = 9,
    var sampleRate: Int = 16000,
    var frameSamples: Int = 512,
    var endSpeechPadFrames: Int = 3,
    var isDebug: Boolean = false
) {
    val contextSize: Int
        get() = if (sampleRate == 16000) 64 else 32
}

/**
 * VAD Event Types matching the C enum
 */
object VADEventType {
    const val INITIALIZED = 0
    const val SPEECH_START = 1
    const val SPEECH_END = 2
    const val FRAME_PROCESSED = 3
    const val REAL_SPEECH_START = 4
    const val MISFIRE = 5
    const val ERROR = 6
    const val STOPPED = 7
}

/**
 * Call clear(), flip() and position(Int) through this. FloatBuffer's own
 * overloads only exist from API 34 and would crash on older Android (minSdk 24);
 * Buffer's exist on every release.
 */
private val FloatBuffer.base: Buffer get() = this

/**
 * The model's tensors, created once per session over direct buffers so ONNX
 * Runtime reads and writes them in place instead of copying every frame.
 */
private class ModelIO(env: OrtEnvironment, config: VADConfigInternal) : AutoCloseable {
    private val input = floatBuffer(config.frameSamples + config.contextSize)
    private val state = floatBuffer(STATE_LAYERS * STATE_HIDDEN_SIZE)
    private val nextState = floatBuffer(STATE_LAYERS * STATE_HIDDEN_SIZE)
    private val probability = floatBuffer(1)
    private val sampleRate = directBytes(Long.SIZE_BYTES).asLongBuffer()
        .put(0, config.sampleRate.toLong())

    private val inputs = mapOf(
        "input" to OnnxTensor.createTensor(env, input, longArrayOf(1, input.capacity().toLong())),
        "sr" to OnnxTensor.createTensor(env, sampleRate, longArrayOf(1)),
        "state" to OnnxTensor.createTensor(env, state, STATE_SHAPE)
    )
    private val outputs = mapOf(
        "output" to OnnxTensor.createTensor(env, probability, longArrayOf(1, 1)),
        "stateN" to OnnxTensor.createTensor(env, nextState, STATE_SHAPE)
    )

    /** Runs one frame and leaves its tail in [context] for the next one. */
    fun run(session: OrtSession, context: FloatArray, frame: FloatArray): Float {
        input.base.clear()
        input.put(context).put(frame)

        session.run(inputs, outputs).close()

        state.base.clear()
        nextState.base.clear()
        state.put(nextState)

        input.base.position(frame.size)
        input.get(context)
        return probability.get(0)
    }

    fun resetState() {
        state.base.clear()
        while (state.hasRemaining()) state.put(0f)
    }

    override fun close() {
        (inputs.values + outputs.values).forEach { it.close() }
    }

    private companion object {
        // v6 model: state tensor (2, 1, 128)
        const val STATE_LAYERS = 2
        const val STATE_HIDDEN_SIZE = 128
        val STATE_SHAPE = longArrayOf(STATE_LAYERS.toLong(), 1, STATE_HIDDEN_SIZE.toLong())

        fun directBytes(size: Int): ByteBuffer =
            ByteBuffer.allocateDirect(size).order(ByteOrder.nativeOrder())

        fun floatBuffer(size: Int): FloatBuffer = directBytes(size * Float.SIZE_BYTES).asFloatBuffer()
    }
}

/**
 * VAD Handle Internal Implementation
 *
 * Audio processing runs on the microphone thread and on Dart's thread, and it
 * reuses its buffers, so everything touching them is synchronized.
 */
class VADHandleInternal {
    // ONNX Runtime
    private var ortEnv: OrtEnvironment? = null
    private var ortSession: OrtSession? = null
    private var modelIO: ModelIO? = null
    
    var config = VADConfigInternal()
        private set
    
    // Context buffer for v6
    private var contextBuffer: FloatArray = FloatArray(0)
    
    // Speech detection state
    @Volatile private var _isSpeaking = false
    
    // JNI-compatible getter
    fun isSpeaking(): Boolean = _isSpeaking
    private var speechFrameCount = 0
    private var silenceFrameCount = 0
    private var hasEmittedRealStart = false
    // pcmLength at the last non-silence frame — endSpeechPadFrames of padding
    // is kept after this point when a segment is emitted
    private var samplesAtLastVoice = 0

    // The frame being filled from incoming audio
    private var frame = FloatArray(0)
    private var frameFill = 0

    // The current segment as PCM16. Between segments it holds just the last
    // preSpeechPadFrames frames, which become the next segment's lead-in.
    // ponytail: capacity stays at the longest segment so far, release it in
    // resetStates if very long segments ever matter.
    private var pcm = ShortArray(0)
    private var pcmLength = 0

    // Audio recording
    private var audioRecord: AudioRecord? = null
    private var recordingThread: Thread? = null
    private var releaseThread: Thread? = null
    private val isRecording = AtomicBoolean(false)
    
    // Callback - using native pointer for FFI
    private val callbackLock = ReentrantLock()
    private var callbackPtr: Long = 0
    private var userDataPtr: Long = 0
    private var callbackValid = AtomicBoolean(false)
    
    // Last error
    private var _lastError: String = ""
    
    // JNI-compatible getter
    fun getLastError(): String = _lastError
    
    init {
        resetStates()
    }
    
    @Synchronized
    fun resetStates() {
        modelIO?.resetState()
        contextBuffer = FloatArray(config.contextSize)
        frame = FloatArray(config.frameSamples)
        frameFill = 0
        
        _isSpeaking = false
        speechFrameCount = 0
        silenceFrameCount = 0
        pcmLength = 0
        hasEmittedRealStart = false
        samplesAtLastVoice = 0
    }
    
    fun destroy() {
        invalidateCallback()
        stopListening()
        closeModel()
    }

    @Synchronized
    private fun closeModel() {
        modelIO?.close()
        modelIO = null
        ortSession?.close()
        ortSession = null
        ortEnv?.close()
        ortEnv = null
    }
    
    // MARK: - Model Loading
    
    fun initialize(config: VADConfigInternal, modelPath: String?, context: Context): Int {
        this.config = config
        resetStates()
        
        try {
            // Initialize ONNX Runtime
            Log.d(TAG, "Initializing ONNX Runtime environment...")
            ortEnv = OrtEnvironment.getEnvironment()
            Log.d(TAG, "ONNX Runtime environment created successfully")
            
            // Find model path
            val finalModelPath = if (!modelPath.isNullOrEmpty()) {
                if (!File(modelPath).exists()) {
                    _lastError = "Model file not found at provided path: $modelPath"
                    Log.e(TAG, _lastError)
                    return -2
                }
                Log.d(TAG, "Using provided model path: $modelPath")
                modelPath
            } else {
                Log.d(TAG, "Extracting model from assets...")
                extractModelFromAssets(context)
            }
            
            if (finalModelPath == null) {
                _lastError = "ONNX model not found in assets or provided path"
                Log.e(TAG, _lastError)
                return -2
            }
            
            // Verify model file exists and has content
            val modelFile = File(finalModelPath)
            if (!modelFile.exists() || modelFile.length() == 0L) {
                _lastError = "Model file does not exist or is empty: $finalModelPath"
                Log.e(TAG, _lastError)
                return -2
            }
            Log.d(TAG, "Model file verified: ${modelFile.length()} bytes at $finalModelPath")
            
            Log.d(TAG, "Creating ONNX session options...")
            val sessionOptions = OrtSession.SessionOptions()
            sessionOptions.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
            // Use CPU execution provider only - avoid NNAPI which may not support all operators
            // This prevents the "this model don't Support" error from MirrorManager/NNAPI
            
            Log.d(TAG, "Creating ONNX session from model...")
            ortSession = ortEnv!!.createSession(finalModelPath, sessionOptions)
            modelIO = ModelIO(ortEnv!!, config)
            Log.d(TAG, "ONNX session created successfully")
            
            // Log model info
            val inputNames = ortSession!!.inputNames
            val outputNames = ortSession!!.outputNames
            Log.d(TAG, "Model inputs: $inputNames, outputs: $outputNames")
            
            sendEvent(VADEventType.INITIALIZED)
            return 0
            
        } catch (e: Exception) {
            _lastError = "Initialization failed: ${e.javaClass.simpleName}: ${e.message}"
            Log.e(TAG, "Initialization error: $_lastError", e)
            // Print full stack trace for debugging
            e.printStackTrace()
            return -2
        }
    }
    
    private fun extractModelFromAssets(context: Context): String? {
        val modelNames = listOf("silero_vad_v6.onnx", "silero_vad.onnx")
        
        for (modelName in modelNames) {
            try {
                // Always overwrite the cached copy so a model bundled by a
                // plugin update is never shadowed by a stale extraction.
                val outputFile = File(context.cacheDir, modelName)
                context.assets.open(modelName).use { inputStream ->
                    FileOutputStream(outputFile).use { outputStream ->
                        inputStream.copyTo(outputStream)
                    }
                }

                if (config.isDebug) {
                    Log.d(TAG, "Extracted model to: ${outputFile.absolutePath}")
                }
                return outputFile.absolutePath

            } catch (e: Exception) {
                if (config.isDebug) {
                    Log.d(TAG, "Model $modelName not found in assets: ${e.message}")
                }
                continue
            }
        }
        
        return null
    }
    
    // MARK: - Audio Capture
    
    fun startListening(): Int {
        if (ortSession == null) {
            _lastError = "VAD not initialized"
            return -2
        }
        
        if (isRecording.get()) {
            return 0 // Already recording
        }
        
        try {
            // Android below 10 allows one capture at a time, so let the last
            // one finish. Only a start right after a stop waits here.
            releaseThread?.join(1000)

            val channelConfig = AudioFormat.CHANNEL_IN_MONO
            val audioFormat = AudioFormat.ENCODING_PCM_16BIT
            val bufferSize = maxOf(
                AudioRecord.getMinBufferSize(config.sampleRate, channelConfig, audioFormat),
                config.frameSamples * 2 * 4 // At least 4 frames worth
            )
            
            audioRecord = AudioRecord(
                MediaRecorder.AudioSource.MIC,
                config.sampleRate,
                channelConfig,
                audioFormat,
                bufferSize
            )
            
            if (audioRecord?.state != AudioRecord.STATE_INITIALIZED) {
                _lastError = "Failed to initialize AudioRecord"
                return -3
            }
            
            audioRecord?.startRecording()
            isRecording.set(true)
            
            recordingThread = Thread {
                val buffer = ShortArray(config.frameSamples)
                val samples = FloatBuffer.allocate(config.frameSamples)
                
                while (isRecording.get()) {
                    val readResult = audioRecord?.read(buffer, 0, buffer.size) ?: -1
                    
                    if (readResult > 0) {
                        // Check if callback is still valid before processing
                        if (!callbackValid.get()) {
                            continue
                        }
                        
                        // Convert PCM16 to float
                        samples.base.clear()
                        for (i in 0 until readResult) {
                            samples.put(buffer[i].toFloat() / 32768.0f)
                        }
                        samples.base.flip()
                        
                        processAudioData(samples)
                    }
                }
            }.apply {
                name = "VadPlusAudioThread"
                start()
            }
            
            if (config.isDebug) {
                Log.d(TAG, "Audio capture started")
            }
            
            return 0
            
        } catch (e: SecurityException) {
            _lastError = "Microphone permission not granted"
            return -4
        } catch (e: Exception) {
            _lastError = e.message ?: "Failed to start audio capture"
            return -5
        }
    }
    
    fun stopListening() {
        isRecording.set(false)
        
        try {
            recordingThread?.join(1000)
        } catch (e: InterruptedException) {
            // Ignore
        }
        recordingThread = null
        
        // AudioRecord.stop() takes 300 ms or more, too long for Dart's thread.
        // Nothing reads from it by now, so it can finish in the background.
        audioRecord?.let { record ->
            releaseThread = Thread {
                try {
                    record.stop()
                    record.release()
                } catch (e: Exception) {
                    // Ignore cleanup errors
                }
            }.apply {
                name = "VadPlusAudioRelease"
                start()
            }
        }
        audioRecord = null

        resetStates()
        sendEvent(VADEventType.STOPPED)
    }
    
    // MARK: - Callback Management
    
    fun setCallback(callback: Long, userData: Long) {
        callbackLock.withLock {
            callbackPtr = callback
            userDataPtr = userData
            callbackValid.set(callback != 0L)
        }
    }
    
    fun invalidateCallback() {
        callbackLock.withLock {
            callbackValid.set(false)
            callbackPtr = 0
            userDataPtr = 0
        }
    }
    
    // MARK: - Audio Processing
    
    /** JNI entry for vad_process_audio: [samples] wraps Dart's native floats. */
    fun processNativeAudio(samples: ByteBuffer) {
        processAudioData(samples.order(ByteOrder.nativeOrder()).asFloatBuffer())
    }

    @Synchronized
    fun processAudioData(samples: FloatBuffer) {
        while (samples.hasRemaining()) {
            val count = minOf(samples.remaining(), frame.size - frameFill)
            samples.get(frame, frameFill, count)
            frameFill += count

            if (frameFill == frame.size) {
                frameFill = 0
                processFrame(frame)
            }
        }
    }
    
    private fun processFrame(frame: FloatArray) {
        try {
            val probability = runInference(frame)
            
            // Send frame processed event
            sendFrameEvent(probability, probability >= config.positiveSpeechThreshold, frame)
            
            processVADLogic(frame, probability)
            
        } catch (e: Exception) {
            _lastError = e.message ?: "Inference error"
            sendErrorEvent(_lastError, -10)
        }
    }
    
    // MARK: - ONNX Inference (v6)
    
    private fun runInference(frame: FloatArray): Float {
        val session = ortSession ?: throw IllegalStateException("ONNX session not initialized")
        val io = modelIO ?: throw IllegalStateException("ONNX session not initialized")
        return io.run(session, contextBuffer, frame)
    }
    
    // MARK: - VAD Logic
    
    private fun processVADLogic(frame: FloatArray, probability: Float) {
        appendPcm(frame)

        if (!_isSpeaking) {
            if (probability >= config.positiveSpeechThreshold) {
                _isSpeaking = true
                speechFrameCount = 1
                silenceFrameCount = 0
                hasEmittedRealStart = false

                // pcm already holds the lead-in followed by this frame
                samplesAtLastVoice = pcmLength

                sendEvent(VADEventType.SPEECH_START)
            }
        } else {
            if (probability >= config.negativeSpeechThreshold) {
                // Not silence — the end pad counts from here
                samplesAtLastVoice = pcmLength
            }

            if (probability >= config.positiveSpeechThreshold) {
                speechFrameCount++
                silenceFrameCount = 0
                
                if (!hasEmittedRealStart && speechFrameCount >= config.minSpeechFrames) {
                    hasEmittedRealStart = true
                    sendEvent(VADEventType.REAL_SPEECH_START)
                }
            } else if (probability < config.negativeSpeechThreshold) {
                silenceFrameCount++
                
                if (silenceFrameCount >= config.redemptionFrames) {
                    if (speechFrameCount >= config.minSpeechFrames) {
                        emitSpeechEnd()
                    } else {
                        sendEvent(VADEventType.MISFIRE)
                    }
                    
                    _isSpeaking = false
                    speechFrameCount = 0
                    silenceFrameCount = 0
                    hasEmittedRealStart = false
                    samplesAtLastVoice = 0
                }
            }
        }

        if (!_isSpeaking) trimToLeadIn()
    }

    private fun appendPcm(samples: FloatArray) {
        val newLength = pcmLength + samples.size
        if (newLength > pcm.size) {
            pcm = pcm.copyOf(maxOf(newLength, pcm.size * 2))
        }
        for (i in samples.indices) {
            val clamped = samples[i].coerceIn(-1.0f, 1.0f)
            pcm[pcmLength + i] = (clamped * 32767).toInt().toShort()
        }
        pcmLength = newLength
    }

    /** Keeps only the last preSpeechPadFrames frames of pcm. */
    private fun trimToLeadIn() {
        val keep = maxOf(0, config.preSpeechPadFrames) * config.frameSamples
        if (pcmLength > keep) {
            System.arraycopy(pcm, pcmLength - keep, pcm, 0, keep)
            pcmLength = keep
        }
    }
    
    internal fun emitSpeechEnd() {
        // Keep audio up to the last voiced frame plus endSpeechPadFrames of
        // padding; the rest of the redemption-window silence is trimmed.
        val endPadSamples = maxOf(0, config.endSpeechPadFrames) * config.frameSamples
        val keepSamples = minOf(pcmLength, samplesAtLastVoice + endPadSamples)
        val durationMs = (keepSamples.toDouble() / config.sampleRate * 1000).toInt()
        
        sendSpeechEndEvent(keepSamples, durationMs)
    }
    
    @Synchronized
    fun forceEndSpeech() {
        if (_isSpeaking && speechFrameCount >= config.minSpeechFrames) {
            emitSpeechEnd()
        }
        
        _isSpeaking = false
        speechFrameCount = 0
        silenceFrameCount = 0
        hasEmittedRealStart = false
        samplesAtLastVoice = 0
        trimToLeadIn()
    }
    
    // MARK: - Event Sending (Native Callbacks)
    
    private fun sendEvent(type: Int) {
        if (!callbackValid.get()) return
        
        callbackLock.withLock {
            if (callbackValid.get() && callbackPtr != 0L) {
                nativeSendEvent(callbackPtr, userDataPtr, type)
            }
        }
    }
    
    private fun sendFrameEvent(probability: Float, isSpeech: Boolean, frame: FloatArray) {
        if (!callbackValid.get()) return
        
        callbackLock.withLock {
            if (callbackValid.get() && callbackPtr != 0L) {
                nativeSendFrameEvent(callbackPtr, userDataPtr, probability, isSpeech, frame, frame.size)
            }
        }
    }
    
    private fun sendSpeechEndEvent(audioLength: Int, durationMs: Int) {
        if (!callbackValid.get()) return
        
        callbackLock.withLock {
            if (callbackValid.get() && callbackPtr != 0L) {
                nativeSendSpeechEndEvent(callbackPtr, userDataPtr, pcm, audioLength, durationMs)
            }
        }
    }
    
    private fun sendErrorEvent(message: String, code: Int) {
        if (!callbackValid.get()) return
        
        callbackLock.withLock {
            if (callbackValid.get() && callbackPtr != 0L) {
                nativeSendErrorEvent(callbackPtr, userDataPtr, message, code)
            }
        }
    }
    
    companion object {
        private const val TAG = "VadPlusFFI"
        
        init {
            System.loadLibrary("vad_plus")
        }
        
        // Native methods for sending events to Dart
        @JvmStatic
        private external fun nativeSendEvent(callbackPtr: Long, userDataPtr: Long, type: Int)
        
        @JvmStatic
        private external fun nativeSendFrameEvent(
            callbackPtr: Long, 
            userDataPtr: Long, 
            probability: Float, 
            isSpeech: Boolean,
            frameData: FloatArray,
            frameLength: Int
        )
        
        @JvmStatic
        private external fun nativeSendSpeechEndEvent(
            callbackPtr: Long, 
            userDataPtr: Long, 
            audioData: ShortArray, 
            audioLength: Int, 
            durationMs: Int
        )
        
        @JvmStatic
        private external fun nativeSendErrorEvent(
            callbackPtr: Long, 
            userDataPtr: Long, 
            message: String, 
            code: Int
        )
    }
}

/**
 * Global handle storage for FFI
 */
object VadPlusHandleManager {
    private val handles = ConcurrentHashMap<Long, VADHandleInternal>()
    private var nextHandleId = 1L
    private val lock = ReentrantLock()
    
    // Application context for asset access
    // Note: Using explicit getter/setter for JNI compatibility
    @Volatile
    @JvmField
    var applicationContext: Context? = null
    
    // Explicit method for JNI access - JNI code looks for this method name
    @JvmStatic
    fun getApplicationContext(): Context? = applicationContext
    
    @JvmStatic
    fun createHandle(): Long {
        lock.withLock {
            val handle = VADHandleInternal()
            val id = nextHandleId++
            handles[id] = handle
            return id
        }
    }
    
    @JvmStatic
    fun getHandle(id: Long): VADHandleInternal? = handles[id]
    
    @JvmStatic
    fun removeHandle(id: Long) {
        lock.withLock {
            handles.remove(id)?.destroy()
        }
    }
}
