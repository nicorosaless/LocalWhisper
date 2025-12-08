import Cocoa
import Carbon.HIToolbox
import AVFoundation

// MARK: - AppDelegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var audioRecorder: AVAudioRecorder?
    var isRecording = false
    var tempAudioURL: URL?
    
    // Hotkey monitor
    var eventMonitor: Any?
    var pressedModifiers: NSEvent.ModifierFlags = []
    var spacePressed = false
    
    // Config
    let modelPath: String
    let language: String
    
    override init() {
        // Get the base directory (parent of swift/)
        let currentPath = FileManager.default.currentDirectoryPath
        let appDir: String
        if currentPath.hasSuffix("/swift") {
            appDir = (currentPath as NSString).deletingLastPathComponent
        } else {
            appDir = currentPath
        }
        
        let configPath = "\(appDir)/config.json"
        
        if let data = FileManager.default.contents(atPath: configPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let modelName = json["model_path"] as? String ?? "models/ggml-small.bin"
            self.modelPath = "\(appDir)/\(modelName)"
            self.language = json["language"] as? String ?? "es"
        } else {
            self.modelPath = "\(appDir)/models/ggml-small.bin"
            self.language = "es"
        }
        
        print("Modelo: \(modelPath)")
        
        super.init()
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎤"
        
        // Create menu
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Estado: Listo", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Modelo: small", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Hotkey: ⌘⇧Space (mantener)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Salir", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
        
        // Setup global hotkey monitor
        setupHotkeyMonitor()
        
        print("WhisperMac Swift iniciado. Mantén Cmd+Shift+Space para dictar.")
    }
    
    func setupHotkeyMonitor() {
        // Monitor key down
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.pressedModifiers = event.modifierFlags.intersection([.command, .shift])
            self?.checkHotkey()
        }
        
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 49 { // Space
                self?.spacePressed = true
                self?.checkHotkey()
            }
        }
        
        NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            if event.keyCode == 49 { // Space
                self?.spacePressed = false
                if self?.isRecording == true {
                    self?.stopRecording()
                }
            }
        }
    }
    
    func checkHotkey() {
        let cmdShiftPressed = pressedModifiers.contains([.command, .shift])
        
        if cmdShiftPressed && spacePressed && !isRecording {
            startRecording()
        }
    }
    
    func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        
        DispatchQueue.main.async {
            self.statusItem.button?.title = "🔴"
            self.statusItem.menu?.item(at: 0)?.title = "Estado: Grabando..."
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
            audioRecorder?.record()
            print("Grabando...")
        } catch {
            print("Error al grabar: \(error)")
            isRecording = false
            statusItem.button?.title = "🎤"
        }
    }
    
    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        
        audioRecorder?.stop()
        audioRecorder = nil
        
        DispatchQueue.main.async {
            self.statusItem.button?.title = "⏳"
            self.statusItem.menu?.item(at: 0)?.title = "Estado: Transcribiendo..."
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
                "-l", language
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
                        
                        // Simulate Cmd+V paste
                        self.simulatePaste()
                        
                        self.statusItem.menu?.item(at: 0)?.title = "Estado: Listo"
                    } else {
                        print("No se detectó texto")
                        self.statusItem.menu?.item(at: 0)?.title = "Estado: Sin texto"
                    }
                    
                    self.statusItem.button?.title = "🎤"
                }
                
                // Cleanup
                try? FileManager.default.removeItem(at: audioURL)
                
            } catch {
                print("Error en transcripción: \(error)")
                DispatchQueue.main.async {
                    self.statusItem.button?.title = "❌"
                    self.statusItem.menu?.item(at: 0)?.title = "Estado: Error"
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
