// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import Testing

@testable import VigilCore

@Suite struct CPULoadTests {
    @Test func fractionsOfElapsedTicks() throws {
        let previous = CPUTicks(user: 100, system: 50, idle: 800, nice: 0)
        let current = CPUTicks(user: 160, system: 70, idle: 910, nice: 10)  // +60 +20 +110 +10 = 200
        let load = try #require(CPULoad(previous: previous, current: current))
        #expect(load.user == 0.30)
        #expect(load.system == 0.10)
        #expect(load.nice == 0.05)
        #expect(abs(load.total - 0.45) < 1e-12)
    }

    @Test func tickCounterWrapIsHandled() throws {
        let previous = CPUTicks(user: UInt32.max - 49, system: 0, idle: 0, nice: 0)
        let current = CPUTicks(user: 50, system: 0, idle: 100, nice: 0)  // +100 user, +100 idle
        let load = try #require(CPULoad(previous: previous, current: current))
        #expect(load.user == 0.5)
    }

    @Test func counterResetGivesNoValue() {
        let previous = CPUTicks(user: 5_000, system: 5_000, idle: 5_000, nice: 0)
        #expect(CPULoad(previous: previous, current: .zero) == nil)
    }

    @Test func coreWithNoElapsedTicksIsIdle() {
        let ticks = CPUTicks(user: 1, system: 2, idle: 3, nice: 4)
        #expect(CPULoad(previous: ticks, current: ticks) == .zero)
    }
}

@Suite struct CPUMetricsTests {
    let previous = [
        CPUTicks(user: 0, system: 0, idle: 0, nice: 0),
        CPUTicks(user: 0, system: 0, idle: 0, nice: 0),
    ]
    let current = [
        CPUTicks(user: 100, system: 0, idle: 0, nice: 0),  // 100% busy
        CPUTicks(user: 0, system: 0, idle: 100, nice: 0),  // idle
    ]

    @Test func overallIsTheAverageOfCores() throws {
        let metrics = try #require(CPUMetrics.make(previous: previous, current: current, loadAverage: .zero))
        #expect(metrics.cores.count == 2)
        #expect(metrics.overall.total == 0.5)
        #expect(metrics.average(of: 0..<1).total == 1)
        #expect(metrics.average(of: 1..<2).total == 0)
    }

    @Test func coreCountChangeGivesNoValue() {
        #expect(CPUMetrics.make(previous: previous, current: [current[0]], loadAverage: .zero) == nil)
    }

    @Test func outOfRangeTierAverageIsSafe() throws {
        let metrics = try #require(CPUMetrics.make(previous: previous, current: current, loadAverage: .zero))
        #expect(metrics.average(of: 5..<9) == .zero)
    }
}

@Suite struct CPUTopologyTests {
    @Test func m5ProTiersAreNamedByTheSystemAndOrderedByLogicalCPU() {
        // M5 Pro: perflevel0 "Super" ×6, perflevel1 "Performance" ×12.
        // Logical CPUs 0–11 are perflevel1, 12–17 are perflevel0.
        let topology = CPUTopology.make(
            logicalCPUCount: 18,
            levels: [(0, "Super", 6), (1, "Performance", 12)],
            brand: "Apple M5 Pro")
        #expect(topology.tiers.map(\.name) == ["Performance", "Super"])
        #expect(topology.tiers.map(\.cores) == [0..<12, 12..<18])
        #expect(topology.tiers.map(\.level) == [1, 0])
    }

    @Test func classicPerformanceEfficiencySplit() {
        let topology = CPUTopology.make(
            logicalCPUCount: 8, levels: [(0, "Performance", 4), (1, "Efficiency", 4)], brand: "Apple M1")
        #expect(topology.tiers.map(\.name) == ["Efficiency", "Performance"])
        #expect(topology.tiers.map(\.cores) == [0..<4, 4..<8])
    }

    @Test func inconsistentCountsFallBackToOneTier() {
        let topology = CPUTopology.make(
            logicalCPUCount: 10, levels: [(0, "Performance", 4), (1, "Efficiency", 4)], brand: "?")
        #expect(topology.tiers.count == 1)
        #expect(topology.tiers[0].cores == 0..<10)
    }

    @Test func noPerfLevelsMeansOneTier() {
        let topology = CPUTopology.make(logicalCPUCount: 16, levels: [], brand: "Intel")
        #expect(topology.tiers == [.init(level: 0, name: "CPU", cores: 0..<16)])
    }
}
