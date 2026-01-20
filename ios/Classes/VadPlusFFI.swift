import Foundation
import AVFoundation
import onnxruntime_objc

// MARK: - VAD Configuration (matching C struct)

struct VADConfigInternal {
    var positiveSpeechThreshold: Float = 0.5
    var negativeSpeechThreshold: Float = 0.35
    var preSpeechPadFrames: Int32 = 3
    var redemptionFrames: Int32 = 24
    var minSpeechFrames: Int32 = 9
    var sampleRate: Int32 = 16000
    var frameSamples: Int32 = 512
    var endSpeechPadFrames: Int32 = 3
    var isDebug: Bool = false
    
    var contextSize: Int {
        return sampleRate == 16000 ? 64 : 32
    }
}

// MARK: - VAD Event Types

enum VADEventTypeInternal: Int32 {
    case initialized = 0
    case speechStart = 1
    case speechEnd = 2
    case frameProcessed = 3
    case realSpeechStart = 4
    case misfire = 5
    case error = 6
    case stopped = 7
}

// MARK: - VAD Handle Class

class VADHandleInternal {
    var ortSession: ORTSession?
    var ortEnv: ORTEnv?
    
    var config = VADConfigInternal()
    
    // VAD state for v6 model (2 * 1 * 128 = 256 floats)
    var state: [Float] = []
    let hiddenSize = 128
    let numLayers = 2
    
    // Context buffer for v6
    var contextBuffer: [Float] = []
    
    // Speech detection state
    var isSpeaking = false
    var speechFrameCount = 0
    var silenceFrameCount = 0
    var speechBuffer: [Float] = []
    var preSpeechBuffer: [[Float]] = []
    var hasEmittedRealStart = false
    
    // Audio buffer for accumulating samples
    var audioBuffer: [Float] = []
    
    // Audio engine for microphone capture
    var audioEngine: AVAudioEngine?
    
    // Callback - using UnsafeRawPointer for C compatibility (Swift structs aren't directly C-representable)
    var callback: (@convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void)?
    var userData: UnsafeMutableRawPointer?
    
    // Last error
    var lastError: String = ""
    
    // Stored speech end data (for callback)
    var storedSpeechEndPCM16: [Int16] = []
    
    init() {
        resetStates()
    }
    
    func resetStates() {
        // v6: single state tensor (2, 1, 128) = 256 floats
        state = [Float](repeating: 0, count: numLayers * hiddenSize)
        contextBuffer = [Float](repeating: 0, count: config.contextSize)
        
        isSpeaking = false
        speechFrameCount = 0
        silenceFrameCount = 0
        speechBuffer = []
        preSpeechBuffer = []
        hasEmittedRealStart = false
        audioBuffer = []
    }
    
    deinit {
        stopListening()
        ortSession = nil
        ortEnv = nil
    }
    
    // MARK: - Model Loading
    
    func initialize(config: VADConfigInternal, modelPath: String?) throws {
        self.config = config
        resetStates()
        
        // Initialize ONNX Runtime
        ortEnv = try ORTEnv(loggingLevel: config.isDebug ? .verbose : .warning)
        
        // Find model path
        let finalModelPath: String
        if let path = modelPath, !path.isEmpty {
            finalModelPath = path
        } else if let bundledPath = findBundledModel() {
            finalModelPath = bundledPath
        } else {
            throw NSError(domain: "VadPlus", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "ONNX model not found"])
        }
        
        let sessionOptions = try ORTSessionOptions()
        try sessionOptions.setGraphOptimizationLevel(.all)
        
        ortSession = try ORTSession(env: ortEnv!, modelPath: finalModelPath, sessionOptions: sessionOptions)
        
        if config.isDebug {
            print("VadPlus: Model loaded from \(finalModelPath)")
        }
        
        sendEvent(type: .initialized)
    }
    
    private func findBundledModel() -> String? {
        let modelNames = ["silero_vad_v6", "silero_vad"]
        
        // Try main bundle
        for name in modelNames {
            if let path = Bundle.main.path(forResource: name, ofType: "onnx") {
                return path
            }
        }
        
        // Try plugin bundle
        let pluginBundles = Bundle.allBundles.filter { $0.bundlePath.contains("vad_plus") }
        for bundle in pluginBundles {
            for name in modelNames {
                if let path = bundle.path(forResource: name, ofType: "onnx") {
                    return path
                }
            }
        }
        
        // Try Frameworks directory
        let frameworkPaths = [
            "Frameworks/vad_plus.framework",
            "Frameworks/App.framework/flutter_assets/packages/vad_plus/onnx"
        ]
        
        for frameworkPath in frameworkPaths {
            for name in modelNames {
                let path = Bundle.main.bundlePath + "/" + frameworkPath + "/" + name + ".onnx"
                if FileManager.default.fileExists(atPath: path) {
                    return path
                }
            }
        }
        
        return nil
    }
    
    // MARK: - Audio Capture
    
    func startListening() throws {
        guard ortSession != nil else {
            throw NSError(domain: "VadPlus", code: -2,
                         userInfo: [NSLocalizedDescriptionKey: "VAD not initialized"])
        }
        
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .mixWithOthers]
        )
        try audioSession.setPreferredIOBufferDuration(0.02)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        
        audioEngine = AVAudioEngine()
        
        guard let audioEngine = audioEngine else {
            throw NSError(domain: "VadPlus", code: -3,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create audio engine"])
        }
        
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(config.sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "VadPlus", code: -4,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create audio format"])
        }
        
        var converter: AVAudioConverter?
        if inputFormat.sampleRate != outputFormat.sampleRate || inputFormat.channelCount != 1 {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        }
        
        let bufferSize = AVAudioFrameCount(config.frameSamples)
        
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            
            var floatData: [Float]
            
            if let converter = converter {
                guard let convertedBuffer = AVAudioPCMBuffer(
                    pcmFormat: outputFormat,
                    frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate)
                ) else { return }
                
                var error: NSError?
                converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                
                if error != nil { return }
                floatData = self.bufferToFloatArray(convertedBuffer)
            } else {
                floatData = self.bufferToFloatArray(buffer)
            }
            
            self.processAudioData(floatData)
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        
        if config.isDebug {
            print("VadPlus: Audio capture started")
        }
    }
    
    func stopListening() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        
        if isSpeaking && !speechBuffer.isEmpty {
            emitSpeechEnd()
        }
        
        resetStates()
        
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        
        sendEvent(type: .stopped)
    }
    
    private func bufferToFloatArray(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let frameLength = Int(buffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
    }
    
    // MARK: - Audio Processing
    
    func processAudioData(_ data: [Float]) {
        audioBuffer.append(contentsOf: data)
        
        while audioBuffer.count >= Int(config.frameSamples) {
            let frame = Array(audioBuffer.prefix(Int(config.frameSamples)))
            audioBuffer.removeFirst(Int(config.frameSamples))
            processFrame(frame)
        }
    }
    
    private func processFrame(_ frame: [Float]) {
        do {
            let probability = try runInference(frame: frame)
            
            // Send frame processed event
            sendFrameEvent(probability: probability, isSpeech: probability >= config.positiveSpeechThreshold, frame: frame)
            
            processVADLogic(frame: frame, probability: probability)
            
        } catch {
            lastError = error.localizedDescription
            sendErrorEvent(message: error.localizedDescription, code: -10)
        }
    }
    
    // MARK: - ONNX Inference (v6)
    
    private func runInference(frame: [Float]) throws -> Float {
        guard let session = ortSession else {
            throw NSError(domain: "VadPlus", code: -5,
                         userInfo: [NSLocalizedDescriptionKey: "ONNX session not initialized"])
        }
        
        // Prepare input with context - shape [1, frameSamples + contextSize]
        var inputWithContext = contextBuffer + frame
        let inputSize = Int(config.frameSamples) + config.contextSize
        let inputShape: [NSNumber] = [1, NSNumber(value: inputSize)]
        let inputData = NSMutableData(bytes: &inputWithContext, length: inputWithContext.count * MemoryLayout<Float>.size)
        let inputTensor = try ORTValue(tensorData: inputData, elementType: .float, shape: inputShape)
        
        // Prepare sample rate tensor - shape [1]
        var sampleRateValue = Int64(config.sampleRate)
        let srData = NSMutableData(bytes: &sampleRateValue, length: MemoryLayout<Int64>.size)
        let srTensor = try ORTValue(tensorData: srData, elementType: .int64, shape: [1])
        
        // Prepare state tensor - shape [2, 1, 128]
        let stateData = NSMutableData(bytes: state, length: state.count * MemoryLayout<Float>.size)
        let stateTensor = try ORTValue(tensorData: stateData, elementType: .float,
                                        shape: [NSNumber(value: numLayers), 1, NSNumber(value: hiddenSize)])
        
        let inputs: [String: ORTValue] = [
            "input": inputTensor,
            "sr": srTensor,
            "state": stateTensor
        ]
        
        let outputs = try session.run(
            withInputs: inputs,
            outputNames: Set(["output", "stateN"]),
            runOptions: nil
        )
        
        guard let outputTensor = outputs["output"],
              let outputData = try outputTensor.tensorData() as? NSData else {
            throw NSError(domain: "VadPlus", code: -6,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to get output tensor"])
        }
        
        var probability: Float = 0
        outputData.getBytes(&probability, length: MemoryLayout<Float>.size)
        
        // Update state
        if let stateOutput = outputs["stateN"],
           let stateOutputData = try stateOutput.tensorData() as? NSData {
            stateOutputData.getBytes(&state, length: state.count * MemoryLayout<Float>.size)
        }
        
        // Update context buffer
        let startIndex = inputWithContext.count - config.contextSize
        contextBuffer = Array(inputWithContext[startIndex...])
        
        return probability
    }
    
    // MARK: - VAD Logic
    
    private func processVADLogic(frame: [Float], probability: Float) {
        preSpeechBuffer.append(frame)
        if preSpeechBuffer.count > Int(config.preSpeechPadFrames) {
            preSpeechBuffer.removeFirst()
        }
        
        if !isSpeaking {
            if probability >= config.positiveSpeechThreshold {
                isSpeaking = true
                speechFrameCount = 1
                silenceFrameCount = 0
                hasEmittedRealStart = false
                
                for preFrame in preSpeechBuffer {
                    speechBuffer.append(contentsOf: preFrame)
                }
                speechBuffer.append(contentsOf: frame)
                
                sendEvent(type: .speechStart)
            }
        } else {
            speechBuffer.append(contentsOf: frame)
            
            if probability >= config.positiveSpeechThreshold {
                speechFrameCount += 1
                silenceFrameCount = 0
                
                if !hasEmittedRealStart && speechFrameCount >= Int(config.minSpeechFrames) {
                    hasEmittedRealStart = true
                    sendEvent(type: .realSpeechStart)
                }
            } else if probability < config.negativeSpeechThreshold {
                silenceFrameCount += 1
                
                if silenceFrameCount >= Int(config.redemptionFrames) {
                    if speechFrameCount >= Int(config.minSpeechFrames) {
                        emitSpeechEnd()
                    } else {
                        sendEvent(type: .misfire)
                    }
                    
                    isSpeaking = false
                    speechFrameCount = 0
                    silenceFrameCount = 0
                    speechBuffer = []
                    hasEmittedRealStart = false
                }
            }
        }
    }
    
    // fileprivate to allow access from vad_force_end_speech FFI function
    fileprivate func emitSpeechEnd() {
        let endPadSamples = Int(config.endSpeechPadFrames) * Int(config.frameSamples)
        let totalSamples = speechBuffer.count
        let keepSamples = max(0, totalSamples - endPadSamples)
        let finalBuffer = Array(speechBuffer.prefix(keepSamples + endPadSamples))
        
        // Convert to PCM16
        storedSpeechEndPCM16 = finalBuffer.map { sample in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16(clamped * 32767)
        }
        
        let durationMs = Int32(Double(finalBuffer.count) / Double(config.sampleRate) * 1000)
        
        sendSpeechEndEvent(audioLength: Int32(storedSpeechEndPCM16.count), durationMs: durationMs)
    }
    
    // MARK: - Event Sending
    
    private func sendEvent(type: VADEventTypeInternal) {
        guard let callback = callback else { return }
        
        var event = VADEventCStruct()
        event.type = type.rawValue
        
        DispatchQueue.main.async { [weak self] in
            withUnsafePointer(to: &event) { ptr in
                callback(UnsafeRawPointer(ptr), self?.userData)
            }
        }
    }
    
    private func sendFrameEvent(probability: Float, isSpeech: Bool, frame: [Float]) {
        guard let callback = callback else { return }
        
        var event = VADEventCStruct()
        event.type = VADEventTypeInternal.frameProcessed.rawValue
        event.frame_probability = probability
        event.frame_is_speech = isSpeech ? 1 : 0
        event.frame_length = Int32(frame.count)
        // Note: frame_data pointer not set here as it would be invalid after this scope
        
        DispatchQueue.main.async { [weak self] in
            withUnsafePointer(to: &event) { ptr in
                callback(UnsafeRawPointer(ptr), self?.userData)
            }
        }
    }
    
    private func sendSpeechEndEvent(audioLength: Int32, durationMs: Int32) {
        guard let callback = callback else { return }
        
        var event = VADEventCStruct()
        event.type = VADEventTypeInternal.speechEnd.rawValue
        event.speech_end_audio_length = audioLength
        event.speech_end_duration_ms = durationMs
        
        storedSpeechEndPCM16.withUnsafeBufferPointer { audioPtr in
            event.speech_end_audio_data = audioPtr.baseAddress
            DispatchQueue.main.async { [weak self] in
                withUnsafePointer(to: &event) { eventPtr in
                    callback(UnsafeRawPointer(eventPtr), self?.userData)
                }
            }
        }
    }
    
    private func sendErrorEvent(message: String, code: Int32) {
        guard let callback = callback else { return }
        
        var event = VADEventCStruct()
        event.type = VADEventTypeInternal.error.rawValue
        event.error_code = code
        
        message.withCString { cstr in
            event.error_message = cstr
            DispatchQueue.main.async { [weak self] in
                withUnsafePointer(to: &event) { ptr in
                    callback(UnsafeRawPointer(ptr), self?.userData)
                }
            }
        }
    }
}

// MARK: - C-Compatible Event Structure

/// Flat C-compatible event structure (easier for FFI than nested unions)
/// Note: Using Int32 instead of Bool for C compatibility with @convention(c)
public struct VADEventCStruct {
    public var type: Int32 = 0
    
    // Frame data
    public var frame_probability: Float = 0
    public var frame_is_speech: Int32 = 0  // 0 = false, 1 = true (Bool not C-compatible)
    public var frame_data: UnsafePointer<Float>? = nil
    public var frame_length: Int32 = 0
    
    // Speech end data
    public var speech_end_audio_data: UnsafePointer<Int16>? = nil
    public var speech_end_audio_length: Int32 = 0
    public var speech_end_duration_ms: Int32 = 0
    
    // Error data
    public var error_message: UnsafePointer<CChar>? = nil
    public var error_code: Int32 = 0
    
    public init() {}
}

// MARK: - Global Handle Storage

private var vadHandles: [UnsafeMutableRawPointer: VADHandleInternal] = [:]
private let handleLock = NSLock()

private func storeHandle(_ handle: VADHandleInternal) -> UnsafeMutableRawPointer {
    handleLock.lock()
    defer { handleLock.unlock() }
    
    let ptr = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    vadHandles[ptr] = handle
    return ptr
}

private func getHandle(_ ptr: UnsafeMutableRawPointer?) -> VADHandleInternal? {
    guard let ptr = ptr else { return nil }
    handleLock.lock()
    defer { handleLock.unlock() }
    return vadHandles[ptr]
}

private func removeHandle(_ ptr: UnsafeMutableRawPointer?) {
    guard let ptr = ptr else { return }
    handleLock.lock()
    defer { handleLock.unlock() }
    vadHandles.removeValue(forKey: ptr)
    ptr.deallocate()
}

// MARK: - FFI Exports (C-compatible functions)

@_cdecl("vad_config_default")
public func vad_config_default(_ configOut: UnsafeMutableRawPointer?) {
    guard let configOut = configOut else { return }
    let configPtr = configOut.assumingMemoryBound(to: VADConfigC.self)
    configPtr.pointee = VADConfigC(
        positive_speech_threshold: 0.5,
        negative_speech_threshold: 0.35,
        pre_speech_pad_frames: 3,
        redemption_frames: 24,
        min_speech_frames: 9,
        sample_rate: 16000,
        frame_samples: 512,
        end_speech_pad_frames: 3,
        is_debug: 0
    )
}

@_cdecl("vad_create")
public func vad_create() -> UnsafeMutableRawPointer? {
    let handle = VADHandleInternal()
    return storeHandle(handle)
}

@_cdecl("vad_destroy")
public func vad_destroy(_ handle: UnsafeMutableRawPointer?) {
    if let h = getHandle(handle) {
        h.stopListening()
    }
    removeHandle(handle)
}

@_cdecl("vad_init")
public func vad_init(_ handle: UnsafeMutableRawPointer?, _ configPtr: UnsafeRawPointer?, _ modelPath: UnsafePointer<CChar>?) -> Int32 {
    guard let h = getHandle(handle), let configPtr = configPtr else { return -1 }
    
    let config = configPtr.assumingMemoryBound(to: VADConfigC.self).pointee
    
    let internalConfig = VADConfigInternal(
        positiveSpeechThreshold: config.positive_speech_threshold,
        negativeSpeechThreshold: config.negative_speech_threshold,
        preSpeechPadFrames: config.pre_speech_pad_frames,
        redemptionFrames: config.redemption_frames,
        minSpeechFrames: config.min_speech_frames,
        sampleRate: config.sample_rate,
        frameSamples: config.frame_samples,
        endSpeechPadFrames: config.end_speech_pad_frames,
        isDebug: config.is_debug != 0
    )
    
    let pathStr: String? = modelPath != nil ? String(cString: modelPath!) : nil
    
    do {
        try h.initialize(config: internalConfig, modelPath: pathStr)
        return 0
    } catch {
        h.lastError = error.localizedDescription
        return -2
    }
}

@_cdecl("vad_set_callback")
public func vad_set_callback(
    _ handle: UnsafeMutableRawPointer?,
    _ callback: (@convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void)?,
    _ userData: UnsafeMutableRawPointer?
) {
    guard let h = getHandle(handle) else { return }
    h.callback = callback
    h.userData = userData
}

@_cdecl("vad_start")
public func vad_start(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    guard let h = getHandle(handle) else { return -1 }
    
    do {
        try h.startListening()
        return 0
    } catch {
        h.lastError = error.localizedDescription
        return -2
    }
}

@_cdecl("vad_stop")
public func vad_stop(_ handle: UnsafeMutableRawPointer?) {
    guard let h = getHandle(handle) else { return }
    h.stopListening()
}

@_cdecl("vad_process_audio")
public func vad_process_audio(_ handle: UnsafeMutableRawPointer?, _ samples: UnsafePointer<Float>?, _ sampleCount: Int32) -> Int32 {
    guard let h = getHandle(handle), let samples = samples, sampleCount > 0 else { return -1 }
    
    let audioData = Array(UnsafeBufferPointer(start: samples, count: Int(sampleCount)))
    h.processAudioData(audioData)
    return 0
}

@_cdecl("vad_reset")
public func vad_reset(_ handle: UnsafeMutableRawPointer?) {
    guard let h = getHandle(handle) else { return }
    h.resetStates()
}

@_cdecl("vad_force_end_speech")
public func vad_force_end_speech(_ handle: UnsafeMutableRawPointer?) {
    guard let h = getHandle(handle) else { return }
    
    if h.isSpeaking && !h.speechBuffer.isEmpty && h.speechFrameCount >= Int(h.config.minSpeechFrames) {
        h.emitSpeechEnd()
    }
    
    h.isSpeaking = false
    h.speechFrameCount = 0
    h.silenceFrameCount = 0
    h.speechBuffer = []
    h.hasEmittedRealStart = false
}

@_cdecl("vad_is_speaking")
public func vad_is_speaking(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    guard let h = getHandle(handle) else { return 0 }
    return h.isSpeaking ? 1 : 0
}

@_cdecl("vad_get_last_error")
public func vad_get_last_error(_ handle: UnsafeMutableRawPointer?) -> UnsafePointer<CChar>? {
    guard let h = getHandle(handle) else { return nil }
    return (h.lastError as NSString).utf8String
}

@_cdecl("vad_float_to_pcm16")
public func vad_float_to_pcm16(_ floatSamples: UnsafePointer<Float>?, _ pcm16Samples: UnsafeMutablePointer<Int16>?, _ sampleCount: Int32) {
    guard let floatSamples = floatSamples, let pcm16Samples = pcm16Samples, sampleCount > 0 else { return }
    
    for i in 0..<Int(sampleCount) {
        let clamped = max(-1.0, min(1.0, floatSamples[i]))
        pcm16Samples[i] = Int16(clamped * 32767)
    }
}

@_cdecl("vad_pcm16_to_float")
public func vad_pcm16_to_float(_ pcm16Samples: UnsafePointer<Int16>?, _ floatSamples: UnsafeMutablePointer<Float>?, _ sampleCount: Int32) {
    guard let pcm16Samples = pcm16Samples, let floatSamples = floatSamples, sampleCount > 0 else { return }
    
    for i in 0..<Int(sampleCount) {
        floatSamples[i] = Float(pcm16Samples[i]) / 32768.0
    }
}

// MARK: - C-Compatible Config Structure
/// Note: Using Int32 instead of Bool for C compatibility with @_cdecl

public struct VADConfigC {
    public var positive_speech_threshold: Float
    public var negative_speech_threshold: Float
    public var pre_speech_pad_frames: Int32
    public var redemption_frames: Int32
    public var min_speech_frames: Int32
    public var sample_rate: Int32
    public var frame_samples: Int32
    public var end_speech_pad_frames: Int32
    public var is_debug: Int32  // 0 = false, 1 = true (Bool not C-compatible)
    
    public init(
        positive_speech_threshold: Float = 0.5,
        negative_speech_threshold: Float = 0.35,
        pre_speech_pad_frames: Int32 = 3,
        redemption_frames: Int32 = 24,
        min_speech_frames: Int32 = 9,
        sample_rate: Int32 = 16000,
        frame_samples: Int32 = 512,
        end_speech_pad_frames: Int32 = 3,
        is_debug: Int32 = 0
    ) {
        self.positive_speech_threshold = positive_speech_threshold
        self.negative_speech_threshold = negative_speech_threshold
        self.pre_speech_pad_frames = pre_speech_pad_frames
        self.redemption_frames = redemption_frames
        self.min_speech_frames = min_speech_frames
        self.sample_rate = sample_rate
        self.frame_samples = frame_samples
        self.end_speech_pad_frames = end_speech_pad_frames
        self.is_debug = is_debug
    }
}

