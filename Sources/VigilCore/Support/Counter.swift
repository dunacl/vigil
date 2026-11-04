// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

/// Delta math for monotonically increasing system counters.
///
/// A counter that goes *down* has been reset (interface re-created, driver
/// reloaded, reboot of a device). We never report a negative or wrapped-around
/// value for that pair: the caller gets `nil` and shows "—" for one tick.
enum Counter {
    /// Delta of a 64-bit counter, `nil` if it went backwards (reset).
    @inline(__always)
    static func delta(_ previous: UInt64, _ current: UInt64) -> UInt64? {
        current >= previous ? current - previous : nil
    }

    /// Delta of a 32-bit counter that legitimately wraps (e.g. Mach CPU ticks).
    ///
    /// Wrapping subtraction handles a single wrap. A delta over half the range
    /// cannot be a real advance within one sample interval, so it is a reset.
    @inline(__always)
    static func wrappingDelta(_ previous: UInt32, _ current: UInt32) -> UInt32? {
        let delta = current &- previous
        return delta <= UInt32.max / 2 ? delta : nil
    }
}

/// Decides whether a pair of samples is close enough in time to produce rates.
///
/// After sleep, an App Nap, or a stalled main thread the elapsed time can be far
/// longer than the configured interval. Averaging over that gap would show a
/// misleading flat value, so such pairs are dropped and the next tick starts fresh.
public struct SampleWindow: Sendable, Equatable {
    /// Elapsed seconds between the two samples.
    public let elapsed: Double

    /// `true` when the pair is usable for rates.
    public let isValid: Bool

    public init(previous: MonotonicInstant, current: MonotonicInstant, expectedInterval: Double) {
        elapsed = current.seconds(since: previous)
        let maximum = max(expectedInterval * 3, expectedInterval + 2)
        isValid = elapsed > 0.05 && elapsed <= maximum
    }
}
