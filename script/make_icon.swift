import AppKit

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: swift make_icon.swift <logo.png> <output.iconset>\n", stderr)
    exit(2)
}
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let source = NSImage(contentsOf: sourceURL), source.size.width > 0, source.size.height > 0 else {
    fputs("Could not load the app logo.\n", stderr)
    exit(1)
}
// The supplied image has transparent padding. Keep all visible artwork while
// fitting its bounds to the standard Mac icon canvas instead of shrinking it twice.
var sourceRect = NSRect(origin: .zero, size: source.size)
if let bitmap = NSBitmapImageRep(data: try Data(contentsOf: sourceURL)), bitmap.hasAlpha,
   !bitmap.isPlanar, bitmap.bitsPerSample == 8, let bytes = bitmap.bitmapData {
    let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
    let bytesPerPixel = bitmap.bitsPerPixel / 8
    let alphaOffset = bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : bitmap.samplesPerPixel - 1
    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width where bytes[y * bitmap.bytesPerRow + x * bytesPerPixel + alphaOffset] > 1 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    if maxX >= minX, maxY >= minY {
        let sx = source.size.width / CGFloat(width), sy = source.size.height / CGFloat(height)
        sourceRect = NSRect(x: CGFloat(minX) * sx, y: CGFloat(height - 1 - maxY) * sy,
                            width: CGFloat(maxX - minX + 1) * sx, height: CGFloat(maxY - minY + 1) * sy)
    }
}
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let n = CGFloat(pixels)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            fputs("Could not create an app icon canvas.\n", stderr)
            exit(1)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: n, height: n).fill()
        let factor = min(n * 0.88 / sourceRect.width, n * 0.88 / sourceRect.height)
        let width = sourceRect.width * factor, height = sourceRect.height * factor
        let rect = NSRect(x: (n - width) / 2, y: (n - height) / 2, width: width, height: height)
        source.draw(in: rect, from: sourceRect, operation: .sourceOver, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            fputs("Could not render an app icon size.\n", stderr)
            exit(1)
        }
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"), options: .atomic)
    }
}
