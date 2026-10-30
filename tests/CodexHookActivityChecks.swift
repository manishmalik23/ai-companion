import Foundation

@main
struct CodexHookActivityChecks {
    static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool) { precondition(value()); checks += 1 }
        func event(_ phase: String, turn: String? = String(repeating: "b", count: 64),
                   session: String = String(repeating: "a", count: 64), at: Double = 100,
                   reply: String? = nil) -> CodexHookEvent {
            CodexHookEvent(id: String(repeating: "c", count: 32), session: session, turn: turn,
                           phase: phase, reply: reply, createdAt: at)
        }
        var tracker = CodexHookActivityTracker()
        check(tracker.receive(event("completed", reply: "old"), now: 100) == nil)
        let first = tracker.receive(event("thinking"), now: 100)!
        check(first.phase == .thinking && first.title == "Codex chat")
        check(tracker.receive(event("thinking"), now: 101) == nil)
        check(tracker.receive(event("completed", turn: String(repeating: "d", count: 64)), now: 101) == nil)
        check(tracker.receive(event("completed", session: String(repeating: "d", count: 64)), now: 101) == nil)
        let completion = tracker.receive(event("completed", at: 101, reply: "hello"), now: 101)!
        check(completion.runID == first.runID && completion.reply == "hello")
        check(tracker.receive(event("completed", at: 102, reply: "duplicate"), now: 102) == nil)
        let second = tracker.receive(event("thinking", turn: String(repeating: "e", count: 64), at: 103), now: 103)!
        check(second.runID != first.runID)
        check(tracker.receive(event("completed", at: 104, reply: "old"), now: 104) == nil)
        check(tracker.receive(event("reset", turn: nil, at: 105), now: 105)?.phase == .reset)
        check(tracker.receive(event("thinking", at: 90), now: 105) == nil)
        check(!event("completed", reply: String(repeating: "x", count: 241)).isValid(now: 100))
        check(!event("thinking", at: 100).isValid(now: 111))
        _ = tracker.receive(event("thinking", turn: String(repeating: "f", count: 64), at: 106), now: 106)
        check(tracker.expire(now: 1907)?.phase == .reset)
        check(tracker.expire(now: 1908) == nil)

        tracker = CodexHookActivityTracker()
        let chat = tracker.receive(event("thinking"), now: 100)!
        let working = tracker.receive(event("working", at: 101), now: 101)!
        check(working.phase == .reset && working.runID == chat.runID)
        check(tracker.isAgentTask)
        check(tracker.receive(event("working", at: 102), now: 102) == nil)
        let taskEnd = tracker.receive(event("completed", at: 103, reply: "Task done"), now: 103)!
        check(taskEnd.phase == .reset && taskEnd.reply == nil)
        let nextChat = tracker.receive(event("thinking", turn: String(repeating: "e", count: 64), at: 104), now: 104)!
        check(!tracker.isAgentTask && nextChat.phase == .thinking)
        check(tracker.receive(event("working", at: 105), now: 105) == nil)
        check(tracker.receive(event("completed", turn: String(repeating: "e", count: 64), at: 106, reply: "Hi"), now: 106)?.reply == "Hi")
        var display = ConversationBubbleState()
        display.receive(chat, now: 100)
        check(display.display?.thinking == true)
        display.receive(working, now: 101)
        check(display.display == nil)
        display.receive(taskEnd, now: 103)
        check(display.display == nil)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RuntimeStore(root: root)
        store.codexActivityEnabled = true
        let now = Date().timeIntervalSince1970
        let directory = root.appendingPathComponent("activities")
        func write(_ item: CodexHookEvent) throws {
            let path = directory.appendingPathComponent(item.id + ".json")
            try JSONEncoder().encode(item).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
        try write(event("completed", at: now - 1, reply: "before launch"))
        let oldEvents = try store.consumeCodexActivities(now: now)
        check(oldEvents.isEmpty)
        try write(event("thinking", at: now + 0.001))
        let events = try store.consumeCodexActivities(now: now + 0.01)
        check(events.count == 1)
        let consumedAgain = try store.consumeCodexActivities(now: now + 0.02)
        check(consumedAgain.isEmpty)
        store.codexActivityEnabled = false
        try write(event("thinking", at: now + 0.03))
        let disabledEvents = try store.consumeCodexActivities(now: now + 0.04)
        check(disabledEvents.isEmpty)
        print("Passed \(checks) Codex hook activity checks")
    }
}
