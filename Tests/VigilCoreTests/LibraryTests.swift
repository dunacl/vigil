// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import Foundation
import Testing

@testable import VigilCore

@Suite struct LayoutLibraryTests {
    @Test func neverEmptyAndActiveIsValid() {
        let empty = LayoutLibrary(profiles: [])
        #expect(empty.profiles.count == 1)
        let bogus = LayoutLibrary(profiles: [.standard], activeID: "missing")
        #expect(bogus.activeID == LayoutProfile.standard.id)
    }

    @Test func addingRenamesOnNameClash() {
        var library = LayoutLibrary(profiles: [.standard])
        let id = library.add(LayoutPreset.standard.profile)
        #expect(library[id]?.name == "Standard 2")
        #expect(library.profiles.map(\.id).count == Set(library.profiles.map(\.id)).count)
    }

    @Test func duplicateIsUnboundAndNamedCopy() throws {
        var library = LayoutLibrary(profiles: [.standard])
        library.bind(LayoutProfile.standard.id, to: ["A"])
        let duplicated = library.duplicate(LayoutProfile.standard.id)
        let copy = try #require(duplicated)
        #expect(library[copy]?.name == "Standard Copy")
        #expect(library[copy]?.displays == nil)
    }

    @Test func renameTrimsAndKeepsNamesUnique() {
        var library = LayoutLibrary(profiles: [.standard, LayoutPreset.btop.profile])
        let btop = library.profiles[1].id
        library.rename(btop, to: "  Standard ")
        #expect(library[btop]?.name == "Standard 2")
        library.rename(btop, to: "   ")
        #expect(library[btop]?.name == "Standard 2")  // empty names are ignored
    }

    @Test func removingTheActiveLayoutActivatesAnother() {
        var library = LayoutLibrary(profiles: [.standard, LayoutPreset.btop.profile])
        library.activate(library.profiles[1].id)
        library.remove(library.activeID)
        #expect(library.profiles.count == 1)
        #expect(library.activeID == LayoutProfile.standard.id)
        library.remove(library.activeID)  // the last one stays
        #expect(library.profiles.count == 1)
    }

    @Test func bindingIsExclusivePerDisplaySet() {
        var library = LayoutLibrary(profiles: [.standard, LayoutPreset.btop.profile])
        let (first, second) = (library.profiles[0].id, library.profiles[1].id)
        library.bind(first, to: ["LAPTOP", "STUDIO"])
        library.bind(second, to: ["STUDIO", "LAPTOP"])  // same set, other order
        #expect(library[first]?.displays == nil)
        #expect(library.profile(forDisplays: ["LAPTOP", "STUDIO"])?.id == second)
        #expect(library.profile(forDisplays: ["LAPTOP"]) == nil)  // exact match only
    }

    @Test func libraryDecodingSkipsBrokenProfiles() throws {
        let json =
            #"{"activeID":"b","profiles":[{"id":"a","name":"A","panels":[]},{"id":"b","name":"B","panels":"oops"}]}"#
        let library = try JSONDecoder().decode(LayoutLibrary.self, from: Data(json.utf8))
        #expect(library.profiles.map(\.id) == ["a"])
        #expect(library.activeID == "a")  // the active one was broken
    }
}

@Suite struct PresetTests {
    // 13" MacBook Air at default scaling: 1280×832, minus menu bar and Dock.
    let screen = ScreenInfo(
        uuid: "S", name: "S", isMain: true, frame: Rect(x: 0, y: 0, width: 1280, height: 832),
        visibleFrame: Rect(x: 0, y: 70, width: 1280, height: 730))

    @Test(arguments: LayoutPreset.allCases)
    func presetFitsASmallLaptopWithoutOverlap(preset: LayoutPreset) {
        let frames = preset.profile.panels.map { PlacementResolver.frame(for: $0.placement, in: screen.visibleFrame) }
        for frame in frames {
            #expect(frame.minY >= screen.visibleFrame.minY && frame.minX >= 0, "\(preset) off screen: \(frame)")
        }
        for (i, a) in frames.enumerated() {
            for b in frames[(i + 1)...] { #expect(!a.intersects(b), "\(preset): \(a) overlaps \(b)") }
        }
    }

    @Test func btopShipsWithSolidPanelsAndBothRankings() {
        let panels = LayoutPreset.btop.profile.panels
        #expect(panels.count == 6)
        #expect(panels.allSatisfy { $0.appearance.material == .solid })  // §13 decision 11
        #expect(Set(panels.filter { $0.kind == .topProcesses }.map(\.options.topSort)) == [.cpu, .memory])
    }

    @Test func minimalIsTwoTiles() {
        #expect(LayoutPreset.minimal.profile.panels.map(\.sizeClass) == [.extraSmall, .extraSmall])
    }
}

@Suite struct GeneralSettingsTests {
    @Test func shortcutsDefaultAndCanBeTurnedOff() throws {
        let missing = try JSONDecoder().decode(ShortcutSettings.self, from: Data("{}".utf8))
        #expect(missing.peek == .peek)
        let off = try JSONDecoder().decode(ShortcutSettings.self, from: Data(#"{"peek":null}"#.utf8))
        #expect(off.peek == nil)
        #expect(off.editLayout == .editLayout)
        var settings = ShortcutSettings()
        settings.dashboard = nil
        let decoded = try JSONDecoder().decode(ShortcutSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)  // "off" survives a round trip
    }

    @Test func oldSettingsWithoutGeneralGetDefaults() throws {
        let settings = try JSONDecoder().decode(
            VigilSettings.self, from: Data(#"{"units":{"networkInBits":true}}"#.utf8))
        #expect(settings.general == GeneralSettings())
        #expect(settings.units.networkInBits)
    }

    @Test func samplingSlowsDownOnlyWhenAllowedAndNeeded() {
        #expect(SamplingPolicy.interval(base: 2, adaptive: true, lowPowerMode: false, thermalState: 0) == 2)
        #expect(SamplingPolicy.interval(base: 2, adaptive: true, lowPowerMode: true, thermalState: 0) == 4)
        #expect(SamplingPolicy.interval(base: 2, adaptive: true, lowPowerMode: false, thermalState: 2) == 4)
        #expect(SamplingPolicy.interval(base: 2, adaptive: true, lowPowerMode: false, thermalState: 1) == 2)
        #expect(SamplingPolicy.interval(base: 2, adaptive: false, lowPowerMode: true, thermalState: 3) == 2)
    }

    @Test func menuBarReadoutDemand() {
        #expect(MenuBarReadout.iconOnly.demand == [])
        #expect(MenuBarReadout.network.demand == .network)
    }
}
