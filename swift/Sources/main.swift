import Cocoa
import Carbon.HIToolbox
import AVFoundation
import SwiftUI

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
    var pressedModifiers: NSEvent.ModifierFlags = []
    var hotkeyKeyPressed = false
    
    // Audio level timer
    var audioLevelTimer: Timer?
    
    // Config
    var config: AppConfig = .defaultConfig
    let appDir: String
    
    override init() {
        // Get the base directory (parent of swift/)
        let currentPath = FileManager.default.currentDirectoryPath
        if currentPath.hasSuffix("/swift") {
            appDir = (currentPath as NSString).deletingLastPathComponent
        } else {
            appDir = currentPath
        }
        
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
        // Check if onboarding is complete
        let onboardingComplete = UserDefaults.standard.bool(forKey: "onboardingComplete")
        
        if !onboardingComplete {
            showOnboarding()
            return
        }
        
        startApp()
    }
    
    func showOnboarding() {
        onboardingController = OnboardingWindowController()
        onboardingController?.onComplete = { [weak self] in
            // Delay to allow window to close properly
            DispatchQueue.main.async {
                self?.onboardingController = nil
                self?.startApp()
            }
        }
        
        // Create bindings with explicit capture
        let hotkeyBinding = Binding<HotkeyConfig>(
            get: { [weak self] in self?.config.hotkey ?? .defaultConfig },
            set: { [weak self] in self?.config.hotkey = $0 }
        )
        let modeBinding = Binding<HotkeyMode>(
            get: { [weak self] in self?.config.hotkeyMode ?? .pushToTalk },
            set: { [weak self] in self?.config.hotkeyMode = $0 }
        )
        
        onboardingController?.show(hotkeyConfig: hotkeyBinding, hotkeyMode: modeBinding)
    }
    
    func startApp() {
        // Update model path to use downloaded model
        if ModelDownloader.shared.isModelDownloaded() {
            config.modelPath = ModelDownloader.shared.getModelPath()
        }
        
        // Load language from UserDefaults
        if let lang = UserDefaults.standard.string(forKey: "language") {
            config.language = lang
        }
        
        saveConfig()
        
        // Create floating indicator
        floatingIndicator = FloatingIndicatorWindow()
        floatingIndicator.hotkeyDisplayString = config.hotkey.displayString
        floatingIndicator.orderFront(nil)
        
        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎤"
        
        // Create menu
        updateMenu()
        
        // Setup global hotkey monitor
        setupHotkeyMonitor()
        
        print("WhisperMac Swift iniciado.")
        print("Modelo: \(modelPath)")
        print("Hotkey: \(config.hotkey.displayString) (\(config.hotkeyMode.displayName))")
    }
    
    func updateMenu() {
        let menu = NSMenu()
        
        let statusMenuItem = NSMenuItem(title: "Estado: Listo", action: nil, keyEquivalent: "")
        statusMenuItem.tag = 100
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())
        
        menu.addItem(NSMenuItem(title: "Idioma: \(config.language)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Hotkey: \(config.hotkey.displayString)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Modo: \(config.hotkeyMode.displayName)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        
        let prefsItem = NSMenuItem(title: "Preferencias...", action: #selector(openSettings), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Salir", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }
    
    func updateStatusMenuItem(_ text: String) {
        if let item = statusItem.menu?.item(withTag: 100) {
            item.title = "Estado: \(text)"
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
        
        // Monitor modifier flags
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.pressedModifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            self?.checkHotkey()
        }
        
        // Monitor key down
        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return }
            if event.keyCode == self.config.hotkey.keyCode {
                self.hotkeyKeyPressed = true
                self.checkHotkey()
            }
        }
        
        // Monitor key up
        keyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self = self else { return }
            if event.keyCode == self.config.hotkey.keyCode {
                self.hotkeyKeyPressed = false
                
                // For push-to-talk mode, stop recording on key release
                if self.config.hotkeyMode == .pushToTalk && self.isRecording {
                    self.stopRecording()
                }
            }
        }
    }
    
    func checkHotkey() {
        let modifiersMatch = checkModifiersMatch()
        
        if modifiersMatch && hotkeyKeyPressed {
            switch config.hotkeyMode {
            case .pushToTalk:
                if !isRecording {
                    startRecording()
                }
            case .toggle:
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
                // Reset to prevent multiple toggles from held key
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
        isRecording = true
        
        DispatchQueue.main.async {
            self.statusItem.button?.title = "🔴"
            self.updateStatusMenuItem("Grabando...")
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
            
            print("Grabando...")
        } catch {
            print("Error al grabar: \(error)")
            isRecording = false
            statusItem.button?.title = "🎤"
            floatingIndicator.setState(.idle)
        }
    }
    
    func startAudioLevelMonitoring() {
        audioLevelTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            guard let self = self, let recorder = self.audioRecorder, recorder.isRecording else { return }
            
            recorder.updateMeters()
            let power = recorder.averagePower(forChannel: 0)
            // Convert dB to 0-1 range (dB typically ranges from -160 to 0)
            let normalizedLevel = max(0, (power + 50) / 50)
            self.floatingIndicator.updateAudioLevel(normalizedLevel)
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
            self.statusItem.button?.title = "⏳"
            self.updateStatusMenuItem("Transcribiendo...")
            self.floatingIndicator.setState(.transcribing)
        }
        
        print("Grabación terminada.")
        
        // Transcribe
        transcribe()
    }
    
    func transcribe() {
        guard let audioURL = tempAudioURL else { return }
        
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let cmd = [
                "/opt/homebrew/bin/whisper-cli",
                "-m", modelPath,
                "-f", audioURL.path,
                "-nt",          // No timestamps
                "-t", "8",      // Threads
                "-bs", "2",     // Beam size
                "-bo", "2",     // Best of
                "-l", config.language
            ]
            
            print("Ejecutando: \(cmd.joined(separator: " "))")
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli")
            process.arguments = Array(cmd.dropFirst())
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            
            do {
                try process.run()
                process.waitUntilExit()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                
                // Parse output
                let text = parseWhisperOutput(output)
                
                DispatchQueue.main.async {
                    if !text.isEmpty {
                        print("Transcripción: \(text)")
                        
                        // Copy to clipboard
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        
                        // Auto-paste if enabled
                        if self.config.autoPaste {
                            self.simulatePaste()
                        }
                        
                        self.updateStatusMenuItem("Listo")
                        self.floatingIndicator.setState(.idle)
                    } else {
                        print("No se detectó texto")
                        self.updateStatusMenuItem("Sin texto")
                        self.floatingIndicator.setState(.idle)
                    }
                    
                    self.statusItem.button?.title = "🎤"
                }
                
                // Cleanup
                try? FileManager.default.removeItem(at: audioURL)
                
            } catch {
                print("Error en transcripción: \(error)")
                DispatchQueue.main.async {
                    self.statusItem.button?.title = "❌"
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
app.setActivationPolicy(.accessory) // Menu bar app, no dock icon
app.run()
