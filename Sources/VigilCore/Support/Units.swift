// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

/// Unit formatting for display. Not used on the sampling hot path.
public enum Units {
    public enum ByteStyle: String, Sendable, Codable, CaseIterable {
        /// Powers of 1024: KiB, MiB, GiB (what Activity Monitor uses for memory).
        case binary
        /// Powers of 1000: kB, MB, GB (what Finder uses for disks).
        case decimal
    }

    /// Formats a byte count, e.g. `"21.4 GiB"` or `"512 B"`.
    public static func bytes(_ value: Double, style: ByteStyle = .binary) -> String {
        let (base, suffixes): (Double, [String]) =
            switch style {
            case .binary: (1024, ["B", "KiB", "MiB", "GiB", "TiB", "PiB"])
            case .decimal: (1000, ["B", "kB", "MB", "GB", "TB", "PB"])
            }
        return scaled(value, base: base, suffixes: suffixes)
    }

    /// Formats a byte rate. With `bits` the value is shown in bits per second
    /// (decimal, as networks are rated), e.g. `"12.5 Mb/s"`.
    public static func rate(bytesPerSecond value: Double, style: ByteStyle = .binary, bits: Bool = false) -> String {
        if bits {
            return scaled(value * 8, base: 1000, suffixes: ["b/s", "kb/s", "Mb/s", "Gb/s", "Tb/s"])
        }
        return bytes(value, style: style) + "/s"
    }

    /// Formats a 0...1 fraction as a percentage, e.g. `"34.2%"`.
    public static func percent(_ fraction: Double, decimals: Int = 1) -> String {
        guard fraction.isFinite else { return "—" }
        return number(max(0, fraction) * 100, decimals: decimals) + "%"
    }

    /// Formats a duration in seconds as e.g. `"3d 4h"`, `"5h 12m"`, `"42s"`.
    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds)
        let days = total / 86_400, hours = total % 86_400 / 3600, minutes = total % 3600 / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(total % 60)s" }
        return "\(total)s"
    }

    /// Rounds a value up to the next 1-2-5 step (…, 1 k, 2 k, 5 k, 10 k, …) in
    /// powers of `base`, never below `floor`. Gives btop-style auto-scaling graph
    /// ceilings that don't jitter with every sample.
    public static func niceCeiling(_ value: Double, floor: Double = 1, base: Double = 1024) -> Double {
        let target = max(value, floor)
        guard target.isFinite, target > 0 else { return floor }
        var magnitude = 1.0
        while magnitude * base <= target { magnitude *= base }
        for step in [1.0, 2, 5, 10, 20, 50, 100, 200, 500, base] where magnitude * step >= target {
            return magnitude * step
        }
        return magnitude * base
    }

    private static func scaled(_ value: Double, base: Double, suffixes: [String]) -> String {
        guard value.isFinite else { return "—" }
        var scaled = max(0, value)
        var index = 0
        while scaled >= base, index < suffixes.count - 1 {
            scaled /= base
            index += 1
        }
        let decimals = index == 0 ? 0 : (scaled < 10 ? 2 : scaled < 100 ? 1 : 0)
        return number(scaled, decimals: decimals) + " " + suffixes[index]
    }

    /// Locale-independent fixed-point formatting of a non-negative value,
    /// e.g. `number(2.5, decimals: 2)` → `"2.50"`. Stable output for tests and logs.
    public static func number(_ value: Double, decimals: Int) -> String {
        // Int(_:) traps beyond ±9.2e18; garbage readings (e.g. from undocumented
        // sensors) must render as "—", never crash.
        guard value.isFinite, abs(value) < 1e15 else { return "—" }
        guard decimals > 0 else { return String(Int(value.rounded())) }
        var factor = 1.0
        for _ in 0..<decimals { factor *= 10 }
        let rounded = (value * factor).rounded()
        let whole = Int(rounded / factor)
        let fraction = Int(abs(rounded - Double(whole) * factor))
        let digits = String(fraction)
        return "\(whole)." + String(repeating: "0", count: max(0, decimals - digits.count)) + digits
    }
}
