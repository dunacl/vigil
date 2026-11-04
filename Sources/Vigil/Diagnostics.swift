// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import Foundation
import MetricKit
import os

/// Crash and hang diagnostics from MetricKit, saved locally to
/// `~/Library/Logs/Vigil/` so a user can attach them to a bug report (SPEC §7).
/// Nothing is ever sent anywhere: no third-party SDK, no telemetry.
final class Diagnostics: NSObject, MXMetricManagerSubscriber, Sendable {
    static let shared = Diagnostics()
    private static let log = Logger(subsystem: "app.vigil", category: "diagnostics")
    private static let keep = 10

    static var folder: URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/Vigil", isDirectory: true)
    }

    func start() {
        MXMetricManager.shared.add(self)
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard let folder = Self.folder else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for payload in payloads {
                let stamp = ISO8601DateFormatter().string(from: payload.timeStampEnd).replacingOccurrences(
                    of: ":", with: "-")
                try payload.jsonRepresentation().write(
                    to: folder.appendingPathComponent("diagnostic-\(stamp).json"), options: .atomic)
            }
            Self.prune(folder)
        } catch {
            Self.log.error("Could not save diagnostics: \(error.localizedDescription)")
        }
    }

    /// Keeps only the most recent few files (bounded disk use).
    private static func prune(_ folder: URL) {
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.lastPathComponent.hasPrefix("diagnostic-") } ?? []
        let sorted = files.sorted {
            let a =
                (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b =
                (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for file in sorted.dropFirst(keep) { try? FileManager.default.removeItem(at: file) }
    }
}
