// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

/// One GPU's statistics (IOAccelerator `PerformanceStatistics`).
public struct GPUDevice: Sendable, Equatable {
    public var name: String
    public var cores: Int?
    /// 0…1. `nil` when the driver doesn't report it.
    public var utilization: Double?
    public var rendererUtilization: Double?
    public var tilerUtilization: Double?
    /// GPU memory in use (on Apple Silicon, unified memory used by the GPU), bytes.
    public var memoryInUse: UInt64?

    public init(
        name: String, cores: Int? = nil, utilization: Double? = nil, rendererUtilization: Double? = nil,
        tilerUtilization: Double? = nil, memoryInUse: UInt64? = nil
    ) {
        self.name = name
        self.cores = cores
        self.utilization = utilization
        self.rendererUtilization = rendererUtilization
        self.tilerUtilization = tilerUtilization
        self.memoryInUse = memoryInUse
    }
}

public struct GPUMetrics: Sendable, Equatable {
    public var devices: [GPUDevice]
    public init(devices: [GPUDevice]) { self.devices = devices }
    /// The first (on Apple Silicon, the only) GPU.
    public var primary: GPUDevice? { devices.first }
}

/// Battery and power adapter (AppleSmartBattery). `nil` metrics = no battery.
public struct BatteryMetrics: Sendable, Equatable {
    /// 0…1.
    public var charge: Double
    public var isCharging: Bool
    public var isPluggedIn: Bool
    public var isFullyCharged: Bool
    /// Minutes until empty (on battery) or full (charging); `nil` while macOS is estimating.
    public var minutesRemaining: Int?
    public var cycleCount: Int?
    /// Full-charge capacity relative to design capacity (can exceed 1 when new).
    public var health: Double?
    /// Watts into (+) or out of (−) the battery.
    public var batteryPower: Double?
    public var temperature: Double?
    public var adapterWatts: Int?
    public var adapterName: String?

    public init(
        charge: Double, isCharging: Bool, isPluggedIn: Bool, isFullyCharged: Bool, minutesRemaining: Int? = nil,
        cycleCount: Int? = nil, health: Double? = nil, batteryPower: Double? = nil, temperature: Double? = nil,
        adapterWatts: Int? = nil, adapterName: String? = nil
    ) {
        self.charge = charge
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.isFullyCharged = isFullyCharged
        self.minutesRemaining = minutesRemaining
        self.cycleCount = cycleCount
        self.health = health
        self.batteryPower = batteryPower
        self.temperature = temperature
        self.adapterWatts = adapterWatts
        self.adapterName = adapterName
    }
}

/// macOS's own thermal pressure level (`ProcessInfo.thermalState`); always available.
public enum ThermalLevel: Int, Sendable, Comparable {
    case nominal, fair, serious, critical
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct Fan: Sendable, Equatable {
    public var rpm: Double
    public var maximum: Double?
    /// 0…1 of the maximum, if known.
    public var fraction: Double? { maximum.flatMap { $0 > 0 ? min(rpm / $0, 1) : nil } }

    public init(rpm: Double, maximum: Double?) {
        self.rpm = rpm
        self.maximum = maximum
    }
}

/// Thermal state, plus — when the user turns on sensor reading — temperatures,
/// fans and power from undocumented interfaces (SPEC §11). Each of those is
/// `nil` when off, unavailable on this Mac, or failing.
public struct SensorMetrics: Sendable, Equatable {
    public var thermal: ThermalLevel
    /// Hottest and average of the chip's die sensors, °C.
    public var chipTemperature: (maximum: Double, average: Double)?
    public var batteryTemperature: Double?
    public var ssdTemperature: Double?
    public var fans: [Fan]?
    /// Whole-system power draw, watts (SMC `PSTR`).
    public var systemPower: Double?
    /// Power coming in from the adapter, watts (SMC `PDTR`).
    public var powerIn: Double?

    public init(
        thermal: ThermalLevel, chipTemperature: (maximum: Double, average: Double)? = nil,
        batteryTemperature: Double? = nil, ssdTemperature: Double? = nil, fans: [Fan]? = nil,
        systemPower: Double? = nil, powerIn: Double? = nil
    ) {
        self.thermal = thermal
        self.chipTemperature = chipTemperature
        self.batteryTemperature = batteryTemperature
        self.ssdTemperature = ssdTemperature
        self.fans = fans
        self.systemPower = systemPower
        self.powerIn = powerIn
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.thermal == rhs.thermal && lhs.chipTemperature?.maximum == rhs.chipTemperature?.maximum
            && lhs.chipTemperature?.average == rhs.chipTemperature?.average
            && lhs.batteryTemperature == rhs.batteryTemperature && lhs.ssdTemperature == rhs.ssdTemperature
            && lhs.fans == rhs.fans && lhs.systemPower == rhs.systemPower && lhs.powerIn == rhs.powerIn
    }
}

// MARK: - Pure helpers (tested)

/// Raw battery registry values, as read (SPEC §5 "Battery").
struct BatteryReading: Sendable, Equatable {
    var currentCapacity: Int?
    var maxCapacity: Int?
    var isCharging: Bool
    var externalConnected: Bool
    var fullyCharged: Bool
    var timeRemaining: Int?
    var cycleCount: Int?
    var rawMaxCapacity: Int?
    var designCapacity: Int?
    /// mV, mA (signed), and hundredths of a degree Celsius.
    var voltage: Int?
    var amperage: Int?
    var temperature: Int?
    var adapterWatts: Int?
    var adapterName: String?

    var metrics: BatteryMetrics? {
        guard let current = currentCapacity, let maximum = maxCapacity, maximum > 0 else { return nil }
        let power = voltage.flatMap { volts in amperage.map { Double(volts) * Double($0) / 1_000_000 } }
        let health = rawMaxCapacity.flatMap { raw in designCapacity.flatMap { $0 > 0 ? Double(raw) / Double($0) : nil }
        }
        // 65535 means "still estimating"; 0 is meaningless unless charging finished.
        let minutes = timeRemaining.flatMap { $0 > 0 && $0 < 65535 ? $0 : nil }
        return BatteryMetrics(
            charge: min(max(Double(current) / Double(maximum), 0), 1), isCharging: isCharging,
            isPluggedIn: externalConnected, isFullyCharged: fullyCharged, minutesRemaining: minutes,
            cycleCount: cycleCount, health: health, batteryPower: power,
            temperature: temperature.map { Double($0) / 100 }, adapterWatts: adapterWatts, adapterName: adapterName)
    }
}

enum TemperatureSensors {
    /// Groups raw HID readings into chip (die sensors), battery and SSD. Values
    /// outside −20…150 °C are sensor sentinels (e.g. −9201) and are dropped;
    /// calibration sensors ("tcal") aren't temperatures of anything.
    static func aggregate(_ readings: [(name: String, celsius: Double)])
        -> (chip: (maximum: Double, average: Double)?, battery: Double?, ssd: Double?)
    {
        let valid = readings.filter { $0.celsius > -20 && $0.celsius < 150 && !$0.name.contains("tcal") }
        let die = valid.filter { $0.name.contains("tdie") }.map(\.celsius)
        let chip = die.isEmpty ? nil : (die.max() ?? 0, die.reduce(0, +) / Double(die.count))
        func average(_ matches: (String) -> Bool) -> Double? {
            let values = valid.filter { matches($0.name.lowercased()) }.map(\.celsius)
            return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        return (chip, average { $0.contains("battery") }, average { $0.contains("nand") || $0.contains("ssd") })
    }
}

/// Plausible ranges for readings from undocumented interfaces; anything else is
/// a garbage value and is dropped rather than shown (or crashing a conversion).
enum SensorRange {
    static func watts(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 >= 0 && $0 < 2_000 ? $0 : nil }
    }

    static func rpm(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 >= 0 && $0 < 20_000 ? $0 : nil }
    }
}

enum SMCValue {
    /// Decodes an SMC value by its four-character type.
    static func decode(type: String, bytes: [UInt8]) -> Double? {
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })  // little-endian on Apple Silicon
        case "fpe2":  // unsigned 14.2 fixed point, big-endian (Intel fans)
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "sp78":  // signed 7.8 fixed point, big-endian (Intel temperatures)
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "ui8 ":
            return bytes.first.map(Double.init)
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        default:
            return nil
        }
    }

    static func fourCharacterCode(_ text: String) -> UInt32 {
        text.utf8.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    static func string(_ code: UInt32) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }, as: UTF8.self)
    }
}
