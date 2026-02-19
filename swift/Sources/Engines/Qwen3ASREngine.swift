import Foundation
import MLX

@available(macOS 14.0, *)
class Qwen3ASREngine: TranscriptionEngine {
    let type: EngineType
    var status: EngineStatus = EngineStatus()
    
    private var model: Qwen3ASRModel?
    private let modelId: String
    private let cacheDirectory: URL
    
    init(type: EngineType) {
        guard type == .qwenSmall || type == .qwenLarge else {
            fatalError("Qwen3ASREngine only supports qwenSmall or qwenLarge types")
        }
        self.type = type
        self.modelId = type.modelId ?? "mlx-community/Qwen3-ASR-0.6B-4bit"
        self.cacheDirectory = Self.getCacheDirectory()
    }
    
    func load(progress: @escaping (Double) -> Void) async throws {
        status.isLoading = true
        status.errorMessage = nil
        progress(0.0)
        
        let modelDir = cacheDirectory.appendingPathComponent(modelId.replacingOccurrences(of: "/", with: "--"))
        
        do {
            if !FileManager.default.fileExists(atPath: modelDir.path) {
                progress(0.1)
                try await downloadModel(to: modelDir, progress: { p in
                    progress(0.1 + p * 0.8)
                })
            } else {
                progress(0.5)
            }
            
            progress(0.9)
            model = try Qwen3ASRModel(directory: modelDir)
            progress(1.0)
            
            status.isLoaded = true
        } catch {
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
        
        let qwenLanguage = mapLanguageToQwen(language)
        let result = try model.transcribe(samples: samples, language: qwenLanguage)
        
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
    
    private func downloadModel(to directory: URL, progress: @escaping (Double) -> Void) async throws {
        let configFiles = [
            "config.json",
            "tokenizer_config.json",
            "generation_config.json",
            "chat_template.json",
            "preprocessor_config.json",
            "vocab.json",
            "merges.txt"
        ]
        let weightFiles = ["model.safetensors"]

        let baseURL = "https://huggingface.co/\(modelId)/resolve/main"

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var totalProgress = 0.0
        let totalFiles = configFiles.count + weightFiles.count
        let progressPerFile = 1.0 / Double(totalFiles)

        for file in configFiles {
            guard let url = URL(string: "\(baseURL)/\(file)") else { continue }
            do {
                let (localURL, _) = try await URLSession.shared.download(from: url)
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
                try FileManager.default.moveItem(at: localURL, to: directory.appendingPathComponent(file))
            } catch {
                // Some config files may be optional — log but continue
                print("Warning: could not download \(file): \(error.localizedDescription)")
            }
            totalProgress += progressPerFile
            progress(totalProgress)
        }

        for file in weightFiles {
            guard let url = URL(string: "\(baseURL)/\(file)") else { continue }
            let (localURL, _) = try await URLSession.shared.download(from: url)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
            try FileManager.default.moveItem(at: localURL, to: directory.appendingPathComponent(file))
            totalProgress += progressPerFile
            progress(totalProgress)
        }
    }
    
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
