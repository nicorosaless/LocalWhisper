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
        logDebug("[MLX ERROR] \(msg)")
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

    // Whether Metal/GPU is available for MLX (requires bundled metallib).
    // We try GPU first for speed; fall back to CPU if an MLX error occurs.
    private let gpuAvailable: Bool
    
    init(type: EngineType) {
        guard type.modelId != nil else {
            fatalError("Qwen3ASREngine requires an engine type with a modelId (Qwen engines only)")
        }
        self.type = type
        self.modelId = type.modelId ?? "mlx-community/Qwen3-ASR-0.6B-4bit"
        self.cacheDirectory = Self.getCacheDirectory()
        self.gpuAvailable = EngineType.hasBundledMLXMetallib
        logDebug("[Qwen3ASREngine] gpuAvailable=\(EngineType.hasBundledMLXMetallib)")
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
            // Load weights on CPU — weight loading is memory-bound, not compute-bound.
            // The device choice for forward passes is made per-transcription.
            model = try Device.withDefaultDevice(.cpu) {
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
        logDebug("[Qwen3ASREngine] audioData size=\(audioData.count)")
        let samples = parseWAVToFloatSamples(audioData)
        logDebug("[Qwen3ASREngine] samples count=\(samples.count)")
        
        guard !samples.isEmpty else {
            throw TranscriptionError.invalidAudioFile
        }
        
        let qwenLanguage = mapLanguageToQwen(language)

        // Temporarily: always use CPU to avoid GPU-poisoning-MLX-state issues.
        // The GPU attention path produces degenerate tensors on this machine (Apple M1 Pro,
        // macOS 26.x) and attempting GPU can corrupt MLX's scheduler state for subsequent CPU ops.
        // TODO: re-enable GPU once text decoder attention is fixed for this GPU family.
        logDebug("[Qwen3ASREngine] Running transcription on CPU")
        mlxClearError()
        let result = try Device.withDefaultDevice(.cpu) {
            try model.transcribe(samples: samples, language: qwenLanguage)
        }
        if let err = mlxLastError() {
            logDebug("[Qwen3ASREngine] CPU MLX error: \(err)")
            throw TranscriptionError.transcriptionFailed("MLX error: \(err)")
        }
        logDebug("[Qwen3ASREngine] CPU transcription succeeded")
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
    
    /// Parse a WAV file to float samples, correctly handling variable-length headers.
    /// AVAudioRecorder on macOS may write LIST/INFO chunks before the data chunk,
    /// making the PCM data start beyond the standard 44-byte offset.
    private func parseWAVToFloatSamples(_ data: Data) -> [Float] {
        // Minimum valid WAV: "RIFF" + 4 + "WAVE" = 12 bytes
        guard data.count > 44 else { return [] }

        // Find the "data" chunk by scanning the RIFF chunk list.
        // RIFF layout: [RIFF 4B][fileSize 4B][WAVE 4B] then chunks:
        //              [chunkId 4B][chunkSize 4B][chunkData ...]
        var offset = 12  // skip RIFF header

        var dataStart = -1
        var dataSize  = 0

        while offset + 8 <= data.count {
            let id = String(bytes: data[offset..<offset+4], encoding: .ascii) ?? ""
            let chunkSize = Int(data[offset+4]) |
                            Int(data[offset+5]) << 8 |
                            Int(data[offset+6]) << 16 |
                            Int(data[offset+7]) << 24
            offset += 8
            if id == "data" {
                dataStart = offset
                dataSize  = min(chunkSize, data.count - offset)
                break
            }
            // Skip this chunk (pad to even boundary)
            offset += chunkSize + (chunkSize & 1)
        }

        guard dataStart >= 0, dataSize >= 2 else {
            logDebug("[Qwen3ASREngine] ❌ No 'data' chunk found in WAV (size \(data.count))")
            return []
        }

        let nSamples = dataSize / 2
        var samples = [Float]()
        samples.reserveCapacity(nSamples)

        for i in 0..<nSamples {
            let byteOffset = dataStart + i * 2
            let low  = UInt8(data[byteOffset])
            let high = UInt8(data[byteOffset + 1])
            let intSample = Int16(bitPattern: UInt16(low) | (UInt16(high) << 8))
            samples.append(Float(intSample) / 32768.0)
        }

        logDebug("[Qwen3ASREngine] WAV parsed: dataStart=\(dataStart) nSamples=\(nSamples) duration=\(String(format: "%.2f", Double(nSamples)/16000.0))s")
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
