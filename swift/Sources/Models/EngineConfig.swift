import Foundation

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
}

struct VADConfig: Codable {
    var enabled: Bool
    var sensitivity: Int          // 0-3 (WebRTC VAD modes)
    var silenceMs: Int            // Silence duration to trigger end
    var activationWord: String    // Optional wake word
    
    static let `default` = VADConfig(
        enabled: false,
        sensitivity: 2,
        silenceMs: 500,
        activationWord: ""
    )
}

struct EngineStatus {
    var isLoaded: Bool = false
    var isLoading: Bool = false
    var loadProgress: Double = 0.0
    var errorMessage: String?
}
