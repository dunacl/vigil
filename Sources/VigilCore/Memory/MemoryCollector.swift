// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import Darwin

/// Reads system memory statistics. All values are gauges or cumulative
/// counters; nothing here allocates per sample.
final class MemoryCollector {
    private let host: host_t
    private let pageSize: UInt64
    private let totalBytes: UInt64
    private var swapMIB = Sysctl.MIB("vm.swapusage")
    private var pressureMIB = Sysctl.MIB("kern.memorystatus_vm_pressure_level")
    private var previous: MemoryReading?
    private var previousTime: MonotonicInstant?

    init() {
        host = mach_host_self()
        var size: vm_size_t = 0
        pageSize = host_page_size(host, &size) == KERN_SUCCESS ? UInt64(size) : 16_384
        totalBytes = UInt64(Sysctl.integer("hw.memsize") ?? 0)
    }

    func reset() {
        previous = nil
        previousTime = nil
    }

    func sample(at time: MonotonicInstant, expectedInterval: Double) -> MemoryMetrics? {
        guard let reading = read() else {
            reset()
            return nil
        }
        let window = previousTime.map {
            SampleWindow(previous: $0, current: time, expectedInterval: expectedInterval)
        }
        let metrics = MemoryMetrics(reading: reading, previous: previous, window: window)
        previous = reading
        previousTime = time
        return metrics
    }

    func read() -> MemoryReading? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var swap = xsw_usage()
        let hasSwap = swapMIB?.read(into: &swap) ?? false
        let pressureLevel = pressureMIB?.integer().flatMap { MemoryPressure(rawValue: Int($0)) } ?? .unknown

        return MemoryReading(
            pageSize: pageSize,
            totalBytes: totalBytes,
            freePages: UInt64(stats.free_count),
            speculativePages: UInt64(stats.speculative_count),
            wiredPages: UInt64(stats.wire_count),
            internalPages: UInt64(stats.internal_page_count),
            externalPages: UInt64(stats.external_page_count),
            purgeablePages: UInt64(stats.purgeable_count),
            compressorPages: UInt64(stats.compressor_page_count),
            pageIns: stats.pageins,
            pageOuts: stats.pageouts,
            swapIns: stats.swapins,
            swapOuts: stats.swapouts,
            swapTotalBytes: hasSwap ? swap.xsu_total : 0,
            swapUsedBytes: hasSwap ? swap.xsu_used : 0,
            pressure: pressureLevel
        )
    }
}
