// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import AppKit
import SwiftUI
import VigilCore

/// The ⚙ popover: everything about one panel's placement and look (SPEC §3.3.1).
/// Each change is applied immediately (and is undoable from the toolbar).
@MainActor
enum PanelInspector {
    static func popover(
        for instance: PanelInstance, apply: @escaping (PanelInstance) -> Void, remove: @escaping () -> Void
    ) -> NSPopover {
        let screens = ScreenCatalog.current()
        var displays: [(DisplayRef, String)] = [(.main, "Main display")]
        displays += screens.map { (DisplayRef.uuid($0.uuid), $0.name) }
        // Desktops available per display; nil when the Spaces bridge is unavailable.
        var desktopCounts: [String: Int]? = nil
        if let bridge = SpacesBridge.shared {
            let spaces = bridge.displays()
            desktopCounts = [:]
            for screen in screens {
                let display =
                    spaces.first { $0.displayIdentifier == screen.uuid }
                    ?? spaces.first { $0.displayIdentifier == "Main" }
                desktopCounts?[screen.uuid] = display?.desktops.count ?? 0
            }
        }
        let mainUUID = screens.first(where: \.isMain)?.uuid
        let popover = NSPopover()
        popover.behavior = .transient
        let controller = NSHostingController(
            rootView: PanelInspectorView(
                panel: instance, displays: displays, desktopCounts: desktopCounts, mainUUID: mainUUID,
                apply: apply,
                remove: {
                    popover.close(); remove()
                }))
        controller.sizingOptions = .preferredContentSize  // the popover follows the form's size
        popover.contentViewController = controller
        return popover
    }
}

private struct PanelInspectorView: View {
    @State var panel: PanelInstance
    let displays: [(DisplayRef, String)]
    let desktopCounts: [String: Int]?
    let mainUUID: String?
    let apply: (PanelInstance) -> Void
    let remove: () -> Void

    private var desktopCount: Int? {
        guard let desktopCounts else { return nil }
        switch panel.placement.display {
        case .main: return mainUUID.flatMap { desktopCounts[$0] } ?? 0
        case .uuid(let uuid): return desktopCounts[uuid] ?? 0
        }
    }

    var body: some View {
        Form {
            Section("Position") {
                Picker("Display", selection: $panel.placement.display) {
                    ForEach(displays, id: \.0) { Text($0.1).tag($0.0) }
                }
                LabeledContent("Anchor") { AnchorGrid(anchor: $panel.placement.anchor) }
                HStack {
                    TextField("X", value: $panel.placement.offset.x, format: .number.precision(.fractionLength(0)))
                    TextField("Y", value: $panel.placement.offset.y, format: .number.precision(.fractionLength(0)))
                }
                Picker("Desktop", selection: $panel.placement.desktop) {
                    Text("All desktops").tag(DesktopRef.all)
                    Text("This desktop").tag(DesktopRef.current)
                    if let desktopCount {
                        ForEach(1..<max(desktopCount, 1) + 1, id: \.self) {
                            Text("Desktop \($0)").tag(DesktopRef.index($0))
                        }
                    }
                }
                if desktopCount == nil {
                    Text("Pinning to a specific desktop isn't available on this version of macOS.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Size & layer") {
                Picker("Size", selection: sizeBinding) {
                    Text("XS").tag(SizeClass.extraSmall).accessibilityLabel("Extra small")
                    Text("Small").tag(SizeClass.small)
                    Text("Medium").tag(SizeClass.medium)
                }
                .pickerStyle(.segmented)
                if panel.kind == .topProcesses {
                    Picker("Rank by", selection: $panel.options.topSort) {
                        Text("CPU").tag(TopProcessesSort.cpu)
                        Text("Memory").tag(TopProcessesSort.memory)
                    }
                    .pickerStyle(.segmented)
                }
                Picker("Layer", selection: $panel.level) {
                    Text("Above desktop icons").tag(PanelLevel.desktop)
                    Text("Behind desktop icons").tag(PanelLevel.behindIcons)
                    Text("Above windows").tag(PanelLevel.floating)
                }
                Toggle("Clicks pass through", isOn: $panel.clickThrough)
            }
            Section {
                AppearanceOverridesForm(overrides: $panel.appearance)
            } header: {
                Text("Appearance")
            } footer: {
                Text("“Default” follows Settings → Appearance.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Hide") { panel.isVisible = false }
                    Spacer()
                    Button("Remove Panel", role: .destructive, action: remove)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 320)
        .onChange(of: panel) { _, updated in apply(updated) }
    }

    /// Changing the size class also resets the size to that class's default.
    private var sizeBinding: Binding<SizeClass> {
        Binding(
            get: { panel.sizeClass },
            set: { sizeClass in
                panel.sizeClass = sizeClass
                panel.placement.size = sizeClass.size
            })
    }
}

private struct AnchorGrid: View {
    @Binding var anchor: VigilCore.Anchor
    private let rows: [[VigilCore.Anchor]] = [
        [.topLeading, .top, .topTrailing], [.leading, .center, .trailing], [.bottomLeading, .bottom, .bottomTrailing],
    ]

    var body: some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            ForEach(rows, id: \.self) { row in
                GridRow {
                    ForEach(row, id: \.self) { cell in
                        Button {
                            anchor = cell
                        } label: {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(cell == anchor ? Color.accentColor : Color.secondary.opacity(0.3))
                                .frame(width: 14, height: 10)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(cell.rawValue)
                    }
                }
            }
        }
    }
}

/// Per-panel appearance overrides; every picker offers "Default" (inherit).
struct AppearanceOverridesForm: View {
    @Binding var overrides: AppearanceOverrides

    var body: some View {
        OverridePicker(
            "Background", selection: $overrides.material,
            options: [(.glass, "Glass"), (.solid, "Solid"), (.none, "None")])
        Toggle("Custom transparency", isOn: customBinding(\.transparency, default: 0.4))
        if let transparency = overrides.transparency {
            Slider(value: Binding(get: { transparency }, set: { overrides.transparency = $0 }), in: 0...1) {
                Text("Transparency")
            }
        }
        OverridePicker(
            "Tint", selection: $overrides.tint,
            options: [(.none, "None")] + TintColor.allCases.map { (.color($0), $0.rawValue.capitalized) })
        OverridePicker("Theme", selection: $overrides.theme, options: SettingsLabels.themes)
        OverridePicker("Graph", selection: $overrides.graphStyle, options: SettingsLabels.graphStyles)
        OverridePicker("On hover", selection: $overrides.hover, options: SettingsLabels.hover)
        OverridePicker("Update", selection: $overrides.refresh, options: SettingsLabels.refresh)
        if !overrides.isEmpty {
            Button("Use Defaults for This Panel") { overrides = AppearanceOverrides() }
        }
    }

    private func customBinding(_ keyPath: WritableKeyPath<AppearanceOverrides, Double?>, default value: Double)
        -> Binding<Bool>
    {
        Binding(
            get: { overrides[keyPath: keyPath] != nil },
            set: { overrides[keyPath: keyPath] = $0 ? value : nil })
    }
}

/// A picker whose first option is "Default" (`nil`).
struct OverridePicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value?
    let options: [(Value, String)]

    init(_ title: String, selection: Binding<Value?>, options: [(Value, String)]) {
        self.title = title
        self._selection = selection
        self.options = options
    }

    var body: some View {
        Picker(title, selection: $selection) {
            Text("Default").tag(Value?.none)
            Divider()
            ForEach(options.indices, id: \.self) { index in
                Text(options[index].1).tag(Optional(options[index].0))
            }
        }
    }
}

/// Display names shared by Settings and the panel inspector.
enum SettingsLabels {
    static let themes: [(PanelTheme, String)] = [(.system, "System"), (.btop, "btop"), (.mono, "Mono")]
    static let graphStyles: [(GraphStyle, String)] = [(.area, "Filled area"), (.line, "Line")]
    static let hover: [(HoverBehavior, String)] = [(.off, "Stay visible"), (.fade, "Fade"), (.hide, "Hide")]
    static let refresh: [(RefreshRate, String)] = [
        (.everyTick, "Every tick (2 s)"), (.everyOtherTick, "Every 4 s"), (.everyFifthTick, "Every 10 s"),
    ]
    static let borders: [(PanelBorder, String)] = [(.off, "None"), (.hairline, "Hairline"), (.accent, "Accent")]
}
