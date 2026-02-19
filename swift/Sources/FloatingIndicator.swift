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
class FloatingIndicatorWindow: NSPanel {
    
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
    
    // The app we are currently 'locked' to for pasting
    var lockedTargetAppName: String? {
        didSet {
            // If we are recording, updating the tooltip might be too noisy, 
            // but we want to show it when starting.
        }
    }
    
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
    
    private let loweredPosition: CGFloat = 12 // Height when dock is hidden (more breathing room)
    
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
    

    
    // Calculate the Y position (Simplified - always fixed at bottom)
    private func calculateBottomY(for screen: NSScreen, dockActive: Bool) -> CGFloat {
        let fullFrame = screen.frame
        return fullFrame.origin.y + loweredPosition
    }
    
    private func logDebug(_ message: String) {
        #if DEBUG
        print("[Indicator] \(message)")
        #endif
    }

    init() {
        indicatorView = IndicatorView(frame: NSRect(x: 0, y: 0, width: 36, height: 12))
        // Use .nonactivatingPanel to prevent focus stealing on click
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

        
        // Use screen with mouse cursor
        let activeScreen = Self.screenWithMouse()
        let fullFrame = activeScreen.frame
        let visibleFrame = activeScreen.visibleFrame
        
        // Center X on the FULL screen width
        let x = fullFrame.origin.x + (fullFrame.size.width - 36) / 2
        // Y position is now fixed
        let y = calculateBottomY(for: activeScreen, dockActive: false)
        
        let frame = NSRect(x: x, y: y, width: 36, height: 12)
        self.setFrame(frame, display: true)
        
        currentScreen = activeScreen
        lastVisibleFrame = visibleFrame
        
        self.isFloatingPanel = true
        self.becomesKeyOnlyIfNeeded = true
        
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .floating // slightly higher than standard status bar to be always top
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
                // Check if user has used click-to-record before for toast
                let hasUsedClickToRecord = UserDefaults.standard.bool(forKey: "hasUsedClickToRecord")
                if !hasUsedClickToRecord {
                    self.showFirstClickToast()
                    UserDefaults.standard.set(true, forKey: "hasUsedClickToRecord")
                }

                self.onStartRecording?()
            } else if self.currentState == .recording {

                self.onStopRecording?()
            }
        }
        
        indicatorView.onCancelClicked = { [weak self] in
             self?.onCancelRecording?()
        }
        
        startHoverDetection()
        startScreenDetection()
        
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screenParametersChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        
        loadSounds()
        

    }
    
    // MARK: - Window Configuration overrides
    // These are CRITICAL to prevent stealing focus from the target app
    override var canBecomeKey: Bool { return false }
    override var canBecomeMain: Bool { return false }
    
    @objc private func screenParametersChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            let screen = self?.currentScreen ?? Self.screenWithMouse()
            self?.moveToScreen(screen)
        }
    }
    
    deinit {
        animationTimer?.invalidate()
        animationTimer = nil
        hoverCheckTimer?.invalidate()
        hoverCheckTimer = nil
        screenCheckTimer?.invalidate()
        screenCheckTimer = nil
        tooltipTimer?.invalidate()
        tooltipTimer = nil
    }
    
    private func startScreenDetection() {
        // Check which screen has the mouse every 50ms for responsive dock detection
        screenCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.checkScreenChange()
        }
        RunLoop.main.add(screenCheckTimer!, forMode: .common)
    }
    
    override func rightMouseDown(with event: NSEvent) {
        onOpenSettings?()
    }

    override func mouseDown(with event: NSEvent) {

        // Handle Ctrl+Click as Right Click
        if event.modifierFlags.contains(.control) {
            onOpenSettings?()
            return
        }
        
        let mouseLoc = event.locationInWindow
        // expandedWidth is 80. X button is on right.
        // Let's say X area is last 24 pixels.
        let xAreaStart = self.frame.width - 24
        
        if currentState == .recording {
             if mouseLoc.x > xAreaStart {
                 // X clicked -> Cancel
                 onCancelRecording?()
                 return
             } else {
                 // Body clicked -> Stop & Transcribe
                 onStopRecording?()
                 return
             }
        } else if currentState == .idle || currentState == .hovering {
            // Show first-use tooltip (only once ever)
            let hasUsedClickToRecord = UserDefaults.standard.bool(forKey: "hasUsedClickToRecord")
            if !hasUsedClickToRecord {
                showFirstClickToast()
                UserDefaults.standard.set(true, forKey: "hasUsedClickToRecord")
            }
            onStartRecording?()
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
        let tooltipText = "Click again to stop recording"
        
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
        toastWindow.level = .statusBar // Match indicator level to stay above dock
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
        toastWindow.orderFrontRegardless()
        
        // Auto-hide after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            toastWindow.orderOut(nil)
        }
    }
    
    func showSettingsToast() {
        showTooltip(text: "Control-click for Settings", duration: 5.0)
    }
    
    // Helper to compare NSRect values properly
    private func rectsAreEqual(_ r1: NSRect?, _ r2: NSRect) -> Bool {
        guard let r1 = r1 else { return false }
        return r1.origin.x == r2.origin.x &&
               r1.origin.y == r2.origin.y &&
               r1.size.width == r2.size.width &&
               r1.size.height == r2.size.height
    }
    
    private func checkScreenChange() {
        let newScreen = Self.screenWithMouse()
        let newVisibleFrame = newScreen.visibleFrame
        
        // Move if screen changed OR if visible frame on same screen changed
        let screenChanged = currentScreen != newScreen
        let frameChanged = !rectsAreEqual(lastVisibleFrame, newVisibleFrame)
        
        if screenChanged || frameChanged {
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
        let newY = calculateBottomY(for: screen, dockActive: false)
        
        let newFrame = NSRect(x: newX, y: newY, width: currentWidth, height: currentHeight)
        
        // Smooth position change
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(newFrame, display: true)
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
        // Show help tooltip immediately (replacing "Listo")

        showHelpTooltip()
        
        // Hide tooltip after 3 seconds
        tooltipTimer?.invalidate()
        tooltipTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in

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
    

    
    private func showHelpTooltip() {
        let helpText = "Press \(hotkeyDisplayString) or click to transcribe"
        showTooltip(text: helpText)
    }
    
    private func showTooltip(text: String, duration: TimeInterval = 0) {
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
        tooltipWindow?.level = .statusBar // Match indicator level to stay above dock
        tooltipWindow?.hasShadow = true
        
        // Create background view
        let bgView = TooltipBackgroundView(frame: NSRect(x: 0, y: 0, width: tooltipWidth, height: tooltipHeight))
        label.frame = NSRect(x: padding, y: (tooltipHeight - label.frame.height) / 2, width: label.frame.width, height: label.frame.height)
        bgView.addSubview(label)
        
        tooltipWindow?.contentView = bgView
        tooltipWindow?.orderFrontRegardless()
        
        if duration > 0 {
            tooltipTimer?.invalidate()
            tooltipTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                self?.hideTooltip()
            }
        }
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
        let newY = calculateBottomY(for: screen, dockActive: false)
        
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
        let newY = calculateBottomY(for: screen, dockActive: false)
        
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
    
    // Click callbacks
    var onClicked: (() -> Void)?
    var onCancelClicked: (() -> Void)?
    
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

        // Handle Ctrl+Click as Right Click at View level just in case
        if event.modifierFlags.contains(.control) {
            // Pass to window via super, or handle?
            // Better to let Window handle rightMouseDown, but Ctrl-Click is mouseDown.
            // Let's explicitly ignore it here so it doesn't trigger body click.
             super.mouseDown(with: event)
             return
        }

        if state == .recording {
            let mouseLoc = convert(event.locationInWindow, from: nil)
            let xAreaStart = bounds.width - 24 // 24px from right
            if mouseLoc.x > xAreaStart {

                onCancelClicked?()
                return
            }
        }
        onClicked?()
    }
    
    // Ensure we accept first mouse to click even if window not key (it never is)
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    
    func animateWaveform() {
        let baseLevel = CGFloat(audioLevel)
        let time = CACurrentMediaTime()
        
        // If no audio, keep bars at minimal static height - NO movement
        if baseLevel < 0.05 {
            for i in 0..<waveformLevels.count {
                let current = waveformLevels[i]
                let target: CGFloat = 0.1
                waveformLevels[i] = current + (target - current) * 0.15
            }
            needsDisplay = true
            return
        }
        
        // Audio is playing - energetic reactive animation
        for i in 0..<waveformLevels.count {
            // Time-varying sensitivity for unpredictability
            let basePhase = CGFloat(i) * 1.5
            let wave1 = sin(time * 1.5 + basePhase) * 0.2
            let wave2 = sin(time * 3.2 + basePhase * 0.6) * 0.15
            let timeFactor = wave1 + wave2
            let sensitivity = 0.7 + timeFactor
            
            // Random variation for energy
            let randomOffset = CGFloat.random(in: -0.1...0.15)
            
            // Strong audio response - amplify the audio level
            var target = baseLevel * 1.3 * sensitivity + randomOffset + 0.1
            target = max(0.1, min(0.85, target))
            
            targetWaveformLevels[i] = target
            
            // Faster attack (0.35) for snappy response, moderate decay (0.15)
            let current = waveformLevels[i]
            let smoothFactor: CGFloat = target > current ? 0.35 : 0.15
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
        let bgColor = NSColor(red: 0.02, green: 0.02, blue: 0.02, alpha: 0.95)
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
        
        let maxBarHeight = bounds.height - 10 // Shorter bars to avoid hitting edges
        
        for i in 0..<barCount {
            let x = startX + CGFloat(i) * (barWidth + barSpacing)
            let barHeight = max(3, waveformLevels[i] * maxBarHeight)
            let y = (bounds.height - barHeight) / 2
            
            let barRect = NSRect(x: x, y: y, width: barWidth, height: barHeight)
            
            // White waveform bars
            NSColor.white.setFill()
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
        
        let activePurple = NSColor(red: 0.55, green: 0.18, blue: 1.0, alpha: 1.0)
        activePurple.setStroke()
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
            
            // White dots
            NSColor.white.withAlphaComponent(0.8).setFill()
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
