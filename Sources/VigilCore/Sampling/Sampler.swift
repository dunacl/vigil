// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import os

/// Sampling settings.
public struct SamplerConfiguration: Sendable, Equatable {
    /// Seconds between samples. Clamped to ``allowedIntervals``.
    public var interval: Double
    public var demand: Demand
    /// Volume capacity changes slowly; it is read at most this often.
    public var volumeRefreshInterval: Double

    public static let allowedIntervals: ClosedRange<Double> = 0.5...10
    public static let `default` = SamplerConfiguration(interval: 2, demand: .all, volumeRefreshInterval: 10)

    public init(interval: Double, demand: Demand, volumeRefreshInterval: Double = 10) {
        self.interval = interval.clamped(to: Self.allowedIntervals)
        self.demand = demand
        self.volumeRefreshInterval = max(1, volumeRefreshInterval)
    }
}

/// Drives all collectors from a single timer and publishes one ``Snapshot`` per tick.
///
/// All mutable sampling state (collectors and their previous readings) is
/// isolated to this actor. Consumers receive immutable snapshots.
///
/// ```swift
/// let sampler = Sampler()
/// for await snapshot in await sampler.snapshots() { ... }
/// ```
public actor Sampler {
    public private(set) var configuration: SamplerConfiguration
    public nonisolated let system: SystemInfo

    private let cpu = CPUCollector()
    private let memory = MemoryCollector()
    private let network = NetworkCollector()
    private let disk = DiskCollector()
    private let processes = ProcessCollector()
    private let gpu = GPUCollector()
    private let battery = BatteryCollector()
    private let sensors = SensorsCollector()
    private var sequence: UInt64 = 0
    private var continuations: [UInt64: AsyncStream<Snapshot>.Continuation] = [:]
    private var nextSubscriberID: UInt64 = 0
    private var loop: Task<Void, Never>?
    private var isPaused = false
    private var changeMonitor: SystemChangeMonitor?

    private static let signposter = OSSignposter(subsystem: "app.vigil.core", category: "sampling")

    public init(configuration: SamplerConfiguration = .default) {
        self.configuration = configuration
        self.system = .current()
    }

    // MARK: - Control

    /// Changes the interval; takes effect from the next tick.
    public func setInterval(_ seconds: Double) {
        configuration.interval = seconds.clamped(to: SamplerConfiguration.allowedIntervals)
    }

    /// Changes which metric groups are collected. Newly demanded groups start
    /// from a fresh baseline so their first rates are never computed across a gap.
    public func setDemand(_ demand: Demand) {
        let added = demand.subtracting(configuration.demand)
        if added.contains(.cpu) { cpu.reset() }
        if added.contains(.memory) { memory.reset() }
        if added.contains(.network) { network.reset() }
        if !added.isDisjoint(with: [.diskIO, .volumes]) { disk.reset() }
        // Only a collector that was off starts over; asking for extra process
        // details (opening the Dashboard) must not blank a tick of CPU rates.
        let processDemand: Demand = [.processes, .processDetails]
        if configuration.demand.isDisjoint(with: processDemand), !demand.isDisjoint(with: processDemand) {
            processes.reset()
        }
        configuration.demand = demand
        // With nothing to collect, the timer stops entirely: zero wakeups.
        if demand.isEmpty { stopLoop() } else { startLoopIfNeeded() }
    }

    /// Temperatures, fans and power use undocumented interfaces; off unless the
    /// user turns them on (SPEC §11).
    public func setPrivateSensorsEnabled(_ enabled: Bool) {
        sensors.privateSensorsEnabled = enabled
    }

    /// Pauses or resumes the timer. While paused nothing is sampled.
    public func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused {
            stopLoop()
        } else {
            resetBaselines()
            startLoopIfNeeded()
        }
    }

    /// Discards previous readings, e.g. after the system wakes from sleep.
    public func resetBaselines() {
        cpu.reset()
        memory.reset()
        network.reset()
        disk.reset()
        processes.reset()
    }

    // MARK: - Output

    /// A stream of snapshots, one per tick. The timer runs while at least one
    /// stream is alive and the sampler isn't paused.
    public func snapshots() -> AsyncStream<Snapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: Snapshot.self, bufferingPolicy: .bufferingNewest(1))
        let id = nextSubscriberID
        nextSubscriberID += 1
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        startLoopIfNeeded()
        return stream
    }

    /// Takes one sample immediately, outside the timer. The first call returns
    /// gauges only; rates appear from the second call on.
    public func sampleNow() -> Snapshot {
        sample(at: .now)
    }

    // MARK: - Loop

    private func removeSubscriber(_ id: UInt64) {
        continuations[id] = nil
        if continuations.isEmpty { stopLoop() }
    }

    private func startLoopIfNeeded() {
        guard loop == nil, !isPaused, !continuations.isEmpty, !configuration.demand.isEmpty else { return }
        loop = Task(priority: .utility) { [weak self] in
            await self?.run()
        }
    }

    private func stopLoop() {
        loop?.cancel()
        loop = nil
    }

    private func run() async {
        let clock = ContinuousClock()
        var deadline = clock.now
        while !Task.isCancelled {
            let snapshot = sample(at: .now)
            for continuation in continuations.values { continuation.yield(snapshot) }

            let interval = Duration.seconds(configuration.interval)
            deadline += interval
            // If we fell behind (sleep, heavy load), re-anchor instead of bursting.
            if deadline < clock.now { deadline = clock.now + interval }
            // 10% tolerance lets the system coalesce our wakeup with others.
            do {
                try await clock.sleep(until: deadline, tolerance: interval / 10)
            } catch {
                return
            }
        }
    }

    /// Takes one sample stamped with `time` instead of the current clock.
    ///
    /// For benchmarks and replay: passing synthetic, evenly spaced times exercises
    /// the full rate path even when samples are taken back to back.
    public func sample(at time: MonotonicInstant) -> Snapshot {
        startMonitoringChangesIfNeeded()
        let started = MonotonicInstant.now
        let state = Self.signposter.beginInterval("sample")
        defer { Self.signposter.endInterval("sample", state) }

        sequence += 1
        let demand = configuration.demand
        let interval = configuration.interval
        disk.volumeRefreshInterval = configuration.volumeRefreshInterval

        var snapshot = Snapshot(sequence: sequence, time: time)
        if demand.contains(.cpu) { snapshot.cpu = cpu.sample(at: time, expectedInterval: interval) }
        if demand.contains(.memory) { snapshot.memory = memory.sample(at: time, expectedInterval: interval) }
        if demand.contains(.network) { snapshot.network = network.sample(at: time, expectedInterval: interval) }
        if !demand.isDisjoint(with: [.diskIO, .volumes]) {
            snapshot.disk = disk.sample(
                at: time, expectedInterval: interval, includeVolumes: demand.contains(.volumes))
        }
        if demand.contains(.gpu) { snapshot.gpu = gpu.sample() }
        if demand.contains(.battery) { snapshot.battery = battery.sample(at: time) }
        if demand.contains(.sensors) { snapshot.sensors = sensors.sample(at: time) }
        if !demand.isDisjoint(with: [.processes, .processDetails]) {
            snapshot.processes = processes.sample(
                at: time, expectedInterval: interval, details: demand.contains(.processDetails))
        }
        snapshot.sampleDuration = MonotonicInstant.now.seconds(since: started)
        return snapshot
    }
}

extension Sampler {
    /// Subscribes to hot-plug and network changes on first use.
    private func startMonitoringChangesIfNeeded() {
        guard changeMonitor == nil else { return }
        changeMonitor = SystemChangeMonitor { [weak self] change in
            Task { await self?.handle(change) }
        }
    }

    private func handle(_ change: SystemChange) {
        switch change {
        case .disks: disk.invalidateDevices()
        case .primaryInterface: network.invalidatePrimaryInterface()
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
