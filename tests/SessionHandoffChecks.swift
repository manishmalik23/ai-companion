import Foundation
import Darwin

@main
struct SessionHandoffChecks {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pip-handoff-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let encoder = JSONEncoder()
        var checks = 0, sequence = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message); checks += 1
        }
        func rejects(_ operation: () throws -> Void) {
            do { try operation(); preconditionFailure("An unsafe handoff was accepted") } catch { checks += 1 }
        }
        func request(source: String = "codex", capability: Bool? = true, notice: Bool = false,
                     question: Bool = false, detail: String = "{}", created: Double? = nil,
                     expires: Double? = nil) -> PermissionRequest {
            sequence += 1
            let now = Date().timeIntervalSince1970
            return PermissionRequest(schemaVersion: 1, id: String(format: "%032x", sequence), source: source,
                sourceLabel: source == "codex" ? "Codex" : "Claude Code",
                sessionId: "38f4f440-e050-460f-a9d0-84274d9e9cce", toolName: question ? "AskUserQuestion" : "Bash",
                cwd: root.path, reason: "Test handoff", detailText: detail, isDemo: false,
                createdAt: created ?? now - 1, expiresAt: expires ?? now + 120,
                canRespond: !notice, kind: question ? "question" : (notice ? "notice" : "permission"),
                questions: question ? [UserQuestion(question: "Continue?", header: "Next", options: [
                    QuestionOption(label: "Yes", description: nil), QuestionOption(label: "No", description: nil)], multiSelect: false)] : nil,
                sessionHost: source == "codex" ? "codex-desktop" : "claude-vscode", canDefer: capability)
        }
        func snapshot(_ request: PermissionRequest) throws -> RequestSnapshot {
            RequestSnapshot(request: request, bytes: try encoder.encode(request))
        }
        func fixture() throws -> RuntimeStore {
            try RuntimeStore(root: root.appendingPathComponent(UUID().uuidString))
        }
        func write(_ bytes: Data, to url: URL) throws {
            try bytes.write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        func publish(_ snapshot: RequestSnapshot, in store: RuntimeStore) throws {
            try write(snapshot.bytes, to: store.root.appendingPathComponent("requests/" + snapshot.request.id + ".json"))
        }
        func decisionURL(_ snapshot: RequestSnapshot, in store: RuntimeStore) -> URL {
            store.root.appendingPathComponent("decisions/" + snapshot.request.id + ".json")
        }
        func pending(_ store: RuntimeStore) throws -> [RequestSnapshot] { try store.poll(now: Date().timeIntervalSince1970).0 }

        for source in ["claude", "codex"] {
            let store = try fixture(), clicked = try snapshot(request(source: source))
            let other = try snapshot(request(source: source))
            try publish(clicked, in: store); try publish(other, in: store)
            var state = SessionHandoffState()
            let token = state.begin(clicked)!
            check(state.isOpening && state.begin(other) == nil, "Only one navigation can own an active handoff")
            check(try state.finish(token, opened: true, current: clicked, now: Date().timeIntervalSince1970) { try store.handoff($0) },
                  "A verified open hands off exactly its captured request")
            let data = try Data(contentsOf: decisionURL(clicked, in: store))
            let response = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            check(Set(response.keys) == Set(["id", "decision", "decidedAt"]) &&
                  response["decision"] as? String == "defer" && response["id"] as? String == clicked.request.id,
                  "Permission handoff emits only a correlated defer, without any grant, denial, or answers")
            var info = stat()
            check(lstat(decisionURL(clicked, in: store).path, &info) == 0 && info.st_mode & 0o077 == 0,
                  "Handoff responses are owner-only")
            check(try pending(store).map(\.request.id) == [other.request.id],
                  "Polling never resurrects the handed-off card and keeps another queued request visible")
            rejects { try store.handoff(clicked) }
            check(try Data(contentsOf: decisionURL(clicked, in: store)) == data, "Duplicate handoff never overwrites a response")
            try fm.removeItem(at: store.root.appendingPathComponent("requests/" + clicked.request.id + ".json"))
            try fm.removeItem(at: decisionURL(clicked, in: store))
            check(try pending(store).map(\.request.id) == [other.request.id], "Bridge cleanup does not revive a retired card")
            try store.handoff(other)
            check(try pending(store).isEmpty, "An empty queue can collapse to the character after handoff")
        }

        for capability in [nil, false] as [Bool?] {
            let store = try fixture(), old = try snapshot(request(capability: capability))
            try publish(old, in: store)
            rejects { try store.handoff(old) }
            check(try !fm.fileExists(atPath: decisionURL(old, in: store).path) && pending(store).count == 1,
                  "Old running hooks without capability keep an answerable card and receive no unsupported defer")
            try write(JSONSerialization.data(withJSONObject: ["id": old.request.id, "decision": "defer",
                "decidedAt": Date().timeIntervalSince1970]), to: decisionURL(old, in: store))
            check(try pending(store).count == 1, "Unsupported external defer cannot hide an old hook's card")
        }

        let malformedStore = try fixture(), malformed = try snapshot(request())
        try publish(malformed, in: malformedStore)
        let now = Date().timeIntervalSince1970
        let valid: [String: Any] = ["id": malformed.request.id, "decision": "defer", "decidedAt": now]
        let invalidResponses: [[String: Any]] = [["answers": NSNull()], ["answers": [:]], ["extra": true],
            ["id": String(repeating: "f", count: 32)], ["decidedAt": true], ["decidedAt": now + 10],
            ["decidedAt": malformed.request.createdAt - 1]]
        for change in invalidResponses {
            var response = valid; response.merge(change) { _, new in new }
            try write(JSONSerialization.data(withJSONObject: response), to: decisionURL(malformed, in: malformedStore))
            check(try pending(malformedStore).count == 1, "A response the hook rejects cannot hide a live card")
        }

        for allow in [true, false] {
            let store = try fixture(), decided = try snapshot(request())
            try publish(decided, in: store); try store.decide(decided, allow: allow)
            let original = try Data(contentsOf: decisionURL(decided, in: store))
            rejects { try store.handoff(decided) }
            check(try Data(contentsOf: decisionURL(decided, in: store)) == original,
                  "An existing approval or denial always wins a racing handoff")
        }
        for change in ["removed", "changed", "expired", "future"] {
            let store = try fixture()
            var value = request()
            if change == "expired" { value = request(expires: now - 1) }
            if change == "future" { value = request(created: now + 30) }
            let old = try snapshot(value)
            try publish(old, in: store)
            if change == "removed" { try fm.removeItem(at: store.root.appendingPathComponent("requests/" + value.id + ".json")) }
            if change == "changed" {
                var changed = value; changed.sessionName = "Changed while navigating"
                try publish(snapshot(changed), in: store)
            }
            rejects { try store.handoff(old) }
            check(!fm.fileExists(atPath: decisionURL(old, in: store).path), "Stale or completed requests never receive a handoff")
        }
        let lockedStore = try fixture(), locked = try snapshot(request())
        try publish(locked, in: lockedStore)
        let fd = open(lockedStore.root.appendingPathComponent("bridge.lock").path, O_CREAT | O_RDWR, mode_t(0o600))
        check(fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0, "Simulate a concurrent source lifecycle transaction")
        let start = Date().timeIntervalSince1970
        rejects { try lockedStore.handoff(locked) }
        check(Date().timeIntervalSince1970 - start < 0.5 && !fm.fileExists(atPath: decisionURL(locked, in: lockedStore).path),
              "A busy source transaction fails without blocking the UI or writing a decision")
        try fm.removeItem(at: lockedStore.root.appendingPathComponent("requests/" + locked.request.id + ".json"))
        flock(fd, LOCK_UN); close(fd)
        rejects { try lockedStore.handoff(locked) }

        let questionStore = try fixture(), question = try snapshot(request(source: "claude", capability: nil, question: true))
        try publish(question, in: questionStore); try questionStore.handoff(question)
        let questionResponse = try JSONSerialization.jsonObject(with: Data(contentsOf: decisionURL(question, in: questionStore))) as! [String: Any]
        check(try questionResponse["decision"] as? String == "defer" && questionResponse["answers"] == nil && pending(questionStore).isEmpty,
              "Claude questions reuse the existing exact-snapshot defer without inventing answers")
        let noticeStore = try fixture(), notice = try snapshot(request(capability: nil, notice: true))
        try publish(notice, in: noticeStore); try noticeStore.handoff(notice)
        check(try pending(noticeStore).isEmpty && !fm.fileExists(atPath: decisionURL(notice, in: noticeStore).path),
              "Codex question notices are dismissed without any response or structured answer")
        let changedNotice = try snapshot(request(capability: nil, notice: true))
        try publish(changedNotice, in: noticeStore)
        var updatedNotice = changedNotice.request; updatedNotice.sessionName = "New notice"
        try publish(snapshot(updatedNotice), in: noticeStore)
        rejects { try noticeStore.handoff(changedNotice) }
        check(try pending(noticeStore).count == 1, "A changed notice is never discarded")

        var state = SessionHandoffState(), transfers: [String] = []
        let first = try snapshot(request()), other = try snapshot(request())
        let navigationNow = Date().timeIntervalSince1970
        let failed = state.begin(first)!
        check(try !state.finish(failed, opened: false, current: first, now: navigationNow) { transfers.append($0.request.id) } && transfers.isEmpty && !state.isOpening,
              "Failed navigation writes nothing and permits retry while retaining the current card")
        let changedToken = state.begin(first)!
        var changed = first.request; changed.sessionName = "Updated"
        check(try !state.finish(changedToken, opened: true, current: snapshot(changed), now: navigationNow) { transfers.append($0.request.id) },
              "Navigation success cannot transfer a changed snapshot")
        let oldToken = state.begin(first)!
        state.cancelIfChanged(other)
        let newToken = state.begin(other)!
        check(try !state.finish(oldToken, opened: true, current: first, now: navigationNow) { transfers.append($0.request.id) } && state.isCurrent(newToken),
              "A late completion cannot retire another request or cancel its newer navigation")
        check(try state.finish(newToken, opened: true, current: other, now: navigationNow) { transfers.append($0.request.id) } && transfers == [other.request.id],
              "Only the matching successful navigation transfers its captured request")
        let retry = state.begin(first)!
        rejects { _ = try state.finish(retry, opened: true, current: first, now: navigationNow) { _ in throw CompanionError.message("Mailbox unavailable") } }
        check(!state.isOpening && state.begin(first) != nil, "A failed mailbox handoff retains a retryable card")
        state.cancelIfChanged(nil)
        check(!state.isOpening, "Resolving a card cancels its pending handoff")
        print("Passed \(checks) native session handoff, freshness, concurrency, and queue checks. No navigation or provider calls.")
    }
}
