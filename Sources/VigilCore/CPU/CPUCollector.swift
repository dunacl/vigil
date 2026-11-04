// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import Darwin

/// Reads per-core CPU ticks with `host_processor_info`.
///
/// Owns two reusable tick buffers and swaps them each sample, so steady-state
/// sampling does not allocate for the raw readings.
final class CPUCollector {
    /// Cached once: every `mach_host_self()` call adds a send right that would
    /// otherwise have to be released.
    private let host = mach_host_self()
    private var previous: [CPUTicks] = []
    private var current: [CPUTicks] = []
    private var previousTime: MonotonicInstant?

    /// Forgets the previous reading (after wake, or on demand change).
    func reset() { previousTime = nil }

    /// Takes a reading and returns metrics relative to the previous one.
    /// The first call after ``reset()`` establishes a baseline and returns `nil`.
    func sample(at time: MonotonicInstant, expectedInterval: Double) -> CPUMetrics? {
        guard Self.read(host: host, into: &current) else {
            reset()
            return nil
        }
        let lastTime = previousTime
        defer {
            swap(&previous, &current)
            previousTime = time
        }
        guard let lastTime,
            SampleWindow(previous: lastTime, current: time, expectedInterval: expectedInterval).isValid
        else { return nil }
        return CPUMetrics.make(previous: previous, current: current, loadAverage: Self.loadAverage())
    }

    /// Fills `ticks` with one entry per logical CPU. Returns `false` on failure.
    static func read(host: host_t, into ticks: inout [CPUTicks]) -> Bool {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return false }
        defer {
            // The kernel allocates this array in our address space on every call.
            let size = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), size)
        }
        let count = Int(cpuCount)
        let stride = Int(CPU_STATE_MAX)
        guard count > 0, Int(infoCount) >= count * stride else { return false }
        if ticks.count != count {
            ticks = [CPUTicks](repeating: .zero, count: count)
        }
        ticks.withUnsafeMutableBufferPointer { buffer in
            for core in 0..<count {
                let base = core * stride
                buffer[core] = CPUTicks(
                    user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                    system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                    idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                    nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
                )
            }
        }
        return true
    }

    static func loadAverage() -> LoadAverage {
        var values: (Double, Double, Double) = (0, 0, 0)
        let read = withUnsafeMutablePointer(to: &values) { tuple in
            tuple.withMemoryRebound(to: Double.self, capacity: 3) { getloadavg($0, 3) }
        }
        return read == 3 ? LoadAverage(one: values.0, five: values.1, fifteen: values.2) : .zero
    }
}
