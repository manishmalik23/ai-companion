import AppKit
import Foundation
import Darwin
import UniformTypeIdentifiers

struct CharacterProfile: Codable {
    let version: Int
    let name: String
    let kind: RobotArt.CharacterKind
    let image: Data
    var builtinID: String? = nil

    static func builtIn(id: String) throws -> CharacterProfile {
        guard let option = RobotArt.builtInOptions.first(where: { $0.id == id }) else {
            throw RobotArt.CharacterError.invalid("Choose one of Pip’s included characters.")
        }
        return CharacterProfile(version: 2, name: option.name, kind: .builtin, image: Data(), builtinID: id)
    }

    func decoded(resourceDirectory: URL? = nil) throws -> RobotArt.Character {
        guard !name.isEmpty, name.utf8.count <= 512 else {
            throw RobotArt.CharacterError.invalid("The saved character could not be loaded.")
        }
        if version == 2, kind == .builtin, image.isEmpty, let builtinID,
           let option = RobotArt.builtInOptions.first(where: { $0.id == builtinID }), option.name == name {
            return try RobotArt.builtInCharacter(id: builtinID, resourceDirectory: resourceDirectory)
        }
        guard version == 1, kind != .builtin, builtinID == nil else {
            throw RobotArt.CharacterError.invalid("The saved character could not be loaded.")
        }
        return try RobotArt.character(data: image, kind: kind)
    }
}

/// A private, atomic copy outside the app bundle, preserved by app updates.
final class CharacterStore {
    let directory: URL
    let resourceDirectory: URL?
    private var profileURL: URL { directory.appendingPathComponent("character.json") }
    init(runtime: URL, resourceDirectory: URL? = nil) throws {
        directory = runtime.appendingPathComponent("appearance")
        self.resourceDirectory = resourceDirectory
        try privateDirectory(runtime)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try privateDirectory(directory)
    }
    private func privateDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFDIR,
              (info.st_mode & 0o077) == 0 else { throw RobotArt.CharacterError.invalid("Character storage is unavailable.") }
    }
    private func read(_ url: URL, limit: Int, privateFile: Bool) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw RobotArt.CharacterError.invalid("The character file could not be opened.") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0, info.st_size <= limit,
              !privateFile || (info.st_uid == getuid() && info.st_mode & 0o077 == 0) else {
            throw RobotArt.CharacterError.invalid("Choose a regular image file up to 10 MB.")
        }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, min(buffer.count, limit + 1 - data.count))
            if count < 0 { if errno == EINTR { continue }; throw RobotArt.CharacterError.invalid("The image could not be read.") }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= limit else { throw RobotArt.CharacterError.invalid("The image is too large.") }
        }
        return data
    }
    func imported(from url: URL, kind: RobotArt.CharacterKind) throws -> CharacterProfile {
        let image = try read(url, limit: 10 * 1024 * 1024, privateFile: false)
        let name = String(url.lastPathComponent.filter { !$0.isNewline }.prefix(100))
        let profile = CharacterProfile(version: 1, name: name.isEmpty ? "My character" : name, kind: kind, image: image)
        _ = try profile.decoded(resourceDirectory: resourceDirectory)
        return profile
    }
    func load() throws -> CharacterProfile? {
        try privateDirectory(directory)
        var info = stat()
        if lstat(profileURL.path, &info) != 0 && errno == ENOENT { return nil }
        let profile = try JSONDecoder().decode(CharacterProfile.self, from: read(profileURL, limit: 15 * 1024 * 1024, privateFile: true))
        _ = try profile.decoded(resourceDirectory: resourceDirectory)
        return profile
    }
    func save(_ profile: CharacterProfile) throws {
        _ = try profile.decoded(resourceDirectory: resourceDirectory)
        try privateDirectory(directory)
        let bytes = try JSONEncoder().encode(profile)
        let temporary = directory.appendingPathComponent(".character-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw RobotArt.CharacterError.invalid("The character could not be saved.") }
        defer { close(fd); _ = unlink(temporary.path) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw RobotArt.CharacterError.invalid("The character could not be saved.") }
                guard count > 0 else { throw RobotArt.CharacterError.invalid("The character could not be saved.") }
                offset += count
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, profileURL.path) == 0 else {
            throw RobotArt.CharacterError.invalid("The character could not be saved.")
        }
    }
    func reset() throws {
        try privateDirectory(directory)
        if unlink(profileURL.path) != 0 && errno != ENOENT { throw RobotArt.CharacterError.invalid("The default character could not be restored.") }
    }
}

final class CharacterPreview: NSView {
    var character: RobotArt.Character?
    var useDefaultCharacter = false
    var mood = "idle"
    var phase: Double = 0
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 22, yRadius: 22)
            shape.addClip()
            NSColor.controlBackgroundColor.setFill(); bounds.fill()
            NSColor.separatorColor.withAlphaComponent(0.10).setFill()
            for row in 0...Int(bounds.height / 14) {
                for column in 0...Int(bounds.width / 14) where (row + column) % 2 == 0 {
                    NSRect(x: column * 14, y: row * 14, width: 14, height: 14).fill()
                }
            }
            if let context = NSGraphicsContext.current?.cgContext {
                RobotArt.draw(in: context, bounds: bounds.insetBy(dx: 30, dy: 14), mood: mood, phase: phase,
                              character: character, useDefault: useDefaultCharacter)
            }
            NSGraphicsContext.restoreGraphicsState()
            NSColor.separatorColor.withAlphaComponent(0.4).setStroke(); shape.lineWidth = 1; shape.stroke()
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

private final class AppearanceBackground: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); bounds.fill() }
}

struct CharacterGalleryLayout {
    let itemCount: Int
    let columns = 4
    var rows: Int { (itemCount + columns - 1) / columns }
    func tileFrame(at index: Int) -> NSRect {
        NSRect(x: 25 + (index % columns) * 110, y: 82 + (index / columns) * 120, width: 100, height: 112)
    }
    var dividerY: CGFloat { CGFloat(82 + max(0, rows - 1) * 120 + 112 + 15) }
    var footerOffset: CGFloat { dividerY - 309 }
    var contentHeight: CGFloat { 730 + footerOffset }
}

private final class CharacterGalleryCell: NSButtonCell {
    override func hitTest(for event: NSEvent, in cellFrame: NSRect, of controlView: NSView) -> NSCell.HitResult {
        // This cell's native radio indicator/title are replaced by a full card.
        // Keep AppKit's press/release tracking over the same area we draw.
        guard isEnabled, cellFrame.contains(controlView.convert(event.locationInWindow, from: nil)) else { return [] }
        return [.contentArea, .trackableArea]
    }
}

private final class CharacterGalleryButton: NSButton {
    let selectionID: String
    let character: RobotArt.Character?
    let isDefault: Bool
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(id: String, name: String, character: RobotArt.Character?, isDefault: Bool = false) {
        selectionID = id; self.character = character; self.isDefault = isDefault
        super.init(frame: .zero)
        cell = CharacterGalleryCell(textCell: name)
        title = name; isBordered = false; setButtonType(.radio)
        setAccessibilityLabel("Preview " + name)
        toolTip = "Preview " + name
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func resetCursorRects() { addCursorRect(bounds, cursor: isEnabled ? .pointingHand : .arrow) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let selected = state == .on
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
            (selected ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
            shape.fill()
            (selected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            shape.lineWidth = selected ? 2 : 1; shape.stroke()
            if (isDefault || character != nil), let context = NSGraphicsContext.current?.cgContext {
                RobotArt.draw(in: context, bounds: NSRect(x: 9, y: 6, width: bounds.width - 18, height: 69),
                              phase: 0, character: character, useDefault: isDefault)
            }
            let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byWordWrapping
            (title as NSString).draw(in: NSRect(x: 5, y: 80, width: bounds.width - 10, height: 29),
                withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: selected ? .semibold : .regular),
                                 .foregroundColor: isEnabled ? NSColor.labelColor : NSColor.secondaryLabelColor,
                                 .paragraphStyle: style])
        }
    }
}

final class AppearanceController: NSObject, NSWindowDelegate {
    private enum Selection { case defaultRobot, profile(CharacterProfile) }
    private let store: CharacterStore
    private var window: NSWindow?
    private var body: AppearanceBackground?
    private let preview = CharacterPreview()
    private let name = NSTextField(labelWithString: "Default robot · Animated")
    private let descriptionText = NSTextField(wrappingLabelWithString: "Slow blinking at rest.\nLaptop pose while working.")
    private let hint = NSTextField(labelWithString: "PNG or WebP · up to 10 MB. Transparency looks best.")
    private let note = NSTextField(wrappingLabelWithString: "Choose a character, then click Use character.")
    private let mode = NSSegmentedControl(labels: ["Still image", "Animated sheet"], trackingMode: .selectOne, target: nil, action: nil)
    private let previewMode = NSSegmentedControl(labels: ["Idle", "Working", "Waiting"], trackingMode: .selectOne, target: nil, action: nil)
    private var useButton: NSButton!
    private var resetButton: NSButton!
    private var gallery: [CharacterGalleryButton] = []
    private var candidate: Selection?
    private var selectedGalleryID: String?
    private var timer: Timer?
    var onChange: ((RobotArt.Character?) -> Void)?

    init(store: CharacterStore) { self.store = store; super.init() }

    func show() {
        if window == nil { createWindow() }
        candidate = nil; useButton.isEnabled = false
        do {
            let current = try store.load()
            preview.character = try current.map { try decoded($0) }
            preview.useDefaultCharacter = current == nil
            name.stringValue = current.map(displayName) ?? "Default robot · Animated"
            selectedGalleryID = current == nil ? "default" : current?.builtinID
            resetButton.isEnabled = current != nil
            updateDescription(for: current)
            note.stringValue = "Choose a character, then click Use character."
        } catch {
            preview.character = nil; preview.useDefaultCharacter = true; selectedGalleryID = nil
            resetButton.isEnabled = true
            name.stringValue = "Saved character unavailable"
            note.stringValue = "Choose another character or reset to default."
        }
        updateGallerySelection(); preview.needsDisplay = true
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.preview.phase = Date().timeIntervalSince1970; self.preview.needsDisplay = true
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func displayName(_ profile: CharacterProfile) -> String {
        profile.name + (profile.kind == .still ? " · Still image" : " · Animated")
    }
    private func decoded(_ profile: CharacterProfile) throws -> RobotArt.Character {
        if profile.kind == .builtin, let id = profile.builtinID,
           let character = gallery.first(where: { $0.selectionID == id })?.character {
            return character
        }
        return try profile.decoded(resourceDirectory: store.resourceDirectory)
    }
    private func updateDescription(for profile: CharacterProfile?) {
        if profile?.kind == .still { descriptionText.stringValue = "Your image stays visible in every state." }
        else if profile?.kind == .sprite { descriptionText.stringValue = "Preview idle, working, and waiting states in your sheet." }
        else if let id = profile?.builtinID,
                ["peach-puff", "lavender-mochi", "mint-bean", "nimbo", "chai", "plumo"].contains(id) {
            descriptionText.stringValue = "Slow blinks, laptop typing,\nand a look when Pip needs you."
        }
        else { descriptionText.stringValue = "Slow blinking at rest.\nLaptop pose while working." }
    }
    private func text(_ value: String, at frame: NSRect, size: CGFloat, bold: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: value); field.frame = frame
        field.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        field.textColor = bold ? .labelColor : .secondaryLabelColor; return field
    }
    private func createWindow() {
        let layout = CharacterGalleryLayout(itemCount: RobotArt.builtInOptions.count + 1)
        let offset = layout.footerOffset
        let content = AppearanceBackground(frame: NSRect(x: 0, y: 0, width: 480, height: layout.contentHeight))
        let height = min(730, max(480, (NSScreen.main?.visibleFrame.height ?? 840) - 100))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: height),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: height))
        scroll.documentView = content; scroll.hasVerticalScroller = height < layout.contentHeight
        scroll.autohidesScrollers = true; scroll.drawsBackground = false
        window.title = "Pip · Appearance"; window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor; window.contentView = scroll
        window.isReleasedWhenClosed = false; window.delegate = self; window.center()
        self.window = window; body = content
        content.addSubview(text("Your companion", at: NSRect(x: 24, y: 18, width: 432, height: 29), size: 23, bold: true))
        content.addSubview(text("Pick a look for your desktop.", at: NSRect(x: 24, y: 52, width: 432, height: 20), size: 13))
        let defaultButton = CharacterGalleryButton(id: "default", name: "Default Pip", character: nil, isDefault: true)
        gallery = [defaultButton]
        for option in RobotArt.builtInOptions {
            let character = try? RobotArt.builtInCharacter(id: option.id, resourceDirectory: store.resourceDirectory)
            let button = CharacterGalleryButton(id: option.id, name: option.name, character: character)
            button.isEnabled = character != nil
            if character == nil { button.toolTip = option.name + " is unavailable in this app build." }
            gallery.append(button)
        }
        for (index, button) in gallery.enumerated() {
            button.frame = layout.tileFrame(at: index)
            button.target = self; button.action = #selector(galleryClicked(_:)); content.addSubview(button)
        }
        let divider = NSBox(frame: NSRect(x: 24, y: layout.dividerY, width: 432, height: 1)); divider.boxType = .separator
        content.addSubview(divider)
        preview.frame = NSRect(x: 24, y: 327 + offset, width: 174, height: 146)
        preview.setAccessibilityElement(true); preview.setAccessibilityRole(.image); preview.setAccessibilityLabel("Character preview")
        content.addSubview(preview)
        name.frame = NSRect(x: 216, y: 334 + offset, width: 240, height: 43)
        name.font = .systemFont(ofSize: 15, weight: .semibold); name.maximumNumberOfLines = 2
        name.lineBreakMode = .byTruncatingTail; content.addSubview(name)
        descriptionText.frame = NSRect(x: 216, y: 382 + offset, width: 240, height: 38)
        descriptionText.font = .systemFont(ofSize: 12); descriptionText.textColor = .secondaryLabelColor
        content.addSubview(descriptionText)
        previewMode.frame = NSRect(x: 216, y: 436 + offset, width: 240, height: 26); previewMode.selectedSegment = 0
        previewMode.target = self; previewMode.action = #selector(previewModeChanged)
        previewMode.setAccessibilityLabel("Preview state"); content.addSubview(previewMode)
        useButton = NSButton(title: "Use character", target: self, action: #selector(applyCharacter))
        useButton.bezelStyle = .rounded; useButton.keyEquivalent = "\r"
        useButton.frame = NSRect(x: 24, y: 493 + offset, width: 432, height: 34); content.addSubview(useButton)
        resetButton = NSButton(title: "Reset to default", target: self, action: #selector(resetCharacter))
        resetButton.bezelStyle = .inline; resetButton.frame = NSRect(x: 166, y: 537 + offset, width: 148, height: 24)
        content.addSubview(resetButton)
        content.addSubview(text("Or use your own image", at: NSRect(x: 24, y: 582 + offset, width: 432, height: 20), size: 13, bold: true))
        mode.frame = NSRect(x: 24, y: 613 + offset, width: 220, height: 26); mode.selectedSegment = 0
        mode.target = self; mode.action = #selector(modeChanged); mode.setAccessibilityLabel("Custom character format")
        content.addSubview(mode)
        let choose = NSButton(title: "Choose character…", target: self, action: #selector(chooseCharacter))
        choose.bezelStyle = .rounded; choose.frame = NSRect(x: 258, y: 610 + offset, width: 198, height: 30); content.addSubview(choose)
        hint.frame = NSRect(x: 24, y: 649 + offset, width: 432, height: 20); hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor; content.addSubview(hint)
        note.frame = NSRect(x: 24, y: 688 + offset, width: 432, height: 30); note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor; content.addSubview(note)
    }

    private func updateGallerySelection() {
        for button in gallery {
            button.state = button.selectionID == selectedGalleryID ? .on : .off
            button.needsDisplay = true
        }
    }

    /// Stage a bundled choice; persistence and the desktop change only on apply.
    func selectBuiltIn(id: String) throws {
        if window == nil { createWindow() }
        if id == "default" {
            candidate = .defaultRobot; preview.character = nil; preview.useDefaultCharacter = true
            name.stringValue = "Default robot · Animated"; updateDescription(for: nil)
        } else {
            let profile = try CharacterProfile.builtIn(id: id)
            let character = try decoded(profile)
            candidate = .profile(profile); preview.character = character; preview.useDefaultCharacter = false
            name.stringValue = displayName(profile); updateDescription(for: profile)
        }
        selectedGalleryID = id; updateGallerySelection(); preview.needsDisplay = true
        useButton.isEnabled = true; note.stringValue = "Preview ready. Choose Use character to apply it."
    }

    func applySelection() throws {
        guard let candidate else { return }
        switch candidate {
        case .defaultRobot:
            try store.reset(); onChange?(nil); resetButton.isEnabled = false
        case .profile(let profile):
            let character = try decoded(profile)
            try store.save(profile); onChange?(character); resetButton.isEnabled = true
        }
        self.candidate = nil; useButton.isEnabled = false
        note.stringValue = "Character saved and applied."
    }

    /// Offscreen artifact generation; does not show a window or save a choice.
    func renderPreview(to url: URL, selectedBuiltInID: String = "default", mood: String = "idle") throws {
        try selectBuiltIn(id: selectedBuiltInID)
        preview.mood = ["working", "waiting"].contains(mood) ? mood : "idle"
        previewMode.selectedSegment = preview.mood == "working" ? 1 : (preview.mood == "waiting" ? 2 : 0)
        preview.phase = 0; preview.needsDisplay = true
        guard let body, let bitmap = body.bitmapImageRepForCachingDisplay(in: body.bounds) else {
            throw RobotArt.CharacterError.invalid("The appearance preview could not be rendered.")
        }
        window?.appearance = NSApp.appearance
        body.appearance = NSApp.appearance
        body.effectiveAppearance.performAsCurrentDrawingAppearance { body.cacheDisplay(in: body.bounds, to: bitmap) }
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw RobotArt.CharacterError.invalid("The appearance preview could not be encoded.")
        }
        try data.write(to: url, options: .atomic)
    }

    @objc private func galleryClicked(_ sender: NSButton) {
        guard let button = sender as? CharacterGalleryButton else { return }
        do { try selectBuiltIn(id: button.selectionID) } catch { updateGallerySelection(); present(error) }
    }
    @objc private func previewModeChanged() {
        preview.mood = ["idle", "working", "waiting"][max(0, min(2, previewMode.selectedSegment))]
        preview.needsDisplay = true
    }
    @objc private func modeChanged() {
        hint.stringValue = mode.selectedSegment == 0 ? "PNG or WebP · up to 10 MB. Transparency looks best." : "Pip: 1254 × 1254 · Legacy: 1536 × 1872/2288."
    }
    @objc private func chooseCharacter() {
        let chooser = NSOpenPanel(); chooser.canChooseFiles = true; chooser.canChooseDirectories = false
        chooser.allowsMultipleSelection = false; chooser.title = "Choose your Pip character"
        chooser.allowedContentTypes = [.png] + [UTType(filenameExtension: "webp")].compactMap { $0 }
        guard let window else { return }
        chooser.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = chooser.url else { return }
            do {
                let profile = try self.store.imported(from: url, kind: self.mode.selectedSegment == 0 ? .still : .sprite)
                self.preview.character = try profile.decoded(resourceDirectory: self.store.resourceDirectory)
                self.preview.useDefaultCharacter = false; self.candidate = .profile(profile)
                self.selectedGalleryID = nil; self.updateGallerySelection()
                self.name.stringValue = self.displayName(profile); self.updateDescription(for: profile)
                self.preview.needsDisplay = true; self.useButton.isEnabled = true
                self.note.stringValue = "Preview ready. Choose Use character to apply it."
            } catch { self.present(error) }
        }
    }
    @objc private func applyCharacter() { do { try applySelection() } catch { present(error) } }
    @objc private func resetCharacter() {
        do {
            try selectBuiltIn(id: "default"); try applySelection()
            note.stringValue = "Default character restored."
        } catch { present(error) }
    }
    private func present(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = "Character could not be used"
        alert.informativeText = error.localizedDescription; alert.beginSheetModal(for: window)
    }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil; candidate = nil }
}
