// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.
//
// Runs the real collectors against this Mac.

import Darwin
import Testing

@testable import VigilCore

// Serialized: the Mach port check counts ports process-wide, so other samplers
// starting or stopping concurrently would skew it.
@Suite(.serialized) struct SamplerIntegrationTests {
    /// Two samples one synthetic interval apart, so rates are produced.
    func twoSamples(_ sampler: Sampler) async -> Snapshot {
        let start = MonotonicInstant.now
        _ = await sampler.sample(at: start)
        try? await Task.sleep(for: .milliseconds(200))  // let CPU ticks advance
        return await sampler.sample(at: MonotonicInstant(nanoseconds: start.nanoseconds + 2_000_000_000))
    }

    @Test func realReadingsAreInSaneRanges() async throws {
        let sampler = Sampler()
        let snapshot = await twoSamples(sampler)
        let system = sampler.system

        let cpu = try #require(snapshot.cpu)
        #expect(cpu.cores.count == system.cpu.logicalCPUCount)
        #expect((0...1).contains(cpu.overall.total))
        #expect(cpu.cores.allSatisfy { (0...1).contains($0.total) })
        #expect(system.cpu.tiers.reduce(0) { $0 + $1.cores.count } == system.cpu.logicalCPUCount)

        let memory = try #require(snapshot.memory)
        #expect(memory.totalBytes == system.memoryBytes)
        #expect(memory.usedBytes > 0 && memory.usedBytes <= memory.totalBytes)
        #expect(memory.pressure != .unknown)

        let network = try #require(snapshot.network)
        #expect(network["lo0"]?.isLoopback == true)
        #expect(network.interfaces.allSatisfy { ($0.receivedBytesPerSecond ?? 0) >= 0 })

        let disk = try #require(snapshot.disk)
        #expect(!disk.disks.isEmpty)
        #expect(disk.disks.allSatisfy { $0.bsdName.hasPrefix("disk") })
        let root = try #require(disk.volumes.first { $0.mountPoint == "/" })
        #expect(root.totalBytes > 0 && root.availableBytes <= root.totalBytes)

        #expect(snapshot.sampleDuration < 0.05)
    }

    @Test func onlyDemandedGroupsAreCollected() async {
        let sampler = Sampler(configuration: .init(interval: 2, demand: [.cpu]))
        let snapshot = await sampler.sampleNow()
        #expect(snapshot.memory == nil)
        #expect(snapshot.network == nil)
        #expect(snapshot.disk == nil)

        await sampler.setDemand([.memory])
        let next = await sampler.sampleNow()
        #expect(next.cpu == nil)
        #expect(next.memory != nil)
    }

    @Test func newlyDemandedGroupStartsFromAFreshBaseline() async {
        let sampler = Sampler(configuration: .init(interval: 2, demand: [.cpu, .network]))
        _ = await twoSamples(sampler)
        await sampler.setDemand([.cpu])
        await sampler.setDemand([.cpu, .network])
        // Network was re-added: its first sample must not compute rates across the gap.
        let snapshot = await sampler.sample(
            at: MonotonicInstant(nanoseconds: MonotonicInstant.now.nanoseconds + 4_000_000_000))
        #expect(snapshot.network?.interfaces.allSatisfy { $0.receivedBytesPerSecond == nil } == true)
    }

    @Test func intervalIsClamped() {
        #expect(SamplerConfiguration(interval: 0.01, demand: .all).interval == 0.5)
        #expect(SamplerConfiguration(interval: 60, demand: .all).interval == 10)
    }

    @Test func streamDeliversSequencedSnapshots() async {
        let sampler = Sampler(configuration: .init(interval: 0.5, demand: [.cpu, .memory]))
        var sequences: [UInt64] = []
        for await snapshot in await sampler.snapshots() {
            sequences.append(snapshot.sequence)
            if sequences.count == 3 { break }
        }
        #expect(sequences == [1, 2, 3])
    }

    @Test func sustainedSamplingLeaksNoMachPorts() async {
        let sampler = Sampler()
        var time = MonotonicInstant.now
        _ = await sampler.sample(at: time)
        let before = machPortCount()
        for _ in 0..<3_000 {
            time = MonotonicInstant(nanoseconds: time.nanoseconds + 2_000_000_000)
            _ = await sampler.sample(at: time)
        }
        #expect(machPortCount() == before)
    }

    func machPortCount() -> Int {
        var names: mach_port_name_array_t?
        var namesCount: mach_msg_type_number_t = 0
        var types: mach_port_type_array_t?
        var typesCount: mach_msg_type_number_t = 0
        guard mach_port_names(mach_task_self_, &names, &namesCount, &types, &typesCount) == KERN_SUCCESS else {
            return -1
        }
        if let names {
            vm_deallocate(
                mach_task_self_, vm_address_t(UInt(bitPattern: names)),
                vm_size_t(Int(namesCount) * MemoryLayout<mach_port_name_t>.stride))
        }
        if let types {
            vm_deallocate(
                mach_task_self_, vm_address_t(UInt(bitPattern: types)),
                vm_size_t(Int(typesCount) * MemoryLayout<mach_port_type_t>.stride))
        }
        return Int(namesCount)
    }
}
