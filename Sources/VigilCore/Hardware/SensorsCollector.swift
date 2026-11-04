// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import CVigilSys
import Darwin
import Foundation
import IOKit
import os

/// Thermal state (public, always) plus, when ``privateSensorsEnabled``,
/// temperatures (HID event system), fans and power (SMC). Both are undocumented
/// (SPEC §11): resolved at runtime, each switched off for the session on its
/// first failure, and never affecting other panels.
final class SensorsCollector {
    var privateSensorsEnabled = false {
        didSet {
            guard !privateSensorsEnabled else { return }
            smc = nil
            temperatures = nil
            temperaturesRequestedAt = nil
        }
    }
    private var smc: SMCReader?
    /// Temperatures change slowly and each of the ~16 sensor reads is an IPC
    /// round trip (~12 ms together), so they're read on a background queue every
    /// 10 s; ticks take the latest values without waiting (SPEC §6 tick budget).
    private var temperatures: BackgroundTemperatures?
    private var temperaturesRequestedAt: MonotonicInstant?
    private var hidFailed = false
    private var smcFailed = false

    func sample(at time: MonotonicInstant = .now) -> SensorMetrics {
        var metrics = SensorMetrics(thermal: Self.thermalLevel())
        guard privateSensorsEnabled else { return metrics }

        if temperatures == nil, !hidFailed {
            temperatures = BackgroundTemperatures()
            hidFailed = temperatures == nil
        }
        if let temperatures {
            if temperaturesRequestedAt.map({ time.seconds(since: $0) >= 10 }) ?? true {
                temperatures.refresh()
                temperaturesRequestedAt = time
            }
            let latest = temperatures.latest
            metrics.chipTemperature = latest?.chip
            metrics.batteryTemperature = latest?.battery
            metrics.ssdTemperature = latest?.ssd
        }

        if smc == nil, !smcFailed { smc = SMCReader(); smcFailed = smc == nil }
        if let smc {
            metrics.fans = smc.fans()
            metrics.systemPower = SensorRange.watts(smc.read("PSTR"))
            metrics.powerIn = SensorRange.watts(smc.read("PDTR"))
        }
        return metrics
    }

    private static func thermalLevel() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }
}

/// Owns the HID client on its own serial queue and publishes the latest
/// aggregated temperatures through a lock (never blocks the sampler).
private final class BackgroundTemperatures: @unchecked Sendable {
    typealias Aggregate = (chip: (maximum: Double, average: Double)?, battery: Double?, ssd: Double?)

    private let queue = DispatchQueue(label: "app.vigil.core.temperatures", qos: .utility)
    private let hid: HIDTemperatures
    private let lock = OSAllocatedUnfairLock<Aggregate?>(initialState: nil)
    private let busy = OSAllocatedUnfairLock(initialState: false)

    init?() {
        guard let hid = HIDTemperatures() else { return nil }
        self.hid = hid
    }

    var latest: Aggregate? { lock.withLock { $0 } }

    /// Starts a read unless one is still running.
    func refresh() {
        guard
            busy.withLock({ running in
                if running { return false }
                running = true
                return true
            })
        else { return }
        queue.async { [self] in
            let aggregate = hid.read().map(TemperatureSensors.aggregate)
            lock.withLock { $0 = aggregate }
            busy.withLock { $0 = false }
        }
    }
}

/// Temperature sensors through the private IOHIDEventSystemClient API. Used
/// only from ``BackgroundTemperatures``'s queue.
private final class HIDTemperatures {
    private let client: CFTypeRef
    private let copyServices: VigilHIDClientCopyServicesFn
    private let copyProperty: VigilHIDServiceCopyPropertyFn
    private let copyEvent: VigilHIDServiceCopyEventFn
    private let floatValue: VigilHIDEventGetFloatValueFn
    private var services: [(service: CFTypeRef, name: String)] = []
    private var servicesReadAt = Date.distantPast

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
            let create = dlsym(handle, "IOHIDEventSystemClientCreate"),
            let setMatching = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
            let copyServices = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
            let copyProperty = dlsym(handle, "IOHIDServiceClientCopyProperty"),
            let copyEvent = dlsym(handle, "IOHIDServiceClientCopyEvent"),
            let floatValue = dlsym(handle, "IOHIDEventGetFloatValue"),
            let client = unsafeBitCast(create, to: VigilHIDClientCreateFn.self)(kCFAllocatorDefault)?
                .takeRetainedValue()
        else { return nil }
        self.client = client
        self.copyServices = unsafeBitCast(copyServices, to: VigilHIDClientCopyServicesFn.self)
        self.copyProperty = unsafeBitCast(copyProperty, to: VigilHIDServiceCopyPropertyFn.self)
        self.copyEvent = unsafeBitCast(copyEvent, to: VigilHIDServiceCopyEventFn.self)
        self.floatValue = unsafeBitCast(floatValue, to: VigilHIDEventGetFloatValueFn.self)
        let matching =
            [
                "PrimaryUsagePage": VigilHIDTemperatureUsagePage, "PrimaryUsage": VigilHIDTemperatureUsage,
            ] as CFDictionary
        _ = unsafeBitCast(setMatching, to: VigilHIDClientSetMatchingFn.self)(client, matching)
    }

    /// Readings by sensor name. The service list is refreshed once a minute.
    func read() -> [(name: String, celsius: Double)]? {
        if Date().timeIntervalSince(servicesReadAt) > 60 {
            servicesReadAt = Date()
            let list = (copyServices(client)?.takeRetainedValue() as? [CFTypeRef]) ?? []
            // Keep only sensors we report (die, battery, SSD), one per name: the
            // same die sensors repeat once per power controller (76 → 16 on M5 Pro).
            var seen = Set<String>()
            services = list.compactMap { service in
                let name = (copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String) ?? ""
                let lower = name.lowercased()
                let relevant =
                    lower.contains("tdie") || lower.contains("battery") || lower.contains("nand")
                    || lower.contains("ssd")
                guard relevant, seen.insert(name).inserted else { return nil }
                return (service, name)
            }
        }
        guard !services.isEmpty else { return nil }
        var readings: [(name: String, celsius: Double)] = []
        readings.reserveCapacity(services.count)
        for (service, name) in services {
            guard let event = copyEvent(service, Int64(VigilHIDEventTypeTemperature), 0, 0)?.takeRetainedValue()
            else { continue }
            readings.append((name, floatValue(event, Int32(VigilHIDTemperatureLevelField))))
        }
        return readings
    }
}

/// Read-only access to the System Management Controller (AppleSMC user client).
private final class SMCReader {
    private var connection: io_connect_t = 0
    private var keyInfo: [UInt32: VigilSMCKeyInfoData] = [:]
    private var fanCount: Int?
    private var fanMaximums: [Int: Double] = [:]

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    func fans() -> [Fan]? {
        if fanCount == nil { fanCount = read("FNum").map { Int($0) } ?? 0 }
        guard let fanCount, fanCount > 0 else { return nil }
        return (0..<min(fanCount, 8)).compactMap { index in
            guard let rpm = SensorRange.rpm(read("F\(index)Ac")) else { return nil }
            if fanMaximums[index] == nil { fanMaximums[index] = SensorRange.rpm(read("F\(index)Mx")) }
            return Fan(rpm: rpm, maximum: fanMaximums[index])
        }
    }

    func read(_ key: String) -> Double? {
        let code = SMCValue.fourCharacterCode(key)
        var input = VigilSMCParamStruct()
        input.key = code
        if keyInfo[code] == nil {
            input.data8 = UInt8(VigilSMCGetKeyInfo)
            guard let info = call(&input) else { return nil }
            keyInfo[code] = info.keyInfo
        }
        guard let info = keyInfo[code] else { return nil }
        input.keyInfo.dataSize = info.dataSize
        input.data8 = UInt8(VigilSMCReadKey)
        guard let output = call(&input) else { return nil }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(min(info.dataSize, 32)))) }
        return SMCValue.decode(type: SMCValue.string(info.dataType), bytes: bytes)
    }

    private func call(_ input: inout VigilSMCParamStruct) -> VigilSMCParamStruct? {
        var output = VigilSMCParamStruct()
        var size = MemoryLayout<VigilSMCParamStruct>.size
        let result = IOConnectCallStructMethod(
            connection, UInt32(VigilSMCHandleYPCEvent), &input, MemoryLayout<VigilSMCParamStruct>.size, &output, &size)
        return result == KERN_SUCCESS && output.result == 0 ? output : nil
    }
}
