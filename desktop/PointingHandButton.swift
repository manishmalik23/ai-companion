import AppKit

/// Button cursor behavior for Pip's nonactivating panel. Hover does not make
/// the app active or turn the panel into the key window.
class PointingHandButton: NSButton {
    private var hoverTracking: NSTrackingArea?
    private var cursorTracking: NSTrackingArea?
    private var cursorHovered = false
    var cursorSetter: (NSCursor) -> Void = { $0.set() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isEnabled: Bool {
        didSet {
            refreshCursorRects()
            if cursorHovered { updateButtonCursor() }
            needsDisplay = true
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshCursorRects()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil && cursorHovered {
            cursorHovered = false
            cursorSetter(.arrow)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func refreshCursorRects() {
        guard let window else { return }
        window.acceptsMouseMovedEvents = true
        window.invalidateCursorRects(for: self)
        // Invalidation waits for a key window. Incoming cards intentionally
        // leave focus in the editor, so build the native cursor regions now.
        window.resetCursorRects()
    }

    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let hover = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        hoverTracking = hover; addTrackingArea(hover)
        // activeAlways suppresses cursorUpdate. Use a separate active-app
        // area for AppKit cursor arbitration, matching Pip's session headers.
        let cursor = NSTrackingArea(rect: .zero,
            options: [.cursorUpdate, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil)
        cursorTracking = cursor; addTrackingArea(cursor)
        super.updateTrackingAreas()
    }

    private func updateButtonCursor() { cursorSetter(isEnabled ? .pointingHand : .arrow) }
    override func mouseEntered(with event: NSEvent) { cursorHovered = true; updateButtonCursor() }
    override func mouseMoved(with event: NSEvent) { cursorHovered = true; updateButtonCursor() }
    override func cursorUpdate(with event: NSEvent) { cursorHovered = true; updateButtonCursor() }
    override func mouseExited(with event: NSEvent) { cursorHovered = false; cursorSetter(.arrow) }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: isEnabled ? .pointingHand : .arrow)
    }
}
