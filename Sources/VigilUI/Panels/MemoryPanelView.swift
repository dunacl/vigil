// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import AppKit
import VigilCore

/// Memory: used fraction and history, pressure badge; Medium adds the
/// app/wired/compressed/cached composition and swap.
final class MemoryPanelView: LayerPanelView {
    private static let segmentNames = ["App", "Wired", "Compr.", "Cached"]

    private let value: TextLayer
    private let detail: TextLayer
    private let pressureDot = DotLayer()
    private var pressureColor: NSColor = .clear
    private let graph: GraphLayer
    private let composition: SegmentedBarLayer
    private let segmentColors: [NSColor]
    private var legendDots: [DotLayer] = []
    private var legendTexts: [TextLayer] = []
    private let swap: TextLayer

    init(store: MetricsStore, sizeClass: SizeClass, style: PanelStyle) {
        value = TextLayer(sizeClass == .extraSmall ? .headlineSmall : .headline)
        detail = TextLayer(.caption, color: .secondaryLabelColor)
        swap = TextLayer(.caption, color: .secondaryLabelColor)
        let palette = PanelPalette.make(style.appearance.theme)
        graph = GraphLayer([.utilization], style: style.appearance.graphStyle, palette: palette)
        segmentColors = [palette.memoryApp, palette.memoryWired, palette.memoryCompressed, palette.memoryCached]
        composition = SegmentedBarLayer(colors: segmentColors, track: palette.track)
        super.init(title: "Memory", store: store, sizeClass: sizeClass, style: style)
        [value, detail].forEach(add)
        add(pressureDot)
        add(graph)
        if sizeClass == .medium {
            add(composition)
            for _ in Self.segmentNames {
                let dot = DotLayer()
                add(dot)
                legendDots.append(dot)
                legendTexts.append(text(.caption, color: .secondaryLabelColor))
            }
            add(swap)
        }
    }

    override func layoutBody(in rect: CGRect) {
        if sizeClass == .extraSmall {
            detail.isHidden = true
            layoutTile(value: value, graph: graph, in: rect)
            return
        }
        let valueHeight = value.lineHeight
        value.frame = CGRect(x: rect.minX, y: rect.minY - 4, width: 66, height: valueHeight)
        let captionY = rect.minY + valueHeight - 4 - detail.lineHeight - 4
        detail.frame = CGRect(x: rect.minX + 66, y: captionY, width: rect.width - 66, height: detail.lineHeight)
        var bottom = rect.maxY
        if sizeClass == .medium {
            let line = swap.lineHeight
            swap.frame = CGRect(x: rect.minX, y: bottom - line, width: rect.width, height: line)
            bottom -= line + 2
            let legendY = bottom - line
            let column = rect.width / CGFloat(Self.segmentNames.count)
            for index in legendTexts.indices {
                let x = rect.minX + CGFloat(index) * column
                legendDots[index].frame = CGRect(x: x, y: legendY + (line - 6) / 2, width: 6, height: 6)
                legendTexts[index].frame = CGRect(x: x + 9, y: legendY, width: column - 10, height: line)
            }
            bottom = legendY - 4
            composition.frame = CGRect(x: rect.minX, y: bottom - 6, width: rect.width, height: 6)
            bottom -= 6 + Self.rowGap
        }
        let graphTop = rect.minY + valueHeight
        graph.frame = CGRect(x: rect.minX, y: graphTop, width: rect.width, height: bottom - graphTop)
        pressureDot.frame = .zero  // repositioned next to the label on the next update
    }

    override func update() {
        withoutAnimation {
            graph.update([store.memoryHistory], capacity: store.historyLength, ceiling: 1)
            guard let memory = store.memory else {
                value.text = Self.pending
                return
            }
            let bytes = { (value: UInt64) in Units.bytes(Double(value), style: self.units.bytes) }
            value.text = Units.percent(memory.usedFraction, decimals: 0)
            detail.text =
                sizeClass == .medium
                ? "\(bytes(memory.usedBytes)) of \(bytes(memory.totalBytes))" : bytes(memory.usedBytes)
            updatePressure(memory.pressure)
            guard sizeClass == .medium else { return }
            let total = Double(max(memory.totalBytes, 1))
            let parts = [memory.appBytes, memory.wiredBytes, memory.compressedBytes, memory.cachedBytes]
            composition.update(parts.map { Double($0) / total })
            for index in legendTexts.indices {
                legendTexts[index].text = "\(Self.segmentNames[index]) \(bytes(parts[index]))"
            }
            swap.text =
                memory.swapUsedBytes > 0 ? "Swap \(bytes(memory.swapUsedBytes)) of \(bytes(memory.swapTotalBytes))" : ""
        }
    }

    private func updatePressure(_ pressure: MemoryPressure) {
        let (label, color): (String, NSColor) =
            switch pressure {
            case .normal: ("Normal", palette.calm)
            case .warning: ("Warning", palette.warm)
            case .critical: ("Critical", palette.hot)
            case .unknown: ("—", .clear)
            }
        guard label != accessory.text || pressureDot.frame.isEmpty else { return }
        accessory.text = label
        pressureColor = color
        pressureDot.backgroundColor = resolved(color, in: effectiveAppearance)
        let x = accessory.frame.maxX - accessory.textWidth - 10
        pressureDot.frame = CGRect(x: x, y: accessory.frame.midY - 3, width: 6, height: 6)
    }

    /// The kernel's own memory-pressure level, not a percentage.
    override func currentAlertLevel() -> AlertLevel {
        store.memory.map { ThresholdEvaluator.level(memoryPressure: $0.pressure) } ?? .normal
    }

    override func accessibilitySummary() -> String {
        guard let memory = store.memory else { return "Memory unavailable" }
        return "Memory \(Units.percent(memory.usedFraction, decimals: 0)) used, pressure \(accessory.text)"
    }

    override func resolveColors(in appearance: NSAppearance) {
        graph.resolveColors(in: appearance)
        composition.resolveColors(in: appearance)
        pressureDot.backgroundColor = resolved(pressureColor, in: appearance)
        for (dot, color) in zip(legendDots, segmentColors) { dot.backgroundColor = resolved(color, in: appearance) }
    }
}
