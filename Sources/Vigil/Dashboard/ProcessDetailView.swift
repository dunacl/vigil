// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import AppKit
import VigilCore
import VigilUI

/// The Dashboard's detail pane for the selected process: identity, path,
/// arguments, counts and live CPU/memory graphs.
@MainActor
final class ProcessDetailView: NSView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let path = NSTextField(labelWithString: "")
    private let facts = NSTextField(labelWithString: "")
    private let arguments = NSTextField(wrappingLabelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private let cpuLabel = NSTextField(labelWithString: "CPU")
    private let memoryLabel = NSTextField(labelWithString: "Memory")
    private let cpuGraph = SparklineView(kind: .utilization)
    private let memoryGraph = SparklineView(kind: .memory)
    private let empty = NSTextField(labelWithString: "Select a process to see its details.")
    private var details: ProcessDetails?
    private var detailsFor: ProcessIdentity?
    private var ticksSinceDetails = 0

    init() {
        super.init(frame: .zero)
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        for field in [path, facts, arguments, note] {
            field.font = .systemFont(ofSize: 11)
            field.textColor = .secondaryLabelColor
            field.isSelectable = true
        }
        path.lineBreakMode = .byTruncatingMiddle
        arguments.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        arguments.maximumNumberOfLines = 3
        note.textColor = .tertiaryLabelColor
        for label in [cpuLabel, memoryLabel] {
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
        }
        empty.textColor = .tertiaryLabelColor
        empty.alignment = .center
        for view in [icon, name, path, facts, arguments, note, cpuLabel, memoryLabel, cpuGraph, memoryGraph, empty] {
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Process details")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let pad: CGFloat = 16, graphWidth: CGFloat = 220
        let textWidth = bounds.width - 3 * pad - graphWidth - 40
        icon.frame = CGRect(x: pad, y: pad, width: 32, height: 32)
        name.frame = CGRect(x: pad + 40, y: pad - 1, width: textWidth, height: 20)
        path.frame = CGRect(x: pad + 40, y: pad + 19, width: textWidth, height: 15)
        facts.frame = CGRect(x: pad, y: pad + 44, width: textWidth + 40, height: 15)
        arguments.frame = CGRect(x: pad, y: pad + 64, width: textWidth + 40, height: 44)
        note.frame = CGRect(x: pad, y: pad + 112, width: textWidth + 40, height: 30)
        let graphX = bounds.width - pad - graphWidth
        let graphHeight = max((bounds.height - 2 * pad - 2 * 16 - 8) / 2, 20)
        cpuLabel.frame = CGRect(x: graphX, y: pad, width: graphWidth, height: 14)
        cpuGraph.frame = CGRect(x: graphX, y: pad + 16, width: graphWidth, height: graphHeight)
        memoryLabel.frame = CGRect(x: graphX, y: pad + 24 + graphHeight, width: graphWidth, height: 14)
        memoryGraph.frame = CGRect(x: graphX, y: pad + 40 + graphHeight, width: graphWidth, height: graphHeight)
        empty.frame = CGRect(x: 0, y: bounds.midY - 10, width: bounds.width, height: 20)
    }

    func show(_ entry: ProcessEntry?, store: MetricsStore, units: UnitSettings, icon image: NSImage?) {
        let hasEntry = entry != nil
        for view in subviews { view.isHidden = view === empty ? hasEntry : !hasEntry }
        guard let entry else { return }

        // Arguments and open files cost syscalls: read on selection and every ~10 s.
        ticksSinceDetails += 1
        if detailsFor != entry.id || ticksSinceDetails >= 5 {
            details = entry.isRestricted ? nil : ProcessDetails.read(entry.id)
            detailsFor = entry.id
            ticksSinceDetails = 0
        }

        icon.image = image
        name.stringValue = entry.name
        path.stringValue = entry.path ?? "Path unavailable"
        let parent = store.processes?.processes.first { $0.pid == entry.parentPID }
        var parts = [
            "PID \(entry.pid)",
            "Parent \(entry.parentPID)\(parent.map { " (\($0.name))" } ?? "")",
            "User \(entry.user)",
            "Started \(Date(timeIntervalSince1970: entry.startDate).formatted(date: .abbreviated, time: .shortened))",
        ]
        if let threads = entry.threads { parts.append("Threads \(threads)") }
        if let files = details?.openFiles { parts.append("Open files \(files)") }
        if let time = entry.cpuTime { parts.append("CPU time \(Units.duration(time))") }
        facts.stringValue = parts.joined(separator: "  ·  ")
        arguments.stringValue = details?.arguments?.joined(separator: " ") ?? ""
        note.stringValue =
            entry.isRestricted
            ? "This process belongs to another user (\(entry.user)). macOS lets apps without administrator "
                + "access see that it exists, but not measure its CPU, memory or disk use."
            : ""

        let cores = Double(max(store.system.cpu.logicalCPUCount, 1))
        cpuLabel.stringValue = "CPU \(entry.cpu.map { Units.percent($0, decimals: 1) } ?? "—")"
        memoryLabel.stringValue =
            "Memory \(entry.memory.map { Units.bytes(Double($0), style: units.bytes) } ?? "—")"
        // CPU graph scaled to the busiest the process has been (at least one core).
        let cpuPeak = Double(store.focusedCPUHistory.max() ?? 0)
        cpuGraph.update(store.focusedCPUHistory, capacity: store.historyLength, ceiling: max(cpuPeak, 1 / cores) * 1.1)
        let memoryPeak = Double(store.focusedMemoryHistory.max() ?? 0)
        memoryGraph.update(
            store.focusedMemoryHistory, capacity: store.historyLength,
            ceiling: Units.niceCeiling(memoryPeak, floor: 1_048_576))
    }
}
