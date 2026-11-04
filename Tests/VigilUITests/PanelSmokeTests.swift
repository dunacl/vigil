// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.
//
// Builds every panel in every size and style, with no data and with live data,
// and drives it the way a panel window does. Catches crashes and layout traps
// in the UI layer, which the core tests don't reach.

import AppKit
import Testing
import VigilCore

@testable import VigilUI

@MainActor
@Suite(.serialized) struct PanelSmokeTests {
    nonisolated static let kinds = PanelKind.allCases
    nonisolated static let sizes = SizeClass.allCases

    private func style(material: PanelMaterial = .glass, theme: PanelTheme = .system, graph: GraphStyle = .area)
        -> PanelStyle
    {
        var settings = AppearanceSettings()
        settings.material = material
        settings.theme = theme
        settings.graphStyle = graph
        return PanelStyle(
            appearance: AppearanceResolver.resolve(
                global: settings, overrides: AppearanceOverrides(), accessibility: AccessibilityDisplay()),
            units: UnitSettings(), thresholds: ThresholdSettings())
    }

    private func exercise(_ panel: LayerPanelView, size: Size) {
        panel.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        panel.layoutSubtreeIfNeeded()
        panel.refresh()
        panel.refresh()
        #expect(panel.accessibilityLabel()?.isEmpty == false)
        // Resizing (Edit Mode) re-lays out every layer.
        panel.frame.size = NSSize(width: size.width * 2, height: size.height * 1.5)
        panel.layoutSubtreeIfNeeded()
        panel.frame.size = NSSize(width: 1, height: 1)
        panel.layoutSubtreeIfNeeded()
    }

    @Test(arguments: kinds, sizes)
    func rendersWithoutData(kind: PanelKind, size: SizeClass) {
        let store = MetricsStore(system: .current())
        let panel = PanelViewFactory.make(kind: kind, sizeClass: size, store: store)
        exercise(panel, size: size.size)
        #expect(!PanelViewFactory.title(of: kind).isEmpty)
    }

    @Test func rendersLiveDataInEveryStyle() async {
        let demand = PanelKind.allCases.reduce(into: Demand()) { $0.formUnion($1.demand) }
        let sampler = Sampler(configuration: SamplerConfiguration(interval: 2, demand: demand))
        let store = MetricsStore(system: sampler.system)
        let start = MonotonicInstant.now
        store.apply(await sampler.sample(at: start))
        try? await Task.sleep(for: .milliseconds(100))
        store.apply(await sampler.sample(at: MonotonicInstant(nanoseconds: start.nanoseconds + 2_000_000_000)))
        #expect(store.cpu != nil)

        let styles = [
            style(), style(material: .solid, theme: .btop, graph: .line),
            style(material: .none, theme: .mono),
        ]
        for style in styles {
            for kind in Self.kinds {
                for size in Self.sizes {
                    exercise(
                        PanelViewFactory.make(kind: kind, sizeClass: size, store: store, style: style), size: size.size)
                }
            }
        }
    }

    @Test func styleChangesApplyInPlaceUnlessThemeOrGraphChanges() {
        let base = style()
        var transparency = base
        transparency.appearance.contentOpacity = 0.5
        #expect(!transparency.needsRebuild(from: base))
        #expect(style(theme: .btop).needsRebuild(from: base))
        #expect(style(graph: .line).needsRebuild(from: base))

        let panel = PanelViewFactory.make(kind: .cpu, sizeClass: .medium, store: MetricsStore(system: .current()))
        panel.style = transparency
        exercise(panel, size: SizeClass.medium.size)
    }
}
