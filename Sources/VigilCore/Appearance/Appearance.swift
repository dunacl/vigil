// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

// Appearance (SPEC §3.6): global defaults, per-panel overrides, and the pure
// resolver that combines them with the user's accessibility settings. Rendering
// code only ever sees a `ResolvedAppearance`.

/// A tint from a small fixed palette (keeps the UI simple and the colors tuned).
public enum TintColor: String, Codable, Sendable, CaseIterable {
    case blue, purple, pink, red, orange, yellow, green, graphite
}

/// "No tint" or a specific tint. Overrides wrap this in an optional, so a panel
/// can inherit, force no tint, or pick a color.
public enum TintChoice: Codable, Sendable, Hashable {
    case none
    case color(TintColor)
}

public enum PanelBorder: String, Codable, Sendable, CaseIterable {
    case off, hairline, accent
}

public enum PanelTheme: String, Codable, Sendable, CaseIterable {
    /// Calm green → amber → red; blue/pink for rates.
    case system
    /// The classic btop terminal palette.
    case btop
    /// Shades of the text color only.
    case mono
}

public enum GraphStyle: String, Codable, Sendable, CaseIterable {
    case area, line
}

/// What happens when the pointer is over a panel.
public enum HoverBehavior: String, Codable, Sendable, CaseIterable {
    case off
    /// Fades to ~25% so the desktop shows through.
    case fade
    /// Disappears (and lets clicks through) until the pointer leaves.
    case hide
}

/// How often a visible panel redraws, in sampler ticks. Slower rates also cut
/// WindowServer cost (≈ half of it is content updates, SPEC §2.1).
public enum RefreshRate: String, Codable, Sendable, CaseIterable {
    case everyTick, everyOtherTick, everyFifthTick

    public var ticks: Int {
        switch self {
        case .everyTick: 1
        case .everyOtherTick: 2
        case .everyFifthTick: 5
        }
    }
}

/// Global appearance defaults. Every field is concrete.
public struct AppearanceSettings: Codable, Sendable, Hashable {
    public var material: PanelMaterial = .glass
    /// 0 = most opaque, 1 = most transparent (see ``TransparencyCurve``).
    public var transparency: Double = 0.4
    /// Opacity of the numbers and graphs, independent of the background.
    public var contentOpacity: Double = 1
    public var tint: TintChoice = .none
    public var tintStrength: Double = 0.3
    public var cornerRadius: Double = 20
    public var border: PanelBorder = .off
    public var theme: PanelTheme = .system
    public var graphStyle: GraphStyle = .area
    public var hover: HoverBehavior = .off
    public var refresh: RefreshRate = .everyTick

    public init() {}
}

/// Per-panel overrides: `nil` means "inherit the global default".
public struct AppearanceOverrides: Codable, Sendable, Hashable {
    public var material: PanelMaterial?
    public var transparency: Double?
    public var contentOpacity: Double?
    public var tint: TintChoice?
    public var tintStrength: Double?
    public var cornerRadius: Double?
    public var border: PanelBorder?
    public var theme: PanelTheme?
    public var graphStyle: GraphStyle?
    public var hover: HoverBehavior?
    public var refresh: RefreshRate?

    public init() {}

    public var isEmpty: Bool { self == AppearanceOverrides() }

    /// The global settings with these overrides applied.
    public func applied(to global: AppearanceSettings) -> AppearanceSettings {
        var result = global
        if let material { result.material = material }
        if let transparency { result.transparency = transparency }
        if let contentOpacity { result.contentOpacity = contentOpacity }
        if let tint { result.tint = tint }
        if let tintStrength { result.tintStrength = tintStrength }
        if let cornerRadius { result.cornerRadius = cornerRadius }
        if let border { result.border = border }
        if let theme { result.theme = theme }
        if let graphStyle { result.graphStyle = graphStyle }
        if let hover { result.hover = hover }
        if let refresh { result.refresh = refresh }
        return result
    }
}

/// The user's macOS accessibility display settings.
public struct AccessibilityDisplay: Sendable, Hashable {
    public var reduceTransparency = false
    public var increaseContrast = false
    public var reduceMotion = false

    public init(reduceTransparency: Bool = false, increaseContrast: Bool = false, reduceMotion: Bool = false) {
        self.reduceTransparency = reduceTransparency
        self.increaseContrast = increaseContrast
        self.reduceMotion = reduceMotion
    }
}

/// How the panel background is drawn.
public enum ResolvedBackground: Sendable, Hashable {
    /// Liquid Glass. `glassOpacity` fades the glass itself; `backingOpacity` is an
    /// opaque layer under the content (for legibility / the opaque end of the slider).
    case glass(clear: Bool, glassOpacity: Double, backingOpacity: Double)
    case solid
    /// Content directly on the wallpaper.
    case none
}

/// Everything a panel needs to draw itself. Produced only by ``AppearanceResolver``.
public struct ResolvedAppearance: Sendable, Hashable {
    public var background: ResolvedBackground
    public var contentOpacity: Double
    public var tint: TintColor?
    public var tintStrength: Double
    public var cornerRadius: Double
    public var border: PanelBorder
    public var theme: PanelTheme
    public var graphStyle: GraphStyle
    public var hover: HoverBehavior
    public var refreshTicks: Int
    /// `false` under Reduce Motion: no pulses, no fades.
    public var animates: Bool
}

/// Maps the single transparency slider onto Liquid Glass (SPEC §3.6). The glass
/// API has no blur or opacity knob, so the slider walks through:
///
/// | slider | result |
/// | --- | --- |
/// | 0.00–0.30 | regular glass over an opaque backing that fades out |
/// | 0.30–0.55 | regular glass |
/// | 0.55–0.80 | clear glass |
/// | 0.80–1.00 | clear glass fading to 15 % |
///
/// Only the slider value is saved, so this curve can be retuned freely.
public enum TransparencyCurve {
    public static func background(for transparency: Double) -> ResolvedBackground {
        let t = min(max(transparency, 0), 1)
        switch t {
        case ..<0.30: return .glass(clear: false, glassOpacity: 1, backingOpacity: 1 - t / 0.30)
        case ..<0.55: return .glass(clear: false, glassOpacity: 1, backingOpacity: 0)
        case ..<0.80: return .glass(clear: true, glassOpacity: 1, backingOpacity: 0)
        default: return .glass(clear: true, glassOpacity: 1 - (t - 0.80) / 0.20 * 0.85, backingOpacity: 0)
        }
    }
}

public enum AppearanceResolver {
    public static func resolve(
        global: AppearanceSettings, overrides: AppearanceOverrides, accessibility: AccessibilityDisplay
    ) -> ResolvedAppearance {
        let settings = overrides.applied(to: global)
        var background: ResolvedBackground =
            switch settings.material {
            case .glass: TransparencyCurve.background(for: settings.transparency)
            case .solid: .solid
            case .none: .none
            }
        var border = settings.border
        if accessibility.reduceTransparency {
            // Reduce Transparency wins over every slider (SPEC §3.6).
            if case .glass = background { background = .solid }
        }
        if accessibility.increaseContrast {
            if border == .off { border = .hairline }
            // Legibility backing on: glass keeps its shape but gets an opaque base.
            if case .glass(let clear, let opacity, _) = background {
                background = .glass(clear: clear, glassOpacity: opacity, backingOpacity: 1)
            }
        }
        let tint: TintColor? =
            switch settings.tint {
            case .none: nil
            case .color(let color): color
            }
        return ResolvedAppearance(
            background: background,
            contentOpacity: min(max(settings.contentOpacity, 0.2), 1),
            tint: tint,
            tintStrength: min(max(settings.tintStrength, 0), 1),
            cornerRadius: min(max(settings.cornerRadius, 0), 32),
            border: border,
            theme: settings.theme,
            graphStyle: settings.graphStyle,
            hover: settings.hover,
            refreshTicks: settings.refresh.ticks,
            animates: !accessibility.reduceMotion)
    }
}
