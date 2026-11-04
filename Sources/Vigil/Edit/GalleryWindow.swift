// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import AppKit
import VigilCore
import VigilUI

/// "Add Panel": every panel kind in each size, as live previews. Clicking a
/// preview adds that panel at a free spot. Previews update only while open.
@MainActor
final class GalleryWindow: NSPanel, NSWindowDelegate {
    var onClose: (() -> Void)?
    private weak var coordinator: DesktopCoordinator?
    private var previews: [LayerPanelView] = []
    private let warning = NSTextField(wrappingLabelWithString: "")

    /// Above this many visible glass panels, warn about WindowServer cost (SPEC §2.1).
    static let glassPanelWarningThreshold = 6

    init(store: MetricsStore, coordinator: DesktopCoordinator, add: @escaping (PanelKind, SizeClass) -> Void) {
        self.coordinator = coordinator
        let columns: [SizeClass] = [.medium, .small, .extraSmall]
        let width: CGFloat = 16 + columns.reduce(0) { $0 + $1.size.width } + 12 * CGFloat(columns.count - 1) + 16
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: width, height: 640),
            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        title = "Add Panel"
        level = NSWindow.Level(NSWindow.Level.floating.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        delegate = self

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 16, right: 16)
        warning.font = .systemFont(ofSize: 11)
        warning.textColor = .systemOrange
        warning.preferredMaxLayoutWidth = width - 32
        stack.addArrangedSubview(warning)

        for kind in PanelKind.allCases {
            let label = NSTextField(labelWithString: PanelViewFactory.title(of: kind))
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            stack.addArrangedSubview(label)
            let row = NSStackView()
            row.alignment = .top
            row.spacing = 12
            for sizeClass in columns {
                let preview = PanelViewFactory.make(
                    kind: kind, sizeClass: sizeClass, store: store, style: coordinator.globalStyle)
                previews.append(preview)
                row.addArrangedSubview(
                    GalleryCell(
                        preview: preview, size: sizeClass.size,
                        label:
                            "\(PanelViewFactory.title(of: kind)), \(LayerPanelView.title(of: sizeClass).lowercased())"
                    ) {
                        add(kind, sizeClass)
                    })
            }
            stack.addArrangedSubview(row)
        }

        let document = FlippedContainer()
        document.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        document.frame = CGRect(origin: .zero, size: stack.fittingSize)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        contentView = scroll
        setContentSize(CGSize(width: width, height: min(stack.fittingSize.height, 640)))

        if let screen = NSScreen.screens.first {
            let visible = screen.visibleFrame
            setFrameOrigin(CGPoint(x: visible.midX - frame.width / 2, y: visible.maxY - frame.height - 72))
        }
        coordinator.observeTicks(self) { [weak self] in self?.tick() }
        updateWarning()
        for preview in previews { preview.refresh() }
    }

    private func tick() {
        for preview in previews { preview.refresh() }
        updateWarning()
    }

    private func updateWarning() {
        let glass =
            coordinator?.controllers.filter {
                guard $0.instance.isVisible, case .glass = $0.style.appearance.background else { return false }
                return true
            }.count ?? 0
        warning.isHidden = glass <= Self.glassPanelWarningThreshold
        warning.stringValue =
            "\(glass) glass panels are visible. Each one adds about 0.2% CPU to the window server; "
            + "consider fewer panels or a Solid background."
    }

    override func cancelOperation(_ sender: Any?) { close() }

    func windowWillClose(_ notification: Notification) {
        coordinator?.stopObservingTicks(self)
        onClose?()
    }
}

/// A clickable live preview with a hover highlight.
@MainActor
private final class GalleryCell: NSView {
    private let action: () -> Void
    private var hovering = false {
        didSet { layer?.borderWidth = hovering ? 2 : 0 }
    }

    init(preview: NSView, size: Size, label: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        preview.frame = bounds
        preview.autoresizingMask = [.width, .height]
        addSubview(preview)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width), heightAnchor.constraint(equalToConstant: size.height),
        ])
        addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Add \(label)")
        toolTip = "Add \(label)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    /// One click adds, even when the Gallery isn't the key window yet.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}  // track the click here so mouseUp comes back to us
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}

private final class FlippedContainer: NSView {
    override var isFlipped: Bool { true }
}
