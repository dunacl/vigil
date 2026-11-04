// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import AppKit

/// The small glass bar shown at the top of the main display in Edit Mode. It is
/// the key window while editing, so it also handles the keyboard: Esc/Return
/// (Done), ⌘Z/⇧⌘Z, Delete (remove selection), arrows (nudge; ⇧ = grid step).
@MainActor
final class EditToolbar: NSPanel {
    private weak var session: EditSession?
    private let undoButton = NSButton()
    private let redoButton = NSButton()

    init(session: EditSession) {
        self.session = session
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 420, height: 44), styleMask: [.borderless], backing: .buffered,
            defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(NSWindow.Level.floating.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        let glass = NSGlassEffectView()
        glass.cornerRadius = 22
        let title = NSTextField(labelWithString: "Editing Layout")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        let add = Self.button("Add Panel…", symbol: "plus", action: #selector(addPanel), target: self)
        configure(undoButton, symbol: "arrow.uturn.backward", action: #selector(undo), help: "Undo (⌘Z)")
        configure(redoButton, symbol: "arrow.uturn.forward", action: #selector(redo), help: "Redo (⇧⌘Z)")
        let done = Self.button("Done", symbol: nil, action: #selector(done), target: self)
        done.keyEquivalent = "\r"
        done.bezelColor = .controlAccentColor
        let stack = NSStackView(views: [title, add, undoButton, redoButton, done])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 16, bottom: 6, right: 8)
        stack.setCustomSpacing(16, after: title)
        glass.contentView = stack
        contentView = glass
        setContentSize(stack.fittingSize)
        update(canUndo: false, canRedo: false)
    }

    override var canBecomeKey: Bool { true }

    /// Borderless floating panels of an accessory app don't take focus on click
    /// by themselves; a click is user intent, so take it explicitly.
    func takeFocus() {
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow { takeFocus() }
        super.sendEvent(event)
    }

    /// ⌘-combinations arrive as key equivalents before `keyDown`.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), event.keyCode == 6 else { return super.performKeyEquivalent(with: event) }
        if flags.contains(.shift) { session?.redo() } else { session?.undo() }
        return true
    }

    func show() {
        guard let screen = NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(CGPoint(x: visible.midX - frame.width / 2, y: visible.maxY - frame.height - 12))
        makeKeyAndOrderFront(nil)
    }

    func update(canUndo: Bool, canRedo: Bool) {
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
    }

    private static func button(_ title: String, symbol: String?, action: Selector, target: AnyObject) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .push
        button.controlSize = .regular
        if let symbol { button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        button.imagePosition = .imageLeading
        return button
    }

    private func configure(_ button: NSButton, symbol: String, action: Selector, help: String) {
        button.bezelStyle = .push
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.toolTip = help
    }

    @objc private func addPanel() { session?.showGallery() }
    @objc private func undo() { session?.undo() }
    @objc private func redo() { session?.redo() }
    @objc private func done() { session?.end() }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let byGrid = flags.contains(.shift)
        switch (event.keyCode, flags.contains(.command)) {
        case (53, _): session?.end()  // Esc
        case (6, true): flags.contains(.shift) ? session?.redo() : session?.undo()  // Z
        case (51, false), (117, false): session?.removeSelection()  // Delete, Forward Delete
        case (123, false): session?.nudge(dx: -1, dy: 0, byGrid: byGrid)
        case (124, false): session?.nudge(dx: 1, dy: 0, byGrid: byGrid)
        case (125, false): session?.nudge(dx: 0, dy: -1, byGrid: byGrid)
        case (126, false): session?.nudge(dx: 0, dy: 1, byGrid: byGrid)
        default: super.keyDown(with: event)
        }
    }
}
