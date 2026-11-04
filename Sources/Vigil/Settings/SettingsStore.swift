// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import Foundation
import Observation
import VigilCore
import os

/// Global settings, persisted to `UserDefaults` as one JSON value (SPEC §9).
/// Every change is saved and pushed to the desktop immediately.
@MainActor @Observable
final class SettingsStore {
    var settings: VigilSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
            onChange?(settings)
        }
    }

    @ObservationIgnored var onChange: ((VigilSettings) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "VigilSettings"
    private static let log = Logger(subsystem: "app.vigil", category: "settings")

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
            let decoded = try? JSONDecoder().decode(VigilSettings.self, from: data)
        {
            settings = decoded
        } else {
            settings = VigilSettings()
        }
    }

    private func save() {
        do {
            defaults.set(try JSONEncoder().encode(settings), forKey: Self.key)
        } catch {
            Self.log.error("Could not save settings: \(error.localizedDescription)")
        }
    }
}
