// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import AppKit
import VigilCore

/// A small live graph for use outside panels (e.g. the Dashboard's detail pane).
@MainActor
public final class SparklineView: NSView {
    public enum Kind {
        /// 0…1 utilization, graded calm → hot.
        case utilization
        /// An amount in the theme's accent for memory.
        case memory
    }

    private let graph: GraphLayer

    public init(kind: Kind) {
        let palette = PanelPalette.make(.system)
        graph = GraphLayer(
            [kind == .utilization ? .utilization : .rate(palette.memoryCompressed)], style: .area, palette: palette)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(graph)
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        graph.frame = bounds
        CATransaction.commit()
    }

    public func update(_ values: RingBuffer<Float>, capacity: Int, ceiling: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        graph.update([values], capacity: capacity, ceiling: ceiling)
        CATransaction.commit()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolve()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolve()
    }

    private func resolve() {
        graph.resolveColors(in: effectiveAppearance)
        layer?.backgroundColor = resolved(NSColor.labelColor.withAlphaComponent(0.05), in: effectiveAppearance)
    }
}
