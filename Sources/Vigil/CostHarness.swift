// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import AppKit
import Darwin
import VigilCore

/// Panel cost harness (SPEC §2.1, §6). Shows N Medium CPU panels at floating
/// level (so they're guaranteed visible), waits for warm-up, measures, prints
/// one JSON line and quits. Used by `scripts/panel-cost.sh`.
@MainActor
enum CostHarness {
    /// `material` is glass, solid, none, or clearGlass (glass at 0.65 transparency).
    static func layout(panels: Int, material: String) -> LayoutProfile {
        var appearance = AppearanceOverrides()
        switch material {
        case "solid": appearance.material = .solid
        case "none": appearance.material = PanelMaterial.none
        case "clearGlass": appearance.transparency = 0.65
        default: break
        }
        return LayoutProfile(
            name: "Cost harness",
            panels: (0..<panels).map { index in
                PanelInstance(
                    id: "measure-\(index)", kind: .cpu, sizeClass: .medium, placement: placement(index),
                    level: .floating, appearance: appearance)
            })
    }

    private static func placement(_ index: Int) -> Placement {
        let size = SizeClass.medium.size
        let gap = 12.0, margin = 24.0, columns = 3
        let x = margin + Double(index % columns) * (size.width + gap)
        let y = margin + Double(index / columns) * (size.height + gap)
        return Placement(display: .main, anchor: .bottomLeading, offset: Point(x: x, y: y), size: size)
    }

    static func run(options: LaunchOptions) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(options.measureWarmup))
            let start = Measurement.now()
            try? await Task.sleep(for: .seconds(options.measureSeconds))
            let end = Measurement.now()
            let cpuPercent = (end.cpuSeconds - start.cpuSeconds) / (end.wallSeconds - start.wallSeconds) * 100
            print(
                #"{"panels":\#(options.measurePanels),"material":"\#(options.measureMaterial)","#
                    + #""static":\#(options.measureStatic),"#
                    + #""seconds":\#(Units.number(end.wallSeconds - start.wallSeconds, decimals: 1)),"#
                    + #""cpuPercent":\#(Units.number(cpuPercent, decimals: 4)),"#
                    + #""footprintMiB":\#(Units.number(Double(end.footprint) / 1_048_576, decimals: 2))}"#)
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }

    struct Measurement {
        var wallSeconds: Double
        var cpuSeconds: Double
        var footprint: UInt64

        static func now() -> Measurement {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let seconds = { (t: timeval) in Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return Measurement(
                wallSeconds: MonotonicInstant.now.seconds(since: MonotonicInstant(nanoseconds: 0)),
                cpuSeconds: seconds(usage.ru_utime) + seconds(usage.ru_stime),
                footprint: result == KERN_SUCCESS ? info.phys_footprint : 0)
        }
    }
}
