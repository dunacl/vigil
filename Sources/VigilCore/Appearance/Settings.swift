// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

/// Units for displayed values (SPEC §3.6 "Units").
public struct UnitSettings: Codable, Sendable, Hashable {
    /// Binary (KiB, like Activity Monitor's memory) or decimal (kB, like Finder).
    public var bytes: Units.ByteStyle = .binary
    /// Network rates in bits per second (Mb/s) instead of bytes.
    public var networkInBits = false

    public init() {}
}

/// Warning/critical levels that tint a panel (SPEC §3.6 "Thresholds").
public struct ThresholdSettings: Codable, Sendable, Hashable {
    public var enabled = true
    /// CPU busy fraction sustained for ``sustainSeconds``.
    public var cpuWarning = 0.85
    public var cpuCritical = 0.95
    public var sustainSeconds = 10.0
    /// Volume fullness (instant).
    public var diskWarning = 0.90
    public var diskCritical = 0.95

    public init() {}

    /// How many samples "sustained for `sustainSeconds`" means at `interval`.
    /// Bounded (1…300) whatever the settings file says, so a bad value can't
    /// overflow or make a check scan forever.
    public func sustainSamples(interval: Double) -> Int {
        let seconds = sustainSeconds.isFinite ? min(max(sustainSeconds, 0), 600) : 10
        let step = interval.isFinite && interval >= 0.5 ? interval : 2
        return min(max(Int((seconds / step).rounded(.up)), 1), 300)
    }
}

/// All global settings, stored in `UserDefaults` as one JSON value (SPEC §9).
public struct VigilSettings: Codable, Sendable, Hashable {
    public var general = GeneralSettings()
    public var appearance = AppearanceSettings()
    public var units = UnitSettings()
    public var thresholds = ThresholdSettings()

    public init() {}
}

/// Alert level shown by a panel.
public enum AlertLevel: Int, Sendable, Comparable {
    case normal, warning, critical

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Stateless threshold checks over recent history: a level holds only when
/// every one of the last `samples` values is at or above it, so a brief spike
/// never tints a panel.
public enum ThresholdEvaluator {
    public static func level(
        history: RingBuffer<Float>, warning: Double, critical: Double, samples: Int
    ) -> AlertLevel {
        let window = max(samples, 1)
        guard history.count >= window else { return .normal }
        var minimum = Double.infinity
        for index in (history.count - window)..<history.count {
            minimum = min(minimum, Double(history[index]))
        }
        if minimum >= critical { return .critical }
        if minimum >= warning { return .warning }
        return .normal
    }

    public static func level(memoryPressure: MemoryPressure) -> AlertLevel {
        switch memoryPressure {
        case .critical: .critical
        case .warning: .warning
        case .normal, .unknown: .normal
        }
    }

    public static func level(fullness: Double, warning: Double, critical: Double) -> AlertLevel {
        fullness >= critical ? .critical : fullness >= warning ? .warning : .normal
    }
}

/// What the menu bar item shows next to its icon (SPEC §3.1).
public enum MenuBarReadout: String, Codable, Sendable, CaseIterable {
    case iconOnly, cpu, cpuAndMemory, network

    /// Metric groups the readout needs sampled even when no panel shows them.
    public var demand: Demand {
        switch self {
        case .iconOnly: []
        case .cpu: .cpu
        case .cpuAndMemory: [.cpu, .memory]
        case .network: .network
        }
    }
}

/// A global keyboard shortcut, stored as a virtual key code and Carbon modifier
/// mask (control 4096, option 2048, command 256, shift 512).
public struct KeyShortcut: Codable, Sendable, Hashable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let controlOption: UInt32 = 4096 | 2048
    public static let editLayout = KeyShortcut(keyCode: 14, modifiers: controlOption)  // ⌃⌥E
    public static let dashboard = KeyShortcut(keyCode: 9, modifiers: controlOption)  // ⌃⌥V
    public static let peek = KeyShortcut(keyCode: 49, modifiers: controlOption)  // ⌃⌥Space
}

/// Global shortcuts; `nil` turns one off.
public struct ShortcutSettings: Codable, Sendable, Hashable {
    public var editLayout: KeyShortcut? = .editLayout
    public var dashboard: KeyShortcut? = .dashboard
    public var peek: KeyShortcut? = .peek

    public init() {}

    enum CodingKeys: String, CodingKey { case editLayout, dashboard, peek }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A key missing from the file keeps its default; an explicit null turns it off.
        self.init()
        if c.contains(.editLayout) { editLayout = c.lenient(.editLayout) }
        if c.contains(.dashboard) { dashboard = c.lenient(.dashboard) }
        if c.contains(.peek) { peek = c.lenient(.peek) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(editLayout, forKey: .editLayout)  // encodes null when off
        try c.encode(dashboard, forKey: .dashboard)
        try c.encode(peek, forKey: .peek)
    }
}

/// App-wide behavior (Settings → General).
public struct GeneralSettings: Codable, Sendable, Hashable {
    /// Icon only by default: a live number in the menu bar measured ~0.18 % CPU
    /// on macOS 27 (title updates cross to the system's menu bar renderer) —
    /// more than all the default panels together. Opt-in.
    public var menuBar: MenuBarReadout = .iconOnly
    /// Keep panels out of screenshots and screen sharing (`NSWindow.sharingType = .none`).
    public var hideFromScreenCapture = false
    /// Sample half as often in Low Power Mode or when the Mac is hot (SPEC §4.4).
    public var adaptiveSampling = true
    /// Read temperatures, fans and power through undocumented interfaces (SPEC §11). Off by default.
    public var privateSensors = false
    public var shortcuts = ShortcutSettings()

    public init() {}

    enum CodingKeys: String, CodingKey {
        case menuBar, hideFromScreenCapture, adaptiveSampling, privateSensors, shortcuts
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        menuBar = c.lenient(.menuBar, default: menuBar)
        hideFromScreenCapture = c.lenient(.hideFromScreenCapture, default: hideFromScreenCapture)
        adaptiveSampling = c.lenient(.adaptiveSampling, default: adaptiveSampling)
        privateSensors = c.lenient(.privateSensors, default: privateSensors)
        shortcuts = c.lenient(.shortcuts, default: shortcuts)
    }
}

/// How often to sample (SPEC §4.4 "Low Power Mode / thermal ≥ serious").
public enum SamplingPolicy {
    /// Thermal levels as in `ProcessInfo.ThermalState` (0 nominal … 3 critical).
    public static func interval(base: Double, adaptive: Bool, lowPowerMode: Bool, thermalState: Int) -> Double {
        guard adaptive, lowPowerMode || thermalState >= 2 else { return base }
        return base * 2
    }
}
