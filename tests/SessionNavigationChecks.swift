import AppKit
import Foundation

@main struct SessionNavigationChecks {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pip-session-navigation-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let workspace = root.appendingPathComponent("Project with spaces")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: false)
        let registryURL = root.appendingPathComponent("links")
        try fm.createDirectory(at: registryURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let sid = "38f4f440-e050-460f-a9d0-84274d9e9cce"
        let key = "71c3ee2b-7b22-4781-89b6-d1df69e789c2"
        let key2 = "e2788e97-6ce6-4989-9590-5fc046ed1070"
        let now = Date().timeIntervalSince1970
        var checks = 0
        func check(_ condition: Bool, _ text: String) throws {
            guard condition else { throw NSError(domain: "SessionNavigationChecks", code: 1,
                userInfo: [NSLocalizedDescriptionKey: text]) }
            checks += 1; print("PASS", text)
        }
        func request(_ extra: [String: Any] = [:]) throws -> PermissionRequest {
            var data: [String: Any] = ["schemaVersion": 1, "id": String(repeating: "a", count: 32),
                "source": "claude", "sourceLabel": "Claude Code", "sessionId": sid, "toolName": "Bash",
                "cwd": workspace.path, "reason": "Check the change", "detailText": "{}", "isDemo": false,
                "createdAt": now, "expiresAt": now + 120]
            data.merge(extra) { _, new in new }
            return try JSONDecoder().decode(PermissionRequest.self, from: JSONSerialization.data(withJSONObject: data))
        }
        func lease(_ extra: [String: Any] = [:]) throws -> SessionLinkLease {
            var data: [String: Any] = ["schemaVersion": 1, "windowKey": key, "processId": 100,
                "updatedAt": now, "workspaces": [workspace.path],
                "claudeSessionURL": "vscode://anthropic.claude-code/open?windowId=7",
                "terminalURL": "vscode://pip-local.pip-session-links/terminal?windowId=7",
                "terminals": [["processId": 200, "name": "zsh"]]]
            data.merge(extra) { _, new in new }
            return try JSONDecoder().decode(SessionLinkLease.self, from: JSONSerialization.data(withJSONObject: data))
        }
        func save(_ value: SessionLinkLease, mode: Int = 0o600) throws {
            var json: [String: Any] = ["schemaVersion": value.schemaVersion, "windowKey": value.windowKey,
                "processId": value.processId, "updatedAt": value.updatedAt, "workspaces": value.workspaces,
                "claudeSessionURL": value.claudeSessionURL, "terminalURL": value.terminalURL,
                "terminals": value.terminals.map { ["processId": $0.processId, "name": $0.name] as [String: Any] }]
            if let route = value.codexSessionURL { json["codexSessionURL"] = route }
            if let version = value.codexExtensionVersion { json["codexExtensionVersion"] = version }
            let file = registryURL.appendingPathComponent(value.windowKey + ".json")
            try JSONSerialization.data(withJSONObject: json).write(to: file)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        }
        func rejects(_ request: PermissionRequest, _ leases: [SessionLinkLease], _ message: String,
                     originAlive: Bool = true) throws {
            do {
                _ = try SessionNavigationResolver(originIsAlive: { _ in originAlive }).destination(for: request, leases: leases)
                try check(false, message)
            } catch is SessionNavigationError { try check(true, message) }
        }
        let baseline = try request()
        try check(baseline.sessionName == nil && baseline.sessionHost == nil, "Old request schemas still decode without session metadata")
        try check(baseline.sessionDisplayName == "Task: Run command", "Missing chat title is explicitly labeled as the pending task")
        try check(baseline.sessionIdentityLabel == "ID: " + sid, "Session ID remains available for diagnostics and copying")
        let named = try request(["sessionName": "  Fix\nanchor \u{202e}links\t "])
        try check(named.sessionDisplayName == "Fix anchor links", "Session titles fold control whitespace and remove bidi controls")
        let huge = try request(["sessionName": String(repeating: "界", count: 1000), "sessionId": String(repeating: "x", count: 1000)])
        try check(huge.sessionDisplayName.utf8.count <= 512 && huge.sessionIdentityLabel.count < 48,
                  "Long title and ID labels remain bounded")
        try check(!baseline.canOpenSession, "Unknown origins do not claim direct navigation")
        try check(!(try request(["sessionHost": "claude-vscode", "isDemo": true])).canOpenSession,
                  "Simulated cards cannot open real sessions")
        try check(!(try request(["sessionHost": "claude-vscode", "sessionId": "../bad?prompt=run"])).canOpenSession,
                  "A session ID cannot inject a URI path or prompt")
        let first = try lease()
        try check(first.isValid(filename: key + ".json", now: now, isAlive: { _ in true }), "Private window-bound lease validates")
        for bad in ["https://example.test/open?windowId=7", "vscode://anthropic.claude-code/open",
                    "vscode://anthropic.claude-code/open?windowId=7&prompt=run",
                    "vscode://anthropic.claude-code/open?windowId=7&windowId=8",
                    "vscode://other-extension/open?windowId=7"] {
            try check(!(try lease(["claudeSessionURL": bad])).isValid(filename: key + ".json", now: now, isAlive: { _ in true }),
                      "Generic, external, ambiguous, or command-bearing URLs are rejected")
        }
        try check(!(try lease(["terminalURL": "vscode://pip-local.pip-session-links/terminal?windowId=8"])).isValid(
            filename: key + ".json", now: now, isAlive: { _ in true }), "Both routes must belong to the same window")
        try check(!(try lease(["updatedAt": now - 40])).isValid(filename: key + ".json", now: now, isAlive: { _ in true }),
                  "Expired window leases are ignored")
        try check(!(try lease(["updatedAt": now + 10])).isValid(filename: key + ".json", now: now, isAlive: { _ in true }),
                  "Future-dated window leases are ignored")
        try check(!first.isValid(filename: key2 + ".json", now: now, isAlive: { _ in true }), "Lease filename and window identity must match")
        try check(!first.isValid(filename: key + ".json", now: now, isAlive: { _ in false }), "Closed extension-host processes cannot supply links")
        try save(first)
        let registry = SessionLinkRegistry(directory: registryURL, isAlive: { $0 == 100 })
        try check(registry.read(now: now).count == 1, "Private lease registry loads one live window")
        try save(first, mode: 0o644)
        try check(registry.read(now: now).isEmpty, "Publicly readable lease files are rejected")
        try save(first)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: registryURL.path)
        try check(registry.read(now: now).isEmpty, "A nonprivate registry directory is rejected")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: registryURL.path)
        let symlinkRoot = root.appendingPathComponent("symlink-links")
        try fm.createSymbolicLink(at: symlinkRoot, withDestinationURL: registryURL)
        try check(SessionLinkRegistry(directory: symlinkRoot, isAlive: { _ in true }).read(now: now).isEmpty,
                  "Registry directory symlinks are not followed")
        let file = registryURL.appendingPathComponent(key + ".json")
        let outside = root.appendingPathComponent("outside.json")
        try fm.moveItem(at: file, to: outside)
        try fm.createSymbolicLink(at: file, withDestinationURL: outside)
        try check(registry.read(now: now).isEmpty, "Lease file symlinks are not followed")
        try fm.removeItem(at: file); try save(first)
        let claude = try request(["sessionHost": "claude-vscode"])
        let resolver = SessionNavigationResolver(originIsAlive: { _ in true })
        let selected = try resolver.destination(for: claude, leases: [first])
        try check(selected == .url(URL(string: "vscode://anthropic.claude-code/open?windowId=7&session=" + sid)!, bundleIdentifier: "com.microsoft.VSCode"),
                  "Claude URL binds both the exact workspace window and session ID")
        try rejects(claude, [], "Missing helper never falls back to a generic workspace link")
        let otherWorkspace = try lease(["workspaces": [root.appendingPathComponent("Other").path]])
        try rejects(claude, [otherWorkspace], "Another workspace cannot receive the session link")
        let second = try lease(["windowKey": key2,
            "claudeSessionURL": "vscode://anthropic.claude-code/open?windowId=8",
            "terminalURL": "vscode://pip-local.pip-session-links/terminal?windowId=8"])
        try rejects(claude, [first, second], "Duplicate workspace windows require an exact origin identity")
        let keyed = try request(["sessionHost": "claude-vscode", "sessionWindowKey": key2])
        try check(try resolver.destination(for: keyed, leases: [first, second]) == .url(
            URL(string: "vscode://anthropic.claude-code/open?windowId=8&session=" + sid)!, bundleIdentifier: "com.microsoft.VSCode"),
            "Origin window key selects the matching window among identical workspaces")
        try rejects(keyed, [first], "An unknown origin key does not jump to another matching workspace")
        let nested = try request(["sessionHost": "claude-vscode", "sessionWindowKey": key,
                                  "cwd": workspace.appendingPathComponent("src").path])
        try check(try resolver.destination(for: nested, leases: [first]) == selected,
                  "A verified origin window key supports sessions rooted in its workspace subfolder")
        try rejects(try request(["sessionHost": "claude-vscode", "cwd": workspace.appendingPathComponent("src").path]), [first],
                    "A workspace subfolder alone does not guess an unverified origin window")
        try rejects(try request(["sessionHost": "claude-vscode", "sessionWindowKey": key, "cwd": workspace.path + "-other"]), [first],
                    "Workspace containment respects complete path components")
        let terminalData: [String: Any] = ["processIds": [300, 200, 100], "tty": "/dev/ttys003",
            "originPid": 300, "originStartTime": "Wed Oct 28 12:00:00 2026"]
        let integrated = try request(["sessionHost": "vscode-terminal", "sessionTerminal": terminalData])
        try check(try resolver.destination(for: integrated, leases: [first]) == .url(
            URL(string: "vscode://pip-local.pip-session-links/terminal?windowId=7&windowKey=" + key + "&pid=200")!,
            bundleIdentifier: "com.microsoft.VSCode"), "Integrated terminal routing matches its existing shell PID")
        try rejects(integrated, [first, second], "Ambiguous terminal ownership is rejected")
        try rejects(integrated, [first], "A dead or replaced origin cannot select a terminal", originAlive: false)
        try rejects(try request(["sessionHost": "vscode-terminal", "sessionTerminal": terminalData, "sessionWindowKey": key2]), [first],
                    "An integrated terminal cannot ignore its explicit origin window key")
        let emptyWorkspace = try lease(["workspaces": []])
        try check(emptyWorkspace.isValid(filename: key + ".json", now: now, isAlive: { _ in true }),
                  "An empty VS Code window can advertise existing terminal identities")
        try check(try resolver.destination(for: integrated, leases: [emptyWorkspace]) == resolver.destination(for: integrated, leases: [first]),
                  "An integrated terminal can open in an untitled VS Code window")
        let terminal = try request(["sessionHost": "apple-terminal", "sessionTerminal": terminalData])
        try check(try resolver.destination(for: terminal, leases: []) == .terminal(tty: "/dev/ttys003"),
                  "Apple Terminal destination uses a validated existing tty")
        try rejects(try request(["sessionHost": "apple-terminal", "sessionTerminal": ["processIds": [200], "tty": "/dev/ttys003"]]), [],
                    "A tty without a live origin identity is insufficient")
        try rejects(try request(["sessionHost": "apple-terminal", "sessionTerminal": ["processIds": [300], "tty": "\"; do script evil", "originPid": 300,
                    "originStartTime": "Wed Oct 28 12:00:00 2026"]]), [], "Terminal parameters cannot contain script source")
        let codex = try request(["source": "codex", "sessionHost": "codex-desktop"])
        try check(try resolver.destination(for: codex, leases: []) == .url(URL(string: "codex://threads/" + sid)!, bundleIdentifier: "com.openai.codex"),
                  "Codex desktop opens the documented exact local-thread route")
        let codexIDE = try request(["source": "codex", "sessionHost": "codex-vscode"])
        let codexLink = "vscode://pip-local.pip-session-links/codex?windowId=7"
        let codexVersion = "26.1021.22027"
        let codexLease = try lease(["codexSessionURL": codexLink, "codexExtensionVersion": codexVersion])
        try check(codexLease.isValid(filename: key + ".json", now: now, isAlive: { _ in true }),
                  "A Codex capability is tied to the helper's same existing window")
        for bad in [["codexSessionURL": codexLink], ["codexExtensionVersion": codexVersion],
                    ["codexSessionURL": "vscode://openai.chatgpt/local?windowId=7", "codexExtensionVersion": codexVersion],
                    ["codexSessionURL": "vscode://pip-local.pip-session-links/codex?windowId=9", "codexExtensionVersion": codexVersion],
                    ["codexSessionURL": codexLink + "&prompt=run", "codexExtensionVersion": codexVersion]] {
            try check(!(try lease(bad)).isValid(filename: key + ".json", now: now, isAlive: { _ in true }),
                      "Incomplete, unbound or injected Codex capabilities are rejected")
        }
        guard case let .url(codexURL, codexApp) = try resolver.destination(for: codexIDE, leases: [codexLease]),
              let codexParts = URLComponents(url: codexURL, resolvingAgainstBaseURL: false) else {
            throw SessionNavigationError.openFailed
        }
        let codexQuery = Dictionary(uniqueKeysWithValues: (codexParts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        try check(codexApp == "com.microsoft.VSCode" && codexParts.host == "pip-local.pip-session-links" &&
                  codexParts.path == "/codex" && codexQuery == ["windowId": "7", "windowKey": key, "sessionId": sid],
                  "Codex IDE navigation sends only exact window, window key and thread ID to the local helper")
        do {
            _ = try resolver.destination(for: codexIDE, leases: [first])
            try check(false, "Old helpers must not fall back to a generic Codex route")
        } catch let error as SessionNavigationError {
            try check(error == .missingCodexConnection, "Old helpers explain that the Codex connection needs updating")
        }
        let unknownVersion = try lease(["codexSessionURL": codexLink, "codexExtensionVersion": "99.1.0"])
        try check(unknownVersion.isValid(filename: key + ".json", now: now, isAlive: { _ in true }),
                  "An unknown Codex version does not disable independent Claude or terminal capabilities")
        do {
            _ = try resolver.destination(for: codexIDE, leases: [unknownVersion])
            try check(false, "Unknown Codex adapters must not be opened")
        } catch let error as SessionNavigationError {
            try check(error == .unsupportedCodexVersion, "Unknown Codex versions fail before opening a link")
        }
        let codexSecond = try lease(["windowKey": key2, "codexSessionURL": codexLink, "codexExtensionVersion": codexVersion])
        try rejects(codexIDE, [codexLease, codexSecond], "Duplicate Codex workspace windows require the exact origin key")
        let keyedCodex = try request(["source": "codex", "sessionHost": "codex-vscode", "sessionWindowKey": key2])
        guard case let .url(keyedCodexURL, _) = try resolver.destination(for: keyedCodex, leases: [codexLease, codexSecond]) else {
            throw SessionNavigationError.openFailed
        }
        try check(URLComponents(url: keyedCodexURL, resolvingAgainstBaseURL: false)?.queryItems?.contains(
            URLQueryItem(name: "windowKey", value: key2)) == true, "An origin key selects the exact Codex workspace window")
        try rejects(try request(["source": "codex", "sessionHost": "codex-vscode", "cwd": "/other-workspace"]),
                    [codexLease], "Codex does not open a thread in another workspace")
        try rejects(try request(["source": "codex", "sessionHost": "codex-vscode", "isDemo": true]),
                    [codexLease], "Demo cards never open a real Codex chat")
        try rejects(try request(["source": "chatgpt-work", "sessionHost": "codex-vscode"]),
                    [codexLease], "Work Cloud cannot masquerade as a local Codex IDE session")
        try rejects(try request(["source": "chatgpt-work", "sessionHost": "codex-desktop"]), [], "Work Cloud cannot masquerade as a local desktop thread")
        var scriptError: NSDictionary?
        let script = NSAppleScript(source: TerminalSessionOpener.script)
        let compiled = script?.compileAndReturnError(&scriptError) == true
        if !compiled { fputs("Terminal script compile error: \(String(describing: scriptError))\n", stderr) }
        try check(compiled, "Parameterized Terminal script compiles without executing it")
        let replyErrors: [(String?, SessionNavigationError?)] = [
            ("opened", nil), ("not-running", .terminalGone), ("not-found", .terminalTabNotFound),
            ("stale", .terminalTabChanged), ("ambiguous", .terminalAmbiguous),
            ("too-many-windows", .terminalSelectionLimit), ("too-many-tabs", .terminalSelectionLimit),
            ("unknown-private-result", .terminalUnexpectedResult), (nil, .terminalUnexpectedResult)
        ]
        for (value, expected) in replyErrors {
            try check(TerminalSessionOpener.failure(for: .init(value: value, failed: false, errorNumber: nil)) == expected,
                      "Terminal reply classification: " + (value ?? "missing result"))
        }
        let scriptErrors: [(Int?, SessionNavigationError)] = [
            (-1743, .terminalPermission), (-1744, .terminalPermission), (-1712, .terminalTimeout),
            (-1708, .terminalScriptFailure(-1708)), (-1728, .terminalScriptFailure(-1728)),
            (nil, .terminalScriptFailure(nil))
        ]
        for (number, expected) in scriptErrors {
            try check(TerminalSessionOpener.failure(for: .init(value: "opened", failed: true, errorNumber: number)) == expected,
                      "Script errors retain their numeric category instead of claiming the origin exited")
        }
        try check(SessionNavigationError.terminalScriptFailure(-1708).errorDescription?.contains("-1708") == true &&
                  SessionNavigationError.terminalUnexpectedResult.errorDescription?.contains("unknown-private-result") == false,
                  "Diagnostics expose numeric errors and never the unknown script result")
        let echoSource = #"""
        on focusExistingTerminalTab(targetTTY)
            return targetTTY
        end focusExistingTerminalTab
        """#
        guard let echo = NSAppleScript(source: echoSource) else { throw SessionNavigationError.openFailed }
        let echoValue = "/dev/ttys003 \"quoted\" \\ value\nnext line"
        let echoReply = TerminalSessionOpener.invoke(echo, tty: echoValue)
        try check(!echoReply.failed && echoReply.errorNumber == nil && echoReply.value == echoValue,
                  "The actual typed invocation passes data exactly to a pure in-process handler")
        func stagedResult(_ stage: String, code: NSAppleEventDescriptor = NSAppleEventDescriptor(int32: -1728),
                          tag: String = "pip-terminal-error", extra: Bool = false) -> NSAppleEventDescriptor {
            let descriptor = NSAppleEventDescriptor.list()
            descriptor.insert(NSAppleEventDescriptor(string: tag), at: 1)
            descriptor.insert(NSAppleEventDescriptor(string: stage), at: 2)
            descriptor.insert(code, at: 3)
            if extra { descriptor.insert(NSAppleEventDescriptor(string: "untrusted-extra"), at: 4) }
            return descriptor
        }
        for stage in TerminalScriptStage.allCases {
            let reply = TerminalSessionOpener.reply(from: stagedResult(stage.rawValue), error: nil)
            try check(reply.failed && reply.stage == stage && reply.errorNumber == -1728 &&
                      TerminalSessionOpener.failure(for: reply) == .terminalScriptFailure(-1728, stage: stage),
                      "Typed script failures retain only an allowed static operation and numeric code")
        }
        for malformed in [stagedResult("untrusted-private-stage"), stagedResult("select-tab", tag: "untrusted-tag"),
                          stagedResult("select-tab", code: NSAppleEventDescriptor(string: "-1728")),
                          stagedResult("select-tab", extra: true)] {
            let reply = TerminalSessionOpener.reply(from: malformed, error: nil)
            try check(reply.stage == nil && reply.errorNumber == nil &&
                      TerminalSessionOpener.failure(for: reply) == .terminalUnexpectedResult,
                      "Unknown or malformed script diagnostic data is not displayed")
        }
        let typedSource = #"""
        on focusExistingTerminalTab(targetTTY)
            return {"pip-terminal-error", "select-tab", -1728}
        end focusExistingTerminalTab
        """#
        guard let typedFixture = NSAppleScript(source: typedSource) else { throw SessionNavigationError.openFailed }
        let typedReply = TerminalSessionOpener.invoke(typedFixture, tty: "/dev/ttys003")
        try check(typedReply.failed && typedReply.stage == .selectTab && typedReply.errorNumber == -1728,
                  "The actual handler transport parses typed stage diagnostics from a pure script")
        let referenceSource = #"""
        using terms from application id "com.apple.Terminal"
            on focusExistingTerminalTab(targetTTY)
                set windowList to {{marker:"settings-window"}, {marker:"first-window", simulatedTabs:{{marker:"first-tab", contents:"simulated text"}}}, {marker:"second-window", simulatedTabs:{{marker:"second-tab", contents:"other simulated text"}}}}
                set targetWindow to missing value
                set targetTab to missing value
                set skippedWindows to 0
                repeat with windowNumber from 1 to (count of windowList)
                    set windowValue to item windowNumber of windowList
                    set tabList to {}
                    try
                        set tabList to simulatedTabs of windowValue
                    on error number tabEnumerationError
                        if tabEnumerationError is not -1728 then error number tabEnumerationError
                        set skippedWindows to skippedWindows + 1
                    end try
                    repeat with tabNumber from 1 to (count of tabList)
                        set tabValue to item tabNumber of tabList
                        if marker of tabValue is "first-tab" then
                            set targetWindow to windowValue
                            set targetTab to tabValue
                        end if
                    end repeat
                end repeat
                return (marker of targetWindow) & ":" & (marker of targetTab) & ":" & (skippedWindows as text)
            end focusExistingTerminalTab
        end using terms from
        """#
        guard let referenceFixture = NSAppleScript(source: referenceSource) else { throw SessionNavigationError.openFailed }
        let referenceReply = TerminalSessionOpener.invoke(referenceFixture, tty: "/dev/ttys003")
        try check(!referenceReply.failed && referenceReply.value == "first-window:first-tab:1",
                  "Indexed list values retain the chosen objects and skip a window that has no tabs")
        let enumerationFailureSource = #"""
        on focusExistingTerminalTab(targetTTY)
            try
                error number -1743
            on error number tabEnumerationError
                if tabEnumerationError is not -1728 then error number tabEnumerationError
            end try
            return "incorrectly-swallowed"
        end focusExistingTerminalTab
        """#
        guard let enumerationFailureFixture = NSAppleScript(source: enumerationFailureSource) else { throw SessionNavigationError.openFailed }
        let enumerationFailureReply = TerminalSessionOpener.invoke(enumerationFailureFixture, tty: "/dev/ttys003")
        try check(enumerationFailureReply.failed && enumerationFailureReply.errorNumber == -1743 &&
                  TerminalSessionOpener.failure(for: enumerationFailureReply) == .terminalPermission,
                  "Tab enumeration never swallows a permission failure or proceeds after it")
        try check(SessionNavigationError.terminalScriptFailure(-1728, stage: .selectTab).errorDescription?.contains("selecting the original tab") == true,
                  "User diagnostics identify the static failing operation without raw script text")
        print("Session navigation checks passed:", checks, "Only pure in-process fixtures executed; no sessions opened, Terminal events sent, agent commands run, or permissions requested.")
    }
}
