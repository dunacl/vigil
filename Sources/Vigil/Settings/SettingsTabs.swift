// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import VigilCore
import VigilUI

// MARK: - General

struct GeneralTab: View {
    @Binding var general: GeneralSettings
    let suspendHotKeys: (Bool) -> Void

    var body: some View {
        Form {
            Section {
                Picker("Show", selection: $general.menuBar) {
                    Text("Icon only").tag(MenuBarReadout.iconOnly)
                    Text("CPU").tag(MenuBarReadout.cpu)
                    Text("CPU and memory").tag(MenuBarReadout.cpuAndMemory)
                    Text("Network speed").tag(MenuBarReadout.network)
                }
            } header: {
                Text("Menu bar")
            } footer: {
                if general.menuBar != .iconOnly {
                    Text("A live number in the menu bar uses about as much energy as all the default panels together.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Startup") { LaunchAtLoginToggle() }
            Section {
                ShortcutRow(title: "Edit layout", shortcut: $general.shortcuts.editLayout, suspend: suspendHotKeys)
                ShortcutRow(title: "Show processes", shortcut: $general.shortcuts.dashboard, suspend: suspendHotKeys)
                ShortcutRow(title: "Peek at panels", shortcut: $general.shortcuts.peek, suspend: suspendHotKeys)
            } header: {
                Text("Keyboard shortcuts")
            } footer: {
                Text("Work from any app. Peek brings the panels above your windows until you press it again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy & energy") {
                Toggle("Hide panels in screenshots and screen sharing", isOn: $general.hideFromScreenCapture)
                Toggle("Update less often in Low Power Mode or when the Mac is hot", isOn: $general.adaptiveSampling)
            }
            Section {
                Toggle("Read temperatures, fans and power", isOn: $general.privateSensors)
            } header: {
                Text("Sensors")
            } footer: {
                Text(
                    "Uses interfaces macOS doesn’t document. They can change with any macOS update; if one stops "
                        + "working, Vigil simply stops showing that reading. Thermal pressure is always shown."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Registers Vigil as a login item (SPEC §3.1, `SMAppService.mainApp`).
private struct LaunchAtLoginToggle: View {
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        Toggle("Open Vigil at login", isOn: Binding(get: { status == .enabled }, set: set))
        if status == .requiresApproval {
            Text("Allow Vigil in System Settings → General → Login Items.").font(.caption).foregroundStyle(.secondary)
        }
        if let error { Text(error).font(.caption).foregroundStyle(.red) }
    }

    private func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error =
                "Couldn’t change the login item: \(error.localizedDescription) "
                + "(this works when Vigil runs from its app bundle)."
        }
        status = SMAppService.mainApp.status
    }
}

/// Click, then press the new shortcut. Esc cancels; Delete turns it off.
private struct ShortcutRow: View {
    let title: String
    @Binding var shortcut: KeyShortcut?
    let suspend: (Bool) -> Void
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
                Button(recording ? "Type shortcut…" : shortcut.map(ShortcutFormatter.string) ?? "Off") {
                    recording ? stop() : start()
                }
                .monospacedDigit()
                .frame(minWidth: 110)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        hint = "Esc to cancel, ⌫ for none"
        suspend(true)  // the current shortcuts must not fire while recording
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                switch event.keyCode {
                case 53: stop()  // Esc
                case 51, 117:  // Delete
                    shortcut = nil
                    stop()
                default:
                    if let recorded = ShortcutFormatter.shortcut(from: event) {
                        shortcut = recorded
                        stop()
                    } else {
                        hint = "Include ⌃, ⌥ or ⌘"
                    }
                }
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { suspend(false) }
        recording = false
        hint = nil
    }
}

// MARK: - Layouts

struct LayoutsTab: View {
    let layout: LayoutController
    let currentDisplays: () -> [(String, String)]
    @State private var selection: String?
    @State private var renaming = false
    @State private var newName = ""

    private var selected: LayoutProfile? { selection.flatMap { layout.library[$0] } ?? layout.library.active }

    var body: some View {
        Form {
            Section {
                List(layout.library.profiles, selection: $selection) { profile in
                    HStack {
                        Image(systemName: "checkmark").opacity(profile.id == layout.library.activeID ? 1 : 0)
                        Text(profile.name)
                        Spacer()
                        if profile.displays != nil {
                            Image(systemName: "display").foregroundStyle(.secondary).help("Switches on automatically")
                        }
                        Text("\(profile.panels.count) panels").foregroundStyle(.secondary).font(.caption)
                    }
                    .tag(profile.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { layout.activate(profile.id) }
                }
                .frame(height: 150)
                HStack {
                    Menu("New") {
                        ForEach(LayoutPreset.allCases, id: \.self) { preset in
                            Button(preset.name) { selection = layout.addLayout(preset.profile) }
                        }
                    }
                    .fixedSize()
                    Button("Use") { if let id = selected?.id { layout.activate(id) } }
                        .disabled(selected?.id == layout.library.activeID)
                    Button("Duplicate") {
                        guard let id = selected?.id else { return }
                        layout.changeLibrary("Duplicate Layout") { selection = $0.duplicate(id) }
                    }
                    Button("Rename…") {
                        newName = selected?.name ?? ""
                        renaming = true
                    }
                    Button("Delete", role: .destructive) {
                        guard let id = selected?.id else { return }
                        layout.changeLibrary("Delete Layout") { $0.remove(id) }
                        selection = nil
                    }
                    .disabled(layout.library.profiles.count < 2)
                    Spacer()
                    Button("Import…", action: importLayout)
                    Button("Export…", action: exportLayout).disabled(selected == nil)
                }
                .controlSize(.small)
                if let selected {
                    AutoSwitchToggle(layout: layout, profile: selected, currentDisplays: currentDisplays)
                }
            } header: {
                Text("Layouts")
            } footer: {
                Text("Double-click a layout to use it. Undo works for these changes in Edit Mode (⌘Z).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            PanelsSection(layout: layout)
        }
        .formStyle(.grouped)
        .alert("Rename Layout", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") {
                guard let id = selected?.id else { return }
                layout.changeLibrary("Rename Layout") { $0.rename(id, to: newName) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func exportLayout() {
        guard let profile = selected else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(profile.name).vigillayout"
        panel.allowedContentTypes = [UTType(filenameExtension: "vigillayout") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url,
            let data = try? LayoutFileStore.export(profile)
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func importLayout() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "vigillayout") ?? .json, .json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        guard var profile = LayoutFileStore.importProfile(from: data) else {
            let alert = NSAlert()
            alert.messageText = "That file isn’t a Vigil layout."
            alert.runModal()
            return
        }
        profile.displays = nil  // another Mac's displays don't apply here
        selection = layout.addLayout(profile, activate: false)
    }
}

/// Binds a layout to the displays connected right now.
private struct AutoSwitchToggle: View {
    let layout: LayoutController
    let profile: LayoutProfile
    let currentDisplays: () -> [(String, String)]

    var body: some View {
        let displays = currentDisplays()
        let ids = Set(displays.map(\.0))
        let names = displays.map(\.1).joined(separator: " + ")
        let bound = Set(profile.displays ?? []) == ids && profile.displays != nil
        Toggle(
            isOn: Binding(
                get: { bound },
                set: { on in layout.changeLibrary("Auto-switch Layout") { $0.bind(profile.id, to: on ? ids : nil) } }
            )
        ) {
            Text("Use “\(profile.name)” automatically with \(names)")
            if let other = profile.displays, !bound {
                Text("Currently set for \(other.count) other display\(other.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Settings → Panels (SPEC §3.4): every panel in the active layout.
private struct PanelsSection: View {
    let layout: LayoutController

    var body: some View {
        Section("Panels in “\(layout.profile.name)”") {
            if layout.profile.panels.isEmpty {
                Text("No panels. Use New in the menu bar’s Edit Layout to add some.").foregroundStyle(.secondary)
            }
            ForEach(layout.profile.panels) { panel in
                HStack {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { panel.isVisible }, set: { layout.setVisible($0, panel: panel.id) })
                    )
                    .labelsHidden()
                    .help(panel.isVisible ? "Hide" : "Show")
                    Text(PanelViewFactory.title(of: panel.kind))
                    Text(LayerPanelView.title(of: panel.sizeClass)).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        layout.duplicatePanel(panel.id)
                    } label: {
                        Image(systemName: "plus.square.on.square")
                    }
                    .buttonStyle(.borderless)
                    .help("Duplicate")
                    Button {
                        layout.remove([panel.id])
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                }
            }
            Button("Gather All Panels on the Main Display") { layout.gatherAll() }
        }
    }
}
