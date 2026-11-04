// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import Foundation
import Testing

@testable import VigilCore

@Suite struct LenientDecodingTests {
    func decode(_ json: String) throws -> LayoutProfile {
        try JSONDecoder().decode(LayoutProfile.self, from: Data(json.utf8))
    }

    @Test func missingOptionalFieldsTakeDefaults() throws {
        let profile = try decode(
            #"{"name":"Old","panels":[{"id":"a","kind":"cpu","placement":{"size":{"width":320,"height":180}}}]}"#)
        let panel = try #require(profile.panels.first)
        #expect(panel.sizeClass == .medium)
        #expect(panel.level == .desktop)
        #expect(panel.appearance.isEmpty)
        #expect(panel.isVisible)
        #expect(!panel.clickThrough)
        #expect(panel.placement.display == .main)
        #expect(panel.placement.desktop == .all)
    }

    @Test func unknownPanelKindsAreSkippedNotFatal() throws {
        let profile = try decode(
            #"""
            {"name":"Future","panels":[
              {"id":"a","kind":"cpu","placement":{"size":{"width":320,"height":180}}},
              {"id":"b","kind":"quantumFlux","placement":{"size":{"width":320,"height":180}}},
              {"id":"c","kind":"memory","material":"holographic","placement":{"size":{"width":154,"height":110}}}
            ]}
            """#)
        #expect(profile.panels.map(\.id) == ["a", "c"])
        #expect(profile.panels[1].appearance.isEmpty)  // unknown material → inherit the default
    }

    @Test func duplicateIdsKeepTheFirst() throws {
        let profile = try decode(
            #"""
            {"name":"Dup","panels":[
              {"id":"a","kind":"cpu","placement":{"size":{"width":320,"height":180}}},
              {"id":"a","kind":"disk","placement":{"size":{"width":154,"height":110}}}
            ]}
            """#)
        #expect(profile.panels.map(\.kind) == [.cpu])
    }
}

@Suite struct LayoutFileStoreTests {
    func temporaryStore(legacy: Bool = false) -> LayoutFileStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vigil-tests-\(UUID().uuidString)", isDirectory: true)
        return LayoutFileStore(
            url: directory.appendingPathComponent("Layouts/Library.json"),
            legacyURL: legacy ? directory.appendingPathComponent("Layouts/Current.json") : nil)
    }

    func library(named name: String) -> LayoutLibrary {
        var profile = LayoutProfile.standard
        profile.name = name
        return LayoutLibrary(profiles: [profile])
    }

    @Test func firstLaunchHasNothingToLoad() {
        #expect(temporaryStore().load() == nil)
    }

    @Test func saveThenLoadRoundTrips() throws {
        let store = temporaryStore()
        var library = LayoutLibrary(profiles: [.standard, LayoutPreset.btop.profile])
        library.activate(library.profiles[1].id)
        try store.save(library)
        let loaded = try #require(store.load())
        #expect(loaded.library == library)
        #expect(loaded.source == .file)
    }

    @Test func damagedFileFallsBackToTheBackup() throws {
        let store = temporaryStore()
        try store.save(library(named: "First"))
        try store.save(library(named: "Second"))  // First becomes the backup
        try Data("{ not json".utf8).write(to: store.url)
        let loaded = try #require(store.load())
        #expect(loaded.source == .backup)
        #expect(loaded.library.active.name == "First")
    }

    @Test func aDamagedFileNeverReplacesAGoodBackup() throws {
        let store = temporaryStore()
        try store.save(library(named: "Good"))
        try store.save(library(named: "Good"))  // backup = Good
        try Data("garbage".utf8).write(to: store.url)
        try store.save(library(named: "Next"))  // must not copy "garbage" over the backup
        try Data("garbage again".utf8).write(to: store.url)
        #expect(store.load()?.library.active.name == "Good")
    }

    @Test func version1SingleLayoutFileMigrates() throws {
        let store = temporaryStore(legacy: true)
        let legacyURL = try #require(store.legacyURL)
        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let v1 =
            #"{"version":1,"profile":{"name":"Mine","panels":[{"id":"a","kind":"cpu","placement":{"size":{"width":320,"height":180}}}]}}"#
        try Data(v1.utf8).write(to: legacyURL)
        let loaded = try #require(store.load())
        #expect(loaded.source == .legacy)
        #expect(loaded.library.profiles.map(\.name) == ["Mine"])
        #expect(loaded.library.active.panels.map(\.id) == ["a"])
    }

    @Test func olderVersionAtTheCurrentPathIsFlaggedForUpgrade() throws {
        let store = temporaryStore()
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let v1 = #"{"version":1,"profile":{"name":"Old","panels":[]}}"#
        try Data(v1.utf8).write(to: store.url)
        let loaded = try #require(store.load())
        #expect(loaded.source == .legacy)
        #expect(loaded.library.active.name == "Old")
    }

    @Test func fileIsVersioned() throws {
        let store = temporaryStore()
        try store.save(library(named: "V"))
        let document = try JSONDecoder().decode(LayoutDocument.self, from: Data(contentsOf: store.url))
        #expect(document.version == LayoutDocument.currentVersion)
    }

    @Test func exportedLayoutImportsAsOneProfile() throws {
        let data = try LayoutFileStore.export(LayoutPreset.developer.profile)
        let imported = try #require(LayoutFileStore.importProfile(from: data))
        #expect(imported.name == "Developer")
        #expect(imported.panels.count == 4)
        #expect(LayoutFileStore.importProfile(from: Data("nope".utf8)) == nil)
    }
}

@Suite struct SnapperTests {
    let area = Rect(x: 0, y: 0, width: 1440, height: 875)
    let settings = SnapSettings()

    @Test func snapsToTheScreenMargin() {
        let (frame, guides) = Snapper.snap(
            Rect(x: 1440 - 16 - 320 + 5, y: 400, width: 320, height: 180), others: [], area: area, settings: settings)
        #expect(frame.maxX == 1440 - 16)
        #expect(guides.contains(SnapGuide(axis: .vertical(x: 1424), from: 0, to: 875)))
    }

    @Test func alignsWithAnotherPanelsEdge() {
        let other = Rect(x: 600, y: 600, width: 320, height: 180)
        let (frame, guides) = Snapper.snap(
            Rect(x: 603, y: 300, width: 154, height: 110), others: [other], area: area, settings: settings)
        #expect(frame.minX == 600)
        #expect(guides.first?.axis == .vertical(x: 600))
    }

    @Test func sitsBesideANeighborWithTheStandardGap() {
        let other = Rect(x: 600, y: 600, width: 320, height: 180)
        let (frame, _) = Snapper.snap(
            Rect(x: 600 + 320 + 15, y: 600, width: 154, height: 110), others: [other], area: area, settings: settings)
        #expect(frame.minX == 600 + 320 + 12)
    }

    @Test func fallsBackToTheGridWhenNothingIsClose() {
        let (frame, guides) = Snapper.snap(
            Rect(x: 403, y: 301, width: 154, height: 110), others: [], area: area, settings: settings)
        #expect(frame.minX == 400)
        #expect(frame.minY == 304)
        #expect(guides.isEmpty)
    }

    @Test func gridOffIsFreeMovement() {
        var free = settings
        free.grid = 0
        let (frame, _) = Snapper.snap(
            Rect(x: 403, y: 301, width: 154, height: 110), others: [], area: area, settings: free)
        #expect(frame.minX == 403 && frame.minY == 301)
    }
}

@Suite struct OverlapTests {
    let area = Rect(x: 0, y: 0, width: 1440, height: 875)

    @Test func nonOverlappingFrameIsUnchanged() {
        let frame = Rect(x: 0, y: 0, width: 100, height: 100)
        #expect(
            Snapper.resolveOverlap(frame, others: [Rect(x: 200, y: 0, width: 100, height: 100)], area: area, gap: 12)
                == frame)
    }

    @Test func overlappingFrameMovesToTheNearestFreeSpot() {
        let other = Rect(x: 500, y: 500, width: 320, height: 180)
        let dropped = Rect(x: 790, y: 520, width: 154, height: 110)
        let resolved = Snapper.resolveOverlap(dropped, others: [other], area: area, gap: 12)
        #expect(!resolved.intersects(other))
        #expect(resolved.minX == other.maxX + 12)  // nudged right, the smallest move
        #expect(resolved.minY == dropped.minY)
    }

    @Test func resolvedSpotStaysOnScreen() {
        let other = Rect(x: 1440 - 320, y: 0, width: 320, height: 180)
        let resolved = Snapper.resolveOverlap(
            Rect(x: 1440 - 154, y: 10, width: 154, height: 110), others: [other], area: area, gap: 12)
        #expect(resolved.maxX <= 1440 && resolved.minY >= 0)
        #expect(!resolved.intersects(other))
    }

    @Test func touchingEdgesDoNotCountAsOverlap() {
        #expect(!Rect(x: 0, y: 0, width: 10, height: 10).intersects(Rect(x: 10, y: 0, width: 10, height: 10)))
    }
}

@Suite struct SizeClassTests {
    @Test func layoutFollowsTheSize() {
        #expect(SizeClass.layout(for: Size(width: 154, height: 110)) == .small)
        #expect(SizeClass.layout(for: Size(width: 320, height: 180)) == .medium)
        #expect(SizeClass.layout(for: Size(width: 400, height: 120)) == .small)  // too short for Medium
        #expect(SizeClass.layout(for: Size(width: 140, height: 64)) == .extraSmall)
        #expect(SizeClass.layout(for: Size(width: 320, height: 80)) == .extraSmall)  // a wide strip
    }

    @Test func nearestClassForAResize() {
        #expect(SizeClass.nearest(to: Size(width: 200, height: 120)) == .small)
        #expect(SizeClass.nearest(to: Size(width: 300, height: 170)) == .medium)
        #expect(SizeClass.nearest(to: Size(width: 150, height: 70)) == .extraSmall)
    }
}
