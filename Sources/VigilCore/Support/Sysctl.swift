// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import Darwin

/// Thin, allocation-free helpers over `sysctl`.
///
/// Name-based lookups (`sysctlbyname`) are for one-off reads at setup time.
/// Values read every tick should use a ``Sysctl/MIB`` resolved once.
enum Sysctl {
    /// Reads an integer value of 4 or 8 bytes by name.
    static func integer(_ name: String) -> Int64? {
        var raw: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &raw, &size, nil, 0) == 0 else { return nil }
        return decode(raw, size: size)
    }

    /// Reads a NUL-terminated string value by name.
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Reads a fixed-size C struct by name.
    static func value<T: BitwiseCopyable>(_ name: String, as _: T.Type) -> T? {
        var size = MemoryLayout<T>.size
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard sysctlbyname(name, pointer, &size, nil, 0) == 0, size == MemoryLayout<T>.size else { return nil }
        return pointer.pointee
    }

    fileprivate static func decode(_ raw: UInt64, size: Int) -> Int64? {
        switch size {
        case 4: Int64(Int32(truncatingIfNeeded: raw))
        case 8: Int64(bitPattern: raw)
        default: nil
        }
    }

    /// A sysctl name resolved to its numeric MIB once, for cheap repeated reads.
    struct MIB {
        private var components: [Int32]

        init?(_ name: String) {
            var mib = [Int32](repeating: 0, count: Int(CTL_MAXNAME))
            var count = mib.count
            guard sysctlnametomib(name, &mib, &count) == 0 else { return nil }
            components = Array(mib.prefix(count))
        }

        /// Reads an integer value of 4 or 8 bytes.
        mutating func integer() -> Int64? {
            var raw: UInt64 = 0
            var size = MemoryLayout<UInt64>.size
            let count = UInt32(components.count)
            let result = components.withUnsafeMutableBufferPointer {
                sysctl($0.baseAddress, count, &raw, &size, nil, 0)
            }
            guard result == 0 else { return nil }
            return Sysctl.decode(raw, size: size)
        }

        /// Reads a fixed-size C struct into `value`. Returns `false` on failure.
        mutating func read<T: BitwiseCopyable>(into value: inout T) -> Bool {
            var size = MemoryLayout<T>.size
            let count = UInt32(components.count)
            let result = components.withUnsafeMutableBufferPointer { mib in
                withUnsafeMutablePointer(to: &value) { sysctl(mib.baseAddress, count, $0, &size, nil, 0) }
            }
            return result == 0 && size == MemoryLayout<T>.size
        }
    }
}
