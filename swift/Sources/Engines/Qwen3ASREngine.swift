import Foundation
import MLX

// MARK: - Global MLX error handler
// MLX evaluates ops on its own background scheduler thread (mlx::core::scheduler::StreamThread).
// That thread is NOT in any Swift Task context, so @TaskLocal-based withError() handlers
// never fire there. The default fallback is fatalError() — which causes EXC_BREAKPOINT crashes
// that are uncatchable. We override that with a global C callback that logs instead of crashing,
// allowing our Swift shape-guards to detect and handle failures gracefully.
private let mlxErrorLogBuffer = NSLock()
private var _lastMLXError: String? = nil

private func installMLXLoggingErrorHandler() {
    // setErrorHandler is deprecated but is the only way to install a truly global
    // (non-task-local) handler that fires from MLX's background eval threads.
    setErrorHandler { message, _ in
        let msg = message.map { String(cString: $0) } ?? "(unknown MLX error)"
        NSLog("[MLX ERROR] %@", msg)
        mlxErrorLogBuffer.withLock { _lastMLXError = msg }
        // Do NOT call fatalError/abort — let Swift shape-guards handle the fallout.
    }
}

func mlxLastError() -> String? {
    mlxErrorLogBuffer.withLock { _lastMLXError }
}

func mlxClearError() {
    mlxErrorLogBuffer.withLock { _lastMLXError = nil }
}

@available(macOS 14.0, *)
class Qwen3ASREngine: TranscriptionEngine {
    let type: EngineType
    var status: EngineStatus = EngineStatus()
    
    private var model: Qwen3ASRModel?
    private let modelId: String
    private let cacheDirectory: URL
    private let preferredDevice: Device
    
    init(type: EngineType) {
        guard type.modelId != nil else {
            fatalError("Qwen3ASREngine requires an engine type with a modelId (Qwen engines only)")
        }
        self.type = type
        self.modelId = type.modelId ?? "mlx-community/Qwen3-ASR-0.6B-4bit"
        self.cacheDirectory = Self.getCacheDirectory()
        // Force CPU unconditionally: GPU Metal kernels cause index-out-of-range
        // crashes deep in AudioSelfAttention.forward on macOS 26 / AGXMetalG13X.
        // CPU is safe and deterministic; re-enable GPU once root cause is confirmed.
        self.preferredDevice = .cpu
        NSLog("[Qwen3ASREngine] preferredDevice=CPU (forced)")
        // Install global logging error handler so MLX background-thread errors
        // are logged instead of calling fatalError/abort.
        installMLXLoggingErrorHandler()
    }
    
    func load(progress: @escaping (Double) -> Void) async throws {
        status.isLoading = true
        status.errorMessage = nil
        progress(0.0)

        let modelDir = cacheDirectory.appendingPathComponent(modelId.replacingOccurrences(of: "/", with: "--"))
        
        do {
            if !FileManager.default.fileExists(atPath: modelDir.path) {
                throw TranscriptionError.modelLoadFailed("Model weights not found. Please download them in Settings.")
            }
            
            progress(0.9)
            model = try Device.withDefaultDevice(preferredDevice) {
                try Qwen3ASRModel(directory: modelDir)
            }
            progress(1.0)
            
            status.isLoaded = true
        } catch {
            status.isLoading = false
            status.errorMessage = error.localizedDescription
            throw TranscriptionError.modelLoadFailed(error.localizedDescription)
        }
        
        status.isLoading = false
    }
    
    func transcribe(audioURL: URL, language: String) async throws -> String {
        guard status.isLoaded, let model = model else {
            throw TranscriptionError.modelNotLoaded
        }
        
        let audioData = try Data(contentsOf: audioURL)
        let samples = parseWAVToFloatSamples(audioData)
        
        guard !samples.isEmpty else {
            throw TranscriptionError.invalidAudioFile
        }
        
        mlxClearError()
        let qwenLanguage = mapLanguageToQwen(language)
        let result = try Device.withDefaultDevice(preferredDevice) {
            try model.transcribe(samples: samples, language: qwenLanguage)
        }
        
        if let err = mlxLastError() {
            NSLog("[Qwen3ASREngine] MLX error occurred during transcription: %@", err)
            throw TranscriptionError.transcriptionFailed("MLX error: \(err)")
        }
        
        return result
    }
    
    func unload() {
        model = nil
        status.isLoaded = false
    }
    
    private static func getCacheDirectory() -> URL {
        if let customDir = ProcessInfo.processInfo.environment["QWEN3_CACHE_DIR"] {
            return URL(fileURLWithPath: customDir)
        }
        
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return FileManager.default.temporaryDirectory
        }
        
        let cacheDir = appSupport.appendingPathComponent("LocalWhisper/qwen3-cache")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return cacheDir
    }
    
    // downloadModel removed as it's handled by ModelDownloadService
    
    private func parseWAVToFloatSamples(_ data: Data) -> [Float] {
        let headerSize = 44
        guard data.count > headerSize else { return [] }
        
        var samples: [Float] = []
        samples.reserveCapacity((data.count - headerSize) / 2)
        
        var i = headerSize
        while i + 1 < data.count {
            let low = UInt8(data[i])
            let high = UInt8(data[i + 1])
            let intSample = Int16(low) | (Int16(high) << 8)
            samples.append(Float(intSample) / 32768.0)
            i += 2
        }
        
        return samples
    }
    
    private func mapLanguageToQwen(_ lang: String) -> String {
        let mapping: [String: String] = [
            "es": "Spanish",
            "en": "English",
            "fr": "French",
            "de": "German",
            "it": "Italian",
            "pt": "Portuguese",
            "zh": "Chinese",
            "ja": "Japanese",
            "ko": "Korean",
            "ru": "Russian",
            "ar": "Arabic",
            "auto": "English"
        ]
        return mapping[lang] ?? "English"
    }
}
