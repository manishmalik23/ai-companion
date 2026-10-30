import Foundation
import CoreGraphics
import ImageIO

@main
struct CreatureCharacterChecks {
    static func main() throws {
        let resources = URL(fileURLWithPath: "desktop/Resources/Characters")
        let previews = URL(fileURLWithPath: ".build/creature-character-previews")
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "CreatureCharacterChecks", code: checks + 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1
        }
        func render(_ character: RobotArt.Character?, mood: String = "idle", phase: Double = 0,
                    useDefault: Bool = false) -> CGImage {
            let context = CGContext(data: nil, width: 384, height: 416, bitsPerComponent: 8,
                bytesPerRow: 384 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.translateBy(x: 0, y: 416); context.scaleBy(x: 1, y: -1)
            RobotArt.draw(in: context, bounds: CGRect(x: 8, y: 8, width: 368, height: 400),
                mood: mood, phase: phase, character: character, useDefault: useDefault)
            return context.makeImage()!
        }
        func bytes(_ image: CGImage) -> Data { image.dataProvider!.data! as Data }
        func export(_ image: CGImage, _ name: String) throws {
            let destination = CGImageDestinationCreateWithURL(previews.appendingPathComponent(name + ".png") as CFURL,
                "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            try check(CGImageDestinationFinalize(destination), "Export the \(name) preview")
        }
        let originalIDs = ["sunny", "mochi", "boba", "lumi", "mallow", "sprout"]
        let animatedResources = ["PeachPuff", "LavenderMochi", "MintBean", "Nimbo", "Chai", "Plumo"]
        let animatedIDs = ["peach-puff", "lavender-mochi", "mint-bean", "nimbo", "chai", "plumo"]
        try check(RobotArt.builtInOptions.map(\.id) == originalIDs + animatedIDs,
            "The original identities are preserved and six animated characters are appended")
        try check(Set(RobotArt.builtInOptions.map(\.name)).count == 12, "Each character has a unique display name")
        let defaultBefore = bytes(render(nil, useDefault: true))
        for option in RobotArt.builtInOptions.prefix(6) {
            let character = try RobotArt.builtInCharacter(id: option.id, resourceDirectory: resources)
            try check(character.kind == .builtin, "\(option.name) loads through the built-in factory")
            let idle = render(character), work = render(character, mood: "working")
            let idleBlink = render(character, phase: 4.68), workBlink = render(character, mood: "working", phase: 4.68)
            try check(bytes(idle) != bytes(work), "\(option.name) changes to its seated laptop pose while working")
            try check(bytes(work) == bytes(render(character, mood: "running")), "\(option.name) uses its laptop for agent activity")
            try check(bytes(work) == bytes(render(character, mood: "working", phase: 2.0)), "\(option.name)'s body and laptop do not sway")
            try check(bytes(idle) == bytes(render(character, phase: 3.0)), "\(option.name) holds its standing pose between slow blinks")
            try check(bytes(idle) != bytes(idleBlink), "\(option.name)'s standing eyes blink")
            try check(bytes(work) != bytes(workBlink), "\(option.name)'s seated eyes blink")
            try check(bytes(idle) == bytes(render(character, phase: .nan)), "\(option.name) safely holds for non-finite animation time")
            try check(bytes(idle) == bytes(render(character, mood: "review")), "\(option.name) returns to standing after work")
            let waiting = render(character, mood: "waiting")
            try check(bytes(waiting) != bytes(idle) && bytes(waiting) == bytes(render(character, mood: "attention")),
                "\(option.name) uses its standing pose and approval badge when attention is needed")
            let pixelBytes = [UInt8](bytes(idle))
            try check(pixelBytes[3] == 0 && pixelBytes[(416 * 384 - 1) * 4 + 3] == 0,
                "\(option.name) preserves transparent exterior pixels")
            var changed = 0
            let openBytes = [UInt8](bytes(work)), closedBytes = [UInt8](bytes(workBlink))
            for index in stride(from: 0, to: openBytes.count, by: 4) {
                if openBytes[index..<(index + 4)] != closedBytes[index..<(index + 4)] { changed += 1 }
            }
            try check(changed > 0 && changed < 384 * 416 / 8,
                "\(option.name)'s blink changes only a small eye area, not its body or laptop")
            for (suffix, image) in [("idle", idle), ("working", work), ("idle-blink", idleBlink),
                                     ("working-blink", workBlink), ("waiting", waiting)] {
                try export(image, option.id + "-" + suffix)
            }
            RobotArt.setCharacter(character)
            try check(bytes(render(nil, useDefault: true)) == defaultBefore,
                "The Default tile ignores the selected \(option.name) global character")
            try check(bytes(render(nil)) == bytes(idle), "The desktop renderer uses the selected \(option.name)")
            RobotArt.setCharacter(nil)
        }
        // Render the registered source crop independently. Exact output equality
        // catches robot eye/sparkle/badge overlays, crop errors, and fake motion.
        let layoutData = try Data(contentsOf: resources.appendingPathComponent("FluffyLayouts.json"))
        let layouts = try JSONSerialization.jsonObject(with: layoutData) as! [String: Any]
        let registrations = layouts["characters"] as! [String: [String: Any]]
        func sourceFrame(_ image: CGImage, rectangle: [Int], canvas: [Int]) -> CGImage {
            let cell = image.cropping(to: CGRect(x: rectangle[0], y: rectangle[1], width: rectangle[2], height: rectangle[3]))!
            let context = CGContext(data: nil, width: 384, height: 416, bitsPerComponent: 8,
                bytesPerRow: 384 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
            let scale = min(368 / CGFloat(canvas[0]), 400 / CGFloat(canvas[1]))
            let size = CGSize(width: CGFloat(cell.width) * scale, height: CGFloat(cell.height) * scale)
            let target = CGRect(x: 192 - size.width / 2, y: 408 - size.height,
                width: size.width, height: size.height)
            context.translateBy(x: 0, y: 416); context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.translateBy(x: target.minX, y: target.maxY); context.scaleBy(x: 1, y: -1)
            context.draw(cell, in: CGRect(origin: .zero, size: target.size))
            return context.makeImage()!
        }
        let samples: [(mood: String, time: Double, row: Int, column: Int)] = [
            ("idle", 0, 0, 0), ("idle", 4.30, 0, 1), ("idle", 4.45, 0, 2), ("idle", 4.65, 0, 3),
            ("working", 0, 1, 0), ("working", 0.35, 1, 1), ("working", 0.65, 1, 3),
            ("working", 0.95, 1, 1), ("working", 1.25, 1, 0),
            ("working", 4.85, 1, 2), ("working", 5.05, 1, 3),
            ("waiting", 0, 2, 0), ("waiting", 2.95, 2, 1), ("waiting", 3.55, 2, 2), ("waiting", 3.90, 2, 3)
        ]
        for (index, option) in RobotArt.builtInOptions.suffix(6).enumerated() {
            let source = CGImageSourceCreateWithURL(resources.appendingPathComponent(animatedResources[index] + ".png") as CFURL, nil)!
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            try check(image.width == 1254 && image.height == 1254, "\(option.name) has its real four-by-three atlas")
            let character = try RobotArt.builtInCharacter(id: option.id, resourceDirectory: resources)
            let frames = try BuiltinCharacterFrames(option: option, directory: resources)
            let rectangles = registrations[option.id]!["frames"] as! [[Int]]
            let canvas = registrations[option.id]!["canvas"] as! [Int]
            try check(character.kind == .builtin, "\(option.name) loads through the built-in factory")
            for sample in samples {
                let actual = render(character, mood: sample.mood, phase: sample.time)
                let expected = sourceFrame(image, rectangle: rectangles[sample.row * 4 + sample.column], canvas: canvas)
                try check(bytes(actual) == bytes(expected),
                    "\(option.name) renders registered source row \(sample.row), cell \(sample.column) at \(sample.time)s without overlays or motion")
                let context = CGContext(data: nil, width: 384, height: 416, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                let destination = frames.draw(in: context, bounds: CGRect(x: 8, y: 8, width: 368, height: 400),
                    mood: sample.mood, phase: sample.time)
                try check(abs(destination.maxY - 408) < 0.000001 && abs(destination.midX - 192) < 0.000001,
                    "\(option.name) keeps every pose on the same baseline and horizontal center")
                let scale = min(368 / CGFloat(canvas[0]), 400 / CGFloat(canvas[1]))
                let rectangle = rectangles[sample.row * 4 + sample.column]
                try check(abs(destination.width / CGFloat(rectangle[2]) - scale) < 0.000001 &&
                          abs(destination.height / CGFloat(rectangle[3]) - scale) < 0.000001,
                    "\(option.name) keeps the same source scale across all twelve frames")
            }
            let idle = render(character), work = render(character, mood: "working"), waiting = render(character, mood: "waiting")
            try check(bytes(idle) != bytes(work) && bytes(idle) != bytes(waiting), "\(option.name) has distinct real idle, laptop, and attention artwork")
            try check(bytes(work) == bytes(render(character, mood: "running")), "\(option.name) uses its laptop while running agent work")
            try check(bytes(waiting) == bytes(render(character, mood: "attention")), "\(option.name) uses its attention animation for both attention moods")
            try check(bytes(idle) == bytes(render(character, mood: "review")), "\(option.name) returns to its idle row after work")
            for (mood, cycle) in [("idle", 4.74), ("working", 5.23), ("waiting", 4.33)] {
                try check(bytes(render(character, mood: mood, phase: -0.1)) == bytes(render(character, mood: mood, phase: cycle - 0.1)),
                    "\(option.name) wraps negative \(mood) timestamps deterministically")
                for phase in [Double.nan, .infinity, -.infinity] {
                    try check(bytes(render(character, mood: mood, phase: phase)) == bytes(render(character, mood: mood)),
                        "\(option.name) holds its first \(mood) frame for non-finite time")
                }
                let huge = bytes(render(character, mood: mood, phase: .greatestFiniteMagnitude))
                try check(huge == bytes(render(character, mood: mood, phase: .greatestFiniteMagnitude)),
                    "\(option.name) safely renders very large finite \(mood) timestamps")
            }
            let pixelBytes = [UInt8](bytes(idle))
            try check(pixelBytes[3] == 0 && pixelBytes[(416 * 384 - 1) * 4 + 3] == 0,
                "\(option.name) preserves transparent exterior pixels")
            for (suffix, output) in [("idle", idle), ("idle-blink", render(character, phase: 4.45)),
                ("working", work), ("working-type", render(character, mood: "working", phase: 0.35)),
                ("working-blink", render(character, mood: "working", phase: 4.85)),
                ("waiting", waiting), ("waiting-blink", render(character, mood: "waiting", phase: 3.55))] {
                try export(output, option.id + "-" + suffix)
            }
            RobotArt.setCharacter(character)
            try check(bytes(render(nil, useDefault: true)) == defaultBefore, "Default remains the original robot after choosing \(option.name)")
            try check(bytes(render(nil)) == bytes(idle), "The selected \(option.name) renders through the desktop path")
            RobotArt.setCharacter(nil)
        }
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("pip-layout-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try FileManager.default.copyItem(at: resources.appendingPathComponent("PeachPuff.png"), to: fixture.appendingPathComponent("PeachPuff.png"))
        let fixtureLayout = fixture.appendingPathComponent("FluffyLayouts.json")
        func rejectsLayout(_ data: Data?) throws {
            if let data { try data.write(to: fixtureLayout) }
            do {
                _ = try RobotArt.builtInCharacter(id: "peach-puff", resourceDirectory: fixture)
                throw NSError(domain: "CreatureCharacterChecks", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid or missing atlas registration was accepted"])
            } catch RobotArt.CharacterError.invalid { checks += 1 }
        }
        try rejectsLayout(nil)
        try layoutData.write(to: fixtureLayout)
        try check(try RobotArt.builtInCharacter(id: "peach-puff", resourceDirectory: fixture).kind == .builtin,
            "The isolated metadata validation fixture first accepts the genuine atlas and registration")
        try rejectsLayout(Data("not JSON".utf8))
        for (key, value) in [("version", 2), ("width", 1253), ("height", 1253), ("columns", 3), ("rows", 4)] {
            var changed = layouts; changed[key] = value
            try rejectsLayout(JSONSerialization.data(withJSONObject: changed))
        }
        var incomplete = layouts
        var missingCharacter = registrations; missingCharacter.removeValue(forKey: "mint-bean")
        incomplete["characters"] = missingCharacter
        try rejectsLayout(JSONSerialization.data(withJSONObject: incomplete))
        let invalidEntries: [[String: Any]] = [
            ["file": "../PeachPuff.png"], ["frames": Array((registrations["peach-puff"]!["frames"] as! [[Int]]).dropLast())],
            ["canvas": [1, 1]], ["canvas": [315, 418]],
            ["frames": Array(repeating: [0, 0, 0, 1], count: 12)],
            ["frames": Array(repeating: [313, 0, 1, 1], count: 12)],
            ["frames": Array(repeating: [0, 417, 2, 2], count: 12)],
            ["frames": Array(repeating: [-1, 0, 2, 2], count: 12)],
            ["frames": Array(repeating: [0, 0, 2], count: 12)],
            ["frames": Array(repeating: [0.5, 0, 2, 2], count: 12)]
        ]
        for invalid in invalidEntries {
            var changed = layouts, entries = registrations, entry = registrations["peach-puff"]!
            for (key, value) in invalid { entry[key] = value }
            entries["peach-puff"] = entry; changed["characters"] = entries
            try rejectsLayout(JSONSerialization.data(withJSONObject: changed))
        }
        try FileManager.default.copyItem(at: resources.appendingPathComponent("Sunny.png"), to: fixture.appendingPathComponent("Sunny.png"))
        try check(try RobotArt.builtInCharacter(id: "sunny", resourceDirectory: fixture).kind == .builtin,
            "Original characters still load when the new atlas registration is malformed")
        for invalid in ["unknown", "../Lumi", "Lumi", "", "lumi.png"] {
            do {
                _ = try RobotArt.builtInCharacter(id: invalid, resourceDirectory: resources)
                throw NSError(domain: "CreatureCharacterChecks", code: -1)
            } catch RobotArt.CharacterError.invalid { checks += 1 }
        }
        let sample = try Data(contentsOf: resources.appendingPathComponent("Lumi.png"))
        let still = try RobotArt.character(data: sample, kind: .still)
        RobotArt.setCharacter(still)
        try check(bytes(render(nil, useDefault: true)) == defaultBefore,
            "The Default tile ignores a previously imported still image")
        try check(bytes(render(nil)) != defaultBefore, "The still-image regression fixture really is selected globally")
        RobotArt.setCharacter(nil)
        try check(RobotArt.useSpriteSheet(at: URL(fileURLWithPath: "desktop/Resources/PipSpriteSheet.png")),
            "The default-source regression fixture loads an explicit atlas")
        try check(bytes(render(nil, useDefault: true)) == defaultBefore,
            "An explicit build-time atlas does not replace the Default tile source")
        do {
            _ = try RobotArt.character(data: sample, kind: .builtin)
            throw NSError(domain: "CreatureCharacterChecks", code: -1)
        } catch RobotArt.CharacterError.invalid { checks += 1 }
        try check(!BuiltinCharacterFrames.isBlinking(at: 0) && !BuiltinCharacterFrames.isBlinking(at: 4.59) &&
            BuiltinCharacterFrames.isBlinking(at: 4.6) && BuiltinCharacterFrames.isBlinking(at: 4.75) &&
            !BuiltinCharacterFrames.isBlinking(at: 4.76), "Blink timing lasts 160 ms in each 5.2-second cycle")
        try check(!BuiltinCharacterFrames.isBlinking(at: .infinity) && !BuiltinCharacterFrames.isBlinking(at: .nan),
            "Non-finite phases never blink")
        print("Passed \(checks) built-in character checks. Offscreen rendering only; no windows, agent calls, or settings changed.")
    }
}
