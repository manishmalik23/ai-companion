import AppKit

private final class SetupBackground: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
}

final class SetupController: NSObject {
    let window: NSWindow
    private let helper: URL
    private let installed: Bool
    private let preview: Bool
    private var busy = false
    private var rows: [String: (NSTextField, NSButton)] = [:]
    private var connected: [String: Bool] = [:]
    private var lastStatus: [String: Any]?
    private let message = NSTextField(wrappingLabelWithString: "Checking your connections…")
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    var onChange: ((String) -> Void)?

    init(helper: URL, installed: Bool, preview: Bool = false) {
        self.helper = helper; self.installed = installed; self.preview = preview
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: installed ? 570 : 630),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Pip · Agent connections"; window.isReleasedWhenClosed = false
        window.center()
        let root = SetupBackground(); window.contentView = root
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -30),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 28)
        ])
        func text(_ value: String, size: CGFloat = 13, color: NSColor = .labelColor) -> NSTextField {
            let label = NSTextField(wrappingLabelWithString: value)
            label.font = .systemFont(ofSize: size); label.textColor = color
            label.setContentCompressionResistancePriority(.required, for: .vertical)
            return label
        }
        let eyebrow = text("PIP  /  YOUR AGENTS, TOGETHER", size: 11, color: .secondaryLabelColor)
        stack.addArrangedSubview(eyebrow)
        let heading = text("Connect your coding agents", size: 27)
        heading.font = .systemFont(ofSize: 27, weight: .semibold); stack.addArrangedSubview(heading)
        stack.addArrangedSubview(text("Keep approvals and activity within reach. Pip connects to the tools you already use on this Mac.", size: 14, color: .secondaryLabelColor))
        if !installed {
            let notice = text("Move Pip to Applications first, then reopen it to connect your agents.", size: 13, color: .systemOrange)
            stack.addArrangedSubview(notice)
        }
        for (id, title, detail) in [("claude", "Claude Code", "Terminal and its VS Code extension"),
                                     ("codex", "Codex", "Supported local CLI and editor sessions")] {
            let card = NSBox(); card.boxType = .custom; card.cornerRadius = 14
            card.borderWidth = 1; card.borderColor = .separatorColor; card.fillColor = .controlBackgroundColor
            card.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            card.heightAnchor.constraint(equalToConstant: 100).isActive = true
            let titleLabel = text(title, size: 17); titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
            let subtitle = text(detail, size: 12, color: .secondaryLabelColor)
            let state = text("Checking…", size: 12, color: .secondaryLabelColor)
            let labels = NSStackView(views: [titleLabel, subtitle, state]); labels.orientation = .vertical
            labels.alignment = .leading; labels.spacing = 4
            let button = NSButton(title: "Connect", target: self, action: #selector(connect(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(id); button.bezelStyle = .rounded
            button.setAccessibilityLabel("Connect " + title); button.isEnabled = false
            let body = card.contentView!; body.addSubview(labels); body.addSubview(button)
            labels.translatesAutoresizingMaskIntoConstraints = false; button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                labels.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16),
                labels.centerYAnchor.constraint(equalTo: body.centerYAnchor),
                button.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -16),
                button.centerYAnchor.constraint(equalTo: body.centerYAnchor),
                labels.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -12)
            ])
            rows[id] = (state, button)
        }
        stack.addArrangedSubview(text("Pip preserves your existing settings and creates backups. Your agent keeps its permission rules and sign-in. Accessibility is optional for desktop chat reading.", size: 12, color: .secondaryLabelColor))
        message.font = .systemFont(ofSize: 12); message.textColor = .secondaryLabelColor
        message.setContentCompressionResistancePriority(.required, for: .vertical)
        stack.addArrangedSubview(message)
        refreshButton.bezelStyle = .rounded
        refreshButton.target = self; refreshButton.action = #selector(refresh)
        let done = NSButton(title: "Done", target: self, action: #selector(close)); done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let footer = NSStackView(views: [refreshButton, done]); footer.spacing = 12
        stack.addArrangedSubview(footer)
        if preview {
            update(["providers": [["id": "claude", "detected": true, "connected": false],
                                    ["id": "codex", "detected": true, "connected": false]]])
        } else { refresh() }
    }

    func show() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func close() { window.close() }

    @objc private func refresh() {
        guard !busy else { return }
        perform(["status"]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value): self.update(value)
            case .failure(let error): self.message.stringValue = error.localizedDescription
            }
        }
    }

    private func update(_ value: [String: Any]) {
        guard let providers = value["providers"] as? [[String: Any]] else { return }
        lastStatus = value
        for provider in providers {
            guard let id = provider["id"] as? String, let (label, button) = rows[id] else { continue }
            let ready = provider["connected"] as? Bool == true
            connected[id] = ready
            label.stringValue = ready ? "Connected · Host hook trust still applies" :
                (provider["detected"] as? Bool == true ? "Detected on this Mac" : "Not detected · Install and sign in first")
            label.textColor = ready ? .systemGreen : .secondaryLabelColor
            button.title = ready ? "Disconnect" : "Connect"
            button.setAccessibilityLabel(button.title + " " + (id == "claude" ? "Claude Code" : "Codex"))
            button.isEnabled = installed && !busy && (ready || provider["detected"] as? Bool == true)
        }
        message.stringValue = "After connecting, review Pip in Codex /hooks. Reload or restart Claude Code after its current action finishes."
    }

    @objc private func connect(_ sender: NSButton) {
        guard !busy, installed, !preview, let provider = sender.identifier?.rawValue else { return }
        let disconnect = connected[provider] == true
        perform(["prepare", "--provider", provider, "--operation", disconnect ? "disconnect" : "connect"]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): self.message.stringValue = error.localizedDescription
            case .success(let plan):
                guard let id = plan["id"] as? String, let path = plan["settings"] as? String else { return }
                let name = provider == "claude" ? "Claude Code" : "Codex"
                let alert = NSAlert()
                alert.messageText = (disconnect ? "Disconnect " : "Connect ") + name + "?"
                alert.informativeText = (disconnect ? "Remove only Pip's connection from:\n" : "Add Pip's local hooks to:\n") + path +
                    "\n\nExisting settings are preserved and backed up. " +
                    (!disconnect && provider == "claude" ? "Local approval sync is enabled without exporting prompt or reply content. " : "") +
                    "Your agent's permission rules and hook trust stay in place. Finish any current action before reloading your agent."
                alert.addButton(withTitle: disconnect ? "Disconnect" : "Connect"); alert.addButton(withTitle: "Cancel")
                alert.beginSheetModal(for: self.window) { response in
                    guard response == .alertFirstButtonReturn else { return }
                    self.perform(["apply", "--plan", id]) { result in
                        switch result {
                        case .failure(let error): self.message.stringValue = error.localizedDescription
                        case .success:
                            self.onChange?(provider); self.refresh()
                        }
                    }
                }
            }
        }
    }

    private func perform(_ arguments: [String], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        busy = true; refreshButton.isEnabled = false
        for (_, button) in rows.values { button.isEnabled = false }
        message.stringValue = "Updating connection status…"
        let executable = helper
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process(), output = Pipe()
            process.executableURL = executable; process.arguments = ["connections"] + arguments
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            let result: Result<[String: Any], Error>
            do {
                try process.run()
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: deadline)
                let bytes = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit(); deadline.cancel()
                guard bytes.count < 65_536, let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                    throw NSError(domain: "PipSetup", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pip could not read its connection status."])
                }
                if process.terminationStatus != 0 {
                    throw NSError(domain: "PipSetup", code: 2, userInfo: [NSLocalizedDescriptionKey: value["error"] as? String ?? "Connection setup could not finish."])
                }
                result = .success(value)
            } catch { result = .failure(error) }
            DispatchQueue.main.async { [weak self] in
                self?.busy = false; self?.refreshButton.isEnabled = true
                if let value = self?.lastStatus { self?.update(value) }
                completion(result)
            }
        }
    }

    func renderPreview(to path: String) throws {
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
