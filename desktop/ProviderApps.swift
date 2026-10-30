import AppKit
import Foundation

enum ProviderApps {
    static func label(_ provider: String) -> String { provider == "claude" ? "Claude" : "ChatGPT" }
    static func identifiers(_ provider: String) -> [String] {
        switch provider {
        case "claude": return ["com.anthropic.claudefordesktop"]
        case "codex": return ["com.openai.chat", "com.openai.codex"]
        default: return []
        }
    }

    static func applicationURL(provider: String) -> URL? {
        let identifiers = identifiers(provider)
        guard !identifiers.isEmpty else { return nil }
        let names = provider == "claude" ? ["Claude.app"] : ["ChatGPT.app"]
        let roots = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var candidates = roots.flatMap { root in names.map { root.appendingPathComponent($0) } }
        for identifier in identifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) { candidates.append(url) }
        }
        return preferredApplicationURL(provider: provider, candidates: candidates)
    }

    static func preferredApplicationURL(provider: String, candidates: [URL]) -> URL? {
        for identifier in identifiers(provider) {
            for url in candidates {
                guard let bundle = Bundle(url: url), bundle.bundleIdentifier == identifier else { continue }
                // Some ChatGPT desktop builds use this ID. A separate Codex app
                // must not be presented as ChatGPT merely because its ID matches.
                if provider == "codex", identifier == "com.openai.codex" {
                    let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
                        bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    guard name == "ChatGPT" else { continue }
                }
                return url
            }
        }
        return nil
    }
}

/// Launching opens the application's existing interface; it never submits a message.
final class ProviderAppLauncher {
    typealias Resolver = (String) -> URL?
    typealias Opener = (URL, @escaping (Bool) -> Void) -> Void
    private let resolver: Resolver
    private let opener: Opener
    private var latestRequest = UUID()

    init(resolver: @escaping Resolver = ProviderApps.applicationURL, opener: @escaping Opener = { url, completed in
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
            completed(application != nil && error == nil)
        }
    }) {
        self.resolver = resolver; self.opener = opener
    }

    func open(provider: String, opened: @escaping (String) -> Void, fallback: @escaping (String) -> Void) {
        guard !ProviderApps.identifiers(provider).isEmpty else { return }
        let request = UUID(); latestRequest = request
        guard let url = resolver(provider) else { fallback(provider); return }
        opener(url) { [weak self] succeeded in
            DispatchQueue.main.async {
                guard self?.latestRequest == request else { return }
                if succeeded { opened(provider) } else { fallback(provider) }
            }
        }
    }
}

struct CompanionChatActivity {
    enum Phase: Equatable { case connected, thinking, completed, replyReady, stopped, failed, reset }
    enum Origin: Equatable { case pip, desktop }
    let provider: String
    let runID: UUID
    let title: String
    let phase: Phase
    let reply: String?
    let origin: Origin

    init(provider: String, runID: UUID, title: String, phase: Phase, reply: String?, origin: Origin = .pip) {
        self.provider = provider; self.runID = runID; self.title = title
        self.phase = phase; self.reply = reply; self.origin = origin
    }

    static func conversationTitle(_ message: String) -> String {
        let firstLine = message.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? "New conversation"
        let cleaned = firstLine.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(cleaned.prefix(48))
    }

    static func shortReply(_ response: String) -> String? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 240, !trimmed.contains(where: { $0.isNewline }) else { return nil }
        return trimmed
    }
}

/// Follow the latest submitted main-thread turn. Hook delivery is not a window-selection API.
struct CodexHookActivityTracker {
    private var session: String?
    private var turn: String?
    private var run = UUID()
    private var beganAt: Double = 0
    private var completed = false
    private(set) var isAgentTask = false
    private(set) var lastEventAt: Double = 0

    mutating func receive(_ event: CodexHookEvent, now: Double) -> CompanionChatActivity? {
        guard event.isValid(now: now) else { return nil }
        let phase: CompanionChatActivity.Phase
        if event.phase == "thinking" {
            guard event.createdAt >= beganAt, let nextTurn = event.turn else { return nil }
            if turn == nextTurn && session == event.session { return nil }
            session = event.session; turn = nextTurn; run = UUID(); beganAt = event.createdAt; completed = false
            isAgentTask = false
            phase = .thinking
        } else {
            guard session == event.session, event.createdAt >= beganAt,
                  (event.turn == turn || (event.phase == "reset" && event.turn == nil)), !completed else { return nil }
            if event.phase == "working" {
                guard !isAgentTask else { return nil }
                isAgentTask = true
                phase = .reset
            } else {
                completed = true
                phase = event.phase == "completed" && !isAgentTask ? .completed : .reset
            }
        }
        lastEventAt = event.createdAt
        return CompanionChatActivity(provider: "codex", runID: run, title: "Codex chat", phase: phase,
                                     reply: phase == .completed ? event.reply : nil, origin: .desktop)
    }

    mutating func expire(now: Double) -> CompanionChatActivity? {
        guard session != nil, !completed, now - beganAt > 1800 else { return nil }
        completed = true
        return CompanionChatActivity(provider: "codex", runID: run, title: "Codex chat", phase: .reset,
                                     reply: nil, origin: .desktop)
    }
}

/// Pure display state keeps late completion/cancellation events from replacing a newer run.
struct ConversationBubbleState {
    struct Display {
        let provider: String
        let title: String
        let detail: String
        let thinking: Bool
    }
    private(set) var display: Display?
    private(set) var expiresAt: Double?
    private var currentRun: UUID?
    private var currentOrigin: CompanionChatActivity.Origin?
    private var currentProvider: String?
    private var deferredDesktop: CompanionChatActivity?

    mutating func receive(_ activity: CompanionChatActivity, now: Double) {
        if case .reset = activity.phase {
            // Resetting a conversation or disconnecting its source must not
            // resurrect desktop activity that was hidden behind a Pip run.
            if activity.origin == .pip ||
                (deferredDesktop?.provider == activity.provider && deferredDesktop?.runID == activity.runID) {
                deferredDesktop = nil
            }
            if currentProvider == activity.provider && currentOrigin == activity.origin &&
                (activity.origin == .pip || currentRun == activity.runID) {
                display = nil; expiresAt = nil; currentRun = nil; currentOrigin = nil; currentProvider = nil
            }
            return
        }
        if activity.origin == .desktop && currentOrigin == .pip && display?.thinking == true {
            switch activity.phase {
            case .thinking:
                deferredDesktop = activity
            case .connected:
                // A newly selected idle chat supersedes the previously busy one.
                deferredDesktop = nil
            case .completed, .replyReady, .stopped, .failed:
                if deferredDesktop?.runID == activity.runID && deferredDesktop?.provider == activity.provider {
                    deferredDesktop = nil
                }
            case .reset: break
            }
            return
        }
        if case .connected = activity.phase {
            if activity.origin == .desktop { deferredDesktop = nil }
            currentRun = activity.runID; currentOrigin = activity.origin; currentProvider = activity.provider
            display = Display(provider: activity.provider, title: String(activity.title.prefix(48)), detail: "", thinking: false)
            expiresAt = now + 2
            return
        }
        if case .thinking = activity.phase {
            if activity.origin == .desktop {
                deferredDesktop = nil
            } else if currentOrigin == .desktop, let display, display.thinking, let currentRun {
                // The desktop may already be busy when Pip takes priority. Its
                // observer need not emit another event until that action ends.
                deferredDesktop = CompanionChatActivity(provider: display.provider, runID: currentRun,
                    title: display.title, phase: .thinking, reply: nil, origin: .desktop)
            }
            currentRun = activity.runID; currentOrigin = activity.origin; currentProvider = activity.provider; expiresAt = nil
            display = Display(provider: activity.provider, title: String(activity.title.prefix(48)),
                              detail: ProviderApps.label(activity.provider) + " · Thinking…", thinking: true)
            return
        }
        guard currentRun == activity.runID, currentOrigin == activity.origin,
              currentProvider == activity.provider else { return }
        switch activity.phase {
        case .completed, .replyReady:
            if let reply = activity.reply.flatMap(CompanionChatActivity.shortReply) {
                display = Display(provider: activity.provider, title: String(activity.title.prefix(48)), detail: reply, thinking: false)
                expiresAt = now + 6
            } else {
                display = nil; expiresAt = nil
            }
        case .stopped, .failed:
            display = Display(provider: activity.provider, title: String(activity.title.prefix(48)),
                              detail: activity.phase == .stopped ? "Stopped" : "Could not complete the reply", thinking: false)
            expiresAt = now + 3
        case .connected, .thinking, .reset: break
        }
        if activity.origin == .pip, let pending = deferredDesktop {
            deferredDesktop = nil
            // Only a currently observed busy phase can resume. A reply that
            // completed while hidden never becomes a delayed history message.
            receive(pending, now: now)
        }
    }

    mutating func opened(provider: String, now: Double) {
        deferredDesktop = nil
        guard display?.thinking != true else { return }
        currentRun = nil
        currentOrigin = nil; currentProvider = nil
        display = Display(provider: provider, title: ProviderApps.label(provider), detail: "Opened " + ProviderApps.label(provider), thinking: false)
        expiresAt = now + 2
    }

    mutating func expire(now: Double) {
        if let expiresAt, now >= expiresAt { display = nil; self.expiresAt = nil }
    }

    mutating func disconnectDesktop() {
        deferredDesktop = nil
        guard currentOrigin == .desktop else { return }
        display = nil; expiresAt = nil; currentRun = nil; currentOrigin = nil; currentProvider = nil
    }
}

enum ChatInputPolicy {
    static func sendsNewline(modifiers: NSEvent.ModifierFlags, hasMarkedText: Bool) -> Bool {
        guard !hasMarkedText, !modifiers.contains(.shift) else { return false }
        return modifiers.contains(.command) || modifiers.intersection([.option, .control]).isEmpty
    }
}
