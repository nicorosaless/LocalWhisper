import Foundation

enum WhisperModel: String, CaseIterable, Codable {
    case tiny = "ggml-tiny.bin"
    case base = "ggml-base.bin"
    case small = "ggml-small.bin"
    case medium = "ggml-medium.bin"
    
    var name: String {
        switch self {
        case .tiny: return "Tiny"
        case .base: return "Base"
        case .small: return "Small"
        case .medium: return "Medium"
        }
    }
    
    var downloadURL: String {
        return "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(self.rawValue)"
    }
    
    var downloadSize: String {
        switch self {
        case .tiny: return "75 MB"
        case .base: return "142 MB"
        case .small: return "466 MB"
        case .medium: return "1.5 GB"
        }
    }
    
    var description: String {
        switch self {
        case .tiny: return "Fastest, lowest accuracy"
        case .base: return "Very fast, good for clear audio"
        case .small: return "Recommended (Balanced)"
        case .medium: return "High accuracy, requires more RAM"
        }
    }
}
