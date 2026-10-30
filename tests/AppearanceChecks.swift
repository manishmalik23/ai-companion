import AppKit
import Foundation
import ImageIO
import Darwin

@main
struct AppearanceChecks {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pip-appearance-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root); RobotArt.setCharacter(nil) }
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        func rejects(_ operation: () throws -> Void) {
            do { try operation(); preconditionFailure("Invalid character/storage accepted") } catch { checks += 1 }
        }
        func png(width: Int, height: Int) -> Data {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.1, green: 0.65, blue: 0.5, alpha: 1))
            context.fillEllipse(in: CGRect(x: width / 8, y: height / 8, width: width * 3 / 4, height: height * 3 / 4))
            let bytes = NSMutableData()
            let destination = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            precondition(CGImageDestinationFinalize(destination)); return bytes as Data
        }
        let image = png(width: 64, height: 96)
        let resources = URL(fileURLWithPath: "desktop/Resources/Characters", isDirectory: true).standardizedFileURL
        let source = root.appendingPathComponent("My companion.png")
        try image.write(to: source)
        let store = try CharacterStore(runtime: root)
        check(try store.load() == nil, "Default is used before importing a character")
        let profile = try store.imported(from: source, kind: .still)
        check(profile.image == image && profile.name == "My companion.png", "Selected image is copied unchanged")
        check(profile.kind == .still, "Still images have explicit format metadata")
        check(try store.load() == nil, "Preview does not save before Use character")
        try store.save(profile)
        let loaded = try CharacterStore(runtime: root).load()!
        check(loaded.image == image && loaded.kind == .still, "Character survives recreating its store")
        let legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
        check(legacy["builtinID"] == nil && loaded.builtinID == nil,
              "Existing version-one custom profiles remain valid without a built-in identifier")
        let saved = store.directory.appendingPathComponent("character.json")
        var info = stat(); check(lstat(saved.path, &info) == 0 && info.st_mode & 0o077 == 0, "Saved character is private")
        rejects { _ = try RobotArt.character(data: Data("not an image".utf8), kind: .still) }
        rejects { _ = try RobotArt.character(data: Data(repeating: 0, count: 10 * 1024 * 1024 + 1), kind: .still) }
        rejects { _ = try RobotArt.character(data: image, kind: .sprite) }
        rejects { _ = try RobotArt.character(data: png(width: 4097, height: 1), kind: .still) }
        rejects { try store.save(CharacterProfile(version: 2, name: "Bad", kind: .still, image: image)) }
        check(try store.load()!.image == image, "A rejected import cannot replace the saved character")
        let spriteData = try Data(contentsOf: URL(fileURLWithPath: "desktop/Resources/PipSpriteSheet.png"))
        let sprite = try RobotArt.character(data: spriteData, kind: .sprite)
        check(sprite.kind == .sprite, "Pip's compact animated PNG atlas is accepted")
        check(try RobotArt.character(data: png(width: 1536, height: 1872), kind: .sprite).kind == .sprite,
              "Legacy nine-row animated sheet remains supported")
        check(try RobotArt.character(data: png(width: 1536, height: 2288), kind: .sprite).kind == .sprite,
              "Legacy extended animated sheet remains supported")
        let still = try profile.decoded()
        RobotArt.setCharacter(still)
        let context = CGContext(data: nil, width: 192, height: 208, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        RobotArt.draw(in: context, bounds: CGRect(x: 0, y: 0, width: 192, height: 208))
        let result = NSBitmapImageRep(cgImage: context.makeImage()!)
        check(result.colorAt(x: 0, y: 0)!.alphaComponent == 0, "Custom image preserves its transparent background")
        check(result.colorAt(x: 96, y: 104)!.alphaComponent > 0.9, "Custom image renders inside the robot bounds")
        let previews = URL(fileURLWithPath: ".build/appearance-previews")
        try fm.createDirectory(at: previews, withIntermediateDirectories: true)
        try image.write(to: previews.appendingPathComponent("test-character.png"))
        for (theme, appearance) in [("light", NSAppearance(named: .aqua)!), ("dark", NSAppearance(named: .darkAqua)!)] {
            let view = CharacterPreview(frame: NSRect(x: 0, y: 0, width: 232, height: 196))
            view.appearance = appearance; view.character = still
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
            check(bitmap.colorAt(x: 0, y: 0)!.alphaComponent == 0, "Preview has rounded transparent corners in \(theme)")
            try bitmap.representation(using: .png, properties: [:])!.write(to: previews.appendingPathComponent(theme + ".png"))
        }

        let bundledStore = try CharacterStore(runtime: root, resourceDirectory: resources)
        check(RobotArt.builtInOptions.map(\.id) == ["sunny", "mochi", "boba", "lumi", "mallow", "sprout",
              "peach-puff", "lavender-mochi", "mint-bean", "nimbo", "chai", "plumo"],
              "The six original identities remain in order, followed by six new stable identifiers")
        for option in RobotArt.builtInOptions {
            let builtin = try CharacterProfile.builtIn(id: option.id)
            check(builtin.version == 2 && builtin.kind == .builtin && builtin.builtinID == option.id && builtin.image.isEmpty,
                  "Built-in selections contain only their catalog identity, not copied image data")
            check(try builtin.decoded(resourceDirectory: resources).kind == .builtin,
                  "Each bundled option decodes through the real renderer and resource files")
            check(try JSONEncoder().encode(builtin).count < 512, "Bundled preferences remain small across app updates")
            try bundledStore.save(builtin)
            let reloaded = try CharacterStore(runtime: root, resourceDirectory: resources).load()!
            check(reloaded.builtinID == option.id && reloaded.name == option.name && reloaded.image.isEmpty,
                  "Every catalog choice survives saving and recreating its store by stable ID")
        }
        try bundledStore.save(profile)
        rejects { _ = try CharacterProfile.builtIn(id: "../lumi") }
        rejects { _ = try RobotArt.character(data: image, kind: .builtin) }
        rejects { _ = try CharacterProfile(version: 1, name: "Lumi", kind: .builtin, image: Data(), builtinID: "lumi").decoded(resourceDirectory: resources) }
        rejects { _ = try CharacterProfile(version: 2, name: "Lumi", kind: .builtin, image: image, builtinID: "lumi").decoded(resourceDirectory: resources) }
        rejects { _ = try CharacterProfile(version: 2, name: "Lumi", kind: .builtin, image: Data(), builtinID: "missing").decoded(resourceDirectory: resources) }
        rejects { _ = try CharacterProfile(version: 2, name: "Wrong name", kind: .builtin, image: Data(), builtinID: "lumi").decoded(resourceDirectory: resources) }

        let controller = AppearanceController(store: bundledStore)
        var changes: [RobotArt.Character?] = []
        controller.onChange = { changes.append($0) }
        try controller.selectBuiltIn(id: "lumi")
        check(try bundledStore.load()?.kind == .still && changes.isEmpty,
              "Selecting a gallery preview does not alter the saved custom image or desktop character")
        try controller.applySelection()
        let persisted = try CharacterStore(runtime: root, resourceDirectory: resources).load()!
        check(persisted.builtinID == "lumi" && persisted.image.isEmpty && changes.last!?.kind == .builtin,
              "Applying a gallery choice persists its identity and updates the desktop callback")
        try controller.selectBuiltIn(id: "plumo"); try controller.applySelection()
        check(try bundledStore.load()?.builtinID == "plumo", "Switching from an original character to a new atlas character persists its ID")
        try controller.selectBuiltIn(id: "default")
        check(try bundledStore.load()?.builtinID == "plumo", "Previewing default leaves the new character in place until apply")
        try controller.applySelection()
        check(try bundledStore.load() == nil && changes.count == 3 && changes.last! == nil,
              "Applying the default tile restores the original robot through the same persistence path")
        check(try Data(contentsOf: source) == image, "Switching bundled characters never changes the user's imported image file")
        try bundledStore.save(profile)
        check(try bundledStore.load()?.image == image, "A custom image can be restored after using bundled choices")
        let window = NSApp.windows.first { $0.title == "Pip · Appearance" }!
        let scroll = window.contentView as! NSScrollView
        let document = scroll.documentView!
        let titles = ["Default Pip"] + RobotArt.builtInOptions.map(\.name)
        let buttons = document.subviews.compactMap { $0 as? NSButton }.filter { titles.contains($0.title) }
        let layout = CharacterGalleryLayout(itemCount: titles.count)
        check(buttons.count == 13 && buttons.allSatisfy(\.isEnabled), "All thirteen gallery choices load and remain selectable")
        check(layout.rows == 4 && document.bounds.height == layout.contentHeight,
              "Gallery height expands to four complete rows for twelve characters plus Default")
        check(scroll.hasVerticalScroller && document.bounds.height > scroll.contentSize.height,
              "The expanded Appearance panel scrolls on the available screen")
        for (index, title) in titles.enumerated() {
            let button = buttons.first { $0.title == title }!
            check(button.frame == layout.tileFrame(at: index) && button.frame.maxY < layout.dividerY,
                  "\(title) fits its gallery row above the preview and action controls")
            check(document.bounds.contains(button.frame), "\(title) remains inside the complete scrollable document")
            for other in buttons where other !== button {
                check(!button.frame.intersects(other.frame), "Gallery tiles do not overlap, including the third and fourth rows")
            }
        }
        let previewControl = document.subviews.compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 3 }!
        check(previewControl.label(forSegment: 2) == "Waiting" && previewControl.frame.minY > layout.dividerY,
              "Idle, Working, and Waiting previews remain below the expanded gallery")
        let clickPoints = [NSPoint(x: 5, y: 5), NSPoint(x: 50, y: 35), NSPoint(x: 50, y: 56),
                           NSPoint(x: 50, y: 89), NSPoint(x: 95, y: 105)]
        for button in buttons {
            document.scrollToVisible(button.frame)
            check(button.acceptsFirstMouse(for: nil) && !button.mouseDownCanMoveWindow,
                  "A gallery click neither requires prior focus nor starts a window drag")
            for point in clickPoints {
                let event = NSEvent.mouseEvent(with: .leftMouseDown, location: button.convert(point, to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: 1)!
                let hit = button.cell!.hitTest(for: event, in: button.bounds, of: button)
                check(window.contentView?.superview?.hitTest(event.locationInWindow) === button,
                      "The actual window hierarchy routes \(button.title)'s first mouse event to its card")
                check(hit.contains([.contentArea, .trackableArea]),
                      "A first mouse event over \(button.title)'s image, name, or card edge enters native cell tracking")
            }
            let outside = NSEvent.mouseEvent(with: .leftMouseDown, location: button.convert(NSPoint(x: -1, y: 56), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1)!
            check(button.cell!.hitTest(for: outside, in: button.bounds, of: button).isEmpty,
                  "Events outside \(button.title)'s card cannot select it")
            button.isEnabled = false
            let disabled = NSEvent.mouseEvent(with: .leftMouseDown, location: button.convert(NSPoint(x: 50, y: 35), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1)!
            check(button.cell!.hitTest(for: disabled, in: button.bounds, of: button).isEmpty,
                  "Unavailable gallery choices never enter cell tracking")
            button.isEnabled = true
        }
        // Hidden windows suppress NSButton.mouseDown action dispatch in AppKit.
        // Verify real NSEvent cell hit testing above, and target/action separately.
        let previewView = document.subviews.compactMap { $0 as? CharacterPreview }.first!
        let useButton = document.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Use character" }!
        let lumiButton = buttons.first { $0.title == "Lumi" }!
        check(!useButton.isEnabled, "No unapplied selection remains after applying Default")
        check(NSApp.sendAction(lumiButton.action!, to: lumiButton.target, from: lumiButton),
              "The gallery uses AppKit target/action dispatch for its first selection")
        let firstLumi = previewView.character
        check(lumiButton.state == .on && useButton.isEnabled && firstLumi?.kind == .builtin,
              "The first gallery action selects its card, updates the preview, and enables Use character")
        try controller.selectBuiltIn(id: "sunny")
        check(NSApp.sendAction(lumiButton.action!, to: lumiButton.target, from: lumiButton) && previewView.character === firstLumi,
              "Revisiting a gallery choice reuses its decoded preview without another image decode")
        check(NSApp.sendAction(lumiButton.action!, to: lumiButton.target, from: lumiButton) && lumiButton.state == .on,
              "Selecting an already selected radio card remains responsive")
        check(try bundledStore.load()?.image == image && changes.count == 3,
              "Gallery mouse hit testing and preview actions preserve the applied profile until Use character")
        check(!window.isVisible && !window.isKeyWindow && !NSApp.isActive,
              "Native click checks keep the window hidden and app inactive")
        for (theme, appearance) in [("light", NSAppearance(named: .aqua)!), ("dark", NSAppearance(named: .darkAqua)!)] {
            NSApp.appearance = appearance
            try controller.renderPreview(to: previews.appendingPathComponent("gallery-" + theme + ".png"), selectedBuiltInID: "lumi")
            try controller.renderPreview(to: previews.appendingPathComponent("gallery-working-" + theme + ".png"), selectedBuiltInID: "peach-puff", mood: "working")
            try controller.renderPreview(to: previews.appendingPathComponent("gallery-waiting-" + theme + ".png"), selectedBuiltInID: "lavender-mochi", mood: "waiting")
            check(previewControl.selectedSegment == 2, "Offscreen previews select and render the Waiting state")
        }
        check(try bundledStore.load()?.image == image && changes.count == 3,
              "Offscreen gallery previews neither apply a choice nor change saved preferences")
        try store.reset()
        check(try store.load() == nil, "Reset returns to the bundled default")
        check(try Data(contentsOf: source) == image, "Reset leaves the original selected file untouched")
        try fm.createSymbolicLink(at: saved, withDestinationURL: source)
        rejects { _ = try store.load() }
        try store.reset()
        check(try Data(contentsOf: source) == image, "A profile link is never followed into a user image")
        let folderLink = root.appendingPathComponent("linked-runtime")
        try fm.createSymbolicLink(at: folderLink, withDestinationURL: root)
        rejects { _ = try CharacterStore(runtime: folderLink) }
        print("Passed \(checks) character import, persistence, reset, and preview checks")
    }
}
