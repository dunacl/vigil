// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import Darwin

/// Reads every process with one `sysctl(KERN_PROC_ALL)` call (pid, parent,
/// owner, state, start time; ~0.5 ms for 840 processes), then statistics with
/// `proc_pid_rusage` for the processes macOS lets us inspect.
///
/// For other users' processes (root, system daemons) macOS refuses statistics to
/// unprivileged apps (EPERM; verified on macOS 27.2). Those are marked
/// restricted once and never retried, so they cost nothing per tick.
final class ProcessCollector {
    private struct Known {
        let name: String
        let path: String?
        let user: String
        var restricted: Bool
        var counters: ProcessCounters?
        var time: MonotonicInstant?
        var lastSeen: UInt64
    }

    private var buffer: [kinfo_proc] = []
    private var known: [ProcessIdentity: Known] = [:]
    private var users: [UInt32: String] = [:]
    private var generation: UInt64 = 0
    private let timebase: (numer: UInt64, denom: UInt64)
    private let ownPID = getpid()

    init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        // rusage CPU times are Mach ticks (125/3 ns on Apple Silicon), not nanoseconds.
        timebase = (UInt64(max(info.numer, 1)), UInt64(max(info.denom, 1)))
    }

    func reset() {
        for key in known.keys {
            known[key]?.counters = nil
            known[key]?.time = nil
        }
    }

    func sample(at time: MonotonicInstant, expectedInterval: Double, details: Bool) -> ProcessMetrics? {
        guard readAll() else { return nil }
        generation += 1
        var entries: [ProcessEntry] = []
        entries.reserveCapacity(buffer.count)
        for kinfo in buffer {
            let proc = kinfo.kp_proc
            let pid = proc.p_pid
            let start = UInt64(max(proc.p_starttime.tv_sec, 0)) * 1_000_000 + UInt64(max(proc.p_starttime.tv_usec, 0))
            let identity = ProcessIdentity(pid: pid, startMicroseconds: start)
            let uid = kinfo.kp_eproc.e_ucred.cr_uid
            var entry = known[identity] ?? describe(identity, comm: proc.p_comm, uid: uid)

            var cpu: Double?, read: Double?, write: Double?, cpuTime: Double?, memory: UInt64?, threads: Int?
            if !entry.restricted {
                switch readCounters(pid) {
                case .success(let counters):
                    let window = entry.time.map {
                        SampleWindow(previous: $0, current: time, expectedInterval: expectedInterval)
                    }
                    (cpu, read, write) = ProcessCounters.rates(
                        previous: entry.counters, current: counters, window: window)
                    cpuTime = Double(counters.cpuNanoseconds) / 1_000_000_000
                    memory = counters.footprint
                    entry.counters = counters
                    entry.time = time
                    if details { threads = Self.threadCount(pid) }
                case .denied:
                    entry.restricted = true
                case .gone:
                    continue  // exited between the list and the read
                }
            }
            entry.lastSeen = generation
            known[identity] = entry
            entries.append(
                ProcessEntry(
                    id: identity, parentPID: kinfo.kp_eproc.e_ppid, uid: uid, user: entry.user, name: entry.name,
                    path: entry.path, state: ProcessState(kernelState: proc.p_stat), isRestricted: entry.restricted,
                    cpu: cpu, memory: memory, diskReadPerSecond: read, diskWritePerSecond: write, cpuTime: cpuTime,
                    threads: threads))
        }
        // Forget exited processes (bounded memory, SPEC §7).
        if known.count > entries.count + entries.count / 4 {
            known = known.filter { $0.value.lastSeen == generation }
        }
        return ProcessMetrics(processes: entries)
    }

    // MARK: - Reading

    private func readAll() -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return false }
            let needed = size / MemoryLayout<kinfo_proc>.stride + 32
            if buffer.count < needed { buffer = Array(repeating: kinfo_proc(), count: needed + needed / 4) }
            size = buffer.count * MemoryLayout<kinfo_proc>.stride
            let result = buffer.withUnsafeMutableBufferPointer { sysctl(&mib, 4, $0.baseAddress, &size, nil, 0) }
            if result == 0 {
                let count = size / MemoryLayout<kinfo_proc>.stride
                if count < buffer.count { buffer.removeSubrange(count...) }
                return true
            }
            guard errno == ENOMEM else { return false }
            buffer = []  // grew between calls; retry
        }
        return false
    }

    private enum CounterRead { case success(ProcessCounters), denied, gone }

    private func readCounters(_ pid: Int32) -> CounterRead {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        guard result == 0 else { return errno == ESRCH ? .gone : .denied }
        let ticks = info.ri_user_time &+ info.ri_system_time
        return .success(
            ProcessCounters(
                cpuNanoseconds: ticks / timebase.denom * timebase.numer + ticks % timebase.denom * timebase.numer
                    / timebase.denom,
                diskRead: info.ri_diskio_bytesread, diskWritten: info.ri_diskio_byteswritten,
                footprint: info.ri_phys_footprint))
    }

    private static func threadCount(_ pid: Int32) -> Int? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return Int(info.pti_threadnum)
    }

    /// Name, path and user are read once per process identity and cached.
    private func describe<Comm>(_ identity: ProcessIdentity, comm: Comm, uid: UInt32) -> Known {
        // PROC_PIDPATHINFO_MAXSIZE is a macro (4 × MAXPATHLEN) Swift can't import.
        var raw = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(identity.pid, &raw, UInt32(raw.count))
        let path =
            length > 0 ? String(decoding: raw.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
        let shortName = withUnsafeBytes(of: comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let name = path.flatMap { $0.split(separator: "/").last.map(String.init) } ?? shortName
        return Known(
            name: name.isEmpty ? (identity.pid == 0 ? "kernel_task" : "pid \(identity.pid)") : name, path: path,
            user: userName(uid), restricted: false, counters: nil, time: nil, lastSeen: 0)
    }

    private func userName(_ uid: UInt32) -> String {
        if let cached = users[uid] { return cached }
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var scratch = [CChar](repeating: 0, count: 1024)
        let name =
            getpwuid_r(uid, &record, &scratch, scratch.count, &result) == 0 && result != nil
            ? String(cString: record.pw_name) : String(uid)
        users[uid] = name
        return name
    }
}
