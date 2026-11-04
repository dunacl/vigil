// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import Testing

@testable import VigilCore

@Suite struct MemoryMetricsTests {
    static let page: UInt64 = 16_384

    static func reading(pageIns: UInt64 = 1_000, swapOuts: UInt64 = 0, purgeable: UInt64 = 100) -> MemoryReading {
        MemoryReading(
            pageSize: page, totalBytes: 16 * page * 1_000,
            freePages: 2_000, speculativePages: 500, wiredPages: 1_500,
            internalPages: 6_000, externalPages: 3_000, purgeablePages: purgeable,
            compressorPages: 700, pageIns: pageIns, pageOuts: 10, swapIns: 0, swapOuts: swapOuts,
            swapTotalBytes: 1 << 30, swapUsedBytes: 1 << 20, pressure: .normal)
    }

    @Test func activityMonitorDefinitions() {
        let metrics = MemoryMetrics(reading: Self.reading(), previous: nil, window: nil)
        let page = Self.page
        #expect(metrics.appBytes == (6_000 - 100) * page)
        #expect(metrics.wiredBytes == 1_500 * page)
        #expect(metrics.compressedBytes == 700 * page)
        #expect(metrics.usedBytes == (5_900 + 1_500 + 700) * page)
        #expect(metrics.cachedBytes == (3_000 + 100) * page)
        #expect(metrics.freeBytes == (2_000 - 500) * page)
        #expect(metrics.pressure == .normal)
    }

    @Test func firstSampleHasNoRates() {
        let metrics = MemoryMetrics(reading: Self.reading(), previous: nil, window: nil)
        #expect(metrics.pageInsPerSecond == nil)
    }

    @Test func ratesOverTheWindow() throws {
        let start = MonotonicInstant(nanoseconds: 1_000_000_000)
        let window = SampleWindow(
            previous: start, current: MonotonicInstant(nanoseconds: 3_000_000_000), expectedInterval: 2)
        let metrics = MemoryMetrics(
            reading: Self.reading(pageIns: 1_400, swapOuts: 20), previous: Self.reading(), window: window)
        #expect(try #require(metrics.pageInsPerSecond) == 200)
        #expect(try #require(metrics.swapOutsPerSecond) == 10)
    }

    @Test func counterResetGivesNoRate() {
        let start = MonotonicInstant(nanoseconds: 1_000_000_000)
        let window = SampleWindow(
            previous: start, current: MonotonicInstant(nanoseconds: 3_000_000_000), expectedInterval: 2)
        let metrics = MemoryMetrics(reading: Self.reading(pageIns: 5), previous: Self.reading(), window: window)
        #expect(metrics.pageInsPerSecond == nil)
    }

    @Test func purgeableLargerThanInternalNeverUnderflows() {
        let metrics = MemoryMetrics(reading: Self.reading(purgeable: 9_999), previous: nil, window: nil)
        #expect(metrics.appBytes == 0)
    }

    @Test func usedFractionIsClamped() {
        var reading = Self.reading()
        reading.totalBytes = 1
        #expect(MemoryMetrics(reading: reading, previous: nil, window: nil).usedFraction == 1)
    }
}
