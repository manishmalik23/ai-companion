// Reproduce FluffyLayouts.json without changing the generated PNG artwork.
// Run from the repository root:
//   swift -module-cache-path .build/module-cache design/characters/measure_fluffy_layouts.swift
// Optional: --resources <directory> --output <file> --allow-clipped
// By default a main component touching a cell edge rejects the measurement.
// --allow-clipped is for diagnosing an existing source sheet before replacing it.

import Foundation
import CoreGraphics
import ImageIO

struct MeasurementError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

let width = 1254, height = 1254, columns = 4, rows = 3
let characters = [
    (id: "peach-puff", file: "PeachPuff.png"),
    (id: "lavender-mochi", file: "LavenderMochi.png"),
    (id: "mint-bean", file: "MintBean.png"),
    (id: "nimbo", file: "Nimbo.png"),
    (id: "chai", file: "Chai.png"),
    (id: "plumo", file: "Plumo.png")
]

func report(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func pixels(at url: URL) throws -> [UInt8] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          CGImageSourceGetType(source) as String? == "public.png",
          CGImageSourceGetCount(source) == 1,
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          image.width == width, image.height == height,
          ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo) else {
        throw MeasurementError("\(url.lastPathComponent) must be one transparent \(width)×\(height) PNG.")
    }
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    try bytes.withUnsafeMutableBytes { memory in
        guard let context = CGContext(data: memory.baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MeasurementError("Cannot read \(url.lastPathComponent) pixels.")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return bytes
}

struct FrameMeasurement {
    let rectangle: [Int]
    let componentPixels: Int
    let boundaryPixels: Int
    let otherComponentPixels: Int
}

// All coordinates are absolute, top-left-origin atlas pixels. Crop cells with
// integer floor partitions so the 1254px-wide sheet loses no odd-column pixels.
func measure(_ bytes: [UInt8], row: Int, column: Int) throws -> FrameMeasurement {
    let minX = column * width / columns, maxX = (column + 1) * width / columns
    let minY = row * height / rows, maxY = (row + 1) * height / rows
    let cellWidth = maxX - minX, cellHeight = maxY - minY
    var visited = [UInt8](repeating: 0, count: cellWidth * cellHeight)
    var queue = [Int](); queue.reserveCapacity(cellWidth * cellHeight)
    var bestCount = 0, bestLeft = 0, bestTop = 0, bestRight = 0, bestBottom = 0
    var bestBoundary = 0, totalPixels = 0
    for y in 0..<cellHeight { for x in 0..<cellWidth {
        let start = y * cellWidth + x
        guard visited[start] == 0,
              bytes[((y + minY) * width + x + minX) * 4 + 3] >= 64 else { continue }
        visited[start] = 1
        queue.removeAll(keepingCapacity: true); queue.append(start)
        var cursor = 0, left = x, right = x, top = y, bottom = y, boundary = 0
        while cursor < queue.count {
            let current = queue[cursor]; cursor += 1
            let px = current % cellWidth, py = current / cellWidth
            left = min(left, px); right = max(right, px)
            top = min(top, py); bottom = max(bottom, py)
            if px == 0 || px == cellWidth - 1 || py == 0 || py == cellHeight - 1 { boundary += 1 }
            for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                let nx = px + dx, ny = py + dy
                guard nx >= 0, nx < cellWidth, ny >= 0, ny < cellHeight else { continue }
                let next = ny * cellWidth + nx
                if visited[next] == 0 && bytes[((ny + minY) * width + nx + minX) * 4 + 3] >= 64 {
                    visited[next] = 1; queue.append(next)
                }
            } }
        }
        totalPixels += queue.count
        if queue.count > bestCount {
            bestCount = queue.count; bestLeft = left; bestRight = right
            bestTop = top; bestBottom = bottom; bestBoundary = boundary
        }
    } }
    guard bestCount > 100 else { throw MeasurementError("Empty main component at row \(row), column \(column).") }
    // Keep a two-pixel fringe, without including pixels from adjacent cells.
    let x = max(minX, minX + bestLeft - 2), y = max(minY, minY + bestTop - 2)
    let right = min(maxX, minX + bestRight + 3), bottom = min(maxY, minY + bestBottom + 3)
    return FrameMeasurement(rectangle: [x, y, right - x, bottom - y],
        componentPixels: bestCount, boundaryPixels: bestBoundary,
        otherComponentPixels: totalPixels - bestCount)
}

do {
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    var resources = project.appendingPathComponent("desktop/Resources/Characters")
    var requestedOutput: URL?
    var allowClipped = false
    let arguments = Array(CommandLine.arguments.dropFirst())
    var index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--resources", "--output":
            guard index + 1 < arguments.count else { throw MeasurementError("Missing value for \(arguments[index]).") }
            let url = URL(fileURLWithPath: arguments[index + 1])
            if arguments[index] == "--resources" { resources = url } else { requestedOutput = url }
            index += 2
        case "--allow-clipped": allowClipped = true; index += 1
        default: throw MeasurementError("Unknown argument: \(arguments[index])")
        }
    }
    let output = requestedOutput ?? resources.appendingPathComponent("FluffyLayouts.json")
    var entries: [String: Any] = [:], clippedFrames = 0
    for character in characters {
        let bytes = try pixels(at: resources.appendingPathComponent(character.file))
        var frames: [[Int]] = [], maxWidth = 0, maxHeight = 0, disconnectedPixels = 0
        for row in 0..<rows { for column in 0..<columns {
            let frame = try measure(bytes, row: row, column: column)
            frames.append(frame.rectangle)
            maxWidth = max(maxWidth, frame.rectangle[2]); maxHeight = max(maxHeight, frame.rectangle[3])
            disconnectedPixels += frame.otherComponentPixels
            if frame.boundaryPixels > 0 {
                clippedFrames += 1
                report("CLIPPED \(character.file) row \(row) column \(column): \(frame.boundaryPixels) main-component pixels touch the cell boundary.")
            }
        } }
        entries[character.id] = ["file": character.file, "frames": frames, "canvas": [maxWidth, maxHeight]]
        report("\(character.file): 12 frames; canvas \(maxWidth)×\(maxHeight); \(disconnectedPixels) disconnected alpha≥64 pixels excluded from main-component measurement.")
    }
    if clippedFrames > 0 && !allowClipped {
        throw MeasurementError("Rejected \(clippedFrames) clipped main components. Regenerate those sheets, or use --allow-clipped for diagnostics.")
    }
    let document: [String: Any] = ["version": 1, "width": width, "height": height,
        "columns": columns, "rows": rows, "characters": entries]
    var data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    data.append(0x0a)
    try data.write(to: output, options: .atomic)
    report("Wrote \(output.lastPathComponent). \(clippedFrames) clipped frames.")
} catch {
    report("Measurement failed: \(error)")
    exit(1)
}
