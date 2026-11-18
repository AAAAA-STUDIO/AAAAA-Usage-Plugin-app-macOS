import AppKit
import Foundation

guard CommandLine.arguments.count == 4 else {
    fputs("Usage: stamp-installer-version.swift <input.png> <version> <output.png>\n", stderr)
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let version = CommandLine.arguments[2]
let outputURL = URL(fileURLWithPath: CommandLine.arguments[3])
guard let sourceBitmap = NSBitmapImageRep(data: try Data(contentsOf: inputURL)) else {
    fputs("Cannot decode installer artwork pixels.\n", stderr)
    exit(1)
}

guard let source = NSImage(contentsOf: inputURL) else {
    fputs("Cannot read installer artwork: \(inputURL.path)\n", stderr)
    exit(1)
}

let width = 900
let height = 521
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: width,
    pixelsHigh: height,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)
guard let bitmap else {
    fputs("Cannot allocate installer artwork canvas.\n", stderr)
    exit(1)
}

guard let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Cannot create installer artwork graphics context.\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
graphics.imageInterpolation = .high
source.draw(
    in: NSRect(x: 0, y: 0, width: width, height: height),
    from: NSRect(origin: .zero, size: source.size),
    operation: .copy,
    fraction: 1
)

// Repaint the small upper-right label by interpolating the original background
// colors at both edges. This preserves the artwork's gradient without a patch box.
let patchLeft = 786
let patchRight = 876
for y in (height - 40)..<(height - 15) {
    let pixelY = height - y - 1
    guard let left = sourceBitmap.colorAt(x: patchLeft - 1, y: pixelY)?.usingColorSpace(.deviceRGB),
          let right = sourceBitmap.colorAt(x: patchRight + 1, y: pixelY)?.usingColorSpace(.deviceRGB),
          let rowGradient = NSGradient(starting: left, ending: right) else {
        fputs("Cannot sample installer background near the version label.\n", stderr)
        exit(1)
    }
    rowGradient.draw(
        in: NSRect(x: patchLeft, y: y, width: patchRight - patchLeft, height: 1),
        angle: 0
    )
}

let label = "VERSION \(version)" as NSString
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 10, weight: .bold),
    .foregroundColor: NSColor(calibratedRed: 0.43, green: 0.50, blue: 0.62, alpha: 1),
    .kern: 0.7
]
let labelSize = label.size(withAttributes: attributes)
label.draw(
    at: NSPoint(x: CGFloat(width - 36) - labelSize.width, y: CGFloat(height - 30)),
    withAttributes: attributes
)

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Cannot encode installer artwork as PNG.\n", stderr)
    exit(1)
}
do {
    try png.write(to: outputURL, options: .atomic)
} catch {
    fputs("Cannot write installer artwork: \(error)\n", stderr)
    exit(1)
}
