// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import AppKit
import QuartzCore

/// Edit Mode chrome drawn over a panel: outline, remove (×) and settings (⚙)
/// buttons, a resize grip, and the mouse handling for select/drag/resize.
@MainActor
final class EditOverlayView: NSView {
    private weak var session: EditSession?
    let panelID: String
    private let outline = CAShapeLayer()
    private let removeButton = CALayer()
    private let settingsButton = CALayer()
    private let grip = CAShapeLayer()

    private enum Hit { case remove, settings, resize, body }
    private var pressed: Hit?

    var isSelected = false {
        didSet { if isSelected != oldValue { updateColors() } }
    }

    init(session: EditSession, panelID: String) {
        self.session = session
        self.panelID = panelID
        super.init(frame: .zero)
        wantsLayer = true
        for layer: CALayer in [outline, removeButton, settingsButton, grip] {
            layer.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull(), "strokeColor": NSNull()]
            self.layer?.addSublayer(layer)
        }
        outline.fillColor = nil
        grip.fillColor = nil
        grip.lineWidth = 1.5
        grip.lineCap = .round
        for (button, symbol) in [(removeButton, "xmark.circle.fill"), (settingsButton, "gearshape.fill")] {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(
                    .init(pointSize: 15, weight: .semibold).applying(
                        .init(paletteColors: [.white, .black.withAlphaComponent(0.55)])))
            button.contents = image
            button.contentsGravity = .resizeAspect
            button.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        }
        setAccessibilityElement(false)
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let inset = bounds.insetBy(dx: 1, dy: 1)
        outline.path = CGPath(roundedRect: inset, cornerWidth: 19, cornerHeight: 19, transform: nil)
        outline.frame = bounds
        removeButton.frame = removeRect
        settingsButton.frame = settingsRect
        grip.frame = bounds
        let path = CGMutablePath()
        for offset: CGFloat in [6, 11] {
            path.move(to: CGPoint(x: bounds.maxX - offset, y: bounds.maxY - 5))
            path.addLine(to: CGPoint(x: bounds.maxX - 5, y: bounds.maxY - offset))
        }
        grip.path = path
    }

    private var removeRect: CGRect { CGRect(x: 6, y: 6, width: 18, height: 18) }
    private var settingsRect: CGRect { CGRect(x: bounds.maxX - 24, y: 6, width: 18, height: 18) }
    private var gripRect: CGRect { CGRect(x: bounds.maxX - 20, y: bounds.maxY - 20, width: 20, height: 20) }

    private func updateColors() {
        let accent = NSColor.controlAccentColor
        outline.strokeColor = (isSelected ? accent : NSColor.white.withAlphaComponent(0.7)).cgColor
        outline.lineWidth = isSelected ? 2.5 : 1.5
        outline.lineDashPattern = isSelected ? nil : [5, 4]
        grip.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
    }

    private func hit(_ point: CGPoint) -> Hit {
        if removeRect.insetBy(dx: -4, dy: -4).contains(point) { return .remove }
        if settingsRect.insetBy(dx: -4, dy: -4).contains(point) { return .settings }
        if gripRect.contains(point) { return .resize }
        return .body
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        session?.focusKeyboard()
        let point = convert(event.locationInWindow, from: nil)
        let hit = hit(point)
        pressed = hit
        switch hit {
        case .body: session?.beginMove(panelID, extending: event.modifierFlags.contains(.shift))
        case .resize: session?.beginResize(panelID)
        case .remove, .settings: break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressed == .body || pressed == .resize else { return }
        // Hold ⌘ to place freely (no snapping, no magnetic sizes).
        let free = event.modifierFlags.contains(.command)
        session?.continueGesture(snapping: !free, freeformResize: free)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        let point = convert(event.locationInWindow, from: nil)
        switch pressed {
        case .body, .resize: session?.endGesture()
        case .remove where hit(point) == .remove: session?.remove(panelID)
        case .settings where hit(point) == .settings: session?.inspect(panelID, from: self, rect: settingsRect)
        default: break
        }
    }

    override func resetCursorRects() {
        addCursorRect(gripRect, cursor: .frameResize(position: .bottomRight, directions: .all))
        addCursorRect(removeRect, cursor: .pointingHand)
        addCursorRect(settingsRect, cursor: .pointingHand)
    }
}
