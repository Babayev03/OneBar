// Renders the OneBar app icon: dark gradient squircle with three ring arcs
// (green / red / blue — CPU, MEM, DISK). Run from the repo root:
//   swift scripts/make-icon.swift
// then:
//   iconutil -c icns build/AppIcon.iconset -o Bundle/AppIcon.icns
import AppKit

func render(_ n: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: n, height: n)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(n)
    // Standard macOS icon margin: artwork fills ~80% of the canvas.
    let inset = s * 0.10
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.2237, yRadius: rect.width * 0.2237)

    NSGradient(
        starting: NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.21, alpha: 1),
        ending: NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.10, alpha: 1)
    )!.draw(in: squircle, angle: -90)

    // Subtle top edge highlight.
    squircle.lineWidth = max(s * 0.004, 0.5)
    NSColor.white.withAlphaComponent(0.12).setStroke()
    squircle.stroke()

    // Three arcs of one ring, with gaps — echoes the CPU/MEM/DISK rings.
    let center = NSPoint(x: rect.midX, y: rect.midY)
    let radius = rect.width * 0.30
    let lineWidth = rect.width * 0.085
    let gap: CGFloat = 14 // degrees of gap on each side of a segment

    let segments: [(NSColor, CGFloat, CGFloat)] = [
        (NSColor.systemGreen, 90 + gap, 210 - gap),   // top-left third
        (NSColor.systemRed, 210 + gap, 330 - gap),    // bottom third
        (NSColor.systemBlue, 330 + gap, 450 - gap)    // top-right third
    ]
    for (color, start, end) in segments {
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end)
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }

    // Small center dot, like a gauge hub.
    let dotR = rect.width * 0.045
    NSColor.white.withAlphaComponent(0.85).setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - dotR, y: center.y - dotR, width: dotR * 2, height: dotR * 2)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
for (name, size) in entries {
    let rep = render(size)
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: iconset.appendingPathComponent("\(name).png"))
}
print("iconset written to \(iconset.path)")
