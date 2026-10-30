import AppKit

private func measuredHeight(_ text: String, width: CGFloat, font: NSFont) -> CGFloat {
    ceil((text as NSString).boundingRect(with: NSSize(width: width, height: 100_000),
          options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height) + 4
}

private final class QuestionAnswerField: NSTextField {
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func focusForAnswer() {
        guard let window else { return }
        // Take typing focus only after the user chooses to edit an answer.
        // The companion normally stays visible without activating its app.
        NSApp.activate(ignoringOtherApps: true)
        focusEditor(in: window)
        // App activation and the originating radio-button click finish after
        // the action returns. Restore the editor once that event is dispatched.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window, window.isVisible else { return }
            self.focusEditor(in: window)
        }
    }

    private func focusEditor(in window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        if currentEditor() == nil || window.firstResponder !== currentEditor() {
            window.makeFirstResponder(self)
        }
        scrollToVisible(bounds)
    }

    override func mouseDown(with event: NSEvent) {
        focusForAnswer()
        super.mouseDown(with: event)
    }
}

final class QuestionSection: NSView, NSTextFieldDelegate {
    let question: UserQuestion
    private var choices: [NSButton] = []
    private let other = NSButton()
    private let text = QuestionAnswerField()
    var onChange: (() -> Void)?
    override var isFlipped: Bool { true }

    init(question: UserQuestion, index: Int, width: CGFloat) {
        self.question = question
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        var y: CGFloat = 12
        let header = question.header?.isEmpty == false ? question.header! : "Question \(index + 1)"
        addSubview(label("\(index + 1). \(header.uppercased())", NSRect(x: 12, y: y, width: width - 24, height: 18),
                         size: 10, weight: .semibold, color: Palette.green))
        y += 25
        let titleHeight = measuredHeight(question.question, width: width - 24, font: .systemFont(ofSize: 14, weight: .semibold))
        addSubview(label(question.question, NSRect(x: 12, y: y, width: width - 24, height: titleHeight), size: 14, weight: .semibold, selectable: true))
        y += titleHeight + 7
        addSubview(label(question.allowsMultiple ? "Choose all that apply" : "Choose one answer",
                         NSRect(x: 12, y: y, width: width - 24, height: 17), size: 11, color: Palette.secondary))
        y += 25
        for (optionIndex, option) in question.options.enumerated() {
            let button = NSButton(title: option.label, target: self, action: #selector(choiceChanged(_:)))
            button.setButtonType(question.allowsMultiple ? .switch : .radio)
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.tag = optionIndex; button.cell?.wraps = true; button.cell?.usesSingleLineMode = false
            let optionHeight = max(24, measuredHeight(option.label, width: width - 51, font: button.font!))
            button.frame = NSRect(x: 12, y: y, width: width - 24, height: optionHeight)
            button.setAccessibilityLabel(option.label); addSubview(button); choices.append(button)
            y += optionHeight
            if let description = option.description, !description.isEmpty {
                let height = measuredHeight(description, width: width - 48, font: .systemFont(ofSize: 11))
                addSubview(label(description, NSRect(x: 34, y: y, width: width - 48, height: height), size: 11, color: Palette.secondary))
                y += height
            }
            y += 11
        }
        other.title = "Other"; other.target = self; other.action = #selector(otherChanged)
        other.setButtonType(question.allowsMultiple ? .switch : .radio)
        other.font = .systemFont(ofSize: 13, weight: .medium)
        other.frame = NSRect(x: 12, y: y, width: width - 24, height: 24); addSubview(other)
        y += 31
        text.frame = NSRect(x: 34, y: y, width: width - 48, height: 34)
        text.placeholderString = "Write your own answer"; text.font = .systemFont(ofSize: 13)
        text.isEditable = true; text.isSelectable = true; text.delegate = self
        text.textColor = Palette.ink; text.backgroundColor = NSColor.textBackgroundColor
        text.drawsBackground = true; text.focusRingType = .default
        text.placeholderAttributedString = NSAttributedString(string: "Write your own answer", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor
        ])
        text.setAccessibilityLabel("Other answer for " + question.question); addSubview(text)
        y += 49
        let separator = NSBox(frame: NSRect(x: 12, y: y, width: width - 24, height: 1))
        separator.boxType = .separator; addSubview(separator); y += 10
        frame.size.height = y
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        text.textColor = Palette.ink
        text.backgroundColor = NSColor.textBackgroundColor
        text.needsDisplay = true
        choices.forEach { $0.needsDisplay = true }
        other.needsDisplay = true
        needsDisplay = true
    }

    var answer: String? {
        var selected = choices.enumerated().filter { $0.element.state == .on }.map { question.options[$0.offset].label }
        if other.state == .on {
            let value = text.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            selected.append(value)
        }
        guard !selected.isEmpty, question.allowsMultiple || selected.count == 1 else { return nil }
        return selected.joined(separator: ", ")
    }

    @objc private func choiceChanged(_ sender: NSButton) {
        if !question.allowsMultiple {
            choices.forEach { $0.state = $0 === sender ? .on : .off }
            other.state = .off
        }
        onChange?()
    }

    @objc private func otherChanged() {
        if !question.allowsMultiple { choices.forEach { $0.state = .off }; other.state = .on }
        if other.state == .on { text.focusForAnswer() }
        onChange?()
    }

    func controlTextDidChange(_ obj: Notification) {
        if !text.stringValue.isEmpty {
            other.state = .on
            if !question.allowsMultiple { choices.forEach { $0.state = .off } }
        }
        onChange?()
    }
}

final class QuestionForm: NSView {
    private let request: PermissionRequest
    private var sections: [QuestionSection] = []
    var onChange: (() -> Void)?
    override var isFlipped: Bool { true }

    init(request: PermissionRequest, width: CGFloat) {
        self.request = request
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        var y: CGFloat = 0
        for (index, question) in (request.questions ?? []).enumerated() {
            let section = QuestionSection(question: question, index: index, width: width)
            section.frame.origin.y = y
            section.onChange = { [weak self] in self?.onChange?() }
            addSubview(section); sections.append(section); y += section.frame.height
        }
        let context = "\(request.sourceLabel) · \(request.cwd)"
        let contextHeight = measuredHeight(context, width: width - 24, font: .systemFont(ofSize: 10))
        addSubview(label(context, NSRect(x: 12, y: y + 8, width: width - 24, height: contextHeight), size: 10, color: Palette.secondary, selectable: true))
        frame.size.height = y + contextHeight + 24
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var answers: [String: String]? {
        var values: [String: String] = [:]
        for section in sections {
            guard let answer = section.answer else { return nil }
            values[section.question.question] = answer
        }
        return request.acceptsAnswers(values) ? values : nil
    }

    var hasOversizedAnswer: Bool {
        sections.compactMap { $0.answer }.reduce(0, { $0 + $1.utf8.count }) > 2_000
    }
}
