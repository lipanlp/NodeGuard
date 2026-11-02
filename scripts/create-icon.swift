import AppKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
        (transform as NSAffineTransform).concat()
        let tile = NSBezierPath(roundedRect: NSRect(x: 54, y: 54, width: 916, height: 916), xRadius: 210, yRadius: 210)
        NSColor(calibratedRed: 0.12, green: 0.29, blue: 0.58, alpha: 1).setFill(); tile.fill()
        let points = [NSPoint(x: 295, y: 725), NSPoint(x: 730, y: 725), NSPoint(x: 512, y: 272)]
        let lines = NSBezierPath(); lines.move(to: points[0]); lines.line(to: points[1]); lines.line(to: points[2]); lines.close()
        lines.lineWidth = 25; NSColor(calibratedRed: 0.32, green: 0.77, blue: 0.95, alpha: 0.8).setStroke(); lines.stroke()
        for p in points { NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: p.x - 43, y: p.y - 43, width: 86, height: 86)).fill() }
        let shield = NSBezierPath(); shield.move(to: NSPoint(x: 512, y: 738)); shield.line(to: NSPoint(x: 674, y: 666)); shield.line(to: NSPoint(x: 661, y: 490)); shield.curve(to: NSPoint(x: 512, y: 357), controlPoint1: NSPoint(x: 647, y: 424), controlPoint2: NSPoint(x: 580, y: 378)); shield.curve(to: NSPoint(x: 363, y: 490), controlPoint1: NSPoint(x: 444, y: 378), controlPoint2: NSPoint(x: 377, y: 424)); shield.line(to: NSPoint(x: 350, y: 666)); shield.close()
        NSColor(calibratedRed: 0.10, green: 0.65, blue: 0.74, alpha: 1).setFill(); shield.fill(); NSColor.white.setStroke(); shield.lineWidth = 17; shield.stroke()
        let check = NSBezierPath(); check.move(to: NSPoint(x: 431, y: 553)); check.line(to: NSPoint(x: 489, y: 499)); check.line(to: NSPoint(x: 596, y: 620)); check.lineWidth = 34; check.lineCapStyle = .round; check.lineJoinStyle = .round; check.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
