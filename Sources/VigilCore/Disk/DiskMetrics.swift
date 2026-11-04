// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

/// Cumulative I/O counters for one physical disk.
public struct DiskCounters: Sendable, Equatable {
    public var bytesRead: UInt64
    public var bytesWritten: UInt64
    public var reads: UInt64
    public var writes: UInt64

    public init(bytesRead: UInt64, bytesWritten: UInt64, reads: UInt64, writes: UInt64) {
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
        self.reads = reads
        self.writes = writes
    }
}

/// One physical disk as read from IOKit.
public struct DiskReading: Sendable, Equatable {
    /// IORegistry entry ID: stable for the device's lifetime, never reused.
    public var registryID: UInt64
    /// BSD name of the whole disk, e.g. `disk0`.
    public var bsdName: String
    /// Model name, e.g. `APPLE SSD AP1024Z`.
    public var name: String
    public var counters: DiskCounters

    public init(registryID: UInt64, bsdName: String, name: String, counters: DiskCounters) {
        self.registryID = registryID
        self.bsdName = bsdName
        self.name = name
        self.counters = counters
    }
}

/// I/O metrics for one physical disk.
public struct DiskIOMetrics: Sendable, Equatable, Identifiable {
    public var bsdName: String
    public var name: String
    public var totals: DiskCounters
    /// `nil` on the first sample, after a gap, or when the counters reset.
    public var readBytesPerSecond: Double?
    public var writeBytesPerSecond: Double?
    public var readsPerSecond: Double?
    public var writesPerSecond: Double?

    public var id: String { bsdName }

    public init(current: DiskReading, previous: DiskReading?, window: SampleWindow?) {
        bsdName = current.bsdName
        name = current.name
        totals = current.counters
        guard let previous, previous.registryID == current.registryID, let window, window.isValid else { return }
        let old = previous.counters, new = current.counters
        guard let bytesRead = Counter.delta(old.bytesRead, new.bytesRead),
            let bytesWritten = Counter.delta(old.bytesWritten, new.bytesWritten),
            let reads = Counter.delta(old.reads, new.reads),
            let writes = Counter.delta(old.writes, new.writes)
        else { return }
        readBytesPerSecond = Double(bytesRead) / window.elapsed
        writeBytesPerSecond = Double(bytesWritten) / window.elapsed
        readsPerSecond = Double(reads) / window.elapsed
        writesPerSecond = Double(writes) / window.elapsed
    }
}

/// A mounted, user-visible volume.
public struct VolumeInfo: Sendable, Equatable, Identifiable {
    /// Mount point, e.g. `/` or `/Volumes/Backup`.
    public var mountPoint: String
    /// Device, e.g. `/dev/disk3s1s1`.
    public var device: String
    /// File system type, e.g. `apfs`, `exfat`.
    public var fileSystem: String
    public var totalBytes: UInt64
    /// Space available to a normal user (excludes reserved blocks).
    public var availableBytes: UInt64
    public var isLocal: Bool
    public var isReadOnly: Bool

    public var id: String { mountPoint }

    public var usedBytes: UInt64 { totalBytes.subtractingClamped(availableBytes) }

    public var usedFraction: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    }

    public init(
        mountPoint: String, device: String, fileSystem: String, totalBytes: UInt64,
        availableBytes: UInt64, isLocal: Bool, isReadOnly: Bool
    ) {
        self.mountPoint = mountPoint
        self.device = device
        self.fileSystem = fileSystem
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.isLocal = isLocal
        self.isReadOnly = isReadOnly
    }
}

/// Disk metrics for one sample.
public struct DiskMetrics: Sendable, Equatable {
    public var disks: [DiskIOMetrics]
    /// Refreshed on a slow cadence (see ``SamplerConfiguration/volumeRefreshInterval``).
    public var volumes: [VolumeInfo]

    public init(disks: [DiskIOMetrics], volumes: [VolumeInfo]) {
        self.disks = disks
        self.volumes = volumes
    }

    /// Sum of all physical disks' rates; `nil` if no disk has a rate yet.
    public var totalReadBytesPerSecond: Double? { sum(\.readBytesPerSecond) }
    public var totalWriteBytesPerSecond: Double? { sum(\.writeBytesPerSecond) }

    private func sum(_ keyPath: KeyPath<DiskIOMetrics, Double?>) -> Double? {
        let rates = disks.compactMap { $0[keyPath: keyPath] }
        return rates.isEmpty ? nil : rates.reduce(0, +)
    }
}
