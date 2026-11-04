// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import AppKit
import SwiftUI
import VigilCore
import VigilUI

/// Settings tabs, so other parts of the app can open a specific one.
enum SettingsTab: Hashable {
    case general, appearance, layouts, alerts
}

/// Which tab is showing; observed by the SwiftUI view.
@MainActor @Observable
final class SettingsNavigation {
    var tab: SettingsTab = .general
}

/// The Settings window (⌘,): general behavior, appearance with a live preview,
/// layouts, units and alert thresholds. Changes apply as you make them.
@MainActor
final class SettingsWindow: NSWindow, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let navigation = SettingsNavigation()

    init(
        store: SettingsStore, coordinator: DesktopCoordinator, metrics: MetricsStore, layout: LayoutController,
        currentDisplays: @escaping () -> [(String, String)], suspendHotKeys: @escaping (Bool) -> Void
    ) {
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 560, height: 640), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        title = "Vigil Settings"
        isReleasedWhenClosed = false
        delegate = self
        let controller = NSHostingController(
            rootView: SettingsView(
                store: store, navigation: navigation, layout: layout, currentDisplays: currentDisplays,
                suspendHotKeys: suspendHotKeys,
                makePreview: { PreviewPanel(coordinator: coordinator, metrics: metrics) }))
        controller.sizingOptions = .preferredContentSize
        contentViewController = controller
        center()
    }

    func show(tab: SettingsTab? = nil) {
        if let tab { navigation.tab = tab }
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}

private struct SettingsView: View {
    @Bindable var store: SettingsStore
    @Bindable var navigation: SettingsNavigation
    let layout: LayoutController
    let currentDisplays: () -> [(String, String)]
    let suspendHotKeys: (Bool) -> Void
    let makePreview: @MainActor () -> PreviewPanel

    var body: some View {
        TabView(selection: $navigation.tab) {
            GeneralTab(general: $store.settings.general, suspendHotKeys: suspendHotKeys)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            AppearanceTab(appearance: $store.settings.appearance, makePreview: makePreview)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
                .tag(SettingsTab.appearance)
            LayoutsTab(layout: layout, currentDisplays: currentDisplays)
                .tabItem { Label("Layouts", systemImage: "rectangle.3.group") }
                .tag(SettingsTab.layouts)
            AlertsAndUnitsTab(units: $store.settings.units, thresholds: $store.settings.thresholds)
                .tabItem { Label("Alerts & Units", systemImage: "gauge.with.dots.needle.67percent") }
                .tag(SettingsTab.alerts)
        }
        .frame(width: 540, height: 620)  // forms scroll; the window never outgrows small screens
        .scenePadding()
    }
}

// MARK: - Appearance

private struct AppearanceTab: View {
    @Binding var appearance: AppearanceSettings
    let makePreview: @MainActor () -> PreviewPanel

    var body: some View {
        Form {
            Section {
                PreviewRepresentable(appearance: appearance, makePreview: makePreview)
                    .frame(width: SizeClass.medium.size.width, height: SizeClass.medium.size.height)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            Section("Background") {
                Picker("Material", selection: $appearance.material) {
                    Text("Glass").tag(PanelMaterial.glass)
                    Text("Solid").tag(PanelMaterial.solid)
                    Text("None").tag(PanelMaterial.none)
                }
                .pickerStyle(.segmented)
                LabeledSlider(
                    "Transparency", value: $appearance.transparency, range: 0...1, low: "Opaque", high: "Clear"
                )
                .disabled(appearance.material != .glass)
                LabeledSlider(
                    "Content opacity", value: $appearance.contentOpacity, range: 0.2...1, low: "Faint", high: "Full")
                TintPicker(tint: $appearance.tint)
                LabeledSlider(
                    "Tint strength", value: $appearance.tintStrength, range: 0...1, low: "Subtle", high: "Strong"
                )
                .disabled(appearance.tint == .none)
                LabeledSlider("Corners", value: $appearance.cornerRadius, range: 0...32, low: "Square", high: "Round")
                Picker("Border", selection: $appearance.border) {
                    ForEach(SettingsLabels.borders, id: \.0) { Text($0.1).tag($0.0) }
                }
            }
            Section("Content") {
                Picker("Theme", selection: $appearance.theme) {
                    ForEach(SettingsLabels.themes, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)
                Picker("Graphs", selection: $appearance.graphStyle) {
                    ForEach(SettingsLabels.graphStyles, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)
            }
            Section {
                Picker("When the pointer is over a panel", selection: $appearance.hover) {
                    ForEach(SettingsLabels.hover, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Update panels", selection: $appearance.refresh) {
                    ForEach(SettingsLabels.refresh, id: \.0) { Text($0.1).tag($0.0) }
                }
            } header: {
                Text("Behavior")
            } footer: {
                Text(
                    "Slower updates and solid backgrounds use less energy. Reduce Transparency and Increase "
                        + "Contrast (System Settings → Accessibility → Display) always take precedence."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Restore Defaults") { appearance = AppearanceSettings() }
            }
        }
        .formStyle(.grouped)
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let low: String
    let high: String

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, low: String, high: String) {
        self.title = title
        self._value = value
        self.range = range
        self.low = low
        self.high = high
    }

    var body: some View {
        Slider(value: $value, in: range) {
            Text(title)
        } minimumValueLabel: {
            Text(low).font(.caption).foregroundStyle(.secondary)
        } maximumValueLabel: {
            Text(high).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct TintPicker: View {
    @Binding var tint: TintChoice

    var body: some View {
        LabeledContent("Tint") {
            HStack(spacing: 6) {
                swatch(.none, color: nil)
                ForEach(TintColor.allCases, id: \.self) { swatch(.color($0), color: Color(nsColor: $0.color)) }
            }
        }
    }

    private func swatch(_ choice: TintChoice, color: Color?) -> some View {
        Button {
            tint = choice
        } label: {
            ZStack {
                Circle().fill(color ?? Color.secondary.opacity(0.15)).frame(width: 18, height: 18)
                if color == nil {
                    Image(systemName: "slash.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if tint == choice { Circle().strokeBorder(Color.primary, lineWidth: 2).frame(width: 22, height: 22) }
            }
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(colorName(choice))
        .accessibilityAddTraits(tint == choice ? .isSelected : [])
    }

    private func colorName(_ choice: TintChoice) -> String {
        switch choice {
        case .none: "No tint"
        case .color(let color): color.rawValue.capitalized
        }
    }
}

// MARK: - Alerts & Units

private struct AlertsAndUnitsTab: View {
    @Binding var units: UnitSettings
    @Binding var thresholds: ThresholdSettings

    var body: some View {
        Form {
            Section("Units") {
                Picker("Sizes", selection: $units.bytes) {
                    Text("Binary (KiB, MiB, GiB)").tag(Units.ByteStyle.binary)
                    Text("Decimal (kB, MB, GB)").tag(Units.ByteStyle.decimal)
                }
                Toggle("Show network speeds in bits (Mb/s)", isOn: $units.networkInBits)
            }
            Section {
                Toggle("Tint panels when a resource runs hot", isOn: $thresholds.enabled)
                Group {
                    PercentSlider("CPU warning", value: $thresholds.cpuWarning)
                    PercentSlider("CPU critical", value: $thresholds.cpuCritical)
                    Stepper(value: $thresholds.sustainSeconds, in: 2...120, step: 2) {
                        LabeledContent("CPU must stay above it for", value: "\(Int(thresholds.sustainSeconds)) s")
                    }
                    PercentSlider("Disk full warning", value: $thresholds.diskWarning)
                    PercentSlider("Disk full critical", value: $thresholds.diskCritical)
                }
                .disabled(!thresholds.enabled)
            } header: {
                Text("Alerts")
            } footer: {
                Text("Memory uses macOS’s own memory-pressure level, like Activity Monitor.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PercentSlider: View {
    let title: String
    @Binding var value: Double

    init(_ title: String, value: Binding<Double>) {
        self.title = title
        self._value = value
    }

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: 0.5...1, step: 0.01)
                Text("\(Int((value * 100).rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
        }
    }
}

// MARK: - Live preview

/// A real CPU panel with the current global style, fed by the live tick.
@MainActor
final class PreviewPanel: NSView {
    private let coordinator: DesktopCoordinator
    private let metrics: MetricsStore
    private var panel: LayerPanelView

    init(coordinator: DesktopCoordinator, metrics: MetricsStore) {
        self.coordinator = coordinator
        self.metrics = metrics
        panel = PanelViewFactory.make(kind: .cpu, sizeClass: .medium, store: metrics, style: coordinator.globalStyle)
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: 320, height: 180)))
        install(panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func install(_ view: LayerPanelView) {
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        view.refresh()
    }

    /// Restyles after a settings change (rebuilding if theme or graph style changed).
    func restyle() {
        let style = coordinator.globalStyle
        if style.needsRebuild(from: panel.style) {
            panel.removeFromSuperview()
            panel = PanelViewFactory.make(kind: .cpu, sizeClass: .medium, store: metrics, style: style)
            install(panel)
        } else {
            panel.style = style
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            coordinator.observeTicks(self) { [weak self] in self?.panel.refresh() }
        } else {
            coordinator.stopObservingTicks(self)
        }
    }
}

private struct PreviewRepresentable: NSViewRepresentable {
    let appearance: AppearanceSettings  // compared by SwiftUI to trigger updates
    let makePreview: @MainActor () -> PreviewPanel

    func makeNSView(context: Context) -> PreviewPanel { makePreview() }
    func updateNSView(_ view: PreviewPanel, context: Context) { view.restyle() }
}
