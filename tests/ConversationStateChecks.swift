import Foundation

/// Pure state checks; no app launch, Accessibility reads, messages, or user files.
@main
struct ConversationStateChecks {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        let pipRun = UUID(), desktopRun = UUID(), newerDesktopRun = UUID()
        check(CompanionChatActivity.shortReply("Hello\nHow are you?") == nil, "Multi-line replies stay in the chat window")
        check(CompanionChatActivity.shortReply("Hello\rWorld") == nil, "Carriage-return replies stay in chat")
        check(CompanionChatActivity.shortReply("Hello\u{2028}World") == nil, "Unicode line separators are multi-line")
        check(CompanionChatActivity.shortReply(" Hello!\n") == "Hello!", "A trailing terminator does not add a reply line")
        func activity(_ origin: CompanionChatActivity.Origin, _ phase: CompanionChatActivity.Phase,
                      run: UUID, provider: String = "claude", title: String = "Current chat",
                      reply: String? = nil) -> CompanionChatActivity {
            CompanionChatActivity(provider: provider, runID: run, title: title,
                                  phase: phase, reply: reply, origin: origin)
        }
        func overlapping() -> ConversationBubbleState {
            var state = ConversationBubbleState()
            state.receive(activity(.pip, .thinking, run: pipRun, title: "Pip question"), now: 1)
            state.receive(activity(.desktop, .connected, run: desktopRun, title: "Desktop question"), now: 2)
            state.receive(activity(.desktop, .thinking, run: desktopRun, title: "Desktop question"), now: 2)
            return state
        }

        // A desktop action can start behind Pip and remain busy when Pip finishes.
        var state = overlapping()
        check(state.display?.title == "Pip question", "Pip owns the bubble while its reply is running")
        check(state.display?.thinking == true, "Pip thinking remains visible")
        state.receive(activity(.pip, .completed, run: pipRun, reply: "Pip reply"), now: 3)
        check(state.display?.title == "Desktop question", "Still-active desktop thinking resumes")
        check(state.display?.thinking == true, "Resumed desktop action stays busy")
        check(state.expiresAt == nil, "Active desktop thinking never gets reply expiry")
        state.receive(activity(.desktop, .completed, run: desktopRun, reply: "Desktop reply"), now: 4)
        check(state.display?.detail == "Desktop reply", "Resumed desktop owner can complete")
        check(state.display?.thinking == false, "Completed desktop reply ends thinking")
        check(state.expiresAt == 10, "Desktop short reply expires normally")
        state.expire(now: 10)
        check(state.display == nil, "Desktop short reply returns to Pip alone")

        // The desktop may already be busy when Pip starts, with no new event
        // until the desktop action ends. Preserve that observed owner too.
        state = ConversationBubbleState()
        state.receive(activity(.desktop, .thinking, run: desktopRun, title: "Desktop started first"), now: 1)
        state.receive(activity(.pip, .thinking, run: pipRun, title: "Pip question"), now: 2)
        check(state.display?.title == "Pip question", "Pip takes priority over existing desktop thinking")
        state.receive(activity(.pip, .completed, run: pipRun, reply: "Pip reply"), now: 3)
        check(state.display?.title == "Desktop started first", "Existing desktop thinking resumes without observer replay")
        check(state.display?.thinking == true, "Existing desktop owner is still active")
        state.receive(activity(.desktop, .completed, run: desktopRun, reply: "Desktop reply"), now: 4)
        check(state.display?.detail == "Desktop reply", "Preserved desktop owner can complete normally")

        state = ConversationBubbleState()
        state.receive(activity(.desktop, .thinking, run: desktopRun, title: "Desktop started first"), now: 1)
        state.receive(activity(.pip, .thinking, run: pipRun, title: "Pip question"), now: 2)
        state.receive(activity(.desktop, .completed, run: desktopRun, reply: "Hidden desktop reply"), now: 2.5)
        state.receive(activity(.pip, .completed, run: pipRun, reply: "Pip reply"), now: 3)
        check(state.display?.detail == "Pip reply", "Already busy desktop completion clears its deferred owner")
        check(state.display?.thinking == false, "Hidden completion never resumes old desktop thinking")

        // Every terminal Pip outcome releases its priority, including a long reply.
        for phase in [CompanionChatActivity.Phase.completed, .replyReady, .stopped, .failed] {
            state = overlapping()
            state.receive(activity(.pip, phase, run: pipRun, reply: String(repeating: "x", count: 241)), now: 3)
            check(state.display?.title == "Desktop question", "Pip terminal phase releases desktop priority")
            check(state.display?.thinking == true, "Only the active desktop busy state resumes")
        }

        // Finishing entirely behind Pip does not replay a hidden response as new.
        for phase in [CompanionChatActivity.Phase.completed, .replyReady, .stopped, .failed] {
            state = overlapping()
            state.receive(activity(.desktop, phase, run: desktopRun, reply: "Hidden desktop reply"), now: 2.5)
            check(state.display?.title == "Pip question", "Hidden desktop completion cannot replace Pip")
            state.receive(activity(.pip, .completed, run: pipRun, reply: "Pip reply"), now: 3)
            check(state.display?.detail == "Pip reply", "No hidden desktop history is resurrected")
        }

        state = overlapping()
        state.disconnectDesktop()
        check(state.display?.title == "Pip question", "Disconnect leaves the active Pip run intact")
        state.receive(activity(.pip, .completed, run: pipRun, reply: "Pip reply"), now: 3)
        check(state.display?.detail == "Pip reply", "Disconnect clears deferred desktop thinking")

        state = overlapping()
        state.receive(activity(.desktop, .reset, run: desktopRun), now: 2.5)
        check(state.display?.title == "Pip question", "Desktop reset cannot reset a Pip run")
        state.receive(activity(.pip, .completed, run: pipRun, reply: "Pip reply"), now: 3)
        check(state.display?.detail == "Pip reply", "Matching desktop reset clears deferred activity")

        state = overlapping()
        state.receive(activity(.pip, .reset, run: UUID()), now: 3)
        check(state.display == nil, "Pip conversation reset clears its display")
        state.receive(activity(.pip, .completed, run: pipRun, reply: "Late Pip reply"), now: 4)
        check(state.display == nil, "Reset does not resurrect hidden desktop activity or late Pip replies")

        // An idle chat selected during overlap supersedes the old busy chat.
        state = overlapping()
        state.receive(activity(.desktop, .connected, run: newerDesktopRun, title: "Different idle chat"), now: 2.5)
        state.receive(activity(.pip, .completed, run: pipRun, reply: "Pip reply"), now: 3)
        check(state.display?.detail == "Pip reply", "Selecting an idle desktop chat clears old deferred thinking")

        // Late events cannot clear the newer observed desktop run just by provider.
        for phase in [CompanionChatActivity.Phase.completed, .stopped, .failed, .reset] {
            state = overlapping()
            state.receive(activity(.desktop, .thinking, run: newerDesktopRun, title: "New desktop action"), now: 2.5)
            state.receive(activity(.desktop, phase, run: desktopRun, reply: "Old desktop reply"), now: 2.7)
            state.receive(activity(.pip, .completed, run: pipRun, reply: "Pip reply"), now: 3)
            check(state.display?.title == "New desktop action", "Old desktop event cannot clear the newer run")
            check(state.display?.thinking == true, "Newer desktop run remains active")
        }

        state = overlapping()
        state.receive(activity(.desktop, .completed, run: desktopRun, provider: "codex", reply: "Other provider"), now: 2.5)
        state.receive(activity(.pip, .completed, run: pipRun, reply: "Pip reply"), now: 3)
        check(state.display?.title == "Desktop question", "Wrong provider cannot clear deferred owner")
        state.receive(activity(.desktop, .reset, run: UUID()), now: 3.2)
        check(state.display?.thinking == true, "Provider-only reset cannot clear a different desktop run")
        state.receive(activity(.desktop, .completed, run: desktopRun, provider: "codex", reply: "Other provider"), now: 3.3)
        check(state.display?.thinking == true, "Wrong provider cannot complete the visible desktop owner")
        state.receive(activity(.desktop, .reset, run: desktopRun), now: 3.4)
        check(state.display == nil, "Matching desktop reset clears the visible owner")

        state = overlapping()
        state.receive(activity(.pip, .completed, run: UUID(), reply: "Older Pip reply"), now: 2.5)
        check(state.display?.title == "Pip question", "Late Pip completion never releases current priority")
        state.receive(activity(.pip, .completed, run: pipRun, reply: "Pip reply"), now: 3)
        check(state.display?.title == "Desktop question", "Current Pip completion releases priority")

        state = overlapping()
        state.opened(provider: "codex", now: 2.5)
        check(state.display?.title == "Pip question", "App opening cannot interrupt active Pip display")
        state.receive(activity(.pip, .completed, run: pipRun, reply: "Pip reply"), now: 3)
        check(state.display?.detail == "Pip reply", "Opening another app clears old deferred activity")

        print("Passed \(checks) conversation state checks")
    }
}
