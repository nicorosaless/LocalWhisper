import Foundation
import AVFoundation

enum VADResult {
    case silence
    case speech
    case speechEnded
}

class VADModule {
    var config: VADConfig
    private var audioRecorder: AVAudioRecorder?
    private var silenceStartTime: Date?
    private var isCurrentlySpeaking: Bool = false
    private var lastSpeechTime: Date?
    
    init(config: VADConfig = .default) {
        self.config = config
    }
    
    func updateConfig(_ newConfig: VADConfig) {
        self.config = newConfig
    }
    
    func processAudioLevel(_ decibels: Float) -> VADResult {
        guard config.enabled else { return .silence }
        
        let threshold = decibelThreshold(for: config.sensitivity)
        let isSpeech = decibels > threshold
        
        if isSpeech {
            lastSpeechTime = Date()
            silenceStartTime = nil
            
            if !isCurrentlySpeaking {
                isCurrentlySpeaking = true
                return .speech
            }
            return .speech
        } else {
            if isCurrentlySpeaking {
                if silenceStartTime == nil {
                    silenceStartTime = Date()
                }
                
                let silenceDuration = Date().timeIntervalSince(silenceStartTime!) * 1000
                if silenceDuration >= Double(config.silenceMs) {
                    isCurrentlySpeaking = false
                    silenceStartTime = nil
                    return .speechEnded
                }
            }
            return .silence
        }
    }
    
    func checkActivationWord(_ transcript: String) -> Bool {
        guard !config.activationWord.isEmpty else { return true }
        let lowerTranscript = transcript.lowercased()
        let lowerActivation = config.activationWord.lowercased()
        return lowerTranscript.contains(lowerActivation)
    }
    
    func reset() {
        isCurrentlySpeaking = false
        silenceStartTime = nil
        lastSpeechTime = nil
    }
    
    private func decibelThreshold(for sensitivity: Int) -> Float {
        switch sensitivity {
        case 0: return -10.0
        case 1: return -20.0
        case 2: return -30.0
        case 3: return -40.0
        default: return -30.0
        }
    }
}
