// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import AppKit
import VigilCore

/// A panel with a big value, a caption, a history graph and (Medium) a few
/// labeled lines — the shape GPU, Battery and Thermals share.
class ValueGraphPanelView: LayerPanelView {
    let value: TextLayer
    let caption: TextLayer
    let graph: GraphLayer
    var lines: [TextLayer] = []

    /// Lines shown under the graph at Medium size.
    var lineCount: Int { 2 }

    init(title: String, fill: GraphLayer.Fill, store: MetricsStore, sizeClass: SizeClass, style: PanelStyle) {
        value = TextLayer(sizeClass == .extraSmall ? .headlineSmall : .headline)
        caption = TextLayer(.caption, color: .secondaryLabelColor)
        graph = GraphLayer(
            [fill], style: style.appearance.graphStyle, palette: PanelPalette.make(style.appearance.theme))
        super.init(title: title, store: store, sizeClass: sizeClass, style: style)
        [value, caption].forEach(add)
        add(graph)
        if sizeClass == .medium {
            for _ in 0..<lineCount { lines.append(text(.caption, color: .secondaryLabelColor)) }
        }
    }

    override func layoutBody(in rect: CGRect) {
        if sizeClass == .extraSmall {
            caption.isHidden = true
            layoutTile(value: value, graph: graph, in: rect)
            return
        }
        let valueHeight = value.lineHeight
        value.frame = CGRect(x: rect.minX, y: rect.minY - 4, width: 92, height: valueHeight)
        let captionY = rect.minY + valueHeight - 4 - caption.lineHeight - 4
        caption.frame = CGRect(x: rect.minX + 94, y: captionY, width: rect.width - 94, height: caption.lineHeight)
        if sizeClass == .small {
            // Small: the caption goes under the value instead of beside it.
            caption.frame = CGRect(
                x: rect.minX, y: rect.minY + valueHeight - 4, width: rect.width, height: caption.lineHeight)
        }
        var bottom = rect.maxY
        for line in lines.reversed() {
            line.frame = CGRect(x: rect.minX, y: bottom - line.lineHeight, width: rect.width, height: line.lineHeight)
            bottom -= line.lineHeight + 1
        }
        let graphTop = rect.minY + valueHeight + (sizeClass == .small ? caption.lineHeight - 2 : 0)
        graph.frame = CGRect(x: rect.minX, y: graphTop, width: rect.width, height: max(bottom - graphTop - 3, 1))
    }

    override func resolveColors(in appearance: NSAppearance) { graph.resolveColors(in: appearance) }
}

// MARK: - GPU

final class GPUPanelView: ValueGraphPanelView {
    init(store: MetricsStore, sizeClass: SizeClass, style: PanelStyle) {
        super.init(title: "GPU", fill: .utilization, store: store, sizeClass: sizeClass, style: style)
    }

    override func update() {
        withoutAnimation {
            graph.update([store.gpuHistory], capacity: store.historyLength, ceiling: 1)
            guard let gpu = store.gpu?.primary else {
                value.text = Self.pending
                caption.text = store.gpu == nil ? "" : "No GPU statistics"
                return
            }
            if sizeClass == .medium {
                accessory.text =
                    gpu.name.replacingOccurrences(of: "Apple ", with: "")
                    + (gpu.cores.map { " · \($0) cores" } ?? "")
            }
            value.text = gpu.utilization.map { Units.percent($0, decimals: 0) } ?? Self.pending
            caption.text = gpu.memoryInUse.map { "\(Units.bytes(Double($0), style: units.bytes)) in use" } ?? ""
            guard lines.count == 2 else { return }
            lines[0].text =
                "Rendering \(gpu.rendererUtilization.map { Units.percent($0, decimals: 0) } ?? "—")"
                + "   Geometry \(gpu.tilerUtilization.map { Units.percent($0, decimals: 0) } ?? "—")"
            lines[1].text = ""
        }
    }

    /// Sustained load, with the same levels as CPU.
    override func currentAlertLevel() -> AlertLevel {
        let thresholds = style.thresholds
        let samples = thresholds.sustainSamples(interval: store.sampleInterval)
        return ThresholdEvaluator.level(
            history: store.gpuHistory, warning: thresholds.cpuWarning, critical: thresholds.cpuCritical,
            samples: samples)
    }

    override func accessibilitySummary() -> String {
        store.gpu?.primary?.utilization.map { "GPU \(Units.percent($0, decimals: 0))" } ?? "GPU unavailable"
    }
}

// MARK: - Battery

final class BatteryPanelView: ValueGraphPanelView {
    init(store: MetricsStore, sizeClass: SizeClass, style: PanelStyle) {
        super.init(title: "Battery", fill: .utilization, store: store, sizeClass: sizeClass, style: style)
    }

    override func update() {
        withoutAnimation {
            graph.update([store.batteryHistory], capacity: store.historyLength, ceiling: 1)
            guard let battery = store.battery else {
                value.text = Self.pending
                caption.text = "This Mac has no battery"
                return
            }
            value.text = Units.percent(battery.charge, decimals: 0)
            caption.text = Self.state(battery)
            if sizeClass == .medium {
                accessory.text = battery.adapterWatts.map { "\($0) W adapter" } ?? ""
            }
            guard lines.count == 2 else { return }
            var health: [String] = []
            if let value = battery.health { health.append("Health \(Units.percent(min(value, 1), decimals: 0))") }
            if let cycles = battery.cycleCount { health.append("\(cycles) cycles") }
            if let temperature = battery.temperature { health.append(Units.number(temperature, decimals: 0) + " °C") }
            lines[0].text = health.joined(separator: "   ")
            lines[1].text =
                battery.batteryPower.map { power in
                    abs(power) < 0.05
                        ? "Battery idle"
                        : (power > 0 ? "Charging at " : "Drawing ") + Units.number(abs(power), decimals: 1)
                            + " W"
                } ?? ""
        }
    }

    static func state(_ battery: BatteryMetrics) -> String {
        let time = battery.minutesRemaining.map { Units.duration(Double($0) * 60) }
        if battery.isFullyCharged { return "Fully charged" }
        if battery.isCharging { return time.map { "Charging · \($0) to full" } ?? "Charging" }
        if battery.isPluggedIn { return "Plugged in, not charging" }
        return time.map { "\($0) left" } ?? "On battery"
    }

    /// Low charge while unplugged.
    override func currentAlertLevel() -> AlertLevel {
        guard let battery = store.battery, !battery.isPluggedIn else { return .normal }
        return battery.charge <= 0.05 ? .critical : battery.charge <= 0.10 ? .warning : .normal
    }

    override func accessibilitySummary() -> String {
        store.battery.map { "Battery \(Units.percent($0.charge, decimals: 0)), \(Self.state($0))" } ?? "No battery"
    }
}

// MARK: - Thermals

final class ThermalsPanelView: ValueGraphPanelView {
    override var lineCount: Int { 3 }

    init(store: MetricsStore, sizeClass: SizeClass, style: PanelStyle) {
        super.init(title: "Thermals", fill: .utilization, store: store, sizeClass: sizeClass, style: style)
    }

    override func update() {
        withoutAnimation {
            // Chip temperature graph: 0–100 °C mapped to the utilization gradient.
            graph.update([store.chipTemperatureHistory], capacity: store.historyLength, ceiling: 100)
            guard let sensors = store.sensors else {
                value.text = Self.pending
                return
            }
            let level = Self.name(sensors.thermal)
            accessory.text = sizeClass == .medium ? "macOS: \(level)" : ""
            if let chip = sensors.chipTemperature {
                value.text = Units.number(chip.maximum, decimals: 0) + "°"
                caption.text = "Chip, hottest · avg \(Units.number(chip.average, decimals: 0))°"
            } else {
                value.text = level
                caption.text = "Thermal pressure"
            }
            guard !lines.isEmpty else { return }
            guard sensors.chipTemperature != nil || sensors.fans != nil || sensors.systemPower != nil else {
                lines[0].text = "Temperatures, fans and power:"
                lines[1].text = "Settings → General → Read sensors"
                lines[2].text = ""
                return
            }
            lines[0].text =
                sensors.fans.map { fans in
                    fans.isEmpty
                        ? "No fans"
                        : fans.enumerated().map { "Fan \($0.offset + 1) \(Int($0.element.rpm)) rpm" }.joined(
                            separator: "   ")
                } ?? ""
            var power: [String] = []
            if let system = sensors.systemPower { power.append("System \(Units.number(system, decimals: 1)) W") }
            if let input = sensors.powerIn, input > 0.5 {
                power.append("From adapter \(Units.number(input, decimals: 1)) W")
            }
            lines[1].text = power.joined(separator: "   ")
            var others: [String] = []
            if let ssd = sensors.ssdTemperature { others.append("SSD \(Units.number(ssd, decimals: 0))°") }
            if let battery = sensors.batteryTemperature {
                others.append("Battery \(Units.number(battery, decimals: 0))°")
            }
            lines[2].text = others.joined(separator: "   ")
        }
    }

    static func name(_ level: ThermalLevel) -> String {
        switch level {
        case .nominal: "Normal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        }
    }

    /// macOS's own thermal pressure, which is what actually slows the Mac down.
    override func currentAlertLevel() -> AlertLevel {
        switch store.sensors?.thermal {
        case .serious: .warning
        case .critical: .critical
        default: .normal
        }
    }

    override func accessibilitySummary() -> String {
        guard let sensors = store.sensors else { return "Thermals unavailable" }
        let temperature = sensors.chipTemperature.map { ", chip \(Int($0.maximum)) degrees" } ?? ""
        return "Thermal pressure \(Self.name(sensors.thermal))\(temperature)"
    }
}

// MARK: - System Info

final class SystemInfoPanelView: LayerPanelView {
    private var rows: [(label: TextLayer, value: TextLayer)] = []

    init(store: MetricsStore, sizeClass: SizeClass, style: PanelStyle) {
        super.init(title: "This Mac", store: store, sizeClass: sizeClass, style: style)
        let count = sizeClass == .medium ? 6 : sizeClass == .small ? 4 : 2
        for _ in 0..<count {
            rows.append((text(.caption, color: .secondaryLabelColor), text(.caption, alignment: .right)))
        }
    }

    override func layoutBody(in rect: CGRect) {
        let line = rows.first?.label.lineHeight ?? 13
        let step = max(line, min(line + 5, rect.height / CGFloat(max(rows.count, 1))))
        for (index, row) in rows.enumerated() {
            let y = rect.minY + CGFloat(index) * step
            row.label.frame = CGRect(x: rect.minX, y: y, width: 70, height: line)
            row.value.frame = CGRect(x: rect.minX + 70, y: y, width: rect.width - 70, height: line)
        }
    }

    override func update() {
        withoutAnimation {
            let system = store.system
            let memory = Units.bytes(Double(system.memoryBytes), style: units.bytes)
            let all: [(String, String)] = [
                ("macOS", system.osVersion + (sizeClass == .medium ? system.osBuild.map { " (\($0))" } ?? "" : "")),
                ("Uptime", Units.duration(system.uptime)),
                ("Chip", system.cpu.brand.replacingOccurrences(of: "Apple ", with: "")),
                ("Memory", memory),
                ("Model", system.model),
                ("Name", system.hostName.replacingOccurrences(of: ".local", with: "")),
            ]
            for (row, item) in zip(rows, all) {
                row.label.text = item.0
                row.value.text = item.1
            }
        }
    }

    override func accessibilitySummary() -> String {
        "\(store.system.model), macOS \(store.system.osVersion), up \(Units.duration(store.system.uptime))"
    }
}
