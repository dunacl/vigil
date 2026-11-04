// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import AppKit
import VigilCore
import VigilUI

/// A borderless, never-key window that hosts one panel on the desktop layer.
final class PanelWindow: NSPanel {
    init() {
        super.init(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false  // the glass draws its own edge; a window shadow would be rectangular
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        isMovable = false  // dragging arrives with Edit Mode (M2)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns one panel's window and keeps it in sync with its ``PanelInstance``.
@MainActor
final class PanelController {
    private(set) var instance: PanelInstance
    private(set) var style: PanelStyle
    let window = PanelWindow()
    private let store: MetricsStore
    private let container = NSView()
    private var view: LayerPanelView
    /// Edit Mode chrome (outline, buttons, drag/resize handling), on top of the content.
    private(set) var overlay: NSView?
    /// Ticks to skip before the next redraw (per-panel update rate, SPEC §3.6).
    private var ticksUntilRefresh = 0

    /// While editing, panels float above app windows and always take the mouse.
    var isEditing = false {
        didSet { if isEditing != oldValue { applyBehavior() } }
    }

    /// Peek: temporarily above app windows (SPEC §3.3).
    var isRaised = false {
        didSet { if isRaised != oldValue { applyBehavior() } }
    }

    /// Re-applies level and ordering, e.g. after the Dock or Finder relaunched
    /// and the window server forgot our desktop-level placement (SPEC §7).
    func reassert() {
        applyBehavior()
        if instance.isVisible { window.orderFrontRegardless() }
    }

    /// Keeps the panel out of screenshots and screen sharing.
    func setHiddenFromCapture(_ hidden: Bool) {
        let type: NSWindow.SharingType = hidden ? .none : .readOnly
        if window.sharingType != type { window.sharingType = type }
    }

    init(instance: PanelInstance, store: MetricsStore, style: PanelStyle) {
        self.instance = instance
        self.store = store
        self.style = style
        view = Self.makeView(for: instance, store: store, style: style)
        container.autoresizesSubviews = true
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        window.contentView = container
        applyBehavior()
    }

    private static func makeView(for instance: PanelInstance, store: MetricsStore, style: PanelStyle) -> LayerPanelView
    {
        PanelViewFactory.make(
            kind: instance.kind, sizeClass: instance.sizeClass, store: store, style: style, options: instance.options)
    }

    /// Applies a changed instance (same id) and style. The content view is rebuilt
    /// only when the kind, layout class, theme or graph style changed; everything
    /// else updates in place.
    func update(_ new: PanelInstance, style newStyle: PanelStyle) {
        let old = instance
        let oldStyle = style
        instance = new
        style = newStyle
        if new.kind != old.kind || new.sizeClass != old.sizeClass || new.options != old.options
            || newStyle.needsRebuild(from: oldStyle)
        {
            let replacement = Self.makeView(for: new, store: store, style: newStyle)
            replacement.frame = container.bounds
            replacement.autoresizingMask = [.width, .height]
            container.replaceSubview(view, with: replacement)
            view = replacement
            view.refresh()
        } else if newStyle != oldStyle {
            view.style = newStyle
        }
        if new.level != old.level || new.clickThrough != old.clickThrough
            || new.placement.desktop != old.placement.desktop
        {
            applyBehavior()
        }
    }

    var isVisibleOnScreen: Bool { window.isVisible && window.occlusionState.contains(.visible) }

    /// Pushes the latest values into the panel at its update rate. Skipped while
    /// it can't be seen; `force` redraws now (e.g. it just became visible).
    func refresh(force: Bool = false) {
        guard isVisibleOnScreen else { return }
        if !force {
            ticksUntilRefresh -= 1
            guard ticksUntilRefresh <= 0 else { return }
        }
        ticksUntilRefresh = style.appearance.refreshTicks
        view.refresh()
    }

    func apply(frame: CGRect) {
        if window.frame != frame { window.setFrame(frame, display: true) }
        if instance.isVisible, !window.isVisible { window.orderFrontRegardless() }
        if !instance.isVisible, window.isVisible { window.orderOut(nil) }
    }

    func close() { window.orderOut(nil) }

    func setOverlay(_ overlay: NSView?) {
        self.overlay?.removeFromSuperview()
        self.overlay = overlay
        guard let overlay else { return }
        overlay.frame = container.bounds
        overlay.autoresizingMask = [.width, .height]
        container.addSubview(overlay, positioned: .above, relativeTo: view)
    }

    /// Hover fade (SPEC §3.6): the window's opacity while the pointer is over it.
    func setHoverOpacity(_ opacity: CGFloat, animated: Bool) {
        guard window.alphaValue != opacity else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                window.animator().alphaValue = opacity
            }
        } else {
            window.alphaValue = opacity
        }
    }

    private func applyBehavior() {
        window.level =
            switch (isEditing || isRaised, instance.level) {
            case (true, _): .floating
            case (_, .desktop): NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            case (_, .behindIcons): NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            case (_, .floating): .floating
            }
        var behavior: NSWindow.CollectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]
        if instance.placement.desktop == .all { behavior.insert(.canJoinAllSpaces) }
        window.collectionBehavior = behavior
        window.ignoresMouseEvents = !isEditing && (instance.clickThrough || instance.level == .behindIcons)
    }
}
