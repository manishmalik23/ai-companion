import AppKit
import Foundation

enum Palette {
    static let ink = NSColor.labelColor
    static let secondary = NSColor.secondaryLabelColor
    static let paper = NSColor.windowBackgroundColor
    static let line = NSColor.separatorColor
    static let mint = NSColor.controlAccentColor
    static let green = NSColor.controlAccentColor
    static let buttonFill = NSColor.controlAccentColor
    static let buttonTitle = NSColor.white
    static let peach = NSColor.keyboardFocusIndicatorColor
    static let muted = NSColor.textBackgroundColor
    static let control = NSColor.controlBackgroundColor
    static let handle = NSColor(name: "PipHandle") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .systemGray : .controlBackgroundColor
    }
    static let glyph = NSColor.labelColor
}

private func invalidateAppearanceDisplay(in view: NSView) {
    view.needsDisplay = true
    if let text = view as? NSTextView {
        text.layoutManager?.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: text.string.utf16.count))
    }
    view.subviews.forEach { invalidateAppearanceDisplay(in: $0) }
}

func label(_ text: String, _ frame: NSRect, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                   color: NSColor = Palette.ink, selectable: Bool = false) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.frame = frame
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.isSelectable = selectable
    field.lineBreakMode = .byWordWrapping
    field.maximumNumberOfLines = 0
    return field
}

final class CompanionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PetView: NSView {
    var mood = "idle"
    var phase: Double = 0
    private var pressPoint: NSPoint?
    private var pressOrigin: NSPoint?
    private var dragged = false
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        pressPoint = window.convertPoint(toScreen: event.locationInWindow)
        pressOrigin = window.frame.origin
        dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, let pressPoint, let pressOrigin else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let delta = NSPoint(x: point.x - pressPoint.x, y: point.y - pressPoint.y)
        guard dragged || hypot(delta.x, delta.y) >= 4 else { return }
        dragged = true
        window.setFrameOrigin(NSPoint(x: pressOrigin.x + delta.x, y: pressOrigin.y + delta.y))
    }
    override func mouseUp(with event: NSEvent) {
        pressPoint = nil; pressOrigin = nil; dragged = false
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        RobotArt.draw(in: context, bounds: bounds, mood: mood, phase: phase)
    }
}

final class ActionButton: PointingHandButton {
    var primary = false
    override var isFlipped: Bool { true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let fill = primary ? Palette.buttonFill : Palette.muted
            fill.withAlphaComponent(isEnabled ? 1 : 0.45).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12).fill()
            if !primary {
                Palette.line.setStroke()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12).stroke()
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: (primary ? Palette.buttonTitle : Palette.ink).withAlphaComponent(isEnabled ? 1 : 0.5)
            ]
            let size = (title as NSString).size(withAttributes: attributes)
            (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                               y: (bounds.height - size.height) / 2), withAttributes: attributes)
            if window?.firstResponder === self {
                Palette.peach.setStroke()
                let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 10, yRadius: 10)
                focus.lineWidth = 2; focus.stroke()
            }
        }
    }
}

private final class DockButtonCell: NSButtonCell {
    override func hitTest(for event: NSEvent, in cellFrame: NSRect, of controlView: NSView) -> NSCell.HitResult {
        // The title is drawn by DockButton. AppKit's borderless cell otherwise
        // tracks only its small native text band inside the larger button.
        let point = controlView.convert(event.locationInWindow, from: nil)
        guard isEnabled, cellFrame.contains(point) else { return [] }
        return [.contentArea, .trackableArea]
    }
}

private final class DockButton: PointingHandButton {
    var provider = "claude"
    private var hovered = false
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = DockButtonCell(textCell: "")
        setButtonType(.momentaryPushIn)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event); hovered = true; needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event); hovered = false; needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if hovered || isHighlighted {
                Palette.glyph.withAlphaComponent(isHighlighted ? 0.12 : 0.06).setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12).fill()
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font ?? NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: Palette.glyph
            ]
            let size = (title as NSString).size(withAttributes: attributes)
            (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                               y: (bounds.height - size.height) / 2), withAttributes: attributes)
            if window?.firstResponder === self {
                Palette.peach.setStroke()
                let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12)
                focus.lineWidth = 1; focus.stroke()
            }
        }
    }
}

private final class CompanionDock: NSView {
    let claude = DockButton(frame: NSRect(x: 4, y: 2, width: 68, height: 32))
    let codex = DockButton(frame: NSRect(x: 76, y: 2, width: 68, height: 32))
    let miniChat = DockButton(frame: NSRect(x: 148, y: 2, width: 68, height: 32))
    var onChat: ((String) -> Void)?
    var onMiniChat: (() -> Void)?
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for button in [claude, codex, miniChat] {
            button.isBordered = false; button.target = self; button.action = #selector(openChat)
            button.font = .systemFont(ofSize: 12, weight: .semibold)
            addSubview(button)
        }
        claude.title = "Claude"; claude.provider = "claude"
        claude.toolTip = "Open Claude · Pip chat if the app is unavailable"; claude.setAccessibilityLabel("Open Claude app or Pip chat")
        codex.title = "ChatGPT"; codex.provider = "codex"
        codex.toolTip = "Open ChatGPT · Pip Codex chat if the app is unavailable"; codex.setAccessibilityLabel("Open ChatGPT app or Pip Codex chat")
        miniChat.title = "Mini Chat"; miniChat.action = #selector(openMiniChat)
        miniChat.toolTip = "Open Pip’s mini chat · Claude Code or Codex CLI"; miniChat.setAccessibilityLabel("Open Pip mini chat")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidateAppearanceDisplay(in: self)
    }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            Palette.control.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 18, yRadius: 18).fill()
            Palette.line.setStroke()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 18, yRadius: 18).stroke()
            Palette.line.setFill()
            for x in [74, 146] { NSRect(x: x, y: 11, width: 1, height: 14).fill() }
        }
    }
    @objc private func openChat(_ sender: NSButton) {
        guard let button = sender as? DockButton else { return }
        onChat?(button.provider)
    }
    @objc private func openMiniChat() { onMiniChat?() }
}

enum CompanionIdleLayout {
    static let size = NSSize(width: 240, height: 164)
    static let pet = NSRect(x: 72, y: 10, width: 96, height: 104)
    static let dock = NSRect(x: 10, y: 114, width: 220, height: 36)
    static let handle = NSRect(x: 108, y: 116, width: 24, height: 5)
    static let handleHover = NSRect(x: 98, y: 114, width: 44, height: 14)
    static let controlsHover = NSRect(x: 6, y: 114, width: 228, height: 40)
}


final class CompanionView: NSView {
    let pet = PetView(frame: .zero)
    private let dock = CompanionDock(frame: CompanionIdleLayout.dock)
    private var request: PermissionRequest?
    private var queueCount = 0
    private var queuePosition = 0
    private var sessionStatus = "All quiet"
    private var desktopChatStatus = "Desktop chats are off"
    private var localError: String?
    private var labels: [NSView] = []
    private var remaining: NSTextField?
    private var footer: NSTextField?
    private var approve: ActionButton?
    private var deny: ActionButton?
    private var questionForm: QuestionForm?
    private var actionsEnabled = false
    private var hoverTracking: [NSTrackingArea] = []
    private var hovered = false
    private let handleRect = CompanionIdleLayout.handle
    private let handleHoverRect = CompanionIdleLayout.handleHover
    private let controlsHoverRect = CompanionIdleLayout.controlsHover
    var onDecision: ((Bool) -> Void)?
    var onQuestion: (([String: String]?) -> Void)?
    var onNavigate: ((Int) -> Void)?
    var onChat: ((String) -> Void)?
    var onMiniChat: (() -> Void)?
    var onOpenSession: ((PermissionRequest) -> Void)?
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(origin: .zero, size: CompanionIdleLayout.size))
        addSubview(pet); addSubview(dock)
        dock.onChat = { [weak self] provider in self?.onChat?(provider) }
        dock.onMiniChat = { [weak self] in self?.onMiniChat?() }
        configure(request: nil, position: 0, count: 0, sessions: [], error: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Repaint in place so a theme change preserves typed answers and hover state.
        invalidateAppearanceDisplay(in: self)
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if request != nil { window?.performDrag(with: event) }
    }

    override func updateTrackingAreas() {
        hoverTracking.forEach { removeTrackingArea($0) }; hoverTracking.removeAll()
        if request == nil {
            // The line starts expansion. The second area lets entry/exit events
            // reconcile movement onto the revealed controls without tracking the pet.
            for rectangle in [handleHoverRect, controlsHoverRect] {
                let tracking = NSTrackingArea(rect: rectangle,
                    options: [.mouseEnteredAndExited, .activeAlways, .enabledDuringMouseDrag], owner: self)
                addTrackingArea(tracking); hoverTracking.append(tracking)
            }
        }
        super.updateTrackingAreas()
        refreshHover()
    }
    override func mouseEntered(with event: NSEvent) { refreshHover() }
    override func mouseExited(with event: NSEvent) { refreshHover() }
    private func updateDockVisibility() {
        let hidden = request != nil || !hovered
        if dock.isHidden != hidden { dock.isHidden = hidden; needsDisplay = true }
    }
    func refreshHover() {
        if request == nil, let window, window.isVisible {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            updateHover(at: point)
        } else { updateHover(at: nil) }
    }
    func updateHover(at point: NSPoint?) {
        if request == nil, let point {
            hovered = (hovered ? controlsHoverRect : handleHoverRect).contains(point)
        } else { hovered = false }
        updateDockVisibility()
    }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            guard request != nil else {
                NSGraphicsContext.current?.cgContext.clear(dirtyRect)
                if dock.isHidden {
                    Palette.handle.setFill()
                    let handle = NSBezierPath(roundedRect: handleRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
                    handle.fill(); Palette.line.setStroke(); handle.stroke()
                }
                return
            }
            Palette.paper.setFill()
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: request == nil ? 26 : 24,
                                      yRadius: request == nil ? 26 : 24)
            outline.fill(); Palette.line.setStroke(); outline.lineWidth = 1; outline.stroke()
            if request != nil {
                let divider = NSBezierPath(); divider.move(to: NSPoint(x: 24, y: 111)); divider.line(to: NSPoint(x: 436, y: 111))
                Palette.line.setStroke(); divider.stroke()
            }
        }
    }

    private func add(_ child: NSView) { addSubview(child); labels.append(child) }

    func setDesktopChatStatus(_ status: String) {
        desktopChatStatus = status
        updatePetHelp()
    }

    private func updatePetHelp() {
        pet.toolTip = (localError ?? "\(sessionStatus) · drag to move") + "\n" + desktopChatStatus
        pet.setAccessibilityHelp("Drag the robot to move the companion. " + desktopChatStatus)
    }

    func configure(request: PermissionRequest?, position: Int, count: Int, sessions: [AgentSession], error: String?) {
        let wasIdle = self.request == nil
        self.request = request; queueCount = count; queuePosition = position; localError = error
        if request != nil || !wasIdle { hovered = false }
        labels.forEach { $0.removeFromSuperview() }; labels.removeAll()
        approve = nil; deny = nil; remaining = nil; footer = nil; questionForm = nil
        let working = sessions.filter { $0.status == "working" }.count
        let attention = sessions.filter { $0.status == "attention" }.count
        sessionStatus = working > 0 ? "\(working) agent\(working == 1 ? "" : "s") working" :
            (attention > 0 ? "Agent needs attention" : (sessions.isEmpty ? "Ready to connect" : "All quiet"))
        pet.mood = request != nil ? "waiting" : (working > 0 ? "working" : "idle")
        updateDockVisibility()
        updatePetHelp()
        if let request {
            frame.size = NSSize(width: 460, height: 650)
            pet.frame = NSRect(x: 22, y: 13, width: 88, height: 88)
            add(SessionHeaderButton(request: request, target: self, action: #selector(openSessionClicked(_:))))
            let source = label(request.sourceLabel.uppercased(), NSRect(x: 24, y: 130, width: 288, height: 20), size: 11, weight: .semibold, color: Palette.green)
            source.toolTip = request.sourceLabel; add(source)
            if request.isDemo {
                let demo = label("DEMO", NSRect(x: 365, y: 128, width: 71, height: 22), size: 10, weight: .bold, color: Palette.green)
                demo.alignment = .center; demo.drawsBackground = true; demo.backgroundColor = Palette.mint.withAlphaComponent(0.35)
                add(demo)
            }
            let activeQuestion = request.isQuestion && request.responseAvailable
            let actionApproval = request.responseAvailable && !activeQuestion
            let actionTitles = ["read": "Read file", "edit": "Edit file", "multiedit": "Edit file", "write": "Write file", "bash": "Run command", "exec_command": "Run command"]
            let approvalTitle = actionTitles[request.toolName.lowercased()] ?? "Permission needed"
            add(label(activeQuestion ? "A question for you" : (request.responseAvailable ? approvalTitle : "Continue in \(request.sourceLabel)"),
                      NSRect(x: 24, y: 158, width: 412, height: 31), size: request.responseAvailable ? 24 : 21, weight: .semibold))
            let reason = request.reason.isEmpty ? (activeQuestion ? "Choose your answers below, or continue in \(request.sourceLabel)." : "\(request.sourceLabel) wants to use \(request.toolName).") : request.reason
            if actionApproval {
                add(label("WHY THIS IS NEEDED", NSRect(x: 24, y: 202, width: 412, height: 14),
                          size: 10, weight: .semibold, color: Palette.secondary))
            }
            let reasonLabel = label(reason,
                                    NSRect(x: 24, y: actionApproval ? 222 : 202, width: 412, height: actionApproval ? 54 : 42),
                                    size: 13, weight: actionApproval ? .medium : .regular,
                                    color: actionApproval ? Palette.ink : Palette.secondary,
                                    selectable: actionApproval)
            reasonLabel.maximumNumberOfLines = actionApproval ? 3 : 2
            reasonLabel.toolTip = reason; add(reasonLabel)
            if activeQuestion {
                let scroll = NSScrollView(frame: NSRect(x: 24, y: 253, width: 412, height: 277))
                scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
                scroll.borderType = .noBorder; scroll.drawsBackground = true; scroll.backgroundColor = Palette.muted
                scroll.wantsLayer = true; scroll.layer?.cornerRadius = 12; scroll.layer?.masksToBounds = true
                let form = QuestionForm(request: request, width: 394)
                form.onChange = { [weak self, weak form] in
                    guard let self, let form else { return }
                    self.localError = form.hasOversizedAnswer ? "Keep all answers together under 2,000 bytes." : nil
                    self.setActionsEnabled(self.actionsEnabled)
                    self.updateCountdown(now: Date().timeIntervalSince1970)
                }
                scroll.documentView = form; add(scroll); questionForm = form
            } else {
            let toolLabel = label(request.actionDetail,
                                  NSRect(x: 24, y: actionApproval ? 286 : 251, width: 412, height: actionApproval ? 54 : 36),
                                  size: 12, weight: .semibold, selectable: true)
            toolLabel.maximumNumberOfLines = actionApproval ? 3 : 2
            toolLabel.lineBreakMode = actionApproval ? .byCharWrapping : .byTruncatingMiddle
            toolLabel.toolTip = request.actionDetail
            toolLabel.font = .monospacedSystemFont(ofSize: actionApproval ? 12 : 13, weight: .semibold); add(toolLabel)
            add(label(actionApproval ? "Do you want to proceed?" : "TOOL INPUT & CONTEXT", NSRect(x: 24, y: actionApproval ? 347 : 291, width: 412, height: 18), size: actionApproval ? 13 : 10, weight: .semibold, color: Palette.secondary))

            let contextHeight: CGFloat = actionApproval ? 118 : 174
            let scroll = NSScrollView(frame: NSRect(x: 24, y: actionApproval ? 374 : 318, width: 412, height: contextHeight))
            scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            scroll.borderType = .noBorder; scroll.drawsBackground = true; scroll.backgroundColor = Palette.muted
            scroll.wantsLayer = true; scroll.layer?.cornerRadius = 12; scroll.layer?.masksToBounds = true
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 392, height: contextHeight))
            text.isEditable = false; text.isSelectable = true
            text.isRichText = false; text.drawsBackground = true; text.backgroundColor = Palette.muted
            text.textColor = Palette.ink; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            text.textContainerInset = NSSize(width: 12, height: 12)
            text.minSize = NSSize(width: 0, height: contextHeight)
            text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            text.isVerticallyResizable = true; text.isHorizontallyResizable = false
            text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
            text.string = "ACTION\n" + request.actionDetail + "\n\nTOOL INPUT\n" + request.toolInputForDisplay(excludingDisplayedReason: reason) + "\n\nSOURCE\n" + request.sourceLabel + " (" + request.source + ")" +
                "\n\nWORKING DIRECTORY\n" + request.cwd
            scroll.documentView = text; add(scroll)

            let cwdLabel = label(request.cwd.isEmpty ? "Working directory not provided" : request.cwd,
                                 NSRect(x: 24, y: 510, width: 412, height: 18), size: 11, color: Palette.secondary, selectable: true)
            cwdLabel.maximumNumberOfLines = 1; cwdLabel.lineBreakMode = .byTruncatingMiddle; cwdLabel.toolTip = request.cwd; add(cwdLabel)
            }
            let time = label("", NSRect(x: 24, y: 541, width: 412, height: 18), size: 12, weight: .medium, color: Palette.secondary)
            add(time); remaining = time
            let allowButton = ActionButton(frame: NSRect(x: 24, y: 578, width: 267, height: 44))
            allowButton.title = activeQuestion ? "Submit answers" : (request.responseAvailable ? "Yes, allow once" : "Dismiss alert")
            if activeQuestion { allowButton.frame.size.width = 226 }
            if !request.responseAvailable { allowButton.frame.size.width = 412 }
            allowButton.primary = true; allowButton.isBordered = false
            allowButton.target = self; allowButton.action = #selector(approveClicked)
            allowButton.setAccessibilityLabel(activeQuestion ? "Submit answers to these questions" : (request.responseAvailable ? "Approve this permission request once" : "Dismiss this alert"))
            add(allowButton); approve = allowButton
            let denyButton = ActionButton(frame: NSRect(x: 303, y: 578, width: 133, height: 44))
            denyButton.title = "No, reject"; denyButton.isBordered = false; denyButton.target = self; denyButton.action = #selector(denyClicked)
            if activeQuestion {
                denyButton.frame = NSRect(x: 262, y: 578, width: 174, height: 44)
                denyButton.title = request.source.lowercased().contains("claude") ? "Answer in Claude" : "Answer in app"
                denyButton.setAccessibilityLabel("Answer these questions in " + request.sourceLabel)
            }
            if request.responseAvailable { add(denyButton); deny = denyButton }
            let foot = label("LOCAL CONNECTION · REQUEST \(position) OF \(count)", NSRect(x: 24, y: 631, width: 412, height: 14),
                             size: 9, weight: .medium, color: Palette.secondary)
            foot.alignment = .center; add(foot); footer = foot
            if count > 1 {
                foot.frame = NSRect(x: 59, y: 631, width: 342, height: 14)
                let previous = PointingHandButton(title: "‹", target: self, action: #selector(previousClicked))
                previous.frame = NSRect(x: 23, y: 625, width: 28, height: 23)
                previous.isBordered = false; previous.font = .systemFont(ofSize: 20)
                previous.setAccessibilityLabel("Previous permission request"); add(previous)
                let next = PointingHandButton(title: "›", target: self, action: #selector(nextClicked))
                next.frame = NSRect(x: 408, y: 625, width: 28, height: 23)
                next.isBordered = false; next.font = .systemFont(ofSize: 20)
                next.setAccessibilityLabel("Next permission request"); add(next)
            }
        } else {
            frame.size = CompanionIdleLayout.size
            // The original sprite still occupies y10...114. Remove only the
            // surrounding transparent view space so handle hover excludes the pet.
            pet.frame = CompanionIdleLayout.pet
        }
        needsDisplay = true; updateCountdown(now: Date().timeIntervalSince1970)
    }

    func animate(at phase: Double) {
        pet.phase = phase; pet.needsDisplay = true
        // Resizing/moving a window may not produce a mouse-enter/exit event.
        // Reconcile the handle/control area while idle so controls never stay stale.
        if request == nil { refreshHover() }
    }

    func updateCountdown(now: Double) {
        guard let request else { return }
        let seconds = max(0, Int(ceil(request.expiresAt - now)))
        let duration = seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
        remaining?.stringValue = localError ?? "Waiting for you · expires in \(duration)"
        remaining?.textColor = localError == nil ? Palette.secondary : .systemRed
    }

    func updateQueue(position: Int, count: Int) {
        footer?.stringValue = "LOCAL CONNECTION · REQUEST \(position) OF \(count)"
    }

    func refreshSessionCursorRects() {
        // Cursor invalidation normally waits for a key window. Approval cards
        // are shown without taking focus from the originating editor.
        labels.compactMap { $0 as? SessionHeaderButton }.forEach { $0.refreshCursorRects() }
        labels.compactMap { $0 as? PointingHandButton }.forEach { $0.refreshCursorRects() }
    }

    func setActionsEnabled(_ enabled: Bool) {
        actionsEnabled = enabled
        approve?.isEnabled = enabled && (questionForm == nil || questionForm?.answers != nil)
        deny?.isEnabled = enabled
        approve?.needsDisplay = true; deny?.needsDisplay = true
    }

    func showError(_ message: String) { localError = message; updateCountdown(now: Date().timeIntervalSince1970) }
    @objc private func approveClicked() {
        if let form = questionForm { if let answers = form.answers { onQuestion?(answers) } }
        else { onDecision?(true) }
    }
    @objc private func denyClicked() { if questionForm != nil { onQuestion?(nil) } else { onDecision?(false) } }
    @objc private func previousClicked() { onNavigate?(-1) }
    @objc private func nextClicked() { onNavigate?(1) }
    @objc private func openSessionClicked(_ sender: NSButton) {
        guard let header = sender as? SessionHeaderButton, let request,
              header.requestId == request.id, request.canOpenSession else { return }
        onOpenSession?(request)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: CompanionPanel!
    private let content = CompanionView()
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var store: RuntimeStore?
    private var pending: [RequestSnapshot] = []
    private var displayed: RequestSnapshot?
    private var sessions: [AgentSession] = []
    private var displayedAt: Double = 0
    private var actionCooldownUntil: Double = 0
    private var processingDecision = false
    private var sessionHandoff = SessionHandoffState()
    private var error: String?
    private var sessionSummary = ""
    private var lastTick: Double = 0
    private var lastPoll: Double = 0
    private var chat: MiniChatController?
    private var characterStore: CharacterStore?
    private var appearance: AppearanceController?
    private let providerApps = ProviderAppLauncher()
    private let conversationBubble = ConversationBubbleController()
    private let desktopChats = DesktopChatObserver()
    private var desktopChatsEnabled: Bool = {
        if CommandLine.arguments.contains("--preview-setup") { return false }
        let defaults = UserDefaults.standard
        // Apply the default-on preference once; subsequent user opt-outs persist.
        if !defaults.bool(forKey: "PipDesktopChatsDefaultOnApplied") {
            defaults.set(true, forKey: "PipDesktopChatsEnabled")
            defaults.set(true, forKey: "PipDesktopChatsDefaultOnApplied")
        }
        return defaults.bool(forKey: "PipDesktopChatsEnabled")
    }()
    private var desktopProvider = UserDefaults.standard.string(forKey: "PipDesktopProvider") ?? "codex"
    private var desktopConnectItem: NSMenuItem?
    private var desktopStatusItem: NSMenuItem?
    private var desktopStatusText = "Desktop chats are off"
    private var desktopStatusDetail: String?
    private var desktopActivityText: String?
    private var approvalReceiver: ApprovalReceiver?
    private var sessionNavigator: SessionNavigator?
    private var setup: SetupController?
    private let previewPath: String?
    private let previewQuestion: Bool
    private let previewChat: Bool
    private let previewIdle: Bool
    private let runtimePath: String

    init(arguments: [String]) {
        func value(after option: String) -> String? {
            guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        previewPath = value(after: "--preview") ?? value(after: "--preview-chat") ?? value(after: "--preview-idle")
        previewQuestion = arguments.contains("--preview-question")
        previewChat = arguments.contains("--preview-chat")
        previewIdle = arguments.contains("--preview-idle")
        let bundle = Bundle.main.bundleURL
        let launchRoot = bundle.pathExtension == "app" ?
            bundle.deletingLastPathComponent().deletingLastPathComponent() :
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let configured = (Bundle.main.object(forInfoDictionaryKey: "CompanionRuntimePath") as? String).flatMap { $0.hasPrefix("/") ? $0 : nil }
        runtimePath = value(after: "--runtime") ?? ProcessInfo.processInfo.environment["PET_RUNTIME_DIR"] ?? configured ??
            (PipRuntime.helper() != nil ? PipRuntime.support.appendingPathComponent(".runtime").path : launchRoot.appendingPathComponent(".runtime").path)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--preview-appearance"), index + 1 < CommandLine.arguments.count {
            NSApp.appearance = NSAppearance(named: CommandLine.arguments.contains("--preview-dark") ? .darkAqua : .aqua)
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("pip-appearance-preview-" + UUID().uuidString)
            do {
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: temporary) }
                let controller = AppearanceController(store: try CharacterStore(runtime: temporary))
                let selected = CommandLine.arguments.firstIndex(of: "--preview-character").flatMap {
                    $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil
                } ?? "default"
                try controller.renderPreview(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]),
                    selectedBuiltInID: selected, mood: CommandLine.arguments.contains("--preview-working") ? "working" : "idle")
            } catch { fputs("Appearance preview error: \(error.localizedDescription)\n", stderr) }
            NSApp.terminate(nil); return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--preview-setup"), index + 1 < CommandLine.arguments.count {
            NSApp.appearance = NSAppearance(named: CommandLine.arguments.contains("--preview-dark") ? .darkAqua : .aqua)
            let controller = SetupController(helper: URL(fileURLWithPath: "/unavailable"), installed: true, preview: true)
            try? controller.renderPreview(to: CommandLine.arguments[index + 1]); NSApp.terminate(nil); return
        }
        if let previewPath {
            let appearance = NSAppearance(named: ProcessInfo.processInfo.arguments.contains("--preview-dark") ? .darkAqua : .aqua)
            NSApp.appearance = appearance; content.appearance = appearance
            renderPreview(path: previewPath); return
        }
        if AppInstallation.handleLaunchIfNeeded() { return }
        createPanel()
        createTray()
        configureDesktopChats()
        content.onDecision = { [weak self] allow in self?.decide(allow: allow) }
        content.onNavigate = { [weak self] delta in self?.navigate(delta: delta) }
        content.onQuestion = { [weak self] answers in self?.answerQuestion(answers: answers) }
        content.onOpenSession = { [weak self] request in self?.openOriginatingSession(request) }
        content.onChat = { [weak self] provider in self?.openProvider(provider) }
        content.onMiniChat = { [weak self] in self?.showMiniChat() }
        content.pet.setAccessibilityElement(true)
        content.pet.setAccessibilityRole(.image)
        content.pet.setAccessibilityLabel("Pip robot · drag to move")
        updateDesktopHelp()
        do {
            guard runtimePath.hasPrefix("/") else { throw CompanionError.message("Use an absolute path for --runtime.") }
            store = try RuntimeStore(root: URL(fileURLWithPath: runtimePath))
            characterStore = try? CharacterStore(runtime: URL(fileURLWithPath: runtimePath))
            if let profile = try? characterStore?.load(), let character = try? profile.decoded() {
                updateCharacter(character)
            }
            approvalReceiver = ApprovalReceiver.configured(runtime: runtimePath)
            approvalReceiver?.start()
        } catch {
            self.error = error.localizedDescription
            content.configure(request: nil, position: 0, count: 0, sessions: [], error: self.error)
        }
        panel.orderFrontRegardless()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        if PipRuntime.helper() != nil && (CommandLine.arguments.contains("--agent-connections") || !UserDefaults.standard.bool(forKey: "PipConnectionSetupOffered")) {
            UserDefaults.standard.set(true, forKey: "PipConnectionSetupOffered")
            showAgentConnections()
        }
    }

    private func createPanel() {
        panel = CompanionPanel(contentRect: content.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = content
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Pet/background drag gestures are handled explicitly; AppKit must not
        // turn a click on a transparent custom view into automatic window dragging.
        panel.isMovableByWindowBackground = false; panel.isReleasedWhenClosed = false
        panel.title = "Pip · Agent Companion"
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - content.frame.width - 28,
                                         y: screen.visibleFrame.minY + 40))
        }
    }

    private func createTray() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let robot = NSImage(size: NSSize(width: 20, height: 20), flipped: true) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            RobotArt.draw(in: context, bounds: bounds); return true
        }
        robot.accessibilityDescription = "Pip robot companion"
        item.button?.image = robot
        let menu = NSMenu()
        let title = NSMenuItem(title: "Pip · Agent Companion", action: nil, keyEquivalent: "")
        title.isEnabled = false; menu.addItem(title)
        let show = NSMenuItem(title: "Show companion", action: #selector(showCompanion), keyEquivalent: "")
        show.target = self; menu.addItem(show)
        let openChat = NSMenuItem(title: "Open mini-chat", action: #selector(showMiniChat), keyEquivalent: "")
        openChat.target = self; menu.addItem(openChat)
        let appearanceItem = NSMenuItem(title: "Appearance…", action: #selector(showAppearance), keyEquivalent: ",")
        appearanceItem.target = self; menu.addItem(appearanceItem)
        if PipRuntime.helper() != nil {
            let connections = NSMenuItem(title: "Agent connections…", action: #selector(showAgentConnections), keyEquivalent: "")
            connections.target = self; menu.addItem(connections)
        }
        let sessionLinks = NSMenuItem(title: "Connect VS Code session links…", action: #selector(connectVSCodeSessionLinks), keyEquivalent: "")
        sessionLinks.target = self; menu.addItem(sessionLinks)
        let main = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu(title: "Pip")
        let settings = NSMenuItem(title: "Appearance…", action: #selector(showAppearance), keyEquivalent: ",")
        settings.target = self; appMenu.addItem(settings)
        let appQuit = NSMenuItem(title: "Quit Pip", action: #selector(quit), keyEquivalent: "q")
        appQuit.target = self; appMenu.addItem(appQuit); appItem.submenu = appMenu
        main.addItem(appItem); NSApp.mainMenu = main
        let connect = NSMenuItem(title: "Connect desktop chats", action: #selector(toggleDesktopChats), keyEquivalent: "")
        connect.target = self; connect.state = desktopChatsEnabled ? .on : .off
        menu.addItem(connect); desktopConnectItem = connect
        let desktopStatus = NSMenuItem(title: desktopChatsEnabled ? "Connecting to Claude…" : "Desktop chats are off", action: nil, keyEquivalent: "")
        desktopStatus.isEnabled = false; menu.addItem(desktopStatus); desktopStatusItem = desktopStatus
        let accessibility = NSMenuItem(title: "Accessibility settings…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        accessibility.target = self; menu.addItem(accessibility)
        let info = NSMenuItem(title: "Local mailbox: " + runtimePath, action: nil, keyEquivalent: "")
        info.isEnabled = false; menu.addItem(info)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit companion", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit); item.menu = menu; statusItem = item
    }

    @objc private func showCompanion() { panel.orderFrontRegardless() }
    @objc private func showMiniChat() { chatController().show() }
    @objc private func connectVSCodeSessionLinks() {
        guard let package = Bundle.main.url(forResource: "PipSessionLinks", withExtension: "vsix"),
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode"),
              Bundle(url: app)?.bundleIdentifier == "com.microsoft.VSCode" else {
            content.showError("VS Code or Pip's session-links package is unavailable."); return
        }
        let command = app.appendingPathComponent("Contents/Resources/app/bin/code")
        guard FileManager.default.isExecutableFile(atPath: command.path) else {
            content.showError("VS Code's extension installer is unavailable."); return
        }
        let alert = NSAlert()
        alert.messageText = "Connect VS Code session links"
        alert.informativeText = "Install Pip Session Links in VS Code to return to the correct chat or existing terminal. The helper shares local workspace and terminal identifiers with Pip. It does not read chats, edit files, or run agent commands."
        alert.addButton(withTitle: "Install helper"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = command
            process.arguments = ["--install-extension", package.path, "--force"]
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "NODE_OPTIONS"); environment.removeValue(forKey: "NODE_PATH")
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do { try process.run(); process.waitUntilExit() }
            catch { DispatchQueue.main.async { self?.content.showError("VS Code could not install Pip Session Links.") }; return }
            let succeeded = process.terminationStatus == 0
            DispatchQueue.main.async {
                let result = NSAlert()
                result.messageText = succeeded ? "Pip Session Links installed" : "Session links could not be installed"
                result.informativeText = succeeded ? "In each VS Code window, run “Pip: Refresh Session Links” from the Command Palette. If VS Code requests a reload, finish active agent work before reloading that window. Then try a new request." : "Try Extensions → Install from VSIX in VS Code using Pip's bundled PipSessionLinks.vsix package."
                result.addButton(withTitle: "OK"); result.runModal()
            }
        }
    }

    private func openOriginatingSession(_ request: PermissionRequest) {
        guard let snapshot = displayed, snapshot.request.id == request.id, snapshot.request.canOpenSession,
              snapshot.request.expiresAt > Date().timeIntervalSince1970, let store,
              error == nil, !processingDecision, let token = sessionHandoff.begin(snapshot) else { return }
        content.setActionsEnabled(false)
        if sessionNavigator == nil { sessionNavigator = SessionNavigator(runtime: URL(fileURLWithPath: runtimePath)) }
        sessionNavigator?.open(snapshot.request) { [weak self] failure in
            guard let self, self.sessionHandoff.isCurrent(token) else { return }
            let stillCurrent = self.displayed?.request.id == snapshot.request.id && self.displayed?.bytes == snapshot.bytes
            do {
                let transferred = try self.sessionHandoff.finish(token, opened: failure == nil,
                    current: self.displayed, now: Date().timeIntervalSince1970) { try store.handoff($0) }
                if transferred {
                    // Poll recognizes the correlated defer immediately. Other
                    // queued requests remain available; an empty queue collapses.
                    self.lastPoll = 0; self.tick()
                } else if stillCurrent, let message = failure?.errorDescription {
                    self.content.showError(message)
                }
            } catch {
                if stillCurrent { self.content.showError(error.localizedDescription) }
            }
        }
    }
    @objc private func showAgentConnections() {
        guard let helper = PipRuntime.helper() else { return }
        if setup == nil {
            setup = SetupController(helper: helper, installed: PipRuntime.installed())
            setup?.onChange = { [weak self] provider in
                guard let self, provider == "claude" else { return }
                self.approvalReceiver?.stop()
                self.approvalReceiver = ApprovalReceiver.configured(runtime: self.runtimePath)
                self.approvalReceiver?.start()
            }
        }
        setup?.show()
    }
    @objc private func showAppearance() {
        do {
            if characterStore == nil { characterStore = try CharacterStore(runtime: URL(fileURLWithPath: runtimePath)) }
            guard let characterStore else { return }
            if appearance == nil {
                let controller = AppearanceController(store: characterStore)
                controller.onChange = { [weak self] character in self?.updateCharacter(character) }
                appearance = controller
            }
            appearance?.show()
        } catch {
            let alert = NSAlert(); alert.messageText = "Appearance is unavailable"
            alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }
    private func updateCharacter(_ character: RobotArt.Character?) {
        RobotArt.setCharacter(character); content.pet.needsDisplay = true
        content.pet.setAccessibilityLabel(character == nil ? "Pip robot · drag to move" : "Pip character · drag to move")
        let icon = NSImage(size: NSSize(width: 20, height: 20), flipped: true) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            RobotArt.draw(in: context, bounds: bounds); return true
        }
        icon.accessibilityDescription = "Pip companion"; statusItem?.button?.image = icon
    }
    private func configureDesktopChats() {
        desktopChats.onActivity = { [weak self] activity in
            guard let self, self.desktopChatsEnabled, activity.provider == "claude", self.desktopProvider == "claude" else { return }
            switch activity.phase {
            case .thinking:
                self.desktopActivityText = ProviderApps.label(activity.provider) + " is replying"
            case .completed, .replyReady:
                self.desktopActivityText = activity.reply == nil ? ProviderApps.label(activity.provider) + " finished responding" :
                    "New short " + ProviderApps.label(activity.provider) + " reply received"
            case .connected, .reset, .stopped, .failed:
                self.desktopActivityText = nil
            }
            self.updateDesktopHelp()
            let now = Date().timeIntervalSince1970
            self.conversationBubble.receive(activity, now: now)
            self.updateConversationBubble(at: now)
        }
        desktopChats.onConnection = { [weak self] connection in
            guard let self, self.desktopChatsEnabled, connection.provider == "claude", self.desktopProvider == "claude" else { return }
            let provider = ProviderApps.label(connection.provider)
            let status: String
            switch connection.status {
            case .connected:
                let title = connection.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                status = provider + " chat connected" + (title.isEmpty ? "" : ": " + title)
            case .permissionRequired:
                self.conversationBubble.disconnectDesktop()
                self.setDesktopStatus("Desktop chats enabled · Accessibility is needed to connect")
                self.updateConversationBubble(at: Date().timeIntervalSince1970)
                return
            case .notRunning: status = "Open " + provider + " to a chat"
            case .unsupported: status = provider + " chat content is unavailable"
            }
            self.setDesktopStatus(status, detail: connection.detail, preserveActivity: connection.status == .connected)
        }
        if desktopProvider == "codex" {
            setDesktopStatus("Codex activity bubbles are off · ChatGPT Chat is not connected")
        } else if desktopChatsEnabled {
            setDesktopStatus("Connecting to " + ProviderApps.label(desktopProvider) + "…")
            desktopChats.select(provider: desktopProvider); desktopChats.start()
        }
    }
    private func setDesktopChatsEnabled(_ enabled: Bool) {
        desktopChatsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "PipDesktopChatsEnabled")
        desktopConnectItem?.state = enabled ? .on : .off
    }
    private func disconnectDesktopChats() {
        setDesktopChatsEnabled(false)
        desktopChats.stop()
        conversationBubble.disconnectDesktop()
        setDesktopStatus("Desktop chats are off")
        updateConversationBubble(at: Date().timeIntervalSince1970)
    }
    @objc private func toggleDesktopChats() {
        if desktopChatsEnabled {
            disconnectDesktopChats()
            return
        }
        if desktopProvider == "codex" {
            setDesktopStatus("Codex activity bubbles are off · ChatGPT Chat is not connected")
            return
        }
        guard DesktopChatObserver.hasAccessibilityPermission else {
            setDesktopChatsEnabled(true)
            desktopChats.select(provider: desktopProvider); desktopChats.start()
            setDesktopStatus("Desktop chats enabled · Accessibility is needed to connect")
            let alert = NSAlert()
            alert.messageText = "Connect Pip to Claude desktop chats"
            alert.informativeText = "Desktop chat reading is optional. Claude Code and Codex approvals work without Accessibility. To read Claude chat activity locally, enable Pip in Privacy & Security → Accessibility. Pip will connect automatically once permission is available."
            alert.addButton(withTitle: "Open Settings"); alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn { openAccessibilitySettings() }
            return
        }
        setDesktopChatsEnabled(true)
        setDesktopStatus("Connecting to " + ProviderApps.label(desktopProvider) + "…")
        desktopChats.select(provider: desktopProvider); desktopChats.start()
    }
    private func setDesktopStatus(_ status: String, detail: String? = nil, preserveActivity: Bool = false) {
        desktopStatusText = status; desktopStatusDetail = detail
        if !preserveActivity { desktopActivityText = nil }
        desktopStatusItem?.title = status
        desktopStatusItem?.toolTip = detail
        updateDesktopHelp()
    }
    private func updateDesktopHelp() {
        let detail = desktopStatusDetail.map { ". " + $0 } ?? ""
        let activity = desktopActivityText.map { ". " + $0 } ?? ""
        content.setDesktopChatStatus(desktopStatusText + detail + activity)
    }
    @objc private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
    private func openProvider(_ provider: String) {
        providerApps.open(provider: provider, opened: { [weak self] selected in
            guard let self else { return }
            let now = Date().timeIntervalSince1970
            self.conversationBubble.opened(provider: selected, now: now)
            self.selectDesktopProvider(selected)
            self.updateConversationBubble(at: now)
        }, fallback: { [weak self] selected in
            guard let self else { return }
            self.selectDesktopProvider(selected)
            self.chatController().show(provider: selected)
        })
    }
    private func selectDesktopProvider(_ provider: String) {
        desktopProvider = provider
        UserDefaults.standard.set(provider, forKey: "PipDesktopProvider")
        conversationBubble.disconnectDesktop()
        if provider == "codex" {
            desktopChats.stop()
            setDesktopStatus("Codex activity bubbles are off · ChatGPT Chat is not connected")
        } else if desktopChatsEnabled {
            setDesktopStatus("Connecting to " + ProviderApps.label(provider) + "…")
            desktopChats.select(provider: provider); desktopChats.start()
        } else {
            setDesktopStatus("Desktop chats are off")
        }
    }
    private func chatController() -> MiniChatController {
        if let chat { return chat }
        let controller = MiniChatController(runtimeURL: URL(fileURLWithPath: runtimePath))
        controller.onActivity = { [weak self] activity in
            guard let self else { return }
            let now = Date().timeIntervalSince1970
            self.conversationBubble.receive(activity, now: now)
            self.updateConversationBubble(at: now)
        }
        chat = controller; return controller
    }
    private func updateConversationBubble(at now: Double) {
        guard let panel else { return }
        conversationBubble.refresh(anchor: panel, pet: content.pet, permissionActive: displayed != nil, now: now)
    }
    @objc private func quit() { NSApp.terminate(nil) }

    private func tick() {
        let now = Date().timeIntervalSince1970
        content.animate(at: now)
        updateConversationBubble(at: now)
        guard now - lastPoll >= 0.4 else { return }
        lastPoll = now
        guard let store else { return }
        do {
            store.codexActivityEnabled = false
            let (newPending, newSessions) = try store.poll(now: now)
            _ = try store.consumeCodexActivities(now: now)
            updateConversationBubble(at: now)
            pending = newPending; sessions = newSessions
            let summary = newSessions.map { "\($0.source):\($0.sessionId):\($0.status)" }.joined(separator: "|")
            let previousError = error; error = nil
            var target: RequestSnapshot?
            if let current = displayed { target = pending.first { $0.request.id == current.request.id } }
            if target == nil { target = pending.first }
            let changed = target?.request.id != displayed?.request.id || target?.bytes != displayed?.bytes
            sessionHandoff.cancelIfChanged(target)
            if changed || previousError != nil || (target == nil && summary != sessionSummary) {
                displayed = target
                if changed { displayedAt = now; processingDecision = false }
                refresh()
                if target != nil && changed {
                    panel.orderFrontRegardless()
                    content.refreshSessionCursorRects()
                }
            }
            sessionSummary = summary
            if let current = displayed, let index = pending.firstIndex(where: { $0.request.id == current.request.id }) {
                content.updateQueue(position: index + 1, count: pending.count)
            }
            content.updateCountdown(now: now)
            content.setActionsEnabled(displayed != nil && !processingDecision && !sessionHandoff.isOpening &&
                                      now - displayedAt >= 0.6 && now >= actionCooldownUntil)
            lastTick = now
        } catch {
            store.stopHeartbeat()
            let message = error.localizedDescription
            if self.error != message {
                self.error = message; refresh()
            }
            content.setActionsEnabled(false)
        }
    }

    private func refresh() {
        let oldFrame = panel.frame
        let position = displayed.flatMap { request in pending.firstIndex { $0.request.id == request.request.id } }.map { $0 + 1 } ?? 0
        content.configure(request: displayed?.request, position: position, count: pending.count, sessions: sessions, error: error)
        let size = content.frame.size
        var origin = NSPoint(x: oldFrame.maxX - size.width, y: oldFrame.minY)
        if let screen = panel.screen ?? NSScreen.main {
            origin.x = min(max(origin.x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
            origin.y = min(max(origin.y, screen.visibleFrame.minY + 8), screen.visibleFrame.maxY - size.height - 8)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        content.refreshSessionCursorRects()
        content.refreshHover()
        updateConversationBubble(at: Date().timeIntervalSince1970)
        content.setActionsEnabled(false)
    }

    private func decide(allow: Bool) {
        let now = Date().timeIntervalSince1970
        guard let store, let snapshot = displayed, error == nil, !processingDecision, !sessionHandoff.isOpening,
              now - displayedAt >= 0.6, now >= actionCooldownUntil, now - lastTick < 1.5 else { return }
        processingDecision = true; actionCooldownUntil = now + 0.8
        content.setActionsEnabled(false)
        do {
            if snapshot.request.responseAvailable { try store.decide(snapshot, allow: allow) }
            else { try store.dismissNotice(snapshot) }
            lastPoll = 0
            tick()
        } catch {
            self.error = error.localizedDescription
            refresh(); content.setActionsEnabled(false)
            // The next poll reads the exact request again before any action can be enabled.
            displayedAt = now; processingDecision = false
        }
    }

    private func navigate(delta: Int) {
        guard !processingDecision, !sessionHandoff.isOpening, pending.count > 1, let current = displayed,
              let index = pending.firstIndex(where: { $0.request.id == current.request.id }) else { return }
        let target = pending[(index + delta + pending.count) % pending.count]
        guard target.request.expiresAt > Date().timeIntervalSince1970 else { lastPoll = 0; tick(); return }
        displayed = target; displayedAt = Date().timeIntervalSince1970
        refresh(); lastPoll = 0; tick()
    }

    private func answerQuestion(answers: [String: String]?) {
        let now = Date().timeIntervalSince1970
        guard let store, let snapshot = displayed, snapshot.request.isQuestion, error == nil,
              !processingDecision, !sessionHandoff.isOpening, now - displayedAt >= 0.6,
              now >= actionCooldownUntil, now - lastTick < 1.5 else { return }
        processingDecision = true; actionCooldownUntil = now + 0.8; content.setActionsEnabled(false)
        do {
            try store.answer(snapshot, answers: answers)
            lastPoll = 0; tick()
        } catch {
            content.showError(error.localizedDescription)
            displayedAt = now; processingDecision = false
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate(); desktopChats.stop(); conversationBubble.hide(); approvalReceiver?.stop(); store?.stopHeartbeat(); chat?.shutdown()
    }

    private func renderPreview(path: String) {
        if previewChat {
            do {
                try chatController().preview(to: URL(fileURLWithPath: path))
                print("Saved chat preview to \(path)")
            } catch { fputs("Preview error: \(error.localizedDescription)\n", stderr) }
            NSApp.terminate(nil); return
        }
        let now = Date().timeIntervalSince1970
        let previewRead = ProcessInfo.processInfo.arguments.contains("--preview-read")
        let previewLongSession = ProcessInfo.processInfo.arguments.contains("--preview-long-session")
        let previewNavigation = ProcessInfo.processInfo.arguments.contains("--preview-session-navigation")
        let sample = PermissionRequest(schemaVersion: 1, id: String(repeating: "a", count: 32), source: "claude",
            sourceLabel: "Claude Code", sessionId: previewNavigation ? "38f4f440-e050-460f-a9d0-84274d9e9cce" : "local-demo-session", toolName: previewRead ? "Read" : "Bash", cwd: "/Users/example/Projects/my-app",
            reason: previewRead ? "Claude needs to read this file to understand how permission requests are handled before changing the approval flow." : "Run the test suite", detailText: previewRead ? "{\"file_path\":\"/Users/example/Library/Application Support/AgentCompanion/bridge.py\",\"offset\":810,\"limit\":32}" : "{\n  \"command\": \"npm test\",\n  \"description\": \"Run the test suite\"\n}",
            isDemo: !previewNavigation, createdAt: now, expiresAt: now + 174, canRespond: nil,
            kind: previewQuestion ? "question" : nil,
            questions: previewQuestion ? [UserQuestion(question: "Should I run the test suite before continuing?", header: "Next step",
                options: [QuestionOption(label: "Yes, run the tests", description: "Check the changes before moving on."),
                          QuestionOption(label: "Continue for now", description: "I will review the tests later.")], multiSelect: false)] : nil,
            sessionName: previewLongSession ? "Preserve anchor links during the documentation content migration" : "Fix anchor tag preservation",
            sessionHost: previewNavigation ? "claude-vscode" : nil)
        content.configure(request: previewIdle ? nil : sample, position: 1, count: 2, sessions: [], error: nil)
        content.setActionsEnabled(true); content.pet.phase = 0
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            fputs("Cannot render preview.\n", stderr); NSApp.terminate(nil); return
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        do {
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CompanionError.message("Cannot encode preview.") }
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
            print("Saved preview to \(path)")
        } catch { fputs("Preview error: \(error.localizedDescription)\n", stderr) }
        NSApp.terminate(nil)
    }
}

#if !PIP_COMPANION_CHECKS
@main
struct CompanionMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate(arguments: CommandLine.arguments)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
