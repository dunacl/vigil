// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

/// The kinds of panel Vigil can show. Each kind has a registered view and the
/// metric groups it needs (see `PanelKind.demand`).
public enum PanelKind: String, Codable, Sendable, CaseIterable {
    case cpu
    case memory
    case network
    case disk
    case topProcesses
    case gpu
    case battery
    /// Thermal state, temperatures, fans and power.
    case thermals
    case systemInfo

    /// Metric groups a visible panel of this kind needs sampled.
    public var demand: Demand {
        switch self {
        case .cpu: .cpu
        case .memory: .memory
        case .network: .network
        case .disk: [.diskIO, .volumes]
        case .topProcesses: .processes
        case .gpu: .gpu
        case .battery: .battery
        case .thermals: .sensors
        case .systemInfo: []
        }
    }
}

/// Discrete panel sizes. Content is laid out per size class, not just scaled.
public enum SizeClass: String, Codable, Sendable, CaseIterable {
    /// One number and a tiny sparkline.
    case extraSmall
    case small
    case medium

    /// Default size in points.
    public var size: Size {
        switch self {
        case .extraSmall: Size(width: 140, height: 64)
        case .small: Size(width: 154, height: 110)
        case .medium: Size(width: 320, height: 180)
        }
    }
}

/// One of nine anchor points on a display's visible frame.
public enum Anchor: String, Codable, Sendable, CaseIterable {
    case topLeading, top, topTrailing
    case leading, center, trailing
    case bottomLeading, bottom, bottomTrailing

    enum Horizontal { case leading, center, trailing }
    enum Vertical { case top, center, bottom }

    var horizontal: Horizontal {
        switch self {
        case .topLeading, .leading, .bottomLeading: .leading
        case .top, .center, .bottom: .center
        case .topTrailing, .trailing, .bottomTrailing: .trailing
        }
    }

    var vertical: Vertical {
        switch self {
        case .topLeading, .top, .topTrailing: .top
        case .leading, .center, .trailing: .center
        case .bottomLeading, .bottom, .bottomTrailing: .bottom
        }
    }

    init(_ horizontal: Horizontal, _ vertical: Vertical) {
        self =
            switch (vertical, horizontal) {
            case (.top, .leading): .topLeading
            case (.top, .center): .top
            case (.top, .trailing): .topTrailing
            case (.center, .leading): .leading
            case (.center, .center): .center
            case (.center, .trailing): .trailing
            case (.bottom, .leading): .bottomLeading
            case (.bottom, .center): .bottom
            case (.bottom, .trailing): .bottomTrailing
            }
    }
}

/// Which display a panel lives on.
public enum DisplayRef: Codable, Sendable, Hashable {
    /// Whichever display is currently main.
    case main
    /// A specific display by `CGDisplayCreateUUIDFromDisplayID` string; stable across reboots.
    case uuid(String)
}

/// Which desktop (Space) a panel lives on.
public enum DesktopRef: Codable, Sendable, Hashable {
    /// Every desktop (public API, always works).
    case all
    /// The desktop where the panel was shown (public API).
    case current
    /// A specific desktop by 1-based position on its display, as in Mission Control.
    /// Requires the private Spaces bridge; falls back to `.all` when unavailable.
    case index(Int)
}

/// What's behind a panel's content.
public enum PanelMaterial: String, Codable, Sendable, CaseIterable {
    /// Liquid Glass; how see-through is set by the transparency slider.
    case glass
    /// An opaque rounded background (also used under Reduce Transparency).
    case solid
    /// No background: content directly on the wallpaper.
    case none
}

/// Settings that only some panel kinds use.
public struct PanelOptions: Codable, Sendable, Hashable {
    /// Top Processes: rank by CPU or memory.
    public var topSort: TopProcessesSort = .cpu

    public init() {}

    enum CodingKeys: String, CodingKey { case topSort }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        topSort = container.lenient(.topSort, default: topSort)
    }
}

/// Window depth relative to icons and app windows.
public enum PanelLevel: String, Codable, Sendable {
    /// Above desktop icons, below all app windows (default).
    case desktop
    /// Below desktop icons; purely visual.
    case behindIcons
    /// Above app windows.
    case floating
}

/// Where a panel sits.
///
/// `offset` is measured from the anchor *into* the display's visible frame
/// (which excludes the menu bar, notch and Dock): leading/trailing anchors
/// measure x away from that edge, top/bottom anchors measure y away from that
/// edge, and center anchors measure from the center (+x right, +y down).
public struct Placement: Codable, Sendable, Hashable {
    enum CodingKeys: String, CodingKey { case display, anchor, offset, size, desktop }

    public var display: DisplayRef
    public var anchor: Anchor
    public var offset: Point
    public var size: Size
    public var desktop: DesktopRef

    public init(display: DisplayRef, anchor: Anchor, offset: Point, size: Size, desktop: DesktopRef = .all) {
        self.display = display
        self.anchor = anchor
        self.offset = offset
        self.size = size
        self.desktop = desktop
    }
}

/// One placed panel.
public struct PanelInstance: Codable, Sendable, Identifiable, Hashable {
    enum CodingKeys: String, CodingKey {
        case id, kind, sizeClass, placement, level, appearance, options, clickThrough, isVisible
        /// M2 files stored the background here; read for migration only.
        case legacyMaterial = "material"
    }

    public var id: String
    public var kind: PanelKind
    public var sizeClass: SizeClass
    public var placement: Placement
    public var level: PanelLevel
    /// Per-panel appearance; empty = use the global defaults.
    public var appearance: AppearanceOverrides
    /// Kind-specific settings.
    public var options: PanelOptions
    /// Clicks pass through to the desktop when `true`.
    public var clickThrough: Bool
    public var isVisible: Bool

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(sizeClass, forKey: .sizeClass)
        try container.encode(placement, forKey: .placement)
        try container.encode(level, forKey: .level)
        if !appearance.isEmpty { try container.encode(appearance, forKey: .appearance) }
        if options != PanelOptions() { try container.encode(options, forKey: .options) }
        try container.encode(clickThrough, forKey: .clickThrough)
        try container.encode(isVisible, forKey: .isVisible)
    }

    public init(
        id: String, kind: PanelKind, sizeClass: SizeClass, placement: Placement, level: PanelLevel = .desktop,
        appearance: AppearanceOverrides = AppearanceOverrides(), options: PanelOptions = PanelOptions(),
        clickThrough: Bool = false, isVisible: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.sizeClass = sizeClass
        self.placement = placement
        self.level = level
        self.appearance = appearance
        self.options = options
        self.clickThrough = clickThrough
        self.isVisible = isVisible
    }
}

/// A named set of panels.
public struct LayoutProfile: Codable, Sendable, Hashable, Identifiable {
    enum CodingKeys: String, CodingKey { case id, name, panels, displays }

    public var id: String
    public var name: String
    public var panels: [PanelInstance]
    /// Display UUIDs this profile is for; when exactly these displays are
    /// connected, it's activated automatically (SPEC §3.5). `nil` = manual only.
    public var displays: [String]?

    public init(id: String = Self.newID(), name: String, panels: [PanelInstance], displays: [String]? = nil) {
        self.id = id
        self.name = name
        self.panels = panels
        self.displays = displays.map { $0.sorted() }
    }

    /// Each panel is a window; more than this isn't a layout anyone uses.
    public static let maximumPanels = 64

    public static func newID() -> String { "layout-" + String(UInt64.random(in: 0...UInt64.max), radix: 36) }

    /// Union of what the given panels need sampled.
    public static func demand(of panels: some Sequence<PanelInstance>) -> Demand {
        panels.reduce(into: Demand()) { $0.formUnion($1.kind.demand) }
    }

    /// The out-of-the-box layout: a column at the top-right of the main display.
    public static let standard: LayoutProfile = {
        let margin = 16.0, gap = 12.0
        let medium = SizeClass.medium.size, small = SizeClass.small.size
        func panel(_ id: String, _ kind: PanelKind, _ sizeClass: SizeClass, x: Double, y: Double) -> PanelInstance {
            PanelInstance(
                id: id, kind: kind, sizeClass: sizeClass,
                placement: Placement(
                    display: .main, anchor: .topTrailing, offset: Point(x: x, y: y), size: sizeClass.size))
        }
        let row3 = margin + 2 * (medium.height + gap)
        return LayoutProfile(
            id: "standard", name: "Standard",
            panels: [
                panel("cpu", .cpu, .medium, x: margin, y: margin),
                panel("memory", .memory, .medium, x: margin, y: margin + medium.height + gap),
                panel("network", .network, .small, x: margin + small.width + gap, y: row3),
                panel("disk", .disk, .small, x: margin, y: row3),
            ])
    }()
}
