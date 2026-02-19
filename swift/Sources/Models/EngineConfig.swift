import Foundation

// MARK: - Download state for Qwen engines (used in Settings UI)
enum QwenDownloadState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case failed(String)
}

enum EngineType: String, CaseIterable, Codable {
    case whisperCpp = "whisper.cpp"
    case qwenSmall = "qwen-0.6b"
    case qwenLarge = "qwen-1.7b"
    
    var displayName: String {
        switch self {
        case .whisperCpp: return "Whisper.cpp"
        case .qwenSmall: return "Qwen3 0.6B (Fast)"
        case .qwenLarge: return "Qwen3 1.7B (Accurate)"
        }
    }
    
    var modelId: String? {
        switch self {
        case .whisperCpp: return nil
        case .qwenSmall: return "mlx-community/Qwen3-ASR-0.6B-4bit"
        case .qwenLarge: return "mlx-community/Qwen3-ASR-1.7B-8bit"
        }
    }
    
    var downloadSize: String {
        switch self {
        case .whisperCpp: return "~466 MB"
        case .qwenSmall: return "~400 MB"
        case .qwenLarge: return "~2.5 GB"
        }
    }
    
    var estimatedRTF: String {
        switch self {
        case .whisperCpp: return "~0.10"
        case .qwenSmall: return "~0.06"
        case .qwenLarge: return "~0.11"
        }
    }

    /// Returns the local cache directory for this engine's model weights (Qwen only).
    static func qwenCacheDirectory() -> URL {
        if let customDir = ProcessInfo.processInfo.environment["QWEN3_CACHE_DIR"] {
            return URL(fileURLWithPath: customDir)
        }
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return FileManager.default.temporaryDirectory
        }
        let dir = appSupport.appendingPathComponent("LocalWhisper/qwen3-cache")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Returns true if the model weights have been downloaded and look valid.
    func isDownloaded() -> Bool {
        guard let mid = modelId else { return true }  // non-Qwen engines are always "ready"
        let dir = Self.qwenCacheDirectory()
            .appendingPathComponent(mid.replacingOccurrences(of: "/", with: "--"))
        let weightFile = dir.appendingPathComponent("model.safetensors")
        let configFile = dir.appendingPathComponent("config.json")
        return FileManager.default.fileExists(atPath: weightFile.path)
            && FileManager.default.fileExists(atPath: configFile.path)
    }
}

struct EngineStatus {
    var isLoaded: Bool = false
    var isLoading: Bool = false
    var loadProgress: Double = 0.0
    var errorMessage: String?
}
