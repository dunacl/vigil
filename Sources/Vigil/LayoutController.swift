// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import AppKit
import Observation
import VigilCore
import os

/// The single owner of the saved layouts. Every change goes through
/// ``change(_:_:)`` or ``changeLibrary(_:_:)``, which register undo, apply the
/// result to the desktop and schedule a (debounced) save — so those three can
/// never disagree. Undo snapshots the whole library, so deleting or renaming a
/// layout is undoable too.
@MainActor @Observable
final class LayoutController {
    private(set) var library: LayoutLibrary
    /// The layout on the desktop.
    var profile: LayoutProfile { library.active }
    @ObservationIgnored let undoManager = UndoManager()
    @ObservationIgnored private let coordinator: DesktopCoordinator
    @ObservationIgnored private let fileStore: LayoutFileStore?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Set while a drag is in progress; saves wait until it ends (SPEC §9).
    @ObservationIgnored var isInteracting = false {
        didSet { if !isInteracting, oldValue, saveTask == nil, hasUnsavedChanges { scheduleSave() } }
    }
    @ObservationIgnored private var hasUnsavedChanges = false
    private static let log = Logger(subsystem: "app.vigil", category: "layout")

    /// Called after every change (undo/redo included), e.g. to refresh menus.
    @ObservationIgnored var onChange: (() -> Void)?

    init(coordinator: DesktopCoordinator, fileStore: LayoutFileStore?) {
        self.coordinator = coordinator
        self.fileStore = fileStore
        if let loaded = fileStore?.load() {
            library = loaded.library
            switch loaded.source {
            case .backup: Self.log.error("Layout file unreadable; restored the backup")
            case .legacy: hasUnsavedChanges = true  // write the migrated library on first save
            case .file: break
            }
        } else {
            library = LayoutLibrary(profiles: [.standard])
        }
        undoManager.levelsOfUndo = 100
    }

    /// Shows the current layout.
    func start() {
        coordinator.show(profile)
        if hasUnsavedChanges { scheduleSave() }
    }

    // MARK: - Changes

    /// Applies `edit` to the active layout as one undoable step named `actionName`.
    func change(_ actionName: String, _ edit: (inout LayoutProfile) -> Void) {
        changeLibrary(actionName) { library in
            var active = library.active
            edit(&active)
            library.active = active
        }
    }

    /// Applies `edit` to the whole library (add, rename, delete, switch…) as one undoable step.
    func changeLibrary(_ actionName: String, _ edit: (inout LayoutLibrary) -> Void) {
        var next = library
        edit(&next)
        guard next != library else { return }
        replace(with: next, actionName: actionName, undoable: true)
    }

    private func replace(with next: LayoutLibrary, actionName: String, undoable: Bool) {
        let previous = library
        if undoable {
            undoManager.registerUndo(withTarget: self) { controller in
                MainActor.assumeIsolated { controller.replace(with: previous, actionName: actionName, undoable: true) }
            }
            undoManager.setActionName(actionName)
        }
        library = next
        coordinator.show(profile)
        hasUnsavedChanges = true
        if !isInteracting { scheduleSave() }
        onChange?()
    }

    // MARK: - Layouts

    func activate(_ id: String) {
        guard id != library.activeID else { return }
        changeLibrary("Switch Layout") { $0.activate(id) }
    }

    /// Activates the layout bound to exactly these displays, if any. Driven by
    /// the system, so it isn't an undo step.
    func autoSwitch(toDisplays displays: Set<String>) {
        guard let match = library.profile(forDisplays: displays), match.id != library.activeID else { return }
        var next = library
        next.activate(match.id)
        Self.log.info("Displays changed; switched to layout \(match.name, privacy: .public)")
        replace(with: next, actionName: "Switch Layout", undoable: false)
    }

    /// Cycles through layouts (p / ⇧p in the Dashboard).
    func activateNeighbor(_ offset: Int) {
        let ids = library.profiles.map(\.id)
        guard ids.count > 1, let index = ids.firstIndex(of: library.activeID) else { return }
        activate(ids[(index + offset + ids.count) % ids.count])
    }

    @discardableResult
    func addLayout(_ profile: LayoutProfile, activate: Bool = true) -> String {
        var id = ""
        changeLibrary("New Layout") { id = $0.add(profile, activate: activate) }
        return id
    }

    // MARK: - Panels in the active layout

    func updatePanel(_ id: String, _ actionName: String, _ edit: (inout PanelInstance) -> Void) {
        change(actionName) { profile in
            guard let index = profile.panels.firstIndex(where: { $0.id == id }) else { return }
            edit(&profile.panels[index])
        }
    }

    func setVisible(_ visible: Bool, panel id: String) {
        updatePanel(id, visible ? "Show Panel" : "Hide Panel") { $0.isVisible = visible }
    }

    func remove(_ ids: Set<String>) {
        change(ids.count == 1 ? "Remove Panel" : "Remove Panels") { $0.panels.removeAll { ids.contains($0.id) } }
    }

    /// Adds a panel at the first free spot near the top-right of the main display.
    @discardableResult
    func add(kind: PanelKind, sizeClass: SizeClass) -> String {
        let id = "\(kind.rawValue)-\(UUID().uuidString.prefix(8).lowercased())"
        let screens = ScreenCatalog.current()
        var placement = Placement(
            display: .main, anchor: .topTrailing, offset: Point(x: 16, y: 16), size: sizeClass.size)
        if let main = screens.first(where: \.isMain),
            let resolved = PlacementResolver.resolve(placement, screens: screens)
        {
            let others = coordinator.visibleFrames(excluding: []).map(Rect.init)
            let free = Snapper.resolveOverlap(resolved.frame, others: others, area: main.visibleFrame, gap: 12)
            placement = PlacementResolver.placement(for: free, on: main, display: .main, desktop: .all)
        }
        change("Add Panel") {
            $0.panels.append(PanelInstance(id: id, kind: kind, sizeClass: sizeClass, placement: placement))
        }
        return id
    }

    /// A copy of a panel, placed at the next free spot.
    func duplicatePanel(_ id: String) {
        guard let panel = profile.panels.first(where: { $0.id == id }) else { return }
        let newID = add(kind: panel.kind, sizeClass: panel.sizeClass)
        updatePanel(newID, "Duplicate Panel") { copy in
            copy.appearance = panel.appearance
            copy.options = panel.options
            copy.level = panel.level
            copy.clickThrough = panel.clickThrough
            copy.placement.size = panel.placement.size
        }
    }

    /// Moves every panel onto the main display (SPEC §7 "Lost panels").
    func gatherAll() {
        change("Gather Panels") { profile in
            for index in profile.panels.indices {
                profile.panels[index].placement.display = .main
                profile.panels[index].isVisible = true
            }
        }
    }

    // MARK: - Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard hasUnsavedChanges, let fileStore else { return }
        do {
            try fileStore.save(library)
            hasUnsavedChanges = false
        } catch {
            Self.log.error("Could not save layout: \(error.localizedDescription)")
        }
    }
}
