import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main
struct IconGenerator {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else { return }
        guard RobotArt.useSpriteSheet(at: URL(fileURLWithPath: CommandLine.arguments[3])) else {
            throw CompanionErrorIcon.invalidSpriteSheet
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for size in [16, 32, 64, 128, 256, 512, 1024] {
            guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            context.translateBy(x: 0, y: CGFloat(size)); context.scaleBy(x: 1, y: -1)
            context.setShouldAntialias(false)
            context.interpolationQuality = .none
            let inset = CGFloat(size) * 0.05
            RobotArt.draw(in: context, bounds: CGRect(x: inset, y: inset, width: CGFloat(size) - 2 * inset, height: CGFloat(size) - 2 * inset))
            guard let image = context.makeImage() else { continue }
            var names: [String] = []
            if [16, 32, 128, 256, 512].contains(size) { names.append("icon_\(size)x\(size).png") }
            if [32, 64, 256, 512, 1024].contains(size) { names.append("icon_\(size / 2)x\(size / 2)@2x.png") }
            for name in names {
                let url = directory.appendingPathComponent(name)
                guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw CompanionErrorIcon.failed }
            }
        }
        // Modern ICNS chunks carry PNG images. Write the small container directly
        // so building the icon does not need a GUI service or iconutil.
        var chunks = Data()
        func appendLength(_ length: Int, to data: inout Data) {
            var bigEndian = UInt32(length).bigEndian
            withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        }
        for (name, type) in [("icon_16x16.png", "icp4"), ("icon_32x32.png", "icp5"), ("icon_32x32@2x.png", "icp6"),
                             ("icon_128x128.png", "ic07"), ("icon_256x256.png", "ic08"),
                             ("icon_512x512.png", "ic09"), ("icon_512x512@2x.png", "ic10")] {
            let png = try Data(contentsOf: directory.appendingPathComponent(name))
            chunks.append(Data(type.utf8)); appendLength(png.count + 8, to: &chunks); chunks.append(png)
        }
        var icon = Data("icns".utf8); appendLength(chunks.count + 8, to: &icon); icon.append(chunks)
        try icon.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
    }
    enum CompanionErrorIcon: Error { case failed, invalidSpriteSheet }
}
