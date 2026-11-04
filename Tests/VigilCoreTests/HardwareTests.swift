// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import Foundation
import Testing

@testable import VigilCore

@Suite struct BatteryReadingTests {
    let base = BatteryReading(
        currentCapacity: 80, maxCapacity: 100, isCharging: false, externalConnected: false, fullyCharged: false,
        timeRemaining: 192, cycleCount: 6, rawMaxCapacity: 8669, designCapacity: 8579, voltage: 12_358,
        amperage: -1_500, temperature: 2_079, adapterWatts: nil, adapterName: nil)

    @Test func derivesChargeHealthPowerAndTemperature() throws {
        let metrics = try #require(base.metrics)
        #expect(metrics.charge == 0.8)
        #expect(abs((metrics.health ?? 0) - 8669.0 / 8579.0) < 1e-9)  // a new battery can exceed 100 %
        #expect(abs((metrics.batteryPower ?? 0) - -18.537) < 0.001)  // 12.358 V × −1.5 A, discharging
        #expect(metrics.temperature == 20.79)
        #expect(metrics.minutesRemaining == 192)
    }

    @Test func stillEstimatingMeansNoTimeRemaining() throws {
        var reading = base
        reading.timeRemaining = 65_535
        #expect(try #require(reading.metrics).minutesRemaining == nil)
        reading.timeRemaining = 0
        #expect(try #require(reading.metrics).minutesRemaining == nil)
    }

    @Test func missingCapacityMeansNoBattery() {
        var reading = base
        reading.currentCapacity = nil
        #expect(reading.metrics == nil)
    }

    @Test func missingHealthDataIsNilNotZero() throws {
        var reading = base
        reading.designCapacity = nil
        #expect(try #require(reading.metrics).health == nil)
    }
}

@Suite struct TemperatureSensorTests {
    @Test func groupsDieBatteryAndSSDAndDropsSentinels() throws {
        let readings: [(name: String, celsius: Double)] = [
            ("PMU tdie1", 31), ("PMU tdie2", 35), ("PMU tdie3", 33),
            ("PMU tdev1", -9201.1),  // sentinel
            ("PMU tcal", 51.8),  // calibration, not a temperature
            ("gas gauge battery", 21), ("NAND CH0 temp", 26),
        ]
        let grouped = TemperatureSensors.aggregate(readings)
        let chip = try #require(grouped.chip)
        #expect(chip.maximum == 35)
        #expect(chip.average == 33)
        #expect(grouped.battery == 21)
        #expect(grouped.ssd == 26)
    }

    @Test func noDieSensorsMeansNoChipTemperature() {
        #expect(TemperatureSensors.aggregate([("NAND CH0 temp", 26)]).chip == nil)
    }
}

@Suite struct SMCValueTests {
    @Test func decodesAppleSiliconFloats() {
        let bytes = withUnsafeBytes(of: Float(1350).bitPattern.littleEndian) { Array($0) }
        #expect(SMCValue.decode(type: "flt ", bytes: bytes) == 1350)
    }

    @Test func decodesIntelFixedPoint() {
        #expect(SMCValue.decode(type: "fpe2", bytes: [0x17, 0x70]) == 1500)  // 6000 / 4
        #expect(SMCValue.decode(type: "sp78", bytes: [0x2a, 0x80]) == 42.5)
        #expect(SMCValue.decode(type: "sp78", bytes: [0xff, 0x00]) == -1)
    }

    @Test func decodesIntegersAndRejectsUnknown() {
        #expect(SMCValue.decode(type: "ui8 ", bytes: [2]) == 2)
        #expect(SMCValue.decode(type: "ui16", bytes: [0x01, 0x00]) == 256)
        #expect(SMCValue.decode(type: "ch8*", bytes: [1, 2]) == nil)
        #expect(SMCValue.decode(type: "flt ", bytes: [1, 2]) == nil)  // too short
    }

    @Test func fourCharacterCodesRoundTrip() {
        let code = SMCValue.fourCharacterCode("F0Ac")
        #expect(code == 0x4630_4163)
        #expect(SMCValue.string(code) == "F0Ac")
    }

    @Test func fanFraction() {
        #expect(Fan(rpm: 2_675, maximum: 5_350).fraction == 0.5)
        #expect(Fan(rpm: 100, maximum: nil).fraction == nil)
    }
}

@Suite(.serialized) struct HardwareIntegrationTests {
    @Test func publicHardwareReadingsAreSane() async {
        let sampler = Sampler(configuration: .init(interval: 2, demand: [.gpu, .battery, .sensors]))
        let snapshot = await sampler.sampleNow()
        if let gpu = snapshot.gpu?.primary {
            #expect((0...1).contains(gpu.utilization ?? 0))
        }
        if let battery = snapshot.battery {  // laptops only
            #expect((0...1).contains(battery.charge))
        }
        // Thermal state is always there; private sensors are off by default.
        #expect(snapshot.sensors != nil)
        #expect(snapshot.sensors?.chipTemperature == nil)
        #expect(snapshot.sensors?.fans == nil)
    }
}
