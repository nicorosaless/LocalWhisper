import Foundation
import Darwin

actor SingleFlightGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
            return
        }
        let waiter = waiters.removeFirst()
        waiter.resume()
    }

    func withPermit<T>(_ operation: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }
}

@available(macOS 14.0, *)
class Qwen3ASREngine: TranscriptionEngine {
    let type: EngineType
    var status: EngineStatus = EngineStatus()
    
    private let modelId: String
    private let cacheDirectory: URL
    private let singleFlight = SingleFlightGate()
    private let enableLowRAMAutoUnload: Bool
    private let idleUnloadSeconds: TimeInterval
    private var idleUnloadWorkItem: DispatchWorkItem?
    
    // Persistent Python subprocess
    private var pythonProcess: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer: Data = Data()
    private let bufferLock = NSLock()
    private let dataAvailable = DispatchSemaphore(value: 0)
    
    // Python interpreter and script paths
    private let pythonPath: String
    
    init(type: EngineType) {
        guard type.modelId != nil else {
            fatalError("Qwen3ASREngine requires an engine type with a modelId (Qwen engines only)")
        }
        self.type = type
        self.modelId = type.modelId ?? "mlx-community/Qwen3-ASR-0.6B-4bit"
        self.cacheDirectory = Self.getCacheDirectory()
        self.pythonPath = Self.resolvePythonPath()
        self.enableLowRAMAutoUnload = Self.resolveLowRAMModeEnabled()
        self.idleUnloadSeconds = Self.resolveIdleUnloadSeconds()
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
        
        // Find the transcribe.py script
        let scriptPath = Self.findTranscribeScript()
        guard let scriptPath = scriptPath else {
            status.isLoading = false
            throw TranscriptionError.modelLoadFailed("transcribe.py not found. Expected in app bundle Resources/scripts/ or project scripts/ directory.")
        }

        let rustDaemonPath = Self.findRustDaemon()
        let useRustBackend = Self.shouldUseRustBackend(hasRustDaemon: rustDaemonPath != nil)

        if useRustBackend {
            guard rustDaemonPath != nil else {
                status.isLoading = false
                throw TranscriptionError.modelLoadFailed("Rust backend requested but qwen-daemon was not found. Build it with: cargo build --release --manifest-path rust/qwen-daemon/Cargo.toml")
            }
        }

        // Verify Python interpreter exists (still required for fallback and rust proxy mode)
        guard FileManager.default.fileExists(atPath: pythonPath) else {
            status.isLoading = false
            throw TranscriptionError.modelLoadFailed("Python 3.11 not found at \(pythonPath). Install with: brew install python@3.11")
        }
        
        if useRustBackend, let rustDaemonPath {
            logDebug("[Qwen3ASREngine] Using Rust daemon: \(rustDaemonPath)")
        } else {
            logDebug("[Qwen3ASREngine] Using Python: \(pythonPath)")
        }
        logDebug("[Qwen3ASREngine] Using script: \(scriptPath)")
        logDebug("[Qwen3ASREngine] Using model: \(modelDir.path)")
        
        progress(0.1)
        
        // Start the persistent Python process
        do {
            if useRustBackend, let rustDaemonPath {
                try startRustProcess(
                    daemonPath: rustDaemonPath,
                    scriptPath: scriptPath,
                    modelDir: modelDir.path
                )
            } else {
                try startPythonProcess(scriptPath: scriptPath, modelDir: modelDir.path)
            }
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
        scheduleIdleUnloadIfNeeded()
    }
    
    func transcribe(audioURL: URL, language: String) async throws -> String {
        cancelIdleUnload()
        return try await singleFlight.withPermit {
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

                let timeout = Self.computeTimeoutSeconds(for: audioURL)
                // Wait for response (async-safe — runs semaphore wait off the cooperative pool)
                let response = try await waitForResponseAsync(timeout: timeout)

                if let text = response["text"] as? String {
                    logDebug("[Qwen3ASREngine] Transcription result: \(text)")
                    scheduleIdleUnloadIfNeeded()
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
    }
    
    func unload() {
        cancelIdleUnload()
        stopPythonProcess()
        status.isLoaded = false
    }
    
    /// Public property to let callers check if the Python subprocess is still alive.
    var isPythonProcessRunning: Bool {
        return pythonProcess?.isRunning ?? false
    }
    
    // MARK: - Python Process Management
    
    private func startPythonProcess(scriptPath: String, modelDir: String) throws {
        // Stop any existing process
        stopPythonProcess()
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [
            scriptPath,
            "--model-dir", modelDir
            // Warmup disabled - causes crash with certain model versions
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

    private func startRustProcess(daemonPath: String, scriptPath: String, modelDir: String) throws {
        stopPythonProcess()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: daemonPath)
        process.arguments = [
            "--python", pythonPath,
            "--script", scriptPath,
            "--model-dir", modelDir
        ]

        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let line = String(data: data, encoding: .utf8) {
                logDebug("[RustDaemon] \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

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
            logDebug("[Qwen3ASREngine] Rust daemon started (PID: \(process.processIdentifier))")
        } catch {
            self.pythonProcess = nil
            self.stdinPipe = nil
            self.stdoutPipe = nil
            self.stderrPipe = nil
            throw TranscriptionError.modelLoadFailed("Failed to start Rust daemon: \(error.localizedDescription)")
        }
    }
    
    private func stopPythonProcess() {
        guard let process = pythonProcess else {
            stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            stderrPipe?.fileHandleForReading.readabilityHandler = nil
            pythonProcess = nil
            stdinPipe = nil
            stdoutPipe = nil
            stderrPipe = nil
            stdoutBuffer = Data()
            return
        }

        if process.isRunning {
            let pid = process.processIdentifier

            // Try graceful shutdown first.
            let quitRequest = "{\"cmd\":\"quit\"}\n"
            if let data = quitRequest.data(using: .utf8) {
                stdinPipe?.fileHandleForWriting.write(data)
            }
            try? stdinPipe?.fileHandleForWriting.close()

            // Wait briefly for graceful exit.
            let gracefulDeadline = Date().addingTimeInterval(1.2)
            while process.isRunning && Date() < gracefulDeadline {
                usleep(50_000)
            }

            // Escalate if still alive.
            if process.isRunning {
                process.terminate()
                let terminateDeadline = Date().addingTimeInterval(0.8)
                while process.isRunning && Date() < terminateDeadline {
                    usleep(50_000)
                }
            }

            // Kill stubborn parent and any children (python behind qwen-daemon).
            if process.isRunning {
                _ = kill(pid, SIGKILL)
            }
            killChildProcesses(of: pid, signal: "-TERM")
            killChildProcesses(of: pid, signal: "-KILL")
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

    private func killChildProcesses(of pid: Int32, signal: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = [signal, "-P", String(pid)]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
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

    private static func shouldUseRustBackend(hasRustDaemon: Bool) -> Bool {
        let raw = ProcessInfo.processInfo.environment["LOCALWHISPER_QWEN_BACKEND"]?.lowercased()
        if raw == "python" {
            return false
        }
        if raw == "rust" {
            return true
        }
        return hasRustDaemon
    }

    private static func resolveLowRAMModeEnabled() -> Bool {
        let raw = ProcessInfo.processInfo.environment["LOCALWHISPER_LOW_RAM"]?.lowercased()
        if let raw {
            if raw == "0" || raw == "false" || raw == "no" {
                return false
            }
            return raw == "1" || raw == "true" || raw == "yes"
        }
        // Default ON: keep RAM low when idle unless explicitly disabled.
        return true
    }

    private static func resolveIdleUnloadSeconds() -> TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["LOCALWHISPER_IDLE_UNLOAD_SECONDS"],
           let seconds = Double(raw),
           seconds >= 15 {
            return seconds
        }
        // Aggressive default to reduce idle footprint while preserving short-session speed.
        return 25
    }

    private func scheduleIdleUnloadIfNeeded() {
        guard enableLowRAMAutoUnload else { return }
        cancelIdleUnload()
        logDebug("[Qwen3ASREngine] low_ram: scheduling unload in \(Int(idleUnloadSeconds))s")
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.status.isLoaded {
                logDebug("[Qwen3ASREngine] low_ram: unloading after \(Int(self.idleUnloadSeconds))s idle")
                self.unload()
            }
        }
        idleUnloadWorkItem = workItem
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + idleUnloadSeconds, execute: workItem)
    }

    private func cancelIdleUnload() {
        if idleUnloadWorkItem != nil {
            logDebug("[Qwen3ASREngine] low_ram: cancel unload timer")
        }
        idleUnloadWorkItem?.cancel()
        idleUnloadWorkItem = nil
    }

    private static func resolvePythonPath() -> String {
        if let override = ProcessInfo.processInfo.environment["LOCALWHISPER_PYTHON_PATH"],
           FileManager.default.fileExists(atPath: override) {
            return override
        }

        let candidates = [
            "/opt/homebrew/bin/python3.11",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3.11",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }

        return "/usr/bin/python3"
    }

    private static func findRustDaemon() -> String? {
        let fm = FileManager.default

        if let bundlePath = Bundle.main.resourcePath {
            let bundled = (bundlePath as NSString).appendingPathComponent("bin/qwen-daemon")
            if fm.fileExists(atPath: bundled) {
                return bundled
            }
        }

        if let execPath = Bundle.main.executablePath {
            var dir = (execPath as NSString).deletingLastPathComponent
            for _ in 0..<10 {
                let candidate = (dir as NSString).appendingPathComponent("rust/qwen-daemon/target/release/qwen-daemon")
                if fm.fileExists(atPath: candidate) {
                    return candidate
                }
                let candidateBin = (dir as NSString).appendingPathComponent("bin/qwen-daemon")
                if fm.fileExists(atPath: candidateBin) {
                    return candidateBin
                }
                let parent = (dir as NSString).deletingLastPathComponent
                if parent == dir { break }
                dir = parent
            }
        }

        return nil
    }

    private static func computeTimeoutSeconds(for wavURL: URL) -> TimeInterval {
        let duration = wavDurationSeconds(wavURL) ?? 30.0
        let timeout = 25.0 + (1.5 * duration)
        return min(180.0, max(45.0, timeout))
    }

    private static func wavDurationSeconds(_ wavURL: URL) -> TimeInterval? {
        guard let wavData = try? Data(contentsOf: wavURL, options: .mappedIfSafe) else {
            return nil
        }
        let header = wavData.prefix(44)
        guard header.count >= 44 else { return nil }

        let byteRate = readLEUInt32(Data(header), at: 28)
        let dataSize = readLEUInt32(Data(header), at: 40)

        guard byteRate > 0 else { return nil }
        return TimeInterval(Double(dataSize) / Double(byteRate))
    }

    private static func readLEUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard data.count >= offset + 4 else { return 0 }
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1]) << 8
        let b2 = UInt32(data[offset + 2]) << 16
        let b3 = UInt32(data[offset + 3]) << 24
        return b0 | b1 | b2 | b3
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
