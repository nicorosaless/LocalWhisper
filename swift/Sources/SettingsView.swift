import SwiftUI
import Carbon.HIToolbox

// MARK: - Hotkey Mode
enum HotkeyMode: String, CaseIterable, Codable {
    case pushToTalk = "push_to_talk"
    case toggle = "toggle"
    
    var displayName: String {
        switch self {
        case .pushToTalk: return "Push to Talk (mantener)"
        case .toggle: return "Toggle (pulsar)"
        }
    }
}

// MARK: - Hotkey Configuration
struct HotkeyConfig: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: [String]
    
    static let defaultConfig = HotkeyConfig(keyCode: 49, modifiers: ["cmd", "shift"]) // Space
    
    var displayString: String {
        var parts: [String] = []
        if modifiers.contains("cmd") { parts.append("⌘") }
        if modifiers.contains("ctrl") { parts.append("⌃") }
        if modifiers.contains("alt") { parts.append("⌥") }
        if modifiers.contains("shift") { parts.append("⇧") }
        parts.append(keyCodeToString(keyCode))
        return parts.joined()
    }
    
    private func keyCodeToString(_ keyCode: UInt16) -> String {
        switch keyCode {
        case 49: return "Space"
        case 36: return "↵"
        case 48: return "⇥"
        case 51: return "⌫"
        case 53: return "⎋"
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 31: return "O"
        case 32: return "U"
        case 34: return "I"
        case 35: return "P"
        case 37: return "L"
        case 38: return "J"
        case 40: return "K"
        case 45: return "N"
        case 46: return "M"
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
    
    static let defaultConfig = AppConfig(
        language: "es",
        hotkey: .defaultConfig,
        hotkeyMode: .pushToTalk,
        autoPaste: true,
        modelPath: "models/ggml-small.bin"
    )
    
    enum CodingKeys: String, CodingKey {
        case language
        case hotkey
        case hotkeyMode = "hotkey_mode"
        case autoPaste = "auto_paste"
        case modelPath = "model_path"
    }
}

// MARK: - Languages
struct Language: Identifiable, Hashable {
    let id: String
    let name: String
    
    static let all: [Language] = [
        Language(id: "auto", name: "Auto-detectar"),
        Language(id: "es", name: "Español"),
        Language(id: "en", name: "English"),
        Language(id: "fr", name: "Français"),
        Language(id: "de", name: "Deutsch"),
        Language(id: "it", name: "Italiano"),
        Language(id: "pt", name: "Português"),
        Language(id: "zh", name: "中文"),
        Language(id: "ja", name: "日本語"),
        Language(id: "ko", name: "한국어"),
        Language(id: "ru", name: "Русский"),
        Language(id: "ar", name: "العربية"),
    ]
}

// MARK: - Hotkey Recorder View
struct HotkeyRecorderView: NSViewRepresentable {
    @Binding var hotkey: HotkeyConfig
    @Binding var isRecording: Bool
    
    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.onHotkeyRecorded = { keyCode, modifiers in
            hotkey = HotkeyConfig(keyCode: keyCode, modifiers: modifiers)
            isRecording = false
        }
        return view
    }
    
    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        nsView.isRecordingHotkey = isRecording
        nsView.currentHotkey = hotkey
        nsView.needsDisplay = true
    }
}

class HotkeyRecorderNSView: NSView {
    var isRecordingHotkey = false
    var currentHotkey: HotkeyConfig = .defaultConfig
    var onHotkeyRecorded: ((UInt16, [String]) -> Void)?
    
    override var acceptsFirstResponder: Bool { true }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        let bgColor = isRecordingHotkey 
            ? NSColor.controlAccentColor.withAlphaComponent(0.2)
            : NSColor.controlBackgroundColor
        bgColor.setFill()
        
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        path.fill()
        
        // Border
        let borderColor = isRecordingHotkey ? NSColor.controlAccentColor : NSColor.separatorColor
        borderColor.setStroke()
        path.lineWidth = 1.5
        path.stroke()
        
        // Text
        let text = isRecordingHotkey ? "Presiona teclas..." : currentHotkey.displayString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let size = text.size(withAttributes: attrs)
        let point = NSPoint(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2
        )
        text.draw(at: point, withAttributes: attrs)
    }
    
    override func mouseDown(with event: NSEvent) {
        isRecordingHotkey = true
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
    
    override func keyDown(with event: NSEvent) {
        guard isRecordingHotkey else {
            super.keyDown(with: event)
            return
        }
        
        var modifiers: [String] = []
        if event.modifierFlags.contains(.command) { modifiers.append("cmd") }
        if event.modifierFlags.contains(.control) { modifiers.append("ctrl") }
        if event.modifierFlags.contains(.option) { modifiers.append("alt") }
        if event.modifierFlags.contains(.shift) { modifiers.append("shift") }
        
        // Local function to check for F-keys
        let isFunctionKey = (event.keyCode == 122 || event.keyCode == 120 || event.keyCode == 99 || 
                           event.keyCode == 118 || event.keyCode == 96 || event.keyCode == 97 || 
                           event.keyCode == 98 || event.keyCode == 100 || event.keyCode == 101 || 
                           event.keyCode == 109 || event.keyCode == 103 || event.keyCode == 111)

        // Require at least one modifier OR it's a function key
        if !modifiers.isEmpty || isFunctionKey {
            onHotkeyRecorded?(event.keyCode, modifiers)
        }
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @State var config: AppConfig
    @State private var isRecordingHotkey = false
    var onSave: (AppConfig) -> Void
    var onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "mic.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text("WhisperMac")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Settings Form
            Form {
                // Language Section
                Section {
                    Picker("Idioma", selection: $config.language) {
                        ForEach(Language.all) { lang in
                            Text(lang.name).tag(lang.id)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Label("Transcripción", systemImage: "text.bubble")
                }
                
                // Hotkey Section
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Atajo de teclado")
                            Spacer()
                            HotkeyRecorderView(hotkey: $config.hotkey, isRecording: $isRecordingHotkey)
                                .frame(width: 140, height: 32)
                        }
                        
                        Picker("Modo", selection: $config.hotkeyMode) {
                            ForEach(HotkeyMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                } header: {
                    Label("Hotkey", systemImage: "keyboard")
                }
                
                // Options Section
                Section {
                    Toggle("Auto-pegar transcripción", isOn: $config.autoPaste)
                } header: {
                    Label("Opciones", systemImage: "gearshape")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 280)
            
            Divider()
            
            // Footer Buttons
            HStack {
                Button("Cancelar") {
                    onCancel()
                }
                .keyboardShortcut(.escape)
                
                Spacer()
                
                Button("Guardar") {
                    onSave(config)
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 500, height: 420)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Settings Window Controller
class SettingsWindowController: NSWindowController {
    convenience init(config: AppConfig, onSave: @escaping (AppConfig) -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "WhisperMac Preferencias"
        window.center()
        
        self.init(window: window)
        
        let settingsView = SettingsView(
            config: config,
            onSave: { [weak self] newConfig in
                print("Settings: Guardando configuración...")
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
