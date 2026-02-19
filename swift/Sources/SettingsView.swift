import SwiftUI
import Carbon.HIToolbox

// MARK: - Paste Method
enum PasteMethod: String, CaseIterable, Codable {
    case auto        // Try all strategies
    case cgEvent     // CGEvent only
    case appleScript // AppleScript only
    case accessibility // AX API only
    case typing      // Character simulation
    
    var displayName: String {
        switch self {
        case .auto: return "Auto (Recommended)"
        case .cgEvent: return "System Events"
        case .appleScript: return "AppleScript"
        case .accessibility: return "Accessibility API"
        case .typing: return "Type Simulation"
        }
    }
}

// MARK: - Hotkey Mode
enum HotkeyMode: String, CaseIterable, Codable {
    case pushToTalk = "push_to_talk"
    case toggle = "toggle"
    
    var displayName: String {
        switch self {
        case .pushToTalk: return "Push to Talk (hold)"
        case .toggle: return "Toggle (press)"
        }
    }
}

// MARK: - Hotkey Configuration
struct HotkeyConfig: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: [String]
    var keyCharacter: String?
    
    static let defaultConfig = HotkeyConfig(keyCode: 49, modifiers: ["cmd", "shift"], keyCharacter: "Space")
    
    var displayString: String {
        var parts: [String] = []
        if modifiers.contains("cmd") { parts.append("⌘") }
        if modifiers.contains("ctrl") { parts.append("⌃") }
        if modifiers.contains("alt") { parts.append("⌥") }
        if modifiers.contains("shift") { parts.append("⇧") }
        
        if let char = keyCharacter, !char.isEmpty {
            parts.append(char)
        } else {
            parts.append(keyCodeToString(keyCode))
        }
        return parts.joined()
    }
    
    private func keyCodeToString(_ keyCode: UInt16) -> String {
        switch keyCode {
        case 49: return "Space"
        case 36: return "↵"
        case 48: return "⇥"
        case 51: return "⌫"
        case 53: return "⎋"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return "Key\(keyCode)"
        }
    }
}

// MARK: - App Configuration
struct AppConfig: Codable {
    var language: String
    var hotkey: HotkeyConfig
    var hotkeyMode: HotkeyMode
    var autoPaste: Bool
    var modelPath: String
    var pasteDelay: Int
    var preferredPasteMethod: PasteMethod
    var launchAtLogin: Bool
    var engineType: EngineType
    
    enum CodingKeys: String, CodingKey {
        case language
        case hotkey
        case hotkeyMode = "hotkey_mode"
        case autoPaste = "auto_paste"
        case modelPath = "model_path"
        case pasteDelay = "paste_delay"
        case preferredPasteMethod = "preferred_paste_method"
        case launchAtLogin = "launch_at_login"
        case engineType = "engine_type"
    }
    
    init(
        language: String = "es",
        hotkey: HotkeyConfig = HotkeyConfig(keyCode: 7, modifiers: ["cmd", "shift"], keyCharacter: "X"),
        hotkeyMode: HotkeyMode = .toggle,
        autoPaste: Bool = true,
        modelPath: String = "models/ggml-small.bin",
        pasteDelay: Int = 80,
        preferredPasteMethod: PasteMethod = .auto,
        launchAtLogin: Bool = false,
        engineType: EngineType = .whisperCpp
    ) {
        self.language = language
        self.hotkey = hotkey
        self.hotkeyMode = hotkeyMode
        self.autoPaste = autoPaste
        self.modelPath = modelPath
        self.pasteDelay = pasteDelay
        self.preferredPasteMethod = preferredPasteMethod
        self.launchAtLogin = launchAtLogin
        self.engineType = engineType
    }
    
    static let defaultConfig = AppConfig()
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        language = try container.decode(String.self, forKey: .language)
        hotkey = try container.decode(HotkeyConfig.self, forKey: .hotkey)
        hotkeyMode = try container.decode(HotkeyMode.self, forKey: .hotkeyMode)
        autoPaste = try container.decode(Bool.self, forKey: .autoPaste)
        modelPath = try container.decode(String.self, forKey: .modelPath)
        pasteDelay = try container.decode(Int.self, forKey: .pasteDelay)
        preferredPasteMethod = try container.decode(PasteMethod.self, forKey: .preferredPasteMethod)
        launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin)
        engineType = try container.decodeIfPresent(EngineType.self, forKey: .engineType) ?? .whisperCpp
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(language, forKey: .language)
        try container.encode(hotkey, forKey: .hotkey)
        try container.encode(hotkeyMode, forKey: .hotkeyMode)
        try container.encode(autoPaste, forKey: .autoPaste)
        try container.encode(modelPath, forKey: .modelPath)
        try container.encode(pasteDelay, forKey: .pasteDelay)
        try container.encode(preferredPasteMethod, forKey: .preferredPasteMethod)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(engineType, forKey: .engineType)
    }
}

// MARK: - Languages
struct Language: Identifiable, Hashable {
    let id: String
    let name: String
    
    static let all: [Language] = [
        Language(id: "auto", name: "Auto-detect"),
        Language(id: "es", name: "Spanish"),
        Language(id: "en", name: "English"),
        Language(id: "fr", name: "French"),
        Language(id: "de", name: "German"),
        Language(id: "it", name: "Italian"),
        Language(id: "pt", name: "Portuguese"),
        Language(id: "zh", name: "Chinese"),
        Language(id: "ja", name: "Japanese"),
        Language(id: "ko", name: "Korean"),
        Language(id: "ru", name: "Russian"),
        Language(id: "ar", name: "Arabic"),
    ]
}

// MARK: - Hotkey Recorder View
struct HotkeyRecorderView: NSViewRepresentable {
    @Binding var hotkey: HotkeyConfig
    @Binding var isRecording: Bool
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.coordinator = context.coordinator
        return view
    }
    
    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        nsView.isRecordingHotkey = isRecording
        nsView.currentHotkey = hotkey
        nsView.needsDisplay = true
    }
    
    class Coordinator {
        var parent: HotkeyRecorderView
        
        init(_ parent: HotkeyRecorderView) {
            self.parent = parent
        }
        
        func hotkeyRecorded(keyCode: UInt16, modifiers: [String], keyCharacter: String?) {
            DispatchQueue.main.async {
                self.parent.hotkey = HotkeyConfig(keyCode: keyCode, modifiers: modifiers, keyCharacter: keyCharacter)
                self.parent.isRecording = false
            }
        }
        
        func startRecording() {
            DispatchQueue.main.async {
                self.parent.isRecording = true
            }
        }
        
        func cancelRecording() {
            DispatchQueue.main.async {
                self.parent.isRecording = false
            }
        }
    }
}

class HotkeyRecorderNSView: NSView {
    var isRecordingHotkey = false {
        didSet {
            if isRecordingHotkey {
                startMonitoring()
            } else {
                stopMonitoring()
            }
            updateAppearance()
        }
    }
    
    var currentHotkey: HotkeyConfig = .defaultConfig {
        didSet {
            updateAppearance()
        }
    }
    
    weak var coordinator: HotkeyRecorderView.Coordinator?
    
    private var localMonitor: Any?
    private var clickMonitor: Any?
    private var globalClickMonitor: Any?
    
    private let label: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    
    override var acceptsFirstResponder: Bool { true }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        stopMonitoring()
    }
    
    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 6
        
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
        ])
        
        updateAppearance()
    }
    
    private func updateAppearance() {
        if isRecordingHotkey {
            label.stringValue = "Press a key..."
            label.textColor = .white.withAlphaComponent(0.5)
        } else {
            label.stringValue = currentHotkey.displayString
            label.textColor = .white
        }
        needsDisplay = true
    }
    
    private func startMonitoring() {
        stopMonitoring()
        
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self, self.isRecordingHotkey else { return event }
            
            var modifiers: [String] = []
            if event.modifierFlags.contains(.command) { modifiers.append("cmd") }
            if event.modifierFlags.contains(.control) { modifiers.append("ctrl") }
            if event.modifierFlags.contains(.option) { modifiers.append("alt") }
            if event.modifierFlags.contains(.shift) { modifiers.append("shift") }
            
            if event.keyCode == 53 {
                self.coordinator?.cancelRecording()
                return nil
            }
            
            var keyChar: String? = nil
            switch event.keyCode {
            case 49: keyChar = "Space"
            case 36: keyChar = "↵"
            case 48: keyChar = "⇥"
            case 51: keyChar = "⌫"
            case 122: keyChar = "F1"
            case 120: keyChar = "F2"
            case 99: keyChar = "F3"
            case 118: keyChar = "F4"
            case 96: keyChar = "F5"
            case 97: keyChar = "F6"
            case 98: keyChar = "F7"
            case 100: keyChar = "F8"
            case 101: keyChar = "F9"
            case 109: keyChar = "F10"
            case 103: keyChar = "F11"
            case 111: keyChar = "F12"
            case 123: keyChar = "←"
            case 124: keyChar = "→"
            case 125: keyChar = "↓"
            case 126: keyChar = "↑"
            default:
                if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
                    keyChar = chars.uppercased()
                }
            }
            
            self.coordinator?.hotkeyRecorded(keyCode: event.keyCode, modifiers: modifiers, keyCharacter: keyChar)
            return nil
        }
        
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, self.isRecordingHotkey else { return event }
            
            // let ourBundleID = Bundle.main.bundleIdentifier ?? "com.nicorosaless.LocalWhisper"
            let pointInView = self.convert(event.locationInWindow, from: nil)
            if !self.bounds.contains(pointInView) {
                DispatchQueue.main.async { self.coordinator?.cancelRecording() }
            }
            return event
        }
        
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, self.isRecordingHotkey else { return }
            DispatchQueue.main.async { self.coordinator?.cancelRecording() }
        }
        
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: self.window, queue: .main) { [weak self] _ in
             guard let self = self, self.isRecordingHotkey else { return }
             self.coordinator?.cancelRecording()
        }
    }
    
    override func resignFirstResponder() -> Bool {
        if isRecordingHotkey {
            coordinator?.cancelRecording()
        }
        return super.resignFirstResponder()
    }
    
    private func stopMonitoring() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        // Minimal Vercel style - dark background with subtle border
        let bgColor = isRecordingHotkey 
            ? NSColor(white: 0.15, alpha: 1.0)
            : NSColor(white: 0.08, alpha: 1.0)
        bgColor.setFill()
        
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        path.fill()
        
        // Subtle border
        let borderColor = isRecordingHotkey 
            ? NSColor.white.withAlphaComponent(0.3)
            : NSColor.white.withAlphaComponent(0.1)
        borderColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
    
    override func mouseDown(with event: NSEvent) {
        if !isRecordingHotkey {
            coordinator?.startRecording()
        }
        window?.makeFirstResponder(self)
    }
}

// MARK: - Qwen Download Manager
@MainActor
final class QwenDownloadManager: ObservableObject {
    @Published var states: [EngineType: QwenDownloadState] = [:]
    private var downloadTasks: [EngineType: Task<Void, Never>] = [:]

    init() {
        // Seed initial states
        for engine in EngineType.allCases {
            states[engine] = engine.isDownloaded() ? .downloaded : .notDownloaded
        }
    }

    func startDownload(for engine: EngineType) {
        guard let modelId = engine.modelId else { return }
        guard states[engine] != .downloaded else { return }
        if case .downloading = states[engine] { return }

        states[engine] = .downloading(progress: 0)

        let task = Task { [weak self] in
            guard let self else { return }
            let cacheDir = EngineType.qwenCacheDirectory()
                .appendingPathComponent(modelId.replacingOccurrences(of: "/", with: "--"))
            do {
                try await Self.downloadFiles(modelId: modelId, to: cacheDir) { progress in
                    Task { @MainActor [weak self] in
                        self?.states[engine] = .downloading(progress: progress)
                    }
                }
                await MainActor.run { self.states[engine] = .downloaded }
            } catch {
                await MainActor.run {
                    self.states[engine] = .failed(error.localizedDescription)
                }
            }
        }
        downloadTasks[engine] = task
    }

    func cancelDownload(for engine: EngineType) {
        downloadTasks[engine]?.cancel()
        downloadTasks[engine] = nil
        states[engine] = .notDownloaded
    }

    // MARK: - Download implementation (mirrors Qwen3ASREngine.downloadModel)
    private static func downloadFiles(
        modelId: String,
        to directory: URL,
        progress: @escaping (Double) -> Void
    ) async throws {
        let configFiles = [
            "config.json",
            "tokenizer_config.json",
            "generation_config.json",
            "preprocessor_config.json",
            "vocab.json",
            "merges.txt",
            "special_tokens_map.json"
        ]
        let weightFiles = ["model.safetensors"]

        let baseURL = "https://huggingface.co/\(modelId)/resolve/main"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Config files are small; weight file dominates progress
        // Weights get 90% of progress bar, config files share the first 10%
        let configShare = 0.10 / Double(configFiles.count)
        var done = 0.0

        for file in configFiles {
            try Task.checkCancellation()
            guard let url = URL(string: "\(baseURL)/\(file)") else { continue }
            do {
                let (localURL, _) = try await URLSession.shared.download(from: url)
                let dest = directory.appendingPathComponent(file)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: localURL, to: dest)
            } catch {
                // Optional files — log and continue
                print("[QwenDownload] Warning: could not download \(file): \(error.localizedDescription)")
            }
            done += configShare
            progress(done)
        }

        // Weight file — stream with URLSession delegate for byte-level progress
        try Task.checkCancellation()
        guard let weightURL = URL(string: "\(baseURL)/\(weightFiles[0])") else { return }
        let dest = directory.appendingPathComponent(weightFiles[0])
        try? FileManager.default.removeItem(at: dest)

        let delegate = DownloadProgressDelegate { bytes in
            let weightProgress = min(1.0, bytes)
            progress(0.10 + weightProgress * 0.90)
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let (localURL, _) = try await session.download(from: weightURL)
        try FileManager.default.moveItem(at: localURL, to: dest)
        progress(1.0)
    }
}

// URLSession delegate for streaming download progress
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData _: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let frac = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(frac)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Handled in async continuation
    }
}

// MARK: - Settings View (Vercel/ShadCN Style)
struct SettingsView: View {
    @State var config: AppConfig
    @State private var isRecordingHotkey = false
    @StateObject private var downloadManager = QwenDownloadManager()
    var onSave: (AppConfig) -> Void
    var onCancel: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            // Pure black background
            Color(red: 0.03, green: 0.03, blue: 0.03)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Minimal header
                HStack {
                    Text("Settings")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 20)

                // Settings content
                ScrollView {
                    VStack(spacing: 20) {
                        // Engine Section
                        settingsSection(title: "Transcription Engine") {
                            VStack(spacing: 12) {
                                ForEach(EngineType.allCases, id: \.self) { engine in
                                    engineButton(engine: engine)
                                }
                            }
                        }

                        // Language Section
                        settingsSection(title: "Language") {
                            HStack {
                                Text("Transcription language")
                                    .font(.system(size: 13))
                                    .foregroundColor(.white.opacity(0.5))
                                Spacer()
                                Picker("", selection: $config.language) {
                                    ForEach(Language.all) { lang in
                                        Text(lang.name).tag(lang.id)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                                .tint(.white)
                            }
                        }

                        // General Section
                        settingsSection(title: "General") {
                            HStack {
                                Text("Launch at login")
                                    .font(.system(size: 13))
                                    .foregroundColor(.white.opacity(0.5))
                                Spacer()
                                Toggle("", isOn: $config.launchAtLogin)
                                    .toggleStyle(SwitchToggleStyle(tint: .white))
                                    .labelsHidden()
                            }
                        }

                        // Hotkey Section
                        settingsSection(title: "Shortcut") {
                            VStack(spacing: 16) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Hotkey")
                                            .font(.system(size: 13))
                                            .foregroundColor(.white.opacity(0.5))
                                        Text("Click to record")
                                            .font(.system(size: 11))
                                            .foregroundColor(.white.opacity(0.3))
                                    }
                                    Spacer()
                                    HotkeyRecorderView(hotkey: $config.hotkey, isRecording: $isRecordingHotkey)
                                        .frame(width: 140, height: 36)
                                }

                                Divider()
                                    .background(Color.white.opacity(0.08))

                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Mode")
                                        .font(.system(size: 13))
                                        .foregroundColor(.white.opacity(0.5))

                                    HStack(spacing: 8) {
                                        modeButton(mode: .pushToTalk, title: "Push to Talk", subtitle: "Hold to record")
                                        modeButton(mode: .toggle, title: "Toggle", subtitle: "Press to start/stop")
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                }

                // Footer Buttons
                VStack(spacing: 0) {
                    Divider()
                        .background(Color.white.opacity(0.08))

                    HStack(spacing: 12) {
                        Button(action: { onCancel() }) {
                            Text("Cancel")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white.opacity(0.6))
                                .frame(height: 36)
                                .padding(.horizontal, 16)
                                .background(Color.white.opacity(0.06))
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.escape)

                        Spacer()

                        Button(action: { onSave(config) }) {
                            HStack(spacing: 6) {
                                Text("Save")
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.black)
                            .frame(height: 36)
                            .padding(.horizontal, 20)
                            .background(Color.white)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.return)
                    }
                    .padding(24)
                }
            }

            // Download toast — shown when any Qwen engine is actively downloading
            downloadToast
        }
        .frame(width: 420, height: 560)
    }

    // MARK: - Download Toast

    @ViewBuilder
    private var downloadToast: some View {
        let activeDownload: (engine: EngineType, progress: Double)? = {
            for engine in [EngineType.qwenSmall, .qwenLarge] {
                if case .downloading(let p) = downloadManager.states[engine] {
                    return (engine, p)
                }
            }
            return nil
        }()

        if let active = activeDownload {
            VStack(spacing: 0) {
                // Thin progress bar at top of toast
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Color.white.opacity(0.08)
                        Color.white
                            .frame(width: geo.size.width * CGFloat(active.progress))
                            .animation(.linear(duration: 0.2), value: active.progress)
                    }
                }
                .frame(height: 2)

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Downloading \(active.engine.displayName)…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                        Text("\(Int(active.progress * 100))% of \(active.engine.downloadSize)")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    Spacer()
                    Button(action: { downloadManager.cancelDownload(for: active.engine) }) {
                        Text("Cancel")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(5)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(
                Color(red: 0.08, green: 0.08, blue: 0.08)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .cornerRadius(10)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 88)  // sits above the Save/Cancel footer
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: activeDownload != nil)
        }
    }

    // MARK: - Sub-views

    private func settingsSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
                .textCase(.uppercase)
                .tracking(0.5)

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.02))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func modeButton(mode: HotkeyMode, title: String, subtitle: String) -> some View {
        Button(action: { config.hotkeyMode = mode }) {
            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(config.hotkeyMode == mode ? .black : .white.opacity(0.6))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(config.hotkeyMode == mode ? .black.opacity(0.5) : .white.opacity(0.3))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(config.hotkeyMode == mode ? Color.white : Color.white.opacity(0.04))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(config.hotkeyMode == mode ? Color.clear : Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func engineButton(engine: EngineType) -> some View {
        let isSelected = config.engineType == engine
        let dlState = downloadManager.states[engine] ?? (engine.isDownloaded() ? .downloaded : .notDownloaded)

        return Button(action: {
            config.engineType = engine
            // If it's a Qwen engine and not yet downloaded, start the download
            if engine.modelId != nil {
                switch dlState {
                case .notDownloaded, .failed:
                    downloadManager.startDownload(for: engine)
                default:
                    break
                }
            }
        }) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(engine.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(isSelected ? .black : .white.opacity(0.8))
                        Text(engine.downloadSize)
                            .font(.system(size: 10))
                            .foregroundColor(isSelected ? .black.opacity(0.6) : .white.opacity(0.4))
                    }
                    HStack(spacing: 6) {
                        Text("RTF ~\(engine.estimatedRTF)")
                            .font(.system(size: 10))
                            .foregroundColor(isSelected ? .black.opacity(0.5) : .white.opacity(0.3))
                        // Download status badge
                        if engine.modelId != nil {
                            switch dlState {
                            case .notDownloaded:
                                Text("Not downloaded")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(isSelected ? .black.opacity(0.4) : .white.opacity(0.25))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.white.opacity(isSelected ? 0.15 : 0.05))
                                    .cornerRadius(3)
                            case .downloading(let p):
                                Text("\(Int(p * 100))%")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(isSelected ? .black.opacity(0.5) : .white.opacity(0.4))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.white.opacity(0.1))
                                    .cornerRadius(3)
                            case .downloaded:
                                EmptyView()
                            case .failed:
                                Text("Failed — tap to retry")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(.red.opacity(0.8))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.red.opacity(0.1))
                                    .cornerRadius(3)
                            }
                        }
                    }
                }
                Spacer()
                // Right-side indicator
                switch dlState {
                case .downloaded:
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.black)
                    } else {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.3))
                    }
                case .downloading(let p):
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.15), lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: CGFloat(p))
                            .stroke(isSelected ? Color.black : Color.white, lineWidth: 2)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.2), value: p)
                    }
                    .frame(width: 16, height: 16)
                case .notDownloaded, .failed:
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 14))
                        .foregroundColor(isSelected ? .black.opacity(0.5) : .white.opacity(0.3))
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(isSelected ? Color.white : Color.white.opacity(0.04))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.clear : Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings Window Controller
class SettingsWindowController: NSWindowController {
    convenience init(config: AppConfig, onSave: @escaping (AppConfig) -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.center()
        window.backgroundColor = NSColor(red: 0.03, green: 0.03, blue: 0.03, alpha: 1.0)
        
        self.init(window: window)
        
        let settingsView = SettingsView(
            config: config,
            onSave: { [weak self] newConfig in
                onSave(newConfig)
                self?.window?.close()
            },
            onCancel: { [weak self] in
                self?.window?.close()
            }
        )
        
        window.contentViewController = NSHostingController(rootView: settingsView)
    }
    
    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
