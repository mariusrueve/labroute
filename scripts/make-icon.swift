// Draws the LabRoute app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift [output-dir-for-preview-png]
import AppKit

/// Draws the icon on a 1024-point canvas scaled to `size` pixels.
func drawIcon(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    let k = CGFloat(size) / 1024
    context.scaleBy(x: k, y: k)
    // NSShadow metrics are in device pixels and ignore the scale above.
    func shadow(alpha: CGFloat, y: CGFloat, blur: CGFloat) -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
        shadow.shadowOffset = NSSize(width: 0, height: y * k)
        shadow.shadowBlurRadius = blur * k
        return shadow
    }

    // macOS icon grid: 824-point rounded square centred on a 1024 canvas, with a soft shadow.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    shadow(alpha: 0.28, y: -12, blur: 24).set()
    NSColor(srgbRed: 0.08, green: 0.16, blue: 0.38, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.27, green: 0.52, blue: 0.98, alpha: 1),
                        NSColor(srgbRed: 0.11, green: 0.25, blue: 0.66, alpha: 1),
                        NSColor(srgbRed: 0.06, green: 0.13, blue: 0.36, alpha: 1)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: tile, angle: -90)
    // Gentle top highlight.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)

    // The route: an S-shaped path from a hollow start node to a solid destination node.
    let lineWidth: CGFloat = 58, radius: CGFloat = 98
    let start = NSPoint(x: 318, y: 316), end = NSPoint(x: 706, y: 708)
    let path = NSBezierPath()
    // Begin inside the ring's stroke so the round cap never shows in its hole.
    path.move(to: NSPoint(x: start.x + 75, y: start.y))
    path.line(to: NSPoint(x: 610, y: start.y))
    path.appendArc(withCenter: NSPoint(x: 610, y: start.y + radius), radius: radius, startAngle: -90, endAngle: 90)
    path.line(to: NSPoint(x: 414, y: start.y + 2 * radius))
    path.appendArc(withCenter: NSPoint(x: 414, y: start.y + 3 * radius), radius: radius, startAngle: 270, endAngle: 90, clockwise: true)
    path.line(to: NSPoint(x: end.x - 40, y: end.y))
    path.lineWidth = lineWidth
    path.lineCapStyle = .round
    path.lineJoinStyle = .round

    shadow(alpha: 0.30, y: -10, blur: 18).set()
    // One transparency layer, so overlapping parts cast a single shadow.
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    NSColor.white.setStroke()
    path.stroke()

    let ring = NSBezierPath(ovalIn: NSRect(x: start.x - 60, y: start.y - 60, width: 120, height: 120))
    ring.lineWidth = 34
    ring.stroke()

    // Destination node in a warm accent: the "unlocked" end of the route.
    NSColor(srgbRed: 1.0, green: 0.76, blue: 0.20, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: end.x - 74, y: end.y - 74, width: 148, height: 148)).fill()
    context.endTransparencyLayer()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("LabRoute-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try drawIcon(size: points * scale).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
if CommandLine.arguments.count > 1 {
    try drawIcon(size: 1024).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon-preview.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote Resources/AppIcon.icns")
