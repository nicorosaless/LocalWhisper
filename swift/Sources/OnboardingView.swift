import SwiftUI
import AVFoundation
import AppKit

// MARK: - Theme Colors
extension Color {
    static let themePurple = Color(red: 0.6, green: 0.2, blue: 0.9)
    static let themePurpleLight = Color(red: 0.7, green: 0.4, blue: 1.0)
    static let themeDark = Color(red: 0.08, green: 0.08, blue: 0.12)
    static let themeDarkSecondary = Color(red: 0.12, green: 0.12, blue: 0.18)
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
    @State private var selectedLanguage = "es"
    @State private var downloadProgress: Double = 0
    @State private var isDownloading = false
    @State private var downloadComplete = false
    @State private var microphoneGranted = false
    @State private var accessibilityGranted = false
    @State private var isRecordingHotkey = false
    @State private var onboardingDoneTriggered = false
    @State private var localHotkeyMode: HotkeyMode = .pushToTalk  // Local state for mode
    @State private var localHotkeyConfig: HotkeyConfig = .defaultConfig  // Local state for hotkey
    
    var initialHotkeyConfig: HotkeyConfig
    var initialHotkeyMode: HotkeyMode
    var onComplete: (HotkeyConfig, HotkeyMode) -> Void  // Pass both back on complete
    
    // Gradient background
    private var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [Color.themeDark, Color(red: 0.1, green: 0.05, blue: 0.2)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    
    var body: some View {
        ZStack {
            // Background
            backgroundGradient
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Progress indicator
                HStack(spacing: 12) {
                    ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                        Capsule()
                            .fill(step.rawValue <= currentStep.rawValue 
                                ? LinearGradient(colors: [.themePurple, .themePurpleLight], startPoint: .leading, endPoint: .trailing)
                                : LinearGradient(colors: [Color.white.opacity(0.2), Color.white.opacity(0.2)], startPoint: .leading, endPoint: .trailing))
                            .frame(width: step.rawValue == currentStep.rawValue ? 24 : 10, height: 10)
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
                
                // Navigation buttons
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
                                Text("Atrás")
                            }
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    Spacer()
                    
                    if currentStep == .done {
                        Button(action: {
                            if !onboardingDoneTriggered {
                                onboardingDoneTriggered = true
                                saveSettings()
                                onComplete(localHotkeyConfig, localHotkeyMode)
                            }
                        }) {
                            HStack(spacing: 8) {
                                Text("Empezar")
                                Image(systemName: "arrow.right")
                            }
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 12)
                            .background(
                                LinearGradient(colors: [.themePurple, .themePurpleLight], startPoint: .leading, endPoint: .trailing)
                            )
                            .cornerRadius(25)
                            .shadow(color: .themePurple.opacity(0.5), radius: 10, x: 0, y: 4)
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
                            .font(.headline)
                            .foregroundColor(canAdvance ? .white : .white.opacity(0.5))
                            .padding(.horizontal, 28)
                            .padding(.vertical, 12)
                            .background(
                                canAdvance 
                                    ? LinearGradient(colors: [.themePurple, .themePurpleLight], startPoint: .leading, endPoint: .trailing)
                                    : LinearGradient(colors: [.gray.opacity(0.3), .gray.opacity(0.3)], startPoint: .leading, endPoint: .trailing)
                            )
                            .cornerRadius(25)
                            .shadow(color: canAdvance ? .themePurple.opacity(0.5) : .clear, radius: 10, x: 0, y: 4)
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

    }
    
    private var nextButtonText: String {
        switch currentStep {
        case .permissions:
            return "Continuar"
        case .modelDownload:
            return downloadComplete ? "Continuar" : "Descargar"
        default:
            return "Continuar"
        }
    }
    
    private var canAdvance: Bool {
        switch currentStep {
        case .permissions:
            return microphoneGranted && accessibilityGranted
        case .modelDownload:
            return downloadComplete || ModelDownloader.shared.isModelDownloaded()
        default:
            return true
        }
    }
    
    private func advanceStep() {
        // Special handling for model download step
        if currentStep == .modelDownload && !downloadComplete && !ModelDownloader.shared.isModelDownloaded() {
            startDownload()
            return
        }
        
        if let next = OnboardingStep(rawValue: currentStep.rawValue + 1) {
            currentStep = next
        }
    }
    
    // MARK: - Permissions View
    private var permissionsView: some View {
        VStack(spacing: 24) {
            // Icon with glow
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.themePurple.opacity(0.3), .themePurpleLight.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 100, height: 100)
                    .blur(radius: 20)
                
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(LinearGradient(colors: [.themePurple, .themePurpleLight], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            
            Text("Permisos necesarios")
                .font(.title.bold())
                .foregroundColor(.white)
            
            Text("WhisperMac necesita acceso para funcionar correctamente.")
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.7))
                .padding(.horizontal, 40)
            
            VStack(spacing: 16) {
                permissionRow(
                    icon: "mic.fill",
                    title: "Micrófono",
                    subtitle: "Para capturar tu voz",
                    granted: microphoneGranted,
                    action: { requestMicrophoneAccess() }
                )
                
                permissionRow(
                    icon: "accessibility",
                    title: "Accesibilidad",
                    subtitle: "Para atajos globales",
                    granted: accessibilityGranted,
                    action: { openAccessibilitySettings() },
                    showSkip: true
                )
            }
            .padding(.horizontal, 30)
            
            if !microphoneGranted || !accessibilityGranted {
                Button(action: { checkPermissions() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text("Verificar permisos")
                    }
                    .font(.caption)
                    .foregroundColor(.themePurpleLight)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
        }
    }
    
    private func permissionRow(icon: String, title: String, subtitle: String, granted: Bool, action: @escaping () -> Void, showSkip: Bool = false) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(granted ? Color.green.opacity(0.2) : Color.themePurple.opacity(0.2))
                    .frame(width: 44, height: 44)
                
                Image(systemName: granted ? "checkmark" : icon)
                    .font(.system(size: 18))
                    .foregroundColor(granted ? .green : .themePurpleLight)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
            }
            
            Spacer()
            
            if !granted {
                VStack(spacing: 4) {
                    Button(action: action) {
                        Text("Permitir")
                            .font(.caption.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color.themePurple)
                            .cornerRadius(15)
                    }
                    .buttonStyle(.plain)
                    
                    if showSkip {
                        Button(action: { accessibilityGranted = true }) {
                            Text("Saltar")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.themeDarkSecondary)
        .cornerRadius(16)
    }
    
    // MARK: - Language View
    private var languageView: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.themePurple.opacity(0.3), .themePurpleLight.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 100, height: 100)
                    .blur(radius: 20)
                
                Image(systemName: "globe")
                    .font(.system(size: 50))
                    .foregroundStyle(LinearGradient(colors: [.themePurple, .themePurpleLight], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            
            Text("Selecciona tu idioma")
                .font(.title.bold())
                .foregroundColor(.white)
            
            Text("WhisperMac transcribirá en el idioma seleccionado.")
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.7))
                .padding(.horizontal, 40)
            
            VStack(spacing: 12) {
                languageButton(code: "es", name: "Español", flag: "🇪🇸")
                languageButton(code: "en", name: "English", flag: "🇺🇸")
            }
            .padding(.horizontal, 30)
        }
    }
    
    private func languageButton(code: String, name: String, flag: String) -> some View {
        Button(action: { selectedLanguage = code }) {
            HStack(spacing: 16) {
                Text(flag)
                    .font(.system(size: 32))
                Text(name)
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                if selectedLanguage == code {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.themePurpleLight)
                }
            }
            .padding(20)
            .background(
                selectedLanguage == code 
                    ? LinearGradient(colors: [.themePurple.opacity(0.3), .themePurpleLight.opacity(0.1)], startPoint: .leading, endPoint: .trailing)
                    : LinearGradient(colors: [Color.themeDarkSecondary, Color.themeDarkSecondary], startPoint: .leading, endPoint: .trailing)
            )
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(selectedLanguage == code ? Color.themePurple : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Model Download View
    private var modelDownloadView: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.themePurple.opacity(0.3), .themePurpleLight.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 100, height: 100)
                    .blur(radius: 20)
                
                Image(systemName: downloadComplete ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(downloadComplete 
                        ? LinearGradient(colors: [.green, .green], startPoint: .topLeading, endPoint: .bottomTrailing)
                        : LinearGradient(colors: [.themePurple, .themePurpleLight], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            
            Text("Descargar modelo de IA")
                .font(.title.bold())
                .foregroundColor(.white)
            
            Text("Se descargará el modelo Whisper (465 MB).\nEsto solo se hace una vez.")
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.7))
                .padding(.horizontal, 40)
            
            if isDownloading {
                VStack(spacing: 12) {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.1))
                            .frame(height: 8)
                        
                        RoundedRectangle(cornerRadius: 8)
                            .fill(LinearGradient(colors: [.themePurple, .themePurpleLight], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(0, CGFloat(downloadProgress) * 300), height: 8)
                    }
                    .frame(width: 300)
                    
                    Text("\(Int(downloadProgress * 100))% descargando...")
                        .font(.caption)
                        .foregroundColor(.themePurpleLight)
                }
                .padding(.top, 10)
            } else if downloadComplete {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Modelo listo")
                        .foregroundColor(.green)
                }
                .font(.headline)
                .padding(.top, 10)
            }
        }
    }
    
    // MARK: - Hotkey View
    private var hotkeyView: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.themePurple.opacity(0.3), .themePurpleLight.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 100, height: 100)
                    .blur(radius: 20)
                
                Image(systemName: "keyboard.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(LinearGradient(colors: [.themePurple, .themePurpleLight], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            
            Text("Configura tu atajo")
                .font(.title.bold())
                .foregroundColor(.white)
            
            Text("Este atajo activará la transcripción de voz.")
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.7))
                .padding(.horizontal, 40)
            
            VStack(spacing: 20) {
                HotkeyRecorderView(hotkey: $localHotkeyConfig, isRecording: $isRecordingHotkey)
                    .frame(width: 180, height: 44)
                
                VStack(spacing: 8) {
                    Text("Modo de activación")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                    
                    HStack(spacing: 12) {
                        modeButton(mode: .pushToTalk, title: "Mantener", icon: "hand.raised.fill")
                        modeButton(mode: .toggle, title: "Pulsar", icon: "power")
                    }
                }
            }
            .padding(.horizontal, 30)
        }
    }
    
    private func modeButton(mode: HotkeyMode, title: String, icon: String) -> some View {
        Button(action: { 
            print("Mode button tapped: \(mode)")
            localHotkeyMode = mode 
        }) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                Text(title)
                    .font(.caption.bold())
            }
            .foregroundColor(localHotkeyMode == mode ? .white : .white.opacity(0.5))
            .frame(width: 120, height: 80)
            .background(
                localHotkeyMode == mode 
                    ? LinearGradient(colors: [.themePurple, .themePurpleLight], startPoint: .topLeading, endPoint: .bottomTrailing)
                    : LinearGradient(colors: [Color.themeDarkSecondary, Color.themeDarkSecondary], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(localHotkeyMode == mode ? Color.themePurpleLight : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Done View
    private var doneView: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.green.opacity(0.3), .green.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 120, height: 120)
                    .blur(radius: 25)
                
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 70))
                    .foregroundStyle(LinearGradient(colors: [.green, Color(red: 0.4, green: 0.9, blue: 0.5)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            
            Text("¡Todo listo!")
                .font(.largeTitle.bold())
                .foregroundColor(.white)
            
            VStack(spacing: 8) {
                Text("Pulsa")
                    .foregroundColor(.white.opacity(0.7))
                
                Text(localHotkeyConfig.displayString)
                    .font(.title2.bold())
                    .foregroundColor(.themePurpleLight)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color.themePurple.opacity(0.2))
                    .cornerRadius(10)
                
                Text("para empezar a transcribir")
                    .foregroundColor(.white.opacity(0.7))
            }
        }
    }
    
    // MARK: - Helpers
    private func checkPermissions() {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let accStatus = AXIsProcessTrusted()
        
        DispatchQueue.main.async {
            self.microphoneGranted = (micStatus == .authorized)
            self.accessibilityGranted = accStatus
        }
    }
    
    private func requestMicrophoneAccess() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            self.checkPermissions()
        }
    }
    
    @State private var pollingTimer: Timer?

    private func startPermissionPolling() {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            checkPermissions()
        }
    }

    private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
    
    private func startDownload() {
        isDownloading = true
        ModelDownloader.shared.downloadModel { progress in
            DispatchQueue.main.async {
                self.downloadProgress = progress
            }
        } completion: { success in
            DispatchQueue.main.async {
                self.isDownloading = false
                self.downloadComplete = success
                if success {
                    advanceStep()
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
    
    var onComplete: ((HotkeyConfig, HotkeyMode) -> Void)?
    
    func show(initialHotkeyConfig: HotkeyConfig, initialHotkeyMode: HotkeyMode) {
        let onboardingView = OnboardingView(
            initialHotkeyConfig: initialHotkeyConfig,
            initialHotkeyMode: initialHotkeyMode,
            onComplete: { [weak self] hotkeyConfig, hotkeyMode in
                self?.close()
                self?.onComplete?(hotkeyConfig, hotkeyMode)
            }
        )
        
        hostingView = NSHostingView(rootView: onboardingView)
        
        // 25% larger window size (550 * 1.25 = 687)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 690, height: 690),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        window?.titlebarAppearsTransparent = true
        window?.titleVisibility = .hidden
        window?.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)
        
        window?.title = "Local Whisper"
        window?.contentView = hostingView
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func close() {
        window?.orderOut(nil)
        hostingView = nil
        window = nil
    }
}
