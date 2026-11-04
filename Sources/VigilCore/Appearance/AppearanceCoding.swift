// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

// Lenient decoding for settings: a missing key or a value this version doesn't
// know (e.g. a theme added later) falls back to the default for that field only.

extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ key: Key, default value: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? value
    }

    func lenient<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

extension AppearanceSettings {
    enum CodingKeys: String, CodingKey {
        case material, transparency, contentOpacity, tint, tintStrength, cornerRadius, border, theme, graphStyle,
            hover, refresh
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppearanceSettings()
        self.init()
        material = c.lenient(.material, default: d.material)
        transparency = c.lenient(.transparency, default: d.transparency)
        contentOpacity = c.lenient(.contentOpacity, default: d.contentOpacity)
        tint = c.lenient(.tint, default: d.tint)
        tintStrength = c.lenient(.tintStrength, default: d.tintStrength)
        cornerRadius = c.lenient(.cornerRadius, default: d.cornerRadius)
        border = c.lenient(.border, default: d.border)
        theme = c.lenient(.theme, default: d.theme)
        graphStyle = c.lenient(.graphStyle, default: d.graphStyle)
        hover = c.lenient(.hover, default: d.hover)
        refresh = c.lenient(.refresh, default: d.refresh)
    }
}

extension AppearanceOverrides {
    enum CodingKeys: String, CodingKey {
        case material, transparency, contentOpacity, tint, tintStrength, cornerRadius, border, theme, graphStyle,
            hover, refresh
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        material = c.lenient(.material)
        transparency = c.lenient(.transparency)
        contentOpacity = c.lenient(.contentOpacity)
        tint = c.lenient(.tint)
        tintStrength = c.lenient(.tintStrength)
        cornerRadius = c.lenient(.cornerRadius)
        border = c.lenient(.border)
        theme = c.lenient(.theme)
        graphStyle = c.lenient(.graphStyle)
        hover = c.lenient(.hover)
        refresh = c.lenient(.refresh)
    }
}

extension UnitSettings {
    enum CodingKeys: String, CodingKey { case bytes, networkInBits }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        bytes = c.lenient(.bytes, default: bytes)
        networkInBits = c.lenient(.networkInBits, default: networkInBits)
    }
}

extension ThresholdSettings {
    enum CodingKeys: String, CodingKey {
        case enabled, cpuWarning, cpuCritical, sustainSeconds, diskWarning, diskCritical
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        func fraction(_ key: CodingKeys, _ fallback: Double) -> Double {
            let value: Double = c.lenient(key, default: fallback)
            return value.isFinite ? min(max(value, 0), 1) : fallback
        }
        enabled = c.lenient(.enabled, default: enabled)
        cpuWarning = fraction(.cpuWarning, cpuWarning)
        cpuCritical = fraction(.cpuCritical, cpuCritical)
        let sustain: Double = c.lenient(.sustainSeconds, default: sustainSeconds)
        sustainSeconds = sustain.isFinite ? min(max(sustain, 0), 600) : 10
        diskWarning = fraction(.diskWarning, diskWarning)
        diskCritical = fraction(.diskCritical, diskCritical)
    }
}

extension VigilSettings {
    enum CodingKeys: String, CodingKey { case general, appearance, units, thresholds }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        general = c.lenient(.general, default: general)
        appearance = c.lenient(.appearance, default: appearance)
        units = c.lenient(.units, default: units)
        thresholds = c.lenient(.thresholds, default: thresholds)
    }
}
