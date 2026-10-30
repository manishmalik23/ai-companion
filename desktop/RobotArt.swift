import Foundation
import CoreGraphics
import ImageIO

/// Renders Pip's original mascot and compatible imported atlases.
/// Coordinates point down, matching Pip's flipped views and icon renderer.
enum RobotArt {
    enum CharacterKind: String, Codable { case still, sprite, builtin }
    enum CharacterError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
    }
    final class Character {
        let kind: CharacterKind
        fileprivate let image: CGImage
        fileprivate let sheet: SpriteSheet?
        fileprivate let builtin: BuiltinCharacterFrames?
        fileprivate init(kind: CharacterKind, image: CGImage, sheet: SpriteSheet?) {
            self.kind = kind; self.image = image; self.sheet = sheet; builtin = nil
        }
        init(builtin: BuiltinCharacterFrames) {
            kind = .builtin; image = builtin.previewImage; sheet = nil; self.builtin = builtin
        }
    }
    private static let frameCounts = [6, 8, 8, 4, 5, 8, 6, 6, 6]
    // The official Pets animation-row durations, in milliseconds.
    private static let durations: [[Double]] = [
        [280, 110, 110, 140, 140, 320],
        [120, 120, 120, 120, 120, 120, 120, 220],
        [120, 120, 120, 120, 120, 120, 120, 220],
        [140, 140, 140, 280],
        [140, 140, 140, 140, 280],
        [140, 140, 140, 140, 140, 140, 140, 240],
        [150, 150, 150, 150, 150, 260],
        [120, 120, 120, 120, 120, 220],
        [150, 150, 150, 150, 150, 280]
    ]
    // The source poses are unchanged. Extend the open-eye first pose between
    // repeated sequences so quiet states do not blink every second.
    private static let playbackRates: [Double] = [0.75, 1, 1, 1, 1, 1, 0.65, 0.65, 0.7]
    private static let restingHolds: [Double] = [3.5, 0, 0, 0, 0, 0, 1.6, 0.6, 1.1]

    fileprivate final class SpriteSheet {
        let frames: [[CGImage]]
        let compact: Bool
        convenience init?(url: URL) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary),
                  image.alphaInfo != .none, image.alphaInfo != .noneSkipFirst, image.alphaInfo != .noneSkipLast else { return nil }
            self.init(image: image)
        }
        init?(image: CGImage) {
            guard image.alphaInfo != .none, image.alphaInfo != .noneSkipFirst, image.alphaInfo != .noneSkipLast else { return nil }
            compact = image.width == 1254 && image.height == 1254
            guard compact || (image.width == 1536 && [1872, 2288].contains(image.height)),
                  let frames = Self.crop(image, compact: compact) else { return nil }
            self.frames = frames
        }
        private static func crop(_ image: CGImage, compact: Bool) -> [[CGImage]]? {
            var rows: [[CGImage]] = []
            for (row, count) in (compact ? [4, 4, 4] : frameCounts).enumerated() {
                var cells: [CGImage] = []
                for column in 0..<count {
                    // Integer partitions cover every pixel, including odd cell widths.
                    let x = compact ? column * image.width / 4 : column * 192
                    let y = compact ? row * image.height / 3 : row * 208
                    let width = compact ? (column + 1) * image.width / 4 - x : 192
                    let height = compact ? (row + 1) * image.height / 3 - y : 208
                    guard let cell = image.cropping(to: CGRect(x: x, y: y, width: width, height: height)) else { return nil }
                    cells.append(cell)
                }
                rows.append(cells)
            }
            return rows
        }
    }

    private static var explicitSheet: SpriteSheet?
    private static var customCharacter: Character?
    static func setCharacter(_ character: Character?) { customCharacter = character }
    static func character(data: Data, kind: CharacterKind) throws -> Character {
        guard kind != .builtin else {
            throw CharacterError.invalid("Choose a built-in character from Appearance.")
        }
        guard !data.isEmpty, data.count <= 10 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?, ["public.png", "org.webmproject.webp"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096, width * height <= 16_777_216,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary) else {
            throw CharacterError.invalid("Choose a PNG or WebP image up to 10 MB and 4096 pixels per side.")
        }
        if kind == .sprite {
            guard let sheet = SpriteSheet(image: image) else {
                throw CharacterError.invalid("Use a transparent 1254 × 1254 Pip sheet (4 columns × 3 rows), or a 1536 × 1872/2288 legacy sheet.")
            }
            return Character(kind: kind, image: image, sheet: sheet)
        }
        return Character(kind: kind, image: image, sheet: nil)
    }
    private static let bundledSheet: SpriteSheet? = {
        if let url = Bundle.main.url(forResource: "PipSpriteSheet", withExtension: "png"),
           let sheet = SpriteSheet(url: url) { return sheet }
        guard let url = Bundle.main.url(forResource: "CodexSpriteSheet", withExtension: "webp") else { return nil }
        return SpriteSheet(url: url)
    }()

    /// Used by the build-time icon generator; the app loads its bundled resource.
    @discardableResult
    static func useSpriteSheet(at url: URL) -> Bool {
        guard let sheet = SpriteSheet(url: url) else { return false }
        explicitSheet = sheet
        return true
    }

    private static func row(for mood: String) -> Int {
        switch mood {
        case "running-right": return 1
        case "running-left": return 2
        case "waving": return 3
        case "jumping": return 4
        case "failed": return 5
        case "waiting", "attention": return 6
        case "working", "running": return 7
        case "review": return 8
        default: return 0
        }
    }

    private static func frameIndex(row: Int, phase: Double) -> Int {
        frameIndex(durations: durations[row], rate: playbackRates[row], hold: restingHolds[row], phase: phase)
    }

    private static func frameIndex(durations: [Double], rate: Double, hold: Double, phase: Double) -> Int {
        guard phase.isFinite else { return 0 }
        let cycle = durations.reduce(0, +) / (1_000 * rate) + hold
        // phase is seconds (including the caller's wall-clock timestamps).
        // Reduce it before converting units to avoid overflow for finite values.
        var seconds = phase.truncatingRemainder(dividingBy: cycle)
        if seconds < 0 { seconds += cycle }
        if seconds < hold { return 0 }
        var time = (seconds - hold) * 1_000 * rate
        for (index, duration) in durations.enumerated() {
            if time < duration { return index }
            time -= duration
        }
        return 0
    }

    static func draw(in context: CGContext, bounds: CGRect, mood: String = "idle", phase: Double = 0,
                     character: Character? = nil, useDefault: Bool = false) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        let chosen = useDefault ? nil : (character ?? customCharacter)
        if let builtin = chosen?.builtin {
            let destination = builtin.draw(in: context, bounds: bounds, mood: mood, phase: phase)
            if !builtin.usesAttentionArtwork && (mood == "waiting" || mood == "attention") {
                drawWaitingBadge(in: context, bounds: destination)
            }
            return
        }
        let sheet = chosen?.sheet ?? (useDefault ? nil : explicitSheet) ?? bundledSheet
        context.interpolationQuality = chosen?.kind == .still || sheet?.compact == true ? .high : .none
        context.setBlendMode(.normal)
        let size = chosen?.kind == .still ? CGSize(width: chosen!.image.width, height: chosen!.image.height) :
            (sheet?.compact == true ? CGSize(width: 313.5, height: 418) : CGSize(width: 192, height: 208))
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let destination = CGRect(x: bounds.midX - size.width * scale / 2, y: bounds.midY - size.height * scale / 2,
                                 width: size.width * scale, height: size.height * scale)
        if chosen?.kind == .still || sheet != nil {
            let frame: CGImage
            if let chosen, chosen.kind == .still { frame = chosen.image }
            else {
                guard let sheet else { return }
                let row = row(for: mood)
                if sheet.compact {
                    let state = row == 7 ? 1 : (row == 6 ? 2 : 0)
                    let times: [Double] = state == 0 ? [250, 160, 130, 200] : [240, 240, 240, 300]
                    let index = frameIndex(durations: times, rate: 1, hold: state == 0 ? 4.0 : 0, phase: phase)
                    // Keep the laptop and body registered in one front-facing
                    // seated pose. The generated alternate poses rotated the
                    // laptop and made the companion appear to sway sideways.
                    frame = sheet.frames[state][state == 1 ? 0 : index]
                } else {
                    frame = sheet.frames[row][frameIndex(row: row, phase: phase)]
                }
            }
            // Raw CGImages need this local flip in a y-down AppKit context.
            // CoreGraphics composites their alpha, so hidden RGB stays invisible.
            context.saveGState()
            context.translateBy(x: destination.minX, y: destination.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(frame, in: CGRect(origin: .zero, size: destination.size))
            context.restoreGState()
            if sheet?.compact == true && chosen?.kind != .still && row(for: mood) == 7 {
                drawLaptopMark(in: context, bounds: destination, phase: phase)
                drawWorkingBlink(in: context, bounds: destination, phase: phase)
            }
        } else {
            drawFallback(in: context, bounds: destination)
        }
        if mood == "waiting" || mood == "attention" { drawWaitingBadge(in: context, bounds: destination) }
    }

    private static func drawLaptopMark(in context: CGContext, bounds: CGRect, phase: Double) {
        // Original vector mark on the laptop lid; only its glow changes. The
        // body, laptop and badge position stay stationary throughout work.
        let seconds = phase.isFinite ? phase.truncatingRemainder(dividingBy: 2.4) : 0
        let brightness = 0.7 + 0.3 * (sin(seconds * .pi / 1.2) + 1) / 2
        let side = bounds.width * 0.055
        let center = CGPoint(x: bounds.minX + bounds.width * 0.465,
                             y: bounds.minY + bounds.height * 0.69)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: center.x, y: center.y - side))
        path.addLine(to: CGPoint(x: center.x + side * 0.32, y: center.y - side * 0.32))
        path.addLine(to: CGPoint(x: center.x + side, y: center.y))
        path.addLine(to: CGPoint(x: center.x + side * 0.32, y: center.y + side * 0.32))
        path.addLine(to: CGPoint(x: center.x, y: center.y + side))
        path.addLine(to: CGPoint(x: center.x - side * 0.32, y: center.y + side * 0.32))
        path.addLine(to: CGPoint(x: center.x - side, y: center.y))
        path.addLine(to: CGPoint(x: center.x - side * 0.32, y: center.y - side * 0.32))
        path.closeSubpath()
        context.setFillColor(CGColor(red: 0.12, green: 0.85, blue: 1, alpha: brightness))
        context.addPath(path); context.fillPath()
    }

    private static func drawWorkingBlink(in context: CGContext, bounds: CGRect, phase: Double) {
        guard phase.isFinite else { return }
        var seconds = phase.truncatingRemainder(dividingBy: 5.2)
        if seconds < 0 { seconds += 5.2 }
        guard seconds >= 4.6 && seconds < 4.76 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        for x in [0.39, 0.685] {
            let center = CGPoint(x: bounds.minX + bounds.width * x,
                                 y: bounds.minY + bounds.height * 0.452)
            let radiusX = bounds.width * 0.09
            let radiusY = bounds.height * 0.095
            context.setFillColor(CGColor(red: 0.08, green: 0.12, blue: 0.22, alpha: 1))
            context.fillEllipse(in: CGRect(x: center.x - radiusX, y: center.y - radiusY,
                                          width: radiusX * 2, height: radiusY * 2))
            let lid = CGMutablePath()
            lid.move(to: CGPoint(x: center.x - radiusX * 0.55, y: center.y))
            lid.addQuadCurve(to: CGPoint(x: center.x + radiusX * 0.55, y: center.y),
                             control: CGPoint(x: center.x, y: center.y + radiusY * 0.25))
            context.setStrokeColor(CGColor(red: 0.12, green: 0.85, blue: 1, alpha: 1))
            context.setLineWidth(max(1.5, bounds.width * 0.014)); context.setLineCap(.round)
            context.addPath(lid); context.strokePath()
        }
    }

    private static func drawWaitingBadge(in context: CGContext, bounds: CGRect) {
        let side = min(14, bounds.width * 0.2)
        let badge = CGRect(x: bounds.maxX - side - 3, y: bounds.minY + bounds.height * 0.13, width: side, height: side)
        context.setFillColor(CGColor(red: 1, green: 0.76, blue: 0.25, alpha: 1))
        context.addPath(CGPath(roundedRect: badge, cornerWidth: side * 0.22, cornerHeight: side * 0.22, transform: nil)); context.fillPath()
        context.setFillColor(CGColor(red: 0.025, green: 0.09, blue: 0.23, alpha: 1))
        context.fill(CGRect(x: badge.midX - side * 0.06, y: badge.minY + side * 0.2, width: side * 0.12, height: side * 0.4))
        context.fill(CGRect(x: badge.midX - side * 0.06, y: badge.minY + side * 0.72, width: side * 0.12, height: side * 0.12))
    }

    private static func drawFallback(in context: CGContext, bounds: CGRect) {
        // A small terminal symbol keeps the control recognizable if packaging is
        // incomplete. It is used only when the original resource cannot decode.
        let box = bounds.insetBy(dx: bounds.width * 0.17, dy: bounds.height * 0.3)
        context.setFillColor(CGColor(red: 0.06, green: 0.13, blue: 0.29, alpha: 1))
        context.addPath(CGPath(roundedRect: box, cornerWidth: 8, cornerHeight: 8, transform: nil)); context.fillPath()
        context.setStrokeColor(CGColor(red: 0.4, green: 0.7, blue: 1, alpha: 1))
        context.setLineWidth(max(1.5, box.width * 0.05)); context.setLineCap(.square)
        context.move(to: CGPoint(x: box.minX + box.width * 0.25, y: box.minY + box.height * 0.3))
        context.addLine(to: CGPoint(x: box.minX + box.width * 0.4, y: box.midY))
        context.addLine(to: CGPoint(x: box.minX + box.width * 0.25, y: box.minY + box.height * 0.7))
        context.move(to: CGPoint(x: box.minX + box.width * 0.56, y: box.minY + box.height * 0.7))
        context.addLine(to: CGPoint(x: box.minX + box.width * 0.77, y: box.minY + box.height * 0.7)); context.strokePath()
    }
}
