// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import Darwin

/// On-demand details for one process (the Dashboard's detail pane). Only
/// available for the user's own processes; `nil`s otherwise.
public struct ProcessDetails: Sendable, Equatable {
    public var arguments: [String]?
    public var openFiles: Int?

    public static func read(_ identity: ProcessIdentity) -> ProcessDetails {
        ProcessDetails(arguments: ProcessArguments.read(identity.pid), openFiles: openFileCount(identity.pid))
    }

    private static func openFileCount(_ pid: Int32) -> Int? {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return nil }
        return Int(size) / MemoryLayout<proc_fdinfo>.stride
    }
}

/// Command-line arguments via `KERN_PROCARGS2`.
public enum ProcessArguments {
    public static func read(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parse(Array(buffer.prefix(size)))
    }

    /// Layout: `Int32 argc`, the executable path, NUL padding, then `argc`
    /// NUL-terminated arguments (then the environment, which is ignored).
    public static func parse(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count > 4 else { return nil }
        let argc = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard argc > 0, argc < 65_536 else { return nil }
        var index = 4
        while index < bytes.count, bytes[index] != 0 { index += 1 }  // executable path
        while index < bytes.count, bytes[index] == 0 { index += 1 }  // padding
        var arguments: [String] = []
        while arguments.count < argc, index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments.count == argc ? arguments : nil
    }
}

/// Signals Vigil can send (SPEC §3.2 "Actions").
public enum ProcessSignal: Int32, Sendable, CaseIterable {
    case terminate = 15  // SIGTERM
    case kill = 9  // SIGKILL
    case interrupt = 2  // SIGINT
    case hangUp = 1  // SIGHUP
    case stop = 17  // SIGSTOP
    case resume = 19  // SIGCONT

    public var name: String {
        switch self {
        case .terminate: "Quit (TERM)"
        case .kill: "Force Quit (KILL)"
        case .interrupt: "Interrupt (INT)"
        case .hangUp: "Hang Up (HUP)"
        case .stop: "Pause (STOP)"
        case .resume: "Resume (CONT)"
        }
    }

    /// Signals that end the process or can't be caught get a stronger confirmation.
    public var isDestructive: Bool { self == .kill || self == .terminate }
}

public enum SignalResult: Sendable, Equatable {
    case sent
    /// The process exited, or its PID now belongs to a different process.
    case processGone
    case permissionDenied
    case failed(errno: Int32)
}

public enum ProcessSignals {
    /// PIDs that need an extra confirmation: kernel_task, launchd, and Vigil itself.
    public static func isSensitive(_ pid: Int32) -> Bool { pid <= 1 || pid == getpid() }

    /// Sends `signal` only if `identity` still refers to the same process, so a
    /// recycled PID can never receive a signal meant for an exited process.
    public static func send(_ signal: ProcessSignal, to identity: ProcessIdentity) -> SignalResult {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, identity.pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return .processGone }
        let start = info.kp_proc.p_starttime
        let micros = UInt64(max(start.tv_sec, 0)) * 1_000_000 + UInt64(max(start.tv_usec, 0))
        guard micros == identity.startMicroseconds else { return .processGone }
        guard Darwin.kill(identity.pid, signal.rawValue) == 0 else {
            switch errno {
            case ESRCH: return .processGone
            case EPERM: return .permissionDenied
            default: return .failed(errno: errno)
            }
        }
        return .sent
    }
}
