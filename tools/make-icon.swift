// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.
//
// Draws Vigil's app icon with Core Graphics (no SF Symbols: their license
// excludes app icons) and writes a 1024×1024 PNG.
//
//   swift tools/make-icon.swift assets/AppIcon-1024.png

import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
let size = 1024.0

func rgb(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func gradient(_ colors: [NSColor]) -> CGGradient? {
    CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map(\.cgColor) as CFArray,
        locations: [0, 1])
}

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    guard let context = NSGraphicsContext.current?.cgContext,
        let background = gradient([rgb(0.05, 0.11, 0.22), rgb(0.04, 0.33, 0.40)]),
        let highlight = gradient([rgb(1, 1, 1, 0.22), rgb(1, 1, 1, 0)]),
        let value = gradient([rgb(0.30, 0.85, 0.50), rgb(0.98, 0.82, 0.28)])
    else { return false }

    // macOS icon grid: an 824 pt squircle centered in the 1024 canvas.
    let frame = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: frame, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow, then the body gradient (deep navy → teal) and a glass highlight.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35).cgColor)
    context.addPath(squircle)
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(squircle)
    context.clip()
    context.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    context.drawLinearGradient(highlight, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    context.restoreGState()

    // The gauge: a 240° track, a calm → warm value arc, and a needle.
    let center = CGPoint(x: 512, y: 470)
    let radius = 270.0
    let start = CGFloat.pi * 7 / 6, end = -CGFloat.pi / 6  // 210° → −30°, clockwise
    func arc(from: CGFloat, to: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addArc(center: center, radius: radius, startAngle: from, endAngle: to, clockwise: true)
        return path
    }
    context.setLineCap(.round)
    context.setLineWidth(58)
    context.addPath(arc(from: start, to: end))
    context.setStrokeColor(rgb(1, 1, 1, 0.16).cgColor)
    context.strokePath()

    let valueEnd = start - (start - end) * 0.68
    context.saveGState()
    context.addPath(arc(from: start, to: valueEnd))
    context.replacePathWithStrokedPath()
    context.clip()
    context.drawLinearGradient(
        value, start: CGPoint(x: center.x - radius, y: center.y), end: CGPoint(x: center.x + radius, y: center.y),
        options: [])
    context.restoreGState()

    // Needle and hub.
    let tip = CGPoint(x: center.x + cos(valueEnd) * (radius - 70), y: center.y + sin(valueEnd) * (radius - 70))
    context.setLineWidth(30)
    context.setStrokeColor(NSColor.white.cgColor)
    context.move(to: center)
    context.addLine(to: tip)
    context.strokePath()
    context.setFillColor(NSColor.white.cgColor)
    context.fillEllipse(in: CGRect(x: center.x - 42, y: center.y - 42, width: 84, height: 84))
    context.setFillColor(rgb(0.05, 0.15, 0.27).cgColor)
    context.fillEllipse(in: CGRect(x: center.x - 18, y: center.y - 18, width: 36, height: 36))

    // Three small bars under the gauge, a nod to btop's process meters.
    for (index, height) in [0.45, 0.8, 0.6].enumerated() {
        let bar = CGRect(x: 512 - 105 + Double(index) * 80, y: 210, width: 50, height: 120 * height)
        context.addPath(CGPath(roundedRect: bar, cornerWidth: 14, cornerHeight: 14, transform: nil))
        context.setFillColor(rgb(1, 1, 1, 0.75 - Double(index) * 0.1).cgColor)
        context.fillPath()
    }
    return true
}

guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    print("could not render the icon")
    exit(1)
}
try png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
