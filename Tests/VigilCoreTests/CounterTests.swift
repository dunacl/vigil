// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import Testing

@testable import VigilCore

@Suite struct CounterTests {
    @Test func deltaOfIncreasingCounter() {
        #expect(Counter.delta(100, 250) == 150)
        #expect(Counter.delta(7, 7) == 0)
    }

    @Test func counterGoingBackwardsIsAReset() {
        #expect(Counter.delta(1_000, 10) == nil)
    }

    @Test func wrappingDeltaHandlesOneWrap() {
        #expect(Counter.wrappingDelta(UInt32.max - 9, 20) == 30)
    }

    @Test func implausiblyLargeWrappingDeltaIsAReset() {
        // Going from 1,000 to 10 would be a ~4-billion-tick advance: a reset, not a wrap.
        #expect(Counter.wrappingDelta(1_000, 10) == nil)
    }
}

@Suite struct SampleWindowTests {
    let start = MonotonicInstant(nanoseconds: 1_000_000_000_000)

    func at(_ seconds: Double) -> MonotonicInstant {
        MonotonicInstant(nanoseconds: start.nanoseconds + UInt64(seconds * 1_000_000_000))
    }

    @Test func regularIntervalIsValid() {
        let window = SampleWindow(previous: start, current: at(2), expectedInterval: 2)
        #expect(window.isValid)
        #expect(abs(window.elapsed - 2) < 1e-9)
    }

    @Test func gapAfterSleepIsInvalid() {
        #expect(!SampleWindow(previous: start, current: at(3600), expectedInterval: 2).isValid)
    }

    @Test func timeGoingBackwardsIsInvalid() {
        #expect(!SampleWindow(previous: at(5), current: start, expectedInterval: 2).isValid)
    }

    @Test func tooShortToMeasureIsInvalid() {
        #expect(!SampleWindow(previous: start, current: at(0.01), expectedInterval: 2).isValid)
    }

    @Test func shortIntervalsStillTolerateSomeJitter() {
        // At 0.5 s, a 2.4 s pair is still acceptable (interval + 2 s slack).
        #expect(SampleWindow(previous: start, current: at(2.4), expectedInterval: 0.5).isValid)
    }
}
