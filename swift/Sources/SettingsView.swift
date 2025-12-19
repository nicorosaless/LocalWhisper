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
    var keyCharacter: String?  // Store the actual character for display
    
    static let defaultConfig = HotkeyConfig(keyCode: 49, modifiers: ["cmd", "shift"], keyCharacter: "Space")
    
    var displayString: String {
        var parts: [String] = []
        if modifiers.contains("cmd") { parts.append("⌘") }
        if modifiers.contains("ctrl") { parts.append("⌃") }
        if modifiers.contains("alt") { parts.append("⌥") }
        if modifiers.contains("shift") { parts.append("⇧") }
        
        // Use stored character if available, otherwise fall back to keyCode mapping
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
    
    // Event monitors
    private var localMonitor: Any?
    private var clickMonitor: Any?
    private var globalClickMonitor: Any?
    
    // UI Elements
    private let label: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 14, weight: .semibold)
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
        layer?.cornerRadius = 8
        
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
        // Update label text
        if isRecordingHotkey {
            label.stringValue = "Presiona una tecla..."
        } else {
            label.stringValue = currentHotkey.displayString
        }
        
        // Trigger background redraw
        needsDisplay = true
    }
    
    private func startMonitoring() {
        stopMonitoring()
        
        // Monitor for key presses to record the hotkey
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self, self.isRecordingHotkey else { return event }
            
            var modifiers: [String] = []
            if event.modifierFlags.contains(.command) { modifiers.append("cmd") }
            if event.modifierFlags.contains(.control) { modifiers.append("ctrl") }
            if event.modifierFlags.contains(.option) { modifiers.append("alt") }
            if event.modifierFlags.contains(.shift) { modifiers.append("shift") }
            
            // Escape cancels recording
            if event.keyCode == 53 {
                self.coordinator?.cancelRecording()
                return nil
            }
            
            // Get the actual character from the keyboard
            var keyChar: String? = nil
            
            // Special keys that don't have printable characters
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
                // Get the actual character from the event (respects keyboard layout)
                if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
                    keyChar = chars.uppercased()
                }
            }
            
            // Record the hotkey with the actual character
            self.coordinator?.hotkeyRecorded(keyCode: event.keyCode, modifiers: modifiers, keyCharacter: keyChar)
            return nil // Consume the event
        }
        
        // 1. Local Monitor: Clicks *inside* the application that are *outside* our view
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, self.isRecordingHotkey else { return event }
            
            let pointInView = self.convert(event.locationInWindow, from: nil)
            if !self.bounds.contains(pointInView) {
                DispatchQueue.main.async { self.coordinator?.cancelRecording() }
            }
            return event
        }
        
        // 2. Global Monitor: Clicks *outside* the application window
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, self.isRecordingHotkey else { return }
            DispatchQueue.main.async { self.coordinator?.cancelRecording() }
        }
        
        // 3. Window Resignation: If the window loses focus (e.g. cmd+tab)
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
        
        // Dark theme background
        let bgColor = isRecordingHotkey 
            ? NSColor(red: 0.4, green: 0.2, blue: 0.6, alpha: 0.4)
            : NSColor(red: 0.15, green: 0.15, blue: 0.2, alpha: 1.0)
        bgColor.setFill()
        
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        path.fill()
        
        // Border
        let borderColor = isRecordingHotkey 
            ? NSColor(red: 0.7, green: 0.4, blue: 1.0, alpha: 1.0) 
            : NSColor(white: 0.3, alpha: 1.0)
        borderColor.setStroke()
        path.lineWidth = 2
        path.stroke()
        
        // Text is handled by NSTextField (label)
    }
    
    override func mouseDown(with event: NSEvent) {
        if !isRecordingHotkey {
            coordinator?.startRecording()
        }
        window?.makeFirstResponder(self)
    }
}

// MARK: - Settings View
// MARK: - Settings View
struct SettingsView: View {
    @State var config: AppConfig
    @State private var isRecordingHotkey = false
    var onSave: (AppConfig) -> Void
    var onCancel: () -> Void
    
    // Theme colors
    private let themePurple = Color(red: 0.6, green: 0.2, blue: 0.9)
    private let themePurpleLight = Color(red: 0.7, green: 0.4, blue: 1.0)
    private let themeDark = Color(red: 0.08, green: 0.08, blue: 0.12)
    private let themeDarkSecondary = Color(red: 0.12, green: 0.12, blue: 0.18)
    
    // Button States
    @State private var isHoveringSave = false
    @State private var isHoveringCancel = false
    
    var body: some View {
        ZStack {
            // Background gradient (matching Onboarding)
            LinearGradient(
                colors: [themeDark, Color(red: 0.1, green: 0.05, blue: 0.2)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack(spacing: 16) {
                    ZStack {
                        // Header icon glow
                        Circle()
                            .fill(LinearGradient(colors: [themePurple.opacity(0.3), themePurpleLight.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 48, height: 48)
                            .blur(radius: 12)
                        
                        Image(systemName: "waveform")
                            .font(.system(size: 24))
                            .foregroundStyle(LinearGradient(colors: [themePurple, themePurpleLight], startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                    
                    Text("Preferencias")
                        .font(.title2.bold())
                        .foregroundColor(.white)
                    
                    Spacer()
                }
                .padding(.horizontal, 30)
                .padding(.top, 30)
                .padding(.bottom, 20)
                
                // Settings content
                ScrollView {
                    VStack(spacing: 24) {
                        // Language Section
                        settingsSection(title: "Transcripción", icon: "text.bubble.fill") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Idioma")
                                    .font(.subheadline)
                                    .foregroundColor(.white.opacity(0.7))
                                
                                Picker("", selection: $config.language) {
                                    ForEach(Language.all) { lang in
                                        Text(lang.name).tag(lang.id)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                                .tint(themePurpleLight)
                            }
                        }
                        
                        // Hotkey Section
                        settingsSection(title: "Atajo de teclado", icon: "keyboard.fill") {
                            VStack(spacing: 20) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Hotkey")
                                            .font(.subheadline)
                                            .foregroundColor(.white.opacity(0.7))
                                        Text("Pulsa para grabar nuevo atajo")
                                            .font(.caption)
                                            .foregroundColor(.white.opacity(0.4))
                                    }
                                    Spacer()
                                    HotkeyRecorderView(hotkey: $config.hotkey, isRecording: $isRecordingHotkey)
                                        .frame(width: 180, height: 44)
                                }
                                
                                Divider().background(Color.white.opacity(0.1))
                                
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Modo de activación")
                                        .font(.subheadline)
                                        .foregroundColor(.white.opacity(0.7))
                                    
                                    HStack(spacing: 12) {
                                        modeButton(mode: .pushToTalk, title: "Mantener", icon: "hand.raised.fill")
                                        modeButton(mode: .toggle, title: "Pulsar", icon: "power")
                                    }
                                }
                            }
                        }
                        
                        // Options Section
                        settingsSection(title: "Opciones", icon: "gearshape.fill") {
                            Toggle(isOn: $config.autoPaste) {
                                HStack {
                                    Image(systemName: "doc.on.clipboard")
                                        .foregroundColor(themePurpleLight)
                                    Text("Auto-pegar transcripción")
                                        .foregroundColor(.white)
                                }
                            }
                            .toggleStyle(SwitchToggleStyle(tint: themePurple))
                        }
                    }
                    .padding(.horizontal, 30)
                    .padding(.vertical, 10)
                }
                
                // Footer Buttons
                VStack(spacing: 0) {
                    Divider().background(Color.white.opacity(0.1))
                    
                    HStack(spacing: 16) {
                        Button(action: { onCancel() }) {
                            Text("Cancelar")
                                .font(.headline)
                                .foregroundColor(.white.opacity(0.7))
                                .frame(height: 44)
                                .padding(.horizontal, 24)
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(22)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.escape)
                        .onHover { isHoveringCancel = $0 }
                        .scaleEffect(isHoveringCancel ? 1.02 : 1.0)
                        .animation(.easeInOut(duration: 0.2), value: isHoveringCancel)
                        
                        Spacer()
                        
                        Button(action: { onSave(config) }) {
                            HStack(spacing: 8) {
                                Text("Guardar cambios")
                                Image(systemName: "checkmark")
                            }
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(height: 44)
                            .padding(.horizontal, 28)
                            .background(
                                LinearGradient(colors: [themePurple, themePurpleLight], startPoint: .leading, endPoint: .trailing)
                            )
                            .cornerRadius(22)
                            .shadow(color: themePurple.opacity(0.5), radius: 10, x: 0, y: 4)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.return)
                        .onHover { isHoveringSave = $0 }
                        .scaleEffect(isHoveringSave ? 1.02 : 1.0)
                        .animation(.easeInOut(duration: 0.2), value: isHoveringSave)
                    }
                    .padding(30)
                }
            }
        }
        .frame(width: 500, height: 700)
    }
    
    private func settingsSection<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(LinearGradient(colors: [themePurple, themePurpleLight], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)
            }
            .padding(.bottom, 4)
            
            content()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.03)) // Glassmorphism base
        .cornerRadius(20)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(LinearGradient(colors: [.white.opacity(0.1), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        )
    }
    
    private func modeButton(mode: HotkeyMode, title: String, icon: String) -> some View {
        Button(action: { config.hotkeyMode = mode }) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title3)
                Text(title)
                    .font(.caption.bold())
            }
            .foregroundColor(config.hotkeyMode == mode ? .white : .white.opacity(0.5))
            .frame(maxWidth: .infinity)
            .frame(height: 70)
            .background(
                config.hotkeyMode == mode 
                    ? LinearGradient(colors: [themePurple, themePurpleLight], startPoint: .topLeading, endPoint: .bottomTrailing)
                    : LinearGradient(colors: [Color.white.opacity(0.05), Color.white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(config.hotkeyMode == mode ? Color.white.opacity(0.2) : Color.clear, lineWidth: 1)
            )
            .shadow(color: config.hotkeyMode == mode ? themePurple.opacity(0.3) : .clear, radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: config.hotkeyMode)
    }
}

// MARK: - Settings Window Controller
class SettingsWindowController: NSWindowController {
    convenience init(config: AppConfig, onSave: @escaping (AppConfig) -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 625),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Preferencias"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.center()
        window.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)
        
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
