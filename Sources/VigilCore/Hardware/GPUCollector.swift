// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import Foundation
import IOKit

/// GPU utilization and memory from each IOAccelerator's `PerformanceStatistics`
/// (public registry data). Devices are found once; per tick only the statistics
/// dictionary is read, without bridging it to Swift.
final class GPUCollector {
    private struct Device {
        let entry: io_registry_entry_t
        let name: String
        let cores: Int?
    }

    private var devices: [Device] = []
    private var discovered = false
    private let statisticsKey = "PerformanceStatistics" as CFString
    private let deviceKey = "Device Utilization %" as CFString
    private let rendererKey = "Renderer Utilization %" as CFString
    private let tilerKey = "Tiler Utilization %" as CFString
    private let memoryKey = "In use system memory" as CFString

    deinit { release() }

    func sample() -> GPUMetrics? {
        if !discovered { discover() }
        guard !devices.isEmpty else { return nil }
        var result: [GPUDevice] = []
        for device in devices {
            guard
                let property = IORegistryEntryCreateCFProperty(device.entry, statisticsKey, kCFAllocatorDefault, 0)?
                    .takeRetainedValue(), CFGetTypeID(property) == CFDictionaryGetTypeID()
            else {
                discovered = false  // the device went away; look again next tick
                continue
            }
            let statistics = unsafeDowncast(property, to: CFDictionary.self)
            result.append(
                GPUDevice(
                    name: device.name, cores: device.cores,
                    utilization: Registry.number(statistics, deviceKey).map { $0 / 100 },
                    rendererUtilization: Registry.number(statistics, rendererKey).map { $0 / 100 },
                    tilerUtilization: Registry.number(statistics, tilerKey).map { $0 / 100 },
                    memoryInUse: Registry.number(statistics, memoryKey).flatMap {
                        $0.isFinite && $0 >= 0 && $0 < 1e18 ? UInt64($0) : nil
                    }))
        }
        return result.isEmpty ? nil : GPUMetrics(devices: result)
    }

    private func discover() {
        release()
        discovered = true
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator)
                == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            let name =
                Registry.string(entry, "model") ?? Registry.string(entry, "IOClass") ?? "GPU"
            let cores = Registry.int(entry, "gpu-core-count")
            devices.append(Device(entry: entry, name: name, cores: cores))
        }
    }

    private func release() {
        for device in devices { IOObjectRelease(device.entry) }
        devices.removeAll()
    }
}

/// Small IORegistry readers shared by the hardware collectors.
enum Registry {
    static func property(_ entry: io_registry_entry_t, _ key: String) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func string(_ entry: io_registry_entry_t, _ key: String) -> String? {
        guard let value = property(entry, key) else { return nil }
        if let string = value as? String { return string }
        // Device-tree strings are NUL-terminated data.
        if let data = value as? Data { return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self) }
        return nil
    }

    static func int(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        (property(entry, key) as? NSNumber)?.intValue
    }

    static func bool(_ entry: io_registry_entry_t, _ key: String) -> Bool {
        (property(entry, key) as? NSNumber)?.boolValue ?? false
    }

    /// A number from a CF dictionary, without bridging the dictionary.
    static func number(_ dictionary: CFDictionary, _ key: CFString) -> Double? {
        guard let raw = CFDictionaryGetValue(dictionary, Unmanaged.passUnretained(key).toOpaque()) else { return nil }
        let value = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
        guard CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        var result: Double = 0
        CFNumberGetValue(unsafeDowncast(value, to: CFNumber.self), .doubleType, &result)
        return result
    }
}
