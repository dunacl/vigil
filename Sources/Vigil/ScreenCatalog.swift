// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import AppKit
import VigilCore

/// Bridges `NSScreen` to the layout engine's ``ScreenInfo``.
@MainActor
enum ScreenCatalog {
    /// Connected screens. The first `NSScreen` is the one with the menu bar,
    /// which is what "Main display" means to users.
    static func current() -> [ScreenInfo] {
        NSScreen.screens.enumerated().compactMap { index, screen in
            guard let uuid = uuid(of: screen) else { return nil }
            return ScreenInfo(
                uuid: uuid, name: screen.localizedName, isMain: index == 0, frame: Rect(screen.frame),
                visibleFrame: Rect(screen.visibleFrame))
        }
    }

    static func uuid(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
            let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

extension Rect {
    init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
    }
}

extension CGRect {
    init(_ rect: Rect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.size.width, height: rect.size.height)
    }
}
