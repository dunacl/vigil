// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

/// Cumulative 64-bit counters for one interface.
public struct InterfaceCounters: Sendable, Equatable {
    public var receivedBytes: UInt64
    public var sentBytes: UInt64
    public var receivedPackets: UInt64
    public var sentPackets: UInt64

    public init(receivedBytes: UInt64, sentBytes: UInt64, receivedPackets: UInt64, sentPackets: UInt64) {
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
        self.receivedPackets = receivedPackets
        self.sentPackets = sentPackets
    }
}

/// One interface as read from the routing socket.
public struct InterfaceReading: Sendable, Equatable {
    public var index: UInt16
    public var name: String
    public var isUp: Bool
    public var isLoopback: Bool
    public var counters: InterfaceCounters

    public init(index: UInt16, name: String, isUp: Bool, isLoopback: Bool, counters: InterfaceCounters) {
        self.index = index
        self.name = name
        self.isUp = isUp
        self.isLoopback = isLoopback
        self.counters = counters
    }
}

/// Metrics for one network interface.
public struct InterfaceMetrics: Sendable, Equatable, Identifiable {
    public var name: String
    public var isUp: Bool
    public var isLoopback: Bool
    /// Totals since the interface came up (typically since boot).
    public var totals: InterfaceCounters
    /// `nil` on the first sample, after a gap, or when the counters reset.
    public var receivedBytesPerSecond: Double?
    public var sentBytesPerSecond: Double?

    public var id: String { name }

    public init(current: InterfaceReading, previous: InterfaceReading?, window: SampleWindow?) {
        name = current.name
        isUp = current.isUp
        isLoopback = current.isLoopback
        totals = current.counters
        guard let previous, let window, window.isValid,
            let received = Counter.delta(previous.counters.receivedBytes, current.counters.receivedBytes),
            let sent = Counter.delta(previous.counters.sentBytes, current.counters.sentBytes)
        else { return }
        receivedBytesPerSecond = Double(received) / window.elapsed
        sentBytesPerSecond = Double(sent) / window.elapsed
    }
}

/// Network metrics for one sample.
public struct NetworkMetrics: Sendable, Equatable {
    /// All interfaces, in kernel index order.
    public var interfaces: [InterfaceMetrics]
    /// BSD name of the interface carrying the default route (e.g. `en0`), if known.
    public var primaryInterface: String?

    public init(interfaces: [InterfaceMetrics], primaryInterface: String?) {
        self.interfaces = interfaces
        self.primaryInterface = primaryInterface
    }

    public subscript(name: String) -> InterfaceMetrics? {
        interfaces.first { $0.name == name }
    }

    /// The primary interface, or the busiest non-loopback interface that is up.
    public var preferred: InterfaceMetrics? {
        if let primaryInterface, let match = self[primaryInterface] { return match }
        return
            interfaces
            .filter { $0.isUp && !$0.isLoopback }
            .max { $0.totals.receivedBytes + $0.totals.sentBytes < $1.totals.receivedBytes + $1.totals.sentBytes }
    }
}
