import AppKit
import Carbon
import Darwin
import Foundation

struct SessionLinkLease: Decodable {
    struct Terminal: Decodable {
        let processId: Int
        let name: String
    }
    let schemaVersion: Int
    let windowKey: String
    let processId: Int
    let updatedAt: Double
    let workspaces: [String]
    let claudeSessionURL: String
    let terminalURL: String
    let terminals: [Terminal]
    let codexSessionURL: String?
    let codexExtensionVersion: String?

    static let supportedCodexVersions: Set<String> = ["26.1021.22027"]

    static func boundURL(_ raw: String, authority: String, path: String) -> URLComponents? {
        guard raw.utf8.count <= 2048, let parts = URLComponents(string: raw),
              ["vscode", "vscode-insiders"].contains(parts.scheme ?? ""), parts.host == authority,
              parts.path == path, parts.user == nil, parts.password == nil, parts.port == nil,
              parts.fragment == nil, let query = parts.queryItems, query.count == 1,
              query[0].name == "windowId", let window = query[0].value,
              window.range(of: #"^[1-9][0-9]{0,15}$"#, options: .regularExpression) != nil else { return nil }
        return parts
    }

    func isValid(filename: String, now: Double, isAlive: (Int) -> Bool) -> Bool {
        guard schemaVersion == 1, UUID(uuidString: windowKey) != nil,
              filename == windowKey.lowercased() + ".json", processId > 1, processId <= Int(Int32.max),
              updatedAt.isFinite, updatedAt >= now - 35, updatedAt <= now + 5, isAlive(processId),
              workspaces.count <= 32,
              workspaces.allSatisfy({ $0.hasPrefix("/") && $0 != "/" && $0.utf8.count <= 4096 &&
                  $0.rangeOfCharacter(from: .controlCharacters) == nil }),
              terminals.count <= 64,
              terminals.allSatisfy({ $0.processId > 1 && $0.processId <= Int(Int32.max) && $0.name.utf8.count <= 512 }),
              let claude = Self.boundURL(claudeSessionURL, authority: "anthropic.claude-code", path: "/open"),
              let terminal = Self.boundURL(terminalURL, authority: "pip-local.pip-session-links", path: "/terminal"),
              claude.scheme == terminal.scheme,
              claude.queryItems?[0].value == terminal.queryItems?[0].value else { return false }
        switch (codexSessionURL, codexExtensionVersion) {
        case (nil, nil): return true
        case let (raw?, version?):
            guard version.utf8.count <= 128,
                  version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$"#, options: .regularExpression) != nil,
                  let codex = Self.boundURL(raw, authority: "pip-local.pip-session-links", path: "/codex"),
                  codex.scheme == terminal.scheme,
                  codex.queryItems?[0].value == terminal.queryItems?[0].value else { return false }
            return true
        default: return false
        }
    }
}

/// Window links are written only by the local VS Code helper. No chat body is read.
struct SessionLinkRegistry {
    let directory: URL
    var isAlive: (Int) -> Bool = { kill(pid_t($0), 0) == 0 }

    func read(now: Double) -> [SessionLinkLease] {
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard dir >= 0 else { return [] }
        defer { close(dir) }
        var directoryInfo = stat()
        guard fstat(dir, &directoryInfo) == 0, (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
              directoryInfo.st_uid == getuid(), directoryInfo.st_mode & 0o077 == 0,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path), names.count <= 64 else { return [] }
        return names.compactMap { name in
            guard name.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.json$"#,
                             options: .regularExpression) != nil else { return nil }
            let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var fileInfo = stat()
            guard fstat(fd, &fileInfo) == 0, (fileInfo.st_mode & S_IFMT) == S_IFREG,
                  fileInfo.st_uid == getuid(), fileInfo.st_mode & 0o077 == 0,
                  fileInfo.st_size > 0, fileInfo.st_size <= 65536 else { return nil }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count < 0 { if errno == EINTR { continue }; return nil }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(Int(count)))
                if data.count > 65536 { return nil }
            }
            guard let lease = try? JSONDecoder().decode(SessionLinkLease.self, from: data),
                  lease.isValid(filename: name, now: now, isAlive: isAlive) else { return nil }
            return lease
        }
    }
}

enum TerminalScriptStage: String, CaseIterable {
    case applicationState = "application-state", enumerateWindows = "enumerate-windows", enumerateTabs = "enumerate-tabs"
    case inspectTTY = "inspect-tty", revalidateTTY = "revalidate-tty", selectTab = "select-tab"
    case restoreWindow = "restore-window", raiseWindow = "raise-window", activate = "activate"

    var operation: String {
        switch self {
        case .applicationState: return "checking Terminal"
        case .enumerateWindows: return "reading Terminal windows"
        case .enumerateTabs: return "reading Terminal tabs"
        case .inspectTTY: return "checking tab identities"
        case .revalidateTTY: return "rechecking the original tab"
        case .selectTab: return "selecting the original tab"
        case .restoreWindow: return "restoring the Terminal window"
        case .raiseWindow: return "raising the Terminal window"
        case .activate: return "activating Terminal"
        }
    }
}

enum SessionNavigationError: LocalizedError, Equatable {
    case unavailable, missingVSCodeConnection, ambiguousWindow, terminalGone, appMissing, openFailed, cancelled
    case terminalPermission, terminalTimeout
    case terminalTabNotFound, terminalTabChanged, terminalAmbiguous, terminalSelectionLimit, terminalUnexpectedResult
    case terminalScriptFailure(Int?, stage: TerminalScriptStage? = nil)
    case missingCodexConnection, unsupportedCodexVersion

    var errorDescription: String? {
        switch self {
        case .unavailable: return "This request does not include a supported session link. You can copy its ID from the session header."
        case .missingVSCodeConnection: return "Pip session links are not connected for this VS Code window. Enable Pip Session Links in VS Code."
        case .missingCodexConnection: return "Codex session links need the updated Pip Session Links helper. Reload VS Code after active work finishes, then run Pip: Refresh Session Links."
        case .unsupportedCodexVersion: return "This Codex extension version is not supported by Pip's session links yet."
        case .ambiguousWindow: return "Pip could not identify which VS Code window owns this session."
        case .terminalGone: return "The original terminal session is no longer available."
        case .appMissing: return "The originating app is not available on this Mac."
        case .openFailed: return "The originating app could not open this session."
        case .cancelled: return nil
        case .terminalPermission: return "Allow Pip to control Terminal in System Settings → Privacy & Security → Automation to select its existing tab."
        case .terminalTimeout: return "Terminal did not respond. The session was not opened."
        case .terminalTabNotFound: return "The original terminal is running, but its Terminal tab could not be found."
        case .terminalTabChanged: return "The original Terminal tab changed before it could be selected."
        case .terminalAmbiguous: return "More than one Terminal tab matched. Pip did not select a tab."
        case .terminalSelectionLimit: return "Terminal has too many windows or tabs for Pip to select the original tab safely."
        case .terminalUnexpectedResult: return "Terminal returned an unexpected result. The session was not opened."
        case let .terminalScriptFailure(number, stage):
            let operation = stage.map { " while " + $0.operation } ?? ""
            if let number { return "Terminal could not select the session\(operation) (AppleScript error \(number))." }
            return "Terminal could not select the session because its AppleScript failed."
        }
    }
}

enum SessionNavigationDestination: Equatable {
    case url(URL, bundleIdentifier: String)
    case terminal(tty: String)
}

struct SessionNavigationResolver {
    var originIsAlive: (SessionTerminalContext) -> Bool = SessionTerminalIdentity.isAlive

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func matchingWindow(for request: PermissionRequest, leases: [SessionLinkLease]) throws -> SessionLinkLease {
        let directory = canonical(request.cwd)
        let matches: [SessionLinkLease]
        if let key = request.sessionWindowKey {
            guard UUID(uuidString: key) != nil else { throw SessionNavigationError.unavailable }
            matches = leases.filter { lease in
                lease.windowKey.lowercased() == key.lowercased() && lease.workspaces.contains {
                    let folder = canonical($0)
                    return folder == directory || directory.hasPrefix(folder + "/")
                }
            }
        } else {
            matches = leases.filter { $0.workspaces.contains { canonical($0) == directory } }
        }
        guard !matches.isEmpty else { throw SessionNavigationError.missingVSCodeConnection }
        guard matches.count == 1 else { throw SessionNavigationError.ambiguousWindow }
        return matches[0]
    }

    func destination(for request: PermissionRequest, leases: [SessionLinkLease]) throws -> SessionNavigationDestination {
        guard request.canOpenSession else { throw SessionNavigationError.unavailable }
        switch request.sessionHost {
        case "codex-desktop":
            guard let id = request.navigationSessionID, let url = URL(string: "codex://threads/" + id) else {
                throw SessionNavigationError.unavailable
            }
            return .url(url, bundleIdentifier: "com.openai.codex")
        case "claude-vscode":
            guard let id = request.navigationSessionID else { throw SessionNavigationError.unavailable }
            let lease = try matchingWindow(for: request, leases: leases)
            guard var url = SessionLinkLease.boundURL(lease.claudeSessionURL, authority: "anthropic.claude-code", path: "/open") else {
                throw SessionNavigationError.unavailable
            }
            url.queryItems = (url.queryItems ?? []) + [URLQueryItem(name: "session", value: id)]
            guard let target = url.url else { throw SessionNavigationError.unavailable }
            return .url(target, bundleIdentifier: url.scheme == "vscode-insiders" ? "com.microsoft.VSCodeInsiders" : "com.microsoft.VSCode")
        case "codex-vscode":
            guard let id = request.navigationSessionID else { throw SessionNavigationError.unavailable }
            let lease = try matchingWindow(for: request, leases: leases)
            guard let raw = lease.codexSessionURL, let version = lease.codexExtensionVersion else {
                throw SessionNavigationError.missingCodexConnection
            }
            guard SessionLinkLease.supportedCodexVersions.contains(version) else {
                throw SessionNavigationError.unsupportedCodexVersion
            }
            guard var url = SessionLinkLease.boundURL(raw, authority: "pip-local.pip-session-links", path: "/codex") else {
                throw SessionNavigationError.unavailable
            }
            url.queryItems = (url.queryItems ?? []) + [URLQueryItem(name: "windowKey", value: lease.windowKey),
                                                     URLQueryItem(name: "sessionId", value: id.lowercased())]
            guard let target = url.url else { throw SessionNavigationError.unavailable }
            return .url(target, bundleIdentifier: url.scheme == "vscode-insiders" ? "com.microsoft.VSCodeInsiders" : "com.microsoft.VSCode")
        case "vscode-terminal":
            guard let context = request.sessionTerminal, originIsAlive(context) else { throw SessionNavigationError.terminalGone }
            var windows = leases
            if let key = request.sessionWindowKey {
                guard UUID(uuidString: key) != nil else { throw SessionNavigationError.unavailable }
                windows = windows.filter { $0.windowKey.lowercased() == key.lowercased() }
            }
            let matches = windows.flatMap { lease in lease.terminals.compactMap { terminal -> (SessionLinkLease, Int)? in
                context.validProcessIDs.contains(terminal.processId) ? (lease, terminal.processId) : nil
            } }
            guard !matches.isEmpty else { throw SessionNavigationError.missingVSCodeConnection }
            guard matches.count == 1 else { throw SessionNavigationError.ambiguousWindow }
            guard var url = SessionLinkLease.boundURL(matches[0].0.terminalURL, authority: "pip-local.pip-session-links", path: "/terminal") else {
                throw SessionNavigationError.unavailable
            }
            url.queryItems = (url.queryItems ?? []) + [URLQueryItem(name: "windowKey", value: matches[0].0.windowKey),
                                                     URLQueryItem(name: "pid", value: String(matches[0].1))]
            guard let target = url.url else { throw SessionNavigationError.unavailable }
            return .url(target, bundleIdentifier: url.scheme == "vscode-insiders" ? "com.microsoft.VSCodeInsiders" : "com.microsoft.VSCode")
        case "apple-terminal":
            guard let context = request.sessionTerminal, let tty = context.validatedTTY, originIsAlive(context) else {
                throw SessionNavigationError.terminalGone
            }
            return .terminal(tty: tty)
        default:
            throw SessionNavigationError.unavailable
        }
    }
}

enum SessionTerminalIdentity {
    static func isAlive(_ context: SessionTerminalContext) -> Bool {
        guard context.hasOriginIdentity, let pid = context.originPid, let start = context.originStartTime else { return false }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "pid=,tty=,lstart="]
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { process.terminate(); return false }
        guard process.terminationStatus == 0,
              let line = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return false }
        let fields = line.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
        guard fields.count == 3, Int(fields[0]) == pid,
              fields[2].split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") == start.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") else { return false }
        if let tty = context.validatedTTY { return "/dev/" + fields[1] == tty }
        return true
    }
}

enum TerminalSessionOpener {
    struct ScriptReply {
        let value: String?
        let failed: Bool
        let errorNumber: Int?
        let stage: TerminalScriptStage?

        init(value: String?, failed: Bool, errorNumber: Int?, stage: TerminalScriptStage? = nil) {
            self.value = value; self.failed = failed; self.errorNumber = errorNumber; self.stage = stage
        }
    }

    // Parameterized AppleScript only selects an existing tab. It never runs a command.
    static let script = #"""
    on focusExistingTerminalTab(targetTTY)
        set navigationStage to "application-state"
        try
            if application id "com.apple.Terminal" is not running then return "not-running"
            with timeout of 3 seconds
                tell application id "com.apple.Terminal"
                    set matchCount to 0
                    set targetWindow to missing value
                    set targetTab to missing value
                    set visitedTabs to 0
                    set skippedWindows to 0
                    set navigationStage to "enumerate-windows"
                    set windowList to every window
                    if (count of windowList) > 128 then return "too-many-windows"
                    repeat with windowNumber from 1 to (count of windowList)
                        set navigationStage to "enumerate-tabs"
                        set windowValue to item windowNumber of windowList
                        set tabList to {}
                        try
                            set tabList to tabs of windowValue
                        on error number tabEnumerationError
                            -- Settings and other non-terminal windows may not expose tabs.
                            if tabEnumerationError is not -1728 then error number tabEnumerationError
                            set skippedWindows to skippedWindows + 1
                        end try
                        set visitedTabs to visitedTabs + (count of tabList)
                        if visitedTabs > 512 then return "too-many-tabs"
                        repeat with tabNumber from 1 to (count of tabList)
                            set navigationStage to "inspect-tty"
                            set tabValue to item tabNumber of tabList
                            if tty of tabValue is targetTTY then
                                set matchCount to matchCount + 1
                                set targetWindow to windowValue
                                set targetTab to tabValue
                            end if
                        end repeat
                    end repeat
                    if matchCount is 0 then
                        if skippedWindows > 0 then return {"pip-terminal-error", "enumerate-tabs", -1728}
                        return "not-found"
                    end if
                    if matchCount is not 1 then return "ambiguous"
                    set navigationStage to "revalidate-tty"
                    if tty of targetTab is not targetTTY then return "stale"
                    set navigationStage to "select-tab"
                    set selected of targetTab to true
                    set navigationStage to "restore-window"
                    set miniaturized of targetWindow to false
                    set navigationStage to "raise-window"
                    set frontmost of targetWindow to true
                    set navigationStage to "activate"
                    activate
                    return "opened"
                end tell
            end timeout
        on error number scriptErrorNumber
            return {"pip-terminal-error", navigationStage, scriptErrorNumber}
        end try
    end focusExistingTerminalTab
    """#

    /// Invoke a typed handler; the tty is data, never interpolated into script source.
    static func invoke(_ executable: NSAppleScript, tty: String) -> ScriptReply {
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(string: tty), at: 1)
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: "focusExistingTerminalTab"), forKeyword: AEKeyword(keyASSubroutineName))
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        let answer = executable.executeAppleEvent(event, error: &error)
        return reply(from: answer, error: error)
    }

    static func reply(from answer: NSAppleEventDescriptor, error: NSDictionary?) -> ScriptReply {
        if let error {
            return ScriptReply(value: nil, failed: true,
                               errorNumber: (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue)
        }
        if answer.descriptorType == typeAEList {
            guard answer.numberOfItems == 3,
                  answer.atIndex(1)?.stringValue == "pip-terminal-error",
                  let rawStage = answer.atIndex(2)?.stringValue,
                  let stage = TerminalScriptStage(rawValue: rawStage),
                  let code = answer.atIndex(3), code.descriptorType == typeSInt32 else {
                return ScriptReply(value: nil, failed: false, errorNumber: nil)
            }
            return ScriptReply(value: nil, failed: true, errorNumber: Int(code.int32Value), stage: stage)
        }
        return ScriptReply(value: answer.stringValue, failed: false, errorNumber: nil)
    }

    /// Preserve only a static failure category and numeric code, never raw script error text.
    static func failure(for reply: ScriptReply) -> SessionNavigationError? {
        if reply.failed {
            switch reply.errorNumber {
            case -1743, -1744: return .terminalPermission
            case -1712: return .terminalTimeout
            default: return .terminalScriptFailure(reply.errorNumber, stage: reply.stage)
            }
        }
        switch reply.value {
        case "opened": return nil
        case "not-running": return .terminalGone
        case "not-found": return .terminalTabNotFound
        case "stale": return .terminalTabChanged
        case "ambiguous": return .terminalAmbiguous
        case "too-many-windows", "too-many-tabs": return .terminalSelectionLimit
        default: return .terminalUnexpectedResult
        }
    }

    static func open(_ context: SessionTerminalContext, current: () -> Bool) throws {
        guard context.hasOriginIdentity, let tty = context.validatedTTY, SessionTerminalIdentity.isAlive(context),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first,
              !app.isTerminated else { throw SessionNavigationError.terminalGone }
        let target = NSAppleEventDescriptor(processIdentifier: app.processIdentifier)
        let permission = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true)
        guard permission == noErr else { throw SessionNavigationError.terminalPermission }
        // Consent can take time. Revalidate the original process after the dialog.
        guard current() else { throw SessionNavigationError.cancelled }
        guard SessionTerminalIdentity.isAlive(context), !app.isTerminated else { throw SessionNavigationError.terminalGone }
        guard let executable = NSAppleScript(source: script) else { throw SessionNavigationError.terminalScriptFailure(nil) }
        if let error = failure(for: invoke(executable, tty: tty)) { throw error }
    }
}

final class SessionNavigator {
    private let registry: SessionLinkRegistry
    private let queue = DispatchQueue(label: "dev.local.pip.session-navigation")
    private let lock = NSLock()
    private var latest = UUID()

    init(runtime: URL) { registry = SessionLinkRegistry(directory: runtime.appendingPathComponent("session-links")) }

    func open(_ request: PermissionRequest, completion: @escaping (SessionNavigationError?) -> Void) {
        let key = UUID()
        lock.lock(); latest = key; lock.unlock()
        let current = { [weak self] in
            guard let self else { return false }
            self.lock.lock(); defer { self.lock.unlock() }
            return self.latest == key
        }
        queue.async { [weak self] in
            guard let self, current() else { return }
            do {
                let destination = try SessionNavigationResolver().destination(for: request, leases: self.registry.read(now: Date().timeIntervalSince1970))
                guard current() else { return }
                switch destination {
                case let .terminal(tty):
                    guard let context = request.sessionTerminal, context.validatedTTY == tty else { throw SessionNavigationError.unavailable }
                    try TerminalSessionOpener.open(context, current: current)
                    DispatchQueue.main.async { if current() { completion(nil) } }
                case let .url(url, identifier):
                    DispatchQueue.main.async {
                        guard current() else { return }
                        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
                              Bundle(url: app)?.bundleIdentifier == identifier else { completion(.appMissing); return }
                        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
                        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { application, error in
                            DispatchQueue.main.async { if current() { completion(application != nil && error == nil ? nil : .openFailed) } }
                        }
                    }
                }
            } catch let error as SessionNavigationError {
                DispatchQueue.main.async { if current() { completion(error) } }
            } catch {
                DispatchQueue.main.async { if current() { completion(.openFailed) } }
            }
        }
    }
}
