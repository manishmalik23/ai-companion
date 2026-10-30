import AppKit

// Finder copies applications but does not launch them. Keep both steps visible
// in the disk image so installation does not depend on Spotlight search results.
let width = 640, height = 360
guard CommandLine.arguments.count == 2,
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2,
                                    pixelsHigh: height * 2, bitsPerSample: 8,
                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot render installer background") }
bitmap.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.cgContext.scaleBy(x: 2, y: 2)
NSColor.white.setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

func text(_ value: String, top: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .black) {
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
    let string = value as NSString, bounds = string.size(withAttributes: attributes)
    string.draw(at: NSPoint(x: (CGFloat(width) - bounds.width) / 2,
                           y: CGFloat(height) - top - bounds.height), withAttributes: attributes)
}
text("Install Pip", top: 22, size: 24, weight: .semibold)
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 267, y: 202))
for point in [NSPoint(x: 330, y: 202), NSPoint(x: 330, y: 218), NSPoint(x: 385, y: 185),
              NSPoint(x: 330, y: 152), NSPoint(x: 330, y: 168), NSPoint(x: 267, y: 168)] { arrow.line(to: point) }
arrow.close()
NSColor(calibratedRed: 0.18, green: 0.35, blue: 0.84, alpha: 1).setFill()
arrow.fill()
text("1. Drag Pip onto Applications.", top: 246, size: 16, weight: .medium)
text("2. Open Applications, then double-click Pip.", top: 276, size: 16, weight: .medium)
text("The robot appears after you open Pip.", top: 316, size: 13, color: NSColor(calibratedWhite: 0.38, alpha: 1))
NSGraphicsContext.restoreGraphicsState()
guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode installer background") }
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
