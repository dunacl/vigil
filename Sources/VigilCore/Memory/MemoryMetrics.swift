// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

/// Raw VM counters for one reading (from `vm_statistics64`, `vm.swapusage` and
/// `kern.memorystatus_vm_pressure_level`).
public struct MemoryReading: Sendable, Equatable {
    public var pageSize: UInt64
    public var totalBytes: UInt64

    // Page counts (gauges).
    public var freePages: UInt64
    public var speculativePages: UInt64
    public var wiredPages: UInt64
    public var internalPages: UInt64
    public var externalPages: UInt64
    public var purgeablePages: UInt64
    public var compressorPages: UInt64

    // Cumulative event counters.
    public var pageIns: UInt64
    public var pageOuts: UInt64
    public var swapIns: UInt64
    public var swapOuts: UInt64

    public var swapTotalBytes: UInt64
    public var swapUsedBytes: UInt64
    public var pressure: MemoryPressure

    public init(
        pageSize: UInt64, totalBytes: UInt64, freePages: UInt64, speculativePages: UInt64,
        wiredPages: UInt64, internalPages: UInt64, externalPages: UInt64, purgeablePages: UInt64,
        compressorPages: UInt64, pageIns: UInt64, pageOuts: UInt64, swapIns: UInt64, swapOuts: UInt64,
        swapTotalBytes: UInt64, swapUsedBytes: UInt64, pressure: MemoryPressure
    ) {
        self.pageSize = pageSize
        self.totalBytes = totalBytes
        self.freePages = freePages
        self.speculativePages = speculativePages
        self.wiredPages = wiredPages
        self.internalPages = internalPages
        self.externalPages = externalPages
        self.purgeablePages = purgeablePages
        self.compressorPages = compressorPages
        self.pageIns = pageIns
        self.pageOuts = pageOuts
        self.swapIns = swapIns
        self.swapOuts = swapOuts
        self.swapTotalBytes = swapTotalBytes
        self.swapUsedBytes = swapUsedBytes
        self.pressure = pressure
    }
}

/// The kernel's memory pressure level, as shown in Activity Monitor's graph colors.
public enum MemoryPressure: Int, Sendable, Codable {
    case normal = 1
    case warning = 2
    case critical = 4
    case unknown = 0
}

/// Memory metrics using Activity Monitor's definitions, so numbers match what
/// users already know:
///
/// - **App** = anonymous (internal) pages − purgeable
/// - **Wired** = wired pages
/// - **Compressed** = pages held by the compressor
/// - **Used** = App + Wired + Compressed
/// - **Cached files** = file-backed (external) pages + purgeable
/// - **Free** = free pages − speculative
public struct MemoryMetrics: Sendable, Equatable {
    public var totalBytes: UInt64
    public var appBytes: UInt64
    public var wiredBytes: UInt64
    public var compressedBytes: UInt64
    public var cachedBytes: UInt64
    public var freeBytes: UInt64
    public var swapTotalBytes: UInt64
    public var swapUsedBytes: UInt64
    public var pressure: MemoryPressure

    /// Per-second rates over the sample interval; `nil` on the first sample, after
    /// a gap, or when a counter reset.
    public var pageInsPerSecond: Double?
    public var pageOutsPerSecond: Double?
    public var swapInsPerSecond: Double?
    public var swapOutsPerSecond: Double?

    public var usedBytes: UInt64 { appBytes + wiredBytes + compressedBytes }

    /// Used / total in 0...1.
    public var usedFraction: Double {
        totalBytes > 0 ? min(1, Double(usedBytes) / Double(totalBytes)) : 0
    }

    public init(reading: MemoryReading, previous: MemoryReading?, window: SampleWindow?) {
        let page = reading.pageSize
        totalBytes = reading.totalBytes
        appBytes = reading.internalPages.subtractingClamped(reading.purgeablePages) * page
        wiredBytes = reading.wiredPages * page
        compressedBytes = reading.compressorPages * page
        cachedBytes = (reading.externalPages + reading.purgeablePages) * page
        freeBytes = reading.freePages.subtractingClamped(reading.speculativePages) * page
        swapTotalBytes = reading.swapTotalBytes
        swapUsedBytes = reading.swapUsedBytes
        pressure = reading.pressure

        guard let previous, let window, window.isValid else { return }
        func rate(_ keyPath: KeyPath<MemoryReading, UInt64>) -> Double? {
            Counter.delta(previous[keyPath: keyPath], reading[keyPath: keyPath]).map {
                Double($0) / window.elapsed
            }
        }
        pageInsPerSecond = rate(\.pageIns)
        pageOutsPerSecond = rate(\.pageOuts)
        swapInsPerSecond = rate(\.swapIns)
        swapOutsPerSecond = rate(\.swapOuts)
    }
}

extension UInt64 {
    @inline(__always)
    func subtractingClamped(_ other: UInt64) -> UInt64 { self > other ? self - other : 0 }
}
