import Foundation

@available(macOS 14.0, *)
class Qwen3ASREngine: TranscriptionEngine {
    let type: EngineType
    var status: EngineStatus = EngineStatus()
    
    private let modelId: String
    private let cacheDirectory: URL
    
    // Persistent Python subprocess
    private var pythonProcess: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer: Data = Data()
    private let bufferLock = NSLock()
    private let dataAvailable = DispatchSemaphore(value: 0)
    
    // Python interpreter and script paths
    private let pythonPath = "/opt/homebrew/bin/python3.11"
    
    init(type: EngineType) {
        guard type.modelId != nil else {
            fatalError("Qwen3ASREngine requires an engine type with a modelId (Qwen engines only)")
        }
        self.type = type
        self.modelId = type.modelId ?? "mlx-community/Qwen3-ASR-0.6B-4bit"
        self.cacheDirectory = Self.getCacheDirectory()
    }
    
    func load(progress: @escaping (Double) -> Void) async throws {
        status.isLoading = true
        status.errorMessage = nil
        progress(0.0)
        
        // Verify model weights exist
        let modelDir = cacheDirectory.appendingPathComponent(modelId.replacingOccurrences(of: "/", with: "--"))
        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            status.isLoading = false
            throw TranscriptionError.modelLoadFailed("Model weights not found at \(modelDir.path). Please download them in Settings.")
        }
        
        // Verify Python interpreter exists
        guard FileManager.default.fileExists(atPath: pythonPath) else {
            status.isLoading = false
            throw TranscriptionError.modelLoadFailed("Python 3.11 not found at \(pythonPath). Install with: brew install python@3.11")
        }
        
        // Find the transcribe.py script
        let scriptPath = Self.findTranscribeScript()
        guard let scriptPath = scriptPath else {
            status.isLoading = false
            throw TranscriptionError.modelLoadFailed("transcribe.py not found. Expected in app bundle Resources/scripts/ or project scripts/ directory.")
        }
        
        logDebug("[Qwen3ASREngine] Using Python: \(pythonPath)")
        logDebug("[Qwen3ASREngine] Using script: \(scriptPath)")
        logDebug("[Qwen3ASREngine] Using model: \(modelDir.path)")
        
        progress(0.1)
        
        // Start the persistent Python process
        do {
            try startPythonProcess(scriptPath: scriptPath, modelDir: modelDir.path)
        } catch {
            status.isLoading = false
            status.errorMessage = error.localizedDescription
            throw error
        }
        
        progress(0.3)
        
        // Wait for the "ready" signal from the Python process
        logDebug("[Qwen3ASREngine] Waiting for Python model to load...")
        do {
            let readyResponse = try await waitForResponseAsync(timeout: 120) // Model loading can take a while
            if let statusVal = readyResponse["status"] as? String, statusVal == "ready" {
                logDebug("[Qwen3ASREngine] Python process ready!")
            } else if let error = readyResponse["error"] as? String {
                throw TranscriptionError.modelLoadFailed("Python process error: \(error)")
            } else {
                throw TranscriptionError.modelLoadFailed("Unexpected response from Python process: \(readyResponse)")
            }
        } catch {
            stopPythonProcess()
            status.isLoading = false
            status.errorMessage = error.localizedDescription
            throw error
        }
        
        progress(1.0)
        status.isLoaded = true
        status.isLoading = false
    }
    
    func transcribe(audioURL: URL, language: String) async throws -> String {
        guard status.isLoaded, pythonProcess != nil else {
            throw TranscriptionError.modelNotLoaded
        }
        
        // Verify the process is still running
        guard let process = pythonProcess, process.isRunning else {
            status.isLoaded = false
            throw TranscriptionError.transcriptionFailed("Python process has exited unexpectedly. Please reload the engine.")
        }
        
        let qwenLanguage = mapLanguageToQwen(language)
        
        // Send transcription request
        let request: [String: Any] = [
            "wav": audioURL.path,
            "language": qwenLanguage
        ]
        
        do {
            let requestData = try JSONSerialization.data(withJSONObject: request)
            guard var requestString = String(data: requestData, encoding: .utf8) else {
                throw TranscriptionError.transcriptionFailed("Failed to encode request as JSON")
            }
            requestString += "\n"
            
            logDebug("[Qwen3ASREngine] Sending request: \(requestString.trimmingCharacters(in: .newlines))")
            
            guard let stdinPipe = stdinPipe else {
                throw TranscriptionError.transcriptionFailed("stdin pipe not available")
            }
            
            stdinPipe.fileHandleForWriting.write(requestString.data(using: .utf8)!)
            
            // Wait for response (async-safe — runs semaphore wait off the cooperative pool)
            let response = try await waitForResponseAsync(timeout: 60)
            
            if let text = response["text"] as? String {
                logDebug("[Qwen3ASREngine] Transcription result: \(text)")
                return text
            } else if let error = response["error"] as? String {
                throw TranscriptionError.transcriptionFailed("Python error: \(error)")
            } else {
                throw TranscriptionError.transcriptionFailed("Unexpected response: \(response)")
            }
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.transcriptionFailed(error.localizedDescription)
        }
    }
    
    func unload() {
        stopPythonProcess()
        status.isLoaded = false
    }
    
    // MARK: - Python Process Management
    
    private func startPythonProcess(scriptPath: String, modelDir: String) throws {
        // Stop any existing process
        stopPythonProcess()
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [
            scriptPath,
            "--model-dir", modelDir,
            "--warmup"
        ]
        
        // Set up environment
        var env = ProcessInfo.processInfo.environment
        // Ensure Python can find its packages
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env
        
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        
        // Read stderr asynchronously for logging
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let line = String(data: data, encoding: .utf8) {
                logDebug("[Python] \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        
        // Read stdout asynchronously into a buffer, signal when data arrives
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                self?.bufferLock.lock()
                self?.stdoutBuffer.append(data)
                self?.bufferLock.unlock()
                self?.dataAvailable.signal()
            }
        }
        
        self.pythonProcess = process
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        self.stdoutBuffer = Data()
        
        do {
            try process.run()
            logDebug("[Qwen3ASREngine] Python process started (PID: \(process.processIdentifier))")
        } catch {
            self.pythonProcess = nil
            self.stdinPipe = nil
            self.stdoutPipe = nil
            self.stderrPipe = nil
            throw TranscriptionError.modelLoadFailed("Failed to start Python process: \(error.localizedDescription)")
        }
    }
    
    private func stopPythonProcess() {
        if let process = pythonProcess, process.isRunning {
            // Try graceful quit first
            let quitRequest = "{\"cmd\":\"quit\"}\n"
            stdinPipe?.fileHandleForWriting.write(quitRequest.data(using: .utf8)!)
            
            // Give it a moment to exit gracefully
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak process] in
                if let p = process, p.isRunning {
                    p.terminate()
                }
            }
        }
        
        // Clean up handlers to avoid retain cycles
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        
        pythonProcess = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        stdoutBuffer = Data()
    }
    
    /// Wait for a complete JSON line from stdout, with timeout.
    /// Uses a semaphore to wake immediately when data arrives instead of polling.
    /// NOTE: This is a blocking method — only call from a non-cooperative thread (see waitForResponseAsync).
    private func waitForResponse(timeout: TimeInterval) throws -> [String: Any] {
        let deadline = DispatchTime.now() + timeout
        
        while true {
            // Check if process has died
            if let process = pythonProcess, !process.isRunning {
                throw TranscriptionError.transcriptionFailed(
                    "Python process exited with code \(process.terminationStatus)")
            }
            
            // Try to extract a complete JSON line from the buffer
            bufferLock.lock()
            if let newlineRange = stdoutBuffer.range(of: Data("\n".utf8)) {
                let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<newlineRange.lowerBound)
                stdoutBuffer.removeSubrange(stdoutBuffer.startIndex..<newlineRange.upperBound)
                bufferLock.unlock()
                
                guard let lineString = String(data: lineData, encoding: .utf8) else {
                    throw TranscriptionError.transcriptionFailed("Failed to decode response as UTF-8")
                }
                
                let trimmed = lineString.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                
                guard let jsonData = trimmed.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                    logDebug("[Qwen3ASREngine] Non-JSON output from Python: \(trimmed)")
                    continue
                }
                
                return json
            } else {
                bufferLock.unlock()
            }
            
            // Wait for data with timeout — wakes immediately when readabilityHandler signals
            let result = dataAvailable.wait(timeout: deadline)
            if result == .timedOut {
                throw TranscriptionError.transcriptionFailed("Timeout waiting for Python response after \(Int(timeout))s")
            }
        }
    }
    
    /// Async-safe wrapper around waitForResponse.
    /// Runs the blocking semaphore wait on a dedicated GCD thread (outside Swift Concurrency's
    /// cooperative thread pool) to prevent thread starvation and potential deadlocks.
    private func waitForResponseAsync(timeout: TimeInterval) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.waitForResponse(timeout: timeout)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Helpers
    
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
    
    /// Find the transcribe.py script in several locations.
    private static func findTranscribeScript() -> String? {
        // 1. Check app bundle Resources/scripts/
        if let bundlePath = Bundle.main.resourcePath {
            let bundleScript = (bundlePath as NSString).appendingPathComponent("scripts/transcribe.py")
            if FileManager.default.fileExists(atPath: bundleScript) {
                return bundleScript
            }
        }
        
        // 2. Check next to the executable (in Contents/MacOS/../scripts/)
        if let execPath = Bundle.main.executablePath {
            let contentsDir = (execPath as NSString).deletingLastPathComponent  // MacOS/
            let appContentsDir = (contentsDir as NSString).deletingLastPathComponent  // Contents/
            let scriptsDir = (appContentsDir as NSString).appendingPathComponent("Resources/scripts/transcribe.py")
            if FileManager.default.fileExists(atPath: scriptsDir) {
                return scriptsDir
            }
        }
        
        // 3. Check relative to the process (for development: project/scripts/)
        let devPath = (ProcessInfo.processInfo.environment["PROJECT_DIR"] ?? "").isEmpty
            ? "" : ProcessInfo.processInfo.environment["PROJECT_DIR"]!
        if !devPath.isEmpty {
            let devScript = (devPath as NSString).appendingPathComponent("scripts/transcribe.py")
            if FileManager.default.fileExists(atPath: devScript) {
                return devScript
            }
        }
        
        // 4. Walk up from executable to find scripts/transcribe.py (development builds)
        if let execPath = Bundle.main.executablePath {
            var dir = (execPath as NSString).deletingLastPathComponent
            for _ in 0..<10 {  // Walk up at most 10 levels
                let candidate = (dir as NSString).appendingPathComponent("scripts/transcribe.py")
                if FileManager.default.fileExists(atPath: candidate) {
                    return candidate
                }
                let parent = (dir as NSString).deletingLastPathComponent
                if parent == dir { break }
                dir = parent
            }
        }
        
        return nil
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
