#!/usr/bin/env swift
// Draws the OneShot icon's artwork into the Icon Composer document at Resources/AppIcon.icon
// and exports a PNG of the finished icon for the README.
// Usage: swift scripts/generate-icon.swift
//
// Only the layer images are generated. The background, glass and shadow settings live in
// Resources/AppIcon.icon/icon.json and can be tuned in Icon Composer.
// scripts/build-app.sh compiles the document into the app with actool.

import AppKit

let document = "Resources/AppIcon.icon"
let preview = "Resources/AppIcon.png"
// Full-bleed canvas; the system masks it to the icon shape. Y grows downwards, as in SVG.
let canvas: CGFloat = 1024

func pathData(_ path: CGPath) -> String {
    var data = ""
    func point(_ p: CGPoint) -> String { String(format: "%.2f %.2f", p.x, p.y) }
    path.applyWithBlock { element in
        let points = element.pointee.points
        switch element.pointee.type {
        case .moveToPoint: data += "M\(point(points[0]))"
        case .addLineToPoint: data += "L\(point(points[0]))"
        case .addQuadCurveToPoint: data += "Q\(point(points[0])) \(point(points[1]))"
        case .addCurveToPoint: data += "C\(point(points[0])) \(point(points[1])) \(point(points[2]))"
        case .closeSubpath: data += "Z"
        @unknown default: break
        }
    }
    return data
}

/// Writes a layer as a single white filled path. Strokes are outlined first, since Icon Composer's
/// glass treats every shape as a fill.
func writeLayer(_ path: CGPath, named name: String) throws {
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(Int(canvas))" height="\(Int(canvas))" viewBox="0 0 \(Int(canvas)) \(Int(canvas))">
    <path d="\(pathData(path))" fill="#FFFFFF"/>
    </svg>

    """
    try svg.write(toFile: "\(document)/Assets/\(name).svg", atomically: true, encoding: .utf8)
}

try FileManager.default.createDirectory(atPath: "\(document)/Assets", withIntermediateDirectories: true)

// Viewfinder corner brackets.
let frame = CGRect(x: 0, y: 0, width: canvas, height: canvas).insetBy(dx: 236, dy: 236)
let arm: CGFloat = 147
let radius: CGFloat = 55
let brackets = CGMutablePath()
let corners: [(CGPoint, CGFloat, CGFloat)] = [
    (CGPoint(x: frame.minX, y: frame.minY), 1, 1),
    (CGPoint(x: frame.maxX, y: frame.minY), -1, 1),
    (CGPoint(x: frame.minX, y: frame.maxY), 1, -1),
    (CGPoint(x: frame.maxX, y: frame.maxY), -1, -1),
]
for (corner, dx, dy) in corners {
    brackets.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
    brackets.addArc(tangent1End: corner, tangent2End: CGPoint(x: corner.x + dx * arm, y: corner.y), radius: radius)
    brackets.addLine(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
}
try writeLayer(brackets.copy(strokingWithWidth: 57, lineCap: .round, lineJoin: .round, miterLimit: 10), named: "viewfinder")

// The single "shot", shaped like a "1": a stem with rounded ends and a dot up and
// to its left as the flag, a small gap apart.
let dotSize: CGFloat = 119
let stemWidth: CGFloat = 99
let stemTop = CGPoint(x: canvas / 2 + 78, y: canvas / 2 - 137)
let stemBottom = CGPoint(x: stemTop.x, y: canvas / 2 + 137)
let flagDistance = (dotSize + stemWidth) / 2 + 42
let flagAngle: CGFloat = 15 * .pi / 180
let dot = CGPoint(x: stemTop.x - flagDistance * cos(flagAngle), y: stemTop.y + flagDistance * sin(flagAngle))
let stem = CGMutablePath()
stem.move(to: stemTop)
stem.addLine(to: stemBottom)
let one = CGMutablePath()
one.addPath(stem.copy(strokingWithWidth: stemWidth, lineCap: .round, lineJoin: .round, miterLimit: 10))
one.addEllipse(in: CGRect(x: dot.x - dotSize / 2, y: dot.y - dotSize / 2, width: dotSize, height: dotSize))
try writeLayer(one, named: "one")

// Export the finished icon with Icon Composer's command line tool.
func run(_ tool: String, _ arguments: [String]) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fatalError("\(tool) failed") }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

let developer = try run("/usr/bin/xcode-select", ["-p"])
let ictool = "\(developer)/../Applications/Icon Composer.app/Contents/Executables/ictool"
_ = try run(ictool, [
    document, "--export-image", "--output-file", preview, "--platform", "macOS",
    "--rendition", "Default", "--width", "1024", "--height", "1024", "--scale", "1",
])
print("Wrote \(document) and \(preview)")
