// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import Testing

@testable import VigilCore

let twoSeconds = SampleWindow(
    previous: MonotonicInstant(nanoseconds: 10_000_000_000),
    current: MonotonicInstant(nanoseconds: 12_000_000_000),
    expectedInterval: 2)

@Suite struct NetworkMetricsTests {
    func reading(_ name: String, rx: UInt64, tx: UInt64, index: UInt16 = 4, loopback: Bool = false) -> InterfaceReading
    {
        InterfaceReading(
            index: index, name: name, isUp: true, isLoopback: loopback,
            counters: InterfaceCounters(receivedBytes: rx, sentBytes: tx, receivedPackets: 0, sentPackets: 0))
    }

    @Test func ratesPerSecond() throws {
        let metrics = InterfaceMetrics(
            current: reading("en0", rx: 3_000, tx: 1_400), previous: reading("en0", rx: 1_000, tx: 1_000),
            window: twoSeconds)
        #expect(try #require(metrics.receivedBytesPerSecond) == 1_000)
        #expect(try #require(metrics.sentBytesPerSecond) == 200)
    }

    @Test func interfaceResetGivesNoRate() {
        let metrics = InterfaceMetrics(
            current: reading("en0", rx: 10, tx: 10), previous: reading("en0", rx: 1_000, tx: 1_000),
            window: twoSeconds)
        #expect(metrics.receivedBytesPerSecond == nil)
        #expect(metrics.totals.receivedBytes == 10)
    }

    @Test func preferredUsesPrimaryThenBusiestNonLoopback() {
        let lo = InterfaceMetrics(
            current: reading("lo0", rx: 9_999_999, tx: 0, loopback: true), previous: nil, window: nil)
        let en0 = InterfaceMetrics(current: reading("en0", rx: 500, tx: 0), previous: nil, window: nil)
        let en1 = InterfaceMetrics(current: reading("en1", rx: 900, tx: 0), previous: nil, window: nil)
        #expect(NetworkMetrics(interfaces: [lo, en0, en1], primaryInterface: "en0").preferred?.name == "en0")
        #expect(NetworkMetrics(interfaces: [lo, en0, en1], primaryInterface: nil).preferred?.name == "en1")
        #expect(NetworkMetrics(interfaces: [lo, en0, en1], primaryInterface: "utun9").preferred?.name == "en1")
    }
}

@Suite struct DiskMetricsTests {
    func reading(id: UInt64 = 1, read: UInt64, written: UInt64, ops: UInt64 = 0) -> DiskReading {
        DiskReading(
            registryID: id, bsdName: "disk0", name: "SSD",
            counters: DiskCounters(bytesRead: read, bytesWritten: written, reads: ops, writes: ops))
    }

    @Test func throughputAndIOPS() throws {
        let metrics = DiskIOMetrics(
            current: reading(read: 4_096, written: 8_192, ops: 10), previous: reading(read: 0, written: 0, ops: 0),
            window: twoSeconds)
        #expect(try #require(metrics.readBytesPerSecond) == 2_048)
        #expect(try #require(metrics.writeBytesPerSecond) == 4_096)
        #expect(try #require(metrics.readsPerSecond) == 5)
    }

    @Test func replacedDeviceWithSameBSDNameGivesNoRate() {
        // A different disk re-using "disk0" must never produce a delta against the old one.
        let metrics = DiskIOMetrics(
            current: reading(id: 2, read: 10, written: 10), previous: reading(id: 1, read: 0, written: 0),
            window: twoSeconds)
        #expect(metrics.readBytesPerSecond == nil)
    }

    @Test func totalsSumOnlyDisksWithRates() {
        let a = DiskIOMetrics(
            current: reading(read: 2_000, written: 0), previous: reading(read: 0, written: 0), window: twoSeconds)
        let b = DiskIOMetrics(current: reading(read: 5, written: 5), previous: nil, window: nil)
        #expect(DiskMetrics(disks: [a, b], volumes: []).totalReadBytesPerSecond == 1_000)
        #expect(DiskMetrics(disks: [b], volumes: []).totalReadBytesPerSecond == nil)
    }

    @Test func volumeUsage() {
        let volume = VolumeInfo(
            mountPoint: "/", device: "/dev/disk3s1s1", fileSystem: "apfs", totalBytes: 1_000,
            availableBytes: 250, isLocal: true, isReadOnly: true)
        #expect(volume.usedBytes == 750)
        #expect(volume.usedFraction == 0.75)
    }
}
