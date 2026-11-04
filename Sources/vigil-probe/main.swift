// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.
//
// vigil-probe: prints live VigilCore readings, or benchmarks the sampling path.
//
//   vigil-probe                  live readout every 2 s (Ctrl-C to stop)
//   vigil-probe -i 1 -n 5        5 samples, 1 s apart
//   vigil-probe --bench 1000     time 1000 back-to-back samples

import Darwin
import VigilCore

struct Options {
    var interval = SamplerConfiguration.default.interval
    var count: Int?
    var bench: Int?
    var all = false
    var demand: Demand = .all
    var privateSensors = false

    static let usage = """
        usage: vigil-probe [-i seconds] [-n count] [--only groups] [--all] [--bench samples]
          -i, --interval   seconds between samples (0.5–10, default 2)
          -n, --count      stop after this many samples
              --only       comma-separated groups: cpu,memory,network,disk,volumes,processes,threads,
                           gpu,battery,sensors
              --private-sensors   also read temperatures, fans and power (undocumented interfaces)
              --all        list every network interface and disk, not just active ones
              --bench      time N back-to-back samples and report p50/p95/max and footprint
        """

    static func parse(_ arguments: [String]) -> Options? {
        var options = Options()
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "-i", "--interval":
                guard let value = iterator.next().flatMap(Double.init) else { return nil }
                options.interval = value
            case "-n", "--count":
                guard let value = iterator.next().flatMap(Int.init), value > 0 else { return nil }
                options.count = value
            case "--bench":
                guard let value = iterator.next().flatMap(Int.init), value > 1 else { return nil }
                options.bench = value
            case "--only":
                guard let value = iterator.next() else { return nil }
                var demand: Demand = []
                for name in value.split(separator: ",") {
                    switch name {
                    case "cpu": demand.insert(.cpu)
                    case "memory": demand.insert(.memory)
                    case "network": demand.insert(.network)
                    case "disk": demand.insert(.diskIO)
                    case "volumes": demand.insert(.volumes)
                    case "processes": demand.insert(.processes)
                    case "threads": demand.insert([.processes, .processDetails])
                    case "gpu": demand.insert(.gpu)
                    case "battery": demand.insert(.battery)
                    case "sensors": demand.insert(.sensors)
                    default: return nil
                    }
                }
                options.demand = demand
            case "--private-sensors":
                options.privateSensors = true
            case "--all":
                options.all = true
            default:
                return nil
            }
        }
        return options
    }
}

guard let options = Options.parse(Array(CommandLine.arguments.dropFirst())) else {
    print(Options.usage)
    exit(64)
}

let sampler = Sampler(configuration: SamplerConfiguration(interval: options.interval, demand: options.demand))
await sampler.setPrivateSensorsEnabled(options.privateSensors)
if let samples = options.bench {
    await Bench.run(sampler: sampler, samples: samples)
} else {
    printHeader(sampler.system)
    var printed = 0
    for await snapshot in await sampler.snapshots() {
        // The first snapshot only establishes baselines for rates.
        guard snapshot.sequence > 1 else { continue }
        Report.print(snapshot, system: sampler.system, all: options.all)
        printed += 1
        if let count = options.count, printed >= count { break }
    }
}

func printHeader(_ system: SystemInfo) {
    let tiers = system.cpu.tiers.map { "\($0.cores.count) \($0.name)" }.joined(separator: " + ")
    print("\(system.cpu.brand) (\(tiers)) · \(Units.bytes(Double(system.memoryBytes))) · macOS \(system.osVersion)")
    print("\(system.model) · \(system.hostName) · up \(Units.duration(system.uptime))")
}

enum Report {
    static func print(_ snapshot: Snapshot, system: SystemInfo, all: Bool) {
        var lines = [
            "", "── #\(snapshot.sequence)  sampled in \(Units.number(snapshot.sampleDuration * 1000, decimals: 2)) ms",
        ]

        if let cpu = snapshot.cpu {
            let load = cpu.loadAverage
            lines.append(
                "CPU   \(pct(cpu.overall.total))  usr \(pct(cpu.overall.user)) sys \(pct(cpu.overall.system))"
                    + "  load \(Units.number(load.one, decimals: 2)) \(Units.number(load.five, decimals: 2)) \(Units.number(load.fifteen, decimals: 2))"
            )
            for tier in system.cpu.tiers {
                let cores = tier.cores.map { bar(cpu.cores[$0].total) }.joined()
                lines.append("      \(pad(tier.name, 12)) \(pct(cpu.average(of: tier.cores).total))  \(cores)")
            }
        }

        if let memory = snapshot.memory {
            let b = { (value: UInt64) in Units.bytes(Double(value)) }
            lines.append(
                "MEM   \(b(memory.usedBytes)) / \(b(memory.totalBytes)) (\(pct(memory.usedFraction)))"
                    + "  app \(b(memory.appBytes))  wired \(b(memory.wiredBytes))"
                    + "  compressed \(b(memory.compressedBytes))")
            lines.append(
                "      cached \(b(memory.cachedBytes))  free \(b(memory.freeBytes))  pressure \(memory.pressure)"
                    + "  swap \(b(memory.swapUsedBytes)) / \(b(memory.swapTotalBytes))"
                    + "  pageins \(rate(memory.pageInsPerSecond, unit: "/s"))")
        }

        if let network = snapshot.network {
            let shown = network.interfaces.filter {
                all || $0.name == network.primaryInterface
                    || ($0.receivedBytesPerSecond ?? 0) + ($0.sentBytesPerSecond ?? 0) > 0 && !$0.isLoopback
            }
            for (index, interface) in shown.enumerated() {
                let label = index == 0 ? "NET" : ""
                let primary = interface.name == network.primaryInterface ? "*" : " "
                lines.append(
                    "\(pad(label, 6))\(pad(interface.name + primary, 9))"
                        + "↓ \(pad(rate(interface.receivedBytesPerSecond), 12)) ↑ \(pad(rate(interface.sentBytesPerSecond), 12))"
                        + "  total ↓ \(Units.bytes(Double(interface.totals.receivedBytes)))"
                        + " ↑ \(Units.bytes(Double(interface.totals.sentBytes)))")
            }
        }

        if let disk = snapshot.disk {
            for (index, device) in disk.disks.enumerated() {
                lines.append(
                    "\(pad(index == 0 ? "DISK" : "", 6))\(pad(device.bsdName, 8))"
                        + "R \(pad(rate(device.readBytesPerSecond), 12)) W \(pad(rate(device.writeBytesPerSecond), 12))"
                        + "  \(device.name)")
            }
            for (index, volume) in disk.volumes.enumerated() where all || volume.isLocal {
                lines.append(
                    "\(pad(index == 0 ? "VOL" : "", 6))\(pad(volume.mountPoint, 24))"
                        + "\(Units.bytes(Double(volume.usedBytes), style: .decimal)) / "
                        + "\(Units.bytes(Double(volume.totalBytes), style: .decimal))"
                        + " (\(pct(volume.usedFraction)))  \(volume.fileSystem)")
            }
        }
        if let gpu = snapshot.gpu?.primary {
            lines.append(
                "GPU   \(gpu.name)\(gpu.cores.map { " · \($0) cores" } ?? "")  \(pct(gpu.utilization ?? 0))"
                    + "  renderer \(pct(gpu.rendererUtilization ?? 0))  tiler \(pct(gpu.tilerUtilization ?? 0))"
                    + "  memory \(Units.bytes(Double(gpu.memoryInUse ?? 0)))")
        }
        if let battery = snapshot.battery {
            let state = battery.isCharging ? "charging" : battery.isPluggedIn ? "plugged in" : "on battery"
            lines.append(
                "BATT  \(pct(battery.charge)) \(state)"
                    + "  health \(battery.health.map { Units.percent($0, decimals: 0) } ?? "—")"
                    + "  cycles \(battery.cycleCount.map(String.init) ?? "—")"
                    + "  power \(battery.batteryPower.map { Units.number(abs($0), decimals: 1) + " W" } ?? "—")"
                    + "  \(battery.temperature.map { Units.number($0, decimals: 1) + " °C" } ?? "")"
                    + "  adapter \(battery.adapterWatts.map { "\($0) W" } ?? "—")")
        }
        if let sensors = snapshot.sensors {
            var parts = ["thermal \(sensors.thermal)"]
            if let chip = sensors.chipTemperature {
                parts.append(
                    "chip \(Units.number(chip.maximum, decimals: 1)) °C max, \(Units.number(chip.average, decimals: 1)) avg"
                )
            }
            if let ssd = sensors.ssdTemperature { parts.append("SSD \(Units.number(ssd, decimals: 1)) °C") }
            if let fans = sensors.fans {
                parts.append("fans " + fans.map { "\(Int($0.rpm)) rpm" }.joined(separator: ", "))
            }
            if let power = sensors.systemPower { parts.append("system \(Units.number(power, decimals: 1)) W") }
            if let power = sensors.powerIn { parts.append("in \(Units.number(power, decimals: 1)) W") }
            lines.append("SENS  " + parts.joined(separator: "  "))
        }
        if let processes = snapshot.processes {
            let top = processes.top(5, by: .cpu)
            lines.append(
                "PROC  \(processes.processes.count) processes, \(processes.restrictedCount) restricted (other users')")
            for entry in top {
                lines.append(
                    "      \(pad(String(entry.pid), 7))\(pad(entry.name, 28))\(pct(entry.cpu ?? 0))"
                        + "  \(Units.bytes(Double(entry.memory ?? 0)))  \(entry.user)")
            }
        }
        Swift.print(lines.joined(separator: "\n"))
    }

    static func pct(_ fraction: Double) -> String { pad(Units.percent(fraction), 6, left: true) }

    static func rate(_ value: Double?, unit: String? = nil) -> String {
        guard let value else { return "—" }
        if let unit { return Units.number(value, decimals: 1) + unit }
        return Units.rate(bytesPerSecond: value)
    }

    /// One-character vertical bar, btop style.
    static func bar(_ fraction: Double) -> String {
        let levels: [Character] = [" ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
        let index = Int((min(max(fraction, 0), 1) * Double(levels.count - 1)).rounded())
        return String(levels[index])
    }

    static func pad(_ text: String, _ width: Int, left: Bool = false) -> String {
        let padding = String(repeating: " ", count: max(0, width - text.count))
        return left ? padding + text : text + padding
    }
}

enum Bench {
    static func run(sampler: Sampler, samples: Int) async {
        // Synthetic timestamps one interval apart, so every sample runs the full
        // delta/rate path (real back-to-back samples are too close for rates).
        let step = UInt64(await sampler.configuration.interval * 1_000_000_000)
        var time = MonotonicInstant.now
        func nextTime() -> MonotonicInstant {
            time = MonotonicInstant(nanoseconds: time.nanoseconds + step)
            return time
        }
        _ = await sampler.sample(at: nextTime())  // warm caches and baselines
        // Touch the results buffer up front so its pages don't count as growth.
        var durations = [Double](repeating: 0, count: samples)
        let footprintBefore = footprint()
        let portsBefore = machPortCount()
        let cpuBefore = processCPUSeconds()
        for index in 0..<samples {
            durations[index] = await sampler.sample(at: nextTime()).sampleDuration
        }
        let cpuSeconds = processCPUSeconds() - cpuBefore
        let footprintAfter = footprint()
        let portsAfter = machPortCount()
        durations.sort()
        let ms = { (value: Double) in Units.number(value * 1000, decimals: 3) + " ms" }
        let p = { (q: Double) in durations[min(durations.count - 1, Int(Double(durations.count) * q))] }
        print("samples        \(samples)")
        print("tick p50       \(ms(p(0.50)))")
        print("tick p95       \(ms(p(0.95)))   budget ≤ 2 ms")
        print("tick max       \(ms(durations.last ?? 0))")
        print("cpu/tick       \(ms(cpuSeconds / Double(samples)))  (user+system)")
        print(
            "est. CPU @2s   \(Units.number(cpuSeconds / Double(samples) / 2 * 100, decimals: 3))% of one core (sampling only)"
        )
        print(
            "footprint      \(Units.bytes(Double(footprintAfter))) "
                + "(Δ \(Units.number((Double(footprintAfter) - Double(footprintBefore)) / 1024, decimals: 1)) KiB over run)"
        )
        print("mach ports     \(portsAfter) (Δ \(portsAfter - portsBefore) over run)")
    }

    /// Number of Mach port names in this task; growth means a leaked right.
    static func machPortCount() -> Int {
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

    /// Physical footprint, the number Activity Monitor shows as "Memory".
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let seconds = { (t: timeval) in Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
