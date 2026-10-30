import AppKit
import Foundation

private final class ActionCheckTarget: NSObject {
    var actions = 0
    @objc func decide(_ sender: NSButton) { actions += 1 }
}

private final class ActionCheckPanel: NSPanel {
    var invalidations = 0
    var rebuilds = 0
    override func invalidateCursorRects(for view: NSView) {
        invalidations += 1; super.invalidateCursorRects(for: view)
    }
    override func resetCursorRects() {
        rebuilds += 1; super.resetCursorRects()
    }
}

private final class ActionCursorProbe: NSView {
    var rebuilds = 0
    override func resetCursorRects() {
        rebuilds += 1; super.resetCursorRects(); addCursorRect(bounds, cursor: .arrow)
    }
}

@main struct ActionButtonChecks {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "ActionButtonChecks", code: checks + 1,
                                                 userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1
        }
        let target = ActionCheckTarget()
        let button = PointingHandButton(title: "Yes, allow once", target: target,
                                        action: #selector(ActionCheckTarget.decide(_:)))
        button.frame = NSRect(x: 24, y: 24, width: 267, height: 44)
        try check(!button.mouseDownCanMoveWindow && button.acceptsFirstMouse(for: nil),
                  "An action button accepts the first click without turning it into a window drag")
        let action = button.action
        let hoverOptions: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect]
        let cursorOptions: NSTrackingArea.Options = [.cursorUpdate, .activeInActiveApp, .inVisibleRect]
        for _ in 0..<3 {
            button.updateTrackingAreas()
            try check(button.trackingAreas.filter { $0.options.contains(hoverOptions) }.count == 1 &&
                      button.trackingAreas.filter { $0.options.contains(cursorOptions) }.count == 1,
                      "Repeated tracking updates retain one background hover area and one active cursor area")
        }
        try check(!button.trackingAreas.contains { $0.options.contains([.activeAlways, .cursorUpdate]) },
                  "Action buttons do not rely on cursor updates suppressed by activeAlways")
        guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else {
            throw NSError(domain: "ActionButtonChecks", code: -1)
        }
        var cursors: [NSCursor] = []
        button.cursorSetter = { cursors.append($0) }
        button.mouseEntered(with: event)
        try check(cursors.last === NSCursor.pointingHand, "An enabled action requests the hand on background hover")
        button.mouseMoved(with: event); button.cursorUpdate(with: event)
        try check(cursors.suffix(2).allSatisfy { $0 === NSCursor.pointingHand },
                  "Movement and active-app cursor updates retain the hand without clicking")
        button.isEnabled = false
        try check(cursors.last === NSCursor.arrow, "Disabling an action under the pointer immediately restores the arrow")
        button.mouseMoved(with: event); button.cursorUpdate(with: event)
        try check(cursors.suffix(2).allSatisfy { $0 === NSCursor.arrow },
                  "Disabled actions keep the arrow for both background and active-app updates")
        button.isEnabled = true
        try check(cursors.last === NSCursor.pointingHand, "Re-enabling a hovered action restores the hand without a click")
        button.mouseExited(with: event)
        try check(cursors.last === NSCursor.arrow, "Leaving the action releases the hand cursor")
        try check(target.actions == 0 && button.target === target && button.action == action,
                  "Hover and enabled-state changes never invoke or replace the decision action")

        let panel = ActionCheckPanel(contentRect: NSRect(x: -10000, y: -10000, width: 460, height: 650),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let probe = ActionCursorProbe(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        panel.contentView?.addSubview(probe); panel.contentView?.addSubview(button)
        try check(panel.acceptsMouseMovedEvents && panel.invalidations > 0 && panel.rebuilds > 0 &&
                  !panel.isVisible && !panel.isKeyWindow && !NSApp.isActive,
                  "Attaching rebuilds cursor regions while leaving the panel hidden, non-key and inactive")
        let previousRebuilds = panel.rebuilds, previousProbeRebuilds = probe.rebuilds
        button.frame.size.width = 133; button.refreshCursorRects()
        try check(panel.rebuilds > previousRebuilds && probe.rebuilds > previousProbeRebuilds &&
                  !panel.isKeyWindow && !NSApp.isActive,
                  "Post-layout refresh runs actual AppKit cursor rebuilding without activating Pip")
        button.mouseEntered(with: event)
        button.isEnabled = false
        try check(cursors.last === NSCursor.arrow && panel.rebuilds > previousRebuilds + 1,
                  "An attached hovered action resets its native cursor regions and arrow immediately when disabled")
        button.isEnabled = true; button.removeFromSuperview()
        try check(cursors.last === NSCursor.arrow && target.actions == 0,
                  "Removing a hovered action releases its hand without making a permission decision")
        panel.close()
        print("Action button checks passed:", checks,
              "No UI events posted, windows shown, app activation, permission decisions, or model calls.")
    }
}
