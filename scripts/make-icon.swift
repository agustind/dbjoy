// Renders the DBJoy app icon and builds Assets/AppIcon.icns.
// Usage: swift scripts/make-icon.swift
import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// macOS-style squircle (superellipse) inside `rect`.
func squircle(_ rect: NSRect, exponent: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / exponent)
        let y = rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / exponent)
        if i == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
    }
    path.close()
    return path
}

/// Four-point sparkle.
func sparkle(center: NSPoint, size: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let r = size / 2, w = size * 0.12
    path.move(to: NSPoint(x: center.x, y: center.y - r))
    path.curve(to: NSPoint(x: center.x + r, y: center.y), controlPoint1: NSPoint(x: center.x + w, y: center.y - w),
               controlPoint2: NSPoint(x: center.x + w, y: center.y - w))
    path.curve(to: NSPoint(x: center.x, y: center.y + r), controlPoint1: NSPoint(x: center.x + w, y: center.y + w),
               controlPoint2: NSPoint(x: center.x + w, y: center.y + w))
    path.curve(to: NSPoint(x: center.x - r, y: center.y), controlPoint1: NSPoint(x: center.x - w, y: center.y + w),
               controlPoint2: NSPoint(x: center.x - w, y: center.y + w))
    path.curve(to: NSPoint(x: center.x, y: center.y - r), controlPoint1: NSPoint(x: center.x - w, y: center.y - w),
               controlPoint2: NSPoint(x: center.x - w, y: center.y - w))
    path.close()
    return path
}

func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
}

/// Lower half of an ellipse, used for the cylinder's stripes.
func lowerArc(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.appendArc(withCenter: .zero, radius: 1, startAngle: 180, endAngle: 360, clockwise: true)
    var transform = AffineTransform(translationByX: cx, byY: cy)
    transform.scale(x: rx, y: ry)
    path.transform(using: transform)
    return path
}

let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: true) { _ in
    let ctx = NSGraphicsContext.current!.cgContext
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(body)

    // Drop shadow under the tile.
    NSGraphicsContext.saveGraphicsState()
    let tileShadow = NSShadow()
    tileShadow.shadowColor = color(0x8A3A63, 0.22)
    tileShadow.shadowBlurRadius = 24
    // In this flipped drawing context a positive height moves the shadow down.
    tileShadow.shadowOffset = NSSize(width: 0, height: 12)
    tileShadow.set()
    color(0xFFC6DD).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Pastel pink gradient with a soft glow at the top.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [color(0xFFE6F1), color(0xFFC4DD), color(0xFFA9CE)], atLocations: [0, 0.55, 1],
               colorSpace: .sRGB)!.draw(in: body, angle: 90)
    NSGradient(colors: [color(0xFFFFFF, 0.55), color(0xFFFFFF, 0)])!
        .draw(fromCenter: NSPoint(x: 400, y: 230), radius: 0, toCenter: NSPoint(x: 400, y: 230), radius: 520, options: [])

    // Sparkles.
    color(0xFFFFFF, 0.95).setFill()
    sparkle(center: NSPoint(x: 230, y: 250), size: 92).fill()
    color(0xFFF3B0).setFill()
    sparkle(center: NSPoint(x: 800, y: 220), size: 64).fill()
    color(0xFFFFFF, 0.9).setFill()
    sparkle(center: NSPoint(x: 820, y: 790), size: 70).fill()
    color(0xD8C8FF).setFill()
    ellipse(205, 760, 16, 16).fill()
    color(0xBDF0DC).setFill()
    ellipse(860, 470, 13, 13).fill()
    color(0xFFFFFF, 0.8).setFill()
    ellipse(270, 860, 10, 10).fill()

    // Cylinder geometry.
    let cx: CGFloat = 512, rx: CGFloat = 238, ry: CGFloat = 70
    let topY: CGFloat = 300, bottomY: CGFloat = 770
    let cylinder = NSBezierPath()
    cylinder.append(NSBezierPath(rect: NSRect(x: cx - rx, y: topY, width: rx * 2, height: bottomY - topY)))
    cylinder.append(ellipse(cx, bottomY, rx, ry))
    cylinder.append(ellipse(cx, topY, rx, ry))
    cylinder.windingRule = .nonZero

    // Soft pink shadow under the cylinder.
    NSGraphicsContext.saveGraphicsState()
    let cylinderShadow = NSShadow()
    cylinderShadow.shadowColor = color(0xC2487E, 0.32)
    cylinderShadow.shadowBlurRadius = 36
    cylinderShadow.shadowOffset = NSSize(width: 0, height: 24)
    cylinderShadow.set()
    color(0xFFFFFF).setFill()
    cylinder.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Body shading: white on the left, a blush of pink on the right.
    NSGraphicsContext.saveGraphicsState()
    cylinder.addClip()
    NSGradient(colors: [color(0xFFFFFF), color(0xFFF6FA), color(0xFFDDEB)], atLocations: [0, 0.55, 1],
               colorSpace: .sRGB)!.draw(in: NSRect(x: cx - rx, y: topY - ry, width: rx * 2, height: bottomY - topY + ry * 2), angle: 0)
    NSGraphicsContext.restoreGraphicsState()

    // Stripes, clipped to the cylinder so their ends don't poke out.
    NSGraphicsContext.saveGraphicsState()
    cylinder.addClip()
    color(0xFFA8CC).setStroke()
    for y in [CGFloat(612), 700] {
        let stripe = lowerArc(cx, y, rx, ry)
        stripe.lineWidth = 16
        stripe.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()

    // Lid with an inner rim.
    color(0xFFFFFF).setFill()
    ellipse(cx, topY, rx, ry).fill()
    let rim = ellipse(cx, topY, rx - 34, ry - 22)
    NSGradient(colors: [color(0xFFD3E6), color(0xFFE9F2)])!.draw(in: rim, angle: 90)
    color(0xFFB9D6).setStroke()
    rim.lineWidth = 6
    rim.stroke()

    // Face.
    let ink = color(0x4B2142)
    ink.setFill()
    for x in [CGFloat(440), 584] {
        ellipse(x, 470, 21, 28).fill()
        color(0xFFFFFF).setFill()
        ellipse(x + 7, 460, 7, 7).fill()
        ink.setFill()
    }
    color(0xFF8DBD, 0.55).setFill()
    ellipse(392, 520, 34, 20).fill()
    ellipse(632, 520, 34, 20).fill()
    let smile = NSBezierPath()
    smile.appendArc(withCenter: NSPoint(x: cx, y: 505), radius: 52, startAngle: 20, endAngle: 160, clockwise: false)
    ink.setStroke()
    smile.lineWidth = 15
    smile.lineCapStyle = .round
    smile.stroke()

    NSGraphicsContext.restoreGraphicsState()
    _ = ctx
    return true
}

func png(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Assets")
let iconset = assets.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try png(1024).write(to: assets.appendingPathComponent("AppIcon.png"))
for base in [16, 32, 128, 256, 512] {
    try png(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try FileManager.default.removeItem(at: iconset)
print("Wrote Assets/AppIcon.png and Assets/AppIcon.icns")
