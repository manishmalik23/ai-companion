import AppKit
import Foundation

/// A status window never takes focus or intercepts a click intended for another app.
final class ConversationBubblePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum ConversationBubblePalette {
    static let surface = NSColor.windowBackgroundColor
    static let outline = NSColor.separatorColor.withAlphaComponent(0.42)
    static let foreground = NSColor.labelColor
    static let secondary = NSColor.secondaryLabelColor
    static let badge = NSColor.labelColor.withAlphaComponent(0.055)
}

/// Keep the speech pointer aimed at Pip even when the capsule reaches a screen edge.
struct ConversationBubblePlacement {
    enum Pointer { case bottom, top }
    let frame: NSRect
    let pointer: Pointer
    let pointerX: CGFloat

    static func fitting(size: NSSize, robot: NSRect, visibleFrame: NSRect) -> ConversationBubblePlacement {
        let available = visibleFrame.insetBy(dx: 8, dy: 8)
        let x = min(max(robot.midX - size.width / 2, available.minX), available.maxX - size.width)
        let above = robot.maxY + 2
        let below = robot.minY - size.height - 2
        let useBelow = above + size.height > available.maxY && below >= available.minY
        let y = min(max(useBelow ? below : above, available.minY), available.maxY - size.height)
        let pointerX = min(max(robot.midX - x, 34), size.width - 34)
        return ConversationBubblePlacement(frame: NSRect(x: x, y: y, width: size.width, height: size.height),
                                           pointer: useBelow ? .top : .bottom, pointerX: pointerX)
    }
}

/// The capsule owns only its display. Chat content and expiry stay in the pure state model.
final class ConversationBubbleView: NSView {
    private let heading = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var display: ConversationBubbleState.Display?
    private var signature: String?
    private var time: Double = 0
    private var reduceMotion = false
    private var pointer: ConversationBubblePlacement.Pointer = .bottom
    private var pointerX: CGFloat = 0
    private var body = NSRect.zero
    private var badge = NSRect.zero
    private var dotsOrigin = NSPoint.zero
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 236, height: 80))
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.textColor = ConversationBubblePalette.foreground
        heading.lineBreakMode = .byTruncatingTail; heading.maximumNumberOfLines = 1
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = ConversationBubblePalette.secondary
        detail.lineBreakMode = .byWordWrapping; detail.maximumNumberOfLines = 0
        for field in [heading, detail] {
            field.setAccessibilityElement(false)
            addSubview(field)
        }
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @discardableResult
    func configure(_ display: ConversationBubbleState.Display, now: Double = 0, reduceMotion: Bool = false) -> Bool {
        self.time = now; self.reduceMotion = reduceMotion
        let signature = "\(display.provider)\u{0}\(display.title)\u{0}\(display.detail)\u{0}\(display.thinking)"
        if self.signature != signature {
            self.signature = signature; self.display = display
            isHidden = false
            heading.stringValue = display.title.isEmpty ? ProviderApps.label(display.provider) : display.title
            detail.stringValue = display.thinking ? "Thinking" : display.detail
            detail.isHidden = !display.thinking && display.detail.isEmpty
            detail.textColor = display.thinking ? ConversationBubblePalette.secondary : ConversationBubblePalette.foreground
            let titleWidth = ceil((heading.stringValue as NSString).size(withAttributes: [.font: heading.font!]).width)
            if detail.isHidden {
                frame.size = NSSize(width: min(280, max(188, titleWidth + 86)), height: 64)
            } else if display.thinking {
                frame.size = NSSize(width: min(280, max(208, titleWidth + 86)), height: 80)
            } else {
                // Replies use a little more space than status, without growing into a chat window.
                let textWidth = ceil((detail.stringValue as NSString).size(withAttributes: [.font: detail.font!]).width)
                let width = min(280, max(230, min(textWidth + 42, 280), titleWidth + 86))
                let detailHeight = max(18, ceil((detail.stringValue as NSString).boundingRect(
                    with: NSSize(width: width - 42, height: 500), options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: detail.font!]).height))
                // A short character count can still mean many lines or wide Unicode glyphs.
                // Revert to Pip alone rather than clipping or summarizing a desktop reply.
                guard !display.detail.contains(where: { $0.isNewline }), textWidth <= width - 42, detailHeight <= 18 else {
                    self.display = nil; isHidden = true
                    heading.stringValue = ""; detail.stringValue = ""
                    setAccessibilityLabel(nil)
                    return false
                }
                frame.size = NSSize(width: width, height: detailHeight + 78)
            }
            let summary = display.thinking ? "Thinking" : display.detail
            setAccessibilityLabel(ProviderApps.label(display.provider) + ", " + heading.stringValue +
                                  (summary.isEmpty ? "" : ", " + summary))
            layoutContent()
        }
        guard !isHidden else { return false }
        needsDisplay = true
        return true
    }

    func pointTowardRobot(_ placement: ConversationBubblePlacement) {
        if pointer != placement.pointer || pointerX != placement.pointerX {
            pointer = placement.pointer; pointerX = placement.pointerX
            layoutContent(); needsDisplay = true
        }
    }

    private func layoutContent() {
        guard let display else { return }
        let top: CGFloat = pointer == .top ? 12 : 6
        body = NSRect(x: 6, y: top, width: bounds.width - 12, height: bounds.height - 18)
        let titleOnly = !display.thinking && display.detail.isEmpty
        let badgeSize: CGFloat = titleOnly ? 28 : display.thinking ? 30 : 26
        badge = NSRect(x: body.minX + 12, y: titleOnly ? body.midY - badgeSize / 2 : body.minY + 13,
                       width: badgeSize, height: badgeSize)
        heading.frame = NSRect(x: badge.maxX + 9, y: body.minY + 13, width: body.maxX - badge.maxX - 23, height: 16)
        if titleOnly {
            heading.frame.origin.y = body.midY - 8
            detail.frame = .zero
        } else if display.thinking {
            detail.frame = NSRect(x: heading.frame.minX, y: body.minY + 33, width: 56, height: 16)
            dotsOrigin = NSPoint(x: detail.frame.maxX + 7, y: detail.frame.midY + 1)
        } else {
            // The reply is on its own row, so the circular badge never squeezes its text.
            heading.frame.origin.y = body.minY + 18
            detail.frame = NSRect(x: body.minX + 15, y: body.minY + 48, width: body.width - 30,
                                 height: max(18, body.height - 55))
        }
    }

    private func drawPointer(fill: NSColor, outline: NSColor) {
        let x = pointerX == 0 ? bounds.midX : pointerX
        let edge = pointer == .bottom ? body.maxY : body.minY
        let direction: CGFloat = pointer == .bottom ? 1 : -1
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: x - 6, y: edge - direction * 0.75))
        tail.curve(to: NSPoint(x: x, y: edge + direction * 6),
                   controlPoint1: NSPoint(x: x - 4, y: edge + direction * 1),
                   controlPoint2: NSPoint(x: x - 2, y: edge + direction * 5))
        tail.curve(to: NSPoint(x: x + 6, y: edge - direction * 0.75),
                   controlPoint1: NSPoint(x: x + 2, y: edge + direction * 5),
                   controlPoint2: NSPoint(x: x + 4, y: edge + direction * 1))
        fill.setFill(); tail.fill()
        outline.setStroke(); tail.lineWidth = 0.75; tail.stroke()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let display else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.current?.cgContext.clear(dirtyRect)
            let capsule = NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), xRadius: display.thinking ? 28 : 24,
                                      yRadius: display.thinking ? 28 : 24)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
            shadow.shadowBlurRadius = 6; shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set(); ConversationBubblePalette.surface.setFill(); capsule.fill()
            NSGraphicsContext.restoreGraphicsState()
            ConversationBubblePalette.outline.setStroke(); capsule.lineWidth = 0.75; capsule.stroke()
            drawPointer(fill: ConversationBubblePalette.surface, outline: ConversationBubblePalette.outline)

            ConversationBubblePalette.badge.setFill(); NSBezierPath(ovalIn: badge).fill()
            let symbol = display.provider == "claude" ? "sparkles" : "bubble.left.and.bubble.right"
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(paletteColors: [ConversationBubblePalette.foreground])) {
                let destination = badge.insetBy(dx: 7, dy: 7)
                image.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 0.8, respectFlipped: true, hints: nil)
            }
            if display.thinking {
                // A slow travelling pulse, rather than fast blinking eyes or jumping text.
                for index in 0..<3 {
                    let phase = time * 2 * .pi / 1.8 - Double(index) * 0.65
                    let emphasis = reduceMotion ? 0.65 : 0.45 + 0.35 * (sin(phase) + 1) / 2
                    ConversationBubblePalette.secondary.withAlphaComponent(emphasis).setFill()
                    NSBezierPath(ovalIn: NSRect(x: dotsOrigin.x + CGFloat(index) * 7, y: dotsOrigin.y - 2,
                                               width: 4, height: 4)).fill()
                }
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true; heading.needsDisplay = true; detail.needsDisplay = true
    }
}

final class ConversationBubbleController {
    private var state = ConversationBubbleState()
    private var panel: ConversationBubblePanel?
    private let content = ConversationBubbleView()
    private var hiding = false
    private var transition = 0

    func receive(_ activity: CompanionChatActivity, now: Double) { state.receive(activity, now: now) }
    func opened(provider: String, now: Double) { state.opened(provider: provider, now: now) }
    func disconnectDesktop() { state.disconnectDesktop(); if state.display == nil { hide() } }
    func hide() { transition += 1; hiding = false; panel?.orderOut(nil); panel?.alphaValue = 1 }

    private func fadeOut(reduceMotion: Bool) {
        guard let panel, panel.isVisible, !hiding else { return }
        guard !reduceMotion else { hide(); return }
        hiding = true; transition += 1
        let token = transition
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14; panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.transition == token else { return }
            self.hide()
        })
    }

    func refresh(anchor: NSWindow, pet: NSView, permissionActive: Bool, now: Double) {
        state.expire(now: now)
        // An approval card must remain the only floating prompt, including during animations.
        guard !permissionActive, anchor.isVisible else { hide(); return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard let display = state.display else { fadeOut(reduceMotion: reduceMotion); return }
        guard content.configure(display, now: now, reduceMotion: reduceMotion) else { hide(); return }
        if panel == nil {
            let window = ConversationBubblePanel(contentRect: content.frame, styleMask: [.borderless, .nonactivatingPanel],
                                                  backing: .buffered, defer: false)
            window.contentView = content; window.isOpaque = false; window.backgroundColor = .clear
            window.hasShadow = false; window.ignoresMouseEvents = true; window.hidesOnDeactivate = false
            window.level = .floating; window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false; window.title = "Pip conversation status"
            panel = window
        }
        guard let panel else { return }
        let robot = anchor.convertToScreen(pet.convert(pet.bounds, to: nil))
        let visible = (anchor.screen ?? NSScreen.main)?.visibleFrame ?? anchor.frame.insetBy(dx: -500, dy: -500)
        let placement = ConversationBubblePlacement.fitting(size: content.frame.size, robot: robot, visibleFrame: visible)
        content.pointTowardRobot(placement)
        if panel.frame != placement.frame { panel.setFrame(placement.frame, display: true) }
        if hiding { transition += 1; hiding = false; panel.alphaValue = 1 }
        if !panel.isVisible {
            transition += 1
            panel.alphaValue = reduceMotion ? 1 : 0
            panel.orderFrontRegardless()
            if !reduceMotion {
                NSAnimationContext.runAnimationGroup { context in context.duration = 0.16; panel.animator().alphaValue = 1 }
            }
        }
    }
}
