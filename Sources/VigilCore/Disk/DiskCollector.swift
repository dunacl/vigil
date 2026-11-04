// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import Darwin
import Foundation
import IOKit

/// Reads physical disk I/O from IOKit and mounted volumes from `getfsstat`.
///
/// The set of disks is discovered once and re-discovered only when IOKit reports
/// a device change (``invalidateDevices()``) or a disk stops answering; per tick
/// only each driver's `Statistics` is read.
final class DiskCollector {
    private struct Device {
        let driver: io_registry_entry_t
        let registryID: UInt64
        let bsdName: String
        let name: String
    }

    private var devices: [Device] = []
    private var devicesAreStale = true
    private var previous: [UInt64: DiskReading] = [:]
    private var previousTime: MonotonicInstant?
    private var volumes: [VolumeInfo] = []
    private var volumesReadAt: MonotonicInstant?
    private var mountBuffer: [statfs] = []

    var volumeRefreshInterval = 10.0

    // Statistics dictionary keys (IOBlockStorageDriver.h), bridged once per collector.
    private let statisticsKey = "Statistics" as CFString
    private let bytesReadKey = "Bytes (Read)" as CFString
    private let bytesWrittenKey = "Bytes (Write)" as CFString
    private let readsKey = "Operations (Read)" as CFString
    private let writesKey = "Operations (Write)" as CFString

    deinit { releaseDevices() }

    func reset() {
        previous.removeAll(keepingCapacity: true)
        previousTime = nil
        devicesAreStale = true
        volumesReadAt = nil
    }

    /// Re-discover disks on the next sample, and refresh volumes (a disk change
    /// usually means a mount or unmount).
    func invalidateDevices() {
        devicesAreStale = true
        volumesReadAt = nil
    }

    func sample(at time: MonotonicInstant, expectedInterval: Double, includeVolumes: Bool) -> DiskMetrics {
        if devicesAreStale {
            discover()
            devicesAreStale = false
        }
        let window = previousTime.map {
            SampleWindow(previous: $0, current: time, expectedInterval: expectedInterval)
        }

        var disks: [DiskIOMetrics] = []
        disks.reserveCapacity(devices.count)
        var lostDevice = false
        var current: [UInt64: DiskReading] = [:]
        for device in devices {
            guard let counters = readCounters(device.driver) else {
                lostDevice = true
                continue
            }
            let reading = DiskReading(
                registryID: device.registryID, bsdName: device.bsdName, name: device.name, counters: counters)
            disks.append(DiskIOMetrics(current: reading, previous: previous[device.registryID], window: window))
            current[device.registryID] = reading
        }
        previous = current
        previousTime = time
        if lostDevice { devicesAreStale = true }  // re-discover on the next tick

        if includeVolumes, volumesReadAt.map({ time.seconds(since: $0) >= volumeRefreshInterval }) ?? true {
            volumes = readVolumes()
            volumesReadAt = time
        }
        return DiskMetrics(disks: disks, volumes: includeVolumes ? volumes : [])
    }

    // MARK: - Physical disks

    private func discover() {
        releaseDevices()
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator)
                == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }

        while case let driver = IOIteratorNext(iterator), driver != 0 {
            guard let device = Self.describe(driver) else {
                IOObjectRelease(driver)
                continue
            }
            devices.append(device)  // keeps the iterator's reference to `driver`
        }
    }

    /// Returns a device for a driver that has whole-disk media attached, else `nil`
    /// (e.g. an empty SD card slot).
    private static func describe(_ driver: io_registry_entry_t) -> Device? {
        var media: io_registry_entry_t = 0
        guard IORegistryEntryGetChildEntry(driver, kIOServicePlane, &media) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(media) }
        guard IOObjectConformsTo(media, "IOMedia") != 0,
            let bsdName = stringProperty(media, "BSD Name")
        else { return nil }

        var registryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(driver, &registryID)

        var rawName = [CChar](repeating: 0, count: 128)  // io_name_t
        var name = bsdName
        if IORegistryEntryGetName(media, &rawName) == KERN_SUCCESS {
            let decoded = String(decoding: rawName.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            name = decoded.hasSuffix(" Media") ? String(decoded.dropLast(6)) : decoded
        }
        return Device(driver: driver, registryID: registryID, bsdName: bsdName, name: name)
    }

    private func releaseDevices() {
        for device in devices { IOObjectRelease(device.driver) }
        devices.removeAll(keepingCapacity: true)
    }

    private func readCounters(_ driver: io_registry_entry_t) -> DiskCounters? {
        guard
            let property = IORegistryEntryCreateCFProperty(driver, statisticsKey, kCFAllocatorDefault, 0)?
                .takeRetainedValue(),
            CFGetTypeID(property) == CFDictionaryGetTypeID()
        else { return nil }
        let statistics = unsafeDowncast(property, to: CFDictionary.self)
        return DiskCounters(
            bytesRead: Self.uint64(statistics, bytesReadKey),
            bytesWritten: Self.uint64(statistics, bytesWrittenKey),
            reads: Self.uint64(statistics, readsKey),
            writes: Self.uint64(statistics, writesKey)
        )
    }

    /// Reads a number without bridging the dictionary to Swift.
    private static func uint64(_ dictionary: CFDictionary, _ key: CFString) -> UInt64 {
        guard let raw = CFDictionaryGetValue(dictionary, Unmanaged.passUnretained(key).toOpaque()) else { return 0 }
        let value = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
        guard CFGetTypeID(value) == CFNumberGetTypeID() else { return 0 }
        var result: Int64 = 0
        CFNumberGetValue(unsafeDowncast(value, to: CFNumber.self), .sInt64Type, &result)
        return UInt64(clamping: result)
    }

    private static func stringProperty(_ entry: io_registry_entry_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    // MARK: - Volumes

    private func readVolumes() -> [VolumeInfo] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        // Room for a few mounts appearing between the two calls.
        let capacity = Int(count) + 4
        if mountBuffer.count < capacity { mountBuffer = Array(repeating: .init(), count: capacity) }
        let filled = mountBuffer.withUnsafeMutableBufferPointer {
            getfsstat($0.baseAddress, Int32(capacity * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        guard filled > 0 else { return [] }

        var result: [VolumeInfo] = []
        for index in 0..<Int(filled) {
            let entry = mountBuffer[index]
            let flags = UInt32(entry.f_flags)
            // MNT_DONTBROWSE hides system-internal mounts (VM, Preboot, Update, ...).
            guard flags & UInt32(MNT_DONTBROWSE) == 0, entry.f_blocks > 0 else { continue }
            let blockSize = UInt64(entry.f_bsize)
            result.append(
                VolumeInfo(
                    mountPoint: Self.string(entry.f_mntonname),
                    device: Self.string(entry.f_mntfromname),
                    fileSystem: Self.string(entry.f_fstypename),
                    totalBytes: entry.f_blocks * blockSize,
                    availableBytes: entry.f_bavail * blockSize,
                    isLocal: flags & UInt32(MNT_LOCAL) != 0,
                    isReadOnly: flags & UInt32(MNT_RDONLY) != 0
                ))
        }
        return result
    }

    /// Decodes a fixed-size C `char[]` tuple.
    private static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
