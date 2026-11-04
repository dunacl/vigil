// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import Observation
import VigilCore

/// The UI's view of the latest metrics plus a short history for graphs.
///
/// Lives on the main actor and is fed one ``Snapshot`` per tick. History is
/// kept here (not in the sampler) so it's never shared across actors.
@MainActor @Observable
public final class MetricsStore {
    public let system: SystemInfo
    /// Samples kept per series: 150 × 2 s = 5 minutes.
    public let historyLength: Int

    public private(set) var sequence: UInt64 = 0
    /// Measured seconds between samples (for "sustained for N seconds" checks).
    public private(set) var sampleInterval: Double = 2
    private var lastTime: MonotonicInstant?

    public private(set) var cpu: CPUMetrics?
    public private(set) var cpuHistory: RingBuffer<Float>
    /// One series per ``CPUTopology/tiers`` entry.
    public private(set) var tierHistory: [RingBuffer<Float>]

    public private(set) var memory: MemoryMetrics?
    public private(set) var memoryHistory: RingBuffer<Float>

    public private(set) var network: NetworkMetrics?
    /// Rates of the preferred interface, bytes per second.
    public private(set) var receiveHistory: RingBuffer<Float>
    public private(set) var sendHistory: RingBuffer<Float>

    public private(set) var disk: DiskMetrics?

    public private(set) var gpu: GPUMetrics?
    public private(set) var gpuHistory: RingBuffer<Float>
    public private(set) var battery: BatteryMetrics?
    public private(set) var batteryHistory: RingBuffer<Float>
    public private(set) var sensors: SensorMetrics?
    /// Hottest chip sensor, °C.
    public private(set) var chipTemperatureHistory: RingBuffer<Float>
    /// Whole-system power, watts.
    public private(set) var systemPowerHistory: RingBuffer<Float>

    public private(set) var processes: ProcessMetrics?
    /// The process selected in the Dashboard; its CPU and memory are recorded.
    public var focusedProcess: ProcessIdentity? {
        didSet {
            guard focusedProcess != oldValue else { return }
            focusedCPUHistory.removeAll()
            focusedMemoryHistory.removeAll()
        }
    }
    /// CPU of the focused process as a fraction of the whole machine (0…1).
    public private(set) var focusedCPUHistory: RingBuffer<Float>
    /// Memory of the focused process in bytes.
    public private(set) var focusedMemoryHistory: RingBuffer<Float>
    /// Sum over physical disks, bytes per second.
    public private(set) var readHistory: RingBuffer<Float>
    public private(set) var writeHistory: RingBuffer<Float>

    public init(system: SystemInfo, historyLength: Int = 150) {
        self.system = system
        self.historyLength = historyLength
        let empty = RingBuffer<Float>(capacity: historyLength, filler: 0)
        cpuHistory = empty
        tierHistory = Array(repeating: empty, count: system.cpu.tiers.count)
        memoryHistory = empty
        receiveHistory = empty
        sendHistory = empty
        readHistory = empty
        writeHistory = empty
        focusedCPUHistory = empty
        focusedMemoryHistory = empty
        gpuHistory = empty
        batteryHistory = empty
        chipTemperatureHistory = empty
        systemPowerHistory = empty
    }

    /// Applies one tick. Groups absent from the snapshot keep their last value
    /// (their panels are hidden, so nothing needs to redraw).
    public func apply(_ snapshot: Snapshot) {
        sequence = snapshot.sequence
        if let lastTime {
            let elapsed = snapshot.time.seconds(since: lastTime)
            if elapsed > 0.25, elapsed < 20 { sampleInterval = elapsed }
        }
        lastTime = snapshot.time
        if let cpu = snapshot.cpu {
            self.cpu = cpu
            cpuHistory.append(Float(cpu.overall.total))
            for (index, tier) in system.cpu.tiers.enumerated() where index < tierHistory.count {
                tierHistory[index].append(Float(cpu.average(of: tier.cores).total))
            }
        }
        if let memory = snapshot.memory {
            self.memory = memory
            memoryHistory.append(Float(memory.usedFraction))
        }
        if let network = snapshot.network {
            self.network = network
            if let preferred = network.preferred,
                let received = preferred.receivedBytesPerSecond, let sent = preferred.sentBytesPerSecond
            {
                receiveHistory.append(Float(received))
                sendHistory.append(Float(sent))
            }
        }
        if let gpu = snapshot.gpu {
            self.gpu = gpu
            if let utilization = gpu.primary?.utilization { gpuHistory.append(Float(utilization)) }
        }
        if let battery = snapshot.battery {
            self.battery = battery
            batteryHistory.append(Float(battery.charge))
        }
        if let sensors = snapshot.sensors {
            self.sensors = sensors
            if let chip = sensors.chipTemperature { chipTemperatureHistory.append(Float(chip.maximum)) }
            if let power = sensors.systemPower { systemPowerHistory.append(Float(power)) }
        }
        if let processes = snapshot.processes {
            self.processes = processes
            if let focusedProcess, let entry = processes[focusedProcess] {
                let cores = Double(max(system.cpu.logicalCPUCount, 1))
                if let cpu = entry.cpu { focusedCPUHistory.append(Float(cpu / cores)) }
                if let memory = entry.memory { focusedMemoryHistory.append(Float(memory)) }
            }
        }
        if let disk = snapshot.disk {
            self.disk = disk
            if let read = disk.totalReadBytesPerSecond, let written = disk.totalWriteBytesPerSecond {
                readHistory.append(Float(read))
                writeHistory.append(Float(written))
            }
        }
    }
}
