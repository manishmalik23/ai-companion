// Pure fixture checks: no apps, Accessibility permission prompts, AX queries,
// messages, or runtime files are involved.
import Foundation
import ApplicationServices

@main
struct DesktopChatObserverChecks {
    static func main() {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); checks += 1
        }
        func reply(_ text: String, id: String? = "assistant-message-1") -> DesktopAssistantReply {
            DesktopAssistantReply(id: id, text: text)
        }
        func snapshot(_ identity: String = "chat-A", busy: Bool = false,
                      response: DesktopAssistantReply? = nil, title: String = "Current chat",
                      provider: String = "claude", reliableIdentity: Bool = true) -> DesktopChatSnapshot {
            DesktopChatSnapshot(provider: provider, identity: identity, title: title, busy: busy,
                                reply: response, reliableIdentity: reliableIdentity)
        }
        func staticText(_ text: String) -> DesktopChatNode { DesktopChatNode(role: "AXStaticText", text: text) }
        func assistant(_ text: String, id: String = "assistant-message-1") -> DesktopChatNode {
            DesktopChatNode(role: "AXGroup", identifier: id, label: "Assistant response", children: [staticText(text)])
        }

        let forbidden = [
            DesktopChatNode(role: "AXTextArea", text: "unsent private draft", editable: true),
            DesktopChatNode(role: "AXGroup", identifier: "user-message-1", children: [staticText("private user message")]),
            DesktopChatNode(role: "AXGroup", label: "Conversation history", children: [assistant("old sidebar reply")]),
            DesktopChatNode(role: "AXGroup", identifier: "sidebar", children: [assistant("private historical chat")]),
            DesktopChatNode(role: "AXDialog", label: "Sign in", children: [assistant("authentication secret")]),
            DesktopChatNode(role: "AXOutline", children: [assistant("history outline")]),
            DesktopChatNode(role: "AXSecureTextField", children: [staticText("password")]),
            DesktopChatNode(role: "AXGroup", label: "Composer", children: [staticText("editable content")]),
        ]
        for node in forbidden {
            check(DesktopChatSemantics.parse(node).reply == nil, "Forbidden subtree must not expose a reply: " + node.role)
        }
        let safeTree = DesktopChatNode(role: "AXGroup", identifier: "chat-messages",
                                      children: forbidden + [assistant("Hello!")])
        check(DesktopChatSemantics.parse(safeTree).reply?.text == "Hello!", "Only explicit assistant text is extracted")
        check(DesktopChatSemantics.parse(safeTree).reply?.id == "assistant-message-1", "Stable reply metadata is retained")
        let noMarker = DesktopChatNode(role: "AXGroup", children: [staticText("unclassified text")])
        check(DesktopChatSemantics.parse(noMarker).reply == nil, "Unclassified text cannot become a reply")
        let lastReply = DesktopChatNode(role: "AXGroup", children: [assistant("First"), assistant("Second", id: "assistant-message-2")])
        check(DesktopChatSemantics.parse(lastReply).reply?.text == "Second", "Newest ordered assistant reply wins")
        let composerInsideReply = DesktopChatNode(role: "AXGroup", label: "Assistant response", children: [
            staticText("Visible answer"), DesktopChatNode(role: "AXTextArea", text: "draft", editable: true)])
        check(DesktopChatSemantics.parse(composerInsideReply).reply?.text == "Visible answer", "Editable text inside a message is excluded")
        let toolbarInsideReply = DesktopChatNode(role: "AXGroup", label: "Assistant response", children: [
            staticText("Answer"), DesktopChatNode(role: "AXButton", children: [staticText("Copy response")]),
            DesktopChatNode(role: "AXToolbar", children: [staticText("Retry")])])
        check(DesktopChatSemantics.parse(toolbarInsideReply).reply?.text == "Answer", "Message action labels are not response text")
        let stop = DesktopChatNode(role: "AXButton", label: "Stop generating")
        check(DesktopChatSemantics.parse(stop).busy, "Actual Stop generating control means busy")
        check(!DesktopChatSemantics.parse(DesktopChatNode(role: "AXButton", label: "Send")).busy, "Send does not imply busy")
        check(!DesktopChatSemantics.parse(DesktopChatNode(role: "AXStaticText", text: "Thinking...")).busy, "Text cannot invent thinking")
        check(!DesktopChatSemantics.parse(DesktopChatNode(role: "AXButton", label: "Stop generating", enabled: false)).busy,
              "Disabled Stop cannot imply an active generation")
        check(!DesktopChatSemantics.parse(DesktopChatNode(role: "AXButton", label: "Stop playback")).busy,
              "Audio playback controls are not generation")
        check(!DesktopChatSemantics.stop(role: "AXButton", label: "Stop", enabled: true),
              "An unscoped Stop button cannot imply generation")
        check(!DesktopChatSemantics.stop(role: "AXButton", label: "Stop", enabled: true, inComposer: true),
              "Unverified plain Stop remains unsupported even inside a composer")
        let long = DesktopChatSemantics.parse(assistant(String(repeating: "x", count: 900))).reply!
        check(long.text.count == 301 && CompanionChatActivity.shortReply(long.text) == nil,
              "Long replies remain classified as long, never displayed as a cropped short reply")
        let withinBudget = DesktopChatNode(role: "AXGroup", children: (0..<220).map { assistant("reply-\($0)", id: "assistant-message-\($0)") })
        check(DesktopChatSemantics.parse(withinBudget).reply?.text != "reply-219", "Traversal is node bounded")
        var tooDeep = assistant("too deep")
        for _ in 0..<15 { tooDeep = DesktopChatNode(role: "AXGroup", children: [tooDeep]) }
        check(DesktopChatSemantics.parse(tooDeep).reply == nil, "Traversal is depth bounded")
        check(!DesktopChatSemantics.chatContainer(identifier: "sidebar", label: "Chat history"), "History is never a chat scope")
        let conversationID = "417E031B-CB94-4CFD-9E50-153634CF41DE"
        let claudeURL = "https://claude.ai/chat/" + conversationID
        check(DesktopChatSemantics.conversationIdentity(provider: "claude", url: claudeURL, identifier: "") != nil,
              "A concrete Claude conversation URL proves identity")
        check(DesktopChatSemantics.conversationIdentity(provider: "codex", url: "https://chatgpt.com/c/" + conversationID, identifier: "") != nil,
              "A concrete ChatGPT conversation URL proves identity")
        check(DesktopChatSemantics.conversationIdentity(provider: "claude", url: claudeURL + "?private=query", identifier: "") ==
              DesktopChatSemantics.conversationIdentity(provider: "claude", url: claudeURL, identifier: ""),
              "Query strings do not become chat identity or metadata")
        check(DesktopChatSemantics.conversationIdentity(provider: "claude", url: "https://claude.ai/", identifier: "chat-thread") == nil,
              "A homepage and generic thread identifier do not prove a selected chat")
        check(DesktopChatSemantics.conversationIdentity(provider: "claude", url: "https://unrelated.test/chat/" + conversationID, identifier: "") == nil,
              "Unrelated URLs do not prove provider identity")
        check(DesktopChatSemantics.conversationIdentity(provider: "claude", url: "https://claude.ai/chat/not-an-id", identifier: "") == nil,
              "Unrecognized route metadata is not a stable conversation identity")
        check(DesktopChatSemantics.conversationIdentity(provider: "claude", url: "", identifier: "conversation-" + conversationID) != nil,
              "An explicitly marked per-conversation UUID is usable")
        check(DesktopChatSemantics.conversationIdentity(provider: "codex", url: "", identifier: "chat-messages") == nil,
              "Generic message-container identifiers remain ambiguous")
        check(DesktopChatSemantics.webConversationTitle("Greeting - Claude", provider: "claude") == "Greeting",
              "Verified Claude WebArea title exposes actual conversation title")
        check(DesktopChatSemantics.webConversationTitle("Claude", provider: "claude") == nil,
              "Generic app title does not invent a conversation title")
        check(DesktopChatSemantics.conversationIdentity(provider: "claude", url: "claude.ai/chat/" + conversationID, identifier: "") != nil,
              "An exposed native conversation URL may omit displayed scheme")
        func claudeMessage(_ index: Int, assistant: Bool, body: [DesktopChatNode]) -> DesktopChatNode {
            let heading = assistant ? "Claude responded: Preview" : "You said: private submitted prompt"
            return DesktopChatNode(role: "AXGroup", label: "Message \(index) of 4", children: [
                DesktopChatNode(role: "AXGroup", children: [
                    DesktopChatNode(role: "AXHeading", label: heading, children: [staticText(heading)])
                ] + body)
            ])
        }
        let actualShortShape = DesktopChatNode(role: "AXGroup", label: "Chat messages", children: [
            claudeMessage(1, assistant: false, body: [staticText("private user body")]),
            claudeMessage(2, assistant: true, body: [staticText("Hi there! What can I help you with today?"),
                DesktopChatNode(role: "AXButton", label: "Show message actions for Claude responded: Hi there!")])
        ])
        let actualShort = DesktopChatSemantics.parse(actualShortShape).reply
        check(actualShort?.text == "Hi there! What can I help you with today?", "Verified Claude wrapper produces assistant body only")
        check(actualShort?.text.contains("Claude responded:") == false, "Accessible assistant heading is not duplicated in reply")
        check(actualShort?.text.contains("private user") == false, "User heading/body do not become assistant response")
        let bullet = String(repeating: "An actual assistant content-list sentence. ", count: 5)
        let actualLongShape = DesktopChatNode(role: "AXGroup", label: "Chat messages", children: [
            claudeMessage(1, assistant: false, body: [staticText("private user body")]),
            claudeMessage(2, assistant: true, body: [staticText("Old answer")]),
            claudeMessage(3, assistant: false, body: [staticText("Another private user body")]),
            claudeMessage(4, assistant: true, body: [staticText("Right now, no."),
                DesktopChatNode(role: "AXButton", label: "Searched the web, read a page"),
                DesktopChatNode(role: "AXList", children: [staticText(bullet), staticText(bullet)]),
                DesktopChatNode(role: "AXToolbar", label: "Message actions", children: [staticText("Copy Read aloud Retry")])])
        ])
        let actualLong = DesktopChatSemantics.parse(actualLongShape).reply
        check(actualLong?.text.contains("content-list") == true, "Assistant content-list bullets are included")
        check(actualLong.flatMap { CompanionChatActivity.shortReply($0.text) } == nil, "Long lists cannot masquerade as short replies")
        check(actualLong?.text.contains("Searched the web") == false, "Tool-status controls are excluded")
        check(actualLong?.text.contains("Copy Read aloud") == false, "Message toolbar labels are excluded")
        let unsupportedNewest = DesktopChatNode(role: "AXGroup", children: [assistant("Old answer"),
            assistant("Prefix", id: "assistant-message-new")])
        var withUnsupportedTable = unsupportedNewest
        withUnsupportedTable.children[1].children.append(DesktopChatNode(role: "AXTable", children: [staticText("Long unsupported table content")]))
        check(DesktopChatSemantics.parse(withUnsupportedTable).reply == nil, "Unsupported latest reply cannot fall back to an old answer or cropped prefix")
        var deepBody = staticText("Hidden actual continuation")
        for _ in 0..<12 { deepBody = DesktopChatNode(role: "AXGroup", children: [deepBody]) }
        let deepReply = DesktopChatNode(role: "AXGroup", label: "Assistant response", children: [staticText("Short prefix"), deepBody])
        check(DesktopChatSemantics.parse(deepReply).reply == nil, "Depth-limited assistant body cannot become a partial short reply")
        let nodeLimitedReply = DesktopChatNode(role: "AXGroup", label: "Assistant response",
            children: [staticText("Short prefix")] + (0..<105).map { _ in DesktopChatNode(role: "AXGroup") })
        check(DesktopChatSemantics.parse(nodeLimitedReply).reply == nil, "Node-limited assistant body cannot become a partial short reply")
        let unknownLatest = DesktopChatNode(role: "AXGroup", children: [assistant("Older reply"),
            DesktopChatNode(role: "AXGroup", label: "Message 4 of 4", children: [staticText("Unclassified current message")])])
        check(DesktopChatSemantics.parse(unknownLatest).reply == nil, "Unknown newest wrapper invalidates historical reply fallback")
        let userLatest = DesktopChatNode(role: "AXGroup", children: [assistant("Last actual assistant reply"),
            claudeMessage(3, assistant: false, body: [staticText("Private submitted message")])])
        check(DesktopChatSemantics.parse(userLatest).reply?.text == "Last actual assistant reply", "Known user wrapper is skipped without invalidating an identified assistant")
        let statusInsideReply = DesktopChatNode(role: "AXGroup", label: "Assistant response", children: [
            DesktopChatNode(role: "AXGroup", label: "Tool status", children: [staticText("Searching the web")]), staticText("Actual response")])
        check(DesktopChatSemantics.parse(statusInsideReply).reply?.text == "Actual response", "Explicit tool-status metadata is excluded from reply")
        var depthTenChat = DesktopChatNode(role: "AXGroup", label: "Chat messages")
        for _ in 0..<10 { depthTenChat = DesktopChatNode(role: "AXGroup", children: [depthTenChat]) }
        check(DesktopChatSemantics.containsChatScope(depthTenChat), "Observed Claude Chat messages scope at depth ten is reachable")
        var depthThirteenButton = DesktopChatNode(role: "AXButton", label: "Stop generating")
        for _ in 0..<13 { depthThirteenButton = DesktopChatNode(role: "AXGroup", children: [depthThirteenButton]) }
        check(DesktopChatSemantics.busyOutsideChat(depthThirteenButton), "A generation control at observed composer depth thirteen is reachable")
        var depthThirteenDictate = DesktopChatNode(role: "AXButton", label: "Dictate")
        for _ in 0..<13 { depthThirteenDictate = DesktopChatNode(role: "AXGroup", children: [depthThirteenDictate]) }
        check(!DesktopChatSemantics.busyOutsideChat(depthThirteenDictate), "Actual Dictate control does not invent busy state")
        let messageHistoryStop = DesktopChatNode(role: "AXGroup", label: "Chat messages", children: [
            DesktopChatNode(role: "AXButton", label: "Stop generating")])
        check(!DesktopChatSemantics.busyOutsideChat(messageHistoryStop), "Separate busy scan never rereads message-history subtree")
        var tooDeepScope = DesktopChatNode(role: "AXGroup", label: "Chat messages")
        for _ in 0..<14 { tooDeepScope = DesktopChatNode(role: "AXGroup", children: [tooDeepScope]) }
        check(!DesktopChatSemantics.containsChatScope(tooDeepScope), "Scope search still has a finite depth bound")
        check(DesktopChatReadPolicy.maximumSeconds == 1.2 && DesktopChatReadPolicy.maximumSeconds <= 2,
              "Selected chat reads have a pragmatic finite total deadline")
        check(DesktopChatReadPolicy.messageTimeout > 0 && DesktopChatReadPolicy.messageTimeout <= 0.1 &&
              DesktopChatReadPolicy.maximumNodes <= 300, "Per-element reads and total traversal remain bounded")
        check(DesktopChatConnection(provider: "claude", status: .unsupported, title: nil).detail == nil,
              "Failure detail remains optional for existing callers")
        check(DesktopChatSemantics.metadataLabel(role: "AXGroup", description: "group", title: "Chat messages") == "Chat messages",
              "A generic group description cannot hide the semantic chat title")
        check(DesktopChatSemantics.metadataLabel(role: "AXGroup", description: "group", title: "Message 2 of 4") == "Message 2 of 4",
              "A generic description cannot hide message role markers")
        check(DesktopChatSemantics.metadataLabel(role: "AXGroup", description: "Chat messages", title: "container") == "Chat messages",
              "An explicit chat description is preferred over a generic title")
        check(DesktopChatSemantics.metadataLabel(role: "AXHeading", description: "heading", title: "You said: private login settings") == "You said:",
              "User heading previews are discarded immediately after role classification")
        check(DesktopChatSemantics.metadataLabel(role: "AXHeading", description: "heading", title: "Claude responded: settings help") == "Claude responded:",
              "Assistant role metadata is sanitized before exclusions")
        let settingsBody = DesktopChatNode(role: "AXGroup", label: "Assistant response", children: [
            DesktopChatNode(role: "AXStaticText", label: "Login settings", text: "Open login settings to continue."),
            DesktopChatNode(role: "AXHeading", label: "Settings", text: "Settings"),
            DesktopChatNode(role: "AXGroup", label: "Useful login settings instructions", children: [staticText("Then return here.")])])
        check(DesktopChatSemantics.parse(settingsBody).reply?.text == "Open login settings to continue.\nSettings\nThen return here.",
              "Actual assistant words login/settings remain whole response content")
        check(DesktopChatSemantics.webConversationTitle("Login settings and chat history - Claude", provider: "claude") == "Login settings and chat history",
              "A legitimate current-chat title remains free-form content")
        switch DesktopChatSemantics.latestAssistant(actualLongShape) {
        case let .found(node): check(node.label == "Message 4 of 4", "Only newest proven assistant wrapper is selected")
        default: check(false, "Latest actual Claude assistant must be found")
        }
        switch DesktopChatSemantics.latestAssistant(userLatest) {
        case let .found(node): check(node.label == "Assistant response", "Known latest user wrapper is skipped using metadata only")
        default: check(false, "Latest identified assistant behind known user must be found")
        }
        switch DesktopChatSemantics.latestAssistant(unknownLatest) {
        case .unknown: check(true, "Unknown newest message blocks historical fallback")
        default: check(false, "Unknown latest wrapper cannot select an old answer")
        }
        let oldHeavy = DesktopChatNode(role: "AXGroup", label: "Assistant response", children:
            (0..<500).map { _ in staticText("Older response text") })
        let newestOnly = DesktopChatNode(role: "AXGroup", label: "Chat messages", children: [oldHeavy, assistant("New answer", id: "assistant-message-newest")])
        switch DesktopChatSemantics.latestAssistant(newestOnly) {
        case let .found(node): check(node.identifier == "assistant-message-newest", "Older heavy assistant bodies are never traversed when selecting latest")
        default: check(false, "Latest selection must not be exhausted by older history")
        }
        let emptyChat = DesktopChatNode(role: "AXGroup", label: "Chat messages")
        switch DesktopChatSemantics.latestAssistant(emptyChat) {
        case .none: check(true, "An empty current chat has no response")
        default: check(false, "Empty chat cannot produce a response")
        }
        check(DesktopChatSemantics.validatedBusy(observedStop: false, requiredReadsSucceeded: false) == nil,
              "Failed generation traversal cannot fabricate an idle completion")
        check(DesktopChatSemantics.validatedBusy(observedStop: true, requiredReadsSucceeded: false) == true,
              "An actually observed Stop still proves busy despite an unrelated unreadable branch")
        check(DesktopChatSemantics.validatedBusy(observedStop: false, requiredReadsSucceeded: true) == false,
              "A successfully read controls tree may establish idle")
        check(DesktopChatWindowPolicy.initial(focused: .present, main: .absent) == .focused,
              "A present focused window is authoritative and prevents fallback")
        check(DesktopChatWindowPolicy.initial(focused: .absent, main: .present) == .main,
              "An existing main window is used without enumeration")
        check(DesktopChatWindowPolicy.initial(focused: .absent, main: .unsupported) == .fallback,
              "Genuinely absent/unsupported focused and main references permit bounded fallback")
        check(DesktopChatWindowPolicy.initial(focused: .unsupported, main: .unsupported) == .fallback,
              "Both unsupported references permit fallback")
        check(DesktopChatWindowPolicy.initial(focused: .failed, main: .present) == .reject,
              "A focused read error cannot be bypassed with another window")
        check(DesktopChatWindowPolicy.initial(focused: .absent, main: .failed) == .reject,
              "A main-window read error cannot trigger enumeration")
        check(DesktopChatWindowPolicy.reference(error: .success, hasValue: true) == .present,
              "A malformed nonnil focused result remains present and cannot trigger fallback")
        check(DesktopChatWindowPolicy.reference(error: .noValue, hasValue: false) == .absent,
              "AX noValue means a genuine missing window reference")
        check(DesktopChatWindowPolicy.reference(error: .attributeUnsupported, hasValue: false) == .unsupported,
              "Unsupported window attributes may use public AXWindows")
        for error: AXError in [.cannotComplete, .apiDisabled, .invalidUIElement, .notImplemented] {
            check(DesktopChatWindowPolicy.reference(error: error, hasValue: false) == .failed,
                  "Messaging/API/invalid-element/no-API errors cannot trigger fallback")
        }
        let safeWindow = DesktopChatWindowPolicy.Candidate(standard: true, minimized: false, hidden: false, modal: false, hasSheet: false)
        let modalWindow = DesktopChatWindowPolicy.Candidate(standard: true, minimized: false, hidden: false, modal: true, hasSheet: false)
        check(DesktopChatWindowPolicy.unique([safeWindow]) == 0, "Exactly one proven eligible window may be selected")
        check(DesktopChatWindowPolicy.unique([safeWindow, safeWindow]) == nil, "Multiple eligible chats remain ambiguous")
        check(DesktopChatWindowPolicy.unique([modalWindow]) == nil, "Modal windows cannot be selected")
        check(DesktopChatWindowPolicy.initial(focused: .present, main: .unsupported) != .fallback && !modalWindow.eligible,
              "An actual focused modal window is rejected without browsing another chat")
        check(DesktopChatWindowPolicy.unique([safeWindow], complete: false) == nil, "Malformed/truncated/unreadable window lists are rejected")
        for unsafe in [
            DesktopChatWindowPolicy.Candidate(standard: false, minimized: false, hidden: false, modal: false, hasSheet: false),
            DesktopChatWindowPolicy.Candidate(standard: true, minimized: true, hidden: false, modal: false, hasSheet: false),
            DesktopChatWindowPolicy.Candidate(standard: true, minimized: false, hidden: true, modal: false, hasSheet: false),
            DesktopChatWindowPolicy.Candidate(standard: true, minimized: false, hidden: false, modal: false, hasSheet: true)
        ] { check(DesktopChatWindowPolicy.unique([unsafe]) == nil, "Nonstandard/minimized/hidden/sheet windows are not chats") }
        check(DesktopChatWindowPolicy.unique(Array(repeating: safeWindow, count: DesktopChatReadPolicy.maximumWindows + 1)) == nil,
              "Fallback enumeration is bounded")
        check(DesktopChatWindowPolicy.nativeIdentifier(provider: "claude", bundleIdentifier: "com.anthropic.claudefordesktop"),
              "The actual native Claude bundle ID is accepted")
        check(!DesktopChatWindowPolicy.nativeIdentifier(provider: "claude", bundleIdentifier: "com.anthropic.claudefordesktop.helper"),
              "A helper inheriting an outer app URL cannot impersonate the native app")
        check(!DesktopChatWindowPolicy.nativeIdentifier(provider: "claude", bundleIdentifier: nil), "An unknown native app identity is rejected")
        check(!DesktopChatReadPolicy.completeChildRange(reportedCount: 3, returnedCount: nil),
              "Malformed AX child arrays cannot prove no sheet or idle controls")
        check(!DesktopChatReadPolicy.completeChildRange(reportedCount: 3, returnedCount: 1),
              "Short AX child arrays cannot be treated as complete")
        check(DesktopChatReadPolicy.completeChildRange(reportedCount: 3, returnedCount: 3),
              "A full typed requested child range is complete")
        check(DesktopChatReadPolicy.completeChildRange(reportedCount: 80, returnedCount: 48),
              "The complete bounded slice has its expected count; callers still flag larger required scopes")
        let selectedClaudeBundle = URL(fileURLWithPath: "/Applications/Claude.app")
        let shellURL = selectedClaudeBundle.appendingPathComponent("Contents/Resources/app.asar/.vite/renderer/main_window/index.html").absoluteString
        check(DesktopChatSemantics.trustedClaudeShell(provider: "claude", bundleURL: selectedClaudeBundle, url: shellURL),
              "Only the selected app's observed native shell document may be traversed")
        for unsafeURL in [
            "file:///Applications/Other.app/Contents/Resources/app.asar/.vite/renderer/main_window/index.html",
            "https://claude.ai/login", "https://unrelated.test/chat/" + conversationID,
            shellURL + "?login=1", shellURL + "#login",
            "file://foreign-host/Applications/Claude.app/Contents/Resources/app.asar/.vite/renderer/main_window/index.html",
            "file:///Applications/Claude.app/Contents/Resources/app.asar/.vite/renderer/main_window/../main_window/index.html",
            "file:///Applications/Claude.app/Contents/Resources/app.asar/.vite/renderer/main_window/%2E%2E/main_window/index.html"
        ] {
            check(!DesktopChatSemantics.trustedClaudeShell(provider: "claude", bundleURL: selectedClaudeBundle, url: unsafeURL),
                  "Wrong app, remote URL, login, query, fragment, foreign file host, and traversal are not trusted shells")
        }
        check(!DesktopChatSemantics.trustedClaudeShell(provider: "codex", bundleURL: selectedClaudeBundle, url: shellURL),
              "Claude shell behavior cannot be applied to another provider")
        check(!DesktopChatSemantics.trustedClaudeShell(provider: "claude", bundleURL: nil, url: shellURL),
              "A missing selected application path cannot authorize a shell")
        check(!DesktopChatSemantics.trustedClaudeShell(provider: "claude", bundleURL: selectedClaudeBundle,
            url: "file:///Applications/Claude.app/Contents/Resources/main_window/index.html"),
              "A similar shell suffix does not broaden the exact observed document allowlist")

        struct ScopeFixture {
            let role: String
            var label = ""
            var url = ""
            var nodeID = ""
            var children: [ScopeFixture] = []
        }
        func scopeFixture(_ root: ScopeFixture, maximumDepth: Int = DesktopChatReadPolicy.maximumScopeDepth) -> (found: Bool, diagnostics: DesktopChatScopeDiagnostics) {
            var remaining = DesktopChatReadPolicy.maximumNodes
            var diagnostics = DesktopChatScopeDiagnostics()
            func walk(_ node: ScopeFixture, depth: Int, key: String? = nil, insideShell: Bool = false, path: [String] = []) -> Bool {
                guard diagnostics.attempt(depth: depth, isAncestor: !node.nodeID.isEmpty && path.contains(node.nodeID)),
                      depth <= maximumDepth, remaining > 0 else { return false }; remaining -= 1
                diagnostics.recordRole(node.role, error: .success)
                let nextPath = node.nodeID.isEmpty ? path : path + [node.nodeID]
                var context = key, permittedShell = insideShell
                if node.role == "AXWebArea" {
                    if let found = DesktopChatSemantics.conversationIdentity(provider: "claude", url: node.url, identifier: "") {
                        context = found
                    } else if DesktopChatSemantics.trustedClaudeShell(provider: "claude", bundleURL: selectedClaudeBundle, url: node.url) {
                        context = nil; permittedShell = true
                    } else { return false }
                }
                guard !DesktopChatSemantics.excluded(role: node.role, identifier: "", label: node.role == "AXWebArea" ? "" : node.label) else { return false }
                if DesktopChatSemantics.chatContainer(identifier: "", label: node.label) {
                    if context != nil { return true }
                    if !permittedShell { return false }
                }
                return node.children.contains { walk($0, depth: depth + 1, key: context, insideShell: permittedShell, path: nextPath) }
            }
            let found = walk(root, depth: 0)
            return (found, diagnostics)
        }
        func observedScope(_ root: ScopeFixture, maximumDepth: Int = DesktopChatReadPolicy.maximumScopeDepth) -> Bool {
            scopeFixture(root, maximumDepth: maximumDepth).found
        }
        let scopeMessages = ScopeFixture(role: "AXGroup", label: "Chat messages")
        let scopePrimary = ScopeFixture(role: "AXGroup", label: "Primary pane", children: [
            ScopeFixture(role: "AXGroup", children: [ScopeFixture(role: "AXGroup", children: [scopeMessages])])])
        let scopeRemote = ScopeFixture(role: "AXWebArea", label: "Hello from Claude - Claude", url: "claude.ai/chat/" + conversationID, children: [
            ScopeFixture(role: "AXGroup", children: [ScopeFixture(role: "AXGroup", children: [
                ScopeFixture(role: "AXGroup", label: "Sidebar"), ScopeFixture(role: "AXGroup", children: [scopePrimary])])])])
        let scopeLocal = ScopeFixture(role: "AXWebArea", url: shellURL)
        let scopeSibling = ScopeFixture(role: "AXWindow", children: [ScopeFixture(role: "AXGroup", children: [
            ScopeFixture(role: "AXGroup", children: [scopeLocal, scopeRemote])])])
        var scopeNestedLocal = scopeLocal; scopeNestedLocal.children = [scopeRemote]
        let scopeNested = ScopeFixture(role: "AXWindow", children: [ScopeFixture(role: "AXGroup", children: [
            ScopeFixture(role: "AXGroup", children: [scopeNestedLocal])])])
        check(observedScope(scopeSibling), "Observed sibling local/remote web areas expose the verified chat")
        check(observedScope(scopeNested), "Verified remote conversation nested inside the exact local shell is reachable")
        func wrapped(_ child: ScopeFixture, groups: Int) -> ScopeFixture {
            var node = child
            for _ in 0..<groups { node = ScopeFixture(role: "AXGroup", children: [node]) }
            return node
        }
        func deeperScope(groups: Int) -> ScopeFixture {
            var shell = scopeLocal; shell.children = [wrapped(scopeRemote, groups: groups)]
            return ScopeFixture(role: "AXWindow", children: [ScopeFixture(role: "AXGroup", children: [
                ScopeFixture(role: "AXGroup", children: [shell])])])
        }
        for wrappers in 2...6 {
            let fixture = deeperScope(groups: wrappers)
            check(!observedScope(fixture, maximumDepth: 12), "Extra native group wrappers reproduce the previous scope-depth failure")
            check(observedScope(fixture), "The bounded expanded scope depth reaches the verified conversation through extra group wrappers")
        }
        let baseScopeDepth = scopeFixture(scopeNested).diagnostics.maximumAttemptedDepth
        let scopeAtLimit = deeperScope(groups: DesktopChatReadPolicy.maximumScopeDepth - baseScopeDepth)
        let scopePastLimit = deeperScope(groups: DesktopChatReadPolicy.maximumScopeDepth - baseScopeDepth + 1)
        let atLimit = scopeFixture(scopeAtLimit), pastLimit = scopeFixture(scopePastLimit)
        check(atLimit.found && atLimit.diagnostics.maximumAttemptedDepth == DesktopChatReadPolicy.maximumScopeDepth,
              "A selected remote chat at the exact finite discovery depth remains reachable")
        check(!pastLimit.found && pastLimit.diagnostics.depthLimitHits == 1 &&
              pastLimit.diagnostics.maximumAttemptedDepth == DesktopChatReadPolicy.maximumScopeDepth + 1,
              "One node beyond the scope bound is rejected and recorded only as an attempted depth")
        let opaqueWrappers = deeperScope(groups: 14)
        check(!observedScope(opaqueWrappers, maximumDepth: 20) && observedScope(opaqueWrappers),
              "The observed depth-21 guard failure is reproduced by opaque groups and supported within the new finite bound")
        let cyclicAncestor = ScopeFixture(role: "AXGroup", nodeID: "ancestor", children: [
            ScopeFixture(role: "AXGroup", nodeID: "child", children: [
                ScopeFixture(role: "AXGroup", nodeID: "ancestor", children: [scopeRemote])])])
        let cycleResult = scopeFixture(cyclicAncestor)
        check(!cycleResult.found && cycleResult.diagnostics.cycleHits == 1 && cycleResult.diagnostics.maximumAttemptedDepth == 2,
              "Repeated ancestor AX identity stops descent before it can masquerade as deeper wrappers")
        check(cycleResult.diagnostics.depthLimitHits == 0 && cycleResult.diagnostics.groupRoles == 2,
              "Cycle diagnostics count the rejected repeat without rereading or treating it as depth exhaustion")
        let immediateCycle = scopeFixture(ScopeFixture(role: "AXGroup", nodeID: "parent", children: [
            ScopeFixture(role: "AXGroup", nodeID: "parent", children: [scopeRemote])]))
        check(!immediateCycle.found && immediateCycle.diagnostics.cycleHits == 1 && immediateCycle.diagnostics.groupRoles == 1,
              "An immediate repeated parent is rejected before a second metadata read")
        let repeatedSibling = scopeFixture(ScopeFixture(role: "AXWindow", children: [
            ScopeFixture(role: "AXGroup", nodeID: "shared-sibling"),
            ScopeFixture(role: "AXGroup", nodeID: "shared-sibling", children: [scopeRemote])]))
        check(repeatedSibling.found && repeatedSibling.diagnostics.cycleHits == 0,
              "An identity encountered on a completed sibling branch is not a current ancestor cycle")
        var shellWithoutRemote = scopeLocal; shellWithoutRemote.children = [scopeMessages]
        check(!observedScope(shellWithoutRemote), "A local shell cannot authorize reading chat bodies without an official remote route")
        var foreignShell = scopeLocal; foreignShell.url = "file:///Applications/Other.app/index.html"; foreignShell.children = [scopeRemote]
        check(!observedScope(foreignShell), "Unknown WebAreas are not traversed even when they contain a chat-looking descendant")
        check(!observedScope(wrapped(foreignShell, groups: 14)), "Expanded structural depth cannot authorize an unknown WebArea")
        let foreignRemote = ScopeFixture(role: "AXWebArea", url: "https://unrelated.test/chat/" + conversationID, children: [scopeMessages])
        check(!observedScope(foreignRemote), "An unrelated remote WebArea cannot supply a current chat scope")
        var inheritedContextShell = scopeLocal; inheritedContextShell.children = [scopeMessages]
        let inheritedRemote = ScopeFixture(role: "AXWebArea", url: "https://claude.ai/chat/" + conversationID, children: [inheritedContextShell])
        check(!observedScope(inheritedRemote), "Traversing a shell clears inherited conversation proof and title")
        var markedShell = scopeLocal
        markedShell.children = [ScopeFixture(role: "AXGroup", label: "Chat messages", children: [scopeRemote])]
        check(observedScope(markedShell), "A shell-only marker cannot block discovery of its official remote child")
        let remoteTranscript = ScopeFixture(role: "AXGroup", label: "Chat messages", nodeID: "transcript", children: [
            ScopeFixture(role: "AXButton", label: "Stop generating")])
        func routedControlState(_ root: ScopeFixture, maximumDepth: Int = DesktopChatReadPolicy.maximumControlDepth) -> Bool? {
            let selectedPath = ["shell", "marker", "remote", "transcript"]
            var incomplete = false
            func walk(_ node: ScopeFixture, depth: Int) -> Bool {
                guard depth <= maximumDepth else { incomplete = true; return false }
                if DesktopChatSemantics.chatContainer(identifier: "", label: node.label) {
                    guard let next = DesktopChatSemantics.nextControlPathNode(markerIndex: selectedPath.firstIndex(of: node.nodeID), pathCount: selectedPath.count),
                          let child = node.children.first(where: { $0.nodeID == selectedPath[next] }) else { return false }
                    return walk(child, depth: depth + 1)
                }
                if node.role == "AXWebArea", !["shell", "remote"].contains(node.nodeID) { return false }
                if DesktopChatSemantics.stop(role: node.role, label: node.label, enabled: true) { return true }
                return node.children.contains { walk($0, depth: depth + 1) }
            }
            let observedStop = walk(root, depth: 0)
            return DesktopChatSemantics.validatedBusy(observedStop: observedStop, requiredReadsSucceeded: !incomplete)
        }
        func routedControls(_ root: ScopeFixture, maximumDepth: Int = DesktopChatReadPolicy.maximumControlDepth) -> Bool {
            routedControlState(root, maximumDepth: maximumDepth) == true
        }
        let inactiveComposer = ScopeFixture(role: "AXGroup", children: [ScopeFixture(role: "AXButton", label: "Dictate")])
        var routedRemote = ScopeFixture(role: "AXWebArea", url: "https://claude.ai/chat/" + conversationID,
            nodeID: "remote", children: [remoteTranscript, inactiveComposer])
        let unrelatedTranscript = ScopeFixture(role: "AXGroup", label: "Chat messages", nodeID: "unrelated", children: [
            ScopeFixture(role: "AXButton", label: "Stop generating")])
        func routedShell(_ remote: ScopeFixture) -> ScopeFixture {
            ScopeFixture(role: "AXWebArea", url: shellURL, nodeID: "shell", children: [
                ScopeFixture(role: "AXGroup", label: "Chat messages", nodeID: "marker", children: [unrelatedTranscript, remote])])
        }
        check(!routedControls(routedShell(routedRemote)), "Marked shell routing skips current and sibling transcripts and cannot invent busy")
        routedRemote.children[1] = ScopeFixture(role: "AXGroup", children: [ScopeFixture(role: "AXButton", label: "Stop generating")])
        check(routedControls(routedShell(routedRemote)), "Generation control remains reachable through the marked shell's next selected-route child")
        let deepRoutedControl = wrapped(routedShell(routedRemote), groups: 19)
        check(!routedControls(deepRoutedControl, maximumDepth: 16), "Extra native wrappers reproduce the previous generation-control depth failure")
        check(routedControls(deepRoutedControl), "The expanded finite control depth reaches the selected remote composer")
        let opaqueControlWrappers = wrapped(routedShell(routedRemote), groups: 24)
        check(routedControlState(opaqueControlWrappers, maximumDepth: 24) == nil && routedControls(opaqueControlWrappers),
              "Selected generation controls beyond the previous 24-depth bound remain reachable within the new finite limit")
        check(routedControls(wrapped(routedShell(routedRemote), groups: DesktopChatReadPolicy.maximumControlDepth - 4)), "An explicit Stop at the exact control depth limit is reachable")
        check(!routedControls(wrapped(routedShell(routedRemote), groups: DesktopChatReadPolicy.maximumControlDepth - 3)), "Controls beyond the finite depth remain unreadable")
        check(routedControlState(wrapped(routedShell(routedRemote), groups: DesktopChatReadPolicy.maximumControlDepth - 3)) == nil,
              "Hitting the control depth limit cannot fabricate idle or completion")
        var deepIdleRemote = routedRemote; deepIdleRemote.children[1] = inactiveComposer
        check(!routedControls(wrapped(routedShell(deepIdleRemote), groups: 19)), "Deep traversal still excludes fake Stop controls in current and sibling transcripts")
        check(DesktopChatSemantics.nextControlPathNode(markerIndex: nil, pathCount: 4) == nil,
              "Unrelated chat-looking markers cannot enter control traversal")
        check(DesktopChatSemantics.nextControlPathNode(markerIndex: 3, pathCount: 4) == nil,
              "The selected actual transcript remains excluded from control traversal")
        var metadataDiagnostics = DesktopChatScopeDiagnostics()
        metadataDiagnostics.recordRole("AXGroup", error: .success)
        metadataDiagnostics.recordRole("AXScrollArea", error: .success)
        metadataDiagnostics.recordRole("AXWebArea", error: .success)
        metadataDiagnostics.recordRole("private arbitrary role", error: .success)
        metadataDiagnostics.recordRole("", error: .cannotComplete)
        metadataDiagnostics.recordMetadata(error: .success, hasValue: true, isString: true, nonempty: true)
        metadataDiagnostics.recordMetadata(error: .success, hasValue: true, isString: true, nonempty: false)
        metadataDiagnostics.recordMetadata(error: .noValue, hasValue: false, isString: false, nonempty: false)
        metadataDiagnostics.recordMetadata(error: .attributeUnsupported, hasValue: false, isString: false, nonempty: false)
        metadataDiagnostics.recordMetadata(error: .success, hasValue: true, isString: false, nonempty: false)
        metadataDiagnostics.recordMetadata(error: .cannotComplete, hasValue: false, isString: false, nonempty: false)
        check(metadataDiagnostics.groupRoles == 1 && metadataDiagnostics.scrollRoles == 1 && metadataDiagnostics.webRoles == 1 &&
              metadataDiagnostics.otherRoles == 1 && metadataDiagnostics.unknownRoles == 1,
              "Scope role diagnostics retain only fixed role-category counts")
        check(metadataDiagnostics.metadataValues == 1 && metadataDiagnostics.metadataEmpty == 1 && metadataDiagnostics.metadataAbsent == 1 &&
              metadataDiagnostics.metadataUnsupported == 1 && metadataDiagnostics.metadataInvalid == 1 && metadataDiagnostics.metadataFailed == 1,
              "Scope metadata diagnostics distinguish read categories without retaining values")
        check(!metadataDiagnostics.summary.contains("private") && !metadataDiagnostics.summary.contains(conversationID) &&
              !metadataDiagnostics.summary.contains("claude.ai"), "Diagnostics do not reveal attribute strings, identifiers, or URLs")

        var tracking = DesktopChatTracking()
        let old = reply("Old branch discussion")
        let baseline = tracking.receive(snapshot(response: old))
        check(baseline.map(\.phase) == [.connected], "Connect shows title only, never old reply")
        check(baseline.allSatisfy { $0.reply == nil && $0.origin == .desktop }, "Connect has explicit desktop provenance")
        for _ in 0..<8 { check(tracking.receive(snapshot(response: old)).isEmpty, "Idle baseline must stay silent") }
        let started = tracking.receive(snapshot(busy: true, response: old))
        check(started.map(\.phase) == [.thinking], "Only observed busy starts thinking")
        let runID = started[0].runID
        check(tracking.receive(snapshot(busy: true, response: reply("New partial", id: "assistant-message-2"))).isEmpty,
              "Streaming response is not shown as completed")
        let new = reply("New answer", id: "assistant-message-2")
        check(tracking.receive(snapshot(response: new)).isEmpty, "One completion sample must settle")
        let finished = tracking.receive(snapshot(response: new))
        check(finished.map(\.phase) == [.completed] && finished[0].reply == "New answer", "Stable new completion is shown")
        check(finished[0].runID == runID, "Completion retains the actual busy run")
        check(tracking.receive(snapshot(response: new)).isEmpty, "Completion is emitted once")
        _ = tracking.receive(snapshot(busy: true, response: new))
        _ = tracking.receive(snapshot(response: new))
        let cancelled = tracking.receive(snapshot(response: new))
        check(cancelled.map(\.phase) == [.completed] && cancelled[0].reply == nil,
              "Stopping without a new reply clears thinking without echoing the prior answer")
        _ = tracking.receive(snapshot(busy: true, response: new))
        let swapped = tracking.receive(snapshot("chat-B", response: reply("Historical B answer", id: "assistant-message-B")))
        check(swapped.map(\.phase) == [.reset, .connected], "Switching chats resets an active run and baselines history")
        for _ in 0..<6 { _ = tracking.receive(snapshot("chat-B", response: reply("Historical B answer", id: "assistant-message-B"))) }
        let smallNew = reply("Fresh B reply", id: "assistant-message-B2")
        check(tracking.receive(snapshot("chat-B", response: smallNew)).isEmpty, "Unobserved new reply must settle")
        let direct = tracking.receive(snapshot("chat-B", response: smallNew))
        check(direct.isEmpty, "Changed assistant identifiers without busy are baselined silently")
        check(!direct.contains { $0.phase == .thinking }, "Direct completion cannot fabricate busy state")
        check(tracking.receive(snapshot("chat-B", response: reply("Changed rendering", id: "assistant-message-B2"))).isEmpty,
              "Delayed rendering of an existing reply is silent")
        check(tracking.receive(snapshot("chat-B", response: reply("Changed rendering", id: "assistant-message-B2"))).isEmpty,
              "Same message identifier cannot replay a historical message")
        let titleChanged = tracking.receive(snapshot("chat-B", response: smallNew, title: "New title"))
        check(titleChanged.map(\.phase) == [.connected] && titleChanged[0].reply == nil, "A title update does not replay replies")
        let lost = tracking.disconnect(provider: "claude")
        check(lost.map(\.phase) == [.reset] && lost[0].origin == .desktop, "Lost scope resets desktop activity")
        check(tracking.disconnect(provider: "claude").isEmpty, "Repeated disconnect is silent")
        let relaunched = tracking.receive(snapshot("new-process", response: new))
        check(relaunched.map(\.phase) == [.connected], "Relaunch baselines replies")

        var loading = DesktopChatTracking()
        _ = loading.receive(snapshot(response: nil))
        for _ in 0..<4 { check(loading.receive(snapshot(response: old)).allSatisfy { $0.phase == .connected },
                              "Initial delayed history load must not appear as a new response") }
        for _ in 0..<4 { check(loading.receive(snapshot(response: reply("Unidentified", id: nil))).isEmpty,
                              "Unidentified idle text never becomes a new response") }
        var initiallyBusy = DesktopChatTracking()
        check(initiallyBusy.receive(snapshot(busy: true, response: old)).map(\.phase) == [.connected, .thinking],
              "Connecting during a real active generation may show thinking")
        _ = initiallyBusy.receive(snapshot(response: reply(String(repeating: "x", count: 241), id: "assistant-message-long")))
        let largeFinished = initiallyBusy.receive(snapshot(response: reply(String(repeating: "x", count: 241), id: "assistant-message-long")))
        check(largeFinished.count == 1 && largeFinished[0].reply == nil, "Long completion clears the bubble")
        var scrolledHistory = DesktopChatTracking()
        _ = scrolledHistory.receive(snapshot(response: old, reliableIdentity: false))
        for _ in 0..<8 { _ = scrolledHistory.receive(snapshot(response: old, reliableIdentity: false)) }
        for index in 0..<4 {
            let historical = reply("Historical branch-\(index)", id: "assistant-message-history-\(index)")
            check(scrolledHistory.receive(snapshot(response: historical, reliableIdentity: false)).isEmpty,
                  "History virtualization after many idle polls cannot replay an old reply")
            check(scrolledHistory.receive(snapshot(response: historical, reliableIdentity: false)).isEmpty,
                  "Settled history still cannot become a new answer")
        }
        _ = scrolledHistory.receive(snapshot(busy: true, response: old, reliableIdentity: false))
        _ = scrolledHistory.receive(snapshot(response: new, reliableIdentity: false))
        let ambiguousCompletion = scrolledHistory.receive(snapshot(response: new, reliableIdentity: false))
        check(ambiguousCompletion.count == 1 && ambiguousCompletion[0].reply == nil,
              "Generic window identity cannot justify a short reply after same-title conversation switch")

        let gate = DesktopChatEpoch()
        var guardedTracking = DesktopChatTracking()
        let beforeSelect = gate.current
        let afterSelect = gate.advance()
        func deliver(_ token: Int, _ snapshot: DesktopChatSnapshot) -> [CompanionChatActivity] {
            guard gate.matches(token) else { return [] }
            return guardedTracking.receive(snapshot)
        }
        check(deliver(beforeSelect, snapshot(busy: true, response: old)).isEmpty,
              "A poll finishing after provider selection cannot publish stale busy activity")
        check(guardedTracking.snapshot == nil, "Invalidated poll cannot mutate tracking state")
        check(deliver(afterSelect, snapshot(response: new)).map(\.phase) == [.connected],
              "The new selection may baseline its actual selected chat")
        let queuedCallbackToken = gate.current
        _ = gate.advance()
        check(!gate.matches(queuedCallbackToken), "Already queued UI callbacks are rejected after stop")
        check(deliver(afterSelect, snapshot(busy: true, response: old)).isEmpty,
              "Stopping discards a pending AX result")
        gate.requestRunning(true)
        check(gate.runningRequested, "An explicit start requests polling")
        gate.requestRunning(false)
        check(!gate.runningRequested, "Stop prevents a queued start from reactivating polling")
        print("\(checks) desktop observer fixture checks passed")
    }
}
