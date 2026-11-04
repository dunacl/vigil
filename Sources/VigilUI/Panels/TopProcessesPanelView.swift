// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import AppKit
import VigilCore

/// The heaviest processes by CPU or memory. Clicking a row opens the Dashboard
/// on that process (via ``LayerPanelView/openProcess``).
final class TopProcessesPanelView: LayerPanelView {
    private let sort: TopProcessesSort
    private var names: [TextLayer] = []
    private var values: [TextLayer] = []
    private var secondaryValues: [TextLayer] = []
    private let footer: TextLayer
    private var rowIdentities: [ProcessIdentity] = []
    private var rowHeight: CGFloat = 14
    private var firstRowY: CGFloat = 0

    private var rowCount: Int {
        switch sizeClass {
        case .extraSmall: 1
        case .small: 4
        case .medium: 7
        }
    }

    init(store: MetricsStore, sizeClass: SizeClass, style: PanelStyle, sort: TopProcessesSort) {
        self.sort = sort
        footer = TextLayer(.caption, color: .tertiaryLabelColor)
        super.init(title: "Top Processes", store: store, sizeClass: sizeClass, style: style)
        accessory.text = sort == .cpu ? "by CPU" : "by Memory"
        let style: TextLayer.Style = sizeClass == .medium ? .body : .caption
        for _ in 0..<rowCount {
            names.append(text(style))
            values.append(text(style, alignment: .right))
            if sizeClass == .medium {
                secondaryValues.append(text(style, color: .secondaryLabelColor, alignment: .right))
            }
        }
        if sizeClass == .medium { add(footer) }
    }

    override func layoutBody(in rect: CGRect) {
        let line = names.first?.lineHeight ?? 14
        let footerHeight: CGFloat = sizeClass == .medium ? footer.lineHeight + 4 : 0
        rowHeight = max(line, min(line + 6, (rect.height - footerHeight) / CGFloat(rowCount)))
        firstRowY = rect.minY
        let valueWidth: CGFloat = sizeClass == .medium ? 64 : 52
        let secondaryWidth: CGFloat = sizeClass == .medium ? 72 : 0
        for index in names.indices {
            let y = rect.minY + CGFloat(index) * rowHeight
            let nameWidth = rect.width - valueWidth - secondaryWidth - 4
            names[index].frame = CGRect(x: rect.minX, y: y, width: nameWidth, height: line)
            values[index].frame = CGRect(x: rect.minX + nameWidth + 4, y: y, width: valueWidth, height: line)
            if index < secondaryValues.count {
                secondaryValues[index].frame = CGRect(
                    x: rect.maxX - secondaryWidth, y: y, width: secondaryWidth, height: line)
            }
        }
        footer.frame = CGRect(
            x: rect.minX, y: rect.maxY - footer.lineHeight, width: rect.width, height: footer.lineHeight)
    }

    override func update() {
        withoutAnimation {
            guard let processes = store.processes else {
                names.first?.text = Self.pending
                return
            }
            let top = processes.top(rowCount, by: sort)
            rowIdentities = top.map(\.id)
            for index in names.indices {
                guard index < top.count else {
                    names[index].text = ""
                    values[index].text = ""
                    if index < secondaryValues.count { secondaryValues[index].text = "" }
                    continue
                }
                let entry = top[index]
                names[index].text = entry.name
                let cpu = Units.percent(entry.cpu ?? 0, decimals: (entry.cpu ?? 0) < 0.1 ? 1 : 0)
                let memory = Units.bytes(Double(entry.memory ?? 0), style: units.bytes)
                // Medium shows both; the ranked metric comes first.
                values[index].text = sort == .cpu ? cpu : memory
                if index < secondaryValues.count { secondaryValues[index].text = sort == .cpu ? memory : cpu }
            }
            if sizeClass == .medium {
                footer.text =
                    processes.restrictedCount > 0
                    ? "\(processes.processes.count) processes · \(processes.restrictedCount) system ones not measured"
                    : "\(processes.processes.count) processes"
            }
        }
    }

    // MARK: - Clicking a row

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        let point = host.convert(event.locationInWindow, from: nil)
        let row = Int((point.y - firstRowY) / rowHeight)
        guard point.y >= firstRowY, row >= 0, row < rowIdentities.count else { return }
        Self.openProcess?(rowIdentities[row])
    }

    override func accessibilitySummary() -> String {
        guard let processes = store.processes else { return "Top processes unavailable" }
        let top = processes.top(3, by: sort).map(\.name).joined(separator: ", ")
        return "Top processes by \(sort == .cpu ? "CPU" : "memory"): \(top)"
    }
}

extension LayerPanelView {
    /// Set by the app: opens the Dashboard on a process (from a Top Processes row).
    @MainActor public static var openProcess: ((ProcessIdentity) -> Void)?
}
