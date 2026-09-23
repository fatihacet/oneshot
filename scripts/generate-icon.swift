#!/usr/bin/env swift
// Renders the OneShot app icon and packs it into an .icns file.
// Usage: swift scripts/generate-icon.swift Resources/AppIcon.icns

import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"
let canvas: CGFloat = 1024

/// A superellipse ("squircle") close to the macOS icon shape.
func squircle(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2
    let b = rect.height / 2
    let steps = 720
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let cosT = cos(t)
        let sinT = sin(t)
        let x = a * copysign(pow(abs(cosT), 2 / exponent), cosT)
        let y = b * copysign(pow(abs(sinT), 2 / exponent), sinT)
        let point = CGPoint(x: rect.midX + x, y: rect.midY + y)
        step == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.closeSubpath()
    return path
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func renderIcon() -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    // Body: the standard 824 pt icon grid inside the 1024 canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(in: body)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, alpha: 0.35))
    context.addPath(shape)
    context.setFillColor(color(0x1B1F3B))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [color(0x4F46E5), color(0x2563EB), color(0x06B6D4)] as CFArray,
        locations: [0, 0.55, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: body.minX, y: body.maxY),
        end: CGPoint(x: body.maxX, y: body.minY),
        options: []
    )
    // Soft highlight on the upper half.
    let highlight = CGGradient(
        colorsSpace: space,
        colors: [color(0xFFFFFF, alpha: 0.22), color(0xFFFFFF, alpha: 0)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        highlight,
        start: CGPoint(x: body.midX, y: body.maxY),
        end: CGPoint(x: body.midX, y: body.midY),
        options: []
    )
    context.restoreGState()

    // Viewfinder corner brackets.
    let frame = body.insetBy(dx: 190, dy: 190)
    let arm: CGFloat = 118
    let radius: CGFloat = 44
    context.setStrokeColor(color(0xFFFFFF))
    context.setLineWidth(46)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    let corners: [(CGPoint, CGFloat, CGFloat)] = [
        (CGPoint(x: frame.minX, y: frame.maxY), 1, -1),
        (CGPoint(x: frame.maxX, y: frame.maxY), -1, -1),
        (CGPoint(x: frame.minX, y: frame.minY), 1, 1),
        (CGPoint(x: frame.maxX, y: frame.minY), -1, 1),
    ]
    for (corner, dx, dy) in corners {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
        path.addArc(
            tangent1End: corner,
            tangent2End: CGPoint(x: corner.x + dx * arm, y: corner.y),
            radius: radius
        )
        path.addLine(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
        context.addPath(path)
        context.strokePath()
    }

    // The single "shot": a solid dot with a soft glow.
    let center = CGPoint(x: body.midX, y: body.midY)
    context.saveGState()
    context.setShadow(offset: .zero, blur: 40, color: color(0xFFFFFF, alpha: 0.55))
    context.setFillColor(color(0xFFFFFF))
    context.fillEllipse(in: CGRect(x: center.x - 70, y: center.y - 70, width: 140, height: 140))
    context.restoreGState()

    return context.makeImage()!
}

func writePNG(_ image: CGImage, size: Int, to url: URL) {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
}

let icon = renderIcon()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("OneShot-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    writePNG(icon, size: base, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(icon, size: base * 2, to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output]
try process.run()
process.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }

// Also keep a 1024 px PNG for the README.
let preview = URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("png")
writePNG(icon, size: 1024, to: preview)
print("Wrote \(output) and \(preview.path)")
