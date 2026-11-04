// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import Darwin

/// Static or slowly changing facts about this Mac. Read once at startup.
public struct SystemInfo: Sendable, Equatable {
    public var model: String
    public var cpu: CPUTopology
    public var memoryBytes: UInt64
    public var osVersion: String
    public var osBuild: String?
    public var hostName: String
    /// Boot time in seconds since 1970.
    public var bootTime: Double

    public init(
        model: String, cpu: CPUTopology, memoryBytes: UInt64, osVersion: String, osBuild: String? = nil,
        hostName: String, bootTime: Double
    ) {
        self.osBuild = osBuild
        self.model = model
        self.cpu = cpu
        self.memoryBytes = memoryBytes
        self.osVersion = osVersion
        self.hostName = hostName
        self.bootTime = bootTime
    }

    /// Seconds since boot, wall-clock based.
    public var uptime: Double {
        var now = timeval()
        gettimeofday(&now, nil)
        return max(0, Double(now.tv_sec) + Double(now.tv_usec) / 1_000_000 - bootTime)
    }

    public static func current() -> SystemInfo {
        let boot = Sysctl.value("kern.boottime", as: timeval.self).map {
            Double($0.tv_sec) + Double($0.tv_usec) / 1_000_000
        }
        return SystemInfo(
            model: Sysctl.string("hw.model") ?? "Mac",
            cpu: .current(),
            memoryBytes: UInt64(Sysctl.integer("hw.memsize") ?? 0),
            osVersion: Sysctl.string("kern.osproductversion") ?? "",
            osBuild: Sysctl.string("kern.osversion"),
            hostName: Sysctl.string("kern.hostname") ?? "",
            bootTime: boot ?? 0
        )
    }
}
