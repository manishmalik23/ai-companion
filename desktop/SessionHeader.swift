import AppKit

final class SessionHeaderButton: NSButton {
    let requestId: String
    let sessionName: String
    let context: String
    private let fullSessionID: String
    private var cursorTracking: NSTrackingArea?
    private var activeCursorTracking: NSTrackingArea?
    private var hovered = false
    var cursorSetter: (NSCursor) -> Void = { $0.set() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isEnabled: Bool {
        didSet {
            refreshCursorRects()
            if hovered { updateHeaderCursor() }
            needsDisplay = true
        }
    }

    init(request: PermissionRequest, target: AnyObject, action: Selector) {
        let presentation = SessionHeaderPresentation(request: request)
        requestId = request.id
        sessionName = presentation.subject
        context = presentation.context
        fullSessionID = presentation.fullSessionID
        super.init(frame: NSRect(x: 123, y: 24, width: 313, height: 66))
        self.target = target; self.action = action
        isBordered = false; isEnabled = presentation.usesLinkCursor
        title = sessionName
        toolTip = presentation.tooltip
        setAccessibilityLabel(presentation.accessibilityLabel)
        setAccessibilityHelp(presentation.accessibilityHelp)
        let contextual = NSMenu()
        contextual.autoenablesItems = false
        let copy = NSMenuItem(title: "Copy session ID", action: #selector(copySessionID), keyEquivalent: "")
        copy.target = self; copy.isEnabled = presentation.canCopySessionID
        contextual.addItem(copy); menu = contextual
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func copySessionID() {
        guard !fullSessionID.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fullSessionID, forType: .string)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A nonactivating panel still needs movement/cursor tracking while the
        // user is working in the originating app.
        refreshCursorRects()
    }

    func refreshCursorRects() {
        guard let window else { return }
        window.acceptsMouseMovedEvents = true
        window.invalidateCursorRects(for: self)
        // Invalidation alone defers rebuilding until the window becomes key.
        // Incoming cards deliberately remain non-key, so rebuild eagerly after
        // attachment and once their final panel geometry has been established.
        window.resetCursorRects()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil && hovered {
            hovered = false
            cursorSetter(.arrow)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func updateTrackingAreas() {
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        if let activeCursorTracking { removeTrackingArea(activeCursorTracking) }
        let tracking = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        cursorTracking = tracking; addTrackingArea(tracking)
        // AppKit does not deliver cursorUpdate for an activeAlways area. Keep
        // native cursor-update arbitration separate from background hover.
        let activeTracking = NSTrackingArea(rect: .zero,
            options: [.cursorUpdate, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil)
        activeCursorTracking = activeTracking; addTrackingArea(activeTracking)
        super.updateTrackingAreas()
    }

    private func updateHeaderCursor() { cursorSetter(isEnabled ? .pointingHand : .arrow) }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateHeaderCursor() }
    override func mouseMoved(with event: NSEvent) { updateHeaderCursor() }
    override func cursorUpdate(with event: NSEvent) { updateHeaderCursor() }
    override func mouseExited(with event: NSEvent) { hovered = false; cursorSetter(.arrow) }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: isEnabled ? .pointingHand : .arrow)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let nameStyle = NSMutableParagraphStyle(); nameStyle.lineBreakMode = .byTruncatingTail
            (sessionName as NSString).draw(in: NSRect(x: 0, y: 0, width: bounds.width - (isEnabled ? 27 : 0), height: 25),
                withAttributes: [.font: NSFont.systemFont(ofSize: 17, weight: .semibold),
                                 .foregroundColor: isEnabled ? NSColor.controlAccentColor : NSColor.labelColor, .paragraphStyle: nameStyle])
            let contextStyle = NSMutableParagraphStyle(); contextStyle.lineBreakMode = .byTruncatingTail
            (context as NSString).draw(in: NSRect(x: 0, y: 33, width: bounds.width, height: 20),
                withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .regular),
                                 .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: contextStyle])
            if isEnabled {
                ("↗" as NSString).draw(at: NSPoint(x: bounds.width - 19, y: 1),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 17, weight: .medium), .foregroundColor: NSColor.controlAccentColor])
            }
            if window?.firstResponder === self {
                NSColor.keyboardFocusIndicatorColor.setStroke()
                let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
                focus.lineWidth = 1; focus.stroke()
            }
        }
    }
}
