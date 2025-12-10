import SwiftUI
import AVFoundation
import AppKit

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
    
    @Binding var hotkeyConfig: HotkeyConfig
    @Binding var hotkeyMode: HotkeyMode
    
    var onComplete: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            HStack(spacing: 8) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                    Circle()
                        .fill(step.rawValue <= currentStep.rawValue ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 30)
            
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
            
            Spacer()
            
            // Navigation buttons
            HStack {
                if currentStep != .permissions && currentStep != .done {
                    Button("Atrás") {
                        withAnimation {
                            if let prev = OnboardingStep(rawValue: currentStep.rawValue - 1) {
                                currentStep = prev
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                
                Spacer()
                
                if currentStep == .done {
                    Button("Empezar") {
                        saveSettings()
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(nextButtonText) {
                        withAnimation {
                            advanceStep()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdvance)
                }
            }
            .padding(20)
        }
        .frame(width: 450, height: 400)
        .onAppear {
            checkPermissions()
        }
    }
    
    private var nextButtonText: String {
        switch currentStep {
        case .permissions:
            return "Continuar"
        case .modelDownload:
            return downloadComplete ? "Continuar" : "Descargar modelo"
        default:
            return "Continuar"
        }
    }
    
    private var canAdvance: Bool {
        switch currentStep {
        case .permissions:
            return microphoneGranted
        case .modelDownload:
            return downloadComplete || !isDownloading
        default:
            return true
        }
    }
    
    private func advanceStep() {
        if currentStep == .modelDownload && !downloadComplete {
            startDownload()
            return
        }
        
        if let next = OnboardingStep(rawValue: currentStep.rawValue + 1) {
            currentStep = next
        }
    }
    
    // MARK: - Permissions View
    private var permissionsView: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)
            
            Text("Permisos necesarios")
                .font(.title2.bold())
            
            Text("WhisperMac necesita acceso al micrófono para transcribir tu voz.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)
            
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: microphoneGranted ? "checkmark.circle.fill" : "mic.circle")
                        .foregroundColor(microphoneGranted ? .green : .orange)
                    Text("Micrófono")
                    Spacer()
                    if !microphoneGranted {
                        Button("Permitir") {
                            requestMicrophoneAccess()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                
                HStack {
                    Image(systemName: accessibilityGranted ? "checkmark.circle.fill" : "accessibility.badge.arrow.up.right")
                        .foregroundColor(accessibilityGranted ? .green : .orange)
                    Text("Accesibilidad")
                    Spacer()
                    if !accessibilityGranted {
                        Button("Abrir ajustes") {
                            openAccessibilitySettings()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(10)
            .padding(.horizontal)
        }
    }
    
    // MARK: - Language View
    private var languageView: some View {
        VStack(spacing: 20) {
            Image(systemName: "globe")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)
            
            Text("Selecciona tu idioma")
                .font(.title2.bold())
            
            Text("WhisperMac transcribirá en el idioma seleccionado.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            
            VStack(spacing: 12) {
                languageButton(code: "es", name: "Español", flag: "🇪🇸")
                languageButton(code: "en", name: "English", flag: "🇺🇸")
            }
            .padding()
        }
    }
    
    private func languageButton(code: String, name: String, flag: String) -> some View {
        Button(action: { selectedLanguage = code }) {
            HStack {
                Text(flag)
                    .font(.title)
                Text(name)
                    .font(.headline)
                Spacer()
                if selectedLanguage == code {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                }
            }
            .padding()
            .background(selectedLanguage == code ? Color.accentColor.opacity(0.1) : Color.gray.opacity(0.1))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Model Download View
    private var modelDownloadView: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)
            
            Text("Descargar modelo")
                .font(.title2.bold())
            
            Text("Se descargará el modelo de voz (465 MB).")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            
            if isDownloading {
                VStack(spacing: 8) {
                    ProgressView(value: downloadProgress)
                        .progressViewStyle(.linear)
                        .padding(.horizontal, 40)
                    
                    Text("\(Int(downloadProgress * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if downloadComplete {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Modelo descargado")
                        .foregroundColor(.green)
                }
            }
        }
    }
    
    // MARK: - Hotkey View
    private var hotkeyView: some View {
        VStack(spacing: 20) {
            Image(systemName: "keyboard")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)
            
            Text("Configura tu atajo")
                .font(.title2.bold())
            
            Text("Este atajo activará la transcripción de voz.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            
            VStack(spacing: 16) {
                HotkeyRecorderView(hotkey: $hotkeyConfig, isRecording: $isRecordingHotkey)
                    .frame(width: 160, height: 36)
                
                Picker("Modo", selection: $hotkeyMode) {
                    Text("Mantener (Push to Talk)").tag(HotkeyMode.pushToTalk)
                    Text("Pulsar (Toggle)").tag(HotkeyMode.toggle)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
            }
            .padding()
        }
    }
    
    // MARK: - Done View
    private var doneView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.green)
            
            Text("¡Todo listo!")
                .font(.title.bold())
            
            Text("Pulsa \(hotkeyConfig.displayString) para empezar a transcribir.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - Helpers
    private func checkPermissions() {
        // Check microphone
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneGranted = true
        default:
            microphoneGranted = false
        }
        
        // Check accessibility (simplified check)
        accessibilityGranted = AXIsProcessTrusted()
    }
    
    private func requestMicrophoneAccess() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                microphoneGranted = granted
            }
        }
    }
    
    private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
        
        // Check again after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            checkPermissions()
        }
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
    }
}

// MARK: - Onboarding Window Controller
class OnboardingWindowController {
    private var window: NSWindow?
    private var hostingView: NSHostingView<OnboardingView>?
    
    var onComplete: (() -> Void)?
    
    func show(hotkeyConfig: Binding<HotkeyConfig>, hotkeyMode: Binding<HotkeyMode>) {
        let onboardingView = OnboardingView(
            hotkeyConfig: hotkeyConfig,
            hotkeyMode: hotkeyMode,
            onComplete: { [weak self] in
                self?.close()
                self?.onComplete?()
            }
        )
        
        hostingView = NSHostingView(rootView: onboardingView)
        
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        
        window?.title = "WhisperMac"
        window?.contentView = hostingView
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func close() {
        window?.close()
        window = nil
    }
}
