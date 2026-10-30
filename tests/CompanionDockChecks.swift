import AppKit
import Foundation

@main
struct CompanionDockChecks {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var checks = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: "CompanionDockChecks", code: checks + 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1
        }
        func center(_ rectangle: NSRect) -> NSPoint { NSPoint(x: rectangle.midX, y: rectangle.midY) }
        let companion = CompanionView()
        let panel = CompanionPanel(contentRect: NSRect(x: -10000, y: -10000, width: 240, height: 164),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.contentView = companion
        defer { panel.close() }
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let dock = companion.subviews.first { view in
            view.subviews.compactMap { $0 as? NSButton }.map(\.title) == ["Claude", "ChatGPT", "Mini Chat"]
        }!
        let buttons = dock.subviews.compactMap { $0 as? NSButton }
        var providers: [String] = [], miniChatOpens = 0
        companion.onChat = { providers.append($0) }
        companion.onMiniChat = { miniChatOpens += 1 }
        try check(companion.frame.size == CompanionIdleLayout.size && companion.bounds.contains(dock.frame),
            "The three-button dock fits entirely inside the collapsed companion")
        try check(companion.pet.frame.midX == companion.bounds.midX &&
                  CompanionIdleLayout.handle.midX == companion.bounds.midX,
            "The pet and collapsed handle stay centered above all three choices")
        try check(dock.isHidden, "The dock begins collapsed")
        companion.updateHover(at: center(companion.pet.frame))
        try check(dock.isHidden, "Hovering the draggable pet does not expand controls")
        companion.updateHover(at: center(CompanionIdleLayout.handle))
        try check(!dock.isHidden, "Hovering the small handle expands controls")
        for button in buttons {
            try check(dock.bounds.contains(button.frame) && button.frame.width >= 68,
                "\(button.title) has its full usable click area inside the dock")
            for other in buttons where other !== button {
                try check(!button.frame.intersects(other.frame), "All three button click areas remain distinct")
            }
            let point = companion.convert(center(button.bounds), from: button)
            companion.updateHover(at: point)
            try check(!dock.isHidden && companion.hitTest(companion.convert(point, to: companion.superview)) === button,
                "Moving from the handle onto \(button.title) retains the dock and hits the real button")
            try check(button.acceptsFirstMouse(for: nil) && !button.mouseDownCanMoveWindow,
                "\(button.title) accepts an inactive-panel click without dragging")
            for local in [NSPoint(x: 1, y: 1), center(button.bounds),
                          NSPoint(x: button.bounds.maxX - 1, y: button.bounds.maxY - 1)] {
                let down = event(.leftMouseDown, button.convert(local, to: nil))
                try check(panel.contentView!.superview!.hitTest(down.locationInWindow) === button,
                    "The full hidden AppKit window hierarchy delivers the mouse event to \(button.title)")
                let hit = button.cell!.hitTest(for: down, in: button.bounds, of: button)
                try check(hit.contains([.contentArea, .trackableArea]),
                    "\(button.title) tracks real mouse events across its entire drawn area")
            }
            let outside = event(.leftMouseUp, button.convert(NSPoint(x: -1, y: 1), to: nil))
            try check(button.cell!.hitTest(for: outside, in: button.bounds, of: button).isEmpty,
                "Releasing outside \(button.title) does not hit its cell")
            button.isEnabled = false
            let disabledDown = event(.leftMouseDown, button.convert(center(button.bounds), to: nil))
            try check(button.cell!.hitTest(for: disabledDown, in: button.bounds, of: button).isEmpty,
                "Disabled \(button.title) rejects mouse tracking")
            button.isEnabled = true
            let titleSize = (button.title as NSString).size(withAttributes: [.font: button.font!])
            try check(titleSize.width <= button.bounds.width - 8,
                "The complete \(button.title) title fits without truncation")
            button.performClick(nil)
        }
        try check(providers == ["claude", "codex"] && miniChatOpens == 1,
            "Claude and ChatGPT retain provider routing while Mini Chat uses its independent callback")
        buttons[2].performClick(nil)
        try check(miniChatOpens == 2 && providers == ["claude", "codex"],
            "Repeated Mini Chat clicks cannot invoke installed-app provider routing")
        try check(buttons[2].toolTip == "Open Pip’s mini chat · Claude Code or Codex CLI",
            "Mini Chat describes its local CLI providers without implying desktop conversation sync")
        let previews = URL(fileURLWithPath: ".build/companion-dock-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        try check(RobotArt.useSpriteSheet(at: URL(fileURLWithPath: "desktop/Resources/PipSpriteSheet.png")),
            "Offscreen dock previews use Pip’s actual bundled sprite source")
        for (theme, appearance) in [("light", NSAppearance(named: .aqua)!), ("dark", NSAppearance(named: .darkAqua)!)] {
            companion.appearance = appearance
            companion.updateHover(at: center(CompanionIdleLayout.handle))
            let bitmap = companion.bitmapImageRepForCachingDisplay(in: companion.bounds)!
            appearance.performAsCurrentDrawingAppearance { companion.cacheDisplay(in: companion.bounds, to: bitmap) }
            try bitmap.representation(using: .png, properties: [:])!.write(to: previews.appendingPathComponent(theme + ".png"))
        }
        companion.updateHover(at: NSPoint(x: companion.bounds.maxX + 1, y: 130))
        try check(dock.isHidden, "Leaving the complete controls area collapses the dock")
        companion.updateHover(at: companion.convert(center(buttons[2].bounds), from: buttons[2]))
        try check(dock.isHidden, "A hidden outer button cannot expand the dock without entering the handle")

        let petPoint = companion.pet.convert(center(companion.pet.bounds), to: nil)
        let origin = panel.frame.origin
        companion.pet.mouseDown(with: event(.leftMouseDown, petPoint))
        companion.pet.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: petPoint.x + 12, y: petPoint.y + 8)))
        companion.pet.mouseUp(with: event(.leftMouseUp, petPoint))
        try check(panel.frame.origin == NSPoint(x: origin.x + 12, y: origin.y + 8),
            "The centered pet still drags its companion through the production mouse handlers")
        try check(providers == ["claude", "codex"] && miniChatOpens == 2,
            "Dragging the pet does not trigger any chat choice")
        let request = PermissionRequest(schemaVersion: 1, id: String(repeating: "a", count: 32), source: "claude",
            sourceLabel: "Claude Code", sessionId: "dock-check", toolName: "Read", cwd: "/tmp", reason: "Read file",
            detailText: "{}", isDemo: true, createdAt: 0, expiresAt: 60, canRespond: nil, kind: nil, questions: nil)
        companion.configure(request: request, position: 1, count: 1, sessions: [], error: nil)
        companion.updateHover(at: center(CompanionIdleLayout.handle))
        try check(dock.isHidden && companion.frame.size.width == 460,
            "Permission cards retain their existing width and hide all three idle chat choices")
        companion.configure(request: nil, position: 0, count: 0, sessions: [], error: nil)
        try check(companion.frame.size == CompanionIdleLayout.size && companion.pet.frame == CompanionIdleLayout.pet,
            "Returning from a permission restores the centered three-button companion layout")
        let miniRuntime = FileManager.default.temporaryDirectory.appendingPathComponent("pip-mini-chat-check-" + UUID().uuidString)
        let mini = MiniChatController(runtimeURL: miniRuntime)
        try mini.preview(to: previews.appendingPathComponent("mini-chat.png"))
        let miniPanel = NSApp.windows.first { $0.title == "Pip chat" }!
        let miniBody = miniPanel.contentView!
        let picker = miniBody.subviews.compactMap { $0 as? NSPopUpButton }.first!
        try check(picker.itemTitles == ["Claude Code", "Codex CLI"],
            "The existing Mini Chat provider picker explicitly identifies its two CLI providers")
        try check(picker.toolTip?.contains("local Claude Code or Codex CLI") == true,
            "The provider picker explains its local CLI connection")
        picker.selectItem(at: 1)
        try check(NSApp.sendAction(picker.action!, to: picker.target, from: picker),
            "The actual Mini Chat provider picker routes its selection action")
        try mini.preview(to: previews.appendingPathComponent("mini-chat-codex.png"))
        try check(picker.indexOfSelectedItem == 1 && picker.titleOfSelectedItem == "Codex CLI",
            "Opening another Mini Chat preview preserves the provider selected in its own UI")
        try check(!miniPanel.isVisible && !miniPanel.isKeyWindow && !FileManager.default.fileExists(atPath: miniRuntime.path),
            "Mini Chat previews and provider changes neither show a window nor create live conversation workspaces")
        mini.shutdown()
        try check(!panel.isVisible && !panel.isKeyWindow && !NSApp.isActive,
            "Dock checks do not show or activate windows, launch providers, or open Mini Chat")
        print("Passed \(checks) companion dock geometry, hover, routing, and drag checks. No live UI or model calls.")
    }
}
