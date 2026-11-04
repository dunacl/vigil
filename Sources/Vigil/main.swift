// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import AppKit

// A plain AppKit lifecycle: lighter than the SwiftUI `App` scene machinery for an
// app that is only borderless panels and a status item.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate(options: LaunchOptions(CommandLine.arguments))
    app.delegate = delegate
    app.setActivationPolicy(.accessory)  // no Dock icon, no menu bar of our own
    withExtendedLifetime(delegate) { app.run() }
}
