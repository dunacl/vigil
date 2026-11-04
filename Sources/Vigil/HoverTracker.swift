// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import AppKit

/// Reports pointer movement for hover fade. Installed only while some panel
/// uses hover, and purely event-driven: a global monitor sees moves over other
/// apps (and over hidden, click-through panels), a local one over our own windows.
/// Mouse monitors need no Accessibility permission (SPEC §10).
@MainActor
final class HoverTracker {
    private var monitors: [Any] = []
    private var handler: ((CGPoint) -> Void)?

    func start(_ handler: @escaping (CGPoint) -> Void) {
        self.handler = handler
        guard monitors.isEmpty else { return }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: events,
            handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.handler?(NSEvent.mouseLocation) }
            })
        {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: events,
            handler: { [weak self] event in
                MainActor.assumeIsolated { self?.handler?(NSEvent.mouseLocation) }
                return event
            })
        {
            monitors.append(local)
        }
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        handler = nil
    }
}
