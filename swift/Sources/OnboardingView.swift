import SwiftUI
import AVFoundation
import AppKit

// MARK: - Theme Colors (Vercel/ShadCN Style - Black & White)
extension Color {
    static let themePurple = Color.white
    static let themePurpleLight = Color.white.opacity(0.8)
    static let themeDark = Color(red: 0.03, green: 0.03, blue: 0.03)
    static let themeDarkSecondary = Color(red: 0.08, green: 0.08, blue: 0.08)
}

// MARK: - Onboarding State
enum OnboardingStep: Int, CaseIterable {
    case permissions = 0
    case language = 1
    case modelDownload = 2
    case hotkey = 3
    case done = 4
}

// MARK: - Onboarding View
struct OnboardingView: View {
    @State private var currentStep: OnboardingStep = .permissions
    @State private var selectedLanguage = "en"
    @State private var searchText = ""
    // Engine selection: the user picks WhisperCpp or Qwen3
    @State private var selectedEngine: EngineType = .whisperCpp
    // WhisperCpp always uses the "small" model in onboarding
    private let whisperModel: WhisperModel = .small
    @State private var downloadProgress: Double = 0
    @State private var isDownloading = false
    @State private var downloadComplete = false
    @State private var microphoneGranted = false
    @State private var accessibilityGranted = false
    @State private var isRecordingHotkey = false
    @State private var onboardingDoneTriggered = false
    @State private var localHotkeyMode: HotkeyMode = .pushToTalk
    @State private var localHotkeyConfig: HotkeyConfig = .defaultConfig
    
    var initialHotkeyConfig: HotkeyConfig
    var initialHotkeyMode: HotkeyMode
    var onComplete: (HotkeyConfig, HotkeyMode, String, String, EngineType) -> Void
    
    private var filteredLanguages: [Language] {
        if searchText.isEmpty {
            return Language.all
        } else {
            return Language.all.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    // Clean black background
    private var backgroundGradient: some View {
        Color.themeDark
    }
    
    var body: some View {
        ZStack {
            // Background
            backgroundGradient
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Progress indicator - minimal dots
                HStack(spacing: 8) {
                    ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                        Circle()
                            .fill(step.rawValue <= currentStep.rawValue 
                                ? Color.white 
                                : Color.white.opacity(0.2))
                            .frame(width: step.rawValue == currentStep.rawValue ? 8 : 6, 
                                   height: step.rawValue == currentStep.rawValue ? 8 : 6)
                            .animation(.easeInOut(duration: 0.2), value: currentStep)
                    }
                }
                .padding(.top, 40)
                .padding(.bottom, 40)
                
                // Step content
                Group {
                    switch currentStep {
                    case .permissions:
                        permissionsView
                    case .language:
                        languageView
                    case .modelDownload:
                        modelDownloadView
                    case .hotkey:
                        hotkeyView
                    case .done:
                        doneView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
                
                Spacer()
                
                // Navigation buttons - minimal style
                HStack {
                    if currentStep != .permissions && currentStep != .done {
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                if let prev = OnboardingStep(rawValue: currentStep.rawValue - 1) {
                                    currentStep = prev
                                }
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.left")
                                Text("Back")
                            }
                            .foregroundColor(.white.opacity(0.5))
                            .font(.system(size: 14, weight: .medium))
                        }
                        .buttonStyle(.plain)
                    }
                    
                    Spacer()
                    
                    if currentStep == .done {
                        Button(action: {
                            if !onboardingDoneTriggered {
                                onboardingDoneTriggered = true
                                saveSettings()
                                let modelPath: String
                                if selectedEngine == .whisperCpp {
                                    modelPath = ModelDownloader.shared.getModelPath(for: whisperModel)
                                } else {
                                    modelPath = "" // Qwen3 manages its own path
                                }
                                onComplete(localHotkeyConfig, localHotkeyMode, selectedLanguage, modelPath, selectedEngine)
                            }
                        }) {
                            HStack(spacing: 8) {
                                Text("Get Started")
                                Image(systemName: "arrow.right")
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(Color.white)
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .disabled(onboardingDoneTriggered)
                    } else {
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                advanceStep()
                            }
                        }) {
                            HStack(spacing: 8) {
                                Text(nextButtonText)
                                Image(systemName: "arrow.right")
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(canAdvance ? .black : .white.opacity(0.3))
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(canAdvance ? Color.white : Color.white.opacity(0.1))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canAdvance)
                    }
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 30)
            }
        }
        .onAppear {
            localHotkeyConfig = initialHotkeyConfig
            localHotkeyMode = initialHotkeyMode
            checkPermissions()
            startPermissionPolling()
        }
        .onDisappear {
            stopPermissionPolling()
        }

    }
    
    private var nextButtonText: String {
        switch currentStep {
        case .permissions:
            return "Continue"
        case .modelDownload:
            return downloadComplete ? "Continue" : "Download"
        default:
            return "Continue"
        }
    }
    
    private var canAdvance: Bool {
        switch currentStep {
        case .permissions:
            return microphoneGranted && accessibilityGranted
        case .modelDownload:
            return true
        default:
            return true
        }
    }
    
    private func advanceStep() {
        if currentStep == .modelDownload && !downloadComplete {
            // Check if the selected engine already has its model downloaded
            if selectedEngine == .whisperCpp {
                if !ModelDownloader.shared.isModelDownloaded(whisperModel) {
                    startDownload()
                    return
                }
            } else {
                // Qwen3: check if already downloaded
                if !selectedEngine.isDownloaded() {
                    startQwenDownload()
                    return
                }
            }
        }
        
        if let next = OnboardingStep(rawValue: currentStep.rawValue + 1) {
            currentStep = next
        }
    }
    
    // MARK: - Permissions View
    private var permissionsView: some View {
        VStack(spacing: 32) {
            // Minimal icon
            Image(systemName: "lock.shield")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.white)
            
            VStack(spacing: 8) {
                Text("Permissions")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.white)
                
                Text("LocalWhisper needs access to function correctly.")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.5))
            }
            
            VStack(spacing: 12) {
                permissionRow(
                    icon: "mic",
                    title: "Microphone",
                    subtitle: "To capture your voice",
                    granted: microphoneGranted,
                    action: { requestMicrophoneAccess() }
                )
                
                permissionRow(
                    icon: "accessibility",
                    title: "Accessibility",
                    subtitle: "For global shortcuts",
                    granted: accessibilityGranted,
                    action: { openAccessibilitySettings() },
                    showSkip: true
                )
            }
            .padding(.horizontal, 40)
        }
    }
    
    private func permissionRow(icon: String, title: String, subtitle: String, granted: Bool, action: @escaping () -> Void, showSkip: Bool = false) -> some View {
        HStack(spacing: 16) {
            // Icon
            Image(systemName: granted ? "checkmark" : icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(granted ? .green : .white.opacity(0.6))
                .frame(width: 40, height: 40)
                .background(granted ? Color.green.opacity(0.1) : Color.white.opacity(0.05))
                .cornerRadius(8)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
            }
            
            Spacer()
            
            if !granted {
                VStack(spacing: 4) {
                    Button(action: action) {
                        Text("Allow")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.black)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.white)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    
                    if showSkip {
                        Button(action: { accessibilityGranted = true }) {
                            Text("Skip")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.3))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.03))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
    
    // MARK: - Language View
    private var languageView: some View {
        VStack(spacing: 32) {
            Image(systemName: "globe")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.white)
            
            VStack(spacing: 8) {
                Text("Language")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.white)
                
                Text("Select your transcription language.")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.5))
            }
            
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Language.all) { lang in
                        languageButton(code: lang.id, name: lang.name)
                    }
                }
                .padding(8)
            }
            .frame(height: 240)
            .background(Color.white.opacity(0.02))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
            .padding(.horizontal, 40)
        }
    }
    
    private func languageButton(code: String, name: String) -> some View {
        Button(action: { selectedLanguage = code }) {
            HStack(spacing: 12) {
                Text(name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                Spacer()
                if selectedLanguage == code {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(selectedLanguage == code ? Color.white.opacity(0.1) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Model Download View
    private var modelDownloadView: some View {
        VStack(spacing: 24) {
            Image(systemName: downloadComplete ? "checkmark.circle" : "arrow.down.circle")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(downloadComplete ? .green : .white)
            
            VStack(spacing: 8) {
                Text("AI Model")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.white)
                
                Text("Choose your transcription engine.")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
            
            if !isDownloading && !downloadComplete {
                VStack(spacing: 8) {
                    engineOption(
                        engine: .whisperCpp,
                        title: "Whisper.cpp",
                        subtitle: "Offline · \(whisperModel.downloadSize)",
                        detail: "Great accuracy, works without internet"
                    )
                    engineOption(
                        engine: .qwenSmall,
                        title: "Qwen3 0.6B",
                        subtitle: "Offline · \(EngineType.qwenSmall.downloadSize)",
                        detail: "Faster inference on Apple Silicon"
                    )
                }
                .padding(.horizontal, 40)
            }
            
            if isDownloading {
                VStack(spacing: 12) {
                    Text("Downloading \(selectedEngine == .whisperCpp ? whisperModel.name : selectedEngine.displayName)...")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                    
                    // Minimal progress bar
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.1))
                            .frame(height: 4)
                        
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white)
                            .frame(width: max(0, CGFloat(downloadProgress) * 280), height: 4)
                    }
                    .frame(width: 280)
                    
                    Text("\(Int(downloadProgress * 100))%")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                }
            } else if downloadComplete {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Ready with \(selectedEngine == .whisperCpp ? whisperModel.name : selectedEngine.displayName)")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.green)
            }
        }
    }

    private func engineOption(engine: EngineType, title: String, subtitle: String, detail: String) -> some View {
        Button(action: { selectedEngine = engine }) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        Text(subtitle)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(4)
                            .foregroundColor(.white.opacity(0.6))
                    }
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }
                Spacer()
                if selectedEngine == engine {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.white)
                } else {
                    Circle()
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        .frame(width: 20, height: 20)
                }
            }
            .padding(12)
            .background(selectedEngine == engine ? Color.white.opacity(0.08) : Color.clear)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selectedEngine == engine ? Color.white.opacity(0.2) : Color.white.opacity(0.05), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Hotkey View
    private var hotkeyView: some View {
        VStack(spacing: 32) {
            Image(systemName: "keyboard")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.white)
            
            VStack(spacing: 8) {
                Text("Shortcut")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.white)
                
                Text("Configure your activation shortcut.")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.5))
            }
            
            VStack(spacing: 24) {
                HotkeyRecorderView(hotkey: $localHotkeyConfig, isRecording: $isRecordingHotkey)
                    .frame(width: 180, height: 44)
                
                VStack(spacing: 12) {
                    Text("Mode")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                    
                    HStack(spacing: 8) {
                        modeButton(mode: .pushToTalk, title: "Push to Talk", subtitle: "Hold to record")
                        modeButton(mode: .toggle, title: "Toggle", subtitle: "Press to start/stop")
                    }
                }
            }
        }
    }
    
    private func modeButton(mode: HotkeyMode, title: String, subtitle: String) -> some View {
        Button(action: { 
            localHotkeyMode = mode 
        }) {
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(localHotkeyMode == mode ? .black : .white.opacity(0.6))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(localHotkeyMode == mode ? .black.opacity(0.6) : .white.opacity(0.3))
            }
            .frame(width: 140, height: 60)
            .background(localHotkeyMode == mode ? Color.white : Color.white.opacity(0.05))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(localHotkeyMode == mode ? Color.clear : Color.white.opacity(0.1), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Done View
    private var doneView: some View {
        VStack(spacing: 32) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 56, weight: .light))
                .foregroundColor(.green)
            
            VStack(spacing: 8) {
                Text("Ready")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundColor(.white)
                
                Text("You're all set to start transcribing.")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.5))
            }
            
            VStack(spacing: 8) {
                Text("Press")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.4))
                
                Text(localHotkeyConfig.displayString)
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(8)
                
                Text("to start")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
    }
    
    // MARK: - Helpers
    private func checkPermissions() {
        DispatchQueue.global(qos: .userInitiated).async {
            let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            let accStatus = AXIsProcessTrusted()
            
            DispatchQueue.main.async {
                self.microphoneGranted = (micStatus == .authorized)
                self.accessibilityGranted = accStatus
            }
        }
    }
    
    private func requestMicrophoneAccess() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                self.microphoneGranted = granted
            }
        }
    }
    
    @State private var pollingTimer: Timer?

    private func startPermissionPolling() {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            DispatchQueue.main.async {
                // Only poll during the permissions step to avoid unnecessary work
                guard self.currentStep == .permissions else { return }
                
                let accStatus = AXIsProcessTrusted()
                let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                
                if self.accessibilityGranted != accStatus {
                    self.accessibilityGranted = accStatus
                }
                if self.microphoneGranted != (micStatus == .authorized) {
                    self.microphoneGranted = (micStatus == .authorized)
                }
            }
        }
    }
    
    private func stopPermissionPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
    
    private func startDownload() {
        isDownloading = true
        ModelDownloader.shared.downloadModel(whisperModel) { progress in
            DispatchQueue.main.async {
                self.downloadProgress = progress
            }
        } completion: { success in
            DispatchQueue.main.async {
                self.isDownloading = false
                self.downloadComplete = success
                if success {
                    self.advanceStep()
                }
            }
        }
    }

    private func startQwenDownload() {
        guard let modelId = EngineType.qwenSmall.modelId else { return }
        isDownloading = true
        let cacheDir = EngineType.qwenCacheDirectory()
            .appendingPathComponent(modelId.replacingOccurrences(of: "/", with: "--"))
        Task {
            do {
                try await QwenDownloadManager.downloadFiles(modelId: modelId, to: cacheDir) { progress in
                    DispatchQueue.main.async {
                        self.downloadProgress = progress
                    }
                }
                await MainActor.run {
                    self.isDownloading = false
                    self.downloadComplete = true
                    self.advanceStep()
                }
            } catch {
                await MainActor.run {
                    self.isDownloading = false
                }
            }
        }
    }
    
    private func saveSettings() {
        UserDefaults.standard.set(selectedLanguage, forKey: "language")
        UserDefaults.standard.set(true, forKey: "onboardingComplete")
        
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        UserDefaults.standard.set(currentVersion, forKey: "lastRunVersion")
    }
}

// MARK: - Onboarding Window Controller
class OnboardingWindowController {
    private var window: NSWindow?
    private var hostingView: NSHostingView<OnboardingView>?
    
    var onComplete: ((HotkeyConfig, HotkeyMode, String, String, EngineType) -> Void)?
    
    func show(initialHotkeyConfig: HotkeyConfig, initialHotkeyMode: HotkeyMode) {
        // print("🎯 OnboardingWindowController.show() called")
        
        close()
        
        let onboardingView = OnboardingView(
            initialHotkeyConfig: initialHotkeyConfig,
            initialHotkeyMode: initialHotkeyMode,
            onComplete: { [weak self] hotkeyConfig, hotkeyMode, language, modelPath, engineType in
                // CRITICAL: Call onComplete FIRST (sets isAppStarted=true), THEN close window
                // Otherwise app terminates before startApp() runs
                self?.onComplete?(hotkeyConfig, hotkeyMode, language, modelPath, engineType)
                self?.close()
            }
        )
        
        hostingView = NSHostingView(rootView: onboardingView)
        
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 580),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        guard let window = window else { return }
        
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(red: 0.03, green: 0.03, blue: 0.03, alpha: 1.0)
        window.title = "LocalWhisper"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.level = .floating
        
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            window.level = .normal
        }
    }
    
    func close() {
        window?.orderOut(nil)
        hostingView = nil
        window = nil
    }
}
