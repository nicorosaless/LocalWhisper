import Cocoa
import AVFoundation

// MARK: - State
enum IndicatorState {
    case idle
    case hovering
    case recording
    case transcribing
}

// MARK: - Floating Indicator Window
class FloatingIndicatorWindow: NSWindow {
    
    private let indicatorView: IndicatorView
    private var currentState: IndicatorState = .idle
    
    // Sound effects
    private var startSound: NSSound?
    private var stopSound: NSSound?
    
    // Callback for settings
    var onOpenSettings: (() -> Void)?
    
    // Callbacks for recording control
    var onStartRecording: (() -> Void)?
    var onStopRecording: (() -> Void)?
    var onCancelRecording: (() -> Void)?
    
    // Animation
    private var animationTimer: Timer?
    
    // Hover detection using timer (avoids tracking area flickering)
    private var hoverCheckTimer: Timer?
    private var tooltipWindow: NSWindow?
    private var tooltipTimer: Timer?
    private var isHovering = false
    private var isHoveringX = false
    
    // Hotkey display string (set from main.swift)
    var hotkeyDisplayString: String = "⌘⇧Space"
    
    // Idle size: small minimal pill
    private let idleWidth: CGFloat = 36
    private let idleHeight: CGFloat = 12
    
    // Expanded size (hover and recording use same size)
    private let expandedWidth: CGFloat = 80
    private let expandedHeight: CGFloat = 24
    
    // Screen tracking
    private var screenCheckTimer: Timer?
    private var currentScreen: NSScreen?
    private var lastVisibleFrame: NSRect?
    
    // Get the screen containing the mouse cursor
    private static func screenWithMouse() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            if screen.frame.contains(mouseLocation) {
                return screen
            }
        }
        return NSScreen.main ?? NSScreen.screens.first!
    }
    
    // Calculate the Y position based on dock visibility for a specific screen
    private static func calculateBottomY(for screen: NSScreen) -> CGFloat {
        print("🚀 calculateBottomY for screen: \(screen.frame)")
        let fullFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        
        // The dock takes space from the bottom when visible
        // If visibleFrame.origin.y is close to fullFrame.origin.y, dock is hidden or on sides
        let dockHeightAtBottom = visibleFrame.origin.y - fullFrame.origin.y
        
        if dockHeightAtBottom < 10 {
            // Dock is hidden or on the side - position at very bottom of screen
            return fullFrame.origin.y + 2
        } else {
            // Dock is visible at bottom - position above it
            return visibleFrame.origin.y + 30
        }
    }
    
    private func logDebug(_ message: String) {
        let timestamp = Date().description
        let logMessage = "[\(timestamp)] [Indicator] \(message)\n"
        print(message)
        let logURL = URL(fileURLWithPath: "/tmp/whisper_mac_startup.log")
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

    init() {
        indicatorView = IndicatorView(frame: NSRect(x: 0, y: 0, width: 36, height: 12))
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        logDebug("Init started")
        
        // Use screen with mouse cursor
        let activeScreen = Self.screenWithMouse()
        let fullFrame = activeScreen.frame
        let visibleFrame = activeScreen.visibleFrame
        
        // Center X on the FULL screen width
        let x = fullFrame.origin.x + (fullFrame.size.width - 36) / 2
        // Y position based on dock visibility
        let y = Self.calculateBottomY(for: activeScreen)
        
        logDebug("🎯 Initial Position: screen=\(fullFrame), visible=\(visibleFrame), x=\(x), y=\(y)")
        
        let frame = NSRect(x: x, y: y, width: 36, height: 12)
        self.setFrame(frame, display: true)
        
        currentScreen = activeScreen
        lastVisibleFrame = visibleFrame
        
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        self.hasShadow = true
        self.isMovableByWindowBackground = false
        self.isReleasedWhenClosed = false
        self.hidesOnDeactivate = false
        self.acceptsMouseMovedEvents = true
        self.ignoresMouseEvents = false
        
        self.contentView = indicatorView
        
        indicatorView.onClicked = { [weak self] in
            guard let self = self else { return }
            if self.currentState == .idle || self.currentState == .hovering {
                self.onStartRecording?()
            } else if self.currentState == .recording {
                self.onStopRecording?()
            }
        }
        
        startHoverDetection()
        startScreenDetection()
        
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screenParametersChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        
        loadSounds()
        
        logDebug("Init complete")
    }
    
    @objc private func screenParametersChanged() {
        logDebug("Screen parameters/workspace changed Triggered")
        // Delay significantly (0.5s) to allow OS to finish Dock/Layout animations
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.logDebug("   Executing delayed repositioning...")
            let screen = self?.currentScreen ?? Self.screenWithMouse()
            self?.moveToScreen(screen)
        }
    }
    
    deinit {
        logDebug("deinit called - cleaning up timers")
        animationTimer?.invalidate()
        animationTimer = nil
        hoverCheckTimer?.invalidate()
        hoverCheckTimer = nil
        screenCheckTimer?.invalidate()
        screenCheckTimer = nil
        tooltipTimer?.invalidate()
        tooltipTimer = nil
        logDebug("deinit complete")
    }
    
    private func startScreenDetection() {
        // Check which screen has the mouse every 100ms
        screenCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.checkScreenChange()
        }
        RunLoop.main.add(screenCheckTimer!, forMode: .common)
    }
    
    override func mouseDown(with event: NSEvent) {
        print("👆 Window clicked! State: \(currentState)")
        if currentState == .idle || currentState == .hovering {
            // Show first-use tooltip
            let hasUsedClickToRecord = UserDefaults.standard.bool(forKey: "hasUsedClickToRecord")
            if !hasUsedClickToRecord {
                showFirstClickToast()
                UserDefaults.standard.set(true, forKey: "hasUsedClickToRecord")
            }
            onStartRecording?()
        } else if currentState == .recording {
            // Any click during recording = cancel immediately (no transcription)
            print("❌ Clicked during recording - canceling")
            onCancelRecording?()
        }
    }
    
    override func mouseMoved(with event: NSEvent) {
        guard currentState == .recording else { return }
        
        let mouseLocation = event.locationInWindow
        let xAreaStart = expandedWidth - 24
        let wasHoveringX = isHoveringX
        isHoveringX = mouseLocation.x > xAreaStart
        
        if wasHoveringX != isHoveringX {
            indicatorView.setXHighlighted(isHoveringX)
        }
    }
    
    private func showFirstClickToast() {
        // Calculate tooltip position (above the indicator)
        let indicatorFrame = self.frame
        let tooltipText = "🎵 Click again to stop recording"
        
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let size = tooltipText.size(withAttributes: [.font: font])
        let padding: CGFloat = 12
        let tooltipWidth = size.width + padding * 2
        let tooltipHeight: CGFloat = 28
        
        let tooltipX = indicatorFrame.midX - tooltipWidth / 2
        let tooltipY = indicatorFrame.maxY + 15
        
        let tooltipFrame = NSRect(x: tooltipX, y: tooltipY, width: tooltipWidth, height: tooltipHeight)
        
        let toastWindow = NSWindow(
            contentRect: tooltipFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        toastWindow.isOpaque = false
        toastWindow.backgroundColor = .clear
        toastWindow.level = .floating
        toastWindow.hasShadow = true
        
        // Create label
        let label = NSTextField(labelWithString: tooltipText)
        label.font = font
        label.textColor = .white
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.sizeToFit()
        
        // Create background view
        let bgView = TooltipBackgroundView(frame: NSRect(x: 0, y: 0, width: tooltipWidth, height: tooltipHeight))
        label.frame = NSRect(x: padding, y: (tooltipHeight - label.frame.height) / 2, width: label.frame.width, height: label.frame.height)
        bgView.addSubview(label)
        
        toastWindow.contentView = bgView
        toastWindow.orderFront(nil)
        
        // Auto-hide after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            toastWindow.orderOut(nil)
        }
    }
    
    private func checkScreenChange() {
        let newScreen = Self.screenWithMouse()
        let newVisibleFrame = newScreen.visibleFrame
        
        // Move if screen changed OR if visible frame on same screen changed (Dock toggle)
        if currentScreen != newScreen || lastVisibleFrame != newVisibleFrame {
            logDebug("♻️ Screen/Frame update required. ScreenChange=\(currentScreen != newScreen), FrameChange=\(lastVisibleFrame != newVisibleFrame)")
            logDebug("   Current Visible: \(lastVisibleFrame ?? .zero) -> New Visible: \(newVisibleFrame)")
            currentScreen = newScreen
            lastVisibleFrame = newVisibleFrame
            moveToScreen(newScreen)
        }
    }
    
    private func moveToScreen(_ screen: NSScreen) {
        let fullFrame = screen.frame
        let currentWidth = self.frame.width
        let currentHeight = self.frame.height
        
        let newX = fullFrame.origin.x + (fullFrame.size.width - currentWidth) / 2
        let newY = Self.calculateBottomY(for: screen)
        
        logDebug("🚀 [Move] Screen: \(fullFrame.origin.x),\(fullFrame.origin.y) | Visible Origin Y: \(screen.visibleFrame.origin.y)")
        logDebug("   Target: (\(newX), \(newY)) | Actual Frame: \(self.frame)")
        
        self.setFrame(NSRect(x: newX, y: newY, width: currentWidth, height: currentHeight), display: true)
        
        // Direct property check to confirm move
        if self.frame.origin.y != newY {
            logDebug("   ⚠️ WARNING: Window origin Y (\(self.frame.origin.y)) did not match target (\(newY))!")
        }
    }
    
    private func startHoverDetection() {
        // Check mouse position every 100ms
        hoverCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.checkMouseHover()
        }
        RunLoop.main.add(hoverCheckTimer!, forMode: .common)
    }
    
    private func checkMouseHover() {
        // Don't check hover during recording/transcribing
        guard currentState == .idle || currentState == .hovering else {
            if isHovering {
                isHovering = false
                hideTooltip()
            }
            return
        }
        
        let mouseLocation = NSEvent.mouseLocation
        
        // Use a larger hit area for easier hovering
        let hitArea = self.frame.insetBy(dx: -10, dy: -10)
        let isMouseInside = hitArea.contains(mouseLocation)
        
        if isMouseInside && !isHovering {
            // Mouse entered
            isHovering = true
            enterHoverState()
        } else if !isMouseInside && isHovering {
            // Mouse exited
            isHovering = false
            exitHoverState()
        }
    }
    
    private func enterHoverState() {
        guard currentState == .idle else { return }
        
        // Show dots (same size as recording)
        indicatorView.setState(.hovering)
        animateToExpandedSize()
        
        // Show help tooltip immediately (replacing "Listo")
        print("DEBUG: enterHoverState called - showing help tooltip")
        showHelpTooltip()
        
        // Hide tooltip after 3 seconds
        tooltipTimer?.invalidate()
        tooltipTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            print("DEBUG: Hiding tooltip")
            self?.hideTooltip()
        }
    }
    
    private func exitHoverState() {
        // Return to idle if not recording
        if currentState == .idle || currentState == .hovering {
            indicatorView.setState(.idle)
            animateToIdleSize()
        }
        
        tooltipTimer?.invalidate()
        tooltipTimer = nil
        hideTooltip()
    }
    
    private func showStatusTooltip() {
        let statusText: String
        switch currentState {
        case .idle, .hovering:
            statusText = "Listo"
        case .recording:
            statusText = "Grabando..."
        case .transcribing:
            statusText = "Transcribiendo..."
        }
        showTooltip(text: statusText)
    }
    
    private func showHelpTooltip() {
        let helpText = "Presiona \(hotkeyDisplayString) para pasar tu voz a texto!"
        showTooltip(text: helpText)
    }
    
    private func showTooltip(text: String) {
        hideTooltip()
        
        // Create tooltip label
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.sizeToFit()
        
        let padding: CGFloat = 8
        let tooltipWidth = label.frame.width + padding * 2
        let tooltipHeight: CGFloat = 24
        
        // Position above the indicator
        let indicatorFrame = self.frame
        let tooltipX = indicatorFrame.midX - tooltipWidth / 2
        let tooltipY = indicatorFrame.maxY + 20
        
        let tooltipFrame = NSRect(x: tooltipX, y: tooltipY, width: tooltipWidth, height: tooltipHeight)
        
        tooltipWindow = NSWindow(
            contentRect: tooltipFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        tooltipWindow?.isOpaque = false
        tooltipWindow?.backgroundColor = .clear
        tooltipWindow?.level = .floating
        tooltipWindow?.hasShadow = true
        
        // Create background view
        let bgView = TooltipBackgroundView(frame: NSRect(x: 0, y: 0, width: tooltipWidth, height: tooltipHeight))
        label.frame = NSRect(x: padding, y: (tooltipHeight - label.frame.height) / 2, width: label.frame.width, height: label.frame.height)
        bgView.addSubview(label)
        
        tooltipWindow?.contentView = bgView
        tooltipWindow?.orderFront(nil)
    }
    
    private func hideTooltip() {
        tooltipWindow?.orderOut(nil)
        tooltipWindow = nil
    }
    
    private func loadSounds() {
        // Use Submarine sound - soft bubble-like
        startSound = NSSound(named: "Submarine")
        startSound?.volume = 0.1
        stopSound = NSSound(named: "Submarine") 
        stopSound?.volume = 0.1
    }
    
    func setState(_ state: IndicatorState) {
        setState(state, silent: false)
    }
    
    func setState(_ state: IndicatorState, silent: Bool) {
        let previousState = currentState
        currentState = state
        
        // Execute immediately on main thread for minimal latency
        if Thread.isMainThread {
            handleStateChange(state: state, previousState: previousState, silent: silent)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.handleStateChange(state: state, previousState: previousState, silent: silent)
            }
        }
    }
    
    private func handleStateChange(state: IndicatorState, previousState: IndicatorState, silent: Bool = false) {
        // Clear hover state when recording starts
        if state == .recording {
            isHovering = false
            hideTooltip()
        }
        
        switch state {
        case .idle:
            animateToIdleSize()
            indicatorView.setState(.idle)
            stopAnimationTimer()
        
        case .hovering:
            // Hovering is handled by mouse events
            break
            
        case .recording:
            if !silent && (previousState == .idle || previousState == .hovering) {
                startSound?.play()
            }
            indicatorView.setState(.recording)
            startWaveformAnimation()
            animateToExpandedSize()
            
        case .transcribing:
            if !silent && previousState == .recording {
                stopSound?.play()
            }
            indicatorView.setState(.transcribing)
            startSpinnerAnimation()
        }
    }
    
    func updateAudioLevel(_ level: Float) {
        indicatorView.updateAudioLevel(level)
    }
    
    private func animateToExpandedSize() {
        let screen = currentScreen ?? NSScreen.main ?? NSScreen.screens.first!
        let fullFrame = screen.frame
        let newX = fullFrame.origin.x + (fullFrame.size.width - expandedWidth) / 2
        let newY = Self.calculateBottomY(for: screen)
        
        logDebug("📐 Animate to Expanded: \(newX), \(newY)")
        
        // Fast, snappy animation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(NSRect(x: newX, y: newY, width: expandedWidth, height: expandedHeight), display: true)
        }
    }
    
    private func animateToIdleSize() {
        let screen = currentScreen ?? NSScreen.main ?? NSScreen.screens.first!
        let fullFrame = screen.frame
        let newX = fullFrame.origin.x + (fullFrame.size.width - idleWidth) / 2
        let newY = Self.calculateBottomY(for: screen)
        
        logDebug("📐 Animate to Idle: \(newX), \(newY)")
        
        // Fast, snappy animation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(NSRect(x: newX, y: newY, width: idleWidth, height: idleHeight), display: true)
        }
    }
    
    private func startWaveformAnimation() {
        stopAnimationTimer()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            self?.indicatorView.animateWaveform()
        }
        if let timer = animationTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    private func startSpinnerAnimation() {
        stopAnimationTimer()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            self?.indicatorView.animateSpinner()
        }
        if let timer = animationTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    private func stopAnimationTimer() {
        animationTimer?.invalidate()
        animationTimer = nil
    }
}

// MARK: - Tooltip Background View
class TooltipBackgroundView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func draw(_ dirtyRect: NSRect) {
        let bgColor = NSColor(white: 0.1, alpha: 0.95)
        bgColor.setFill()
        
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        path.fill()
    }
}

// MARK: - Indicator View
class IndicatorView: NSView {
    
    private var state: IndicatorState = .idle
    private var audioLevel: Float = 0.0
    private var waveformLevels: [CGFloat] = Array(repeating: 0.3, count: 7)
    private var spinnerAngle: CGFloat = 0.0
    
    private var targetWaveformLevels: [CGFloat] = Array(repeating: 0.3, count: 7)
    
    // X button highlight state
    private var xHighlighted = false
    
    // Click callback
    var onClicked: (() -> Void)?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.drawsAsynchronously = true
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func setState(_ newState: IndicatorState) {
        state = newState
        needsDisplay = true
    }
    
    func updateAudioLevel(_ level: Float) {
        audioLevel = max(0, min(1, level))
    }
    
    func setXHighlighted(_ highlighted: Bool) {
        xHighlighted = highlighted
        needsDisplay = true
    }
    
    override func mouseDown(with event: NSEvent) {
        onClicked?()
    }
    
    func animateWaveform() {
        // Center-weighted animation logic
        let centerIndex = waveformLevels.count / 2
        let maxDist = CGFloat(centerIndex)
        
        for i in 0..<waveformLevels.count {
            let baseLevel = CGFloat(audioLevel)
            
            // Calculate distance from center (0.0 at center, 1.0 at edges)
            let distFromCenter = abs(CGFloat(i - centerIndex)) / maxDist
            
            // Sensitivity drops off towards edges
            // Center bars react fully, edges react less but not as drastically (flatter curve)
            // Improved curve: (1 - x^2) for smoother falloff
            let positionSensitivity = 1.0 - (distFromCenter * distFromCenter * 0.8)
            
            // Generate a target
            // More variation range for livelier animation
            let randomVariation = CGFloat.random(in: -0.1...0.25)
            
            // Apply sensitivity to the active part of the signal
            // Scale up the variation based on volume
            let variationComponent = (randomVariation * baseLevel)
            
            // Base height + Volume impact + Randomness
            // Ensure minimum visibility (0.15) and cap at 1.0
            var target = (baseLevel * 0.8 * positionSensitivity) + variationComponent + 0.15
            target = max(0.15, min(1.0, target))
            
            targetWaveformLevels[i] = target
            
            // Lerp current towards target
            // Asymmetric smoothing: Attack fast (0.3), Decay slow (0.15)
            let current = waveformLevels[i]
            let smoothFactor: CGFloat = target > current ? 0.3 : 0.15
            
            waveformLevels[i] = current + (target - current) * smoothFactor
        }
        needsDisplay = true
    }
    
    func animateSpinner() {
        spinnerAngle += 8.0
        if spinnerAngle >= 360 {
            spinnerAngle = 0
        }
        needsDisplay = true
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        let bounds = self.bounds
        
        // Draw background pill
        let bgColor = NSColor(white: 0.08, alpha: 0.9)
        let cornerRadius = bounds.height / 2
        let bgPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: cornerRadius, yRadius: cornerRadius)
        
        switch state {
        case .idle:
            // Idle state: slightly transparent background + light border
            bgColor.withAlphaComponent(0.7).setFill()
            bgPath.fill()
            
            // Light semi-transparent border
            NSColor(white: 1.0, alpha: 0.3).setStroke()
            bgPath.lineWidth = 1.0
            bgPath.stroke()
            
        case .hovering, .recording, .transcribing:
            // Active states: solid background
            bgColor.setFill()
            bgPath.fill()
        }
        
        switch state {
        case .idle:
            break
        case .hovering:
            drawHoveringState(in: bounds)
        case .recording:
            drawRecordingState(in: bounds)
        case .transcribing:
            drawTranscribingState(in: bounds)
        }
    }
    
    private func drawRecordingState(in bounds: NSRect) {
        // Draw waveform bars (leaving space for X on right)
        let barCount = waveformLevels.count
        let barWidth: CGFloat = 2.0
        let barSpacing: CGFloat = 3.0
        let totalBarsWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
        
        // Leave space for X icon on the right
        let xIconSpace: CGFloat = 16
        let availableWidth = bounds.width - xIconSpace
        let startX = (availableWidth - totalBarsWidth) / 2
        
        let maxBarHeight = bounds.height - 6
        
        for i in 0..<barCount {
            let x = startX + CGFloat(i) * (barWidth + barSpacing)
            let barHeight = max(3, waveformLevels[i] * maxBarHeight)
            let y = (bounds.height - barHeight) / 2
            
            let barRect = NSRect(x: x, y: y, width: barWidth, height: barHeight)
            
            NSColor.white.withAlphaComponent(0.9).setFill()
            let barPath = NSBezierPath(roundedRect: barRect, xRadius: barWidth/2, yRadius: barWidth/2)
            barPath.fill()
        }
        
        // Draw X icon on the right side
        let xSize: CGFloat = 5
        let xCenterX = bounds.maxX - 12
        let xCenterY = bounds.midY
        
        // Draw highlight circle if hovering
        if xHighlighted {
            let circleRadius: CGFloat = 8
            let circlePath = NSBezierPath(ovalIn: NSRect(
                x: xCenterX - circleRadius,
                y: xCenterY - circleRadius,
                width: circleRadius * 2,
                height: circleRadius * 2
            ))
            NSColor.white.withAlphaComponent(0.2).setFill()
            circlePath.fill()
        }
        
        // Draw X with appropriate opacity
        let xOpacity: CGFloat = xHighlighted ? 1.0 : 0.7
        NSColor.white.withAlphaComponent(xOpacity).setStroke()
        let xPath = NSBezierPath()
        xPath.move(to: NSPoint(x: xCenterX - xSize/2, y: xCenterY - xSize/2))
        xPath.line(to: NSPoint(x: xCenterX + xSize/2, y: xCenterY + xSize/2))
        xPath.move(to: NSPoint(x: xCenterX + xSize/2, y: xCenterY - xSize/2))
        xPath.line(to: NSPoint(x: xCenterX - xSize/2, y: xCenterY + xSize/2))
        xPath.lineWidth = 1.5
        xPath.lineCapStyle = .round
        xPath.stroke()
    }
    
    private func drawTranscribingState(in bounds: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius: CGFloat = 6
        let lineWidth: CGFloat = 2
        
        NSColor.white.withAlphaComponent(0.2).setStroke()
        let bgCircle = NSBezierPath()
        bgCircle.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        bgCircle.lineWidth = lineWidth
        bgCircle.stroke()
        
        NSColor.white.setStroke()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: spinnerAngle, endAngle: spinnerAngle + 90)
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        arc.stroke()
    }
    
    private func drawHoveringState(in bounds: NSRect) {
        // MATCHING LAYOUT with recording state for seamless transition
        let dotCount = 11 // Consistent with bar count
        let dotSize: CGFloat = 2.0
        let dotSpacing: CGFloat = 3.0 // Consistent with bar spacing
        let totalWidth = CGFloat(dotCount) * dotSize + CGFloat(dotCount - 1) * dotSpacing
        let startX = (bounds.width - totalWidth) / 2
        let y = (bounds.height - dotSize) / 2
        
        for i in 0..<dotCount {
            let x = startX + CGFloat(i) * (dotSize + dotSpacing)
            let dotRect = NSRect(x: x, y: y, width: dotSize, height: dotSize)
            
            NSColor.white.withAlphaComponent(0.6).setFill()
            let dotPath = NSBezierPath(ovalIn: dotRect)
            dotPath.fill()
        }
    }
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu(title: "Context Menu")
        let settingsItem = NSMenuItem(title: "Ir a configuración", action: #selector(openSettingsAction), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    
    @objc func openSettingsAction() {
        (window as? FloatingIndicatorWindow)?.onOpenSettings?()
    }
}
