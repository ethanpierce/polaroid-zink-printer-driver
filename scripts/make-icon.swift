// Draws the app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Background tile
    let tile = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s),
                            xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(red: 0.16, green: 0.20, blue: 0.32, alpha: 1),
               ending: NSColor(red: 0.07, green: 0.09, blue: 0.16, alpha: 1))!.draw(in: tile, angle: -90)

    // Printer body
    let body = NSBezierPath(roundedRect: NSRect(x: 230 * s, y: 250 * s, width: 564 * s, height: 250 * s),
                            xRadius: 48 * s, yRadius: 48 * s)
    NSGradient(starting: NSColor(white: 0.97, alpha: 1), ending: NSColor(white: 0.80, alpha: 1))!.draw(in: body, angle: -90)
    NSColor(white: 0.25, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 330 * s, y: 455 * s, width: 364 * s, height: 22 * s), xRadius: 11 * s, yRadius: 11 * s).fill()
    NSColor(red: 0.30, green: 0.85, blue: 0.45, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 690 * s, y: 300 * s, width: 40 * s, height: 40 * s)).fill()

    // Print coming out of the slot
    let card = NSRect(x: 372 * s, y: 470 * s, width: 280 * s, height: 400 * s)
    NSShadow().then { $0.shadowColor = NSColor(white: 0, alpha: 0.35); $0.shadowBlurRadius = 20 * s; $0.shadowOffset = NSSize(width: 0, height: -6 * s); $0.set() }
    NSColor.white.setFill()
    NSBezierPath(rect: card).fill()
    NSShadow().set()
    let photo = card.insetBy(dx: 22 * s, dy: 22 * s)
    NSGradient(colors: [NSColor(red: 0.98, green: 0.55, blue: 0.30, alpha: 1),
                        NSColor(red: 0.95, green: 0.35, blue: 0.50, alpha: 1),
                        NSColor(red: 0.40, green: 0.35, blue: 0.85, alpha: 1)])!.draw(in: photo, angle: 90)
    NSColor(red: 1, green: 0.92, blue: 0.55, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: photo.midX - 45 * s, y: photo.midY + 20 * s, width: 90 * s, height: 90 * s)).fill()
    let hills = NSBezierPath()
    hills.move(to: NSPoint(x: photo.minX, y: photo.minY))
    hills.line(to: NSPoint(x: photo.minX, y: photo.minY + 120 * s))
    hills.curve(to: NSPoint(x: photo.maxX, y: photo.minY + 90 * s),
                controlPoint1: NSPoint(x: photo.minX + 90 * s, y: photo.minY + 210 * s),
                controlPoint2: NSPoint(x: photo.maxX - 90 * s, y: photo.minY + 20 * s))
    hills.line(to: NSPoint(x: photo.maxX, y: photo.minY))
    hills.close()
    NSColor(red: 0.13, green: 0.25, blue: 0.40, alpha: 1).setFill()
    hills.fill()

    // Slot lip in front of the print
    NSColor(white: 0.88, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 300 * s, y: 440 * s, width: 424 * s, height: 40 * s), xRadius: 14 * s, yRadius: 14 * s).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

extension NSObject {
    @discardableResult func then(_ f: (Self) -> Void) -> Self { f(self); return self }
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(points * scale)
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try draw(size: px).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}

let out = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "wrote \(out.path)" : "iconutil failed")
