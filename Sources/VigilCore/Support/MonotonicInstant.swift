// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import Darwin

/// A point on a monotonic clock that keeps counting while the Mac sleeps
/// (`CLOCK_MONOTONIC` is `mach_continuous_time` in nanoseconds on Darwin).
///
/// Used for rate deltas so a sample pair spanning sleep has a truthful elapsed
/// time and can be recognized as a gap.
public struct MonotonicInstant: Sendable, Hashable, Comparable {
    public let nanoseconds: UInt64

    public init(nanoseconds: UInt64) { self.nanoseconds = nanoseconds }

    public static var now: MonotonicInstant {
        MonotonicInstant(nanoseconds: clock_gettime_nsec_np(CLOCK_MONOTONIC))
    }

    /// Seconds elapsed since `earlier`; zero if `earlier` is not actually earlier.
    public func seconds(since earlier: MonotonicInstant) -> Double {
        guard nanoseconds > earlier.nanoseconds else { return 0 }
        return Double(nanoseconds - earlier.nanoseconds) / 1_000_000_000
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.nanoseconds < rhs.nanoseconds }
}
