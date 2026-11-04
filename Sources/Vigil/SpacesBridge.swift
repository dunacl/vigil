// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import AppKit
import CVigilSys
import os

/// Pins windows to a specific desktop ("Desktop N") using undocumented SkyLight
/// calls (SPEC §11). Everything else in Vigil uses public API.
///
/// Symbols are resolved once with `dlsym`; if any is missing, ``shared`` is `nil`
/// and the app offers only "All desktops" / "This desktop".
@MainActor
final class SpacesBridge {
    /// Desktops of one display, in Mission Control order.
    struct DisplaySpaces: Equatable {
        /// Display UUID string, or `"Main"` when "Displays have separate Spaces" is off.
        var displayIdentifier: String
        var desktops: [UInt64]
        var current: UInt64?
    }

    static let shared: SpacesBridge? = SpacesBridge()
    private static let log = Logger(subsystem: "app.vigil", category: "spaces")

    private let connection: VigilCGSConnectionID
    private let copyManagedDisplaySpaces: VigilSLSCopyManagedDisplaySpacesFn
    private let copySpacesForWindows: VigilSLSCopySpacesForWindowsFn
    private let moveWindowsToManagedSpace: VigilSLSMoveWindowsToManagedSpaceFn

    private init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
            let main = dlsym(handle, "SLSMainConnectionID"),
            let displaySpaces = dlsym(handle, "SLSCopyManagedDisplaySpaces"),
            let spacesForWindows = dlsym(handle, "SLSCopySpacesForWindows"),
            let move = dlsym(handle, "SLSMoveWindowsToManagedSpace")
        else {
            Self.log.notice("SkyLight Spaces symbols unavailable; Desktop N disabled")
            return nil
        }
        connection = unsafeBitCast(main, to: VigilSLSMainConnectionIDFn.self)()
        copyManagedDisplaySpaces = unsafeBitCast(displaySpaces, to: VigilSLSCopyManagedDisplaySpacesFn.self)
        copySpacesForWindows = unsafeBitCast(spacesForWindows, to: VigilSLSCopySpacesForWindowsFn.self)
        moveWindowsToManagedSpace = unsafeBitCast(move, to: VigilSLSMoveWindowsToManagedSpaceFn.self)
    }

    /// Current desktops per display. Full-screen app Spaces are excluded.
    func displays() -> [DisplaySpaces] {
        guard let raw = copyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { display in
            guard let identifier = display["Display Identifier"] as? String else { return nil }
            let spaces = display["Spaces"] as? [[String: Any]] ?? []
            let desktops = spaces.compactMap { space -> UInt64? in
                guard (space["type"] as? Int) == 0 else { return nil }  // 0 = user desktop
                return (space["ManagedSpaceID"] as? NSNumber)?.uint64Value
            }
            let current = ((display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value
            return DisplaySpaces(displayIdentifier: identifier, desktops: desktops, current: current)
        }
    }

    /// The space ID of desktop `index` (1-based) on the given display, if it exists.
    func space(desktop index: Int, displayUUID: String) -> UInt64? {
        let all = displays()
        let display = all.first { $0.displayIdentifier == displayUUID } ?? all.first { $0.displayIdentifier == "Main" }
        guard let display, index >= 1, index <= display.desktops.count else { return nil }
        return display.desktops[index - 1]
    }

    func spaces(of window: NSWindow) -> [UInt64] {
        let numbers = [NSNumber(value: window.windowNumber)] as CFArray
        let result = copySpacesForWindows(connection, Int32(VigilCGSSpaceMaskAll), numbers)?.takeRetainedValue()
        return (result as? [NSNumber])?.map(\.uint64Value) ?? []
    }

    /// Moves `window` onto exactly `space`. No-op when it's already there.
    /// Returns `false` if the window server didn't apply it.
    @discardableResult
    func pin(_ window: NSWindow, to space: UInt64) -> Bool {
        guard window.windowNumber > 0 else { return false }
        if spaces(of: window) == [space] { return true }
        moveWindowsToManagedSpace(connection, [NSNumber(value: window.windowNumber)] as CFArray, space)
        let applied = spaces(of: window) == [space]
        if !applied { Self.log.error("Could not pin window \(window.windowNumber) to space \(space)") }
        return applied
    }
}
