// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

/// A connected display, as the layout engine sees it.
public struct ScreenInfo: Sendable, Hashable {
    public var uuid: String
    public var name: String
    public var isMain: Bool
    /// Full frame in global AppKit coordinates.
    public var frame: Rect
    /// Frame excluding menu bar, notch and Dock.
    public var visibleFrame: Rect

    public init(uuid: String, name: String, isMain: Bool, frame: Rect, visibleFrame: Rect) {
        self.uuid = uuid
        self.name = name
        self.isMain = isMain
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

/// Where a placement ended up on the current set of screens.
public struct ResolvedPlacement: Sendable, Hashable {
    public var screen: ScreenInfo
    /// Window frame in global AppKit coordinates.
    public var frame: Rect
    /// `true` when the placement's display isn't connected and the main display
    /// is used instead. The saved placement is left untouched so the panel
    /// returns when its display reconnects.
    public var isOnFallbackDisplay: Bool
}

/// Pure placement math: placement + screens → window frame, and back.
///
/// Runs only on events (layout edit, display change), never per tick.
public enum PlacementResolver {
    public static func resolve(_ placement: Placement, screens: [ScreenInfo]) -> ResolvedPlacement? {
        guard let main = screens.first(where: \.isMain) ?? screens.first else { return nil }
        var screen = main
        var fallback = false
        if case .uuid(let uuid) = placement.display {
            if let match = screens.first(where: { $0.uuid == uuid }) {
                screen = match
            } else {
                fallback = true
            }
        }
        let frame = clamp(frame(for: placement, in: screen.visibleFrame), to: screen.visibleFrame)
        return ResolvedPlacement(screen: screen, frame: frame, isOnFallbackDisplay: fallback)
    }

    /// Unclamped frame for a placement within `area`.
    static func frame(for placement: Placement, in area: Rect) -> Rect {
        let size = placement.size, offset = placement.offset
        let x: Double =
            switch placement.anchor.horizontal {
            case .leading: area.minX + offset.x
            case .center: area.midX - size.width / 2 + offset.x
            case .trailing: area.maxX - offset.x - size.width
            }
        let y: Double =
            switch placement.anchor.vertical {
            case .top: area.maxY - offset.y - size.height
            case .center: area.midY - size.height / 2 - offset.y
            case .bottom: area.minY + offset.y
            }
        return Rect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Keeps a frame fully inside `area` (or pinned to its top-left if larger).
    public static func clamp(_ frame: Rect, to area: Rect) -> Rect {
        let width = min(frame.size.width, area.size.width)
        let height = min(frame.size.height, area.size.height)
        let x = min(max(frame.minX, area.minX), area.maxX - width)
        let y = min(max(frame.minY, area.minY), area.maxY - height)
        return Rect(x: x, y: y, width: width, height: height)
    }

    /// The inverse: describes a window frame on a screen as a placement anchored
    /// to the nearest of the nine anchors. Used when a panel is dropped after a drag.
    public static func placement(
        for frame: Rect, on screen: ScreenInfo, display: DisplayRef, desktop: DesktopRef
    ) -> Placement {
        let area = screen.visibleFrame
        func third(_ value: Double, _ low: Double, _ length: Double) -> Int {
            guard length > 0 else { return 1 }
            return min(2, max(0, Int((value - low) / (length / 3))))
        }
        let column = third(frame.midX, area.minX, area.size.width)
        let row = third(frame.midY, area.minY, area.size.height)  // 0 = bottom
        let horizontal: Anchor.Horizontal = [.leading, .center, .trailing][column]
        let vertical: Anchor.Vertical = [.bottom, .center, .top][row]

        let x: Double =
            switch horizontal {
            case .leading: frame.minX - area.minX
            case .center: frame.midX - area.midX
            case .trailing: area.maxX - frame.maxX
            }
        let y: Double =
            switch vertical {
            case .top: area.maxY - frame.maxY
            case .center: area.midY - frame.midY
            case .bottom: frame.minY - area.minY
            }
        return Placement(
            display: display, anchor: Anchor(horizontal, vertical), offset: Point(x: x, y: y), size: frame.size,
            desktop: desktop)
    }
}
