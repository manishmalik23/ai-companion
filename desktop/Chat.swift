import AppKit
import Foundation

private final class ChatBackground: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { Palette.paper.setFill(); bounds.fill() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private class ChatTextView: NSTextView {
    func refreshAppearance() {
        backgroundColor = Palette.muted
        insertionPointColor = Palette.ink
        selectedTextAttributes = [
            .foregroundColor: NSColor.selectedTextColor,
            .backgroundColor: NSColor.selectedTextBackgroundColor
        ]
        // Preserve the transcript's individual semantic text colors. Its saved
        // attributed strings retain dynamic NSColor values across appearances.
        if !isRichText { textColor = Palette.ink }
        layoutManager?.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: textStorage?.length ?? 0))
        enclosingScrollView?.backgroundColor = Palette.muted
        enclosingScrollView?.needsDisplay = true
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }
}

private final class ChatInput: ChatTextView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            ("Ask something…" as NSString).draw(at: NSPoint(x: 12, y: 10), withAttributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor
            ])
        }
    }
}

private final class ChatRun {
    let id = UUID()
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    let input = Pipe()
    let provider: String
    var cancelled = false
    var buffer = Data()
    var reply = ""
    var replyIsLong = false
    var title = ""
    init(provider: String) { self.provider = provider }
}

private struct ChatViewState {
    let draft: String
    let draftSelections: [NSValue]
    let transcriptSelections: [NSValue]
    let transcriptScrollOrigin: NSPoint
}

/// A fresh conversation through the user's installed, authenticated local CLI.
/// No request is sent until the user presses Send.
final class MiniChatController: NSObject, NSTextViewDelegate, NSWindowDelegate {
    private let runtimeURL: URL
    private let workspaceRoot: URL
    private var panel: CompanionPanel?
    private var conversation: NSTextView!
    private var input: ChatInput!
    private var providerPicker: NSPopUpButton!
    private var sendButton: ActionButton!
    private var stopButton: ActionButton!
    private var newButton: NSButton!
    private var status: NSTextField!
    private var active: ChatRun?
    private var sessions: [String: String] = [:]
    private var workspaceIDs: [String: UUID] = [:]
    private var titles: [String: String] = [:]
    private var histories: [String: NSAttributedString] = [:]
    private var viewStates: [String: ChatViewState] = [:]
    private var selectedProvider = "claude"
    private let ioQueue = DispatchQueue(label: "dev.local.pip.chat-output")
    var onActivity: ((CompanionChatActivity) -> Void)?

    init(runtimeURL: URL) {
        self.runtimeURL = runtimeURL; workspaceRoot = runtimeURL.appendingPathComponent("chat-workspaces")
        super.init()
    }

    func show(provider: String? = nil) {
        if panel == nil { createWindow() }
        guard let panel else { return }
        if let provider, provider == "claude" || provider == "codex" {
            selectProvider(provider)
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(input)
        // Finish activation after the originating click has been dispatched.
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, panel.isVisible else { return }
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(self.input)
        }
    }

    private func createWindow() {
        let body = ChatBackground(frame: NSRect(x: 0, y: 0, width: 420, height: 565))
        let window = CompanionPanel(contentRect: body.frame, styleMask: [.titled, .closable, .utilityWindow],
                                    backing: .buffered, defer: false)
        window.title = "Pip chat"; window.titlebarAppearsTransparent = true
        window.backgroundColor = Palette.paper; window.contentView = body
        window.level = .floating; window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; window.delegate = self
        window.center(); panel = window
        body.addSubview(label("Chat with your agent", NSRect(x: 20, y: 17, width: 380, height: 28), size: 21, weight: .semibold))
        providerPicker = NSPopUpButton(frame: NSRect(x: 17, y: 58, width: 183, height: 28))
        providerPicker.addItems(withTitles: ["Claude Code", "Codex CLI"])
        providerPicker.selectItem(at: selectedProvider == "claude" ? 0 : 1)
        providerPicker.target = self; providerPicker.action = #selector(providerChanged)
        providerPicker.setAccessibilityLabel("Chat provider")
        providerPicker.toolTip = "Chat through your local Claude Code or Codex CLI. Mini Chat keeps its own conversations."
        body.addSubview(providerPicker)
        newButton = NSButton(title: "New conversation", target: self, action: #selector(newConversation))
        newButton.frame = NSRect(x: 239, y: 58, width: 164, height: 28); newButton.bezelStyle = .rounded; body.addSubview(newButton)
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 102, width: 380, height: 300))
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        scroll.backgroundColor = Palette.muted
        scroll.wantsLayer = true; scroll.layer?.cornerRadius = 12; scroll.layer?.masksToBounds = true
        let transcript = ChatTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 300))
        conversation = transcript
        conversation.isEditable = false; conversation.isSelectable = true; conversation.isRichText = true
        conversation.drawsBackground = true; conversation.backgroundColor = Palette.muted
        conversation.textContainerInset = NSSize(width: 12, height: 14)
        conversation.font = .systemFont(ofSize: 13); conversation.textColor = Palette.ink
        conversation.minSize = NSSize(width: 0, height: 300)
        conversation.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        conversation.isVerticallyResizable = true; conversation.isHorizontallyResizable = false
        conversation.autoresizingMask = [.width]; conversation.textContainer?.widthTracksTextView = true
        conversation.setAccessibilityLabel("Chat conversation")
        scroll.documentView = conversation; body.addSubview(scroll)
        transcript.refreshAppearance()
        status = label("", NSRect(x: 20, y: 415, width: 380, height: 19), size: 11, color: Palette.secondary)
        status.toolTip = "Each new conversation uses its own separate workspace."; body.addSubview(status)
        let inputScroll = NSScrollView(frame: NSRect(x: 20, y: 443, width: 380, height: 62))
        inputScroll.hasVerticalScroller = true; inputScroll.autohidesScrollers = true
        inputScroll.backgroundColor = Palette.muted
        inputScroll.borderType = .noBorder; inputScroll.wantsLayer = true
        inputScroll.layer?.cornerRadius = 10; inputScroll.layer?.masksToBounds = true
        input = ChatInput(frame: NSRect(x: 0, y: 0, width: 360, height: 62))
        input.font = .systemFont(ofSize: 13); input.textColor = Palette.ink; input.backgroundColor = Palette.muted
        input.isRichText = false; input.allowsUndo = true; input.textContainerInset = NSSize(width: 12, height: 10)
        input.isVerticallyResizable = true; input.isHorizontallyResizable = false
        input.autoresizingMask = [.width]; input.textContainer?.widthTracksTextView = true
        input.minSize = NSSize(width: 0, height: 62); input.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        input.delegate = self; input.setAccessibilityLabel("Message to your agent")
        inputScroll.documentView = input; body.addSubview(inputScroll)
        input.refreshAppearance()
        stopButton = ActionButton(frame: NSRect(x: 20, y: 521, width: 89, height: 34))
        stopButton.title = "Stop"; stopButton.isBordered = false; stopButton.target = self; stopButton.action = #selector(stop)
        stopButton.isEnabled = false; body.addSubview(stopButton)
        let shortcut = label("Return sends · Shift ↵ newline", NSRect(x: 113, y: 530, width: 170, height: 17), size: 10, color: Palette.secondary)
        body.addSubview(shortcut)
        sendButton = ActionButton(frame: NSRect(x: 285, y: 521, width: 115, height: 34))
        sendButton.title = "Send"; sendButton.primary = true; sendButton.isBordered = false
        sendButton.target = self; sendButton.action = #selector(send); body.addSubview(sendButton)
        restoreConversation(); updateControls()
    }

    private var providerLabel: String { selectedProvider == "claude" ? "Claude Code" : "Codex CLI" }

    private func restoreConversation() {
        if let history = histories[selectedProvider] { conversation.textStorage?.setAttributedString(history) }
        else {
            conversation.textStorage?.setAttributedString(NSAttributedString(string: ""))
            append("A fresh conversation with \(providerLabel).\n\nAsk a question to get started. Connected permission requests appear in Pip.\n", color: Palette.secondary)
        }
        status.stringValue = "Ready · \(providerLabel)"; status.toolTip = "Each new conversation uses its own separate workspace."
    }

    private func append(_ text: String, color: NSColor = Palette.ink, weight: NSFont.Weight = .regular) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 3; paragraph.paragraphSpacing = 6
        conversation.textStorage?.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph
        ]))
        conversation.scrollToEndOfDocument(nil)
    }

    @objc private func providerChanged() {
        selectProvider(providerPicker.indexOfSelectedItem == 0 ? "claude" : "codex")
    }

    private func selectProvider(_ provider: String) {
        guard provider == "claude" || provider == "codex" else { return }
        guard active == nil else {
            providerPicker.selectItem(at: selectedProvider == "claude" ? 0 : 1)
            if provider != selectedProvider {
                let currentName = selectedProvider == "claude" ? "Claude Code" : "Codex CLI"
                let requestedName = provider == "claude" ? "Claude Code" : "Codex CLI"
                status.stringValue = "Finish or stop \(currentName) to open \(requestedName)."
                status.toolTip = "Finish or stop this \(providerLabel) reply before switching providers."
            }
            return
        }
        guard provider != selectedProvider else { return }
        histories[selectedProvider] = NSAttributedString(attributedString: conversation.textStorage ?? NSAttributedString())
        viewStates[selectedProvider] = ChatViewState(
            draft: input.string, draftSelections: input.selectedRanges,
            transcriptSelections: conversation.selectedRanges,
            transcriptScrollOrigin: conversation.enclosingScrollView?.contentView.bounds.origin ?? .zero
        )
        selectedProvider = provider
        providerPicker.selectItem(at: provider == "claude" ? 0 : 1)
        restoreConversation()
        let saved = viewStates[provider]
        input.string = saved?.draft ?? ""
        input.selectedRanges = clampedSelections(saved?.draftSelections ?? [], length: (input.string as NSString).length)
        conversation.selectedRanges = clampedSelections(saved?.transcriptSelections ?? [], length: conversation.textStorage?.length ?? 0)
        if let origin = saved?.transcriptScrollOrigin, let scroll = conversation.enclosingScrollView {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        input.undoManager?.removeAllActions()
        input.needsDisplay = true
        updateControls()
    }

    private func clampedSelections(_ selections: [NSValue], length: Int) -> [NSValue] {
        guard !selections.isEmpty else { return [NSValue(range: NSRange(location: 0, length: 0))] }
        return selections.map {
            let range = $0.rangeValue
            let location = min(range.location, length)
            return NSValue(range: NSRange(location: location, length: min(range.length, length - location)))
        }
    }

    @objc private func newConversation() {
        guard active == nil else { return }
        sessions.removeValue(forKey: selectedProvider); histories.removeValue(forKey: selectedProvider)
        workspaceIDs.removeValue(forKey: selectedProvider); titles.removeValue(forKey: selectedProvider)
        viewStates.removeValue(forKey: selectedProvider)
        input.string = ""; input.selectedRanges = [NSValue(range: NSRange(location: 0, length: 0))]
        input.undoManager?.removeAllActions(); input.needsDisplay = true
        restoreConversation()
        onActivity?(CompanionChatActivity(provider: selectedProvider, runID: UUID(), title: "", phase: .reset, reply: nil))
        updateControls()
    }

    private func infoPath(_ name: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: name) as? String, value.hasPrefix("/") else { return nil }
        return value
    }

    @objc private func send() {
        guard active == nil else { return }
        let message = input.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        guard message.utf8.count <= 200_000 else { status.stringValue = "Please shorten this message before sending."; return }
        guard let command = PipRuntime.chat(runtime: runtimeURL) else {
            status.stringValue = "Pip's chat runtime is unavailable. Reinstall Pip."; return
        }
        let run = ChatRun(provider: selectedProvider)
        let workspace = workspaceIDs[run.provider] ?? UUID()
        workspaceIDs[run.provider] = workspace
        run.title = titles[run.provider] ?? CompanionChatActivity.conversationTitle(message)
        run.process.executableURL = command.executable
        var arguments = command.arguments + ["--provider", run.provider, "--workspace-root", workspaceRoot.path, "--workspace-id", workspace.uuidString.lowercased()]
        if let session = sessions[run.provider] { arguments += ["--session", session] }
        if let claude = infoPath("CompanionClaudePath") { arguments += ["--claude-path", claude] }
        if let codex = infoPath("CompanionCodexPath") { arguments += ["--codex-path", codex] }
        run.process.arguments = arguments; run.process.currentDirectoryURL = runtimeURL
        run.process.standardOutput = run.output; run.process.standardError = run.errors; run.process.standardInput = run.input
        var environment = ProcessInfo.processInfo.environment
        environment["PET_RUNTIME_DIR"] = runtimeURL.path; environment["PYTHONUNBUFFERED"] = "1"
        run.process.environment = environment
        run.output.fileHandleForReading.readabilityHandler = { [weak self, weak run] handle in
            let data = handle.availableData
            guard let self, let run else { return }
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self.ioQueue.async { self.consume(data, run: run) }
        }
        run.errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            // Drain stderr to avoid blocking the bridge. Only its safe JSONL
            // error events are shown in the conversation.
        }
        run.process.terminationHandler = { [weak self, weak run] process in
            guard let self, let run else { return }
            self.ioQueue.async {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    guard self.active === run else { return }
                    if run.cancelled { self.finish(run, error: nil, stopped: true) }
                    else { self.finish(run, error: "The agent ended before returning a response (exit \(process.terminationStatus)).") }
                }
            }
        }
        do {
            let encoded = try JSONSerialization.data(withJSONObject: ["message": message]) + Data([10])
            try run.process.run()
            active = run
            titles[run.provider] = run.title
            append("\nYou\n", weight: .semibold); append(message + "\n\n")
            append(providerLabel + "\n", color: Palette.green, weight: .semibold)
            input.string = ""; input.needsDisplay = true
            status.stringValue = "\(providerLabel) is working…"; updateControls()
            onActivity?(CompanionChatActivity(provider: run.provider, runID: run.id, title: run.title, phase: .thinking, reply: nil))
            // Large user messages are written off the main thread so stdin cannot block the UI.
            ioQueue.async {
                do { try run.input.fileHandleForWriting.write(contentsOf: encoded); try run.input.fileHandleForWriting.close() }
                catch { DispatchQueue.main.async { if self.active === run { self.finish(run, error: error.localizedDescription) } } }
            }
        } catch {
            run.output.fileHandleForReading.readabilityHandler = nil
            run.errors.fileHandleForReading.readabilityHandler = nil
            run.process.terminationHandler = nil
            status.stringValue = "Could not start \(providerLabel): \(error.localizedDescription)"
        }
    }

    private func consume(_ data: Data, run: ChatRun) {
        run.buffer.append(data)
        guard run.buffer.count <= 2_000_000 else {
            DispatchQueue.main.async { if self.active === run { self.finish(run, error: "The agent returned an oversized response.") } }; return
        }
        while let newline = run.buffer.firstIndex(of: 10) {
            let line = run.buffer.prefix(upTo: newline)
            run.buffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            let text = event["text"] as? String ?? ""
            let session = event["sessionId"] as? String
            DispatchQueue.main.async {
                guard self.active === run, !run.cancelled else { return }
                switch type {
                case "delta":
                    self.append(text)
                    if !run.replyIsLong {
                        let combined = run.reply + text
                        if combined.count <= 240 { run.reply = combined }
                        else { run.replyIsLong = true; run.reply = "" }
                    }
                case "complete":
                    if let session, !session.isEmpty, session.utf8.count <= 512 { self.sessions[run.provider] = session }
                    self.finish(run, error: nil)
                case "error": self.finish(run, error: text.isEmpty ? "The agent could not respond." : text)
                default: break
                }
            }
        }
    }

    private func finish(_ run: ChatRun, error: String?, stopped: Bool = false) {
        guard active === run else { return }
        run.output.fileHandleForReading.readabilityHandler = nil; run.errors.fileHandleForReading.readabilityHandler = nil
        run.process.terminationHandler = nil
        // A terminal JSONL event may arrive just before Python exits. Terminate
        // any remaining bridge so closing Pip cannot leave its child behind.
        if run.process.isRunning { run.process.terminate() }
        if let error {
            append("\n\n" + error + "\n", color: .systemRed)
            status.stringValue = "Unable to complete · \(providerLabel)"
        } else if stopped {
            append("\n\nStopped.\n", color: Palette.secondary); status.stringValue = "Stopped · \(providerLabel)"
        } else { append("\n"); status.stringValue = "Ready · \(providerLabel)" }
        histories[run.provider] = NSAttributedString(attributedString: conversation.textStorage ?? NSAttributedString())
        onActivity?(CompanionChatActivity(provider: run.provider, runID: run.id, title: run.title,
                                          phase: stopped ? .stopped : (error == nil ? .completed : .failed),
                                          reply: run.replyIsLong ? nil : CompanionChatActivity.shortReply(run.reply)))
        active = nil; updateControls()
    }

    @objc func stop() {
        guard let run = active, !run.cancelled else { return }
        run.cancelled = true; status.stringValue = "Stopping…"; stopButton.isEnabled = false
        onActivity?(CompanionChatActivity(provider: run.provider, runID: run.id, title: run.title, phase: .stopped, reply: nil))
        if run.process.isRunning { run.process.terminate() } else { finish(run, error: nil, stopped: true) }
    }

    func shutdown() { stop() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { stop(); sender.orderOut(nil); return false }
    func textDidChange(_ notification: Notification) { input.needsDisplay = true; updateControls() }
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        if commandSelector == #selector(NSResponder.insertNewline(_:)),
           ChatInputPolicy.sendsNewline(modifiers: modifiers, hasMarkedText: textView.hasMarkedText()) {
            send(); return true
        }
        return false
    }
    private func updateControls() {
        let idle = active == nil
        sendButton?.isEnabled = idle && !(input?.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        stopButton?.isEnabled = !idle && active?.cancelled == false
        providerPicker?.isEnabled = idle; newButton?.isEnabled = idle
    }

    func preview(to destination: URL) throws {
        if panel == nil { createWindow() }
        append("\nYou\n", weight: .semibold); append("Can you explain what this project does?\n\n")
        append(providerLabel + "\n", color: Palette.green, weight: .semibold)
        append("Of course. Tell me what you want to explore, and I’ll help you work through it.\n")
        input.string = "What should we improve first?"; updateControls()
        status.stringValue = "DEMO · preview · no message sent"
        guard let body = panel?.contentView, let bitmap = body.bitmapImageRepForCachingDisplay(in: body.bounds) else {
            throw CompanionError.message("Cannot render chat preview.")
        }
        body.cacheDisplay(in: body.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CompanionError.message("Cannot encode chat preview.") }
        try png.write(to: destination, options: .atomic)
    }
}
