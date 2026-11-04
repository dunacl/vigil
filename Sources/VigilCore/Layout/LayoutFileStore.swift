// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import Foundation

/// The on-disk layout file. Version 1 (M2–M4) held one `profile`; version 2
/// holds the whole `library`. Both decode; version 2 is written.
public struct LayoutDocument: Codable, Sendable, Equatable {
    public static let currentVersion = 2

    public var version: Int
    public var library: LayoutLibrary?
    /// A single profile: version-1 files, and exported `.vigillayout` files.
    public var profile: LayoutProfile?

    public init(library: LayoutLibrary) {
        version = Self.currentVersion
        self.library = library
    }

    public init(profile: LayoutProfile) {
        version = Self.currentVersion
        self.profile = profile
    }

    /// The library this document describes (a single profile becomes a library of one).
    public var resolvedLibrary: LayoutLibrary? {
        library ?? profile.map { LayoutLibrary(profiles: [$0]) }
    }
}

extension LayoutLibrary {
    enum CodingKeys: String, CodingKey { case profiles, activeID }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let profiles = try container.decode([LossyProfile].self, forKey: .profiles).compactMap(\.value).prefix(100)
        self.init(profiles: Array(profiles), activeID: container.lenient(.activeID))
    }

    private struct LossyProfile: Decodable {
        let value: LayoutProfile?
        init(from decoder: any Decoder) throws { value = try? LayoutProfile(from: decoder) }
    }
}

/// Reads and writes the layout library with crash-safe semantics (SPEC §7, §9):
/// atomic writes, a copy of the last good file kept as `.bak`, and a fallback
/// chain on load (file → backup → nothing, so the caller uses its default).
public struct LayoutFileStore: Sendable {
    public enum Source: Sendable, Equatable {
        case file
        case backup
        /// Migrated from an older format (the pre-M5 single-layout file, or an
        /// older version at this path); the caller should save to upgrade it.
        case legacy
    }

    public let url: URL
    /// The pre-M5 single-layout file, read once for migration.
    public let legacyURL: URL?
    public var backupURL: URL { url.appendingPathExtension("bak") }

    public init(url: URL, legacyURL: URL? = nil) {
        self.url = url
        self.legacyURL = legacyURL
    }

    /// `~/Library/Application Support/Vigil/Layouts/Library.json`
    public static func standard() -> LayoutFileStore? {
        guard
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let folder = support.appendingPathComponent("Vigil/Layouts", isDirectory: true)
        return LayoutFileStore(
            url: folder.appendingPathComponent("Library.json"), legacyURL: folder.appendingPathComponent("Current.json")
        )
    }

    /// The saved library and where it came from, or `nil` on first launch (or if
    /// every candidate is unreadable).
    public func load() -> (library: LayoutLibrary, source: Source)? {
        if let (library, version) = Self.decode(url) {
            return (library, version < LayoutDocument.currentVersion ? .legacy : .file)
        }
        if let (library, _) = Self.decode(backupURL) { return (library, .backup) }
        if let legacyURL, let (library, _) = Self.decode(legacyURL) { return (library, .legacy) }
        return nil
    }

    /// Writes atomically. The previous file is kept as the backup only if it
    /// was readable, so a damaged file never replaces a good backup.
    public func save(_ library: LayoutLibrary) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if Self.decode(url) != nil {
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.copyItem(at: url, to: backupURL)
        }
        try Self.encode(LayoutDocument(library: library)).write(to: url, options: .atomic)
    }

    /// A single layout for sharing (`.vigillayout`).
    public static func export(_ profile: LayoutProfile) throws -> Data {
        try encode(LayoutDocument(profile: profile))
    }

    /// Layout files are small (a few KB); anything bigger isn't one of ours.
    public static let maximumFileSize = 1_000_000

    /// The layout in a shared file (or the active one of a whole library file).
    public static func importProfile(from data: Data) -> LayoutProfile? {
        guard data.count <= maximumFileSize, let document = try? JSONDecoder().decode(LayoutDocument.self, from: data)
        else { return nil }
        return document.profile ?? document.library?.active
    }

    private static func encode(_ document: LayoutDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    private static func decode(_ url: URL) -> (LayoutLibrary, version: Int)? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maximumFileSize, let data = try? Data(contentsOf: url),
            let document = try? JSONDecoder().decode(LayoutDocument.self, from: data),
            let library = document.resolvedLibrary
        else { return nil }
        return (library, document.version)
    }
}
