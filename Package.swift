// swift-tools-version: 6.2
// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import PackageDescription

let package = Package(
    name: "Vigil",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "VigilCore", targets: ["VigilCore"]),
        .library(name: "VigilUI", targets: ["VigilUI"]),
        .executable(name: "Vigil", targets: ["Vigil"]),
        .executable(name: "vigil-probe", targets: ["vigil-probe"]),
    ],
    targets: [
        // Declarations and inline shims for system interfaces Swift can't import directly.
        .target(name: "CVigilSys"),
        // Collectors, metrics, sampling, history. No UI imports.
        .target(
            name: "VigilCore",
            dependencies: ["CVigilSys"],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("SystemConfiguration")]
        ),
        // Panel views, graphs, glass. SwiftUI + AppKit; no window management.
        .target(name: "VigilUI", dependencies: ["VigilCore"]),
        // The app: desktop panel windows, Spaces, status item, lifecycle.
        .executableTarget(name: "Vigil", dependencies: ["VigilCore", "VigilUI", "CVigilSys"]),
        // Command-line debug dump and micro-benchmark for VigilCore.
        .executableTarget(name: "vigil-probe", dependencies: ["VigilCore"]),
        .testTarget(name: "VigilCoreTests", dependencies: ["VigilCore"]),
        .testTarget(name: "VigilUITests", dependencies: ["VigilUI", "VigilCore"]),
    ],
    swiftLanguageModes: [.v6]
)
