// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import AppKit
import QuartzCore
import VigilCore

/// Draws snap guides during a drag: one transparent, click-through window per
/// screen, created on first use and hidden (not destroyed) between drags.
@MainActor
final class GuideOverlay {
    private var windows: [String: (window: NSWindow, lines: CAShapeLayer)] = [:]

    func show(_ guides: [SnapGuide]) {
        let screens = NSScreen.screens
        for screen in screens {
            guard let uuid = ScreenCatalog.uuid(of: screen) else { continue }
            let frame = screen.frame
            let path = CGMutablePath()
            for guide in guides {
                switch guide.axis {
                case .vertical(let x) where x >= frame.minX && x <= frame.maxX:
                    path.move(to: CGPoint(x: x - frame.minX, y: guide.from - frame.minY))
                    path.addLine(to: CGPoint(x: x - frame.minX, y: guide.to - frame.minY))
                case .horizontal(let y) where y >= frame.minY && y <= frame.maxY:
                    path.move(to: CGPoint(x: guide.from - frame.minX, y: y - frame.minY))
                    path.addLine(to: CGPoint(x: guide.to - frame.minX, y: y - frame.minY))
                default:
                    continue
                }
            }
            if path.isEmpty {
                windows[uuid]?.window.orderOut(nil)
                continue
            }
            let entry = windows[uuid] ?? makeWindow(for: screen)
            windows[uuid] = entry
            if entry.window.frame != frame { entry.window.setFrame(frame, display: false) }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            entry.lines.path = path
            CATransaction.commit()
            if !entry.window.isVisible { entry.window.orderFrontRegardless() }
        }
    }

    func hide() {
        for entry in windows.values { entry.window.orderOut(nil) }
    }

    private func makeWindow(for screen: NSScreen) -> (window: NSWindow, lines: CAShapeLayer) {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(NSWindow.Level.floating.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.isReleasedWhenClosed = false
        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        let lines = CAShapeLayer()
        lines.strokeColor = NSColor.systemPink.cgColor
        lines.lineWidth = 1
        lines.lineDashPattern = [4, 3]
        lines.fillColor = nil
        lines.frame = view.bounds
        view.layer?.addSublayer(lines)
        window.contentView = view
        return (window, lines)
    }
}
