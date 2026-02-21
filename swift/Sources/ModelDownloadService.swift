import Foundation

// MARK: - Shared download service used by both SettingsView and OnboardingView

/// Manages downloading Qwen3-ASR model weights from HuggingFace.
/// Uses URLSessionDownloadTask (not the async API) so the delegate progress
/// callbacks fire correctly — the async URLSession.download(from:) API ignores
/// delegate progress methods when called on a session that has a delegate.
@MainActor
final class ModelDownloadService: ObservableObject {
    static let shared = ModelDownloadService()

    @Published var states: [EngineType: QwenDownloadState] = [:]

    private var activeTasks: [EngineType: ActiveDownload] = [:]

    private init() {
        refreshStates()
    }

    func refreshStates() {
        for engine in EngineType.allCases {
            if case .downloading = states[engine] { continue }
            states[engine] = engine.isDownloaded() ? .downloaded : .notDownloaded
        }
    }

    func startDownload(for engine: EngineType) {
        guard let modelId = engine.modelId else { return }
        if case .downloading = states[engine] { return }
        if states[engine] == .downloaded { return }

        states[engine] = .downloading(progress: 0)

        let download = ActiveDownload(engine: engine, modelId: modelId, service: self)
        activeTasks[engine] = download
        download.start()
    }

    func cancelDownload(for engine: EngineType) {
        activeTasks[engine]?.cancel()
        activeTasks[engine] = nil
        states[engine] = .notDownloaded
        
        if engine == .whisperCpp {
            let path = ModelDownloader.shared.getModelPath()
            try? FileManager.default.removeItem(atPath: path)
        } else if let modelId = engine.modelId {
            let dir = EngineType.qwenCacheDirectory()
                .appendingPathComponent(modelId.replacingOccurrences(of: "/", with: "--"))
            try? FileManager.default.removeItem(at: dir)
        }
    }

    fileprivate func reportProgress(_ progress: Double, for engine: EngineType) {
        states[engine] = .downloading(progress: progress)
    }

    fileprivate func reportCompleted(for engine: EngineType) {
        activeTasks[engine] = nil
        states[engine] = .downloaded
    }

    fileprivate func reportFailed(_ message: String, for engine: EngineType) {
        activeTasks[engine] = nil
        states[engine] = .failed(message)
    }
}

// MARK: - Per-engine download coordinator

private final class ActiveDownload: NSObject, URLSessionDownloadDelegate {
    let engine: EngineType
    let modelId: String
    weak var service: ModelDownloadService?

    private var session: URLSession?
    private var currentTask: URLSessionDownloadTask?
    private var cancelled = false

    // Files to download and their target destinations
    private let configFiles = [
        "config.json",
        "tokenizer_config.json",
        "generation_config.json",
        "preprocessor_config.json",
        "vocab.json",
        "merges.txt",
        "special_tokens_map.json",
    ]
    private let weightFile = "model.safetensors"

    // Track multi-file config download progress (10% of total)
    private var configFilesDownloaded = 0
    private var directory: URL = FileManager.default.temporaryDirectory

    init(engine: EngineType, modelId: String, service: ModelDownloadService) {
        self.engine = engine
        self.modelId = modelId
        self.service = service
    }

    func start() {
        let dir = EngineType.qwenCacheDirectory()
            .appendingPathComponent(modelId.replacingOccurrences(of: "/", with: "--"))
        self.directory = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Download config files sequentially using simple async dispatch, then the weight file.
        Task { [weak self] in
            await self?.downloadConfigFiles()
        }
    }

    func cancel() {
        cancelled = true
        currentTask?.cancel()
        currentTask = nil
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: - Config files (small — use URLSession.shared async API, no progress needed)

    private func downloadConfigFiles() async {
        if engine == .whisperCpp {
            await downloadWeightFile()
            return
        }
        
        let base = "https://huggingface.co/\(modelId)/resolve/main"
        for (index, file) in configFiles.enumerated() {
            guard !cancelled else { return }
            guard let url = URL(string: "\(base)/\(file)") else { continue }
            do {
                let (tmpURL, _) = try await URLSession.shared.download(from: url)
                let dest = directory.appendingPathComponent(file)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmpURL, to: dest)
            } catch {
                print("[ModelDownloadService] Optional file \(file) not available: \(error.localizedDescription)")
            }
            let frac = Double(index + 1) / Double(configFiles.count) * 0.10
            await reportProgress(frac)
        }
        guard !cancelled else { return }
        await downloadWeightFile()
    }

    @MainActor
    private func reportProgress(_ p: Double) {
        service?.reportProgress(p, for: engine)
    }

    // MARK: - Weight file (large — URLSessionDownloadTask with delegate for real progress)

    private func downloadWeightFile() async {
        let urlString: String
        let destinationURL: URL
        
        if engine == .whisperCpp {
            urlString = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"
            destinationURL = URL(fileURLWithPath: ModelDownloader.shared.getModelPath())
        } else {
            urlString = "https://huggingface.co/\(modelId)/resolve/main/\(weightFile)"
            destinationURL = directory.appendingPathComponent(weightFile)
        }
        
        self.targetWeightURL = destinationURL
        
        guard let url = URL(string: urlString) else {
            await MainActor.run { service?.reportFailed("Invalid weight file URL", for: engine) }
            return
        }

        try? FileManager.default.removeItem(at: destinationURL)

        let config = URLSessionConfiguration.default
        // Allow large downloads — no timeout on transfer
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 86400  // 24 hours

        let sess = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = sess

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.weightContinuation = continuation
            let task = sess.downloadTask(with: url)
            self.currentTask = task
            task.resume()
        }
    }

    private var weightContinuation: CheckedContinuation<Void, Never>?
    private var weightDownloadError: Error?
    private var weightLocalURL: URL?

    private var targetWeightURL: URL?

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData _: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let weightFrac = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let overall = engine == .whisperCpp ? weightFrac : (0.10 + weightFrac * 0.90)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.service?.reportProgress(overall, for: self.engine)
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let dest = targetWeightURL else { return }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            weightLocalURL = dest
        } catch {
            weightDownloadError = error
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        let err = error ?? weightDownloadError
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let err {
                if (err as NSError).code == NSURLErrorCancelled {
                    // Already handled by cancel()
                } else {
                    self.service?.reportFailed(err.localizedDescription, for: self.engine)
                }
            } else {
                self.service?.reportCompleted(for: self.engine)
            }
            self.weightContinuation?.resume()
            self.weightContinuation = nil
        }
    }
}
