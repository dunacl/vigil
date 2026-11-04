// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import AppKit
import VigilCore

/// CPU: overall load and history; Medium adds user/system split, load average,
/// and per-core bars grouped by the Mac's performance tiers.
final class CPUPanelView: LayerPanelView {
    private let value: TextLayer
    private let detail: TextLayer
    private let load: TextLayer
    private let graph: GraphLayer
    private var tierNames: [TextLayer] = []
    private var tierValues: [TextLayer] = []
    private var tierBars: [CoreBarsLayer] = []

    init(store: MetricsStore, sizeClass: SizeClass, style: PanelStyle) {
        value = TextLayer(sizeClass == .extraSmall ? .headlineSmall : .headline)
        detail = TextLayer(.caption, color: .secondaryLabelColor)
        load = TextLayer(.caption, color: .secondaryLabelColor, alignment: .right)
        let palette = PanelPalette.make(style.appearance.theme)
        graph = GraphLayer([.utilization], style: style.appearance.graphStyle, palette: palette)
        super.init(title: "CPU", store: store, sizeClass: sizeClass, style: style)
        [value, detail, load].forEach(add)
        add(graph)
        if sizeClass == .medium {
            accessory.text = store.system.cpu.brand.replacingOccurrences(of: "Apple ", with: "")
            for tier in store.system.cpu.tiers {
                let name = text(.caption, color: .secondaryLabelColor)
                name.text = tier.name
                tierNames.append(name)
                tierValues.append(text(.caption, alignment: .right))
                let bars = CoreBarsLayer(count: tier.cores.count, palette: palette)
                add(bars)
                tierBars.append(bars)
            }
        } else {
            detail.isHidden = true
            load.isHidden = true
        }
    }

    override func layoutBody(in rect: CGRect) {
        if sizeClass == .extraSmall {
            layoutTile(value: value, graph: graph, in: rect)
            return
        }
        let valueHeight = value.lineHeight
        value.frame = CGRect(x: rect.minX, y: rect.minY - 4, width: 80, height: valueHeight)
        var graphTop = rect.minY + valueHeight - 2
        if sizeClass == .medium {
            let captionY = rect.minY + valueHeight - 4 - detail.lineHeight - 4
            detail.frame = CGRect(x: rect.minX + 66, y: captionY, width: 140, height: detail.lineHeight)
            load.frame = CGRect(x: rect.maxX - 90, y: captionY, width: 90, height: load.lineHeight)
            graphTop += 2
        }
        let rowHeight: CGFloat = 12
        let tiersHeight = CGFloat(tierBars.count) * (rowHeight + Self.rowGap)
        graph.frame = CGRect(x: rect.minX, y: graphTop, width: rect.width, height: rect.maxY - graphTop - tiersHeight)
        for index in tierBars.indices {
            let y =
                rect.maxY - CGFloat(tierBars.count - index) * rowHeight - CGFloat(tierBars.count - 1 - index)
                * Self.rowGap
            tierNames[index].frame = CGRect(x: rect.minX, y: y - 1, width: 76, height: rowHeight + 2)
            tierValues[index].frame = CGRect(x: rect.maxX - 34, y: y - 1, width: 34, height: rowHeight + 2)
            tierBars[index].frame = CGRect(x: rect.minX + 80, y: y, width: rect.width - 80 - 40, height: rowHeight)
        }
    }

    override func update() {
        withoutAnimation {
            graph.update([store.cpuHistory], capacity: store.historyLength, ceiling: 1)
            guard let cpu = store.cpu else {
                value.text = Self.pending
                return
            }
            value.text = Units.percent(cpu.overall.total, decimals: 0)
            guard sizeClass == .medium else { return }
            detail.text =
                "usr \(Units.percent(cpu.overall.user, decimals: 0))  sys \(Units.percent(cpu.overall.system, decimals: 0))"
            load.text = "load \(Units.number(cpu.loadAverage.one, decimals: 2))"
            for (index, tier) in store.system.cpu.tiers.enumerated() {
                tierValues[index].text = Units.percent(cpu.average(of: tier.cores).total, decimals: 0)
                tierBars[index].update(cpu.cores[tier.cores.clamped(to: cpu.cores.indices)])
            }
        }
    }

    /// Sustained load: every sample over the last `sustainSeconds` above the level.
    override func currentAlertLevel() -> AlertLevel {
        let thresholds = style.thresholds
        let samples = thresholds.sustainSamples(interval: store.sampleInterval)
        return ThresholdEvaluator.level(
            history: store.cpuHistory, warning: thresholds.cpuWarning, critical: thresholds.cpuCritical,
            samples: samples)
    }

    override func accessibilitySummary() -> String {
        store.cpu.map { "CPU \(Units.percent($0.overall.total, decimals: 0))" } ?? "CPU unavailable"
    }

    override func resolveColors(in appearance: NSAppearance) {
        graph.resolveColors(in: appearance)
        for bars in tierBars { bars.resolveColors(in: appearance) }
    }
}
