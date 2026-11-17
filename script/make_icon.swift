import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let n = CGFloat(pixels)
        NSColor(calibratedRed: 0.014, green: 0.028, blue: 0.02, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: n * 0.06, y: n * 0.06, width: n * 0.88, height: n * 0.88), xRadius: n * 0.21, yRadius: n * 0.21).fill()
        let green = NSColor(calibratedRed: 57 / 255, green: 1, blue: 106 / 255, alpha: 1)
        green.setStroke()
        let border = NSBezierPath(roundedRect: NSRect(x: n * 0.12, y: n * 0.12, width: n * 0.76, height: n * 0.76), xRadius: n * 0.16, yRadius: n * 0.16)
        border.lineWidth = n * 0.012; border.stroke()
        if let symbol = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: n * 0.57, weight: .semibold)) {
            let tinted = NSImage(size: symbol.size)
            tinted.lockFocus(); symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1); green.setFill(); NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop); tinted.unlockFocus()
            tinted.draw(in: NSRect(x: n * 0.22, y: n * 0.22, width: n * 0.56, height: n * 0.56))
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let data = bitmap.representation(using: .png, properties: [:])!
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
