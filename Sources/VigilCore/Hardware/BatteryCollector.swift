// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import Foundation
import IOKit

/// Battery and adapter from the AppleSmartBattery registry entry (public data).
/// Charge, current and voltage are read each tick; health, cycles, temperature
/// and the adapter change slowly and are read every 30 s (SPEC §4.3). On recent
/// Macs the health figures live in the nested `BatteryData` dictionary.
final class BatteryCollector {
    private var entry: io_registry_entry_t = 0
    private var searched = false
    private var slow = BatteryReading(isCharging: false, externalConnected: false, fullyCharged: false)
    private var slowReadAt: MonotonicInstant?
    private let slowInterval = 30.0

    deinit { if entry != 0 { IOObjectRelease(entry) } }

    func reset() { slowReadAt = nil }

    func sample(at time: MonotonicInstant) -> BatteryMetrics? {
        if !searched {
            searched = true
            entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        }
        guard entry != 0 else { return nil }  // a Mac without a battery
        if slowReadAt.map({ time.seconds(since: $0) >= slowInterval }) ?? true {
            readSlow()
            slowReadAt = time
        }
        var reading = slow
        reading.currentCapacity = Registry.int(entry, "CurrentCapacity")
        reading.maxCapacity = Registry.int(entry, "MaxCapacity")
        reading.isCharging = Registry.bool(entry, "IsCharging")
        reading.externalConnected = Registry.bool(entry, "ExternalConnected")
        reading.fullyCharged = Registry.bool(entry, "FullyCharged")
        reading.timeRemaining = Registry.int(entry, "TimeRemaining")
        reading.voltage = Registry.int(entry, "Voltage")
        reading.amperage = Registry.int(entry, "Amperage")
        if reading.currentCapacity == nil {  // the registry entry went stale; find it again
            IOObjectRelease(entry)
            entry = 0
            searched = false
        }
        return reading.metrics
    }

    private func readSlow() {
        let data = Registry.property(entry, "BatteryData") as? [String: Any] ?? [:]
        func int(_ key: String) -> Int? {
            Registry.int(entry, key) ?? (data[key] as? NSNumber)?.intValue
        }
        slow.cycleCount = int("CycleCount")
        slow.rawMaxCapacity = int("AppleRawMaxCapacity")
        slow.designCapacity = int("DesignCapacity")
        slow.temperature = int("Temperature")
        let adapter = Registry.property(entry, "AdapterDetails") as? [String: Any]
        slow.adapterWatts = (adapter?["Watts"] as? NSNumber)?.intValue
        slow.adapterName = adapter?["Name"] as? String
    }
}
