import AppKit
import ApplicationServices
import CryptoKit
import Foundation

struct DesktopChatConnection: Equatable {
    enum Status: Equatable { case notRunning, permissionRequired, unsupported, connected }
    let provider: String
    let status: Status
    let title: String?
    let detail: String?
    init(provider: String, status: Status, title: String?, detail: String? = nil) {
        self.provider = provider; self.status = status; self.title = title; self.detail = detail
    }
}

enum DesktopChatReadPolicy {
    static let maximumSeconds = 1.2
    static let messageTimeout: Float = 0.08
    static let maximumNodes = 280
    static let maximumWindows = 8
    static let maximumScopeDepth = 32
    static let maximumControlDepth = 48
    static func completeChildRange(reportedCount: Int, returnedCount: Int?) -> Bool {
        reportedCount >= 0 && returnedCount == min(reportedCount, 48)
    }
}

/// Content-free counters for diagnosing an unsupported selected-chat layout.
/// No attribute strings, titles, identifiers, or URLs are retained here.
struct DesktopChatScopeDiagnostics {
    private(set) var maximumAttemptedDepth = 0
    private(set) var depthLimitHits = 0
    private(set) var cycleHits = 0
    private(set) var groupRoles = 0
    private(set) var scrollRoles = 0
    private(set) var webRoles = 0
    private(set) var otherRoles = 0
    private(set) var unknownRoles = 0
    private(set) var metadataValues = 0
    private(set) var metadataEmpty = 0
    private(set) var metadataAbsent = 0
    private(set) var metadataUnsupported = 0
    private(set) var metadataInvalid = 0
    private(set) var metadataFailed = 0

    mutating func attempt(depth: Int, isAncestor: Bool = false) -> Bool {
        maximumAttemptedDepth = max(maximumAttemptedDepth, depth)
        guard !isAncestor else { cycleHits += 1; return false }
        guard depth <= DesktopChatReadPolicy.maximumScopeDepth else { depthLimitHits += 1; return false }
        return true
    }
    mutating func recordRole(_ role: String, error: AXError) {
        guard error == .success, !role.isEmpty else { unknownRoles += 1; return }
        switch role {
        case "AXGroup": groupRoles += 1
        case "AXScrollArea": scrollRoles += 1
        case "AXWebArea": webRoles += 1
        default: otherRoles += 1
        }
    }
    mutating func recordMetadata(error: AXError, hasValue: Bool, isString: Bool, nonempty: Bool) {
        switch error {
        case .success:
            if !hasValue { metadataAbsent += 1 }
            else if !isString { metadataInvalid += 1 }
            else if nonempty { metadataValues += 1 }
            else { metadataEmpty += 1 }
        case .noValue: metadataAbsent += 1
        case .attributeUnsupported: metadataUnsupported += 1
        default: metadataFailed += 1
        }
    }
    var summary: String {
        "attempt-depth:\(maximumAttemptedDepth), depth-hits:\(depthLimitHits), cycles:\(cycleHits), roles:g\(groupRoles)/s\(scrollRoles)/w\(webRoles)/o\(otherRoles)/unknown\(unknownRoles), metadata:value\(metadataValues)/empty\(metadataEmpty)/absent\(metadataAbsent)/unsupported\(metadataUnsupported)/invalid\(metadataInvalid)/error\(metadataFailed)"
    }
}

enum DesktopChatWindowPolicy {
    enum Reference: Equatable { case present, absent, unsupported, failed }
    enum Choice: Equatable { case focused, main, fallback, reject }
    struct Candidate {
        let standard: Bool
        let minimized: Bool
        let hidden: Bool
        let modal: Bool
        let hasSheet: Bool
        var eligible: Bool { standard && !minimized && !hidden && !modal && !hasSheet }
    }
    static func initial(focused: Reference, main: Reference) -> Choice {
        if focused == .present { return .focused }
        guard focused == .absent || focused == .unsupported else { return .reject }
        if main == .present { return .main }
        return main == .absent || main == .unsupported ? .fallback : .reject
    }
    static func unique(_ windows: [Candidate], complete: Bool = true) -> Int? {
        guard complete, windows.count <= DesktopChatReadPolicy.maximumWindows else { return nil }
        let eligible = windows.indices.filter { windows[$0].eligible }
        return eligible.count == 1 ? eligible[0] : nil
    }
    static func nativeIdentifier(provider: String, bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return ProviderApps.identifiers(provider).contains(bundleIdentifier)
    }
    static func reference(error: AXError, hasValue: Bool) -> Reference {
        switch error {
        case .success: return hasValue ? .present : .absent
        case .noValue: return .absent
        case .attributeUnsupported: return .unsupported
        default: return .failed
        }
    }
}

/// These values contain only the selected chat's public accessibility metadata.
/// No transcript, composer contents, or identifiers are written to disk.
struct DesktopAssistantReply: Equatable {
    let id: String?
    let text: String
    var digest: String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
}

struct DesktopChatSnapshot: Equatable {
    let provider: String
    let identity: String
    let title: String
    let busy: Bool
    let reply: DesktopAssistantReply?
    var reliableIdentity = true
}

/// A conservative pure state machine: opening or switching chats baselines the
/// existing reply. A response must settle across two samples before it is shown.
struct DesktopChatTracking {
    private(set) var snapshot: DesktopChatSnapshot?
    private var runID = UUID()
    private var baseline: DesktopAssistantReply?
    private var busy = false
    private var candidate: DesktopAssistantReply?
    private var candidateSamples = 0
    private var pendingCompletion = false

    mutating func disconnect(provider: String) -> [CompanionChatActivity] {
        guard snapshot != nil else { return [] }
        snapshot = nil; baseline = nil; candidate = nil; busy = false
        candidateSamples = 0; pendingCompletion = false
        return [activity(provider: provider, title: "", phase: .reset)]
    }

    mutating func receive(_ value: DesktopChatSnapshot) -> [CompanionChatActivity] {
        guard snapshot?.provider == value.provider, snapshot?.identity == value.identity else {
            var output = snapshot.map { [activity(provider: $0.provider, title: "", phase: .reset)] } ?? []
            snapshot = value; baseline = value.reply; candidate = nil
            candidateSamples = 0; pendingCompletion = false
            busy = value.busy; runID = UUID()
            output.append(activity(provider: value.provider, title: value.title, phase: .connected))
            if value.busy { output.append(activity(provider: value.provider, title: value.title, phase: .thinking)) }
            return output
        }
        let titleChanged = snapshot?.title != value.title
        let previouslyVisibleReply = snapshot?.reply
        snapshot = value
        if value.busy {
            candidate = nil; candidateSamples = 0; pendingCompletion = false
            if !busy {
                baseline = previouslyVisibleReply
                busy = true; runID = UUID()
                return [activity(provider: value.provider, title: value.title, phase: .thinking)]
            }
            if titleChanged { return [activity(provider: value.provider, title: value.title, phase: .thinking)] }
            return []
        }
        if busy { busy = false; pendingCompletion = true; candidate = nil; candidateSamples = 0 }
        if candidate == value.reply { candidateSamples += 1 }
        else { candidate = value.reply; candidateSamples = 1 }
        guard candidateSamples >= 2 else {
            return titleChanged && !pendingCompletion ? [activity(provider: value.provider, title: value.title, phase: .connected)] : []
        }
        if pendingCompletion {
            pendingCompletion = false
            let newReply = value.reliableIdentity && value.reply != baseline ? value.reply?.text : nil
            if let reply = value.reply { baseline = reply }
            return [activity(provider: value.provider, title: value.title, phase: .completed,
                             reply: newReply.flatMap(CompanionChatActivity.shortReply))]
        }
        // A changed identifier can result from history loading, scrolling, or
        // virtualization. Without a real observed busy phase it is only a new
        // baseline, never evidence that the assistant just answered.
        baseline = value.reply
        return titleChanged ? [activity(provider: value.provider, title: value.title, phase: .connected)] : []
    }

    private func activity(provider: String, title: String, phase: CompanionChatActivity.Phase,
                          reply: String? = nil) -> CompanionChatActivity {
        CompanionChatActivity(provider: provider, runID: runID, title: title, phase: phase,
                              reply: reply, origin: .desktop)
    }
}

/// Fixture representation intentionally separates structural metadata from text.
/// The live reader populates text only for noneditable assistant message leaves.
struct DesktopChatNode {
    var role: String
    var identifier: String = ""
    var label: String = ""
    var text: String? = nil
    var editable = false
    var enabled = true
    var children: [DesktopChatNode] = []
}

/// Shared cancellation gate also guards already queued main-thread callbacks.
final class DesktopChatEpoch {
    private let lock = NSLock()
    private var value = 0
    private var wantsRunning = false
    var current: Int { lock.lock(); defer { lock.unlock() }; return value }
    var runningRequested: Bool { lock.lock(); defer { lock.unlock() }; return wantsRunning }
    func advance() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    func matches(_ token: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return token == value }
    func requestRunning(_ running: Bool) { lock.lock(); wantsRunning = running; lock.unlock() }
}

enum DesktopChatSemantics {
    enum MessageRole { case assistant, user, unknown }
    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    static func validatedBusy(observedStop: Bool, requiredReadsSucceeded: Bool) -> Bool? {
        observedStop ? true : requiredReadsSucceeded ? false : nil
    }
    static func nextControlPathNode(markerIndex: Int?, pathCount: Int) -> Int? {
        guard let markerIndex, markerIndex >= 0, markerIndex + 1 < pathCount else { return nil }
        return markerIndex + 1
    }
    static func metadataLabel(role: String, description: String, title: String) -> String {
        let candidates = [description, title].filter { !$0.isEmpty }
        if role == "AXHeading" {
            for value in [title, description] {
                if let kind = roleHeading(value) { return kind }
            }
            return title.isEmpty ? description : title
        }
        for value in candidates {
            if chatContainer(identifier: "", label: value) || messageWrapper(value) ||
                ["sidebar", "primary pane", "composer"].contains(normalized(value)) { return value }
        }
        let generic = ["group", "container", "button", "web area", "heading", "text", "scroll area"]
        return candidates.first { !generic.contains(normalized($0)) } ?? candidates.first ?? ""
    }
    static func excluded(role: String, identifier: String, label: String) -> Bool {
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField", "AXOutline", "AXList", "AXTable",
            "AXBrowser", "AXMenu", "AXMenuBar", "AXDialog", "AXSheet"].contains(role) { return true }
        let metadata = normalized(identifier + " " + label)
        return ["sidebar", "navigation", "conversation history", "chat history", "composer", "message input",
                "user message", "user-message", "human message", "authentication", "login", "sign in",
                "settings", "search results"].contains { metadata.contains($0) }
    }
    static func assistantContentExcluded(role: String, identifier: String, label: String) -> Bool {
        // Lists inside a classified assistant response are reply content. Lists
        // outside it remain excluded because they can be conversation history.
        let label = ["AXStaticText", "AXHeading"].contains(role) ? "" : label
        return excluded(role: role == "AXList" ? "AXGroup" : role, identifier: identifier, label: "") ||
            ["sidebar", "navigation", "conversation history", "chat history", "composer", "message input",
             "user message", "authentication", "sign in", "settings"].contains(normalized(label)) ||
            ["tool status", "tool activity", "message actions"].contains(normalized(label)) ||
            normalized(identifier).hasPrefix("tool-status")
    }
    static func assistant(identifier: String, label: String) -> Bool {
        let identifier = normalized(identifier), label = normalized(label)
        return identifier.hasPrefix("assistant-message") || identifier.hasPrefix("assistant-response") ||
            ["assistant message", "assistant response", "claude response", "chatgpt response", "assistant"].contains(label)
    }
    static func stop(role: String, label: String, enabled: Bool, inComposer: Bool = false) -> Bool {
        role == "AXButton" && enabled &&
            ["stop generating", "stop response", "stop responding", "stop streaming", "stop claude"].contains(normalized(label))
    }
    static func chatContainer(identifier: String, label: String) -> Bool {
        let identifier = normalized(identifier), label = normalized(label)
        return ["chat-messages", "conversation-messages", "chat-thread", "conversation-thread"].contains(identifier) ||
            ["conversation", "conversation messages", "chat messages", "chat thread", "current conversation"].contains(label)
    }
    static func messageWrapper(_ label: String) -> Bool {
        let parts = normalized(label).split(separator: " ")
        return parts.count == 4 && parts[0] == "message" && Int(parts[1]) != nil &&
            parts[2] == "of" && Int(parts[3]) != nil
    }
    static func claudeHeading(_ label: String) -> Bool { normalized(label).hasPrefix("claude responded:") }
    static func roleHeading(_ label: String) -> String? {
        let normalized = normalized(label)
        if normalized.hasPrefix("claude responded:") { return "Claude responded:" }
        if normalized.hasPrefix("you said:") { return "You said:" }
        return nil
    }
    static func assistantWrapper(_ node: DesktopChatNode) -> Bool {
        if assistant(identifier: node.identifier, label: node.label) { return true }
        return messageWrapper(node.label) && messageRole(node) == .assistant
    }
    static func messageRole(_ node: DesktopChatNode) -> MessageRole {
        guard messageWrapper(node.label) else { return .unknown }
        var visited = 0
        func heading(_ child: DesktopChatNode, depth: Int) -> MessageRole {
            guard depth <= 4, visited < 18, !child.editable,
                  !excluded(role: child.role, identifier: child.identifier, label: child.label) else { return .unknown }
            visited += 1
            if child.role == "AXHeading" {
                if claudeHeading(child.label) { return .assistant }
                if roleHeading(child.label) == "You said:" { return .user }
                return .unknown
            }
            for descendant in child.children {
                let role = heading(descendant, depth: depth + 1)
                if role != .unknown { return role }
            }
            return .unknown
        }
        return heading(node, depth: 0)
    }
    static func webConversationTitle(_ title: String, provider: String) -> String? {
        let suffix = provider == "claude" ? " - Claude" : " - ChatGPT"
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.hasSuffix(suffix) else { return nil }
        let name = String(cleaned.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : String(name.prefix(48))
    }
    static func trustedClaudeShell(provider: String, bundleURL: URL?, url: String) -> Bool {
        guard provider == "claude", let bundleURL, bundleURL.isFileURL, url.utf8.count <= 4096,
              let components = URLComponents(string: url), components.scheme?.lowercased() == "file",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              components.host == nil || components.host == "" || components.host?.lowercased() == "localhost" else { return false }
        let expected = bundleURL.appendingPathComponent("Contents/Resources/app.asar/.vite/renderer/main_window/index.html").standardizedFileURL.path
        let segments = components.path.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.contains("."), !segments.contains("..") else { return false }
        return components.path == expected
    }
    static func containsChatScope(_ root: DesktopChatNode) -> Bool {
        var nodes = 0
        func walk(_ node: DesktopChatNode, depth: Int) -> Bool {
            guard depth <= 12, nodes < 180, !node.editable,
                  !excluded(role: node.role, identifier: node.identifier, label: node.label) else { return false }
            nodes += 1
            if chatContainer(identifier: node.identifier, label: node.label) { return true }
            return node.children.contains { walk($0, depth: depth + 1) }
        }
        return walk(root, depth: 0)
    }
    static func busyOutsideChat(_ root: DesktopChatNode) -> Bool {
        var nodes = 0
        func walk(_ node: DesktopChatNode, depth: Int) -> Bool {
            guard depth <= 16, nodes < 180, !node.editable,
                  !chatContainer(identifier: node.identifier, label: node.label) else { return false }
            let composer = ["AXGroup", "AXScrollArea"].contains(node.role) &&
                normalized(node.identifier + " " + node.label).contains("composer")
            guard composer || !excluded(role: node.role, identifier: node.identifier, label: node.label) else { return false }
            nodes += 1
            if stop(role: node.role, label: node.label, enabled: node.enabled) { return true }
            return node.children.contains { walk($0, depth: depth + 1) }
        }
        return walk(root, depth: 0)
    }
    enum LatestAssistant { case found(DesktopChatNode), none, unknown }
    static func latestAssistant(_ root: DesktopChatNode) -> LatestAssistant {
        var nodes = 0
        func walk(_ node: DesktopChatNode, depth: Int) -> LatestAssistant {
            guard depth <= 12, nodes < 180 else { return .unknown }
            guard !node.editable, !excluded(role: node.role, identifier: node.identifier, label: node.label) else { return .none }
            nodes += 1
            if messageWrapper(node.label) {
                switch messageRole(node) {
                case .assistant: return .found(node)
                case .user: return .none
                case .unknown: return .unknown
                }
            }
            if assistant(identifier: node.identifier, label: node.label) { return .found(node) }
            for child in node.children.suffix(48).reversed() {
                switch walk(child, depth: depth + 1) {
                case .none: continue
                case let .found(value): return .found(value)
                case .unknown: return .unknown
                }
            }
            return .none
        }
        return walk(root, depth: 0)
    }
    static func conversationIdentity(provider: String, url: String, identifier: String) -> String? {
        guard !url.isEmpty || !identifier.isEmpty else { return nil }
        let url = url.hasPrefix("claude.ai/chat/") || url.hasPrefix("chatgpt.com/c/") ? "https://" + url : url
        if url.utf8.count <= 2048, let components = URLComponents(string: url),
           let host = components.host?.lowercased(), components.scheme?.lowercased() == "https" {
            let path = components.path.split(separator: "/").map(String.init)
            let conversationID: String?
            if provider == "claude", host == "claude.ai", path.count == 2, path[0] == "chat" {
                conversationID = path[1]
            } else if provider == "codex", ["chatgpt.com", "chat.openai.com"].contains(host),
                      path.count == 2, path[0] == "c" {
                conversationID = path[1]
            } else if provider == "codex", host == "chatgpt.com", path.count == 4,
                      path[0] == "g", path[2] == "c" {
                conversationID = path[3]
            } else { conversationID = nil }
            if let conversationID, UUID(uuidString: conversationID) != nil {
                return digest(provider + ":" + host + ":" + components.path)
            }
        }
        // Only a deliberately marked per-conversation UUID qualifies. A generic
        // chat-thread/chat-messages DOM identifier is not a conversation key.
        for prefix in ["conversation-", "chat-"] where identifier.hasPrefix(prefix) {
            let id = String(identifier.dropFirst(prefix.count))
            if UUID(uuidString: id) != nil { return digest(provider + ":" + identifier) }
        }
        return nil
    }
    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func parse(_ root: DesktopChatNode) -> (busy: Bool, reply: DesktopAssistantReply?) {
        var busy = false, latestReply: DesktopAssistantReply?, visited = 0, truncated = false
        func walk(_ node: DesktopChatNode, depth: Int) {
            guard depth <= 12, visited < 180 else { truncated = true; return }
            guard !node.editable,
                  !excluded(role: node.role, identifier: node.identifier, label: node.label) else { return }
            visited += 1
            if stop(role: node.role, label: node.label, enabled: node.enabled) { busy = true }
            if messageWrapper(node.label) && !assistantWrapper(node) {
                if messageRole(node) == .unknown { latestReply = nil }
                return
            }
            if assistantWrapper(node) {
                var text = "", leaves = 0, complete = true
                func assistantText(_ leaf: DesktopChatNode, level: Int) {
                    guard level <= 10, leaves < 100 else { complete = false; return }
                    guard text.count <= 300 else { return }
                    if ["AXTable", "AXOutline", "AXBrowser"].contains(leaf.role) { complete = false; return }
                    guard !leaf.editable,
                          !["AXButton", "AXImage", "AXToolbar"].contains(leaf.role),
                          !(leaf.role == "AXHeading" && claudeHeading(leaf.label)),
                          !assistantContentExcluded(role: leaf.role, identifier: leaf.identifier, label: leaf.label) else { return }
                    leaves += 1
                    if ["AXStaticText", "AXHeading"].contains(leaf.role), let content = leaf.text {
                        if !text.isEmpty { text += "\n" }; text += String(content.prefix(301))
                    }
                    for child in leaf.children { assistantText(child, level: level + 1) }
                }
                assistantText(node, level: 0)
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                latestReply = complete && !cleaned.isEmpty ?
                    DesktopAssistantReply(id: node.identifier.isEmpty ? nil : node.identifier,
                                          text: String(cleaned.prefix(301))) : nil
                return
            }
            for child in node.children { walk(child, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return (busy, truncated ? nil : latestReply)
    }
}

/// Read-only public AX bridge. Opt-in selection and trust checks happen before
/// any app inspection; only an allowlisted selected standard window is queried.
final class DesktopChatObserver {
    var onActivity: ((CompanionChatActivity) -> Void)?
    var onConnection: ((DesktopChatConnection) -> Void)?
    private let queue = DispatchQueue(label: "dev.local.pip.desktop-chat", qos: .utility)
    private let gate = DesktopChatEpoch()
    private var timer: DispatchSourceTimer?
    private var selectedProvider: String?
    private var tracking = DesktopChatTracking()
    private var lastConnection: DesktopChatConnection?

    static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    func start() {
        gate.requestRunning(true)
        queue.async { [weak self] in
            guard let self, self.gate.runningRequested, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(600), leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer; timer.resume()
        }
    }

    func select(provider: String) {
        guard !ProviderApps.identifiers(provider).isEmpty else { return }
        let generation = gate.advance()
        queue.async { [weak self] in
            guard let self, self.gate.matches(generation) else { return }
            if let previous = self.selectedProvider {
                for activity in self.tracking.disconnect(provider: previous) { self.publish(activity, epoch: generation) }
            }
            self.selectedProvider = provider; self.lastConnection = nil
            if self.gate.runningRequested { self.poll() }
        }
    }

    func stop() {
        gate.requestRunning(false)
        let generation = gate.advance()
        queue.async { [weak self] in
            guard let self, !self.gate.runningRequested else { return }
            self.timer?.cancel(); self.timer = nil
            guard self.gate.matches(generation) else { return }
            if let provider = self.selectedProvider {
                for activity in self.tracking.disconnect(provider: provider) { self.publish(activity, epoch: generation) }
            }
            self.selectedProvider = nil; self.lastConnection = nil
        }
    }

    private func publish(_ activity: CompanionChatActivity, epoch: Int) {
        guard gate.matches(epoch) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.gate.matches(epoch), activity.phase == .reset || Self.hasAccessibilityPermission else { return }
            self.onActivity?(activity)
        }
    }

    private func connection(_ value: DesktopChatConnection, epoch: Int) {
        guard gate.matches(epoch) else { return }
        guard value != lastConnection else { return }
        lastConnection = value
        DispatchQueue.main.async { [weak self] in
            guard let self, self.gate.matches(epoch), value.status != .connected || Self.hasAccessibilityPermission else { return }
            self.onConnection?(value)
        }
    }

    private func disconnected(provider: String, status: DesktopChatConnection.Status, epoch: Int, detail: String? = nil) {
        guard gate.matches(epoch) else { return }
        for activity in tracking.disconnect(provider: provider) { publish(activity, epoch: epoch) }
        connection(DesktopChatConnection(provider: provider, status: status, title: nil, detail: detail), epoch: epoch)
    }

    private func poll() {
        guard gate.runningRequested else { return }
        let generation = gate.current
        guard let provider = selectedProvider else { return }
        guard Self.hasAccessibilityPermission else {
            disconnected(provider: provider, status: .permissionRequired, epoch: generation); return
        }
        let allowed = NSWorkspace.shared.runningApplications.filter { application in
            guard let url = application.bundleURL, !application.isTerminated else { return false }
            guard DesktopChatWindowPolicy.nativeIdentifier(provider: provider, bundleIdentifier: application.bundleIdentifier) else { return false }
            return ProviderApps.preferredApplicationURL(provider: provider, candidates: [url]) != nil
        }
        guard allowed.count == 1, let application = allowed.first else {
            disconnected(provider: provider, status: .notRunning, epoch: generation); return
        }
        guard !application.isHidden else {
            disconnected(provider: provider, status: .unsupported, epoch: generation, detail: "The desktop app is hidden"); return
        }
        let result = DesktopChatAXReader.read(application: application, provider: provider)
        guard gate.matches(generation) else { return }
        guard Self.hasAccessibilityPermission else {
            disconnected(provider: provider, status: .permissionRequired, epoch: generation); return
        }
        guard let snapshot = result.snapshot else {
            disconnected(provider: provider, status: .unsupported, epoch: generation, detail: result.detail); return
        }
        connection(DesktopChatConnection(provider: provider, status: .connected, title: snapshot.title), epoch: generation)
        guard gate.matches(generation) else { return }
        for activity in tracking.receive(snapshot) { publish(activity, epoch: generation) }
    }
}

private final class DesktopChatAXReader {
    private enum MessageRole { case assistant, user, unknown }
    private enum LatestAssistant { case found(AXUIElement), none, unknown }
    struct Result { let snapshot: DesktopChatSnapshot?; let detail: String? }
    private struct ChatScope {
        let element: AXUIElement
        let key: String?
        let title: String?
        let webArea: AXUIElement?
        let shells: [AXUIElement]
        let path: [AXUIElement]
    }
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var deadline: Double { startedAt + DesktopChatReadPolicy.maximumSeconds }
    private var remaining = DesktopChatReadPolicy.maximumNodes
    private var titleNodes = 16
    private var contentIncomplete = false
    private var stage = "window"
    private var calls = 0
    private var selectedWebArea: AXUIElement?
    private var selectedShells: [AXUIElement] = []
    private var selectedScopePath: [AXUIElement] = []
    private var selectedBundleURL: URL?
    private var webAreasSeen = 0
    private var verifiedRoutes = 0
    private var localShells = 0
    private var chatMarkers = 0
    private var scopeDiagnostics = DesktopChatScopeDiagnostics()
    private var lastURLCategory = "unread"
    private var lastURLKind = "none"
    private var busyReadFailed = false
    private var windowDiagnostic = ""
    private var exhausted: Bool { remaining <= 0 || ProcessInfo.processInfo.systemUptime >= deadline }

    private func readAttribute(_ element: AXUIElement, _ name: String) -> (value: CFTypeRef?, error: AXError) {
        guard !exhausted else { return (nil, .cannotComplete) }
        // Messaging timeouts belong to each client AX element, not its app's
        // descendants. This only configures the read; it does not change UI.
        AXUIElementSetMessagingTimeout(element, DesktopChatReadPolicy.messageTimeout)
        calls += 1
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (error == .success ? value : nil, error)
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        readAttribute(element, name).value
    }
    private static func category(_ error: AXError, value: CFTypeRef? = nil) -> String {
        switch error {
        case .success: return value == nil ? "no-value" : "available"
        case .attributeUnsupported: return "unsupported"
        case .notImplemented: return "not-implemented"
        case .noValue: return "no-value"
        case .apiDisabled: return "API-disabled"
        case .invalidUIElement: return "invalid-element"
        case .cannotComplete: return "cannot-complete"
        default: return "read-error"
        }
    }
    private static func reference(_ result: (value: CFTypeRef?, error: AXError)) -> DesktopChatWindowPolicy.Reference {
        DesktopChatWindowPolicy.reference(error: result.error, hasValue: result.value != nil)
    }
    private func string(_ element: AXUIElement, _ name: String) -> String {
        (attribute(element, name) as? String).map { String($0.prefix(400)) } ?? ""
    }
    private func bool(_ element: AXUIElement, _ name: String) -> Bool? { attribute(element, name) as? Bool }
    private func identifier(_ element: AXUIElement) -> String {
        let native = string(element, kAXIdentifierAttribute)
        return native.isEmpty ? string(element, "AXDOMIdentifier") : native
    }
    private func metadataLabel(_ element: AXUIElement, role: String, diagnosingScope: Bool = false) -> String {
        func metadata(_ name: String) -> String {
            let result = readAttribute(element, name)
            let value = (result.value as? String).map { String($0.prefix(400)) }
            if diagnosingScope {
                scopeDiagnostics.recordMetadata(error: result.error, hasValue: result.value != nil,
                    isString: value != nil, nonempty: !(value ?? "").isEmpty)
            }
            return value ?? ""
        }
        let description = metadata(kAXDescriptionAttribute)
        let title = ["AXGroup", "AXButton", "AXWebArea", "AXHeading"].contains(role) ? metadata(kAXTitleAttribute) : ""
        return DesktopChatSemantics.metadataLabel(role: role, description: description, title: title)
    }
    private func url(_ element: AXUIElement, attribute name: String) -> String {
        guard let value = attribute(element, name) else { return "" }
        if let url = value as? URL { return url.absoluteString }
        if let text = value as? String { return text.utf8.count <= 2048 ? text : "" }
        return ""
    }
    private func webAreaURL(_ element: AXUIElement) -> String {
        let result = readAttribute(element, kAXURLAttribute)
        lastURLCategory = Self.category(result.error, value: result.value)
        guard let value = result.value else { lastURLKind = "none"; return "" }
        if let url = value as? URL { lastURLKind = "URL"; return url.absoluteString }
        if let text = value as? String { lastURLKind = "string"; return text.utf8.count <= 4096 ? text : "" }
        lastURLKind = "other"; return ""
    }
    private func children(_ element: AXUIElement, tail: Bool = false, completeContent: Bool = false,
                          requiredControls: Bool = false) -> [AXUIElement] {
        guard !exhausted else { return [] }
        // Bounded array reads avoid materializing an entire transcript/tree.
        var count = 0
        AXUIElementSetMessagingTimeout(element, DesktopChatReadPolicy.messageTimeout)
        calls += 1
        guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success else {
            if requiredControls { busyReadFailed = true }
            if completeContent { contentIncomplete = true }; return []
        }
        guard count > 0 else { return [] }
        if completeContent, count > 48 { contentIncomplete = true }
        if requiredControls, count > 48 { busyReadFailed = true }
        var values: CFArray?
        let offset = tail ? max(0, count - 48) : 0
        guard !exhausted else { return [] }
        AXUIElementSetMessagingTimeout(element, DesktopChatReadPolicy.messageTimeout)
        calls += 1
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, offset,
                                             min(count, 48), &values) == .success else {
            if requiredControls { busyReadFailed = true }
            if completeContent { contentIncomplete = true }; return []
        }
        let result = values as? [AXUIElement]
        guard DesktopChatReadPolicy.completeChildRange(reportedCount: count, returnedCount: result?.count),
              let result else {
            if requiredControls { busyReadFailed = true }
            if completeContent { contentIncomplete = true }
            return []
        }
        return result
    }

    private func failure(_ reason: String) -> Result {
        let code = remaining <= 0 ? "node-budget" :
            ProcessInfo.processInfo.systemUptime >= deadline ? "time-budget" : reason
        let message: String
        switch code {
        case "no-visible-window": message = "No visible chat window"
        case "no-chat-scope": message = "The selected chat is unavailable"
        case "time-budget": message = "Reading the chat timed out"
        case "node-budget": message = "The chat layout exceeds the read limit"
        default: message = "The selected chat could not be read"
        }
        // Only stage/counters/timing are retained in this diagnostic. Never
        // include titles, URLs, message identifiers, or attribute values.
        let milliseconds = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
        var extra = stage == "window" && !windowDiagnostic.isEmpty ? ", " + windowDiagnostic : ""
        if stage == "chat scope" {
            extra += ", web:\(webAreasSeen), shell:\(localShells), route:\(verifiedRoutes), marker:\(chatMarkers), URL:\(lastURLCategory)/\(lastURLKind)"
            extra += ", " + scopeDiagnostics.summary
        }
        return Result(snapshot: nil, detail: "\(message) (\(stage), \(calls) reads, \(milliseconds) ms\(extra))")
    }

    private func uniqueWindow(_ app: AXUIElement) -> AXUIElement? {
        guard !exhausted else { return nil }
        AXUIElementSetMessagingTimeout(app, DesktopChatReadPolicy.messageTimeout); calls += 1
        var count = 0
        let countError = AXUIElementGetAttributeValueCount(app, kAXWindowsAttribute as CFString, &count)
        guard countError == .success else {
            windowDiagnostic += ", windows:\(Self.category(countError))"; return nil
        }
        windowDiagnostic += ", windows:\(count)"
        guard count > 0, count <= DesktopChatReadPolicy.maximumWindows, !exhausted else {
            if count > DesktopChatReadPolicy.maximumWindows { windowDiagnostic += ", window-limit" }; return nil
        }
        AXUIElementSetMessagingTimeout(app, DesktopChatReadPolicy.messageTimeout); calls += 1
        var raw: CFArray?
        let copyError = AXUIElementCopyAttributeValues(app, kAXWindowsAttribute as CFString, 0, count, &raw)
        guard copyError == .success, let windows = raw as? [AXUIElement], windows.count == count else {
            windowDiagnostic += ", window-list:\(copyError == .success ? "invalid-type" : Self.category(copyError))"; return nil
        }
        var candidates: [DesktopChatWindowPolicy.Candidate] = []
        for window in windows {
            guard !exhausted else { return nil }; remaining -= 1
            let role = readAttribute(window, kAXRoleAttribute), subrole = readAttribute(window, kAXSubroleAttribute)
            guard role.error == .success, subrole.error == .success,
                  let roleName = role.value as? String, let subroleName = subrole.value as? String else {
                windowDiagnostic += ", window-metadata:unreadable"; return nil
            }
            let standard = roleName == kAXWindowRole && subroleName == kAXStandardWindowSubrole
            if !standard {
                candidates.append(.init(standard: false, minimized: false, hidden: false, modal: false, hasSheet: false)); continue
            }
            let minimized = readAttribute(window, kAXMinimizedAttribute)
            guard minimized.error == .success, let isMinimized = minimized.value as? Bool else {
                windowDiagnostic += ", window-visibility:unreadable"; return nil
            }
            let modalResult = readAttribute(window, "AXModal"), hiddenResult = readAttribute(window, "AXHidden")
            guard modalResult.error == .success, let modal = modalResult.value as? Bool else {
                windowDiagnostic += ", window-modal:unreadable"; return nil
            }
            let hidden: Bool
            if hiddenResult.error == .attributeUnsupported || hiddenResult.error == .noValue { hidden = false }
            else if hiddenResult.error == .success, let value = hiddenResult.value as? Bool { hidden = value }
            else { windowDiagnostic += ", window-hidden:unreadable"; return nil }
            if isMinimized || hidden || modal {
                candidates.append(.init(standard: true, minimized: isMinimized, hidden: hidden, modal: modal, hasSheet: false)); continue
            }
            // Only inspect direct window-child roles to reject an attached
            // dialog/sheet. No window title, document, chat, or text is read.
            let directChildren = children(window, requiredControls: true)
            guard !busyReadFailed, !exhausted else {
                windowDiagnostic += ", window-children:unreadable"; return nil
            }
            var hasSheet = false
            for child in directChildren {
                guard !exhausted else { return nil }; remaining -= 1
                let childRole = readAttribute(child, kAXRoleAttribute)
                guard childRole.error == .success, let name = childRole.value as? String else {
                    windowDiagnostic += ", window-child-role:unreadable"; return nil
                }
                if ["AXSheet", "AXDialog"].contains(name) { hasSheet = true }
            }
            candidates.append(.init(standard: true, minimized: false, hidden: false, modal: false, hasSheet: hasSheet))
        }
        let eligibleCount = candidates.filter(\.eligible).count
        windowDiagnostic += ", eligible:\(eligibleCount)"
        guard let index = DesktopChatWindowPolicy.unique(candidates), !exhausted else { return nil }
        return windows[index]
    }

    static func read(application: NSRunningApplication, provider: String) -> Result {
        let reader = DesktopChatAXReader(), app = AXUIElementCreateApplication(application.processIdentifier)
        reader.selectedBundleURL = application.bundleURL
        AXUIElementSetMessagingTimeout(app, DesktopChatReadPolicy.messageTimeout)
        let focused = reader.readAttribute(app, kAXFocusedWindowAttribute)
        let main = reference(focused) == .present || reference(focused) == .failed ?
            (value: nil as CFTypeRef?, error: AXError.noValue) : reader.readAttribute(app, kAXMainWindowAttribute)
        reader.windowDiagnostic = "focused:\(category(focused.error, value: focused.value))"
        if reference(focused) != .present && reference(focused) != .failed {
            reader.windowDiagnostic += ", main:\(category(main.error, value: main.value))"
        }
        let window: AXUIElement
        switch DesktopChatWindowPolicy.initial(focused: reference(focused), main: reference(main)) {
        case .focused, .main:
            let rawWindow = reference(focused) == .present ? focused.value : main.value
            guard let rawWindow, CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else {
                reader.windowDiagnostic += ", invalid-window-type"; return reader.failure("no-visible-window")
            }
            window = unsafeBitCast(rawWindow, to: AXUIElement.self)
        case .fallback:
            guard let selected = reader.uniqueWindow(app) else { return reader.failure("no-visible-window") }
            window = selected
        case .reject: return reader.failure("no-visible-window")
        }
        guard reader.string(window, kAXRoleAttribute) == kAXWindowRole,
              reader.string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole,
              reader.bool(window, kAXMinimizedAttribute) != true,
              reader.bool(window, "AXModal") != true,
              reader.bool(window, "AXHidden") != true else { return reader.failure("no-visible-window") }
        if reader.children(window).contains(where: {
            ["AXSheet", "AXDialog"].contains(reader.string($0, kAXRoleAttribute))
        }) { return reader.failure("no-visible-window") }
        let windowTitle = reader.string(window, kAXTitleAttribute).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !windowTitle.isEmpty, !["log in", "sign in", "login", "settings", "preferences"].contains(DesktopChatSemantics.normalized(windowTitle)) else { return reader.failure("no-visible-window") }
        reader.stage = "chat scope"
        guard let scope = reader.findChat(window, depth: 0, provider: provider) else { return reader.failure("no-chat-scope") }
        reader.selectedWebArea = scope.webArea
        reader.selectedShells = scope.shells
        reader.selectedScopePath = scope.path
        let chat = scope.element
        let containerTitle = reader.string(chat, kAXTitleAttribute).trimmingCharacters(in: .whitespacesAndNewlines)
        let markedTitle = scope.title == nil ? reader.findTitle(chat, depth: 0) : nil
        let title = markedTitle ?? scope.title ?? (containerTitle.isEmpty ? windowTitle : containerTitle)
        reader.stage = "latest reply"
        let reply: DesktopAssistantReply?
        switch reader.latestAssistant(chat, depth: 0) {
        case .none: reply = nil
        case .unknown: return reader.failure("read-error")
        case let .found(element):
            guard let tree = reader.node(element, depth: 0, assistant: true), !reader.exhausted else { return reader.failure("read-error") }
            reply = DesktopChatSemantics.parse(tree).reply
        }
        reader.stage = "generation controls"
        let observedStop = reader.busyControl(window, depth: 0)
        guard let busy = DesktopChatSemantics.validatedBusy(observedStop: observedStop,
            requiredReadsSucceeded: !reader.busyReadFailed) else { return reader.failure("read-error") }
        guard !reader.exhausted else { return reader.failure("read-error") }
        // A URL exposed by the current chat container distinguishes conversation
        // switches even when two conversations have the same display title.
        let key = scope.key ?? DesktopChatSemantics.conversationIdentity(provider: provider,
            url: reader.url(chat, attribute: kAXURLAttribute), identifier: reader.identifier(chat)) ??
            DesktopChatSemantics.conversationIdentity(provider: provider,
                url: reader.url(window, attribute: kAXDocumentAttribute), identifier: "")
        let identity = "\(application.processIdentifier):\(CFHash(window)):\(key ?? title)"
        guard !reader.exhausted else { return reader.failure("read-error") }
        return Result(snapshot: DesktopChatSnapshot(provider: provider, identity: identity, title: String(title.prefix(48)),
                                   busy: busy, reply: reader.contentIncomplete ? nil : reply, reliableIdentity: key != nil), detail: nil)
    }

    private func findChat(_ element: AXUIElement, depth: Int, provider: String,
                          webKey: String? = nil, webTitle: String? = nil, webArea: AXUIElement? = nil,
                          shells: [AXUIElement] = [], path: [AXUIElement] = []) -> ChatScope? {
        guard scopeDiagnostics.attempt(depth: depth, isAncestor: path.contains(where: { CFEqual(element, $0) })),
              !exhausted else { return nil }; remaining -= 1
        let roleResult = readAttribute(element, kAXRoleAttribute)
        let role = (roleResult.value as? String).map { String($0.prefix(400)) } ?? ""
        scopeDiagnostics.recordRole(role, error: roleResult.error)
        let identifier = identifier(element)
        let label = metadataLabel(element, role: role, diagnosingScope: true)
        var key = webKey, title = webTitle, area = webArea, ancestors = shells
        let currentPath = path + [element]
        if role == "AXWebArea" {
            webAreasSeen += 1
            let exposedURL = webAreaURL(element)
            if let found = DesktopChatSemantics.conversationIdentity(provider: provider, url: exposedURL, identifier: "") {
                verifiedRoutes += 1; key = found; area = element
                title = DesktopChatSemantics.webConversationTitle(string(element, kAXTitleAttribute), provider: provider)
            } else if DesktopChatSemantics.trustedClaudeShell(provider: provider, bundleURL: selectedBundleURL, url: exposedURL) {
                localShells += 1; key = nil; title = nil; area = nil; ancestors.append(element)
            } else { return nil }
        }
        // A validated current-conversation WebArea title is free-form content,
        // not a navigation label (a chat may be named "Login settings").
        guard !DesktopChatSemantics.excluded(role: role, identifier: identifier,
                 label: role == "AXWebArea" ? "" : label), bool(element, "AXEditable") != true else { return nil }
        if DesktopChatSemantics.chatContainer(identifier: identifier, label: label) {
            chatMarkers += 1
            if provider != "claude" || key != nil {
                return ChatScope(element: element, key: key, title: title, webArea: area, shells: ancestors, path: currentPath)
            }
            // A shell marker is not proof of a conversation. It may wrap the
            // remote view, so continue structural metadata discovery only
            // inside the exact selected-app shell path.
            guard !ancestors.isEmpty else { return nil }
        }
        for child in children(element) {
            if let result = findChat(child, depth: depth + 1, provider: provider, webKey: key, webTitle: title,
                                     webArea: area, shells: ancestors, path: currentPath) { return result }
        }
        return nil
    }

    private func latestAssistant(_ element: AXUIElement, depth: Int) -> LatestAssistant {
        guard depth <= 12, !exhausted else { return .unknown }; remaining -= 1
        let role = string(element, kAXRoleAttribute), identifier = identifier(element)
        let label = metadataLabel(element, role: role)
        guard !DesktopChatSemantics.excluded(role: role, identifier: identifier, label: label),
              bool(element, "AXEditable") != true else { return .none }
        if DesktopChatSemantics.messageWrapper(label) {
            var budget = 18
            switch classifyMessage(element, depth: 0, budget: &budget) {
            case .assistant: return .found(element)
            case .user: return .none
            case .unknown: return .unknown
            }
        }
        if DesktopChatSemantics.assistant(identifier: identifier, label: label) { return .found(element) }
        guard ["AXGroup", "AXScrollArea"].contains(role) else { return .none }
        for child in children(element, tail: true).reversed() {
            switch latestAssistant(child, depth: depth + 1) {
            case .none: continue
            case let .found(value): return .found(value)
            case .unknown: return .unknown
            }
        }
        return .none
    }

    private func node(_ element: AXUIElement, depth: Int, assistant: Bool) -> DesktopChatNode? {
        guard depth <= 12, !exhausted else { if assistant { contentIncomplete = true }; return nil }; remaining -= 1
        let role = string(element, kAXRoleAttribute), identifier = identifier(element)
        var label = metadataLabel(element, role: role)
        if assistant, ["AXTable", "AXOutline", "AXBrowser"].contains(role) { contentIncomplete = true; return nil }
        guard !(assistant ? DesktopChatSemantics.assistantContentExcluded(role: role, identifier: identifier, label: label) :
                 DesktopChatSemantics.excluded(role: role, identifier: identifier, label: label)),
              bool(element, "AXEditable") != true else { return nil }
        var assistant = assistant || DesktopChatSemantics.assistant(identifier: identifier, label: label)
        if !assistant, DesktopChatSemantics.messageWrapper(label) {
            var budget = 18
            switch classifyMessage(element, depth: 0, budget: &budget) {
            case .assistant: assistant = true
            case .user: return nil
            case .unknown: contentIncomplete = true; return nil
            }
        }
        if role == "AXHeading", let kind = DesktopChatSemantics.roleHeading(label) { label = kind }
        var result = DesktopChatNode(role: role, identifier: identifier, label: label,
                                     enabled: bool(element, kAXEnabledAttribute) != false)
        if assistant, ["AXButton", "AXImage", "AXToolbar"].contains(role) { return result }
        if role == "AXHeading", DesktopChatSemantics.claudeHeading(label) { return result }
        if assistant, ["AXStaticText", "AXHeading"].contains(role) {
            let value = attribute(element, kAXValueAttribute) as? String
            let title = value == nil || value?.isEmpty == true ? attribute(element, kAXTitleAttribute) as? String : nil
            if value == nil && title == nil { contentIncomplete = true }
            result.text = String((value?.isEmpty == false ? value! : title ?? value ?? "").prefix(400))
            return result
        }
        for child in children(element, tail: depth == 0, completeContent: assistant) {
            if let node = node(child, depth: depth + 1, assistant: assistant) { result.children.append(node) }
        }
        return result
    }

    private func classifyMessage(_ element: AXUIElement, depth: Int, budget: inout Int) -> MessageRole {
        guard depth <= 4, budget > 0, !exhausted else { return .unknown }; remaining -= 1; budget -= 1
        let role = string(element, kAXRoleAttribute), identifier = identifier(element)
        let label = metadataLabel(element, role: role)
        guard !DesktopChatSemantics.excluded(role: role, identifier: identifier, label: label),
              bool(element, "AXEditable") != true else { return .unknown }
        if role == "AXHeading" {
            if DesktopChatSemantics.claudeHeading(label) { return .assistant }
            if DesktopChatSemantics.roleHeading(label) == "You said:" { return .user }
            return .unknown
        }
        guard ["AXGroup", "AXScrollArea"].contains(role) else { return .unknown }
        for child in children(element).prefix(6) {
            let role = classifyMessage(child, depth: depth + 1, budget: &budget)
            if role != .unknown { return role }
        }
        return .unknown
    }

    private func findTitle(_ element: AXUIElement, depth: Int) -> String? {
        guard depth <= 4, titleNodes > 0, !exhausted else { return nil }; remaining -= 1; titleNodes -= 1
        let role = string(element, kAXRoleAttribute), identifier = identifier(element)
        let label = metadataLabel(element, role: role)
        guard !DesktopChatSemantics.excluded(role: role, identifier: identifier, label: label),
              !DesktopChatSemantics.assistant(identifier: identifier, label: label),
              bool(element, "AXEditable") != true else { return nil }
        if ["chat-title", "conversation-title"].contains(DesktopChatSemantics.normalized(identifier)) ||
            ["chat title", "conversation title"].contains(DesktopChatSemantics.normalized(label)) {
            let title = string(element, kAXTitleAttribute)
            let text = title.isEmpty && ["AXStaticText", "AXHeading"].contains(role) ? string(element, kAXValueAttribute) : title
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { return cleaned }
        }
        for child in children(element).prefix(8) { if let title = findTitle(child, depth: depth + 1) { return title } }
        return nil
    }

    private func busyControl(_ element: AXUIElement, depth: Int, inComposer: Bool = false) -> Bool {
        guard depth <= DesktopChatReadPolicy.maximumControlDepth else { busyReadFailed = true; return false }
        guard !exhausted else { return false }; remaining -= 1
        let role = string(element, kAXRoleAttribute), identifier = identifier(element)
        guard !role.isEmpty else { busyReadFailed = true; return false }
        var label = metadataLabel(element, role: role)
        if DesktopChatSemantics.chatContainer(identifier: identifier, label: label) {
            // Skip the actual transcript and all unrelated chat-looking groups.
            // A premature shell marker may wrap the selected remote view; walk
            // only its next proven path child, never its transcript siblings.
            guard let next = DesktopChatSemantics.nextControlPathNode(
                markerIndex: selectedScopePath.firstIndex(where: { CFEqual(element, $0) }),
                pathCount: selectedScopePath.count) else { return false }
            return busyControl(selectedScopePath[next], depth: depth + 1, inComposer: inComposer)
        }
        if role == "AXWebArea" {
            let selectedRemote = selectedWebArea.map { CFEqual(element, $0) } ?? false
            guard selectedRemote || selectedShells.contains(where: { CFEqual(element, $0) }) else { return false }
            label = ""
        }
        // Composer containers can contain Stop; editable descendants themselves
        // are never inspected. No value/text attribute is requested here.
        let composerContainer = ["AXGroup", "AXScrollArea"].contains(role) &&
            DesktopChatSemantics.normalized(identifier + " " + label).contains("composer")
        guard composerContainer || !DesktopChatSemantics.excluded(role: role, identifier: identifier, label: label),
              !DesktopChatSemantics.assistant(identifier: identifier, label: label),
              bool(element, "AXEditable") != true else { return false }
        if role == "AXButton" {
            if label.isEmpty { label = string(element, kAXTitleAttribute) }
            if DesktopChatSemantics.stop(role: role, label: label, enabled: bool(element, kAXEnabledAttribute) != false,
                                         inComposer: inComposer) { return true }
            return false
        }
        if ["AXStaticText", "AXHeading", "AXImage", "AXLink", "AXCheckBox", "AXRadioButton", "AXSlider",
            "AXProgressIndicator", "AXSeparator"].contains(role) { return false }
        for child in children(element, requiredControls: true) {
            if busyControl(child, depth: depth + 1, inComposer: inComposer || composerContainer) { return true }
        }
        return false
    }
}
