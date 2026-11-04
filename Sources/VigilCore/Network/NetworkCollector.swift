// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import CVigilSys
import Darwin
import Foundation
import SystemConfiguration

/// Reads per-interface counters from the routing socket (`NET_RT_IFLIST2`).
///
/// Uses `if_data64` counters. `getifaddrs` is avoided on purpose: its `if_data`
/// counters are 32-bit and wrap every 4 GiB.
final class NetworkCollector {
    private var buffer: UnsafeMutableRawBufferPointer = .init(start: nil, count: 0)
    private var names: [UInt16: String] = [:]
    private var previous: [UInt16: InterfaceReading] = [:]
    private var previousTime: MonotonicInstant?
    private var readings: [InterfaceReading] = []

    private var primaryInterface: String?
    /// The primary interface rarely changes: it's looked up once, then again only
    /// when configd reports a default-route change (see ``invalidatePrimaryInterface()``).
    private var primaryIsStale = true

    deinit { buffer.deallocate() }

    func reset() {
        previous.removeAll(keepingCapacity: true)
        previousTime = nil
        primaryIsStale = true
    }

    func invalidatePrimaryInterface() { primaryIsStale = true }

    func sample(at time: MonotonicInstant, expectedInterval: Double) -> NetworkMetrics? {
        guard read(into: &readings) else {
            reset()
            return nil
        }
        let window = previousTime.map {
            SampleWindow(previous: $0, current: time, expectedInterval: expectedInterval)
        }
        var interfaces: [InterfaceMetrics] = []
        interfaces.reserveCapacity(readings.count)
        for reading in readings {
            interfaces.append(InterfaceMetrics(current: reading, previous: previous[reading.index], window: window))
        }

        previous.removeAll(keepingCapacity: true)
        for reading in readings { previous[reading.index] = reading }
        previousTime = time

        if primaryIsStale {
            primaryInterface = Self.currentPrimaryInterface()
            primaryIsStale = false
        }
        return NetworkMetrics(interfaces: interfaces, primaryInterface: primaryInterface)
    }

    /// Fills `readings` with every interface. Returns `false` on failure.
    func read(into readings: inout [InterfaceReading]) -> Bool {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var needed = 0
        // The table can grow between the size query and the read; retry a few times.
        for _ in 0..<4 {
            guard sysctl(&mib, UInt32(mib.count), nil, &needed, nil, 0) == 0 else { return false }
            if needed > buffer.count { grow(to: needed + needed / 4) }
            var length = buffer.count
            if sysctl(&mib, UInt32(mib.count), buffer.baseAddress, &length, nil, 0) == 0 {
                parse(length: length, into: &readings)
                return true
            }
            guard errno == ENOMEM else { return false }
        }
        return false
    }

    private func grow(to size: Int) {
        buffer.deallocate()
        buffer = .allocate(byteCount: size, alignment: MemoryLayout<if_msghdr2>.alignment)
    }

    private func parse(length: Int, into readings: inout [InterfaceReading]) {
        readings.removeAll(keepingCapacity: true)
        guard let base = buffer.baseAddress else { return }
        let headerSize = MemoryLayout<if_msghdr>.size
        var offset = 0
        while offset + headerSize <= length {
            let header = base.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
            let messageLength = Int(header.ifm_msglen)
            guard messageLength > 0, offset + messageLength <= length else { break }
            defer { offset += messageLength }
            guard Int32(header.ifm_type) == RTM_IFINFO2,
                messageLength >= MemoryLayout<if_msghdr2>.size
            else { continue }

            let message = base.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
            let index = message.ifm_index
            let data = message.ifm_data
            readings.append(
                InterfaceReading(
                    index: index,
                    name: name(for: index),
                    isUp: message.ifm_flags & IFF_UP != 0,
                    isLoopback: message.ifm_flags & IFF_LOOPBACK != 0,
                    counters: InterfaceCounters(
                        receivedBytes: data.ifi_ibytes,
                        sentBytes: data.ifi_obytes,
                        receivedPackets: data.ifi_ipackets,
                        sentPackets: data.ifi_opackets
                    )
                ))
        }
        // Interface indices are reused after removal; drop names of vanished ones.
        if names.count > readings.count {
            let live = Set(readings.map(\.index))
            names = names.filter { live.contains($0.key) }
        }
    }

    /// Interface name for a kernel index, resolved once and cached.
    private func name(for index: UInt16) -> String {
        if let cached = names[index] { return cached }
        var raw = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        let resolved =
            if_indextoname(UInt32(index), &raw) != nil
            ? String(decoding: raw.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : "if\(index)"
        names[index] = resolved
        return resolved
    }

    /// BSD name of the interface carrying the IPv4 (or IPv6) default route.
    static func currentPrimaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "Vigil" as CFString, nil, nil) else { return nil }
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            if let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                let name = value["PrimaryInterface"] as? String
            {
                return name
            }
        }
        return nil
    }
}
