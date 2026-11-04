// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import AppKit
import VigilCore

/// "Send Signal…": pick a signal, confirm, and report the result (SPEC §3.2, §7).
@MainActor
enum SignalSheet {
    static func present(for entry: ProcessEntry, on window: NSWindow, preselect: ProcessSignal = .terminate) {
        let alert = NSAlert()
        alert.messageText = "Send a signal to “\(entry.name)”?"
        alert.informativeText = "PID \(entry.pid), owned by \(entry.user)."
        let popup = NSPopUpButton(frame: CGRect(x: 0, y: 0, width: 220, height: 26), pullsDown: false)
        for signal in ProcessSignal.allCases {
            popup.addItem(withTitle: signal.name)
            popup.lastItem?.representedObject = signal.rawValue
        }
        popup.selectItem(at: ProcessSignal.allCases.firstIndex(of: preselect) ?? 0)
        alert.accessoryView = popup
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn,
                let raw = popup.selectedItem?.representedObject as? Int32,
                let signal = ProcessSignal(rawValue: raw)
            else { return }
            MainActor.assumeIsolated {
                if ProcessSignals.isSensitive(entry.pid) {
                    confirmSensitive(entry, signal: signal, on: window)
                } else {
                    send(signal, to: entry, on: window)
                }
            }
        }
    }

    /// kernel_task, launchd and Vigil itself need a second, explicit confirmation.
    private static func confirmSensitive(_ entry: ProcessEntry, signal: ProcessSignal, on window: NSWindow) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "“\(entry.name)” is essential"
        alert.informativeText =
            entry.pid == getpid()
            ? "This is Vigil itself." : "Signaling PID \(entry.pid) can make your Mac unresponsive or restart it."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Send \(signal.name)").hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertSecondButtonReturn else { return }
            MainActor.assumeIsolated { send(signal, to: entry, on: window) }
        }
    }

    private static func send(_ signal: ProcessSignal, to entry: ProcessEntry, on window: NSWindow) {
        let message: String? =
            switch ProcessSignals.send(signal, to: entry.id) {
            case .sent: nil
            case .processGone: "“\(entry.name)” has already exited."
            case .permissionDenied:
                "“\(entry.name)” belongs to \(entry.user). Without administrator access you can only signal your own processes."
            case .failed(let code): "The signal couldn’t be sent (error \(code))."
            }
        guard let message else { return }
        let alert = NSAlert()
        alert.messageText = "Signal not sent"
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }
}
