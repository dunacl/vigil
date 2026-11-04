// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import Darwin

/// Snapping and overlap rules for Edit Mode. Pure geometry in global AppKit
/// coordinates; called on every mouse-drag event, so no allocation beyond the
/// small guide array.
public struct SnapSettings: Sendable, Hashable {
    /// Grid step in points; 0 disables the grid.
    public var grid: Double = 8
    /// How close (pt) an edge must come before it snaps to a target.
    public var threshold: Double = 8
    /// Distance kept from the edges of the visible frame.
    public var margin: Double = 16
    /// Preferred gap between neighboring panels.
    public var gap: Double = 12

    public init() {}
}

/// A line to draw while dragging, showing what the panel snapped to.
public struct SnapGuide: Sendable, Hashable {
    public enum Axis: Sendable, Hashable {
        /// A vertical line at `x`.
        case vertical(x: Double)
        /// A horizontal line at `y`.
        case horizontal(y: Double)
    }

    public var axis: Axis
    /// Extent along the line (y range for vertical, x range for horizontal).
    public var from: Double
    public var to: Double
}

public enum Snapper {
    /// Snaps a moving frame to screen edges, other panels (edges, centers and
    /// neighbor gaps) and, failing those, the grid. Each axis snaps independently.
    public static func snap(
        _ frame: Rect, others: [Rect], area: Rect, settings: SnapSettings
    ) -> (frame: Rect, guides: [SnapGuide]) {
        var result = frame
        var guides: [SnapGuide] = []

        // Horizontal position: candidate (target x for minX, guide x, related rect).
        var xTargets: [(minX: Double, guideX: Double, related: Rect?)] = [
            (area.minX + settings.margin, area.minX + settings.margin, nil),
            (area.maxX - settings.margin - frame.size.width, area.maxX - settings.margin, nil),
            (area.midX - frame.size.width / 2, area.midX, nil),
        ]
        var yTargets: [(minY: Double, guideY: Double, related: Rect?)] = [
            (area.minY + settings.margin, area.minY + settings.margin, nil),
            (area.maxY - settings.margin - frame.size.height, area.maxY - settings.margin, nil),
            (area.midY - frame.size.height / 2, area.midY, nil),
        ]
        for other in others {
            xTargets += [
                (other.minX, other.minX, other),  // left edges aligned
                (other.maxX - frame.size.width, other.maxX, other),  // right edges aligned
                (other.midX - frame.size.width / 2, other.midX, other),  // centers aligned
                (other.maxX + settings.gap, other.maxX + settings.gap, other),  // to the right, with gap
                (other.minX - settings.gap - frame.size.width, other.minX - settings.gap, other),  // to the left
            ]
            yTargets += [
                (other.minY, other.minY, other),
                (other.maxY - frame.size.height, other.maxY, other),
                (other.midY - frame.size.height / 2, other.midY, other),
                (other.maxY + settings.gap, other.maxY + settings.gap, other),  // above, with gap
                (other.minY - settings.gap - frame.size.height, other.minY - settings.gap, other),  // below
            ]
        }

        if let best = xTargets.min(by: { abs($0.minX - frame.minX) < abs($1.minX - frame.minX) }),
            abs(best.minX - frame.minX) <= settings.threshold
        {
            result.origin.x = best.minX
            let span =
                best.related.map { (min($0.minY, frame.minY), max($0.maxY, frame.maxY)) }
                ?? (area.minY, area.maxY)
            guides.append(SnapGuide(axis: .vertical(x: best.guideX), from: span.0, to: span.1))
        } else if settings.grid > 0 {
            result.origin.x = area.minX + ((frame.minX - area.minX) / settings.grid).rounded() * settings.grid
        }

        if let best = yTargets.min(by: { abs($0.minY - frame.minY) < abs($1.minY - frame.minY) }),
            abs(best.minY - frame.minY) <= settings.threshold
        {
            result.origin.y = best.minY
            let span =
                best.related.map { (min($0.minX, frame.minX), max($0.maxX, frame.maxX)) }
                ?? (area.minX, area.maxX)
            guides.append(SnapGuide(axis: .horizontal(y: best.guideY), from: span.0, to: span.1))
        } else if settings.grid > 0 {
            result.origin.y = area.minY + ((frame.minY - area.minY) / settings.grid).rounded() * settings.grid
        }
        return (result, guides)
    }

    /// If `frame` overlaps any of `others`, returns the nearest position inside
    /// `area` that doesn't (trying spots beside each other panel), else `frame`.
    public static func resolveOverlap(_ frame: Rect, others: [Rect], area: Rect, gap: Double) -> Rect {
        guard others.contains(where: { $0.intersects(frame) }) else { return frame }
        let width = frame.size.width, height = frame.size.height
        var candidates: [Rect] = []
        for other in others {
            candidates += [
                Rect(x: other.maxX + gap, y: frame.minY, width: width, height: height),
                Rect(x: other.minX - gap - width, y: frame.minY, width: width, height: height),
                Rect(x: frame.minX, y: other.maxY + gap, width: width, height: height),
                Rect(x: frame.minX, y: other.minY - gap - height, width: width, height: height),
                Rect(x: other.minX, y: other.minY - gap - height, width: width, height: height),
                Rect(x: other.maxX + gap, y: other.maxY - height, width: width, height: height),
            ]
        }
        let valid = candidates.filter { candidate in
            candidate.minX >= area.minX && candidate.maxX <= area.maxX && candidate.minY >= area.minY
                && candidate.maxY <= area.maxY && !others.contains(where: { $0.intersects(candidate) })
        }
        func distance(_ rect: Rect) -> Double {
            let dx = rect.minX - frame.minX, dy = rect.minY - frame.minY
            return dx * dx + dy * dy
        }
        return valid.min { distance($0) < distance($1) } ?? frame
    }
}

extension Rect {
    /// `true` when the two rects share interior area (touching edges don't count).
    public func intersects(_ other: Rect) -> Bool {
        minX < other.maxX && other.minX < maxX && minY < other.maxY && other.minY < maxY
    }
}

extension SizeClass {
    /// The content layout for an arbitrary (freeform) size.
    public static func layout(for size: Size) -> SizeClass {
        if size.height < 90 { return .extraSmall }
        return size.width >= 260 && size.height >= 150 ? .medium : .small
    }

    /// The smallest size any panel may be resized to.
    public static let minimumSize = Size(width: 120, height: 56)

    /// The size class whose default size is closest to `size`.
    public static func nearest(to size: Size) -> SizeClass {
        allCases.min {
            hypot($0.size.width - size.width, $0.size.height - size.height)
                < hypot($1.size.width - size.width, $1.size.height - size.height)
        } ?? .medium
    }
}
