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
import java.nio.FloatBuffer
import java.nio.LongBuffer
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
 * VAD Handle Internal Implementation
 */
class VADHandleInternal {
    // ONNX Runtime
    private var ortEnv: OrtEnvironment? = null
    private var ortSession: OrtSession? = null
    
    var config = VADConfigInternal()
        private set
    
    // VAD state for v6 model (2 * 1 * 128 = 256 floats)
    private var state: FloatArray = FloatArray(0)
    private val hiddenSize = 128
    private val numLayers = 2
    
    // Context buffer for v6
    private var contextBuffer: FloatArray = FloatArray(0)
    
    // Speech detection state
    @Volatile private var _isSpeaking = false
    
    // JNI-compatible getter
    fun isSpeaking(): Boolean = _isSpeaking
    private var speechFrameCount = 0
    private var silenceFrameCount = 0
    private var speechBuffer = mutableListOf<Float>()
    private var preSpeechBuffer = mutableListOf<FloatArray>()
    private var hasEmittedRealStart = false
    
    // Audio buffer for accumulating samples
    private var audioBuffer = mutableListOf<Float>()
    
    // Audio recording
    private var audioRecord: AudioRecord? = null
    private var recordingThread: Thread? = null
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
    
    // Stored speech end data
    private var storedSpeechEndPCM16: ShortArray = ShortArray(0)
    
    init {
        resetStates()
    }
    
    fun resetStates() {
        // v6: single state tensor (2, 1, 128) = 256 floats
        state = FloatArray(numLayers * hiddenSize)
        contextBuffer = FloatArray(config.contextSize)
        
        _isSpeaking = false
        speechFrameCount = 0
        silenceFrameCount = 0
        speechBuffer.clear()
        preSpeechBuffer.clear()
        hasEmittedRealStart = false
        audioBuffer.clear()
    }
    
    fun destroy() {
        invalidateCallback()
        stopListening()
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
            val finalModelPath = when {
                !modelPath.isNullOrEmpty() && File(modelPath).exists() -> {
                    Log.d(TAG, "Using provided model path: $modelPath")
                    modelPath
                }
                else -> {
                    Log.d(TAG, "Extracting model from assets...")
                    extractModelFromAssets(context)
                }
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
                val assetManager = context.assets
                val inputStream = assetManager.open(modelName)
                
                val outputFile = File(context.cacheDir, modelName)
                if (outputFile.exists()) {
                    // Check if file is valid by comparing size
                    if (outputFile.length() > 0) {
                        if (config.isDebug) {
                            Log.d(TAG, "Using cached model: ${outputFile.absolutePath}")
                        }
                        return outputFile.absolutePath
                    }
                }
                
                FileOutputStream(outputFile).use { outputStream ->
                    inputStream.copyTo(outputStream)
                }
                inputStream.close()
                
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
                
                while (isRecording.get()) {
                    val readResult = audioRecord?.read(buffer, 0, buffer.size) ?: -1
                    
                    if (readResult > 0) {
                        // Check if callback is still valid before processing
                        if (!callbackValid.get()) {
                            continue
                        }
                        
                        // Convert PCM16 to float
                        val floatData = FloatArray(readResult) { i ->
                            buffer[i].toFloat() / 32768.0f
                        }
                        
                        processAudioData(floatData)
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
        
        try {
            audioRecord?.stop()
            audioRecord?.release()
        } catch (e: Exception) {
            // Ignore cleanup errors
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
    
    fun processAudioData(data: FloatArray) {
        audioBuffer.addAll(data.toList())
        
        while (audioBuffer.size >= config.frameSamples) {
            val frame = audioBuffer.take(config.frameSamples).toFloatArray()
            repeat(config.frameSamples) { audioBuffer.removeAt(0) }
            processFrame(frame)
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
        val env = ortEnv ?: throw IllegalStateException("ONNX environment not initialized")
        
        // Prepare input with context - shape [1, frameSamples + contextSize]
        val inputSize = config.frameSamples + config.contextSize
        val inputWithContext = FloatArray(inputSize)
        System.arraycopy(contextBuffer, 0, inputWithContext, 0, config.contextSize)
        System.arraycopy(frame, 0, inputWithContext, config.contextSize, config.frameSamples)
        
        val inputShape = longArrayOf(1, inputSize.toLong())
        val inputTensor = OnnxTensor.createTensor(env, FloatBuffer.wrap(inputWithContext), inputShape)
        
        // Prepare sample rate tensor - shape [1]
        val srTensor = OnnxTensor.createTensor(env, LongBuffer.wrap(longArrayOf(config.sampleRate.toLong())), longArrayOf(1))
        
        // Prepare state tensor - shape [2, 1, 128]
        val stateShape = longArrayOf(numLayers.toLong(), 1, hiddenSize.toLong())
        val stateTensor = OnnxTensor.createTensor(env, FloatBuffer.wrap(state), stateShape)
        
        val inputs = mapOf(
            "input" to inputTensor,
            "sr" to srTensor,
            "state" to stateTensor
        )
        
        val outputs = session.run(inputs)
        
        // Get output probability
        val outputTensor = outputs.get("output").get() as OnnxTensor
        val outputBuffer = outputTensor.floatBuffer
        val probability = outputBuffer.get(0)
        
        // Update state
        val stateOutput = outputs.get("stateN").get() as OnnxTensor
        val stateBuffer = stateOutput.floatBuffer
        stateBuffer.get(state)
        
        // Update context buffer
        val startIndex = inputWithContext.size - config.contextSize
        System.arraycopy(inputWithContext, startIndex, contextBuffer, 0, config.contextSize)
        
        // Close tensors
        inputTensor.close()
        srTensor.close()
        stateTensor.close()
        outputs.close()
        
        return probability
    }
    
    // MARK: - VAD Logic
    
    private fun processVADLogic(frame: FloatArray, probability: Float) {
        preSpeechBuffer.add(frame.clone())
        if (preSpeechBuffer.size > config.preSpeechPadFrames) {
            preSpeechBuffer.removeAt(0)
        }
        
        if (!_isSpeaking) {
            if (probability >= config.positiveSpeechThreshold) {
                _isSpeaking = true
                speechFrameCount = 1
                silenceFrameCount = 0
                hasEmittedRealStart = false
                
                for (preFrame in preSpeechBuffer) {
                    speechBuffer.addAll(preFrame.toList())
                }
                speechBuffer.addAll(frame.toList())
                
                sendEvent(VADEventType.SPEECH_START)
            }
        } else {
            speechBuffer.addAll(frame.toList())
            
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
                    speechBuffer.clear()
                    hasEmittedRealStart = false
                }
            }
        }
    }
    
    internal fun emitSpeechEnd() {
        val endPadSamples = config.endSpeechPadFrames * config.frameSamples
        val totalSamples = speechBuffer.size
        val keepSamples = maxOf(0, totalSamples - endPadSamples)
        val finalBuffer = speechBuffer.take(keepSamples + endPadSamples)
        
        // Convert to PCM16
        storedSpeechEndPCM16 = ShortArray(finalBuffer.size) { i ->
            val clamped = finalBuffer[i].coerceIn(-1.0f, 1.0f)
            (clamped * 32767).toInt().toShort()
        }
        
        val durationMs = (finalBuffer.size.toDouble() / config.sampleRate * 1000).toInt()
        
        sendSpeechEndEvent(storedSpeechEndPCM16.size, durationMs)
    }
    
    fun forceEndSpeech() {
        if (_isSpeaking && speechBuffer.isNotEmpty() && speechFrameCount >= config.minSpeechFrames) {
            emitSpeechEnd()
        }
        
        _isSpeaking = false
        speechFrameCount = 0
        silenceFrameCount = 0
        speechBuffer.clear()
        hasEmittedRealStart = false
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
                nativeSendFrameEvent(callbackPtr, userDataPtr, probability, isSpeech, frame.size)
            }
        }
    }
    
    private fun sendSpeechEndEvent(audioLength: Int, durationMs: Int) {
        if (!callbackValid.get()) return
        
        callbackLock.withLock {
            if (callbackValid.get() && callbackPtr != 0L) {
                nativeSendSpeechEndEvent(callbackPtr, userDataPtr, storedSpeechEndPCM16, audioLength, durationMs)
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
