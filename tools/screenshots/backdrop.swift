// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.
//
// A wallpaper-like gradient window for README screenshots, so glass panels have
// something to refract and nothing personal shows behind them. It sits just
// below the floating level: above every app window, below floating panels.
//
//   backdrop X Y WIDTH HEIGHT      (top-left screen coordinates, points)

import AppKit

let numbers = CommandLine.arguments.dropFirst().compactMap(Double.init)
guard numbers.count == 4, let screen = NSScreen.screens.first else {
    print("usage: backdrop X Y WIDTH HEIGHT")
    exit(1)
}
let rect = NSRect(
    x: numbers[0], y: screen.frame.maxY - numbers[1] - numbers[3], width: numbers[2], height: numbers[3])

func color(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) -> CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient? {
    CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)
}

final class BackdropView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
            let base = gradient(
                [color(0.07, 0.10, 0.24), color(0.20, 0.12, 0.36), color(0.05, 0.30, 0.42)], [0, 0.55, 1])
        else { return }
        context.drawLinearGradient(
            base, start: CGPoint(x: 0, y: bounds.height), end: CGPoint(x: bounds.width, y: 0), options: [])

        // Soft color blobs: (x, y, radius) as fractions of the view, and a color.
        let blobs: [(Double, Double, Double, CGColor)] = [
            (0.18, 0.75, 0.42, color(0.95, 0.45, 0.35, 0.55)),
            (0.62, 0.30, 0.48, color(0.25, 0.75, 0.85, 0.50)),
            (0.88, 0.85, 0.30, color(0.98, 0.78, 0.30, 0.40)),
            (0.40, 0.05, 0.35, color(0.55, 0.40, 0.95, 0.45)),
        ]
        for (x, y, radius, tone) in blobs {
            guard let fade = tone.copy(alpha: 0), let blob = gradient([tone, fade], [0, 1]) else { continue }
            let center = CGPoint(x: bounds.width * x, y: bounds.height * y)
            context.drawRadialGradient(
                blob, startCenter: center, startRadius: 0, endCenter: center,
                endRadius: max(bounds.width, bounds.height) * radius, options: [])
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
window.level = NSWindow.Level(NSWindow.Level.floating.rawValue - 1)
window.ignoresMouseEvents = true
window.hasShadow = false
window.contentView = BackdropView(frame: NSRect(origin: .zero, size: rect.size))
window.orderFrontRegardless()
app.run()
