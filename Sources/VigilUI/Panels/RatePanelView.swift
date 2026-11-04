// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import AppKit
import VigilCore

/// Two rates with a shared auto-scaling graph (btop style). Used for Network
/// (download/upload) and Disk (read/write); Medium adds totals or volumes.
final class RatePanelView: LayerPanelView {
    /// What a rate panel shows; pure reads of the store.
    struct Source {
        var symbols: (String, String)
        var colors: (NSColor, NSColor)
        /// Network rates may be shown in bits; disk rates never are.
        var allowsBits: Bool
        var rates: @MainActor (MetricsStore) -> (Double, Double)?
        var histories: @MainActor (MetricsStore) -> (RingBuffer<Float>, RingBuffer<Float>)
        var accessory: @MainActor (MetricsStore, SizeClass) -> String
        var volumes: Bool
        var accessibilityName: String
    }

    private let source: Source
    private let symbols: (TextLayer, TextLayer)
    private let values: (TextLayer, TextLayer)
    private let ceilingLabel: TextLayer
    private let graph: GraphLayer
    private let footer: TextLayer
    private var volumeNames: [TextLayer] = []
    private var volumeBars: [SegmentedBarLayer] = []
    private var volumeFree: [TextLayer] = []

    private init(title: String, source: Source, store: MetricsStore, sizeClass: SizeClass, style: PanelStyle) {
        self.source = source
        let valueStyle: TextLayer.Style = sizeClass == .medium ? .body : .caption
        symbols = (TextLayer(valueStyle, color: source.colors.0), TextLayer(valueStyle, color: source.colors.1))
        values = (TextLayer(valueStyle), TextLayer(valueStyle))
        ceilingLabel = TextLayer(.caption, color: .tertiaryLabelColor, alignment: .right)
        let palette = PanelPalette.make(style.appearance.theme)
        graph = GraphLayer(
            [.rate(source.colors.0), .rate(source.colors.1)], style: style.appearance.graphStyle, palette: palette)
        footer = TextLayer(.caption, color: .secondaryLabelColor)
        super.init(title: title, store: store, sizeClass: sizeClass, style: style)
        symbols.0.text = source.symbols.0
        symbols.1.text = source.symbols.1
        [symbols.0, symbols.1, values.0, values.1].forEach(add)
        add(graph)
        if sizeClass == .medium {
            add(ceilingLabel)
            add(footer)
            if source.volumes {
                for _ in 0..<2 {
                    volumeNames.append(text(.caption, color: .secondaryLabelColor))
                    let bar = SegmentedBarLayer(colors: [palette.calm], track: palette.track)
                    add(bar)
                    volumeBars.append(bar)
                    volumeFree.append(text(.caption, color: .secondaryLabelColor, alignment: .right))
                }
            }
        }
    }

    static func network(store: MetricsStore, sizeClass: SizeClass, style: PanelStyle) -> RatePanelView {
        let palette = PanelPalette.make(style.appearance.theme)
        return RatePanelView(
            title: "Network",
            source: Source(
                symbols: ("↓", "↑"), colors: (palette.receive, palette.send), allowsBits: true,
                rates: { store in
                    guard let preferred = store.network?.preferred, let received = preferred.receivedBytesPerSecond,
                        let sent = preferred.sentBytesPerSecond
                    else { return nil }
                    return (received, sent)
                },
                histories: { ($0.receiveHistory, $0.sendHistory) },
                accessory: { store, _ in store.network?.preferred?.name ?? "" },
                volumes: false, accessibilityName: "Network"),
            store: store, sizeClass: sizeClass, style: style)
    }

    static func disk(store: MetricsStore, sizeClass: SizeClass, style: PanelStyle) -> RatePanelView {
        let palette = PanelPalette.make(style.appearance.theme)
        return RatePanelView(
            title: "Disk",
            source: Source(
                symbols: ("R", "W"), colors: (palette.read, palette.write), allowsBits: false,
                rates: { store in
                    guard let read = store.disk?.totalReadBytesPerSecond,
                        let written = store.disk?.totalWriteBytesPerSecond
                    else { return nil }
                    return (read, written)
                },
                histories: { ($0.readHistory, $0.writeHistory) },
                accessory: { store, sizeClass in sizeClass == .medium ? store.disk?.disks.first?.name ?? "" : "" },
                volumes: true, accessibilityName: "Disk"),
            store: store, sizeClass: sizeClass, style: style)
    }

    private func rate(_ value: Double) -> String {
        Units.rate(bytesPerSecond: value, style: units.bytes, bits: source.allowsBits && units.networkInBits)
    }

    override func layoutBody(in rect: CGRect) {
        let line = values.0.lineHeight
        var top = rect.minY
        if sizeClass == .extraSmall {
            // Two compact lines, no graph: the tile is too short for one.
            graph.isHidden = true
            for (row, (symbol, value)) in [(symbols.0, values.0), (symbols.1, values.1)].enumerated() {
                let y = top + CGFloat(row) * (line + 1)
                symbol.frame = CGRect(x: rect.minX, y: y, width: 14, height: line)
                value.frame = CGRect(x: rect.minX + 14, y: y, width: rect.width - 14, height: line)
            }
            return
        }
        if sizeClass == .small {
            // Two rates don't fit side by side at 154 pt; stack them.
            for (row, (symbol, value)) in [(symbols.0, values.0), (symbols.1, values.1)].enumerated() {
                let y = top + CGFloat(row) * (line + 1)
                symbol.frame = CGRect(x: rect.minX, y: y, width: 14, height: line)
                value.frame = CGRect(x: rect.minX + 14, y: y, width: rect.width - 14, height: line)
            }
            top += 2 * line + 4
        } else {
            let column: CGFloat = 112
            for (index, (symbol, value)) in [(symbols.0, values.0), (symbols.1, values.1)].enumerated() {
                let x = rect.minX + CGFloat(index) * column
                symbol.frame = CGRect(x: x, y: top, width: 14, height: line)
                value.frame = CGRect(x: x + 14, y: top, width: column - 18, height: line)
            }
            ceilingLabel.frame = CGRect(x: rect.maxX - 80, y: top + 2, width: 80, height: ceilingLabel.lineHeight)
            top += line + 4
        }
        var bottom = rect.maxY
        if sizeClass == .medium {
            let captionLine = footer.lineHeight
            if source.volumes {
                for index in volumeNames.indices.reversed() {
                    let y = bottom - captionLine
                    volumeNames[index].frame = CGRect(x: rect.minX, y: y, width: 84, height: captionLine)
                    volumeBars[index].frame = CGRect(
                        x: rect.minX + 88, y: y + (captionLine - 5) / 2, width: rect.width - 88 - 80, height: 5)
                    volumeFree[index].frame = CGRect(x: rect.maxX - 76, y: y, width: 76, height: captionLine)
                    bottom = y - 3
                }
            } else {
                footer.frame = CGRect(x: rect.minX, y: bottom - captionLine, width: rect.width, height: captionLine)
                bottom -= captionLine + 3
            }
        }
        graph.frame = CGRect(x: rect.minX, y: top, width: rect.width, height: bottom - top)
    }

    override func update() {
        withoutAnimation {
            accessory.text = source.accessory(store, sizeClass)
            let (first, second) = source.histories(store)
            let peak = Double(max(first.max() ?? 0, second.max() ?? 0))
            let ceiling = Units.niceCeiling(peak, floor: 10_240)
            if sizeClass != .extraSmall {
                graph.update([first, second], capacity: store.historyLength, ceiling: ceiling)
            }
            guard let (a, b) = source.rates(store) else {
                values.0.text = Self.pending
                values.1.text = ""
                return
            }
            values.0.text = rate(a)
            values.1.text = rate(b)
            guard sizeClass == .medium else { return }
            ceilingLabel.text = rate(ceiling)
            if source.volumes {
                updateVolumes()
            } else if let preferred = store.network?.preferred {
                let total = { (value: UInt64) in Units.bytes(Double(value), style: self.units.bytes) }
                footer.text = "Total ↓ \(total(preferred.totals.receivedBytes))  ↑ \(total(preferred.totals.sentBytes))"
            }
        }
    }

    private func updateVolumes() {
        let volumes = store.disk?.volumes.filter(\.isLocal).prefix(volumeNames.count) ?? []
        for index in volumeNames.indices {
            let hidden = index >= volumes.count
            volumeNames[index].isHidden = hidden
            volumeBars[index].isHidden = hidden
            volumeFree[index].isHidden = hidden
            guard !hidden else { continue }
            let volume = volumes[volumes.startIndex + index]
            volumeNames[index].text = volume.mountPoint == "/" ? "Macintosh HD" : volume.mountPoint
            volumeBars[index].update([volume.usedFraction])
            volumeBars[index].setColor(palette.utilization(volume.usedFraction), in: effectiveAppearance)
            volumeFree[index].text = Units.bytes(Double(volume.availableBytes), style: units.bytes) + " free"
        }
    }

    /// Disk: the fullest local volume. Network has no alert level.
    override func currentAlertLevel() -> AlertLevel {
        guard source.volumes, let volumes = store.disk?.volumes.filter(\.isLocal), !volumes.isEmpty else {
            return .normal
        }
        let fullest = volumes.map(\.usedFraction).max() ?? 0
        return ThresholdEvaluator.level(
            fullness: fullest, warning: style.thresholds.diskWarning, critical: style.thresholds.diskCritical)
    }

    override func accessibilitySummary() -> String {
        guard let (a, b) = source.rates(store) else { return "\(source.accessibilityName) unavailable" }
        return "\(source.accessibilityName) \(source.symbols.0) \(rate(a)), \(source.symbols.1) \(rate(b))"
    }

    override func resolveColors(in appearance: NSAppearance) {
        graph.resolveColors(in: appearance)
        for bar in volumeBars { bar.resolveColors(in: appearance) }
    }
}
