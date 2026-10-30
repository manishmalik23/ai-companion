import AppKit
import Foundation

// Minimal view fixtures. The question controls and answer validation are the
// production implementations, with a nonactivating panel like Pip's companion.
enum Palette {
    static let green = NSColor.controlAccentColor
    static let secondary = NSColor.secondaryLabelColor
    static let ink = NSColor.labelColor
}

func label(_ value: String, _ frame: NSRect, size: CGFloat = 13,
           weight: NSFont.Weight = .regular, color: NSColor = Palette.ink,
           selectable: Bool = false) -> NSTextField {
    let field = NSTextField(labelWithString: value)
    field.frame = frame; field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color; field.isSelectable = selectable
    field.lineBreakMode = .byWordWrapping; field.maximumNumberOfLines = 0
    return field
}

private final class QuestionTestPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@main struct QuestionFocusChecks {
    static func main() {
        do { try run() }
        catch { fputs("FAIL \(error.localizedDescription)\n", stderr); exit(1) }
    }

    static func run() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        var count = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "QuestionFocusChecks", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
            count += 1; print("PASS", message)
        }
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        let question = UserQuestion(question: "Which approach?", header: "Approach",
            options: [QuestionOption(label: "First", description: "A built-in option"),
                      QuestionOption(label: "Second", description: "Another built-in option")], multiSelect: false)
        let panel = QuestionTestPanel(contentRect: NSRect(x: 30, y: 30, width: 394, height: 160),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 394, height: 160))
        scroll.hasVerticalScroller = true
        let section = QuestionSection(question: question, index: 0, width: 376)
        scroll.documentView = section; panel.contentView = scroll
        let controls = descendants(section)
        let other = controls.compactMap { $0 as? NSButton }.first { $0.title == "Other" }!
        let first = controls.compactMap { $0 as? NSButton }.first { $0.title == "First" }!
        let input = controls.compactMap { $0 as? NSTextField }.first { $0.isEditable }!
        panel.orderFrontRegardless()
        panel.resignKey()
        try check(!panel.isKeyWindow, "A question does not initially take keyboard focus")
        other.performClick(nil)
        let deadline = Date().addingTimeInterval(2)
        repeat {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01),
                                          inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } while (!panel.isKeyWindow || input.currentEditor() == nil) && Date() < deadline
        try check(panel.isKeyWindow, "Selecting Other gives the nonactivating panel keyboard focus")
        try check(input.currentEditor() != nil, "Other starts the answer field editor")
        try check(input.visibleRect.height >= input.bounds.height - 1, "Other scrolls the whole input field into view")
        try check(section.answer == nil, "An empty custom answer cannot submit")
        let editor = input.currentEditor() as! NSTextView
        editor.insertText("Use my custom approach", replacementRange: NSRange(location: 0, length: 0))
        try check(section.answer == "Use my custom approach", "Text entered through the field editor becomes the custom answer")
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        other.performClick(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        try check(editor.selectedRange() == NSRange(location: 4, length: 0), "Restoring keyboard focus preserves the editing cursor")
        first.performClick(nil)
        try check(section.answer == "First", "Choosing a preset excludes the custom answer")
        other.performClick(nil)
        try check(section.answer == "Use my custom approach", "Switching back to Other preserves the typed draft")
        section.appearance = NSAppearance(named: .darkAqua)
        section.viewDidChangeEffectiveAppearance()
        try check(section.answer == "Use my custom approach", "Appearance changes preserve the custom answer")
        try check(panel.styleMask.contains(.nonactivatingPanel) && !panel.canBecomeMain,
                  "Editing keeps the companion's nonactivating panel behavior")
        print("Question input checks passed:", count)
    }
}
