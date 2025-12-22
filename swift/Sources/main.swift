import Cocoa
import Carbon.HIToolbox
import AVFoundation
import SwiftUI

func logDebug(_ message: String) {
    let timestamp = Date().description
    let logMessage = "[\(timestamp)] \(message)\n"
    print(message)
    let logURL = URL(fileURLWithPath: "/tmp/whisper_mac_startup.log")
    if let data = logMessage.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let fileHandle = try? FileHandle(forWritingTo: logURL) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                try? fileHandle.synchronize() // Force flush
                fileHandle.closeFile()
            }
        } else {
            try? data.write(to: logURL)
        }
    }
}

// MARK: - AppDelegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var audioRecorder: AVAudioRecorder?
    var isRecording = false
    var tempAudioURL: URL?
    
    // UI Components
    var floatingIndicator: FloatingIndicatorWindow!
    var settingsWindowController: SettingsWindowController?
    var onboardingController: OnboardingWindowController?
    
    // Hotkey monitor
    var flagsMonitor: Any?
    var keyDownMonitor: Any?
    var keyUpMonitor: Any?
    var localKeyDownMonitor: Any?
    var localKeyUpMonitor: Any?
    var pressedModifiers: NSEvent.ModifierFlags = []
    var hotkeyKeyPressed = false
    var isHotkeyDown = false // Tracks if the physical key is currently pressed
    var isAppStarted = false // Prevent multiple app starts
    
    // Audio level timer
    var audioLevelTimer: Timer?
    
    // Store last active application for focus restoration
    var lastActiveApplication: NSRunningApplication?
    
    // Config
    var config: AppConfig = .defaultConfig
    let appDir: String
    
    override init() {
        logDebug("AppDelegate init started")
        let fileManager = FileManager.default
        let bundlePath = Bundle.main.bundlePath
        let isPackaged = bundlePath.hasSuffix(".app")
        
        let calculatedAppDir: String
        
        if isPackaged {
            logDebug("Run mode: Packaged (.app)")
            // Use Application Support for config
            guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                logDebug("FATAL: Could not find Application Support directory")
                fatalError("Could not find Application Support directory")
            }
            let appConfigDir = appSupport.appendingPathComponent("LocalWhisper")
            
            // Create directory if it doesn't exist
            do {
                try fileManager.createDirectory(at: appConfigDir, withIntermediateDirectories: true)
                logDebug("Config dir: \(appConfigDir.path)")
            } catch {
                logDebug("FATAL: Could not create config dir: \(error)")
            }
            
            calculatedAppDir = appConfigDir.path
        } else {
            // Development mode: use local directory
            let currentPath = fileManager.currentDirectoryPath
            if currentPath.hasSuffix("/swift") {
                calculatedAppDir = (currentPath as NSString).deletingLastPathComponent
            } else {
                calculatedAppDir = currentPath
            }
        }
        
        self.appDir = calculatedAppDir
        super.init()
        
        loadConfig()
    }
    
    func loadConfig() {
        let configPath = "\(appDir)/config.json"
        
        if let data = FileManager.default.contents(atPath: configPath) {
            do {
                config = try JSONDecoder().decode(AppConfig.self, from: data)
            } catch {
                // Try legacy format
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    config.language = json["language"] as? String ?? "es"
                    config.modelPath = json["model_path"] as? String ?? "models/ggml-small.bin"
                    config.autoPaste = json["auto_paste"] as? Bool ?? true
                    
                    if let hotkeyMode = json["hotkey_mode"] as? String {
                        config.hotkeyMode = HotkeyMode(rawValue: hotkeyMode) ?? .pushToTalk
                    }
                }
            }
        }
        
        print("Config loaded: language=\(config.language), mode=\(config.hotkeyMode)")
    }
    
    func saveConfig() {
        let configPath = "\(appDir)/config.json"
        
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(config)
            try data.write(to: URL(fileURLWithPath: configPath))
            print("Config saved")
        } catch {
            print("Error saving config: \(error)")
        }
    }
    
    var modelPath: String {
        let path = config.modelPath
        if path.hasPrefix("/") {
            return path
        }
        return "\(appDir)/\(path)"
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        logDebug("applicationDidFinishLaunching triggered")
        // Check if onboarding is complete
        let onboardingComplete = UserDefaults.standard.bool(forKey: "onboardingComplete")
        
        // Version Check: Force onboarding if version changed or new install
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let lastRunVersion = UserDefaults.standard.string(forKey: "lastRunVersion")
        let versionChanged = currentVersion != lastRunVersion
        
        // Critical: Check if model file actually exists
        let modelExists = FileManager.default.fileExists(atPath: modelPath)
        
        // Accessibility check: Vital for hotkeys
        let accessibilityGranted = AXIsProcessTrusted()
        
        logDebug("Onboarding state: complete=\(onboardingComplete), model=\(modelExists), versionChanged=\(versionChanged), accessibility=\(accessibilityGranted)")
        
        if !onboardingComplete || !modelExists || versionChanged || !accessibilityGranted {
            logDebug("Decision: Triggering Onboarding")
            
            // Reset flags for fresh start if accessibility is missing or it's a new version
            if !accessibilityGranted || versionChanged {
                UserDefaults.standard.set(false, forKey: "onboardingComplete")
            }
            
            showOnboarding()
            return
        }
        
        logDebug("Decision: Starting App normally")
        
        // Wrap in do-catch just in case
        do {
             // Save current version if we are starting normally
             UserDefaults.standard.set(currentVersion, forKey: "lastRunVersion")
             logDebug("UserDefaults saved")
             
             startApp()
        } catch {
             logDebug("CRITICAL ERROR in startup sequence: \(error)")
        }
        
        // Open settings by default so user sees something (only if it's the first time on this version)
        if versionChanged {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.openSettings()
            }
        }
    }

    @objc func resetApp() {
        let alert = NSAlert()
        alert.messageText = "Reset LocalWhisper?"
        alert.informativeText = "This will remove all configuration and the downloaded model. The application will close and you must configure it again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset and Quit")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            print("🧹 Resetting application...")
            
            // Clear UserDefaults
            if let bundleID = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleID)
            }
            
            // Delete Application Support folder
            let fileManager = FileManager.default
            if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                let appConfigDir = appSupport.appendingPathComponent("LocalWhisper")
                try? fileManager.removeItem(at: appConfigDir)
            }
            
            // Quit
            NSApplication.shared.terminate(nil)
        }
    }
    
    func showOnboarding() {
        onboardingController = OnboardingWindowController()
        onboardingController?.onComplete = { [weak self] hotkeyConfig, hotkeyMode in
            DispatchQueue.main.async {
                print("🚀 Onboarding complete callback triggered with hotkey: \(hotkeyConfig.displayString), mode: \(hotkeyMode)")
                // Save the received config values
                self?.config.hotkey = hotkeyConfig
                self?.config.hotkeyMode = hotkeyMode
                self?.saveConfig()
                self?.onboardingController = nil
                self?.startApp()
            }
        }
        
        // Pass current config values
        onboardingController?.show(
            initialHotkeyConfig: config.hotkey,
            initialHotkeyMode: config.hotkeyMode
        )
    }
    
    // Prevent app from terminating when the last window (onboarding) closes
    // This is critical for menu bar apps that should stay running without visible windows
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
    
    func startApp() {
        logDebug("🚀 startApp() called")
        guard !isAppStarted else {
            logDebug("⚠️ startApp() called but app is already started. Skipping.")
            return
        }
        isAppStarted = true
        
        // Update model path to use downloaded model
        if ModelDownloader.shared.isModelDownloaded() {
            config.modelPath = ModelDownloader.shared.getModelPath()
        }
        
        // Load language from UserDefaults
        if let lang = UserDefaults.standard.string(forKey: "language") {
            config.language = lang
        }
        
        saveConfig()
        
        logDebug("🎧 CONFIG AFTER SAVE: hotkey=\(config.hotkey.displayString), mode=\(config.hotkeyMode), lang=\(config.language)")
        
        // Create floating indicator (already on main thread from callback)
        logDebug("🚀 Creating FloatingIndicatorWindow...")
        floatingIndicator = FloatingIndicatorWindow()
        floatingIndicator.hotkeyDisplayString = config.hotkey.displayString
        floatingIndicator.onOpenSettings = { [weak self] in
            self?.openSettings()
        }
        floatingIndicator.onStartRecording = { [weak self] in
            self?.startRecording()
        }
        floatingIndicator.onStopRecording = { [weak self] in
            self?.stopRecording()
        }
        floatingIndicator.onCancelRecording = { [weak self] in
            self?.cancelRecording()
        }
        floatingIndicator.orderFrontRegardless()
        logDebug("🚀 FloatingIndicatorWindow created and shown")
        
        // Create status bar item
        logDebug("📊 Creating status bar item...")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Local Whisper") {
            image.isTemplate = true // Allows it to adapt to dark/light mode
            statusItem.button?.image = image
            statusItem.button?.title = "" // Clear text
        } else {
            statusItem.button?.title = "LW" // Fallback
        }
        logDebug("📊 Status bar item created")
        
        // Create menu
        logDebug("📋 Creating menu...")
        updateMenu()
        logDebug("📋 Menu created")
        
        // Setup global hotkey monitor
        logDebug("⌨️ Setting up hotkey monitors...")
        setupHotkeyMonitor()
        setupEscapeMonitor()
        logDebug("⌨️ Hotkey monitors set up")
        
        logDebug("✅ startApp() completed successfully")
        print("LocalWhisper Swift started.")
        print("Model: \(modelPath)")
        print("Hotkey: \(config.hotkey.displayString) (\(config.hotkeyMode.displayName))")
        print("🎧 Hotkey keyCode: \(config.hotkey.keyCode), modifiers: \(config.hotkey.modifiers)")
    }
    
    func updateMenu() {
        let menu = NSMenu()
        
        let statusMenuItem = NSMenuItem(title: "Status: Ready", action: nil, keyEquivalent: "")
        statusMenuItem.tag = 100
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())
        
        menu.addItem(NSMenuItem(title: "Language: \(config.language)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Hotkey: \(config.hotkey.displayString)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Mode: \(config.hotkeyMode.displayName)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        
        let prefsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)
        
        let resetItem = NSMenuItem(title: "Reset application...", action: #selector(resetApp), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }
    
    func updateStatusMenuItem(_ text: String) {
        if let item = statusItem.menu?.item(withTag: 100) {
            item.title = "Status: \(text)"
        }
    }
    
    @objc func openSettings() {
        settingsWindowController = SettingsWindowController(config: config) { [weak self] newConfig in
            self?.config = newConfig
            self?.saveConfig()
            self?.updateMenu()
            self?.floatingIndicator.hotkeyDisplayString = newConfig.hotkey.displayString
            self?.setupHotkeyMonitor() // Re-setup with new hotkey
        }
        settingsWindowController?.show()
    }
    
    func setupHotkeyMonitor() {
        // Remove existing monitors
        if let monitor = flagsMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = keyDownMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = keyUpMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localKeyDownMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localKeyUpMonitor { NSEvent.removeMonitor(monitor) }
        
        // Check accessibility permissions
        let trusted = AXIsProcessTrusted()
        print("🔑 Accessibility permission: \(trusted ? "GRANTED ✅" : "DENIED ❌")")
        
        if !trusted {
            print("⚠️ WARNING: Hotkeys will NOT work without Accessibility permission!")
            print("   Please go to System Settings > Privacy & Security > Accessibility")
            print("   and enable 'LocalWhisper'")
            
            // Open accessibility settings
            DispatchQueue.main.async {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                NSWorkspace.shared.open(url)
            }
            return
        }
        
        print("🎹 Setting up hotkey monitor for keyCode \(config.hotkey.keyCode) with modifiers: \(config.hotkey.modifiers)")
        print("🎹 Current hotkey config: \(config.hotkey.displayString)")
        
        // Monitor modifier flags
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.pressedModifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            self?.checkHotkey()
        }
        
        // Local monitor for flags (when app is focused)
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.pressedModifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            self?.checkHotkey()
            return event
        }
        
        // Monitor key down (Global)
        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return }
            if event.keyCode == self.config.hotkey.keyCode {
                // Update modifiers from the keyDown event to ensure accuracy
                self.pressedModifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                if !self.isHotkeyDown {
                    self.isHotkeyDown = true
                    self.hotkeyKeyPressed = true
                    self.checkHotkey()
                }
            }
        }

        // Monitor key down (Local - for when app has focus)
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == self.config.hotkey.keyCode {
                // Update modifiers from the keyDown event to ensure accuracy
                self.pressedModifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                if !self.isHotkeyDown {
                    self.isHotkeyDown = true
                    self.hotkeyKeyPressed = true
                    self.checkHotkey()
                }
                // Consume the event when modifiers match to prevent system beep sound
                if self.checkModifiersMatch() {
                    return nil
                }
            }
            return event
        }
        
        // Monitor key up (Global)
        keyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self = self else { return }
            if event.keyCode == self.config.hotkey.keyCode {
                self.isHotkeyDown = false
                self.handleKeyUp()
            }
        }

        // Monitor key up (Local)
        localKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == self.config.hotkey.keyCode {
                self.isHotkeyDown = false
                self.handleKeyUp()
            }
            return event
        }
    }
    
    func handleKeyUp() {
        self.hotkeyKeyPressed = false
        
        // For push-to-talk mode, stop recording on key release
        if self.config.hotkeyMode == .pushToTalk && self.isRecording {
            print("🔼 Key released in Push-to-Talk mode - stopping recording")
            self.stopRecording()
        }
    }
    
    func setupEscapeMonitor() {
        // Monitor ESC key to cancel recording
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 && self?.isRecording == true {  // 53 = ESC key
                print("⎋ ESC pressed - canceling recording")
                self?.cancelRecording()
            }
        }
        
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 && self?.isRecording == true {  // 53 = ESC key
                print("⎋ ESC pressed - canceling recording")
                self?.cancelRecording()
                return nil  // Consume the event
            }
            return event
        }
    }
    
    func checkHotkey() {
        let modifiersMatch = checkModifiersMatch()
        
        if modifiersMatch && hotkeyKeyPressed {
            switch config.hotkeyMode {
            case .pushToTalk:
                if !isRecording {
                    print("🔽 Push-to-Talk: Key down - starting recording")
                    startRecording()
                }
            case .toggle:
                if isRecording {
                    // Toggle mode: Pressing hotkey AGAIN while recording = STOP and TRANSCRIBE
                    print("⏹️ Hotkey pressed during recording - stopping and transcribing")
                    stopRecording()
                } else {
                    startRecording()
                }
                // Reset flag for this cycle
                hotkeyKeyPressed = false
            }
        }
    }
    
    func checkModifiersMatch() -> Bool {
        let mods = config.hotkey.modifiers
        let needCmd = mods.contains("cmd")
        let needShift = mods.contains("shift")
        let needAlt = mods.contains("alt")
        let needCtrl = mods.contains("ctrl")
        
        let hasCmd = pressedModifiers.contains(.command)
        let hasShift = pressedModifiers.contains(.shift)
        let hasAlt = pressedModifiers.contains(.option)
        let hasCtrl = pressedModifiers.contains(.control)
        
        return (needCmd == hasCmd) && (needShift == hasShift) && 
               (needAlt == hasAlt) && (needCtrl == hasCtrl)
    }
    
    func startRecording() {
        guard !isRecording else { return }
        
        // CRITICAL: Save the currently active application BEFORE recording starts
        // This is needed so we can restore focus for auto-paste after transcription
        lastActiveApplication = NSWorkspace.shared.frontmostApplication
        print("📍 Saved active app: \(lastActiveApplication?.localizedName ?? "none")")
        
        isRecording = true
        
        DispatchQueue.main.async {
            if let image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Recording") {
                image.isTemplate = true
                self.statusItem.button?.image = image
            }
            self.updateStatusMenuItem("Recording...")
            self.floatingIndicator.setState(.recording)
        }
        
        // Create temp file for recording
        let tempDir = FileManager.default.temporaryDirectory
        tempAudioURL = tempDir.appendingPathComponent("whisper_recording.wav")
        
        // Audio settings for Whisper (16kHz mono)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: tempAudioURL!, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()
            
            // Start audio level monitoring
            startAudioLevelMonitoring()
            
            print("Recording...")
        } catch {
            print("Error recording: \(error)")
            isRecording = false
            if let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Local Whisper") {
                image.isTemplate = true
                statusItem.button?.image = image
            }
            floatingIndicator.setState(.idle)
        }
    }
    
    func startAudioLevelMonitoring() {
        audioLevelTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            guard let self = self, let recorder = self.audioRecorder, recorder.isRecording else { return }
            
            recorder.updateMeters()
            let power = recorder.averagePower(forChannel: 0)
            // Convert dB to linearly scaling 0-1 range
            // Typical noise floor is around -60dB -> map -60...0 to 0...1
            let minDb: Float = -60.0
            let normalizedLevel = max(0, (power - minDb) / -minDb)
            // Boost low levels slightly for better visibility
            let boostedLevel = pow(normalizedLevel, 0.8) * 1.2
            self.floatingIndicator.updateAudioLevel(min(1.0, boostedLevel))
        }
    }
    
    func stopAudioLevelMonitoring() {
        audioLevelTimer?.invalidate()
        audioLevelTimer = nil
    }
    
    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        
        stopAudioLevelMonitoring()
        audioRecorder?.stop()
        audioRecorder = nil
        
        DispatchQueue.main.async {
            if let image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Transcribing") {
                image.isTemplate = true
                self.statusItem.button?.image = image
            }
            self.updateStatusMenuItem("Transcribing...")
            self.floatingIndicator.setState(.transcribing)
        }
        
        print("Recording finished.")
        
        // Transcribe
        transcribe()
    }
    
    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        
        print("❌ Recording canceled.")
        
        stopAudioLevelMonitoring()
        audioRecorder?.stop()
        audioRecorder = nil
        
        // Delete temp file without transcribing (silently in background)
        if let url = tempAudioURL {
            DispatchQueue.global(qos: .utility).async {
                try? FileManager.default.removeItem(at: url)
            }
        }
        tempAudioURL = nil
        
        // Update UI immediately on main thread
        DispatchQueue.main.async {
            if let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Local Whisper") {
                image.isTemplate = true
                self.statusItem.button?.image = image
            }
            self.updateStatusMenuItem("Ready")
            self.floatingIndicator.setState(.idle, silent: true)
        }
    }
    
    func getWhisperCliPath() -> String? {
        // 1. Check inside App Bundle (Production)
        if let bundlePath = Bundle.main.path(forResource: "whisper-cli", ofType: nil, inDirectory: "bin") {
             print("Found whisper-cli in bundle: \(bundlePath)")
            return bundlePath
        }
        
        // 2. Check local bin directory (Development)
        let localBinPath = "\(appDir)/bin/whisper-cli"
        if FileManager.default.fileExists(atPath: localBinPath) {
             print("Found whisper-cli in local bin: \(localBinPath)")
            return localBinPath
        }
        
        // 3. Last resort: try system path (Legacy/Homebrew)
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/whisper-cli") {
            return "/opt/homebrew/bin/whisper-cli"
        }
        
        return nil
    }

    func transcribe() {
        guard let audioURL = tempAudioURL else { return }
        
        let desktopPath = NSSearchPathForDirectoriesInDomains(.desktopDirectory, .userDomainMask, true).first!
        let logURL = URL(fileURLWithPath: desktopPath).appendingPathComponent("whisper_debug.log")
        
        func log(_ message: String) {
            let timestamp = Date().description
            let logMessage = "[\(timestamp)] \(message)\n"
            print(message)
            if let data = logMessage.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logURL.path) {
                    if let fileHandle = try? FileHandle(forWritingTo: logURL) {
                        fileHandle.seekToEndOfFile()
                        fileHandle.write(data)
                        fileHandle.closeFile()
                    }
                } else {
                    try? data.write(to: logURL)
                }
            }
        }

        log("🚀 Starting transcription...")
        log("📁 Audio file: \(audioURL.path)")
        log("⚙️ Language: \(config.language)")
        log("🧠 Model: \(modelPath)")

        guard let whisperPath = getWhisperCliPath() else {
            log("❌ Error: whisper-cli not found")
            DispatchQueue.main.async {
                if let image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Error") {
                    image.isTemplate = true
                    self.statusItem.button?.image = image
                }
                self.updateStatusMenuItem("Error: Missing binary")
                self.floatingIndicator.setState(.idle)
            }
            return
        }
        
        log("🛠 CLI Path: \(whisperPath)")
        
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // Check audio file size
            if let attrs = try? FileManager.default.attributesOfItem(atPath: audioURL.path) {
                let size = attrs[.size] as? Int64 ?? 0
                log("🎙️ Audio file size: \(size) bytes")
            }
            
            // Optimal thread count: use ALL cores for maximum quality
            let totalCores = ProcessInfo.processInfo.processorCount
            log("⚡ Using \(totalCores) threads for maximum quality")
            
            // Build language-specific prompt for better accuracy
            let qualityPrompt: String
            if config.language == "es" {
                qualityPrompt = "Esta es una transcripción de alta calidad en español, con puntuación correcta y mayúsculas apropiadas."
            } else if config.language == "en" {
                qualityPrompt = "This is a high-quality transcription in English, with correct punctuation and proper capitalization."
            } else {
                qualityPrompt = "High-quality transcription with correct punctuation."
            }
            
            let cmd = [
                whisperPath,
                "-m", modelPath,
                "-f", audioURL.path,
                "-nt",                          // No timestamps
                "-t", String(totalCores),       // Use ALL cores for quality
                "-bs", "8",                     // Beam size: MAXIMUM quality (default 5)
                "-bo", "8",                     // Best of: more candidates = better selection
                "-nth", "0.6",                  // No-speech threshold: default, balanced
                "-et", "2.4",                   // Entropy threshold: default for reliability
                "-lpt", "-0.5",                 // Log probability threshold: stricter quality filter
                "--prompt", qualityPrompt,      // Language-specific context
                "-l", config.language
            ]
            
            log("🏃 Running: \(cmd.joined(separator: " "))")
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: whisperPath)
            process.arguments = Array(cmd.dropFirst())
            
            // Fix library loading for packaged app by forcing DYLD_LIBRARY_PATH
            var env = ProcessInfo.processInfo.environment
            if let resourcePath = Bundle.main.resourcePath {
                let libPath = resourcePath + "/lib"
                env["DYLD_LIBRARY_PATH"] = libPath
                process.environment = env
                log("🔧 Set DYLD_LIBRARY_PATH: \(libPath)")
            }
            
            let pipe = Pipe()
            process.standardOutput = pipe
            
            let errorPipe = Pipe()
            process.standardError = errorPipe
            
            do {
                try process.run()
                process.waitUntilExit()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
                
                if !output.isEmpty { log("📤 STDOUT:\n\(output)") }
                if !errorOutput.isEmpty { log("⚠️ STDERR:\n\(errorOutput)") }
                
                let text = parseWhisperOutput(output)
                
                DispatchQueue.main.async {
                    if !text.isEmpty {
                        log("✅ Transcription successful: \(text)")
                        
                        // Copy to clipboard
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        
                        // Auto-paste if enabled
                        if self.config.autoPaste {
                            // Restore focus to original app before pasting
                            if let app = self.lastActiveApplication {
                                app.activate(options: [.activateIgnoringOtherApps])
                            }
                            self.simulatePaste()
                        }
                        
                        self.updateStatusMenuItem("Ready")
                        self.floatingIndicator.setState(.idle)
                    } else {
                        log("❓ No text detected in transcription")
                        self.updateStatusMenuItem("No text")
                        self.floatingIndicator.setState(.idle)
                    }
                    
                    if let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Local Whisper") {
                        image.isTemplate = true
                        self.statusItem.button?.image = image
                    }
                }
                
                try? FileManager.default.removeItem(at: audioURL)
                
            } catch {
                log("💀 Fatal error in transcription: \(error)")
                DispatchQueue.main.async {
                    if let image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Error") {
                         image.isTemplate = true
                         self.statusItem.button?.image = image
                    }
                    self.updateStatusMenuItem("Error")
                    self.floatingIndicator.setState(.idle)
                }
            }
        }
    }
    
    func parseWhisperOutput(_ output: String) -> String {
        var lines: [String] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
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
    
    func simulatePaste() {
        // Use CGEvent for reliable paste simulation
        let source = CGEventSource(stateID: .hidSystemState)
        
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // V key
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
    
    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Main
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // Menu bar app: never steal focus, no dock icon
app.run()
