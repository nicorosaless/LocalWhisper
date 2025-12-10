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
    
    // Animation
    private var animationTimer: Timer?
    
    // Hover detection using timer (avoids tracking area flickering)
    private var hoverCheckTimer: Timer?
    private var tooltipWindow: NSWindow?
    private var tooltipTimer: Timer?
    private var isHovering = false
    
    // Hotkey display string (set from main.swift)
    var hotkeyDisplayString: String = "⌘⇧Space"
    
    // Idle size: small minimal pill
    private let idleWidth: CGFloat = 36
    private let idleHeight: CGFloat = 12
    
    // Expanded size (hover and recording use same size)
    private let expandedWidth: CGFloat = 120
    private let expandedHeight: CGFloat = 26
    
    init() {
        indicatorView = IndicatorView(frame: NSRect(x: 0, y: 0, width: 36, height: 12))
        
        // Get screen dimensions
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        
        // Position: bottom center, above dock
        let x = (screenFrame.width - 36) / 2 + screenFrame.origin.x
        let y = screenFrame.origin.y + 20
        
        let frame = NSRect(x: x, y: y, width: 36, height: 12)
        
        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        // Window configuration
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.hasShadow = true
        self.isMovableByWindowBackground = true
        
        self.contentView = indicatorView
        
        // Start hover detection timer
        startHoverDetection()
        
        // Load sounds asynchronously
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.loadSounds()
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
        
        // Show status tooltip
        showStatusTooltip()
        
        // Start timer for help tooltip after 1 second
        tooltipTimer?.invalidate()
        tooltipTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.showHelpTooltip()
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
        let tooltipY = indicatorFrame.maxY + 8
        
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
        let previousState = currentState
        currentState = state
        
        // Execute immediately on main thread for minimal latency
        if Thread.isMainThread {
            handleStateChange(state: state, previousState: previousState)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.handleStateChange(state: state, previousState: previousState)
            }
        }
    }
    
    private func handleStateChange(state: IndicatorState, previousState: IndicatorState) {
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
            if previousState == .idle || previousState == .hovering {
                startSound?.play()
            }
            indicatorView.setState(.recording)
            startWaveformAnimation()
            animateToExpandedSize()
            
        case .transcribing:
            if previousState == .recording {
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
        let screenFrame = NSScreen.main?.visibleFrame ?? self.frame
        let newX = (screenFrame.width - expandedWidth) / 2 + screenFrame.origin.x
        let newY = screenFrame.origin.y + 20
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(NSRect(x: newX, y: newY, width: expandedWidth, height: expandedHeight), display: true)
        }
    }
    
    private func animateToIdleSize() {
        let screenFrame = NSScreen.main?.visibleFrame ?? self.frame
        let newX = (screenFrame.width - idleWidth) / 2 + screenFrame.origin.x
        let newY = screenFrame.origin.y + 20
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
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
    private var waveformLevels: [CGFloat] = Array(repeating: 0.3, count: 9)
    private var spinnerAngle: CGFloat = 0.0
    
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
    
    func animateWaveform() {
        for i in 0..<waveformLevels.count {
            let baseLevel = CGFloat(audioLevel)
            let randomFactor = CGFloat.random(in: 0.3...1.0)
            waveformLevels[i] = max(0.2, min(1.0, baseLevel * randomFactor + 0.15))
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
        
        // Draw background pill - solid black
        let bgColor = NSColor(white: 0.08, alpha: 0.9)
        bgColor.setFill()
        
        let cornerRadius = bounds.height / 2
        let bgPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: cornerRadius, yRadius: cornerRadius)
        bgPath.fill()
        
        switch state {
        case .idle:
            // Plain black pill - nothing drawn
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
        // Draw small gray waveform bars
        let barCount = waveformLevels.count
        let barWidth: CGFloat = 3
        let barSpacing: CGFloat = 5
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
        let startX = (bounds.width - totalWidth) / 2
        let maxBarHeight = bounds.height - 8
        
        for i in 0..<barCount {
            let x = startX + CGFloat(i) * (barWidth + barSpacing)
            let barHeight = max(3, waveformLevels[i] * maxBarHeight)
            let y = (bounds.height - barHeight) / 2
            
            let barRect = NSRect(x: x, y: y, width: barWidth, height: barHeight)
            
            // Gray/white color
            NSColor.white.withAlphaComponent(0.7).setFill()
            let barPath = NSBezierPath(roundedRect: barRect, xRadius: barWidth/2, yRadius: barWidth/2)
            barPath.fill()
        }
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
        // Small dots in a row (same layout as recording bars)
        let dotCount = 9
        let dotSize: CGFloat = 3
        let dotSpacing: CGFloat = 6
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
}
