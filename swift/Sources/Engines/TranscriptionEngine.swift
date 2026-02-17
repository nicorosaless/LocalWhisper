import Foundation

protocol TranscriptionEngine {
    var type: EngineType { get }
    var status: EngineStatus { get }
    
    func load(progress: @escaping (Double) -> Void) async throws
    func transcribe(audioURL: URL, language: String) async throws -> String
    func unload()
}

enum TranscriptionError: Error, LocalizedError {
    case modelNotLoaded
    case modelLoadFailed(String)
    case transcriptionFailed(String)
    case invalidAudioFile
    case audioProcessingFailed
    
    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Model is not loaded"
        case .modelLoadFailed(let reason):
            return "Failed to load model: \(reason)"
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        case .invalidAudioFile:
            return "Invalid audio file"
        case .audioProcessingFailed:
            return "Failed to process audio"
        }
    }
}
