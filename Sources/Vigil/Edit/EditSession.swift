// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import AppKit
import VigilCore
import VigilUI

/// Edit Mode (SPEC §3.4): panels rise above windows and can be selected, dragged
/// (with snapping), resized, nudged, inspected and removed. Every committed
/// change goes through ``LayoutController`` and is undoable.
@MainActor
final class EditSession {
    private let layout: LayoutController
    private let coordinator: DesktopCoordinator
    private let store: MetricsStore
    private let guides = GuideOverlay()
    private var toolbar: EditToolbar?
    private var gallery: GalleryWindow?
    private var inspector: NSPopover?
    private(set) var selection: Set<String> = []
    var snapSettings = SnapSettings()
    var onEnd: (() -> Void)?

    private enum Gesture {
        case move(primary: String, startMouse: CGPoint, startFrames: [String: CGRect])
        case resize(id: String, startMouse: CGPoint, startFrame: CGRect)
    }
    private var gesture: Gesture?

    init(layout: LayoutController, coordinator: DesktopCoordinator, store: MetricsStore) {
        self.layout = layout
        self.coordinator = coordinator
        self.store = store
    }

    func begin() {
        NSApp.activate()
        attachOverlays()
        let toolbar = EditToolbar(session: self)
        toolbar.show()
        self.toolbar = toolbar
    }

    func end() {
        inspector?.close()
        gallery?.close()
        gallery = nil
        toolbar?.close()
        toolbar = nil
        guides.hide()
        for controller in coordinator.controllers {
            controller.setOverlay(nil)
            controller.isEditing = false
        }
        layout.saveNow()
        onEnd?()
    }

    /// Called after every layout change: new panels need overlays, removed ones
    /// leave the selection.
    func layoutDidChange() {
        let ids = Set(coordinator.controllers.map(\.instance.id))
        selection.formIntersection(ids)
        attachOverlays()
        toolbar?.update(canUndo: layout.undoManager.canUndo, canRedo: layout.undoManager.canRedo)
    }

    private func attachOverlays() {
        for controller in coordinator.controllers {
            controller.isEditing = true
            if let overlay = controller.overlay as? EditOverlayView {
                overlay.isSelected = selection.contains(controller.instance.id)
            } else {
                controller.setOverlay(EditOverlayView(session: self, panelID: controller.instance.id))
            }
        }
    }

    // MARK: - Selection

    /// Gives Edit Mode keyboard focus (arrows, Delete, ⌘Z, Esc) after a click.
    func focusKeyboard() { toolbar?.takeFocus() }

    func select(_ id: String, extending: Bool) {
        if extending {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else if !selection.contains(id) {
            selection = [id]
        }
        attachOverlays()
    }

    func clearSelection() {
        selection = []
        attachOverlays()
    }

    // MARK: - Moving

    func beginMove(_ id: String, extending: Bool) {
        select(id, extending: extending)
        guard selection.contains(id) else { return }
        var frames: [String: CGRect] = [:]
        for selected in selection {
            if let controller = coordinator.controller(id: selected) { frames[selected] = controller.window.frame }
        }
        gesture = .move(primary: id, startMouse: NSEvent.mouseLocation, startFrames: frames)
        layout.isInteracting = true
    }

    func continueGesture(snapping: Bool, freeformResize: Bool) {
        switch gesture {
        case .move(let primary, let startMouse, let startFrames):
            guard let start = startFrames[primary] else { return }
            let mouse = NSEvent.mouseLocation
            var proposed = start.offsetBy(dx: mouse.x - startMouse.x, dy: mouse.y - startMouse.y)
            let screen = Self.screen(containing: mouse)
            var lines: [SnapGuide] = []
            if snapping, let screen {
                let others = coordinator.visibleFrames(excluding: selection).map(Rect.init)
                let snapped = Snapper.snap(
                    Rect(proposed), others: others, area: screen.visibleFrame, settings: snapSettings)
                proposed = CGRect(snapped.frame)
                lines = snapped.guides
            }
            let dx = proposed.minX - start.minX, dy = proposed.minY - start.minY
            for (id, frame) in startFrames {
                coordinator.controller(id: id)?.window.setFrameOrigin(CGPoint(x: frame.minX + dx, y: frame.minY + dy))
            }
            guides.show(lines)
        case .resize(let id, let startMouse, let start):
            guard let controller = coordinator.controller(id: id) else { return }
            let mouse = NSEvent.mouseLocation
            let minimum = SizeClass.minimumSize
            var width = max(minimum.width, start.width + mouse.x - startMouse.x)
            var height = max(minimum.height, start.height - (mouse.y - startMouse.y))
            if !freeformResize {
                // Magnetic size classes: within 16 pt, take the class's exact size.
                for sizeClass in SizeClass.allCases
                where abs(sizeClass.size.width - width) < 16 && abs(sizeClass.size.height - height) < 16 {
                    width = sizeClass.size.width
                    height = sizeClass.size.height
                }
            }
            // The top-left corner stays put; the grip can't pull the panel off its screen.
            if let area = Self.screenInfo(for: start, in: ScreenCatalog.current())?.visibleFrame {
                width = min(width, area.maxX - start.minX)
                height = min(height, start.maxY - area.minY)
            }
            controller.window.setFrame(
                CGRect(x: start.minX, y: start.maxY - height, width: width, height: height), display: true)
        case nil:
            break
        }
    }

    func endGesture() {
        defer {
            gesture = nil
            guides.hide()
            layout.isInteracting = false
        }
        switch gesture {
        case .move(_, _, let startFrames):
            commitFrames(Array(startFrames.keys), actionName: startFrames.count == 1 ? "Move Panel" : "Move Panels")
        case .resize(let id, _, _):
            commitFrames([id], actionName: "Resize Panel", resized: true)
        case nil:
            break
        }
    }

    func beginResize(_ id: String) {
        select(id, extending: false)
        guard let controller = coordinator.controller(id: id) else { return }
        gesture = .resize(id: id, startMouse: NSEvent.mouseLocation, startFrame: controller.window.frame)
        layout.isInteracting = true
    }

    /// Moves the selection by whole points (arrow keys).
    func nudge(dx: CGFloat, dy: CGFloat, byGrid: Bool) {
        guard !selection.isEmpty else { return }
        let step = byGrid ? CGFloat(snapSettings.grid) : 1
        for id in selection {
            guard let window = coordinator.controller(id: id)?.window else { continue }
            window.setFrameOrigin(CGPoint(x: window.frame.minX + dx * step, y: window.frame.minY + dy * step))
        }
        commitFrames(Array(selection), actionName: "Nudge", resolveOverlaps: false)
    }

    /// Turns the windows' current frames into placements and commits them as one step.
    private func commitFrames(
        _ ids: [String], actionName: String, resized: Bool = false, resolveOverlaps: Bool = true
    ) {
        let screens = ScreenCatalog.current()
        var frames: [String: CGRect] = [:]
        for id in ids {
            // Saved placements always describe an on-screen frame.
            guard let window = coordinator.controller(id: id)?.window,
                let screen = Self.screenInfo(for: window.frame, in: screens)
            else { continue }
            frames[id] = CGRect(PlacementResolver.clamp(Rect(window.frame), to: screen.visibleFrame))
        }
        // No-overlap applies to a single dropped panel (moving a group keeps its shape).
        if resolveOverlaps, ids.count == 1, let id = ids.first, var frame = frames[id],
            let screen = Self.screenInfo(for: frame, in: screens)
        {
            let others = coordinator.visibleFrames(excluding: [id]).map(Rect.init)
            frame = CGRect(
                Snapper.resolveOverlap(Rect(frame), others: others, area: screen.visibleFrame, gap: snapSettings.gap))
            frames[id] = frame
        }
        layout.change(actionName) { profile in
            for index in profile.panels.indices {
                let panel = profile.panels[index]
                guard let frame = frames[panel.id], let screen = Self.screenInfo(for: frame, in: screens) else {
                    continue
                }
                // Keep "Main display" when the panel stays on the main display.
                let display: DisplayRef =
                    (panel.placement.display == .main && screen.isMain) ? .main : .uuid(screen.uuid)
                profile.panels[index].placement = PlacementResolver.placement(
                    for: Rect(frame), on: screen, display: display, desktop: panel.placement.desktop)
                if resized {
                    profile.panels[index].sizeClass = SizeClass.layout(
                        for: Size(width: frame.width, height: frame.height))
                }
            }
        }
    }

    // MARK: - Panel actions

    func remove(_ id: String) { layout.remove([id]) }

    func removeSelection() {
        guard !selection.isEmpty else { return }
        layout.remove(selection)
    }

    func undo() { layout.undoManager.undo() }
    func redo() { layout.undoManager.redo() }

    func showGallery() {
        if let gallery {
            gallery.makeKeyAndOrderFront(nil)
            return
        }
        let gallery = GalleryWindow(store: store, coordinator: coordinator) { [weak self] kind, sizeClass in
            guard let self else { return }
            let id = self.layout.add(kind: kind, sizeClass: sizeClass)
            self.select(id, extending: false)
        }
        gallery.onClose = { [weak self] in self?.gallery = nil }
        gallery.makeKeyAndOrderFront(nil)
        self.gallery = gallery
    }

    func inspect(_ id: String, from view: NSView, rect: CGRect) {
        inspector?.close()
        guard let instance = layout.profile.panels.first(where: { $0.id == id }) else { return }
        let popover = PanelInspector.popover(
            for: instance,
            apply: { [weak self] updated in
                self?.layout.updatePanel(id, "Change Panel") { $0 = updated }
            },
            remove: { [weak self] in self?.remove(id) })
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        inspector = popover
    }

    // MARK: - Helpers

    private static func screen(containing point: CGPoint) -> ScreenInfo? {
        let screens = ScreenCatalog.current()
        return screens.first { CGRect($0.frame).contains(point) } ?? screens.first(where: \.isMain)
    }

    private static func screenInfo(for frame: CGRect, in screens: [ScreenInfo]) -> ScreenInfo? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return screens.first { CGRect($0.frame).contains(center) } ?? screens.first(where: \.isMain)
    }
}
