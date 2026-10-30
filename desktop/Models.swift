import Foundation
import CoreFoundation
import Darwin

struct QuestionOption: Codable {
    let label: String
    let description: String?
}

struct UserQuestion: Codable {
    let question: String
    let header: String?
    let options: [QuestionOption]
    let multiSelect: Bool?

    var allowsMultiple: Bool { multiSelect ?? false }

    var isValid: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        question.utf8.count <= 16_000 && (2...4).contains(options.count) &&
        options.allSatisfy { !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.label.utf8.count <= 4_000 } &&
        Set(options.map { $0.label }).count == options.count
    }
}

struct SessionTerminalContext: Codable {
    let processIds: [Int]
    let tty: String?
    var originPid: Int? = nil
    var originStartTime: String? = nil

    var validProcessIDs: Set<Int> {
        Set(processIds.prefix(10).filter { $0 > 1 && $0 <= Int(Int32.max) })
    }

    var validatedTTY: String? {
        guard let tty, tty.range(of: #"^/dev/ttys[0-9]{1,4}$"#, options: .regularExpression) != nil else { return nil }
        return tty
    }

    var hasOriginIdentity: Bool {
        guard let originPid, validProcessIDs.contains(originPid), let originStartTime else { return false }
        let normalized = originStartTime.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return normalized.count <= 64 && normalized.range(
            of: #"^[A-Za-z]{3} [A-Za-z]{3} [0-9]{1,2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}$"#,
            options: .regularExpression) != nil
    }
}

struct PermissionRequest: Codable {
    let schemaVersion: Int
    let id: String
    let source: String
    let sourceLabel: String
    let sessionId: String
    let toolName: String
    let cwd: String
    let reason: String
    let detailText: String
    let isDemo: Bool
    let createdAt: Double
    let expiresAt: Double
    let canRespond: Bool?
    let kind: String?
    let questions: [UserQuestion]?
    var sessionName: String? = nil
    var sessionHost: String? = nil
    var sessionWindowKey: String? = nil
    var sessionTerminal: SessionTerminalContext? = nil
    var canDefer: Bool? = nil

    var responseAvailable: Bool { canRespond ?? true }
    var isQuestion: Bool { kind == "question" }

    static func sessionText(_ text: String, limit: Int = 512) -> String {
        let bidi: Set<UInt32> = [0x061c, 0x200e, 0x200f, 0x202a, 0x202b, 0x202c, 0x202d, 0x202e, 0x2066, 0x2067, 0x2068, 0x2069]
        let scalars = text.unicodeScalars.prefix(4096).filter { !bidi.contains($0.value) }
        let spaced = String(String.UnicodeScalarView(scalars)).components(separatedBy: .controlCharacters).joined(separator: " ")
        var result = spaced.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        while result.utf8.count > limit { result.removeLast() }
        return result
    }

    private func informativeSubject(_ value: String) -> String? {
        let name = Self.sessionText(value)
        guard !name.isEmpty, name.caseInsensitiveCompare(Self.sessionText(sessionId, limit: 256)) != .orderedSame else { return nil }
        let identifier = name.replacingOccurrences(of: #"(?i)^(?:session(?:\s+(?:id|uuid))?|id|uuid)\s*[:#]?\s*"#,
            with: "", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "[](){}<> \t"))
        guard identifier.caseInsensitiveCompare(Self.sessionText(sessionId, limit: 256)) != .orderedSame,
              UUID(uuidString: identifier) == nil,
              identifier.range(of: #"(?i)^[0-9a-f]{32}$"#, options: .regularExpression) == nil else { return nil }
        let directory = Self.sessionText(cwd, limit: 4096)
        if directory.hasPrefix("/") {
            let folder = URL(fileURLWithPath: directory).lastPathComponent
            let pathLabel = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let pathDirectory = directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if pathLabel.caseInsensitiveCompare(pathDirectory) == .orderedSame ||
                !folder.isEmpty && pathLabel.caseInsensitiveCompare(folder) == .orderedSame { return nil }
        }
        return name
    }

    var sessionDisplayName: String {
        if let sessionName, let name = informativeSubject(sessionName) { return name }
        if detailText.utf8.count <= 16_384, let data = detailText.data(using: .utf8),
           let input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let description = input["description"] as? String {
            if let text = informativeSubject(description) {
                return "Task: " + String(text.prefix(96)) + (text.count > 96 ? "…" : "")
            }
        }
        // These describe the pending action, not an inferred conversation title.
        switch toolName.lowercased() {
        case "read": return "Task: Read file"
        case "edit", "multiedit": return "Task: Edit file"
        case "write": return "Task: Write file"
        case "bash", "exec_command": return "Task: Run command"
        case "question", "askuserquestion", "request_user_input", "request_user_input_async":
            return "Task: Answer a question"
        default: break
        }
        switch source {
        case "claude", "vscode": return "Claude Code session"
        case "codex": return "Codex session"
        case "chatgpt-work": return "ChatGPT session"
        default:
            let provider = Self.sessionText(sourceLabel)
            return (provider.isEmpty ? "Assistant" : provider) + " session"
        }
    }

    var sessionContextLabel: String {
        let provider = Self.sessionText(sourceLabel)
        let host: String?
        switch sessionHost {
        case "claude-vscode", "codex-vscode": host = "VS Code"
        case "vscode-terminal": host = "VS Code Terminal"
        case "apple-terminal": host = "Terminal"
        case "codex-desktop": host = "Desktop"
        default: host = nil
        }
        var parts = provider.isEmpty ? [] : [provider]
        if let host, !parts.contains(host) { parts.append(host) }
        let directory = Self.sessionText(cwd, limit: 4096)
        if directory.hasPrefix("/") {
            let folder = URL(fileURLWithPath: directory).lastPathComponent
            if !folder.isEmpty && folder != "/" { parts.append(Self.sessionText(folder)) }
        }
        return Self.sessionText(parts.joined(separator: " · "))
    }

    var sessionIdentityLabel: String {
        let id = Self.sessionText(sessionId, limit: 256)
        if id.count > 48 { return "ID: " + id.prefix(12) + "…" + id.suffix(12) }
        return "ID: " + (id.isEmpty ? "Unavailable" : id)
    }

    var navigationSessionID: String? {
        guard sessionId.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#,
                              options: .regularExpression) != nil else { return nil }
        return sessionId
    }

    var canOpenSession: Bool {
        guard !isDemo else { return false }
        switch sessionHost {
        case "claude-vscode":
            return ["claude", "vscode"].contains(source) && navigationSessionID != nil && cwd.hasPrefix("/")
        case "codex-vscode":
            return source == "codex" && navigationSessionID != nil && cwd.hasPrefix("/")
        case "codex-desktop":
            return source == "codex" && navigationSessionID != nil
        case "vscode-terminal":
            return ["claude", "vscode", "codex"].contains(source) && sessionTerminal?.hasOriginIdentity == true
        case "apple-terminal":
            return ["claude", "vscode", "codex"].contains(source) && sessionTerminal?.validatedTTY != nil && sessionTerminal?.hasOriginIdentity == true
        default:
            return false
        }
    }

    /// Describe only parameters supplied by the originating assistant.
    var actionDetail: String {
        guard let data = detailText.data(using: .utf8),
              let input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return toolName }
        func text(_ key: String) -> String? {
            guard let value = input[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        func positiveInteger(_ key: String) -> Int? {
            guard let number = input[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let value = Int(number.stringValue), value > 0 else { return nil }
            return value
        }
        switch toolName.lowercased() {
        case "read":
            guard let file = text("file_path") else { return toolName }
            if let offset = positiveInteger("offset") {
                if let limit = positiveInteger("limit") {
                    let end = offset.addingReportingOverflow(limit - 1)
                    if !end.overflow { return "Read(\(file) · lines \(offset)–\(end.partialValue))" }
                }
                return "Read(\(file) · from line \(offset))"
            }
            return "Read(\(file))"
        case "edit", "write", "multiedit":
            guard let file = text("file_path") else { return toolName }
            return "\(toolName)(\(file))"
        case "bash":
            guard let command = text("command") else { return toolName }
            return "Bash(\(command))"
        case "exec_command":
            guard let command = text("cmd") else { return toolName }
            return "\(toolName)(\(command))"
        default: return toolName
        }
    }

    /// Display only: omit top-level metadata already shown as the explanation.
    /// The original input and request snapshot remain the decision authority.
    func toolInputForDisplay(excludingDisplayedReason displayedReason: String) -> String {
        let visibleReason = displayedReason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visibleReason.isEmpty, detailText.utf8.count <= 512 * 1024,
              let data = detailText.data(using: .utf8),
              var input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return detailText }
        var removed = false
        for key in ["description", "justification", "reason", "message"] {
            if let value = input[key] as? String,
               value.trimmingCharacters(in: .whitespacesAndNewlines) == visibleReason {
                input.removeValue(forKey: key)
                removed = true
            }
        }
        guard removed, let display = try? JSONSerialization.data(withJSONObject: input,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: display, encoding: .utf8) else { return detailText }
        return text
    }

    var hasValidQuestions: Bool {
        guard let questions else { return false }
        return (1...4).contains(questions.count) && questions.allSatisfy { $0.isValid } &&
            Set(questions.map { $0.question }).count == questions.count
    }

    func acceptsAnswers(_ answers: [String: String]) -> Bool {
        guard isQuestion, responseAvailable, hasValidQuestions, let questions,
              Set(answers.keys) == Set(questions.map { $0.question }),
              answers.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              answers.values.reduce(0, { $0 + $1.utf8.count }) <= 2_000 else { return false }
        return true
    }

    func isValid(now: Double) -> Bool {
        schemaVersion == 1 && Self.validID(id) && !source.isEmpty && !sourceLabel.isEmpty &&
        !toolName.isEmpty && createdAt.isFinite && expiresAt.isFinite &&
        expiresAt > now && createdAt <= now + 60 && expiresAt > createdAt &&
        (kind == nil || ["permission", "notice", "question"].contains(kind!)) &&
        (!isQuestion || hasValidQuestions)
    }

    static func validID(_ value: String) -> Bool {
        value.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil
    }
}

/// Header text and link policy, with the technical ID kept out of visible labels.
struct SessionHeaderPresentation {
    let subject: String
    let context: String
    let fullSessionID: String
    let usesLinkCursor: Bool
    let tooltip: String
    let accessibilityLabel: String
    let accessibilityHelp: String

    var canCopySessionID: Bool { !fullSessionID.isEmpty }

    init(request: PermissionRequest) {
        subject = request.sessionDisplayName
        context = request.sessionContextLabel
        fullSessionID = PermissionRequest.sessionText(request.sessionId, limit: 256)
        usesLinkCursor = request.canOpenSession
        let identity = "Session ID: " + (fullSessionID.isEmpty ? "Unavailable" : fullSessionID)
        let detail = [subject, context, identity].filter { !$0.isEmpty }.joined(separator: "\n")
        tooltip = usesLinkCursor ? "Open this session\n" + detail :
            detail + "\nDirect session navigation is unavailable for this request."
        accessibilityLabel = (usesLinkCursor ? "Open session: " : "Session: ") + subject + ". " + identity
        accessibilityHelp = usesLinkCursor ? "Open this exact session in its originating app." :
            "Session information. Direct navigation is unavailable for this request."
    }
}

struct AgentSession: Codable {
    let source: String
    let sourceLabel: String
    let sessionId: String
    let cwd: String
    let status: String
    let updatedAt: Double
}

struct RequestSnapshot {
    let request: PermissionRequest
    let bytes: Data
}

/// Correlates asynchronous navigation with the exact card that was clicked.
struct SessionHandoffState {
    private struct Navigation {
        let token: UUID
        let snapshot: RequestSnapshot
    }
    private var navigation: Navigation?
    var isOpening: Bool { navigation != nil }
    func isCurrent(_ token: UUID) -> Bool { navigation?.token == token }

    mutating func begin(_ snapshot: RequestSnapshot) -> UUID? {
        guard navigation == nil else { return nil }
        let token = UUID()
        navigation = Navigation(token: token, snapshot: snapshot)
        return token
    }

    mutating func cancelIfChanged(_ current: RequestSnapshot?) {
        guard let navigation else { return }
        if current?.request.id != navigation.snapshot.request.id || current?.bytes != navigation.snapshot.bytes {
            self.navigation = nil
        }
    }

    mutating func finish(_ token: UUID, opened: Bool, current: RequestSnapshot?, now: Double,
                         transfer: (RequestSnapshot) throws -> Void) throws -> Bool {
        guard let navigation, navigation.token == token else { return false }
        self.navigation = nil
        guard opened, let current, current.request.id == navigation.snapshot.request.id,
              current.bytes == navigation.snapshot.bytes, current.request.isValid(now: now),
              current.request.createdAt <= now else { return false }
        try transfer(navigation.snapshot)
        return true
    }

}

struct CodexHookEvent: Codable {
    let id: String
    let session: String
    let turn: String?
    let phase: String
    let reply: String?
    let createdAt: Double

    func isValid(now: Double) -> Bool {
        func digest(_ text: String) -> Bool { text.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }
        return PermissionRequest.validID(id) && digest(session) && (turn.map(digest) ?? (phase == "reset")) &&
            ["thinking", "working", "completed", "reset"].contains(phase) && createdAt.isFinite &&
            createdAt > now - 10 && createdAt <= now + 1 &&
            (reply == nil || (phase == "completed" && reply!.utf8.count <= 2048 && reply!.count <= 240))
    }
}

enum CompanionError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

/// A local, owner-only mailbox. No terminal commands or agent transcripts are read.
final class RuntimeStore {
    let root: URL
    private var lockDescriptor: Int32 = -1
    private let fm = FileManager.default
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    var codexActivityEnabled = false
    private let startedAt = Date().timeIntervalSince1970

    init(root: URL) throws {
        self.root = root.standardizedFileURL
        encoder.outputFormatting = [.sortedKeys]
        try ensureDirectory(self.root)
        for directory in ["requests", "decisions", "sessions", "activities"] {
            try ensureDirectory(self.root.appendingPathComponent(directory))
        }
        let lockURL = self.root.appendingPathComponent("desktop.lock")
        lockDescriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, mode_t(0o600))
        guard lockDescriptor >= 0 else { throw CompanionError.message("Cannot create the desktop lock.") }
        var lockStat = stat()
        guard fstat(lockDescriptor, &lockStat) == 0, lockStat.st_uid == getuid(),
              (lockStat.st_mode & S_IFMT) == S_IFREG, (lockStat.st_mode & 0o077) == 0 else {
            close(lockDescriptor); lockDescriptor = -1
            throw CompanionError.message("The desktop lock is not a safe local file.")
        }
        guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(lockDescriptor); lockDescriptor = -1
            throw CompanionError.message("A companion is already running for this mailbox.")
        }
    }

    deinit {
        if lockDescriptor >= 0 { flock(lockDescriptor, LOCK_UN); close(lockDescriptor) }
    }

    private func ensureDirectory(_ url: URL) throws {
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else {
            throw CompanionError.message("Mailbox folders must be private, owned by you, and cannot be symbolic links. Use a dedicated runtime folder.")
        }
    }

    private func verifyDirectories() throws {
        for path in [root, root.appendingPathComponent("requests"),
                     root.appendingPathComponent("decisions"), root.appendingPathComponent("sessions"),
                     root.appendingPathComponent("activities")] {
            var info = stat()
            guard lstat(path.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else {
                throw CompanionError.message("The local mailbox is unavailable or has unsafe permissions.")
            }
        }
    }

    private func readRegularFile(_ url: URL, limit: Int = 2_000_000) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw CompanionError.message("A mailbox file is unavailable.") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), (info.st_mode & 0o077) == 0,
              info.st_size >= 0, info.st_size <= limit else {
            throw CompanionError.message("A mailbox file is invalid.")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw CompanionError.message("Cannot read the local mailbox.") }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(Int(count)))
            guard data.count <= limit else { throw CompanionError.message("A mailbox file is too large.") }
        }
        return data
    }

    func poll(now: Double) throws -> ([RequestSnapshot], [AgentSession]) {
        try verifyDirectories()
        let requestDirectory = root.appendingPathComponent("requests")
        let files = try fm.contentsOfDirectory(at: requestDirectory, includingPropertiesForKeys: nil,
                                               options: [.skipsHiddenFiles])
        var pending: [RequestSnapshot] = []
        for file in files {
            let id = file.deletingPathExtension().lastPathComponent
            guard file.pathExtension == "json", PermissionRequest.validID(id),
                  let bytes = try? readRegularFile(file),
                  let request = try? decoder.decode(PermissionRequest.self, from: bytes),
                  request.id == id, request.isValid(now: now) else { continue }
            if validDecision(for: request, now: now) { continue }
            pending.append(RequestSnapshot(request: request, bytes: bytes))
        }
        pending.sort { a, b in
            a.request.createdAt == b.request.createdAt ? a.request.id < b.request.id :
                a.request.createdAt < b.request.createdAt
        }
        let sessionFiles = try fm.contentsOfDirectory(at: root.appendingPathComponent("sessions"),
                                                      includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        let sessions = sessionFiles.compactMap { file -> AgentSession? in
            guard file.pathExtension == "json",
                  file.deletingPathExtension().lastPathComponent.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  let bytes = try? readRegularFile(file, limit: 1_024 * 1_024),
                  let session = try? decoder.decode(AgentSession.self, from: bytes),
                  session.updatedAt.isFinite, session.updatedAt > now - 300, session.updatedAt <= now + 60,
                  ["working", "idle", "attention", "offline"].contains(session.status) else { return nil }
            return session
        }.sorted { $0.sourceLabel < $1.sourceLabel }
        struct Heartbeat: Encodable { let updatedAt: Double; let codexActivity: Bool }
        try writeAtomic(try encoder.encode(Heartbeat(updatedAt: now, codexActivity: codexActivityEnabled)),
                        to: root.appendingPathComponent("heartbeat.json"), replace: true)
        return (pending, sessions)
    }

    func consumeCodexActivities(now: Double) throws -> [CodexHookEvent] {
        try verifyDirectories()
        let files = try fm.contentsOfDirectory(at: root.appendingPathComponent("activities"),
                                               includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var events: [CodexHookEvent] = []
        for file in files {
            guard file.pathExtension == "json", PermissionRequest.validID(file.deletingPathExtension().lastPathComponent) else { continue }
            // Events predating launch are discarded, never replayed as new replies.
            if let bytes = try? readRegularFile(file, limit: 8192),
               let event = try? decoder.decode(CodexHookEvent.self, from: bytes), event.id == file.deletingPathExtension().lastPathComponent,
               event.isValid(now: now), event.createdAt >= startedAt, codexActivityEnabled { events.append(event) }
            _ = unlink(file.path)
        }
        return events.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
    }

    private func decisionURL(_ id: String) -> URL {
        root.appendingPathComponent("decisions").appendingPathComponent(id + ".json")
    }

    private func validDecision(for request: PermissionRequest, now: Double) -> Bool {
        struct Decision: Decodable { let id: String; let decision: String; let answers: [String: String]?; let decidedAt: Double }
        guard let bytes = try? readRegularFile(decisionURL(request.id), limit: 4_096),
              let decision = try? decoder.decode(Decision.self, from: bytes),
              decision.id == request.id,
              decision.decidedAt.isFinite, decision.decidedAt >= request.createdAt,
              decision.decidedAt <= min(now, request.expiresAt) else { return false }
        if request.isQuestion {
            return request.responseAvailable && ((decision.decision == "defer" && decision.answers == nil) ||
                (decision.decision == "answer" && decision.answers.map { request.acceptsAnswers($0) } == true))
        }
        guard request.responseAvailable,
              let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              Set(object.keys) == Set(["id", "decision", "decidedAt"]), decision.answers == nil else { return false }
        return ["allow", "deny"].contains(decision.decision) || (decision.decision == "defer" && request.canDefer == true)
    }

    /// Return this exact request to its originating UI without answering it.
    /// The bridge lock prevents a source completion from racing publication.
    func handoff(_ snapshot: RequestSnapshot) throws {
        try verifyDirectories()
        let fd = open(root.appendingPathComponent("bridge.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, mode_t(0o600))
        guard fd >= 0 else { throw CompanionError.message("The source connection is unavailable. This request remains in Pip.") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw CompanionError.message("Pip is updating this request. It remains here; try opening its session again.")
        }
        defer { flock(fd, LOCK_UN) }
        let request = snapshot.request, now = Date().timeIntervalSince1970
        guard request.isValid(now: now), request.createdAt <= now else {
            throw CompanionError.message("This request has expired or changed. Review the current request in Pip.")
        }
        let url = root.appendingPathComponent("requests").appendingPathComponent(request.id + ".json")
        guard try readRegularFile(url) == snapshot.bytes else {
            throw CompanionError.message("This request changed. Review it again in Pip.")
        }
        var decisionInfo = stat()
        guard lstat(decisionURL(request.id).path, &decisionInfo) != 0, errno == ENOENT else {
            throw CompanionError.message("This request already has a response or is no longer available.")
        }
        if !request.responseAvailable { try dismissNotice(snapshot) }
        else if request.isQuestion { try answer(snapshot, answers: nil) }
        else {
            guard request.canDefer == true else {
                throw CompanionError.message("This request uses an older Pip connection. Answer it here; new requests can continue in the source app.")
            }
            struct Deferred: Encodable { let id: String; let decision = "defer"; let decidedAt: Double }
            try writeAtomic(encoder.encode(Deferred(id: request.id, decidedAt: now)),
                            to: decisionURL(request.id), replace: false)
        }
    }

    func decide(_ snapshot: RequestSnapshot, allow: Bool) throws {
        try verifyDirectories()
        let now = Date().timeIntervalSince1970
        let request = snapshot.request
        guard !request.isQuestion else { throw CompanionError.message("Answer this question or continue in the source app.") }
        guard request.responseAvailable else { throw CompanionError.message("Continue with this request in the source app.") }
        guard request.isValid(now: now) else { throw CompanionError.message("This request has expired.") }
        let current = try readRegularFile(root.appendingPathComponent("requests").appendingPathComponent(request.id + ".json"))
        guard current == snapshot.bytes else {
            throw CompanionError.message("This request changed. Review it again before deciding.")
        }
        struct Decision: Encodable { let id: String; let decision: String; let decidedAt: Double }
        let data = try encoder.encode(Decision(id: request.id, decision: allow ? "allow" : "deny", decidedAt: now))
        try writeAtomic(data, to: decisionURL(request.id), replace: false)
    }

    func answer(_ snapshot: RequestSnapshot, answers: [String: String]?) throws {
        try verifyDirectories()
        let now = Date().timeIntervalSince1970
        let request = snapshot.request
        guard request.isQuestion, request.responseAvailable, request.hasValidQuestions else {
            throw CompanionError.message("Continue with this question in the source app.")
        }
        guard request.isValid(now: now) else { throw CompanionError.message("This question has expired.") }
        let url = root.appendingPathComponent("requests").appendingPathComponent(request.id + ".json")
        guard try readRegularFile(url) == snapshot.bytes else {
            throw CompanionError.message("This question changed. Review it again before answering.")
        }
        if let answers, !request.acceptsAnswers(answers) {
            throw CompanionError.message("Answer every question. Keep all answers together under 2,000 bytes.")
        }
        struct AnswerDecision: Encodable { let id: String; let decision: String; let answers: [String: String]?; let decidedAt: Double }
        let data = try encoder.encode(AnswerDecision(id: request.id, decision: answers == nil ? "defer" : "answer", answers: answers, decidedAt: now))
        guard data.count <= 4_096 else { throw CompanionError.message("Your answers are too long. Shorten them or answer in the source app.") }
        try writeAtomic(data, to: decisionURL(request.id), replace: false)
    }

    func dismissNotice(_ snapshot: RequestSnapshot) throws {
        try verifyDirectories()
        guard !snapshot.request.responseAvailable, snapshot.request.isValid(now: Date().timeIntervalSince1970) else {
            throw CompanionError.message("This alert is no longer available.")
        }
        let url = root.appendingPathComponent("requests").appendingPathComponent(snapshot.request.id + ".json")
        guard try readRegularFile(url) == snapshot.bytes else {
            throw CompanionError.message("This alert changed. Review it again.")
        }
        guard unlink(url.path) == 0 else { throw CompanionError.message("This alert is no longer available.") }
    }

    private func writeAtomic(_ data: Data, to destination: URL, replace: Bool) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".desktop-" + UUID().uuidString)
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw CompanionError.message("Cannot write to the local mailbox.") }
        var complete = false
        defer { close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < data.count {
                let count = write(fd, base.advanced(by: written), data.count - written)
                if count < 0 { if errno == EINTR { continue }; throw CompanionError.message("Cannot save the decision.") }
                guard count > 0 else { throw CompanionError.message("Cannot save the decision.") }
                written += count
            }
        }
        guard fsync(fd) == 0 else { throw CompanionError.message("Cannot save the local mailbox.") }
        if replace { complete = rename(temporary.path, destination.path) == 0 }
        else { complete = link(temporary.path, destination.path) == 0 }
        guard complete else {
            throw CompanionError.message(replace ? "Cannot update the local mailbox." : "This request was already decided or is no longer available.")
        }
    }

    func stopHeartbeat() {
        _ = unlink(root.appendingPathComponent("heartbeat.json").path)
    }
}
