// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.
//
// Lists Vigil's on-screen windows, one per line, tab-separated:
//   window-number  level  x  y  width  height  title
// (top-left screen coordinates, points). Used by make-screenshots.sh.

import CoreGraphics

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows where window[kCGWindowOwnerName as String] as? String == "Vigil" {
    let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
    let fields: [String] = [
        "\(window[kCGWindowNumber as String] as? Int ?? 0)",
        "\(window[kCGWindowLayer as String] as? Int ?? 0)",
        "\(Int(bounds["X"] ?? 0))", "\(Int(bounds["Y"] ?? 0))",
        "\(Int(bounds["Width"] ?? 0))", "\(Int(bounds["Height"] ?? 0))",
        window[kCGWindowName as String] as? String ?? "",
    ]
    print(fields.joined(separator: "\t"))
}
