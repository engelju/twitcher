// Generates AppIcon.icns: a macOS-style rounded-rect icon in Twitch purple
// with a play glyph and a chat-bubble notch.
//
// Usage: swift scripts/make-icon.swift <output-dir>

import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build"
let iconsetURL = URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.iconset")
let icnsURL = URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.icns")

func draw(in size: CGFloat) {
    let s = size

    // Big Sur-style icon: rounded rect inset ~10% on each side.
    let inset = s * 0.10
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // Twitch-purple vertical gradient.
    let top = NSColor(calibratedRed: 0.663, green: 0.396, blue: 1.0, alpha: 1)
    let bottom = NSColor(calibratedRed: 0.372, green: 0.145, blue: 0.702, alpha: 1)
    NSGradient(starting: top, ending: bottom)!.draw(in: squircle, angle: -90)

    // Chat bubble (upper right), drawn softly translucent behind the play glyph.
    let bubbleRect = NSRect(x: s * 0.56, y: s * 0.58, width: s * 0.20, height: s * 0.15)
    let bubble = NSBezierPath(roundedRect: bubbleRect, xRadius: s * 0.04, yRadius: s * 0.04)
    bubble.move(to: NSPoint(x: bubbleRect.minX + bubbleRect.width * 0.25, y: bubbleRect.minY))
    bubble.line(to: NSPoint(x: bubbleRect.minX + bubbleRect.width * 0.20, y: bubbleRect.minY - s * 0.035))
    bubble.line(to: NSPoint(x: bubbleRect.minX + bubbleRect.width * 0.45, y: bubbleRect.minY))
    NSColor.white.withAlphaComponent(0.35).setFill()
    bubble.fill()

    // Play triangle, rounded via a thick round-joined stroke.
    let triangle = NSBezierPath()
    triangle.move(to: NSPoint(x: s * 0.375, y: s * 0.30))
    triangle.line(to: NSPoint(x: s * 0.375, y: s * 0.64))
    triangle.line(to: NSPoint(x: s * 0.68, y: s * 0.47))
    triangle.close()
    triangle.lineJoinStyle = .round
    triangle.lineWidth = s * 0.06
    NSColor.white.setFill()
    NSColor.white.setStroke()
    triangle.fill()
    triangle.stroke()
}

func renderPNG(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    draw(in: CGFloat(pixels))
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
try? fm.removeItem(at: iconsetURL)
try! fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    try! renderPNG(pixels: points)
        .write(to: iconsetURL.appendingPathComponent("icon_\(points)x\(points).png"))
    try! renderPNG(pixels: points * 2)
        .write(to: iconsetURL.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fputs("iconutil failed\n", stderr)
    exit(1)
}
print("Wrote \(icnsURL.path)")
