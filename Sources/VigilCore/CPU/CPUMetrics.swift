// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

/// Cumulative Mach tick counters for one logical CPU. They wrap at 2³².
public struct CPUTicks: Sendable, Equatable, BitwiseCopyable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    public static let zero = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
}

/// CPU utilization over one sample interval. All values are fractions in 0...1.
public struct CPULoad: Sendable, Equatable {
    public var user: Double
    public var system: Double
    public var nice: Double

    public init(user: Double, system: Double, nice: Double) {
        self.user = user
        self.system = system
        self.nice = nice
    }

    /// Busy fraction (everything except idle).
    public var total: Double { user + system + nice }

    public static let zero = CPULoad(user: 0, system: 0, nice: 0)

    /// Computes load from two tick readings. `nil` if any counter reset.
    /// A core with no elapsed ticks (e.g. parked) reports zero load.
    public init?(previous: CPUTicks, current: CPUTicks) {
        guard let user = Counter.wrappingDelta(previous.user, current.user),
            let system = Counter.wrappingDelta(previous.system, current.system),
            let idle = Counter.wrappingDelta(previous.idle, current.idle),
            let nice = Counter.wrappingDelta(previous.nice, current.nice)
        else { return nil }
        let total = Double(user) + Double(system) + Double(idle) + Double(nice)
        guard total > 0 else {
            self = .zero
            return
        }
        self.init(user: Double(user) / total, system: Double(system) / total, nice: Double(nice) / total)
    }
}

/// 1, 5 and 15 minute run-queue load averages.
public struct LoadAverage: Sendable, Equatable {
    public var one: Double
    public var five: Double
    public var fifteen: Double

    public init(one: Double, five: Double, fifteen: Double) {
        self.one = one
        self.five = five
        self.fifteen = fifteen
    }

    public static let zero = LoadAverage(one: 0, five: 0, fifteen: 0)
}

/// CPU metrics for one sample.
public struct CPUMetrics: Sendable, Equatable {
    /// Average over all logical CPUs (each core weighted equally, like Activity Monitor).
    public var overall: CPULoad
    /// One entry per logical CPU, indexed like ``CPUTopology/Tier/cores``.
    public var cores: [CPULoad]
    public var loadAverage: LoadAverage

    public init(overall: CPULoad, cores: [CPULoad], loadAverage: LoadAverage) {
        self.overall = overall
        self.cores = cores
        self.loadAverage = loadAverage
    }

    /// Average busy fraction of the given cores (e.g. one tier).
    public func average(of range: Range<Int>) -> CPULoad {
        let slice = cores[range.clamped(to: cores.indices)]
        guard !slice.isEmpty else { return .zero }
        var sum = CPULoad.zero
        for load in slice {
            sum.user += load.user
            sum.system += load.system
            sum.nice += load.nice
        }
        let count = Double(slice.count)
        return CPULoad(user: sum.user / count, system: sum.system / count, nice: sum.nice / count)
    }

    /// Builds metrics from two per-core tick readings of equal length.
    /// Returns `nil` if the core count changed or any counter reset.
    public static func make(
        previous: [CPUTicks], current: [CPUTicks], loadAverage: LoadAverage
    ) -> CPUMetrics? {
        guard previous.count == current.count, !current.isEmpty else { return nil }
        var cores: [CPULoad] = []
        cores.reserveCapacity(current.count)
        for index in current.indices {
            guard let load = CPULoad(previous: previous[index], current: current[index]) else { return nil }
            cores.append(load)
        }
        var metrics = CPUMetrics(overall: .zero, cores: cores, loadAverage: loadAverage)
        metrics.overall = metrics.average(of: cores.indices)
        return metrics
    }
}
