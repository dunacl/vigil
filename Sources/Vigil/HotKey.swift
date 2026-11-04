// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import Carbon.HIToolbox

/// A system-wide hotkey via Carbon's `RegisterEventHotKey`, which (unlike
/// `NSEvent` global monitors) needs no Accessibility permission (SPEC §10).
@MainActor
final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    /// - Parameters:
    ///   - keyCode: a `kVK_*` virtual key code.
    ///   - modifiers: Carbon modifier mask (`controlKey | optionKey`, …).
    private let id: UInt32
    private static var nextID: UInt32 = 1

    init?(keyCode: Int, modifiers: Int, action: @escaping @MainActor () -> Void) {
        self.action = action
        id = Self.nextID
        Self.nextID += 1
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, context in
                // Every installed handler sees every hotkey: act only on our own.
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var pressed = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
                guard status == noErr, pressed.id == hotKey.id else { return OSStatus(eventNotHandledErr) }
                MainActor.assumeIsolated { hotKey.action() }
                return noErr
            }, 1, &type, context, &handler)
        guard installed == noErr else { return nil }
        let hotKeyID = EventHotKeyID(signature: OSType(0x5647_494C), id: id)  // 'VGIL'
        let registered = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), hotKeyID, GetEventDispatcherTarget(), 0, &reference)
        guard registered == noErr else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
    }

    isolated deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}
