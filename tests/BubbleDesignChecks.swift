import AppKit
import Foundation

private final class FixtureRobotView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if let context = NSGraphicsContext.current?.cgContext { RobotArt.draw(in: context, bounds: bounds, mood: "working", phase: 0) }
    }
}
private final class BubbleCanvas: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.underPageBackgroundColor.setFill(); bounds.fill()
        }
    }
}

@main struct BubbleDesignChecks {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        _ = RobotArt.useSpriteSheet(at: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("desktop/Resources/PipSpriteSheet.png"))
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/bubble-design-previews")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "BubbleDesign", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1; print("PASS", message)
        }
        func pixels(_ view: NSView) throws -> NSBitmapImageRep {
            guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw NSError(domain: "BubbleDesign", code: 2) }
            view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: image) }
            return image
        }
        func write(_ image: NSBitmapImageRep, _ name: String) throws {
            let path = root.appendingPathComponent(name + ".png")
            try image.representation(using: .png, properties: [:])!.write(to: path)
            print("PREVIEW", path.path)
        }
        let panel = ConversationBubblePanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        try check(!panel.canBecomeKey && !panel.canBecomeMain, "Status capsule cannot become a key or main window")
        let light = NSAppearance(named: .aqua)!, dark = NSAppearance(named: .darkAqua)!
        func color(_ value: NSColor, _ appearance: NSAppearance) -> NSColor {
            var result: NSColor!
            appearance.performAsCurrentDrawingAppearance { result = value.usingColorSpace(.deviceRGB)! }
            return result
        }
        let lightSurface = color(ConversationBubblePalette.surface, light), darkSurface = color(ConversationBubblePalette.surface, dark)
        try check(lightSurface.redComponent > darkSurface.redComponent + 0.3, "Capsule surface follows system light and dark appearance")
        try check(color(ConversationBubblePalette.foreground, light).redComponent < color(ConversationBubblePalette.foreground, dark).redComponent, "Capsule text follows system foreground")
        let fittingCheck = ConversationBubbleView()
        let normalReply = ConversationBubbleState.Display(provider: "claude", title: "A new reply", detail: "Hello! What would you like to work on?", thinking: false)
        try check(fittingCheck.configure(normalReply) && !fittingCheck.isHidden, "A complete short reply remains visible")
        for (name, reply) in [("CJK", String(repeating: "明日の旅行について考えましょう", count: 15)),
                              ("wrapped-line", String(repeating: "A thoughtful response. ", count: 10)),
                              ("two-lines", "Hello\nHow are you?"),
                              ("newline-rich", String(repeating: "Hi\n", count: 60))] {
            try check(reply.count <= 240, "\(name) clipping fixture is within the short-reply character limit")
            let oversized = ConversationBubbleState.Display(provider: "claude", title: "A new reply", detail: reply, thinking: false)
            try check(!fittingCheck.configure(oversized) && fittingCheck.isHidden, "\(name) reply reverts to Pip alone instead of clipping")
            try check(!fittingCheck.configure(oversized) && fittingCheck.isHidden, "\(name) rejection remains hidden on the next refresh")
            try check(fittingCheck.subviews.compactMap { $0 as? NSTextField }.allSatisfy { $0.stringValue.isEmpty }, "\(name) hidden capsule retains no stale displayed reply")
            try check(fittingCheck.configure(normalReply) && !fittingCheck.isHidden, "\(name) rejection does not suppress a later complete short reply")
        }
        try check(fittingCheck.configure(.init(provider: "codex", title: "Still working", detail: "Thinking…", thinking: true)) && !fittingCheck.isHidden,
                  "Thinking remains visible after an oversized reply")
        let fixtures: [(String, ConversationBubbleState.Display)] = [
            ("claude-connected", .init(provider: "claude", title: "Fresh conversation", detail: "", thinking: false)),
            ("claude-thinking", .init(provider: "claude", title: "A fresh conversation", detail: "Claude · Thinking…", thinking: true)),
            ("chatgpt-thinking", .init(provider: "codex", title: "Ideas for a weekend in the mountains", detail: "ChatGPT · Thinking…", thinking: true)),
            ("claude-reply", .init(provider: "claude", title: "A fresh conversation", detail: "Hello! What would you like to work on?", thinking: false)),
            ("chatgpt-reply", .init(provider: "codex", title: "Ideas for a weekend in the mountains", detail: "A quiet morning hike sounds good.", thinking: false)),
            ("long-title-short-reply", .init(provider: "claude", title: String(repeating: "A long conversation title ", count: 2), detail: "That sounds good.", thinking: false)),
        ]
        for (theme, appearance) in [("light", light), ("dark", dark)] {
            for (name, display) in fixtures {
                let canvas = BubbleCanvas(frame: NSRect(x: 0, y: 0, width: 320, height: 350))
                canvas.appearance = appearance
                let view = ConversationBubbleView()
                view.configure(display, now: 0.7, reduceMotion: false)
                view.frame.origin = NSPoint(x: (canvas.bounds.width - view.frame.width) / 2, y: 15)
                canvas.addSubview(view)
                let robot = FixtureRobotView(frame: NSRect(x: 96, y: view.frame.maxY - 3, width: 128, height: 156))
                canvas.addSubview(robot)
                panel.contentView = canvas
                try check(view.frame.width <= 280 && view.frame.height <= 198, "\(theme) \(name) remains compact")
                try check(view.hitTest(NSPoint(x: 40, y: 40)) == nil, "\(theme) \(name) passes desktop clicks through")
                try check(view.accessibilityLabel()?.contains(ProviderApps.label(display.provider)) == true, "\(theme) \(name) exposes provider to accessibility")
                let fields = view.subviews.compactMap { $0 as? NSTextField }
                try check(fields.count == 2 && fields.allSatisfy { view.bounds.contains($0.frame) }, "\(theme) \(name) text fits capsule bounds")
                let heading = fields[0], detail = fields[1]
                try check(heading.maximumNumberOfLines == 1 && heading.lineBreakMode == .byTruncatingTail, "\(theme) \(name) truncates long titles")
                if !display.thinking && display.detail.isEmpty { try check(detail.isHidden && view.frame.height == 64, "Title-only desktop status stays a compact pill") }
                if display.thinking { try check(detail.stringValue == "Thinking", "\(theme) \(name) separates title and live thinking status") }
                let capsule = try pixels(view)
                try check(capsule.colorAt(x: 0, y: 0)?.alphaComponent == 0, "\(theme) \(name) has transparent rounded exterior")
                try write(try pixels(canvas), theme + "-" + name)
                if display.thinking {
                    view.configure(display, now: 1.7, reduceMotion: false)
                    let animated = try pixels(view)
                    try check(capsule.bitmapData != nil && animated.bitmapData != nil && capsule.representation(using: .png, properties: [:]) != animated.representation(using: .png, properties: [:]), "\(theme) \(name) animates three thinking dots")
                    view.configure(display, now: 0.7, reduceMotion: true)
                    let reducedOne = try pixels(view)
                    view.configure(display, now: 1.7, reduceMotion: true)
                    let reducedTwo = try pixels(view)
                    try check(reducedOne.representation(using: .png, properties: [:]) == reducedTwo.representation(using: .png, properties: [:]), "\(theme) \(name) respects reduced motion")
                }
                let originalSubviews = view.subviews.map { ObjectIdentifier($0) }
                view.appearance = theme == "light" ? dark : light
                view.viewDidChangeEffectiveAppearance()
                try check(view.subviews.map { ObjectIdentifier($0) } == originalSubviews, "\(theme) \(name) appearance changes reuse text views")
            }
            let below = ConversationBubbleView()
            below.configure(.init(provider: "codex", title: "A reply near the top of the screen", detail: "Yes, that works. Let's continue.", thinking: false))
            below.appearance = appearance
            below.pointTowardRobot(.init(frame: below.frame, pointer: .top, pointerX: below.frame.midX))
            try write(try pixels(below), theme + "-top-pointer")
            try check(below.subviews.compactMap { $0 as? NSTextField }.allSatisfy { below.bounds.contains($0.frame) },
                      "\(theme) reversed pointer keeps reply text inside capsule")
        }
        let screen = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let size = NSSize(width: 280, height: 140)
        let robots = [NSRect(x: 20, y: 30, width: 128, height: 150), NSRect(x: 1050, y: 30, width: 128, height: 150), NSRect(x: 500, y: 640, width: 128, height: 150), NSRect(x: 500, y: 400, width: 128, height: 150)]
        for (index, robot) in robots.enumerated() {
            let position = ConversationBubblePlacement.fitting(size: size, robot: robot, visibleFrame: screen)
            try check(screen.insetBy(dx: 8, dy: 8).contains(position.frame), "Placement \(index) remains inside visible screen")
            try check(position.pointerX >= 34 && position.pointerX <= size.width - 34, "Placement \(index) pointer stays outside rounded corners")
            try check(!position.frame.intersects(robot), "Placement \(index) avoids covering Pip")
            if index == 2 { try check(position.pointer == .top, "Top-edge Pip places capsule below and reverses speech pointer") }
        }
        print("Bubble design checks passed:", checks, "offscreen checks. No desktop app automation, real chat calls, window ordering, or system appearance changes.")
    }
}
