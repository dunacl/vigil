// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import AppKit
import VigilCore
import VigilUI

/// The menu bar item (SPEC §3.1): an icon with an optional live readout, and a
/// menu rebuilt each time it opens (layouts, panels, Edit Mode, Processes, …).
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    /// What the menu can do; supplied by the app delegate.
    struct Actions {
        var isEditing: () -> Bool
        var toggleEditMode: () -> Void
        var openDashboard: () -> Void
        var openSettings: (SettingsTab?) -> Void
        var isPaused: () -> Bool
        var togglePause: () -> Void
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let layout: LayoutController
    private let actions: Actions
    private var shortcuts = ShortcutSettings()
    private var lastTitle = ""
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    var readout: MenuBarReadout = .iconOnly {
        didSet {
            guard readout != oldValue else { return }
            applyWidth()
            lastTitle = "-"
            render(nil)
        }
    }

    init(layout: LayoutController, actions: Actions) {
        self.layout = layout
        self.actions = actions
        super.init()
        item.button?.image = NSImage(
            systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "Vigil")
        item.button?.imagePosition = .imageLeading
        item.button?.font = font
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        applyWidth()
        render(nil)
    }

    /// A fixed width per readout, sized for its widest value. A variable-length
    /// item re-lays out the whole menu bar whenever the text width changes
    /// ("9%" → "12%"), which measured ~0.25 % CPU; a fixed width doesn't.
    private func applyWidth() {
        let widest: String? =
            switch readout {
            case .iconOnly: nil
            case .cpu: "100%"
            case .cpuAndMemory: "100% · 100%"
            case .network: "↓999K ↑999K"
            }
        guard let widest else {
            item.length = NSStatusItem.squareLength
            return
        }
        let text = (" " + widest as NSString).size(withAttributes: [.font: font]).width
        item.length = ceil(text + 16 + 8)  // icon + padding
    }

    func update(shortcuts: ShortcutSettings) { self.shortcuts = shortcuts }

    // MARK: - Readout

    /// Called each tick; touches the menu bar only when the text changes.
    func tick(store: MetricsStore, units: UnitSettings) {
        render(text(store: store, units: units))
    }

    private func text(store: MetricsStore, units: UnitSettings) -> String? {
        switch readout {
        case .iconOnly:
            return nil
        case .cpu:
            return store.cpu.map { Self.percent($0.overall.total) }
        case .cpuAndMemory:
            guard let cpu = store.cpu, let memory = store.memory else { return nil }
            return "\(Self.percent(cpu.overall.total)) · \(Self.percent(memory.usedFraction))"
        case .network:
            guard let preferred = store.network?.preferred, let received = preferred.receivedBytesPerSecond,
                let sent = preferred.sentBytesPerSecond
            else { return nil }
            return
                "↓\(Self.compact(received, bits: units.networkInBits)) ↑\(Self.compact(sent, bits: units.networkInBits))"
        }
    }

    private func render(_ text: String?) {
        let title = text ?? ""
        guard title != lastTitle, let button = item.button else { return }
        lastTitle = title
        button.title = title.isEmpty ? "" : " " + title
        button.setAccessibilityLabel(title.isEmpty ? "Vigil" : "Vigil, \(title)")
    }

    private static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    /// "1.2M", "830K" — short enough for the menu bar.
    private static func compact(_ bytesPerSecond: Double, bits: Bool) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 0, bytesPerSecond < 1e15 else { return "—" }
        var value = bits ? bytesPerSecond * 8 : bytesPerSecond
        let base: Double = bits ? 1000 : 1024
        for suffix in ["", "K", "M", "G"] {
            if value < base || suffix == "G" {
                return value < 10 && !suffix.isEmpty
                    ? Units.number(value, decimals: 1) + suffix : String(Int(value.rounded())) + suffix
            }
            value /= base
        }
        return "?"
    }

    // MARK: - Menu

    /// Rebuilt each time it opens, so it always reflects the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let edit = item(actions.isEditing() ? "Done Editing" : "Edit Layout…", shortcut: shortcuts.editLayout) {
            [actions] in actions.toggleEditMode()
        }
        menu.addItem(edit)
        menu.addItem(layoutsMenu())
        menu.addItem(panelsMenu())
        menu.addItem(.separator())
        menu.addItem(item("Processes…", shortcut: shortcuts.dashboard) { [actions] in actions.openDashboard() })
        let settings = item("Settings…") { [actions] in actions.openSettings(nil) }
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(
            item(actions.isPaused() ? "Resume Updates" : "Pause Updates") { [actions] in actions.togglePause() })
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(title: "Quit Vigil", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func layoutsMenu() -> NSMenuItem {
        let menu = NSMenu()
        for profile in layout.library.profiles {
            let entry = item(profile.name) { [layout] in layout.activate(profile.id) }
            entry.state = profile.id == layout.library.activeID ? .on : .off
            if profile.displays != nil { entry.toolTip = "Switches on automatically with its displays" }
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let presets = NSMenu()
        for preset in LayoutPreset.allCases {
            let entry = item(preset.name) { [layout] in layout.addLayout(preset.profile) }
            entry.toolTip = preset.summary
            presets.addItem(entry)
        }
        let newFromPreset = NSMenuItem(title: "New Layout", action: nil, keyEquivalent: "")
        newFromPreset.submenu = presets
        menu.addItem(newFromPreset)
        menu.addItem(item("Manage Layouts…") { [actions] in actions.openSettings(.layouts) })
        let parent = NSMenuItem(title: "Layout: \(layout.profile.name)", action: nil, keyEquivalent: "")
        parent.submenu = menu
        return parent
    }

    private func panelsMenu() -> NSMenuItem {
        let menu = NSMenu()
        for panel in layout.profile.panels {
            let title = "\(PanelViewFactory.title(of: panel.kind)) (\(LayerPanelView.title(of: panel.sizeClass)))"
            let entry = item(title) { [layout] in layout.setVisible(!panel.isVisible, panel: panel.id) }
            entry.state = panel.isVisible ? .on : .off
            menu.addItem(entry)
        }
        if layout.profile.panels.isEmpty {
            menu.addItem(NSMenuItem(title: "No panels — use Edit Layout to add some", action: nil, keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(item("Gather All Panels") { [layout] in layout.gatherAll() })
        let parent = NSMenuItem(title: "Panels", action: nil, keyEquivalent: "")
        parent.submenu = menu
        return parent
    }

    /// A menu item running a closure; shows a global shortcut if one is set.
    private func item(_ title: String, shortcut: KeyShortcut? = nil, _ action: @escaping () -> Void) -> NSMenuItem {
        let target = ClosureTarget(action)
        let entry = NSMenuItem(title: title, action: #selector(ClosureTarget.run), keyEquivalent: "")
        entry.target = target
        entry.representedObject = target  // keeps the target alive with the item
        if let shortcut, let key = ShortcutFormatter.keyEquivalent(shortcut.keyCode) {
            entry.keyEquivalent = key
            entry.keyEquivalentModifierMask = ShortcutFormatter.modifierFlags(shortcut.modifiers)
        }
        return entry
    }
}

/// Wraps a closure as an Objective-C action target.
@MainActor
final class ClosureTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}
