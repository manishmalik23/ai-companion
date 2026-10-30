import AppKit
import Foundation

private final class HeaderCheckTarget: NSObject {
    @objc func openSession(_ sender: NSButton) {}
}

private final class HeaderCheckPanel: NSPanel {
    var cursorInvalidations = 0
    var cursorRebuilds = 0
    override func invalidateCursorRects(for view: NSView) {
        cursorInvalidations += 1
        super.invalidateCursorRects(for: view)
    }
    override func resetCursorRects() {
        cursorRebuilds += 1
        super.resetCursorRects()
    }
}

private final class CursorRectProbe: NSView {
    var cursorRebuilds = 0
    override func resetCursorRects() {
        cursorRebuilds += 1
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }
}

@main struct SessionHeaderChecks {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let sessionID = "38f4f440-e050-460f-a9d0-84274d9e9cce"
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "SessionHeaderChecks", code: checks + 1,
                                                 userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1
        }
        func request(_ extra: [String: Any] = [:]) throws -> PermissionRequest {
            var data: [String: Any] = ["schemaVersion": 1, "id": String(repeating: "a", count: 32),
                "source": "claude", "sourceLabel": "Claude Code", "sessionId": sessionID,
                "toolName": "Bash", "cwd": "/Users/example/Projects/shared-workspace",
                "reason": "Check the change", "detailText": "{}", "isDemo": false,
                "createdAt": 1000.0, "expiresAt": 1120.0]
            data.merge(extra) { _, new in new }
            return try JSONDecoder().decode(PermissionRequest.self, from: JSONSerialization.data(withJSONObject: data))
        }

        let first = SessionHeaderPresentation(request: try request([
            "sessionName": "Fix anchor tag preservation", "sessionHost": "claude-vscode"]))
        let second = SessionHeaderPresentation(request: try request([
            "sessionName": "Improve checkout validation", "sessionHost": "claude-vscode"]))
        try check(first.subject == "Fix anchor tag preservation" && second.subject == "Improve checkout validation",
                  "Session subjects distinguish conversations within the same workspace")
        try check(first.context == "Claude Code · VS Code · shared-workspace" && first.context == second.context,
                  "Provider, host and workspace are secondary context rather than a shared title")
        try check(!first.subject.contains(sessionID) && !first.context.contains(sessionID),
                  "The technical ID is absent from both visible header labels")
        try check(first.fullSessionID == sessionID && first.canCopySessionID,
                  "The exact ID remains available to the copy-session-ID action")
        try check(first.tooltip.contains(sessionID) && first.tooltip.contains(first.subject) &&
                  first.accessibilityLabel.contains(sessionID),
                  "Tooltip and accessibility retain the full identity and subject")
        try check(first.usesLinkCursor && first.accessibilityHelp.contains("originating app"),
                  "A navigable session exposes a link cursor and its opening action")

        let unnamed = SessionHeaderPresentation(request: try request())
        try check(unnamed.subject == "Task: Run command" && !unnamed.subject.contains("shared-workspace"),
                  "Missing subjects explicitly describe the known action, not an inferred chat title")
        try check(unnamed.context == "Claude Code · shared-workspace" && !unnamed.usesLinkCursor,
                  "Unavailable navigation keeps context without offering a link cursor")
        let whitespace = SessionHeaderPresentation(request: try request(["sessionName": " \n\t "]))
        try check(whitespace.subject == unnamed.subject, "Blank host titles retain the honest generic fallback")
        let idAsTitle = SessionHeaderPresentation(request: try request(["sessionName": sessionID]))
        try check(idAsTitle.subject == unnamed.subject, "A host ID masquerading as a title is not shown as the subject")
        for name in ["shared-workspace", "SHARED-WORKSPACE", "shared-workspace/", "/Users/example/Projects/shared-workspace",
                     "11111111-1111-4111-8111-111111111111", "ID: " + sessionID, "Session ID: " + sessionID,
                     "UUID: [" + sessionID + "]", "Session UUID: {" + sessionID + "}", String(repeating: "a", count: 32)] {
            let fallback = SessionHeaderPresentation(request: try request([
                "source": "codex", "sourceLabel": "Codex", "sessionName": name,
                "detailText": "{\"description\":\"Review checkout changes\"}"]))
            try check(fallback.subject == "Task: Review checkout changes",
                      "A workspace or technical identifier cannot replace the Codex conversation subject")
            try check(fallback.context == "Codex · shared-workspace",
                      "Workspace context remains secondary when an invalid title falls back")
        }
        let idDescription = SessionHeaderPresentation(request: try request([
            "detailText": "{\"description\":\"ID: " + sessionID + "\"}"]))
        try check(idDescription.subject == unnamed.subject, "An ID-shaped task description also uses the friendly action fallback")
        let describedTask = SessionHeaderPresentation(request: try request([
            "detailText": "{\"description\":\"Check branch state and recent PRs\",\"command\":\"opaque --command\"}"]))
        try check(describedTask.subject == "Task: Check branch state and recent PRs",
                  "An existing friendly action description is explicitly labelled as a task fallback")
        let noDescription = SessionHeaderPresentation(request: try request([
            "toolName": "Unknown tool", "detailText": "{\"command\":\"never use this raw command as a title\"}"]))
        try check(noDescription.subject == "Claude Code session",
                  "Raw command text is never promoted to a chat subject")
        let actualSubject = SessionHeaderPresentation(request: try request([
            "sessionName": "Real saved conversation title", "detailText": "{\"description\":\"Different action\"}"]))
        try check(actualSubject.subject == "Real saved conversation title", "An actual subject always takes priority over task context")
        let longTask = SessionHeaderPresentation(request: try request([
            "detailText": "{\"description\":\"" + String(repeating: "a", count: 200) + "\"}"]))
        try check(longTask.subject == "Task: " + String(repeating: "a", count: 96) + "…",
                  "Long action descriptions remain a compact labelled fallback")

        let sanitized = SessionHeaderPresentation(request: try request([
            "sessionName": "  Fix\nanchor\u{202e} links\t ", "sourceLabel": "Claude\nCode",
            "sessionHost": "apple-terminal", "sessionId": "  source\u{202e}\nidentifier  "]))
        try check(sanitized.subject == "Fix anchor links" && sanitized.context == "Claude Code · Terminal · shared-workspace",
                  "Subject and context strip control and bidi formatting")
        try check(sanitized.fullSessionID == "source identifier", "Diagnostic ID data is sanitized without showing it in labels")

        let codex = SessionHeaderPresentation(request: try request([
            "source": "codex", "sourceLabel": "Codex", "sessionHost": "codex-vscode",
            "sessionName": "Review the checkout branch"]))
        try check(codex.subject == "Review the checkout branch" && codex.context == "Codex · VS Code · shared-workspace",
                  "Codex subjects and source context use the same header layout")
        try check(codex.usesLinkCursor, "A well-formed local Codex IDE identity permits window-link resolution")
        let wrongProvider = SessionHeaderPresentation(request: try request(["sessionHost": "codex-vscode"]))
        try check(!wrongProvider.usesLinkCursor, "A Claude request cannot claim the Codex IDE link policy")
        let invalidID = SessionHeaderPresentation(request: try request([
            "source": "codex", "sourceLabel": "Codex", "sessionHost": "codex-vscode", "sessionId": "../new?prompt=run"]))
        try check(!invalidID.usesLinkCursor, "Invalid technical IDs cannot offer Codex navigation")
        let relative = SessionHeaderPresentation(request: try request([
            "source": "codex", "sourceLabel": "Codex", "sessionHost": "codex-vscode", "cwd": "relative-project"]))
        try check(!relative.usesLinkCursor && relative.context == "Codex · VS Code",
                  "A relative path cannot claim a local Codex workspace")
        let demo = SessionHeaderPresentation(request: try request([
            "sessionHost": "claude-vscode", "isDemo": true]))
        try check(!demo.usesLinkCursor, "A simulated card never offers an active session cursor")
        let desktop = SessionHeaderPresentation(request: try request([
            "source": "codex", "sourceLabel": "Codex", "sessionHost": "codex-desktop", "cwd": "/"]))
        try check(desktop.context == "Codex · Desktop", "A filesystem root is not presented as a project title")

        let bounded = SessionHeaderPresentation(request: try request([
            "sessionName": String(repeating: "界", count: 1000),
            "sourceLabel": String(repeating: "p", count: 1000),
            "cwd": "/" + String(repeating: "folder", count: 1000)]))
        try check(bounded.subject.utf8.count <= 512 && bounded.context.utf8.count <= 512,
                  "Visible labels remain bounded for oversized host metadata")
        let absentID = SessionHeaderPresentation(request: try request(["sessionId": " \n\t "]))
        try check(!absentID.canCopySessionID && absentID.tooltip.contains("Unavailable"),
                  "An absent ID is not copied or represented as a usable identity")

        let target = HeaderCheckTarget()
        let clickable = SessionHeaderButton(request: try request([
            "source": "codex", "sourceLabel": "Codex", "sessionHost": "codex-vscode",
            "sessionName": "Review the checkout branch"]), target: target, action: #selector(HeaderCheckTarget.openSession(_:)))
        try check(clickable.title == codex.subject && clickable.context == codex.context && !clickable.context.contains(sessionID),
                  "The actual header control draws subject and context rather than an ID label")
        try check(clickable.toolTip?.contains(sessionID) == true && clickable.menu?.items.first?.title == "Copy session ID" &&
                  clickable.menu?.autoenablesItems == false && clickable.menu?.items.first?.isEnabled == true,
                  "The actual control retains exact identity diagnostics and explicit copy availability")
        clickable.updateTrackingAreas()
        let hoverOptions: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect]
        let cursorOptions: NSTrackingArea.Options = [.cursorUpdate, .activeInActiveApp, .inVisibleRect]
        try check(clickable.trackingAreas.filter { $0.options.contains(hoverOptions) }.count == 1 &&
                  clickable.trackingAreas.filter { $0.options.contains(cursorOptions) }.count == 1,
                  "Background hover and active-app cursor updates have separate AppKit tracking scopes")
        try check(!clickable.trackingAreas.contains { $0.options.contains([.activeAlways, .cursorUpdate]) },
                  "The header never relies on cursor updates suppressed by activeAlways")
        clickable.updateTrackingAreas()
        try check(clickable.trackingAreas.filter { $0.options.contains(hoverOptions) }.count == 1 &&
                  clickable.trackingAreas.filter { $0.options.contains(cursorOptions) }.count == 1,
                  "Tracking area replacement does not accumulate stale hover regions")

        var cursorValues: [NSCursor] = []
        clickable.cursorSetter = { cursorValues.append($0) }
        guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else {
            throw NSError(domain: "SessionHeaderChecks", code: -1)
        }
        clickable.mouseEntered(with: event)
        try check(cursorValues.last === NSCursor.pointingHand, "The header's enter handler requests the hand cursor")
        clickable.isEnabled = false
        try check(cursorValues.last === NSCursor.arrow, "Disabling a hovered session immediately restores its arrow cursor")
        clickable.isEnabled = true
        clickable.cursorUpdate(with: event)
        clickable.mouseMoved(with: event)
        try check(cursorValues.suffix(3).allSatisfy { $0 === NSCursor.pointingHand },
                  "The enabled, cursor-update and movement handlers consistently request the hand cursor")
        clickable.mouseExited(with: event)
        try check(cursorValues.last === NSCursor.arrow, "Leaving the header releases the hand cursor without a push/pop stack")

        let panel = HeaderCheckPanel(contentRect: NSRect(x: -10000, y: -10000, width: 460, height: 650),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let probe = CursorRectProbe(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        panel.contentView?.addSubview(probe)
        panel.contentView?.addSubview(clickable)
        let attachedInvalidations = panel.cursorInvalidations
        try check(panel.acceptsMouseMovedEvents && attachedInvalidations > 0 && panel.cursorRebuilds > 0 &&
                  !panel.isVisible && !panel.isKeyWindow && !NSApp.isActive,
                  "Attaching eagerly rebuilds cursor regions without showing, making key, or activating the panel")
        let beforeLayoutRebuilds = panel.cursorRebuilds
        let beforeProbeRebuilds = probe.cursorRebuilds
        clickable.frame.size.width = 280
        clickable.refreshCursorRects()
        try check(panel.cursorRebuilds > beforeLayoutRebuilds && probe.cursorRebuilds > beforeProbeRebuilds &&
                  !panel.isKeyWindow && !NSApp.isActive,
                  "An explicit post-layout refresh invokes real AppKit view cursor rebuilding while the panel remains non-key")
        clickable.isEnabled = false
        try check(panel.cursorInvalidations > attachedInvalidations && panel.cursorRebuilds > beforeLayoutRebuilds + 1,
                  "Enabled-state changes rebuild cursor regions immediately rather than waiting for a key window")
        clickable.removeFromSuperview()
        panel.close()
        let disabled = SessionHeaderButton(request: try request(["sessionId": ""]), target: target,
                                           action: #selector(HeaderCheckTarget.openSession(_:)))
        try check(!disabled.isEnabled && disabled.menu?.items.first?.isEnabled == false,
                  "Unknown origins and absent IDs neither navigate nor offer a usable copy action")
        print("Session header checks passed:", checks,
              "No UI events posted, windows shown, sessions opened, clipboard writes, or model calls.")
    }
}
