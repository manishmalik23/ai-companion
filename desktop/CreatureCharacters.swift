import Foundation
import CoreGraphics
import ImageIO

struct BuiltinCharacterOption: Equatable {
    let id: String
    let name: String
}

extension RobotArt {
    static let builtInOptions: [BuiltinCharacterOption] = [
        .init(id: "sunny", name: "Sunny"), .init(id: "mochi", name: "Mochi"),
        .init(id: "boba", name: "Boba"), .init(id: "lumi", name: "Lumi"),
        .init(id: "mallow", name: "Mallow"), .init(id: "sprout", name: "Sprout"),
        .init(id: "peach-puff", name: "Peach Puff"), .init(id: "lavender-mochi", name: "Lavender Mochi"),
        .init(id: "mint-bean", name: "Mint Bean"), .init(id: "nimbo", name: "Nimbo"),
        .init(id: "chai", name: "Chai"), .init(id: "plumo", name: "Plumo")
    ]

    static func builtInCharacter(id: String, resourceDirectory: URL? = nil) throws -> Character {
        guard let option = builtInOptions.first(where: { $0.id == id }),
              let directory = resourceDirectory ?? Bundle.main.resourceURL?.appendingPathComponent("Characters") else {
            throw CharacterError.invalid("That built-in character is unavailable.")
        }
        return Character(builtin: try BuiltinCharacterFrames(option: option, directory: directory))
    }
}

final class BuiltinCharacterFrames {
    private static let atlasResources = [
        "peach-puff": "PeachPuff", "lavender-mochi": "LavenderMochi", "mint-bean": "MintBean",
        "nimbo": "Nimbo", "chai": "Chai", "plumo": "Plumo"
    ]
    private struct AtlasLayout: Decodable {
        let version: Int
        let width: Int
        let height: Int
        let columns: Int
        let rows: Int
        let characters: [String: RegisteredCharacter]
    }
    private struct RegisteredCharacter: Decodable {
        let file: String
        let frames: [[Int]]
        let canvas: [Int]
    }
    private let legacy: LegacyBuiltinCharacterFrames?
    private let atlas: [[CGImage]]?
    private let atlasCanvas: CGSize?
    var previewImage: CGImage { legacy?.previewImage ?? atlas![0][0] }
    var hasBlink: Bool { legacy?.hasBlink ?? true }
    var usesAttentionArtwork: Bool { atlas != nil }

    init(option: BuiltinCharacterOption, directory: URL) throws {
        if let resource = Self.atlasResources[option.id] {
            let registration = try Self.registration(for: option.id, directory: directory)
            let image = try LegacyBuiltinCharacterFrames.load(directory.appendingPathComponent(resource + ".png"))
            var rows: [[CGImage]] = []
            for row in 0..<3 {
                var frames: [CGImage] = []
                for column in 0..<4 {
                    let rectangle = registration.frames[row * 4 + column]
                    guard let frame = image.cropping(to: rectangle) else {
                        throw RobotArt.CharacterError.invalid("The built-in character has an invalid animation frame.")
                    }
                    frames.append(frame)
                }
                rows.append(frames)
            }
            atlas = rows; atlasCanvas = registration.canvas; legacy = nil
        } else {
            legacy = try LegacyBuiltinCharacterFrames(option: option, directory: directory)
            atlas = nil; atlasCanvas = nil
        }
    }

    private static func registration(for id: String, directory: URL) throws -> (frames: [CGRect], canvas: CGSize) {
        let error = RobotArt.CharacterError.invalid("The built-in character animation layout is unavailable.")
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("FluffyLayouts.json"), options: .mappedIfSafe),
              !data.isEmpty, data.count <= 64 * 1024,
              let layout = try? JSONDecoder().decode(AtlasLayout.self, from: data),
              layout.version == 1, layout.width == 1254, layout.height == 1254,
              layout.columns == 4, layout.rows == 3,
              Set(layout.characters.keys) == Set(atlasResources.keys) else { throw error }
        for (characterID, registration) in layout.characters {
            guard registration.file == atlasResources[characterID]! + ".png",
                  registration.frames.count == 12, registration.canvas.count == 2,
                  registration.canvas[0] > 0, registration.canvas[0] <= 314,
                  registration.canvas[1] > 0, registration.canvas[1] <= 418 else { throw error }
            for (index, frame) in registration.frames.enumerated() {
                let row = index / 4, column = index % 4
                // The source cells use floor partitions, including alternating
                // 313/314-pixel widths. Registration may never cross a cell edge.
                guard frame.count == 4, frame[0] >= column * layout.width / 4,
                      frame[0] < (column + 1) * layout.width / 4,
                      frame[1] >= row * layout.height / 3, frame[1] < (row + 1) * layout.height / 3,
                      frame[2] > 0, frame[2] <= 314, frame[3] > 0, frame[3] <= 418,
                      frame[0] + frame[2] <= (column + 1) * layout.width / 4,
                      frame[1] + frame[3] <= (row + 1) * layout.height / 3 else { throw error }
            }
            guard registration.canvas == [registration.frames.map { $0[2] }.max()!,
                                          registration.frames.map { $0[3] }.max()!] else { throw error }
        }
        guard let registration = layout.characters[id] else { throw error }
        return (registration.frames.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) },
                CGSize(width: registration.canvas[0], height: registration.canvas[1]))
    }

    /// Atlas rows: slow idle blink, registered laptop typing, waiting for attention.
    /// Durations match the web companion; timestamps are in seconds.
    static func atlasFrame(mood: String, phase: Double) -> (row: Int, column: Int) {
        let row = ["working", "running"].contains(mood) ? 1 : (["waiting", "attention"].contains(mood) ? 2 : 0)
        let columns: [Int]
        let durations: [Double]
        if row == 1 {
            columns = Array(repeating: [0, 1, 3, 1], count: 4).flatMap { $0 } + [2, 3]
            durations = Array(repeating: 300, count: 16) + [130, 300]
        } else {
            columns = [0, 1, 2, 3]
            durations = row == 0 ? [4250, 160, 130, 200] : [2800, 700, 130, 700]
        }
        guard phase.isFinite else { return (row, 0) }
        let cycle = durations.reduce(0, +) / 1000
        var seconds = phase.truncatingRemainder(dividingBy: cycle)
        if seconds < 0 { seconds += cycle }
        let milliseconds = seconds * 1000
        var end = 0.0
        for (index, duration) in durations.enumerated() {
            end += duration
            if milliseconds < end { return (row, columns[index]) }
        }
        return (row, 0)
    }

    @discardableResult
    func draw(in context: CGContext, bounds: CGRect, mood: String, phase: Double) -> CGRect {
        if let legacy {
            return legacy.draw(in: context, bounds: bounds,
                working: mood == "working" || mood == "running", phase: phase)
        }
        let frame = Self.atlasFrame(mood: mood, phase: phase)
        let image = atlas![frame.row][frame.column]
        let scale = min(bounds.width / atlasCanvas!.width, bounds.height / atlasCanvas!.height)
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let destination = CGRect(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height,
            width: size.width, height: size.height)
        context.interpolationQuality = .high
        context.setBlendMode(.normal)
        context.saveGState()
        context.translateBy(x: destination.minX, y: destination.maxY); context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: destination.size))
        context.restoreGState()
        return destination
    }

    static func isBlinking(at phase: Double) -> Bool { LegacyBuiltinCharacterFrames.isBlinking(at: phase) }
}

/// The original six use registered poses with closed-eye patches. Their body
/// and laptop remain identical throughout each animation state.
private final class LegacyBuiltinCharacterFrames {
    private struct Eye {
        let target: CGRect
    }
    private struct Descriptor {
        let split: Int
        let idleEyes: [Eye]
        let workingEyes: [Eye]
        var matchBlinkColors = false
    }
    private struct Patch {
        let image: CGImage
        let rectangle: CGRect
    }
    private struct Pose {
        let image: CGImage
        let originalBounds: CGRect
        let patches: [Patch]
    }
    private struct Body {
        let image: CGImage
        let bounds: CGRect
    }

    private let idle: Pose
    private let working: Pose
    private let canvas: CGSize
    var previewImage: CGImage { idle.image }
    var hasBlink: Bool { idle.patches.count == 2 && working.patches.count == 2 }

    private static func eye(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> Eye {
        Eye(target: CGRect(x: x, y: y, width: width, height: height))
    }

    private static let descriptors: [String: Descriptor] = [
        "sunny": .init(split: 652,
            idleEyes: [eye(177, 433, 148, 158), eye(429, 485, 143, 161)],
            workingEyes: [eye(798, 579, 146, 146), eye(1038, 558, 108, 156)]),
        "mochi": .init(split: 639,
            idleEyes: [eye(178, 427, 130, 134), eye(387, 502, 115, 128)],
            workingEyes: [eye(780, 570, 127, 126), eye(995, 570, 117, 126)]),
        "boba": .init(split: 644,
            idleEyes: [eye(187, 430, 186, 193), eye(432, 409, 154, 185)],
            workingEyes: [eye(795, 628, 168, 155), eye(1006, 663, 151, 145)], matchBlinkColors: true),
        "lumi": .init(split: 630,
            idleEyes: [eye(170, 354, 182, 166), eye(405, 409, 170, 165)],
            workingEyes: [eye(735, 538, 190, 157), eye(982, 493, 142, 169)]),
        "mallow": .init(split: 667,
            idleEyes: [eye(170, 319, 150, 146), eye(414, 392, 148, 137)],
            workingEyes: [eye(730, 501, 145, 144), eye(968, 524, 140, 143)]),
        "sprout": .init(split: 590,
            idleEyes: [eye(118, 318, 160, 169), eye(327, 373, 151, 159)],
            workingEyes: [eye(762, 515, 138, 139), eye(977, 551, 117, 137)])
    ]

    init(option: BuiltinCharacterOption, directory: URL) throws {
        guard let descriptor = Self.descriptors[option.id] else {
            throw RobotArt.CharacterError.invalid("That built-in character is unavailable.")
        }
        let open = try Self.load(directory.appendingPathComponent(option.name + ".png"))
        let closed = try? Self.load(directory.appendingPathComponent(option.name + "Blink.png"))
        let bounds = CGRect(x: 0, y: 0, width: open.width, height: open.height)
        idle = try Self.pose(open: open, closed: closed,
            region: CGRect(x: 0, y: 0, width: descriptor.split + 40, height: open.height),
            eyes: descriptor.idleEyes, matchColors: descriptor.matchBlinkColors)
        working = try Self.pose(open: open, closed: closed,
            region: CGRect(x: descriptor.split - 40, y: 0, width: open.width - descriptor.split + 40, height: open.height),
            eyes: descriptor.workingEyes, matchColors: descriptor.matchBlinkColors)
        canvas = CGSize(width: max(idle.originalBounds.width, working.originalBounds.width),
                        height: max(idle.originalBounds.height, working.originalBounds.height))
        guard bounds.contains(idle.originalBounds), bounds.contains(working.originalBounds) else {
            throw RobotArt.CharacterError.invalid("The built-in character has an invalid pose.")
        }
    }

    fileprivate static func load(_ url: URL) throws -> CGImage {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard !data.isEmpty, data.count <= 10 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?, type == "public.png",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == 1254,
              properties[kCGImagePropertyPixelHeight] as? Int == 1254,
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                  [kCGImageSourceShouldCache: true] as CFDictionary),
              ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo) else {
            throw RobotArt.CharacterError.invalid("The built-in character image is unavailable.")
        }
        return image
    }

    private static func pose(open: CGImage, closed: CGImage?, region: CGRect, eyes: [Eye], matchColors: Bool) throws -> Pose {
        let body = try mainBody(open, within: region)
        let rectangle = body.bounds
        let closedBody = closed.flatMap { try? mainBody($0, within: region) }
        let patches = eyes.compactMap { eye -> Patch? in
            let target = eye.target.insetBy(dx: -eye.target.width * 0.11, dy: -eye.target.height * 0.11)
            guard let closedBody, rectangle.contains(target) else { return nil }
            let closedBounds = closedBody.bounds
            // A generated eye-only edit can differ slightly in framing. Register
            // each closed-eye crop to its pose before placing it on the fixed
            // original image; never swap the full character or laptop frame.
            let source = CGRect(
                x: (target.minX - rectangle.minX) * closedBounds.width / rectangle.width,
                y: (target.minY - rectangle.minY) * closedBounds.height / rectangle.height,
                width: target.width * closedBounds.width / rectangle.width,
                height: target.height * closedBounds.height / rectangle.height)
            guard let patch = closedBody.image.cropping(to: source) else { return nil }
            let relative = target.offsetBy(dx: -rectangle.minX, dy: -rectangle.minY)
            let rendered: CGImage
            if matchColors, let base = body.image.cropping(to: relative),
               let matched = matchBorderColors(patch, to: base) { rendered = matched }
            else { rendered = patch }
            return Patch(image: rendered, rectangle: relative)
        }
        return Pose(image: body.image, originalBounds: rectangle, patches: patches)
    }

    /// Ignore isolated generation speckles by finding the main connected alpha
    /// component in each side of the concept sheet. Assets are bounded to 1254².
    private static func mainBody(_ image: CGImage, within region: CGRect) throws -> Body {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { memory in
            guard let context = CGContext(data: memory.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw RobotArt.CharacterError.invalid("The built-in character cannot be decoded.")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let minX = Int(region.minX), maxX = Int(region.maxX)
        let minY = Int(region.minY), maxY = Int(region.maxY)
        var visited = [Bool](repeating: false, count: width * height)
        var bestCount = 0, best = CGRect.zero, bestPixels: [Int] = []
        for y in minY..<maxY { for x in minX..<maxX {
            let start = y * width + x
            guard !visited[start], bytes[start * 4 + 3] >= 64 else { continue }
            visited[start] = true
            var queue = [start], cursor = 0
            var left = x, right = x, top = y, bottom = y
            while cursor < queue.count {
                let value = queue[cursor]; cursor += 1
                let px = value % width, py = value / width
                left = min(left, px); right = max(right, px); top = min(top, py); bottom = max(bottom, py)
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = px + dx, ny = py + dy
                    guard nx >= minX, nx < maxX, ny >= minY, ny < maxY else { continue }
                    let next = ny * width + nx
                    if !visited[next], bytes[next * 4 + 3] >= 64 {
                        visited[next] = true; queue.append(next)
                    }
                } }
            }
            if queue.count > bestCount {
                bestCount = queue.count
                best = CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
                bestPixels = queue
            }
        } }
        guard bestCount > 100 else { throw RobotArt.CharacterError.invalid("The built-in character is empty.") }
        best = best.insetBy(dx: -2, dy: -2).intersection(region).integral
        let cropWidth = Int(best.width), cropHeight = Int(best.height)
        var selected = [UInt8](repeating: 0, count: cropWidth * cropHeight * 4)
        for index in bestPixels {
            // Keep the anti-aliased fringe next to the solid body, but do not
            // follow faint generation speckles into the neighboring pose.
            let px = index % width, py = index / width
            for dy in -2...2 { for dx in -2...2 {
                let x = px + dx, y = py + dy
                guard x >= Int(best.minX), x < Int(best.maxX), y >= Int(best.minY), y < Int(best.maxY) else { continue }
                let output = ((y - Int(best.minY)) * cropWidth + x - Int(best.minX)) * 4
                let input = (y * width + x) * 4
                selected[output] = bytes[input]; selected[output + 1] = bytes[input + 1]
                selected[output + 2] = bytes[input + 2]; selected[output + 3] = bytes[input + 3]
            } }
        }
        guard let provider = CGDataProvider(data: Data(selected) as CFData),
              let cropped = CGImage(width: cropWidth, height: cropHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: cropWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw RobotArt.CharacterError.invalid("The built-in character pose cannot be decoded.")
        }
        return Body(image: cropped, bounds: best)
    }

    @discardableResult
    func draw(in context: CGContext, bounds: CGRect, working isWorking: Bool, phase: Double) -> CGRect {
        let pose = isWorking ? working : idle
        let scale = min(bounds.width / canvas.width, bounds.height / canvas.height)
        let destination = CGRect(x: bounds.midX - CGFloat(pose.image.width) * scale / 2,
            y: bounds.maxY - CGFloat(pose.image.height) * scale,
            width: CGFloat(pose.image.width) * scale, height: CGFloat(pose.image.height) * scale)
        context.interpolationQuality = .high
        Self.draw(pose.image, in: context, rectangle: destination)
        guard Self.isBlinking(at: phase) else { return destination }
        for patch in pose.patches {
            let target = CGRect(x: destination.minX + patch.rectangle.minX * scale,
                y: destination.minY + patch.rectangle.minY * scale,
                width: patch.rectangle.width * scale, height: patch.rectangle.height * scale)
            context.saveGState()
            context.clip(to: target, mask: Self.eyeMask)
            Self.draw(patch.image, in: context, rectangle: target)
            context.restoreGState()
        }
        return destination
    }

    private static let eyeMask: CGImage = {
        let side = 96
        var bytes = [UInt8](repeating: 255, count: side * side)
        for y in 0..<side { for x in 0..<side {
            let px = (Double(x) + 0.5) / Double(side) * 2 - 1
            let py = (Double(y) + 0.5) / Double(side) * 2 - 1
            let radius = pow(pow(abs(px), 4) + pow(abs(py), 4), 0.25)
            let edge = min(1, max(0, (radius - 0.84) / 0.16))
            bytes[y * side + x] = UInt8((edge * edge * (3 - 2 * edge) * 255).rounded())
        } }
        return CGImage(maskWidth: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: side, provider: CGDataProvider(data: Data(bytes) as CFData)!,
            decode: nil, shouldInterpolate: true)!
    }()

    /// Preserve the original glossy visor's low-frequency lighting. Only the
    /// closed-eye patch is adjusted; the stationary base pose is never changed.
    private static func matchBorderColors(_ patch: CGImage, to base: CGImage) -> CGImage? {
        let width = base.width, height = base.height
        func raster(_ image: CGImage) -> [UInt8]? {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let success = bytes.withUnsafeMutableBytes { memory -> Bool in
                guard let context = CGContext(data: memory.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            return success ? bytes : nil
        }
        guard let original = raster(base), var changed = raster(patch), width > 12, height > 12 else { return nil }
        let side = 6
        let corners = [(2, 2), (width - side - 2, 2), (2, height - side - 2), (width - side - 2, height - side - 2)]
        let offsets = corners.map { corner -> [Double] in
            var delta = [Double](repeating: 0, count: 3), count = 0.0
            for y in corner.1..<(corner.1 + side) { for x in corner.0..<(corner.0 + side) {
                let index = (y * width + x) * 4
                guard original[index + 3] >= 200, changed[index + 3] >= 200 else { continue }
                for channel in 0..<3 { delta[channel] += Double(original[index + channel]) - Double(changed[index + channel]) }
                count += 1
            } }
            return delta.map { count > 0 ? $0 / count : 0 }
        }
        for y in 0..<height { for x in 0..<width {
            let fx = Double(x) / Double(width - 1), fy = Double(y) / Double(height - 1)
            let index = (y * width + x) * 4
            for channel in 0..<3 {
                let upper = offsets[0][channel] * (1 - fx) + offsets[1][channel] * fx
                let lower = offsets[2][channel] * (1 - fx) + offsets[3][channel] * fx
                let value = Double(changed[index + channel]) + upper * (1 - fy) + lower * fy
                changed[index + channel] = UInt8(min(Double(changed[index + 3]), max(0, value)).rounded())
            }
        } }
        guard let provider = CGDataProvider(data: Data(changed) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func isBlinking(at phase: Double) -> Bool {
        guard phase.isFinite else { return false }
        var seconds = phase.truncatingRemainder(dividingBy: 5.2)
        if seconds < 0 { seconds += 5.2 }
        return seconds >= 4.6 && seconds < 4.76
    }

    private static func draw(_ image: CGImage, in context: CGContext, rectangle: CGRect) {
        context.saveGState()
        context.translateBy(x: rectangle.minX, y: rectangle.maxY); context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rectangle.size))
        context.restoreGState()
    }
}
