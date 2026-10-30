import Foundation
import CoreGraphics
import ImageIO

@main
struct RobotAnimationChecks {
    static func main() throws {
        let url = URL(fileURLWithPath: "desktop/Resources/PipSpriteSheet.png")
        let data = try Data(contentsOf: url)
        let character = try RobotArt.character(data: data, kind: .sprite)
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        func render(_ mood: String, _ phase: Double, custom: Bool = true) -> CGImage {
            let context = CGContext(data: nil, width: 192, height: 208, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.translateBy(x: 0, y: 208); context.scaleBy(x: 1, y: -1)
            RobotArt.draw(in: context, bounds: CGRect(x: 0, y: 0, width: 192, height: 208),
                mood: mood, phase: phase, character: custom ? character : nil)
            return context.makeImage()!
        }
        func bytes(_ image: CGImage) -> Data { image.dataProvider!.data! as Data }
        let idle = render("idle", 0), work = render("working", 0)
        check(bytes(idle) != bytes(work), "Working switches to the laptop pose")
        check(bytes(work) == bytes(render("running", 0)), "Running agent uses the working laptop")
        check(bytes(idle) == bytes(render("review", 0)), "Review does not leave a laptop showing")
        check(bytes(idle) == bytes(render("idle", 3)), "Idle holds eyes open for several seconds")
        check(bytes(idle) != bytes(render("idle", 4.45)), "Idle blink advances")
        check(bytes(work) != bytes(render("working", 0.3)), "Laptop mark gently pulses")
        let second = render("working", 0.3)
        let a = [UInt8](bytes(work)), b = [UInt8](bytes(second))
        var outsideChanges = 0
        for y in 0..<208 { for x in 0..<192 {
            // Only the small laptop mark may change; the rendered bitmap uses
            // the same y-down registration as the visible companion.
            if !(x >= 80 && x <= 102 && y >= 132 && y <= 155) {
                let offset = (y * work.bytesPerRow) + x * 4
                if a[offset..<(offset + 4)] != b[offset..<(offset + 4)] { outsideChanges += 1 }
            }
        } }
        check(outsideChanges == 0, "Body and laptop stay stationary while the mark animates")
        check(bytes(work) != bytes(render("working", 4.68)), "Seated robot still blinks slowly")
        check(bytes(work) != bytes(render("waiting", 0)), "Approval replaces working pose")
        check(bytes(render("waiting", 0)) == bytes(render("attention", 0)), "Attention is an approval pose")
        check(bytes(idle) == bytes(render("idle", .nan)), "Invalid animation time falls back safely")
        check(RobotArt.useSpriteSheet(at: url), "Build-time icon can use Pip's atlas")
        check(bytes(idle) == bytes(render("idle", 0, custom: false)), "Bundled path and imported animation agree")
        let output = URL(fileURLWithPath: ".build/robot-animation-previews")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, image) in [("idle", idle), ("working", work), ("waiting", render("waiting", 0)),
                              ("blink", render("idle", 4.45)), ("typing", render("working", 0.3)),
                              ("working-blink", render("working", 4.68))] {
            let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(name + ".png") as CFURL,
                "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            check(CGImageDestinationFinalize(destination), "Preview exports")
        }
        print("Passed \(checks) robot animation and state checks")
    }
}
