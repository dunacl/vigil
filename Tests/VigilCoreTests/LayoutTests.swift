// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import Foundation
import Testing

@testable import VigilCore

@Suite struct PlacementResolverTests {
    // A 1440×900 laptop with a 25 pt menu bar and a 70 pt Dock at the bottom.
    let laptop = ScreenInfo(
        uuid: "LAPTOP", name: "Built-in", isMain: true,
        frame: Rect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: Rect(x: 0, y: 70, width: 1440, height: 805))
    // An external display to the right.
    let external = ScreenInfo(
        uuid: "EXTERNAL", name: "Studio Display", isMain: false,
        frame: Rect(x: 1440, y: 0, width: 2560, height: 1440),
        visibleFrame: Rect(x: 1440, y: 0, width: 2560, height: 1415))

    func placement(_ anchor: Anchor, x: Double, y: Double, display: DisplayRef = .main) -> Placement {
        Placement(display: display, anchor: anchor, offset: Point(x: x, y: y), size: Size(width: 320, height: 180))
    }

    @Test func topTrailingMeasuresInwardFromTheCorner() throws {
        let resolved = try #require(PlacementResolver.resolve(placement(.topTrailing, x: 16, y: 16), screens: [laptop]))
        #expect(resolved.frame == Rect(x: 1440 - 16 - 320, y: 875 - 16 - 180, width: 320, height: 180))
        #expect(!resolved.isOnFallbackDisplay)
    }

    @Test func bottomLeadingStaysAboveTheDock() throws {
        let resolved = try #require(PlacementResolver.resolve(placement(.bottomLeading, x: 0, y: 0), screens: [laptop]))
        #expect(resolved.frame.minY == 70)
        #expect(resolved.frame.minX == 0)
    }

    @Test func centerOffsetsArePositiveRightAndDown() throws {
        let resolved = try #require(PlacementResolver.resolve(placement(.center, x: 10, y: 20), screens: [laptop]))
        #expect(resolved.frame.midX == 720 + 10)
        let expectedMidY: Double = 70 + 805.0 / 2 - 20
        #expect(resolved.frame.midY == expectedMidY)
    }

    @Test func allNineAnchorsLandInsideTheVisibleFrame() throws {
        for anchor in Anchor.allCases {
            let frame = try #require(PlacementResolver.resolve(placement(anchor, x: 8, y: 8), screens: [laptop])).frame
            let area = laptop.visibleFrame
            #expect(frame.minX >= area.minX && frame.maxX <= area.maxX, "\(anchor)")
            #expect(frame.minY >= area.minY && frame.maxY <= area.maxY, "\(anchor)")
        }
    }

    @Test func specificDisplayIsUsedWhenConnected() throws {
        let resolved = try #require(
            PlacementResolver.resolve(
                placement(.topLeading, x: 0, y: 0, display: .uuid("EXTERNAL")), screens: [laptop, external]))
        #expect(resolved.screen.uuid == "EXTERNAL")
        #expect(resolved.frame.minX == 1440)
        #expect(resolved.frame.maxY == 1415)
    }

    @Test func disconnectedDisplayFallsBackToMainWithoutChangingThePlacement() throws {
        let saved = placement(.topTrailing, x: 16, y: 16, display: .uuid("EXTERNAL"))
        let resolved = try #require(PlacementResolver.resolve(saved, screens: [laptop]))
        #expect(resolved.screen.uuid == "LAPTOP")
        #expect(resolved.isOnFallbackDisplay)
        #expect(resolved.frame.maxX == 1440 - 16)  // same corner, same offset
        #expect(saved.display == .uuid("EXTERNAL"))
    }

    @Test func offscreenOffsetsAreClampedIntoView() throws {
        let resolved = try #require(
            PlacementResolver.resolve(placement(.topLeading, x: 5_000, y: -300), screens: [laptop]))
        #expect(resolved.frame.maxX == 1440)
        #expect(resolved.frame.maxY == 875)
    }

    @Test func panelLargerThanTheScreenIsShrunkToFit() {
        let tiny = Rect(x: 0, y: 0, width: 200, height: 100)
        let clamped = PlacementResolver.clamp(Rect(x: -50, y: -50, width: 400, height: 300), to: tiny)
        #expect(clamped == tiny)
    }

    @Test func resolutionChangeKeepsCornerAnchoredPanelsInTheirCorner() throws {
        let saved = placement(.bottomTrailing, x: 16, y: 16)
        var smaller = laptop
        smaller.visibleFrame = Rect(x: 0, y: 70, width: 1280, height: 705)
        let resolved = try #require(PlacementResolver.resolve(saved, screens: [smaller]))
        #expect(resolved.frame.maxX == 1280 - 16)
        #expect(resolved.frame.minY == 70 + 16)
    }

    @Test func noScreensMeansNoPlacement() {
        #expect(PlacementResolver.resolve(placement(.center, x: 0, y: 0), screens: []) == nil)
    }

    @Test(arguments: Anchor.allCases)
    func placementForFrameRoundTrips(anchor: Anchor) throws {
        let original = placement(anchor, x: 24, y: 40)
        let frame = try #require(PlacementResolver.resolve(original, screens: [laptop])).frame
        let derived = PlacementResolver.placement(for: frame, on: laptop, display: .main, desktop: .all)
        #expect(derived.anchor == anchor)
        let again = try #require(PlacementResolver.resolve(derived, screens: [laptop])).frame
        #expect(again == frame)
    }

    @Test func droppedPanelAnchorsToTheNearestRegion() {
        // Dropped in the bottom-right third of the screen.
        let frame = Rect(x: 1100, y: 100, width: 300, height: 150)
        let derived = PlacementResolver.placement(for: frame, on: laptop, display: .uuid("LAPTOP"), desktop: .index(2))
        #expect(derived.anchor == .bottomTrailing)
        #expect(derived.offset == Point(x: 40, y: 30))
        #expect(derived.desktop == .index(2))
    }
}

@Suite struct LayoutProfileTests {
    @Test func demandIsTheUnionOfPanelKinds() {
        let panels = LayoutProfile.standard.panels
        #expect(LayoutProfile.demand(of: panels) == .all)
        #expect(LayoutProfile.demand(of: panels.filter { $0.kind == .disk }) == [.diskIO, .volumes])
        #expect(LayoutProfile.demand(of: []) == [])
    }

    @Test func standardLayoutDoesNotOverlap() throws {
        let screen = ScreenInfo(
            uuid: "S", name: "S", isMain: true, frame: Rect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: Rect(x: 0, y: 0, width: 1440, height: 875))
        let frames = try LayoutProfile.standard.panels.map {
            try #require(PlacementResolver.resolve($0.placement, screens: [screen])).frame
        }
        for (i, a) in frames.enumerated() {
            for b in frames[(i + 1)...] {
                let overlaps = a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
                #expect(!overlaps, "\(a) overlaps \(b)")
            }
        }
    }

    @Test func standardLayoutFitsASmallLaptopScreen() throws {
        // 13" MacBook Air at default scaling: 1280×832, minus menu bar and Dock.
        let screen = ScreenInfo(
            uuid: "S", name: "S", isMain: true, frame: Rect(x: 0, y: 0, width: 1280, height: 832),
            visibleFrame: Rect(x: 0, y: 70, width: 1280, height: 730))
        for panel in LayoutProfile.standard.panels {
            let unclamped = PlacementResolver.frame(for: panel.placement, in: screen.visibleFrame)
            #expect(unclamped.minY >= screen.visibleFrame.minY, "\(panel.id) would be clamped")
        }
    }

    @Test func profilesRoundTripThroughJSON() throws {
        var profile = LayoutProfile.standard
        profile.panels[0].placement.desktop = .index(3)
        profile.panels[1].placement.display = .uuid("ABC")
        let data = try JSONEncoder().encode(profile)
        #expect(try JSONDecoder().decode(LayoutProfile.self, from: data) == profile)
    }
}

@Suite struct NiceCeilingTests {
    @Test func roundsUpToOneTwoFiveSteps() {
        #expect(Units.niceCeiling(3_000) == 5 * 1024)
        #expect(Units.niceCeiling(1_500, floor: 1) == 2 * 1024)
        #expect(Units.niceCeiling(700 * 1024) == 1024 * 1024)
        #expect(Units.niceCeiling(3 * 1_048_576) == 5 * 1_048_576)
    }

    @Test func respectsTheFloor() {
        #expect(Units.niceCeiling(0, floor: 10_240) == 10 * 1024)
        #expect(Units.niceCeiling(.nan, floor: 4) == 4)
    }
}
