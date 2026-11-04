// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import Dispatch
import Foundation
import IOKit
import SystemConfiguration

/// Hardware and network configuration changes that invalidate cached state.
public enum SystemChange: Sendable {
    /// A block storage device appeared or disappeared.
    case disks
    /// The default route moved to another interface.
    case primaryInterface
}

/// Delivers ``SystemChange`` events from IOKit and configd, so collectors can
/// cache discovery results instead of polling for hot-plug.
///
/// All state is confined to a private serial queue; callbacks from C arrive on
/// that queue, which is why `@unchecked Sendable` is sound here.
final class SystemChangeMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.vigil.core.system-changes", qos: .utility)
    private let handler: @Sendable (SystemChange) -> Void
    private var notificationPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var store: SCDynamicStore?

    init(handler: @escaping @Sendable (SystemChange) -> Void) {
        self.handler = handler
        queue.sync {
            startDiskNotifications()
            startNetworkNotifications()
        }
    }

    deinit {
        // Tear down on the delivery queue so no callback can be running with an
        // unretained `self`. (The owner never releases us from that queue.)
        queue.sync {
            if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
            for iterator in iterators { IOObjectRelease(iterator) }
            if let notificationPort { IONotificationPortDestroy(notificationPort) }
        }
    }

    fileprivate func emit(_ change: SystemChange) { handler(change) }

    // MARK: - IOKit

    private func startDiskNotifications() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, queue)
        notificationPort = port
        let context = Unmanaged.passUnretained(self).toOpaque()
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            // The matching dictionary is consumed by each call.
            let result = IOServiceAddMatchingNotification(
                port, type, IOServiceMatching("IOBlockStorageDriver"),
                { context, iterator in
                    // Draining the iterator re-arms the notification.
                    var changed = false
                    while case let entry = IOIteratorNext(iterator), entry != 0 {
                        IOObjectRelease(entry)
                        changed = true
                    }
                    guard changed, let context else { return }
                    Unmanaged<SystemChangeMonitor>.fromOpaque(context).takeUnretainedValue().emit(.disks)
                }, context, &iterator)
            guard result == KERN_SUCCESS else { continue }
            // Drain the initial matches without emitting: the collector discovers on first use.
            while case let entry = IOIteratorNext(iterator), entry != 0 { IOObjectRelease(entry) }
            iterators.append(iterator)
        }
    }

    // MARK: - configd

    private func startNetworkNotifications() {
        var context = SCDynamicStoreContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
            copyDescription: nil)
        guard
            let store = SCDynamicStoreCreate(
                nil, "Vigil" as CFString,
                { _, _, info in
                    guard let info else { return }
                    Unmanaged<SystemChangeMonitor>.fromOpaque(info).takeUnretainedValue().emit(.primaryInterface)
                }, &context)
        else { return }
        let keys = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] as CFArray
        guard SCDynamicStoreSetNotificationKeys(store, keys, nil),
            SCDynamicStoreSetDispatchQueue(store, queue)
        else { return }
        self.store = store
    }
}
