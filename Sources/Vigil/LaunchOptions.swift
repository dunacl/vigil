// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import VigilCore

/// Developer flags. Normal launches pass none.
///
///     Vigil --desktop 2                 pin the standard panels to Desktop 2
///     Vigil --list-spaces               print desktops per display and exit
///     Vigil --layout-file PATH          use this layout file instead of Application Support
///     Vigil --edit | --gallery | --inspect ID
///                                       open Edit Mode (optionally the Gallery or a
///                                       panel's settings) on launch, for testing
///     Vigil --settings [tab]            open Settings on launch (general, appearance,
///                                       layouts or alerts)
///     Vigil --dashboard                 open the process Dashboard on launch
///     Vigil --preset NAME               start with a preset layout (standard, minimal,
///                                       btop, sidebar, developer); use with --layout-file
///     Vigil --measure --panels N --seconds S [--material glass|clearGlass|solid] [--static]
///                                       panel cost harness: N floating Medium CPU
///                                       panels, report footprint/CPU as JSON, exit.
///                                       --static stops content updates after warm-up
///                                       data arrives (isolates glass vs commit cost)
struct LaunchOptions {
    var desktop: Int?
    var listSpaces = false
    var layoutFile: String?
    var edit = false
    var gallery = false
    var inspect: String?
    /// `--settings [general|appearance|layouts|alerts]`
    var settingsTab: SettingsTab?
    var dashboard = false
    /// `--preset btop`: start with that preset as the active layout (measurement, screenshots).
    var preset: LayoutPreset?
    var measure = false
    var measurePanels = 1
    var measureSeconds = 60.0
    var measureWarmup = 10.0
    var measureMaterial = "glass"
    var measureStatic = false

    init(_ arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--desktop": desktop = iterator.next().flatMap { Int($0) }
            case "--list-spaces": listSpaces = true
            case "--layout-file": layoutFile = iterator.next()
            case "--edit": edit = true
            case "--gallery": gallery = true
            case "--inspect": inspect = iterator.next()
            case "--settings":
                settingsTab = .general
                if let next = iterator.next() {
                    switch next {
                    case "appearance": settingsTab = .appearance
                    case "layouts": settingsTab = .layouts
                    case "alerts": settingsTab = .alerts
                    default: break
                    }
                }
            case "--dashboard": dashboard = true
            case "--preset": preset = iterator.next().flatMap(LayoutPreset.init(rawValue:))
            case "--measure": measure = true
            case "--panels": measurePanels = iterator.next().flatMap { Int($0) } ?? measurePanels
            case "--seconds": measureSeconds = iterator.next().flatMap { Double($0) } ?? measureSeconds
            case "--warmup": measureWarmup = iterator.next().flatMap { Double($0) } ?? measureWarmup
            case "--material": measureMaterial = iterator.next() ?? "glass"
            case "--static": measureStatic = true
            default: continue  // ignore flags AppKit passes (e.g. -NSDocumentRevisionsDebugMode)
            }
        }
    }
}
