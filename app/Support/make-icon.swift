// Draws dmbar's icon and writes AppIcon.iconset beside this file.
// Run: swift Support/make-icon.swift && iconutil -c icns Support/AppIcon.iconset -o Support/AppIcon.icns
import AppKit

let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // The macOS icon grid: the shape fills 824/1024 of the canvas.
    let inset = s * 100 / 1024
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [
        NSColor(red: 0.98, green: 0.69, blue: 0.25, alpha: 1), NSColor(red: 0.91, green: 0.19, blue: 0.42, alpha: 1),
        NSColor(red: 0.51, green: 0.23, blue: 0.86, alpha: 1),
    ])!.draw(in: shape, angle: 50)
    // A soft highlight across the top, for a glassy read.
    shape.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: 270)
    let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.46, weight: .semibold)
    if let plane = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let tinted = NSImage(size: plane.size, flipped: false) { r in
            plane.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let size = tinted.size
        tinted.draw(in: NSRect(x: rect.midX - size.width / 2 - rect.width * 0.02, y: rect.midY - size.height / 2 - rect.width * 0.01,
                               width: size.width, height: size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try draw(px).write(to: dir.appendingPathComponent("icon_\(name).png"))
}
