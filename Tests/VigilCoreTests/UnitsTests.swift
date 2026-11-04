// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import Testing

@testable import VigilCore

@Suite struct UnitsTests {
    @Test func binaryBytes() {
        #expect(Units.bytes(512) == "512 B")
        #expect(Units.bytes(1_536) == "1.50 KiB")
        #expect(Units.bytes(51_539_607_552) == "48.0 GiB")
        #expect(Units.bytes(300 * 1_048_576) == "300 MiB")
    }

    @Test func decimalBytes() {
        #expect(Units.bytes(995_000_000_000, style: .decimal) == "995 GB")
        #expect(Units.bytes(1_500, style: .decimal) == "1.50 kB")
    }

    @Test func rates() {
        #expect(Units.rate(bytesPerSecond: 2_048) == "2.00 KiB/s")
        #expect(Units.rate(bytesPerSecond: 1_250_000, bits: true) == "10.0 Mb/s")
    }

    @Test func percentages() {
        #expect(Units.percent(0.3456) == "34.6%")
        #expect(Units.percent(-0.1) == "0.0%")
        #expect(Units.percent(.nan) == "—")
    }

    @Test func durations() {
        #expect(Units.duration(42) == "42s")
        #expect(Units.duration(5 * 60 + 3) == "5m 3s")
        #expect(Units.duration(3 * 3600 + 12 * 60) == "3h 12m")
        #expect(Units.duration(3 * 86_400 + 4 * 3600) == "3d 4h")
    }

    @Test func numbersAreLocaleIndependentAndPadded() {
        #expect(Units.number(2.5, decimals: 2) == "2.50")
        #expect(Units.number(0.049, decimals: 1) == "0.0")
        #expect(Units.number(9.996, decimals: 2) == "10.00")
        #expect(Units.number(3.7, decimals: 0) == "4")
    }
}
