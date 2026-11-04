// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

/// The metric groups a consumer can ask for. The sampler only runs collectors
/// that are demanded, so nothing pays for metrics no visible panel shows.
public struct Demand: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let cpu = Demand(rawValue: 1 << 0)
    public static let memory = Demand(rawValue: 1 << 1)
    public static let network = Demand(rawValue: 1 << 2)
    /// Physical disk I/O.
    public static let diskIO = Demand(rawValue: 1 << 3)
    /// Mounted volume capacity (slow cadence).
    public static let volumes = Demand(rawValue: 1 << 4)
    /// The process list (the most expensive collector; only while shown).
    public static let processes = Demand(rawValue: 1 << 5)
    /// Extra per-process detail (thread counts); implies `.processes`.
    public static let processDetails = Demand(rawValue: 1 << 6)
    public static let gpu = Demand(rawValue: 1 << 7)
    public static let battery = Demand(rawValue: 1 << 8)
    /// Thermal state, plus temperatures/fans/power when private sensors are on.
    public static let sensors = Demand(rawValue: 1 << 9)

    /// Everything except the process collectors, which are opt-in.
    public static let all: Demand = [.cpu, .memory, .network, .diskIO, .volumes]
}

/// One immutable sample of everything that was demanded.
///
/// A group is `nil` when it wasn't demanded or couldn't be read; within a group,
/// rates are `nil` on the first sample after a (re)start or gap.
public struct Snapshot: Sendable {
    /// Monotonically increasing per sampler, starting at 1.
    public var sequence: UInt64
    public var time: MonotonicInstant
    public var cpu: CPUMetrics?
    public var memory: MemoryMetrics?
    public var network: NetworkMetrics?
    public var disk: DiskMetrics?
    public var processes: ProcessMetrics?
    public var gpu: GPUMetrics?
    public var battery: BatteryMetrics?
    public var sensors: SensorMetrics?
    /// Wall time the collectors took for this sample, for self-monitoring.
    public var sampleDuration: Double

    public init(
        sequence: UInt64, time: MonotonicInstant, cpu: CPUMetrics? = nil, memory: MemoryMetrics? = nil,
        network: NetworkMetrics? = nil, disk: DiskMetrics? = nil, processes: ProcessMetrics? = nil,
        sampleDuration: Double = 0
    ) {
        self.sequence = sequence
        self.time = time
        self.cpu = cpu
        self.memory = memory
        self.network = network
        self.disk = disk
        self.processes = processes
        self.sampleDuration = sampleDuration
    }
}
