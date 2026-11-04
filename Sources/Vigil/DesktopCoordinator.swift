// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import AppKit
import QuartzCore
import VigilCore
import VigilUI
import os

/// Places panel windows on screens and desktops and tells the sampler what to
/// collect based on which panels are actually visible.
///
/// Everything here is event-driven: screen changes, Space changes and window
/// occlusion changes. Nothing polls.
@MainActor
final class DesktopCoordinator {
    private let sampler: Sampler
    private let store: MetricsStore
    private(set) var controllers: [PanelController] = []
    private var observers: [NSObjectProtocol] = []
    private var lastDemand: Demand?
    private static let log = Logger(subsystem: "app.vigil", category: "desktop")

    /// Collected even when no panel shows them, so graphs aren't empty when a
    /// panel is revealed (SPEC §4.4 "Keep history while hidden"). ~0.01 ms/tick.
    var backgroundDemand: Demand = [.cpu, .memory]

    /// Demand from other windows (the Dashboard while it's visible).
    var extraDemand: Demand = [] {
        didSet { if extraDemand != oldValue { updateDemand() } }
    }

    /// Measurement only: stop pushing data after this many ticks (static content).
    var refreshLimit: Int?
    private var refreshCount = 0

    init(sampler: Sampler, store: MetricsStore) {
        self.sampler = sampler
        self.store = store
    }

    /// Extra views to refresh each tick (Gallery and Settings previews), by owner.
    private var tickObservers: [ObjectIdentifier: () -> Void] = [:]

    func observeTicks(_ owner: AnyObject, _ handler: @escaping () -> Void) {
        tickObservers[ObjectIdentifier(owner)] = handler
    }

    func stopObservingTicks(_ owner: AnyObject) { tickObservers[ObjectIdentifier(owner)] = nil }

    // MARK: - Appearance

    /// Global settings; changing them restyles every panel immediately.
    var settings = VigilSettings() {
        didSet { if settings != oldValue { reapplyStyles() } }
    }
    private(set) var accessibility = AccessibilityDisplay()
    private var profile = LayoutProfile(name: "", panels: [])
    private let hover = HoverTracker()

    /// While editing, hover fade is off so panels can be grabbed.
    var isEditing = false {
        didSet { if isEditing != oldValue { updateHover() } }
    }

    /// The style a panel gets with no overrides (Gallery and Settings previews).
    var globalStyle: PanelStyle {
        style(
            for: PanelInstance(
                id: "", kind: .cpu, sizeClass: .medium,
                placement: Placement(
                    display: .main, anchor: .center, offset: .zero, size: SizeClass.medium.size)))
    }

    func style(for instance: PanelInstance) -> PanelStyle {
        PanelStyle(
            appearance: AppearanceResolver.resolve(
                global: settings.appearance, overrides: instance.appearance, accessibility: accessibility),
            units: settings.units, thresholds: settings.thresholds)
    }

    private func reapplyStyles() {
        for controller in controllers {
            controller.update(controller.instance, style: style(for: controller.instance))
            controller.setHiddenFromCapture(settings.general.hideFromScreenCapture)
        }
        updateHover()
    }

    /// Peek: all panels above app windows until called again with `false`.
    var isPeeking = false {
        didSet {
            guard isPeeking != oldValue else { return }
            for controller in controllers { controller.isRaised = isPeeking }
            updateHover()
        }
    }

    private func readAccessibility() {
        let workspace = NSWorkspace.shared
        accessibility = AccessibilityDisplay(
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
            reduceMotion: workspace.accessibilityDisplayShouldReduceMotion)
    }

    // MARK: - Hover

    private func updateHover() {
        let hovering = isEditing || isPeeking ? [] : controllers.filter { $0.style.appearance.hover != .off }
        if hovering.isEmpty {
            hover.stop()
            for controller in controllers { controller.setHoverOpacity(1, animated: false) }
        } else {
            hover.start { [weak self] point in self?.pointerMoved(to: point) }
        }
    }

    private func pointerMoved(to point: CGPoint) {
        for controller in controllers where controller.window.isVisible {
            let appearance = controller.style.appearance
            guard appearance.hover != .off else { continue }
            let inside = controller.window.frame.insetBy(dx: -4, dy: -4).contains(point)
            let opacity: CGFloat = !inside ? 1 : appearance.hover == .fade ? 0.25 : 0
            controller.setHoverOpacity(opacity, animated: appearance.animates)
        }
    }

    /// Shows `profile`, reusing the windows of panels that already exist (by id)
    /// so editing one panel never flickers the others.
    func show(_ profile: LayoutProfile) {
        if observers.isEmpty { readAccessibility() }
        self.profile = profile
        let existing = Dictionary(uniqueKeysWithValues: controllers.map { ($0.instance.id, $0) })
        let wanted = Set(profile.panels.map(\.id))
        for controller in controllers where !wanted.contains(controller.instance.id) { controller.close() }
        controllers = profile.panels.map { instance in
            if let controller = existing[instance.id] {
                controller.update(instance, style: style(for: instance))
                return controller
            }
            let controller = PanelController(instance: instance, store: store, style: style(for: instance))
            controller.setHiddenFromCapture(settings.general.hideFromScreenCapture)
            controller.isRaised = isPeeking
            return controller
        }
        layout()
        startObserving()
        updateDemand()
        updateHover()
    }

    func controller(id: String) -> PanelController? { controllers.first { $0.instance.id == id } }

    /// Screens and the frames of visible panels, for snapping and overlap checks.
    func visibleFrames(excluding ids: Set<String>) -> [CGRect] {
        controllers.filter { $0.window.isVisible && !ids.contains($0.instance.id) }.map(\.window.frame)
    }

    /// Pushes the tick to visible panels as a single Core Animation commit, so
    /// WindowServer receives one batched update per tick instead of one per panel.
    func storeDidUpdate() {
        if let refreshLimit {
            guard refreshCount < refreshLimit else { return }
            refreshCount += 1
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for controller in controllers { controller.refresh() }
        for observer in tickObservers.values { observer() }
        CATransaction.commit()
    }

    /// Resolves every placement against the current screens and applies desktops.
    func layout() {
        let screens = ScreenCatalog.current()
        for controller in controllers {
            guard let resolved = PlacementResolver.resolve(controller.instance.placement, screens: screens) else {
                continue
            }
            if resolved.isOnFallbackDisplay {
                Self.log.info("Panel \(controller.instance.id) shown on main display; its display is disconnected")
            }
            controller.apply(frame: CGRect(resolved.frame))
            pinDesktop(controller, displayUUID: resolved.screen.uuid)
        }
    }

    /// After a Dock or Finder relaunch: levels, ordering, frames and desktop pins.
    private func reassertWindows() {
        Self.log.info("Dock or Finder relaunched; re-asserting panel windows")
        for controller in controllers { controller.reassert() }
        layout()
    }

    /// Re-applies "Desktop N" pins. Cheap when nothing moved (one query per panel).
    private func applyDesktops() {
        let screens = ScreenCatalog.current()
        for controller in controllers {
            guard case .index = controller.instance.placement.desktop,
                let resolved = PlacementResolver.resolve(controller.instance.placement, screens: screens)
            else { continue }
            pinDesktop(controller, displayUUID: resolved.screen.uuid)
        }
    }

    private func pinDesktop(_ controller: PanelController, displayUUID: String) {
        guard case .index(let index) = controller.instance.placement.desktop else { return }
        guard let bridge = SpacesBridge.shared, let space = bridge.space(desktop: index, displayUUID: displayUUID)
        else {
            // Desktop N unavailable (no bridge, or that desktop doesn't exist): show on all desktops
            // without changing the saved setting, so it returns when Desktop N exists again.
            controller.window.collectionBehavior.insert(.canJoinAllSpaces)
            return
        }
        controller.window.collectionBehavior.remove(.canJoinAllSpaces)
        bridge.pin(controller.window, to: space)
    }

    private func occlusionDidChange() {
        // Panels that just became visible catch up immediately.
        for controller in controllers { controller.refresh(force: true) }
        updateDemand()
    }

    /// Demand = background ∪ what visible panels need. Applied only when it changes.
    private func updateDemand() {
        let visible = controllers.filter(\.isVisibleOnScreen).map(\.instance)
        let demand = backgroundDemand.union(extraDemand).union(LayoutProfile.demand(of: visible))
        guard demand != lastDemand else { return }
        lastDemand = demand
        Self.log.debug("Demand now \(demand.rawValue), \(visible.count) panel(s) visible")
        Task { await sampler.setDemand(demand) }
    }

    private func startObserving() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main)
            {
                [weak self] _ in MainActor.assumeIsolated { self?.layout() }
            })
        observers.append(
            workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) {
                [weak self] notification in
                let identifier =
                    (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                    .bundleIdentifier
                MainActor.assumeIsolated {
                    guard identifier == "com.apple.dock" || identifier == "com.apple.finder" else { return }
                    // Give the relaunched process a moment to set up its own windows.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.reassertWindows() }
                }
            })
        observers.append(
            workspace.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.readAccessibility()
                    self?.reapplyStyles()
                }
            })
        observers.append(
            workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.applyDesktops() }
            })
        observers.append(
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) {
                [weak self] notification in
                let isPanel = notification.object is PanelWindow
                MainActor.assumeIsolated {
                    guard isPanel else { return }
                    self?.occlusionDidChange()
                }
            })
    }
}
