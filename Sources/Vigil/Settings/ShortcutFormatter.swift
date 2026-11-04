// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import AppKit
import Carbon.HIToolbox
import VigilCore

/// Converts between key events, Carbon hotkey values and display strings ("⌃⌥E").
enum ShortcutFormatter {
    /// Names for the keys a global shortcut is likely to use (ANSI layout).
    private static let keyNames: [Int: String] = {
        var names: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
            kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
            kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Escape: "⎋", kVK_Tab: "⇥", kVK_ANSI_Comma: ",",
            kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Semicolon: ";", kVK_ANSI_Minus: "-",
            kVK_ANSI_Equal: "=",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        ]
        let functionKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
        ]
        for (index, code) in functionKeys.enumerated() { names[code] = "F\(index + 1)" }
        return names
    }()

    static func string(_ shortcut: KeyShortcut) -> String {
        let flags = shortcut.modifiers
        var text = ""
        if flags & UInt32(controlKey) != 0 { text += "⌃" }
        if flags & UInt32(optionKey) != 0 { text += "⌥" }
        if flags & UInt32(shiftKey) != 0 { text += "⇧" }
        if flags & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + (keyNames[Int(shortcut.keyCode)] ?? "Key \(shortcut.keyCode)")
    }

    /// A shortcut from a key event, or `nil` if it has no ⌃/⌥/⌘ (plain keys
    /// would steal typing system-wide) or the key can't be named.
    static func shortcut(from event: NSEvent) -> KeyShortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.isDisjoint(with: [.control, .option, .command]), keyNames[Int(event.keyCode)] != nil else {
            return nil
        }
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        return KeyShortcut(keyCode: UInt32(event.keyCode), modifiers: carbon)
    }

    /// For showing the shortcut in a menu (menus only display it; the hotkey does the work).
    static func keyEquivalent(_ keyCode: UInt32) -> String? {
        guard let name = keyNames[Int(keyCode)] else { return nil }
        if name == "Space" { return " " }
        return name.count == 1 ? name.lowercased() : nil
    }

    static func modifierFlags(_ carbon: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbon & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbon & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbon & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbon & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }
}
