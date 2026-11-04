// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

/// A process identity that survives PID reuse (SPEC §7): the PID plus the
/// process's start time. Deltas are never computed across two identities.
public struct ProcessIdentity: Hashable, Sendable, Comparable, CustomStringConvertible {
    public var pid: Int32
    /// Start time in microseconds since 1970.
    public var startMicroseconds: UInt64

    public init(pid: Int32, startMicroseconds: UInt64) {
        self.pid = pid
        self.startMicroseconds = startMicroseconds
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.pid, lhs.startMicroseconds) < (rhs.pid, rhs.startMicroseconds)
    }

    public var description: String { "\(pid)@\(startMicroseconds)" }
}

public enum ProcessState: String, Sendable, Codable {
    case running, sleeping, stopped, zombie, idle, unknown

    init(kernelState: Int8) {
        // <sys/proc.h>: SIDL 1, SRUN 2, SSLEEP 3, SSTOP 4, SZOMB 5
        self =
            switch kernelState {
            case 1: .idle
            case 2: .running
            case 3: .sleeping
            case 4: .stopped
            case 5: .zombie
            default: .unknown
            }
    }
}

/// One process at one sample.
///
/// Statistics are `nil` when unavailable: on the first sample (rates need two),
/// and always for processes of other users, which macOS doesn't let an
/// unprivileged app inspect (``isRestricted``; a privileged helper is planned).
public struct ProcessEntry: Sendable, Identifiable, Equatable {
    public var id: ProcessIdentity
    public var parentPID: Int32
    public var uid: UInt32
    public var user: String
    /// Executable file name (full, unlike the kernel's 16-character name).
    public var name: String
    public var path: String?
    public var state: ProcessState
    public var isRestricted: Bool
    /// CPU use as a fraction of one core (1.0 = 100 %, can exceed 1 on multiple cores).
    public var cpu: Double?
    /// Physical footprint in bytes (what Activity Monitor calls "Memory").
    public var memory: UInt64?
    public var diskReadPerSecond: Double?
    public var diskWritePerSecond: Double?
    /// Total CPU time used, seconds.
    public var cpuTime: Double?
    /// Only collected while process details are demanded (the Dashboard is open).
    public var threads: Int?

    public var pid: Int32 { id.pid }
    /// Start time in seconds since 1970.
    public var startDate: Double { Double(id.startMicroseconds) / 1_000_000 }

    public init(
        id: ProcessIdentity, parentPID: Int32, uid: UInt32, user: String, name: String, path: String?,
        state: ProcessState, isRestricted: Bool, cpu: Double? = nil, memory: UInt64? = nil,
        diskReadPerSecond: Double? = nil, diskWritePerSecond: Double? = nil, cpuTime: Double? = nil,
        threads: Int? = nil
    ) {
        self.id = id
        self.parentPID = parentPID
        self.uid = uid
        self.user = user
        self.name = name
        self.path = path
        self.state = state
        self.isRestricted = isRestricted
        self.cpu = cpu
        self.memory = memory
        self.diskReadPerSecond = diskReadPerSecond
        self.diskWritePerSecond = diskWritePerSecond
        self.cpuTime = cpuTime
        self.threads = threads
    }
}

/// All processes at one sample.
public struct ProcessMetrics: Sendable, Equatable {
    public var processes: [ProcessEntry]

    public init(processes: [ProcessEntry]) { self.processes = processes }

    /// How many processes macOS didn't let us inspect.
    public var restrictedCount: Int { processes.lazy.filter(\.isRestricted).count }

    public subscript(identity: ProcessIdentity) -> ProcessEntry? {
        processes.first { $0.id == identity }
    }

    /// The `count` heaviest processes by `key` (CPU or memory), skipping ones
    /// without data. A single pass keeping a small sorted top list: O(n·count)
    /// instead of sorting all ~800 processes every tick.
    public func top(_ count: Int, by key: TopProcessesSort) -> [ProcessEntry] {
        guard count > 0 else { return [] }
        func score(_ entry: ProcessEntry) -> Double? {
            switch key {
            case .cpu: entry.cpu
            case .memory: entry.memory.map(Double.init)
            }
        }
        // Higher score first; ties go to the lower PID for a stable order.
        func ranksAbove(_ a: (Double, Int32), _ b: (Double, Int32)) -> Bool { a.0 != b.0 ? a.0 > b.0 : a.1 < b.1 }
        var best: [(score: Double, pid: Int32, entry: ProcessEntry)] = []
        best.reserveCapacity(count + 1)
        for entry in processes {
            guard let value = score(entry) else { continue }
            if best.count == count, let last = best.last, !ranksAbove((value, entry.pid), (last.score, last.pid)) {
                continue
            }
            let index = best.firstIndex { !ranksAbove(($0.score, $0.pid), (value, entry.pid)) } ?? best.count
            best.insert((value, entry.pid, entry), at: index)
            if best.count > count { best.removeLast() }
        }
        return best.map(\.entry)
    }
}

/// What a Top Processes panel ranks by.
public enum TopProcessesSort: String, Codable, Sendable, CaseIterable {
    case cpu, memory
}

/// Raw cumulative counters for one process (for delta math).
struct ProcessCounters: Sendable, Equatable {
    /// User + system CPU time in nanoseconds.
    var cpuNanoseconds: UInt64
    var diskRead: UInt64
    var diskWritten: UInt64
    var footprint: UInt64

    /// CPU fraction and disk rates over `window`; `nil` fields on a reset or invalid window.
    static func rates(previous: ProcessCounters?, current: ProcessCounters, window: SampleWindow?)
        -> (cpu: Double?, read: Double?, write: Double?)
    {
        guard let previous, let window, window.isValid else { return (nil, nil, nil) }
        let cpu = Counter.delta(previous.cpuNanoseconds, current.cpuNanoseconds).map {
            Double($0) / 1_000_000_000 / window.elapsed
        }
        let read = Counter.delta(previous.diskRead, current.diskRead).map { Double($0) / window.elapsed }
        let write = Counter.delta(previous.diskWritten, current.diskWritten).map { Double($0) / window.elapsed }
        return (cpu, read, write)
    }
}
