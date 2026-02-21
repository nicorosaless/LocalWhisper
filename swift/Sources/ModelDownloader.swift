import Foundation

// MARK: - Model Downloader
class ModelDownloader {
    static let shared = ModelDownloader()
    
    private var downloadTask: URLSessionDownloadTask?
    
    private init() {}
    
    func getModelsDirectory() -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("Could not find Application Support directory")
        }
        let modelsDir = appSupport.appendingPathComponent("LocalWhisper/models")
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        
        return modelsDir
    }
    
    func getModelPath(for model: WhisperModel = .small) -> String {
        return getModelsDirectory().appendingPathComponent(model.rawValue).path
    }
    
    func isModelDownloaded(_ model: WhisperModel = .small) -> Bool {
        return FileManager.default.fileExists(atPath: getModelPath(for: model))
    }
    
    func downloadModel(_ model: WhisperModel, progress: @escaping (Double) -> Void, completion: @escaping (Bool) -> Void) {
        // Check if already downloaded
        if isModelDownloaded(model) {
            completion(true)
            return
        }
        
        guard let url = URL(string: model.downloadURL) else {
            completion(false)
            return
        }
        
        let session = URLSession(configuration: .default, delegate: DownloadDelegate(progressHandler: progress, completionHandler: { [weak self] location in
            guard let self = self, let location = location else {
                completion(false)
                return
            }
            
            do {
                let destination = URL(fileURLWithPath: self.getModelPath(for: model))
                
                // Remove existing file if any
                try? FileManager.default.removeItem(at: destination)
                
                // Move downloaded file
                try FileManager.default.moveItem(at: location, to: destination)
                
                #if DEBUG
                print("Model \(model.name) downloaded to: \(destination.path)")
                #endif
                completion(true)
            } catch {
                #if DEBUG
                print("Error moving model: \(error)")
                #endif
                completion(false)
            }
        }), delegateQueue: nil)
        
        downloadTask = session.downloadTask(with: url)
        downloadTask?.resume()
    }
    
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
    }
}

// MARK: - Download Delegate
private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let progressHandler: (Double) -> Void
    let completionHandler: (URL?) -> Void
    
    init(progressHandler: @escaping (Double) -> Void, completionHandler: @escaping (URL?) -> Void) {
        self.progressHandler = progressHandler
        self.completionHandler = completionHandler
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        completionHandler(location)
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async {
            self.progressHandler(progress)
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil {
            completionHandler(nil)
        }
    }
}
