import Cocoa
import Carbon.HIToolbox
import AVFoundation
import SwiftUI


func getPerformanceCoreCount() -> Int {
    // var size: Int = 0
    var results: Int = 0
    var sizeOfInt = MemoryLayout<Int>.size
    
    // hw.perflevel0.logicalcpu usually relates to Performance cores on Apple Silicon
    if sysctlbyname("hw.perflevel0.logicalcpu", &results, &sizeOfInt, nil, 0) == 0 {
        return results
    }
    // Fallback: simple heuristic or just return 0 to default to all cores
    return 0
}
func logDebug(_ message: String) {
    #if DEBUG
    print(message)
    #endif
}

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
    var eventTapWatchdog: Timer? // Watchdog to re-enable event tap if macOS disables it
    
    // Audio level timer
    var audioLevelTimer: Timer?
    
    // Store last active application
    var lastActiveApplication: NSRunningApplication?
    
    // Latency tracking
    var transcriptionStartTime: CFAbsoluteTime?
    
    // Transcription Engine
    var activeEngine: TranscriptionEngine?
    
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
    
    func getAvailableMicrophones() -> [(name: String, id: String)] {
        var microphones: [(name: String, id: String)] = []
        
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        
        for device in discoverySession.devices {
            microphones.append((name: device.localizedName, id: device.uniqueID))
        }
        
        return microphones
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
                    config.launchAtLogin = json["launch_at_login"] as? Bool ?? false
                }
            }
        }
        
        // Migrate old default paste delay to new optimized value (30ms)
        // Pre-activation during transcription means we need less delay here
        if config.pasteDelay >= 80 {
            config.pasteDelay = 30
        }
        
        logDebug("Config loaded: language=\(config.language), mode=\(config.hotkeyMode), pasteDelay=\(config.pasteDelay)ms")
    }
    
    func saveConfig() {
        let configPath = "\(appDir)/config.json"
        
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(config)
            try data.write(to: URL(fileURLWithPath: configPath))
            logDebug("Config saved")
            
            // Sync Launch at Login state with system
            updateLaunchAtLogin()
        } catch {
            logDebug("Error saving config: \(error)")
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
        
         // Save current version if we are starting normally
         UserDefaults.standard.set(currentVersion, forKey: "lastRunVersion")
         logDebug("UserDefaults saved")
         
         startApp()
        
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
            logDebug("🧹 Resetting application...")
            
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
        // Show Dock icon during onboarding so users can find the app
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        
        onboardingController = OnboardingWindowController()
        onboardingController?.onComplete = { [weak self] hotkeyConfig, hotkeyMode, language, modelPath in
            // CRITICAL: Set isAppStarted IMMEDIATELY (synchronously) to prevent app termination
            // when the onboarding window closes. The rest can be async.
            self?.isAppStarted = true
            
            DispatchQueue.main.async {
                logDebug("🚀 Onboarding complete: hotkey=\(hotkeyConfig.displayString), lang=\(language), model=\(modelPath)")
                // Save the received config values
                self?.config.hotkey = hotkeyConfig
                self?.config.hotkeyMode = hotkeyMode
                self?.config.language = language
                self?.config.modelPath = modelPath
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
    // UNLESS we are in onboarding mode (isAppStarted == false) - in that case, closing should Quit
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return !isAppStarted
    }
    
    // Handle Dock icon click - reopen onboarding if not complete, or show settings
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        logDebug("🔄 applicationShouldHandleReopen called, hasVisibleWindows: \(flag), isAppStarted: \(isAppStarted)")
        
        if !flag {
            // No visible windows - need to show something
            let onboardingComplete = UserDefaults.standard.bool(forKey: "onboardingComplete")
            let modelExists = FileManager.default.fileExists(atPath: modelPath)
            let accessibilityGranted = AXIsProcessTrusted()
            
            if !onboardingComplete || !modelExists || !accessibilityGranted {
                // Onboarding not complete - show onboarding window
                logDebug("📋 Reopening onboarding window...")
                showOnboarding()
            } else if isAppStarted {
                // App is running normally - show settings
                logDebug("⚙️ Opening settings...")
                openSettings()
            } else {
                // App should start but hasn't yet
                logDebug("🚀 Starting app from reopen...")
                startApp()
            }
        }
        
        return true
    }
    
    var appSetupComplete = false
    
    func startApp() {
        logDebug("🚀 startApp() called")
        guard !appSetupComplete else {
            logDebug("⚠️ startApp() called but app setup is already complete. Skipping.")
            return
        }
        appSetupComplete = true
        isAppStarted = true
        
        // Ensure model path is absolute
        if !config.modelPath.hasPrefix("/") {
            // If it's a relative path, resolve it against the models directory
            let filename = (config.modelPath as NSString).lastPathComponent
            config.modelPath = ModelDownloader.shared.getModelsDirectory().appendingPathComponent(filename).path
        }
        
        // Load language from UserDefaults if not already set
        if config.language.isEmpty, let lang = UserDefaults.standard.string(forKey: "language") {
            config.language = lang
        }
        
        saveConfig()
        
        logDebug("🎧 CONFIG AFTER SAVE: hotkey=\(config.hotkey.displayString), mode=\(config.hotkeyMode), lang=\(config.language), engine=\(config.engineType.displayName)")
        
        // Initialize transcription engine
        Task { [weak self] in
            await self?.loadEngine()
        }
        
        // Hide Dock icon for normal operation (menu bar mode)
        NSApp.setActivationPolicy(.accessory)
        
        // Create floating indicator (MUST be synchronous to avoid race conditions)
        logDebug("🚀 Creating FloatingIndicatorWindow...")
        floatingIndicator = FloatingIndicatorWindow()
        floatingIndicator.hotkeyDisplayString = config.hotkey.displayString
        floatingIndicator.currentConfig = config
        floatingIndicator.availableMicrophones = getAvailableMicrophones()
        
        floatingIndicator.onOpenSettings = { [weak self] in
            self?.openSettings()
        }
        floatingIndicator.onStartRecording = { [weak self] in
            guard let self = self else { return }
            // Capture the frontmost app lazily at click time.
            // Our pill is canBecomeKey=false, so the frontmost app is still the user's app.
            if !self.isRecording {
                if let frontApp = NSWorkspace.shared.frontmostApplication,
                   frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
                    self.lastActiveApplication = frontApp
                    logDebug("🎯 [CLICK TARGET] Captured app at click: \(frontApp.localizedName ?? "Unknown")")
                } else if let app = self.lastActiveApplication {
                    logDebug("🎯 [CLICK TARGET] Using previously tracked app: \(app.localizedName ?? "Unknown")")
                } else {
                    logDebug("⚠️ [CLICK] No target app - paste will copy to clipboard only")
                }
            }
            self.startRecording()
        }
        floatingIndicator.onStopRecording = { [weak self] in
            self?.stopRecording()
        }
        floatingIndicator.onCancelRecording = { [weak self] in
            self?.cancelRecording()
        }
        
        // Context Menu Callbacks
        floatingIndicator.onSelectLanguage = { [weak self] langId in
            guard let self = self else { return }
            self.config.language = langId
            self.saveConfig()
            self.floatingIndicator.currentConfig = self.config
            logDebug("🌐 Language changed to: \(langId)")
        }
        
        floatingIndicator.onSelectEngine = { [weak self] engine in
            guard let self = self else { return }
            self.config.engineType = engine
            self.saveConfig()
            self.floatingIndicator.currentConfig = self.config
            logDebug("🧠 Engine changed to: \(engine.displayName)")
            Task {
                await self.loadEngine()
            }
        }
        
        floatingIndicator.onSelectMode = { [weak self] mode in
            guard let self = self else { return }
            self.config.hotkeyMode = mode
            self.saveConfig()
            self.floatingIndicator.currentConfig = self.config
            logDebug("⚙️ Mode changed to: \(mode.displayName)")
        }
        
        floatingIndicator.onSelectMicrophone = { [weak self] micId in
            guard let self = self else { return }
            self.config.microphoneId = micId
            self.saveConfig()
            self.floatingIndicator.currentConfig = self.config
            logDebug("🎤 Microphone changed to: \(micId)")
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
        // ESC key handling is done inside the CGEvent tap callback (handleEvent),
        // so no separate monitor is needed.
        logDebug("⌨️ Hotkey monitors set up")
        
        // App activation tracking removed — lastActiveApplication is now captured lazily
        // at hotkey-press time (checkHotkey) and click-to-record time (onStartRecording).
        // This eliminates a callback on every single app switch system-wide.
        
        logDebug("✅ startApp() completed successfully")
        logDebug("LocalWhisper Swift started.")
        logDebug("Model: \(modelPath)")
        logDebug("Hotkey: \(config.hotkey.displayString) (\(config.hotkeyMode.displayName))")
        logDebug("🎧 Hotkey keyCode: \(config.hotkey.keyCode), modifiers: \(config.hotkey.modifiers)")
        
        // Show "Control-click for Settings" toast on first launch (floatingIndicator is guaranteed to exist now)
        let hasShownFirstLaunchToast = UserDefaults.standard.bool(forKey: "hasShownFirstLaunchToast")
        if !hasShownFirstLaunchToast {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.floatingIndicator.showSettingsToast()
            }
            UserDefaults.standard.set(true, forKey: "hasShownFirstLaunchToast")
        }
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
    
    var eventTap: CFMachPort?
    var runLoopSource: CFRunLoopSource?

    func setupHotkeyMonitor() {
        // Remove existing NSEvent monitors if any (legacy cleanup)
        if let monitor = flagsMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = keyDownMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = keyUpMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localKeyDownMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localKeyUpMonitor { NSEvent.removeMonitor(monitor) }
        
        // Clean up previous Event Tap
        if let eventTap = eventTap, let runLoopSource = runLoopSource {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            self.eventTap = nil
            self.runLoopSource = nil
        }
        
        // Check accessibility permissions
        let trusted = AXIsProcessTrusted()
        logDebug("🔑 Accessibility permission: \(trusted ? "GRANTED ✅" : "DENIED ❌")")
        
        if !trusted {
            logDebug("⚠️ WARNING: Hotkeys will NOT work without Accessibility permission!")
            logDebug("   Please go to System Settings > Privacy & Security > Accessibility")
            logDebug("   and enable 'LocalWhisper'")
            
            DispatchQueue.main.async {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                NSWorkspace.shared.open(url)
            }
            return
        }
        
        logDebug("🎹 Setting up active event tap for keyCode \(config.hotkey.keyCode)")
        
        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        
        func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
            
            if delegate.handleEvent(type: type, event: event) {
                // Return nil to consume the event (suppress beep)
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: eventTapCallback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            logDebug("❌ Failed to create CGEvent tap — falling back to NSEvent global monitor")
            setupNSEventFallbackMonitor()
            return
        }
        
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        
        self.eventTap = tap
        self.runLoopSource = source
        
        // Watchdog: macOS can auto-disable the event tap if the callback is slow.
        // Check every 30s (was 2s) — the tap rarely gets disabled and this avoids
        // unnecessary timer wakeups. 30s is fast enough to recover without user noticing.
        eventTapWatchdog?.invalidate()
        eventTapWatchdog = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self = self, let tap = self.eventTap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                logDebug("⚠️ Event tap was disabled by macOS — re-enabling...")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
    }
    
    func setupNSEventFallbackMonitor() {
        // Fallback when CGEvent tap cannot be created (accessibility not granted for this bundle).
        // NSEvent global monitor works for modifier+key combos but cannot consume events (no beep suppression).
        logDebug("⌨️ Setting up NSEvent fallback monitor for hotkey \(config.hotkey.displayString)")
        
        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return }
            let keyCode = Int(event.keyCode)
            guard keyCode == self.config.hotkey.keyCode else { return }
            
            var modifiers: [String] = []
            if event.modifierFlags.contains(.command) { modifiers.append("cmd") }
            if event.modifierFlags.contains(.control) { modifiers.append("ctrl") }
            if event.modifierFlags.contains(.option) { modifiers.append("alt") }
            if event.modifierFlags.contains(.shift) { modifiers.append("shift") }
            
            let needCmd = self.config.hotkey.modifiers.contains("cmd")
            let needShift = self.config.hotkey.modifiers.contains("shift")
            let needAlt = self.config.hotkey.modifiers.contains("alt")
            let needCtrl = self.config.hotkey.modifiers.contains("ctrl")
            
            let match = (needCmd == modifiers.contains("cmd")) &&
                        (needShift == modifiers.contains("shift")) &&
                        (needAlt == modifiers.contains("alt")) &&
                        (needCtrl == modifiers.contains("ctrl"))
            
            guard match else { return }
            
            logDebug("🎹 NSEvent fallback: hotkey detected")
            
            DispatchQueue.main.async {
                if !self.isHotkeyDown {
                    self.isHotkeyDown = true
                    self.hotkeyKeyPressed = true
                    self.checkHotkey()
                }
            }
        }
        
        keyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self = self else { return }
            if Int(event.keyCode) == self.config.hotkey.keyCode {
                self.isHotkeyDown = false
                DispatchQueue.main.async { self.handleKeyUp() }
            }
        }
    }
    
    func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
        // Returns true if event should be consumed
        
        if type == .flagsChanged {
            let flags = event.flags
            
            // Early exit: skip processing if no hotkey-relevant modifiers are pressed
            // AND we're not currently tracking a hotkey press (need to detect release).
            // This avoids unnecessary work for every modifier key press system-wide.
            let hotkeyMods = self.config.hotkey.modifiers
            let hasRelevantModifier =
                (hotkeyMods.contains("cmd") && flags.contains(.maskCommand)) ||
                (hotkeyMods.contains("shift") && flags.contains(.maskShift)) ||
                (hotkeyMods.contains("alt") && flags.contains(.maskAlternate)) ||
                (hotkeyMods.contains("ctrl") && flags.contains(.maskControl))
            
            guard hasRelevantModifier || self.isHotkeyDown else { return false }
            
            // Map CGEventFlags to NSEvent.ModifierFlags for consistency with existing logic
            var modifiers: NSEvent.ModifierFlags = []
            if flags.contains(.maskCommand) { modifiers.insert(.command) }
            if flags.contains(.maskShift) { modifiers.insert(.shift) }
            if flags.contains(.maskAlternate) { modifiers.insert(.option) }
            if flags.contains(.maskControl) { modifiers.insert(.control) }
            
            self.pressedModifiers = modifiers.intersection([.command, .shift, .option, .control])
            self.checkHotkey()
            return false // Don't consume flag change events
        }
        
        if type == .keyDown {
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            
            // Handle ESC key (keyCode 53) to cancel recording.
            // This replaces the leaked NSEvent.addGlobalMonitor/addLocalMonitor that
            // previously handled ESC but could never be removed (references were discarded).
            if keyCode == 53 && self.isRecording {
                logDebug("⎋ ESC pressed (via CGEvent tap) - canceling recording")
                DispatchQueue.main.async { self.cancelRecording() }
                return true // Consume ESC during recording
            }
            
            if keyCode == self.config.hotkey.keyCode {
                // Update modifiers from event flags to ensure accuracy
                let flags = event.flags
                var modifiers: NSEvent.ModifierFlags = []
                if flags.contains(.maskCommand) { modifiers.insert(.command) }
                if flags.contains(.maskShift) { modifiers.insert(.shift) }
                if flags.contains(.maskAlternate) { modifiers.insert(.option) }
                if flags.contains(.maskControl) { modifiers.insert(.control) }
                
                self.pressedModifiers = modifiers.intersection([.command, .shift, .option, .control])
                
                if self.checkModifiersMatch() {
                    logDebug("🎹 Active Hotkey Trap: Consuming event for key \(keyCode)")
                    if !self.isHotkeyDown {
                        self.isHotkeyDown = true
                        self.hotkeyKeyPressed = true
                        self.checkHotkey()
                    }
                    return true // CONSUME EVENT -> PREVENTS BEEP
                }
            }
        }
        
        if type == .keyUp {
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == self.config.hotkey.keyCode {
                self.isHotkeyDown = false
                self.handleKeyUp()
                // Should we consume keyUp? Usually safer effectively to consume it if we consumed keyDown
                // BUT, if we consume it, other apps might miss the keyRelease if hotkey logic was weird.
                // Generally fine to consume it if it was our hotkey.
                let flags = event.flags
                var modifiers: NSEvent.ModifierFlags = []
                 if flags.contains(.maskCommand) { modifiers.insert(.command) }
                if flags.contains(.maskShift) { modifiers.insert(.shift) }
                if flags.contains(.maskAlternate) { modifiers.insert(.option) }
                if flags.contains(.maskControl) { modifiers.insert(.control) }
                
                // We check basic match, but keyUp might have fewer modifiers if user released them first.
                // Just checking keycode is usually enough for the 'release' of the hotkey interaction.
                return true 
            }
        }
        
        return false
    }
    
    func handleKeyUp() {
        self.hotkeyKeyPressed = false
        
        // For push-to-talk mode, stop recording on key release
        if self.config.hotkeyMode == .pushToTalk && self.isRecording {
            logDebug("🔼 Key released in Push-to-Talk mode - stopping recording")
            self.stopRecording()
        }
    }
    
    func checkHotkey() {
        let modifiersMatch = checkModifiersMatch()
        
        logDebug("🎹 checkHotkey: modifiersMatch=\(modifiersMatch), hotkeyKeyPressed=\(hotkeyKeyPressed), isRecording=\(isRecording)")
        
        if modifiersMatch && hotkeyKeyPressed {
            // CRITICAL: Capture the frontmost app only at the START of recording
            // This prevents switching targets if the user clicks somewhere else during recording
            if !isRecording {
                if let frontApp = NSWorkspace.shared.frontmostApplication {
                    // Only update if it's not our own app
                    if frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
                        self.lastActiveApplication = frontApp
                        let appName = frontApp.localizedName ?? "Unknown"
                        logDebug("🎯 [TARGET LOCK] Captured app at recording start: \(appName) (PID: \(frontApp.processIdentifier))")
                        
                        // Update UI to show the user WHERE we will paste
                        DispatchQueue.main.async {
                            self.floatingIndicator.lockedTargetAppName = appName
                        }
                    }
                }
            } else {
                logDebug("ℹ️ Hotkey pressed to STOP - keeping existing target: \(lastActiveApplication?.localizedName ?? "None")")
            }
            
            switch config.hotkeyMode {
            case .pushToTalk:
                if !isRecording {
                    logDebug("🔽 Push-to-Talk: Key down - starting recording")
                    startRecording()
                }
            case .toggle:
                if isRecording {
                    logDebug("⏹️ Hotkey pressed during recording - stopping and transcribing")
                    stopRecording()
                } else {
                    startRecording()
                }
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
        
        // Close context menu if open
        floatingIndicator.closeContextMenu()
        
        // Use tracked application for focus restoration
        logDebug("📍 StartRecording usage Target App: \(lastActiveApplication?.localizedName ?? "none")")
        
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
            
            logDebug("Recording...")
        } catch {
            logDebug("Error recording: \(error)")
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
            
            // Update UI - convert dB to linearly scaling 0-1 range
            let minDb: Float = -60.0
            let normalizedLevel = max(0, (power - minDb) / -minDb)
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
        
        let recordingStopTime = CFAbsoluteTimeGetCurrent()
        
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
        
        logDebug("Recording finished.")
        
        // Pre-activate the target app NOW so it's focused by the time transcription finishes.
        // This overlaps the focus-wait with the transcription time (~300-2000ms), saving ~70-130ms.
        if config.autoPaste, let app = lastActiveApplication,
           app.bundleIdentifier != Bundle.main.bundleIdentifier {
            logDebug("🚀 Pre-activating target app: \(app.localizedName ?? "Unknown") during transcription")
            app.activate(options: [.activateAllWindows])
        }
        
        // Store timing for latency tracking
        transcriptionStartTime = recordingStopTime
        
        // Transcribe
        transcribe()
    }
    
    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        
        logDebug("❌ Recording canceled.")
        
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
             logDebug("Found whisper-cli in bundle: \(bundlePath)")
            return bundlePath
        }
        
        // 2. Check local bin directory (Development)
        let localBinPath = "\(appDir)/bin/whisper-cli"
        if FileManager.default.fileExists(atPath: localBinPath) {
             logDebug("Found whisper-cli in local bin: \(localBinPath)")
            return localBinPath
        }
        
        // 3. Last resort: try system path (Legacy/Homebrew)
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/whisper-cli") {
            return "/opt/homebrew/bin/whisper-cli"
        }
        
        return nil
    }
    
    @MainActor
    func loadEngine() async {
        logDebug("🔄 Loading transcription engine: \(config.engineType.displayName)")
        
        switch config.engineType {
        case .whisperCpp:
            activeEngine = WhisperCppEngine(appDir: appDir, modelPath: modelPath)
        case .qwenSmall:
            if #available(macOS 14.0, *) {
                activeEngine = Qwen3ASREngine(type: config.engineType)
            } else {
                logDebug("⚠️ Qwen3 requires macOS 14.0+, falling back to whisper.cpp")
                activeEngine = WhisperCppEngine(appDir: appDir, modelPath: modelPath)
            }
        }
        
        do {
            try await activeEngine?.load(progress: { p in
                logDebug("📥 Engine loading: \(Int(p * 100))%")
            })
            logDebug("✅ Engine loaded successfully")
        } catch {
            logDebug("❌ Failed to load engine: \(error)")
        }
    }

    func transcribe() {
        guard let audioURL = tempAudioURL else { return }
        
        logDebug("🚀 Starting transcription...")
        logDebug("📁 Audio file: \(audioURL.path)")
        logDebug("⚙️ Language: \(config.language)")
        logDebug("🧠 Engine: \(config.engineType.displayName)")
        
        if let engine = activeEngine, engine.status.isLoaded {
            Task {
                do {
                    let text = try await engine.transcribe(audioURL: audioURL, language: config.language)
                    await handleTranscriptionResult(text)
                } catch {
                    logDebug("❌ Engine transcription failed: \(error)")
                    // Fallback to legacy whisper-cli
                    transcribeWithWhisperCli(audioURL: audioURL)
                }
            }
        } else {
            logDebug("⚠️ Engine not loaded, using legacy whisper-cli")
            transcribeWithWhisperCli(audioURL: audioURL)
        }
    }
    
    func transcribeWithWhisperCli(audioURL: URL) {
        logDebug("🛠 Using whisper-cli for transcription...")

        guard let whisperPath = getWhisperCliPath() else {
            logDebug("❌ Error: whisper-cli not found")
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
        
        logDebug("🛠 CLI Path: \(whisperPath)")
        
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // Check audio file size
            if let attrs = try? FileManager.default.attributesOfItem(atPath: audioURL.path) {
                let size = attrs[.size] as? Int64 ?? 0
                logDebug("🎙️ Audio file size: \(size) bytes")
            }
            
            // Optimal thread count: Target Performance Cores
            let perfCores = getPerformanceCoreCount()
            let usageThreads = perfCores > 0 ? perfCores : ProcessInfo.processInfo.processorCount
            logDebug("⚡ Using \(usageThreads) threads (Perf Cores) for low latency")
            
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
                "-t", String(usageThreads),     // Use Performance Cores
                "-bs", "2",                     // Beam size: 2 is sufficient for high quality dictation & fast speed
                "-bo", "0",                     // Best of: 0 (disabled) to rely on beam search (fastest)
                "-lpt", "-1.0",                 // Log probability threshold: relaxed (was -0.5)
                "--prompt", qualityPrompt,      // Language-specific context
                "-l", config.language
            ]
            
            logDebug("🏃 Running: \(cmd.joined(separator: " "))")
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: whisperPath)
            process.arguments = Array(cmd.dropFirst())
            
            // Fix library loading for packaged app by forcing DYLD_LIBRARY_PATH
            var env = ProcessInfo.processInfo.environment
            if let resourcePath = Bundle.main.resourcePath {
                let libPath = resourcePath + "/lib"
                env["DYLD_LIBRARY_PATH"] = libPath
                process.environment = env
                logDebug("🔧 Set DYLD_LIBRARY_PATH: \(libPath)")
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
                
                if !output.isEmpty { logDebug("📤 STDOUT:\n\(output)") }
                if !errorOutput.isEmpty { logDebug("⚠️ STDERR:\n\(errorOutput)") }
                
                let text = parseWhisperOutput(output)
                
                DispatchQueue.main.async {
                    if !text.isEmpty {
                        logDebug("✅ Transcription successful: \(text)")
                        
                        // Copy to clipboard
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        
                        // Update UI immediately on main thread
                        self.updateStatusMenuItem("Ready")
                        self.floatingIndicator.setState(.idle)
                        
                        // Auto-paste if enabled — run off main thread to avoid blocking UI with usleep
                        if self.config.autoPaste {
                            let targetApp = self.lastActiveApplication
                            DispatchQueue.global(qos: .userInitiated).async {
                                Thread.sleep(forTimeInterval: 0.010) // 10ms clipboard settle
                                if let app = targetApp {
                                    logDebug("📋 Pasting to \(app.localizedName ?? "Unknown") with fallback strategies")
                                    self.pasteWithFallback(text: text, targetApp: app)
                                } else {
                                    logDebug("📋 Pasting blindly (No tracked app)")
                                    self.pasteWithFallback(text: text, targetApp: nil)
                                }
                            }
                        }
                    } else {
                        logDebug("❓ No text detected in transcription")
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
                logDebug("💀 Fatal error in transcription: \(error)")
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
    
    @MainActor
    func handleTranscriptionResult(_ text: String) async {
        if !text.isEmpty {
            let transcriptionDoneTime = CFAbsoluteTimeGetCurrent()
            let latency = transcriptionStartTime != nil ? (transcriptionDoneTime - transcriptionStartTime!) : 0
            logDebug("✅ Transcription successful (\(String(format: "%.3f", latency))s): \(text)")
            
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            
            // Update UI immediately on main thread (don't block for paste)
            updateStatusMenuItem("Ready")
            floatingIndicator.setState(.idle)
            
            if config.autoPaste {
                let targetApp = lastActiveApplication
                // Move paste operations (which use usleep) off the main thread
                // to avoid blocking the UI and the run loop.
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    Thread.sleep(forTimeInterval: 0.003) // 3ms clipboard settle
                    if let app = targetApp {
                        logDebug("📋 Pasting to \(app.localizedName ?? "Unknown") with fallback strategies")
                        self.pasteWithFallback(text: text, targetApp: app)
                    } else {
                        logDebug("📋 Pasting blindly (No tracked app)")
                        self.pasteWithFallback(text: text, targetApp: nil)
                    }
                }
            }
        } else {
            logDebug("❓ No text detected in transcription")
            updateStatusMenuItem("No text")
            floatingIndicator.setState(.idle)
        }
        
        if let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Local Whisper") {
            image.isTemplate = true
            statusItem.button?.image = image
        }
        
        if let url = tempAudioURL {
            try? FileManager.default.removeItem(at: url)
        }
        tempAudioURL = nil
    }
    
    func parseWhisperOutput(_ output: String) -> String {
        var lines: [String] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            
            // Filter out common hallucinations or "blank audio" markers
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
    
    // MARK: - Launch at Login
    
    func updateLaunchAtLogin() {
        let label = "com.nicorosaless.LocalWhisper"
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let launchAgentDir = homeDir.appendingPathComponent("Library/LaunchAgents")
        let plistURL = launchAgentDir.appendingPathComponent("\(label).plist")
        
        if config.launchAtLogin {
            logDebug("🚀 Ensuring Launch Agent exists...")
            
            // Ensure directory exists
            try? FileManager.default.createDirectory(at: launchAgentDir, withIntermediateDirectories: true)
            
            let executablePath = Bundle.main.executablePath ?? (Bundle.main.bundlePath + "/Contents/MacOS/LocalWhisper")
            
            let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(label)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(executablePath)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <false/>
                <key>ProcessType</key>
                <string>Interactive</string>
            </dict>
            </plist>
            """
            
            do {
                try plistContent.write(to: plistURL, atomically: true, encoding: .utf8)
                logDebug("✅ Launch Agent created/updated at \(plistURL.path)")
            } catch {
                logDebug("❌ Failed to create Launch Agent: \(error)")
            }
        } else {
            logDebug("🛑 Removing Launch Agent...")
            try? FileManager.default.removeItem(at: plistURL)
        }
    }
    
    
    // MARK: - Paste Strategies
    
    /// Strategy 1: CGEvent-based paste (Most reliable for Electron apps, browsers)
    func pasteViaCGEvent(targetApp: NSRunningApplication?) -> Bool {
        logDebug("🎯 Attempting Targeted CGEvent paste...")
        
        // 1. Activation & Verification
        if let app = targetApp {
            logDebug("🎯 Targeting PID \(app.processIdentifier) (\(app.localizedName ?? "app"))")
            app.activate(options: [.activateAllWindows])
            
            // Wait for focus
            var attempts = 0
            while NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier && attempts < 10 {
                usleep(10000) // 10ms poll (was 20ms — app is pre-activated during transcription)
                attempts += 1
            }
            
            // Additional delay to ensure the field is focused
            usleep(UInt32(config.pasteDelay * 1000))
        }
        
        let eventSource = CGEventSource(stateID: .combinedSessionState)
        let targetPID = targetApp?.processIdentifier
        
        // Full sequence: Cmd Down -> V Down -> V Up -> Cmd Up
        guard let cmdDown = CGEvent(keyboardEventSource: eventSource, virtualKey: 0x37, keyDown: true) else { return false }
        cmdDown.flags = .maskCommand
        
        guard let vDown = CGEvent(keyboardEventSource: eventSource, virtualKey: 0x09, keyDown: true) else { return false }
        vDown.flags = .maskCommand
        
        guard let vUp = CGEvent(keyboardEventSource: eventSource, virtualKey: 0x09, keyDown: false) else { return false }
        vUp.flags = .maskCommand
        
        guard let cmdUp = CGEvent(keyboardEventSource: eventSource, virtualKey: 0x37, keyDown: false) else { return false }
        
        func post(_ event: CGEvent) {
            if let pid = targetPID {
                event.postToPid(pid)
            } else {
                event.post(tap: .cghidEventTap)
            }
            usleep(4000) // 4ms between key events (was 8ms)
        }
        
        post(cmdDown)
        post(vDown)
        post(vUp)
        post(cmdUp)
        
        logDebug("✅ CGEvent paste sequence completed")
        return true
    }

    func pasteViaCGEventGlobal() -> Bool {
        let eventSource = CGEventSource(stateID: .combinedSessionState)
        guard let vDown = CGEvent(keyboardEventSource: eventSource, virtualKey: 0x09, keyDown: true) else { return false }
        vDown.flags = .maskCommand
        guard let vUp = CGEvent(keyboardEventSource: eventSource, virtualKey: 0x09, keyDown: false) else { return false }
        vUp.flags = .maskCommand
        
        vDown.post(tap: .cghidEventTap)
        usleep(8000)
        vUp.post(tap: .cghidEventTap)
        
        logDebug("✅ Global CGEvent paste posted")
        return true
    }
    
    /// Strategy 2: Enhanced AppleScript with configurable delay
    func pasteViaAppleScriptDelayed(targetApp: NSRunningApplication?) -> Bool {
        logDebug("🎯 Attempting AppleScript+Delay paste...")
        
        var scriptSource: String
        let delay = Double(config.pasteDelay) / 1000.0 // Convert ms to seconds
        
        if let pid = targetApp?.processIdentifier {
            scriptSource = """
            tell application "System Events"
                set proc to (first process whose unix id is \(pid))
                set frontmost of proc to true
                delay \(delay)
                keystroke "v" using command down
            end tell
            """
        } else {
            scriptSource = """
            tell application "System Events"
                delay \(delay)
                keystroke "v" using command down
            end tell
            """
        }
        
        if let script = NSAppleScript(source: scriptSource) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if let error = error {
                logDebug("❌ AppleScript Error: \(error)")
                return false
            }
            logDebug("✅ AppleScript paste executed")
            return true
        }
        
        return false
    }
    
    /// Strategy 3: Enhanced Accessibility API injection
    func pasteViaAccessibility(_ text: String) -> Bool {
        logDebug("🎯 Attempting Accessibility API paste...")
        
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        
        let code = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        
        guard code == .success, let element = focusedElement else {
            logDebug("❌ AX: Could not get focused element")
            return false
        }
        
        let axElement = element as! AXUIElement
        
        // Strategy A: Try Setting Selected Text (Standard fields)
        var isSettable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(axElement, kAXSelectedTextAttribute as CFString, &isSettable)
        if isSettable.boolValue {
            let setErr = AXUIElementSetAttributeValue(axElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
            if setErr == .success {
                logDebug("✅ AX: Text inserted via AXSelectedText")
                return true
            }
        }
        
        // Strategy B: Try Perform Action "AXPaste" (The "Magic" button)
        // Some apps support a direct paste command on the element
        var actions: CFArray?
        AXUIElementCopyActionNames(axElement, &actions)
        if let actionsArray = actions as? [String], actionsArray.contains("AXPaste") {
            logDebug("✨ AX: Found AXPaste action, trying it...")
            // We need to have the text in clipboard already (which we do)
            let actErr = AXUIElementPerformAction(axElement, "AXPaste" as CFString)
            if actErr == .success {
                logDebug("✅ AX: Successful via AXPaste action")
                return true
            }
        }
        
        // Strategy C: Try AXValue (fallback for simpler fields)
        AXUIElementIsAttributeSettable(axElement, kAXValueAttribute as CFString, &isSettable)
        if isSettable.boolValue {
            var currentValue: AnyObject?
            AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &currentValue)
            let current = currentValue as? String ?? ""
            let newValue = current + text
            let setErr = AXUIElementSetAttributeValue(axElement, kAXValueAttribute as CFString, newValue as CFTypeRef)
            if setErr == .success {
                logDebug("✅ AX: Text inserted via AXValue")
                return true
            }
        }
        
        logDebug("❌ AX: No working strategy found for this element")
        return false
    }
    
    /// Strategy 4: Character-by-character typing simulation (slowest but most compatible)
    func pasteViaTyping(_ text: String, targetApp: NSRunningApplication?) -> Bool {
        logDebug("🎯 Attempting Targeted character typing...")
        
        let targetPID: pid_t? = targetApp?.processIdentifier
        if let app = targetApp {
            logDebug("🎯 Targeting PID \(app.processIdentifier) for typing")
            app.activate(options: [.activateAllWindows])
            usleep(UInt32(config.pasteDelay * 1000))
        }
        
        let eventSource = CGEventSource(stateID: .combinedSessionState)
        
        for char in text {
            let nsChar = String(char) as NSString
            if nsChar.length > 0 {
                let unichar = nsChar.character(at: 0)
                
                if let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true),
                   let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) {
                    
                    keyDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: [unichar])
                    keyUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: [unichar])
                    
                    if let pid = targetPID {
                        keyDown.postToPid(pid)
                        usleep(5000)
                        keyUp.postToPid(pid)
                    } else {
                        keyDown.post(tap: .cghidEventTap)
                        usleep(5000)
                        keyUp.post(tap: .cghidEventTap)
                    }
                    usleep(10000)
                }
            }
        }
        
        logDebug("✅ Targeted typing complete")
        return true
    }
    
    /// Main orchestrator: try strategies based on config and fallback as needed
    func pasteWithFallback(text: String, targetApp: NSRunningApplication?) {
        logDebug("📋 Starting paste with method: \(config.preferredPasteMethod.displayName)")
        
        // Ensure we are not the target
        let finalTarget: NSRunningApplication?
        if let app = targetApp, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            finalTarget = app
        } else {
            // If we don't have a target, or it's us, don't paste
            logDebug("⚠️ No valid target app (or target is us). Skipping paste.")
            return
        }
        
        // 1. FORCED ACTIVATION
        logDebug("🚀 Activating target app: \(finalTarget?.localizedName ?? "Unknown")")
        finalTarget?.activate(options: [.activateAllWindows])
        
        // 2. Wait for focus to settle
        usleep(15000) // 15ms baseline delay (was 50ms — target app is pre-activated during transcription)
        
        let strategies: [(String, () -> Bool)]
        
        switch config.preferredPasteMethod {
        case .auto:
            // NEW ORDER: CGEvent -> AppleScript -> Accessibility -> Typing
            // CGEvent is best for Electron/Browsers.
            // AppleScript is a robust secondary for system apps.
            // Accessibility is now a fallback due to false positives in Electron.
            strategies = [
                ("CGEvent", { self.pasteViaCGEvent(targetApp: finalTarget) }),
                ("AppleScript+Delay", { self.pasteViaAppleScriptDelayed(targetApp: finalTarget) }),
                ("Accessibility", { self.pasteViaAccessibility(text) }),
                ("Typing", { self.pasteViaTyping(text, targetApp: finalTarget) })
            ]
        case .cgEvent:
            strategies = [("CGEvent", { self.pasteViaCGEvent(targetApp: targetApp) })]
        case .appleScript:
            strategies = [("AppleScript+Delay", { self.pasteViaAppleScriptDelayed(targetApp: targetApp) })]
        case .accessibility:
            strategies = [("Accessibility", { self.pasteViaAccessibility(text) })]
        case .typing:
            strategies = [("Typing", { self.pasteViaTyping(text, targetApp: targetApp) })]
        }
        
        // Execute strategies
        for (name, strategy) in strategies {
            logDebug("🔄 Trying strategy: \(name)")
            if strategy() {
                let finalDoneTime = CFAbsoluteTimeGetCurrent()
                let totalLatency = transcriptionStartTime != nil ? (finalDoneTime - transcriptionStartTime!) : 0
                logDebug("✅ Paste successful with: \(name). Total E2E latency: \(String(format: "%.3f", totalLatency))s")
                return
            }
            logDebug("⚠️ Strategy \(name) failed, trying next...")
        }
        
        logDebug("❌ All paste strategies failed")
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
