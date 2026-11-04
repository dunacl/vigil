// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import AppKit
import QuartzCore
import VigilCore

/// A view whose layer geometry has its origin at the top-left.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Everything a panel needs besides the data: resolved appearance, units and thresholds.
public struct PanelStyle: Sendable, Equatable {
    public var appearance: ResolvedAppearance
    public var units: UnitSettings
    public var thresholds: ThresholdSettings

    public init(appearance: ResolvedAppearance, units: UnitSettings, thresholds: ThresholdSettings) {
        self.appearance = appearance
        self.units = units
        self.thresholds = thresholds
    }

    public static let standard = PanelStyle(
        appearance: AppearanceResolver.resolve(
            global: AppearanceSettings(), overrides: AppearanceOverrides(), accessibility: AccessibilityDisplay()),
        units: UnitSettings(), thresholds: ThresholdSettings())

    /// Theme and graph style are baked into a panel's layers; changing them
    /// rebuilds the panel. Everything else is applied in place.
    public func needsRebuild(from other: PanelStyle) -> Bool {
        appearance.theme != other.appearance.theme || appearance.graphStyle != other.appearance.graphStyle
    }
}

/// Base class for panels: a static background (glass, solid or none), a title
/// row, and layer-based content that subclasses lay out and update.
///
/// Views, back to front: Liquid Glass → an opaque backing (legibility / the
/// opaque end of the transparency slider) → a tint wash → the content.
/// Background and content fade independently. The tint is our own layer:
/// `NSGlassEffectView.tintColor` has no visible effect in never-key windows
/// like these panels (verified on macOS 27.2). Subclasses override ``layoutBody(in:)``, ``update()``,
/// ``currentAlertLevel()`` and, if they own colored layers, ``resolveColors(in:)``.
@MainActor
public class LayerPanelView: NSView {
    let store: MetricsStore
    let sizeClass: SizeClass
    let palette: PanelPalette
    let host = FlippedView()
    private let backing = NSView()
    private let tintWash = NSView()
    private var glass: NSGlassEffectView?
    let title: TextLayer
    let accessory = TextLayer(.caption, color: .secondaryLabelColor, alignment: .right)
    /// Text layers to keep in sync with appearance and backing scale.
    private var textLayers: [TextLayer] = []
    private(set) var alertLevel: AlertLevel = .normal

    /// Applied in place when it changes (except theme/graph style; see ``PanelStyle/needsRebuild(from:)``).
    public var style: PanelStyle {
        didSet {
            if style.appearance != oldValue.appearance { applyBackground() }
            if style.units != oldValue.units || style.thresholds != oldValue.thresholds { refresh() }
        }
    }

    var units: UnitSettings { style.units }

    /// Extra small tiles use tighter padding to fit a number and a sparkline.
    var padding: CGFloat { sizeClass == .extraSmall ? 10 : 12 }
    static let titleHeight: CGFloat = 14
    static let rowGap: CGFloat = 6

    init(title: String, store: MetricsStore, sizeClass: SizeClass, style: PanelStyle) {
        self.store = store
        self.sizeClass = sizeClass
        self.style = style
        self.palette = PanelPalette.make(style.appearance.theme)
        self.title = TextLayer(.title, color: .secondaryLabelColor)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        backing.wantsLayer = true
        tintWash.wantsLayer = true
        host.wantsLayer = true
        host.layerContentsRedrawPolicy = .never
        addSubview(backing)
        addSubview(tintWash)
        addSubview(host)
        applyBackground()
        self.title.text = title.uppercased()
        add(self.title)
        add(accessory)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Background (static: changes only when the appearance or alert level changes)

    private func applyBackground() {
        let appearance = style.appearance
        let radius = CGFloat(appearance.cornerRadius)
        layer?.cornerRadius = radius
        backing.layer?.cornerRadius = radius
        tintWash.layer?.cornerRadius = radius
        host.alphaValue = CGFloat(appearance.contentOpacity)

        switch appearance.background {
        case .glass(let clear, let glassOpacity, let backingOpacity):
            let glass = self.glass ?? makeGlass()
            glass.style = clear ? .clear : .regular
            glass.cornerRadius = radius
            glass.alphaValue = CGFloat(glassOpacity)
            backing.alphaValue = CGFloat(backingOpacity)
            layer?.backgroundColor = nil
        case .solid:
            removeGlass()
            backing.alphaValue = 0
            layer?.backgroundColor = resolved(.windowBackgroundColor, in: effectiveAppearance)
        case .none:
            removeGlass()
            backing.alphaValue = 0
            layer?.backgroundColor = nil
        }
        // With no background there is nothing to tint; alerts still show (they matter more).
        let wash = appearance.background == .none && alertLevel == .normal ? nil : tintColor()
        tintWash.layer?.backgroundColor = wash.map { resolved($0, in: effectiveAppearance) }
        backing.layer?.backgroundColor = resolved(.windowBackgroundColor, in: effectiveAppearance)

        switch appearance.border {
        case .off:
            layer?.borderWidth = 0
        case .hairline:
            layer?.borderWidth = 0.5
            layer?.borderColor = resolved(.separatorColor, in: effectiveAppearance)
        case .accent:
            layer?.borderWidth = 1.5
            layer?.borderColor = resolved(.controlAccentColor, in: effectiveAppearance)
        }
    }

    private func makeGlass() -> NSGlassEffectView {
        let glass = NSGlassEffectView(frame: bounds)
        addSubview(glass, positioned: .below, relativeTo: backing)
        self.glass = glass
        return glass
    }

    private func removeGlass() {
        glass?.removeFromSuperview()
        glass = nil
    }

    /// An alert tints the panel amber/red; otherwise the user's tint, if any.
    /// Strength 0…1 maps to a 0…45 % wash, enough to read as colored glass.
    private func tintColor() -> NSColor? {
        switch alertLevel {
        case .warning: return palette.warm.withAlphaComponent(0.3)
        case .critical: return palette.hot.withAlphaComponent(0.35)
        case .normal:
            guard let tint = style.appearance.tint else { return nil }
            return tint.color.withAlphaComponent(CGFloat(style.appearance.tintStrength) * 0.45)
        }
    }

    // MARK: - Building

    /// Adds a sublayer to the content; text layers are tracked for color/scale.
    func add(_ layer: CALayer) {
        host.layer?.addSublayer(layer)
        if let text = layer as? TextLayer {
            textLayers.append(text)
            text.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        }
    }

    func text(_ style: TextLayer.Style, color: NSColor = .labelColor, alignment: CATextLayerAlignmentMode = .left)
        -> TextLayer
    {
        let layer = TextLayer(style, color: color, alignment: alignment)
        add(layer)
        return layer
    }

    // MARK: - Layout

    private var laidOutSize: CGSize = .zero

    /// Positions layers only. It must not read the store: on macOS 26+ AppKit
    /// tracks `@Observable` reads during `layout()` and re-runs layout whenever
    /// they change, which would redraw every tick even while hidden.
    public override func layout() {
        super.layout()
        for view in [glass, backing, tintWash, host] as [NSView?] {
            if let view, view.frame != bounds { view.frame = bounds }
        }
        let bounds = host.bounds
        let pad = padding
        title.frame = CGRect(x: pad, y: pad, width: bounds.width / 2, height: Self.titleHeight)
        accessory.frame = CGRect(
            x: bounds.width / 2, y: pad, width: bounds.width / 2 - pad, height: Self.titleHeight)
        let top = pad + Self.titleHeight + Self.rowGap
        layoutBody(in: CGRect(x: pad, y: top, width: bounds.width - 2 * pad, height: bounds.height - top - pad))
        guard bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        // Paths depend on size: redraw once, outside layout's observation scope.
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    /// Lays out content below the title row.
    func layoutBody(in rect: CGRect) {}

    /// Extra small tile: the value on the left, a sparkline filling the rest.
    func layoutTile(value: TextLayer, graph: CALayer, in rect: CGRect) {
        let valueWidth: CGFloat = 60
        value.frame = CGRect(x: rect.minX, y: rect.minY - 3, width: valueWidth, height: value.lineHeight)
        graph.frame = CGRect(
            x: rect.minX + valueWidth + 4, y: rect.minY + 2, width: rect.width - valueWidth - 4,
            height: max(rect.height - 2, 1))
    }

    // MARK: - Updating

    /// Pushes the latest data into the layers, then updates the alert tint.
    public func refresh() {
        update()
        let level = style.thresholds.enabled ? currentAlertLevel() : .normal
        guard level != alertLevel else { return }
        let rising = level > alertLevel
        alertLevel = level
        applyBackground()
        if rising, style.appearance.animates { pulse() }
    }

    /// Subclasses push store values into their layers here.
    func update() {}

    /// Subclasses report their alert level from the store and ``style``.
    func currentAlertLevel() -> AlertLevel { .normal }

    /// One soft blink of the content when an alert starts (skipped under Reduce Motion).
    private func pulse() {
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [1, 0.35, 1]
        animation.duration = 0.6
        host.layer?.add(animation, forKey: "pulse")
    }

    // MARK: - Accessibility

    /// Computed only when assistive technology asks, never per tick (setting a
    /// label every tick goes through the accessibility system and costs CPU).
    public override func accessibilityLabel() -> String? {
        let summary = accessibilitySummary()
        switch alertLevel {
        case .normal: return summary
        case .warning: return summary + ", warning"
        case .critical: return summary + ", critical"
        }
    }

    /// Spoken summary, e.g. "CPU 34%". Subclasses override.
    func accessibilitySummary() -> String { title.text }

    // MARK: - Appearance

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for layer in textLayers { layer.contentsScale = scale }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeBackingProperties()
        applyAppearance()
    }

    private func applyAppearance() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let appearance = effectiveAppearance
        for layer in textLayers { layer.resolveColors(in: appearance) }
        resolveColors(in: appearance)
        applyBackground()
        CATransaction.commit()
    }

    /// Subclasses resolve their own colored layers here.
    func resolveColors(in appearance: NSAppearance) {}

    // MARK: - Helpers for subclasses

    /// Runs `body` without implicit animations, as one Core Animation commit.
    func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    static let pending = "—"

    /// Display name of a size, for menus and settings.
    public static func title(of sizeClass: SizeClass) -> String {
        switch sizeClass {
        case .extraSmall: "Extra small"
        case .small: "Small"
        case .medium: "Medium"
        }
    }
}

/// Builds the view for a panel kind. Adding a kind means one panel class and
/// one case here; windows and layout don't change.
@MainActor
public enum PanelViewFactory {
    public static func make(
        kind: PanelKind, sizeClass: SizeClass, store: MetricsStore, style: PanelStyle = .standard,
        options: PanelOptions = PanelOptions()
    ) -> LayerPanelView {
        switch kind {
        case .cpu: CPUPanelView(store: store, sizeClass: sizeClass, style: style)
        case .memory: MemoryPanelView(store: store, sizeClass: sizeClass, style: style)
        case .network: RatePanelView.network(store: store, sizeClass: sizeClass, style: style)
        case .disk: RatePanelView.disk(store: store, sizeClass: sizeClass, style: style)
        case .topProcesses:
            TopProcessesPanelView(store: store, sizeClass: sizeClass, style: style, sort: options.topSort)
        case .gpu: GPUPanelView(store: store, sizeClass: sizeClass, style: style)
        case .battery: BatteryPanelView(store: store, sizeClass: sizeClass, style: style)
        case .thermals: ThermalsPanelView(store: store, sizeClass: sizeClass, style: style)
        case .systemInfo: SystemInfoPanelView(store: store, sizeClass: sizeClass, style: style)
        }
    }

    public static func title(of kind: PanelKind) -> String {
        switch kind {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .network: "Network"
        case .disk: "Disk"
        case .topProcesses: "Top Processes"
        case .gpu: "GPU"
        case .battery: "Battery"
        case .thermals: "Thermals"
        case .systemInfo: "This Mac"
        }
    }
}
