import Foundation

class WhisperCppEngine: TranscriptionEngine {
    let type: EngineType = .whisperCpp
    var status: EngineStatus = EngineStatus()
    
    private let appDir: String
    private var modelPath: String
    
    init(appDir: String, modelPath: String) {
        self.appDir = appDir
        self.modelPath = modelPath
    }
    
    func load(progress: @escaping (Double) -> Void) async throws {
        status.isLoading = true
        status.errorMessage = nil
        
        let fm = FileManager.default
        
        if fm.fileExists(atPath: modelPath) {
            status.isLoaded = true
            status.isLoading = false
            progress(1.0)
            return
        }
        
        // If model is missing, we try to download the default small model as fallback
        // but ideally onboarding should have handled this.
        let modelURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"
        guard let url = URL(string: modelURL) else {
            throw TranscriptionError.modelLoadFailed("Invalid URL")
        }
        
        // If the path was customized, we should probably not download small.bin to that path
        // unless the path itself ends in ggml-small.bin
        if !modelPath.hasSuffix("ggml-small.bin") {
             throw TranscriptionError.modelLoadFailed("Model not found at \(modelPath). Please run onboarding or download the model in Settings.")
        }
        
        let modelsDir = (modelPath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: modelsDir, withIntermediateDirectories: true)
        
        do {
            let (localURL, _) = try await URLSession.shared.download(from: url, progress: progress)
            try fm.moveItem(at: localURL, to: URL(fileURLWithPath: modelPath))
            status.isLoaded = true
        } catch {
            status.errorMessage = error.localizedDescription
            throw TranscriptionError.modelLoadFailed(error.localizedDescription)
        }
        
        status.isLoading = false
    }
    
    func transcribe(audioURL: URL, language: String) async throws -> String {
        guard status.isLoaded else {
            throw TranscriptionError.modelNotLoaded
        }
        
        guard let whisperCliPath = getWhisperCliPath() else {
            throw TranscriptionError.modelLoadFailed("whisper-cli not found")
        }
        
        // Auto-detect model file if modelPath is a directory or doesn't end with .bin
        var actualModelPath = modelPath
        if !actualModelPath.hasSuffix(".bin") {
            // modelPath might be a directory like "models" or "/path/to/LocalWhisper/models"
            var modelsDir = modelPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: modelsDir, isDirectory: &isDir), isDir.boolValue {
                // modelPath IS a directory, use it directly
            } else {
                // modelPath might be empty or invalid, try the default location
                let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                modelsDir = appSupport.appendingPathComponent("LocalWhisper/models").path
            }
            
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: modelsDir) {
                if let binFile = contents.first(where: { $0.hasSuffix(".bin") }) {
                    actualModelPath = modelsDir + "/" + binFile
                    logDebug("[WhisperCppEngine] Auto-detected model: \(actualModelPath)")
                }
            }
        }
        
        let qualityPrompt: String
        switch language {
        case "es":
            qualityPrompt = "Esta es una transcripción de alta calidad en español, con puntuación correcta y mayúsculas apropiadas."
        case "en":
            qualityPrompt = "This is a high-quality transcription in English, with correct punctuation and proper capitalization."
        default:
            qualityPrompt = "High-quality transcription with correct punctuation."
        }
        
        let perfCores = getPerformanceCoreCount()
        let threads = perfCores > 0 ? perfCores : ProcessInfo.processInfo.processorCount
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperCliPath)
        process.arguments = [
            "-m", actualModelPath,
            "-f", audioURL.path,
            "-nt",
            "-t", String(threads),
            "-bs", "2",
            "-bo", "0",
            "-lpt", "-1.0",
            "--prompt", qualityPrompt,
            "-l", language
        ]
        
        var env = ProcessInfo.processInfo.environment
        if let resourcePath = Bundle.main.resourcePath {
            let libPath = resourcePath + "/lib"
            env["DYLD_LIBRARY_PATH"] = libPath
        }
        process.environment = env
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        try process.run()
        
        // Non-blocking async wait using continuation
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }
        
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        
        return parseWhisperOutput(output)
    }
    
    func unload() {
        status.isLoaded = false
    }
    
    private func getWhisperCliPath() -> String? {
        if let bundlePath = Bundle.main.path(forResource: "whisper-cli", ofType: nil, inDirectory: "bin") {
            return bundlePath
        }
        
        let localBinPath = "\(appDir)/bin/whisper-cli"
        if FileManager.default.fileExists(atPath: localBinPath) {
            return localBinPath
        }
        
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/whisper-cli") {
            return "/opt/homebrew/bin/whisper-cli"
        }
        
        return nil
    }
    
    private func getPerformanceCoreCount() -> Int {
        var results: Int = 0
        var size = MemoryLayout<Int>.size
        if sysctlbyname("hw.perflevel0.logicalcpu", &results, &size, nil, 0) == 0 {
            return results
        }
        return 0
    }
    
    private func parseWhisperOutput(_ output: String) -> String {
        var lines: [String] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            
            if trimmed.localizedCaseInsensitiveContains("blank audio") { continue }
            if trimmed == "[BLANK_AUDIO]" { continue }
            
            if trimmed.hasPrefix("[") && trimmed.contains("-->") {
                if let idx = trimmed.firstIndex(of: "]") {
                    let text = String(trimmed[trimmed.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty { lines.append(text) }
                }
            } else if !trimmed.hasPrefix("whisper_") && !trimmed.hasPrefix("main:") {
                lines.append(trimmed)
            }
        }
        return lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

extension URLSession {
    func download(from url: URL, progress: @escaping (Double) -> Void) async throws -> (URL, URLResponse) {
        let (asyncBytes, response) = try await self.bytes(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse,
              let expectedLength = Int(exactly: httpResponse.expectedContentLength),
              expectedLength > 0 else {
            throw URLError(.badServerResponse)
        }
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: tempURL)
        
        var totalReceived = 0
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 8192)
        defer { buffer.deallocate() }
        
        for try await _ in asyncBytes {
            let chunk = Data(bytes: buffer, count: min(8192, expectedLength - totalReceived))
            fileHandle.write(chunk)
            totalReceived += chunk.count
            progress(Double(totalReceived) / Double(expectedLength))
            
            if totalReceived >= expectedLength { break }
        }
        
        try fileHandle.close()
        return (tempURL, response)
    }
}
