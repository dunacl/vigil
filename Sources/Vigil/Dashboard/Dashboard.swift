// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import AppKit
import VigilCore
import VigilUI

/// The Dashboard window (SPEC §3.1): the full process table with filter, tree
/// view, sorting, a detail pane and signals. It samples processes only while it
/// can be seen, and shows a Dock icon only while it's open.
@MainActor
final class Dashboard: NSObject, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    let window: NSWindow
    private let table = ProcessTable()
    private let detail = ProcessDetailView()
    private let split = NSSplitView()
    private let search = NSSearchToolbarItem(itemIdentifier: .search)
    private let viewMode = NSSegmentedControl(
        labels: ["List", "Tree"], trackingMode: .selectOne, target: nil, action: nil)
    private let store: MetricsStore
    private let coordinator: DesktopCoordinator
    private let settings: SettingsStore
    private let togglePause: () -> Bool
    private var observers: [NSObjectProtocol] = []
    var onClose: (() -> Void)?
    /// p / ⇧p: next/previous layout (SPEC §3.7).
    var onCycleLayout: ((Int) -> Void)?

    init(
        store: MetricsStore, coordinator: DesktopCoordinator, settings: SettingsStore, togglePause: @escaping () -> Bool
    ) {
        self.store = store
        self.coordinator = coordinator
        self.settings = settings
        self.togglePause = togglePause
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Processes"
        window.minSize = CGSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("VigilDashboard")
        if window.frame.origin == .zero { window.center() }

        let scroll = NSScrollView()
        scroll.documentView = table.tableView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(scroll)
        split.addArrangedSubview(detail)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        split.autosaveName = "VigilDashboardSplit"
        window.contentView = split
        detail.setFrameSize(CGSize(width: 960, height: 170))

        let toolbar = NSToolbar(identifier: "VigilDashboard")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        search.searchField.placeholderString = "Filter (name, user, PID, or /regex/)"
        search.searchField.delegate = self
        viewMode.selectedSegment = 0
        viewMode.target = self
        viewMode.action = #selector(viewModeChanged)
        viewMode.toolTip = "List or tree (T)"

        table.units = settings.settings.units
        table.onSelectionChange = { [weak self] identity in
            self?.store.focusedProcess = identity
            self?.refreshDetail()
        }
        table.tableView.keyHandler = { [weak self] in self?.handleKey($0) ?? false }
        table.tableView.doubleAction = #selector(revealSelected)
        table.tableView.target = self
        let menu = NSMenu()
        menu.delegate = self
        table.tableView.menu = menu

        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.updateDemand() } })
        coordinator.observeTicks(self) { [weak self] in self?.tick() }
    }

    func show(selecting identity: ProcessIdentity? = nil) {
        NSApp.setActivationPolicy(.regular)  // a Dock icon while the Dashboard is open
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(table.tableView)
        // First launch (nothing autosaved): give the table most of the height.
        if detail.frame.height > 240 {
            split.setPosition(split.bounds.height - 180, ofDividerAt: 0)
        }
        if let processes = store.processes { table.update(processes) }
        if let identity { table.select(identity) }
        updateDemand()
    }

    // MARK: - Ticks & demand

    private func tick() {
        guard window.isVisible, window.occlusionState.contains(.visible), let processes = store.processes else {
            return
        }
        table.units = settings.settings.units
        table.update(processes)
        refreshDetail()
        let restricted = processes.restrictedCount
        window.subtitle =
            "\(processes.processes.count) processes" + (restricted > 0 ? " · \(restricted) not measured" : "")
    }

    private func refreshDetail() {
        let entry = table.selectedEntry
        detail.show(entry, store: store, units: settings.settings.units, icon: entry.flatMap(icon(for:)))
    }

    /// Processes (with thread counts) are sampled only while the Dashboard is visible.
    private func updateDemand() {
        let visible = window.isVisible && window.occlusionState.contains(.visible)
        coordinator.extraDemand = visible ? [.processes, .processDetails] : []
    }

    func windowWillClose(_ notification: Notification) {
        coordinator.extraDemand = []
        coordinator.stopObservingTicks(self)
        store.focusedProcess = nil
        NSApp.setActivationPolicy(.accessory)
        onClose?()
    }

    // MARK: - Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.viewMode, .signal, .flexibleSpace, .search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case .search:
            return search
        case .viewMode:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = viewMode
            item.label = "View"
            return item
        case .signal:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "bolt.horizontal.circle", accessibilityDescription: "Send Signal")
            item.label = "Send Signal"
            item.toolTip = "Send a signal to the selected process (S or ⌘⌫)"
            item.target = self
            item.action = #selector(signalSelected)
            return item
        default:
            return nil
        }
    }

    @objc private func viewModeChanged() { table.query.tree = viewMode.selectedSegment == 1 }

    func controlTextDidChange(_ notification: Notification) {
        table.query.filter = search.searchField.stringValue
    }

    // MARK: - Actions

    @objc func signalSelected() {
        guard let entry = table.selectedEntry else { return }
        SignalSheet.present(for: entry, on: window)
    }

    @objc private func revealSelected() {
        guard let path = table.selectedEntry?.path else { return }
        let target = path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" } ?? path
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
    }

    private var detailIcon: (ProcessIdentity, NSImage?)?

    /// The detail pane's 32 pt icon, rendered once per selected process.
    private func icon(for entry: ProcessEntry) -> NSImage? {
        if let detailIcon, detailIcon.0 == entry.id { return detailIcon.1 }
        let image = entry.path.map { path in
            let target = path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" } ?? path
            return ProcessTable.thumbnail(NSWorkspace.shared.icon(forFile: target), points: 32)
        }
        detailIcon = (entry.id, image)
        return image
    }

    /// btop-style keys (SPEC §3.7). Returns `true` when handled.
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            if event.keyCode == 51 {  // ⌘⌫
                signalSelected()
                return true
            }
            return false
        }
        switch (event.keyCode, event.charactersIgnoringModifiers ?? "") {
        case (_, "j"): moveSelection(by: 1)
        case (_, "k"): moveSelection(by: -1)
        case (36, _), (76, _): toggleDetail()  // Return, Enter
        case (_, "/"), (_, "f"): window.makeFirstResponder(search.searchField)
        case (_, "t"):
            viewMode.selectedSegment = table.query.tree ? 0 : 1
            viewModeChanged()
        case (_, "h"): table.shiftSortColumn(by: -1)
        case (_, "l"): table.shiftSortColumn(by: 1)
        case (123, _), (124, _):
            // In a tree: collapse/expand the selection, like Finder. In a list: change sort column.
            if table.query.tree, let entry = table.selectedEntry {
                let collapsed = table.query.collapsed.contains(entry.id)
                if (event.keyCode == 123) != collapsed { table.toggle(entry.id) }
            } else {
                table.shiftSortColumn(by: event.keyCode == 123 ? -1 : 1)
            }
        case (_, "r"): table.reverseSort()
        case (_, "p"): onCycleLayout?(1)
        case (_, "P"): onCycleLayout?(-1)
        case (_, "s"): signalSelected()
        case (49, _):  // Space
            let paused = togglePause()
            window.subtitle = paused ? "Paused — press Space to resume" : window.subtitle
        default:
            return false
        }
        return true
    }

    private func moveSelection(by offset: Int) {
        let tableView = table.tableView
        let next = min(max(tableView.selectedRow + offset, 0), tableView.numberOfRows - 1)
        guard next >= 0, next < table.rows.count else { return }
        table.select(table.rows[next].entry.id)
    }

    private func toggleDetail() {
        detail.isHidden.toggle()
        split.adjustSubviews()
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.tableView.clickedRow
        guard row >= 0, row < table.rows.count else { return }
        let entry = table.rows[row].entry
        table.select(entry.id)
        func item(_ title: String, _ action: @escaping () -> Void) {
            let menuItem = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
            let target = MenuAction(action)
            menuItem.target = target
            menuItem.representedObject = target  // keeps the target alive with the item
            menu.addItem(menuItem)
        }
        item("Send Signal…") { [weak self] in self?.signalSelected() }
        if entry.path != nil { item("Show in Finder") { [weak self] in self?.revealSelected() } }
        menu.addItem(.separator())
        item("Copy PID") { Self.copy(String(entry.pid)) }
        if let path = entry.path { item("Copy Path") { Self.copy(path) } }
        if !entry.isRestricted {
            item("Copy Command Line") {
                Self.copy(ProcessArguments.read(entry.pid)?.joined(separator: " ") ?? entry.path ?? entry.name)
            }
        }
    }

    private static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// Wraps a closure as an Objective-C action target for menu items.
@MainActor
private final class MenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

extension NSToolbarItem.Identifier {
    static let search = Self("search")
    static let viewMode = Self("viewMode")
    static let signal = Self("signal")
}
