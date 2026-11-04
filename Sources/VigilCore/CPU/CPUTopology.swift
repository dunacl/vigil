// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

/// How logical CPUs are grouped into performance tiers.
///
/// Apple Silicon exposes tiers as `hw.perflevelN` (0 = fastest). Names come from
/// the system — e.g. "Performance"/"Efficiency" on M1–M4, "Super"/"Performance"
/// on M5 Pro — so nothing here assumes a P/E split.
///
/// Logical CPU numbering runs from the *highest* perf-level index down to
/// `perflevel0` (verified against `IODeviceTree` `cluster-type` on M1 and M5 Pro),
/// so each tier is a contiguous range of logical CPUs.
public struct CPUTopology: Sendable, Equatable {
    public struct Tier: Sendable, Equatable, Identifiable {
        /// `hw.perflevelN` index; 0 is the fastest tier.
        public let level: Int
        public let name: String
        /// Logical CPU indices (as reported by `host_processor_info`) in this tier.
        public let cores: Range<Int>

        public var id: Int { level }
    }

    public let logicalCPUCount: Int
    /// Ordered by logical CPU index (slowest tier first, as macOS numbers them).
    public let tiers: [Tier]
    public let brand: String

    public init(logicalCPUCount: Int, tiers: [Tier], brand: String) {
        self.logicalCPUCount = logicalCPUCount
        self.tiers = tiers
        self.brand = brand
    }

    /// Reads the topology of this Mac.
    public static func current() -> CPUTopology {
        let count = Int(Sysctl.integer("hw.logicalcpu") ?? Sysctl.integer("hw.ncpu") ?? 1)
        let brand = Sysctl.string("machdep.cpu.brand_string") ?? "CPU"
        let levels = Int(Sysctl.integer("hw.nperflevels") ?? 0)
        let described: [(level: Int, name: String, count: Int)] = (0..<max(levels, 0)).compactMap { level in
            guard let cpus = Sysctl.integer("hw.perflevel\(level).logicalcpu"), cpus > 0 else { return nil }
            let name = Sysctl.string("hw.perflevel\(level).name") ?? "Level \(level)"
            return (level, name, Int(cpus))
        }
        return make(logicalCPUCount: count, levels: described, brand: brand)
    }

    /// Builds tiers from per-level counts; falls back to a single tier if the
    /// counts don't add up (Intel, virtual machines, unexpected hardware).
    static func make(
        logicalCPUCount: Int, levels: [(level: Int, name: String, count: Int)], brand: String
    ) -> CPUTopology {
        let single = [Tier(level: 0, name: "CPU", cores: 0..<logicalCPUCount)]
        guard levels.count > 1, levels.reduce(0, { $0 + $1.count }) == logicalCPUCount else {
            return CPUTopology(logicalCPUCount: logicalCPUCount, tiers: single, brand: brand)
        }
        var start = 0
        var tiers: [Tier] = []
        for level in levels.sorted(by: { $0.level > $1.level }) {
            tiers.append(Tier(level: level.level, name: level.name, cores: start..<(start + level.count)))
            start += level.count
        }
        return CPUTopology(logicalCPUCount: logicalCPUCount, tiers: tiers, brand: brand)
    }
}
