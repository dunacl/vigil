// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

// Minimal geometry types so the layout engine stays free of AppKit and
// CoreGraphics. Coordinates follow AppKit: origin at bottom-left, y up.

public struct Point: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
    public static let zero = Point(x: 0, y: 0)
}

public struct Size: Codable, Sendable, Hashable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct Rect: Codable, Sendable, Hashable {
    public var origin: Point
    public var size: Size

    public init(x: Double, y: Double, width: Double, height: Double) {
        origin = Point(x: x, y: y)
        size = Size(width: width, height: height)
    }

    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.width }
    public var maxY: Double { origin.y + size.height }
    public var midX: Double { origin.x + size.width / 2 }
    public var midY: Double { origin.y + size.height / 2 }
}
