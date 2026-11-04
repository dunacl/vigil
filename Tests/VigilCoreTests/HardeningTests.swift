// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import Foundation
import Testing

@testable import VigilCore

/// Inputs Vigil doesn't control — files, settings, undocumented sensors, typed
/// filters — must be bounded and must never crash the app.
@Suite struct HardeningTests {
    private func layoutJSON(panels: Int, width: Double = 300, offset: Double = 16, name: String = "Shared") -> Data {
        let panel = { (index: Int) in
            """
            {"id":"p\(index)","kind":"cpu","sizeClass":"small","placement":{"display":{"main":{}},
             "anchor":"topLeading","offset":{"x":\(offset),"y":\(offset)},"size":{"width":\(width),"height":200}}}
            """
        }
        let body = (0..<panels).map(panel).joined(separator: ",")
        return Data(#"{"version":2,"layout":{"id":"x","name":"\#(name)","panels":[\#(body)]}}"#.utf8)
    }

    @Test func importRejectsOversizedFiles() {
        var data = layoutJSON(panels: 1)
        data.append(Data(repeating: 0x20, count: LayoutFileStore.maximumFileSize))
        #expect(LayoutFileStore.importProfile(from: data) == nil)
    }

    @Test func importRoundTripsAnExport() throws {
        let data = try LayoutFileStore.export(.standard)
        let imported = try #require(LayoutFileStore.importProfile(from: data))
        #expect(imported.panels.count == LayoutProfile.standard.panels.count)
    }

    @Test func decodedLayoutsAreCappedAndClamped() throws {
        let original = LayoutProfile.standard
        var huge = original
        let template = try #require(original.panels.first)
        huge.panels = (0..<500).map { index in
            var panel = template
            panel.id = "p\(index)"
            panel.placement.size = Size(width: 1e300, height: -5)
            panel.placement.offset = Point(x: -1e300, y: 1e300)
            return panel
        }
        huge.name = String(repeating: "n", count: 5_000)
        let decoded = try JSONDecoder().decode(LayoutProfile.self, from: JSONEncoder().encode(huge))
        #expect(decoded.panels.count == LayoutProfile.maximumPanels)
        #expect(decoded.name.count == 100)
        for panel in decoded.panels {
            #expect(panel.placement.size.width <= 10_000)
            #expect(panel.placement.size.height >= 40)
            #expect(abs(panel.placement.offset.x) <= 20_000)
            #expect(abs(panel.placement.offset.y) <= 20_000)
        }
    }

    @Test func thresholdsAreClampedOnDecode() throws {
        let json = #"{"cpuWarning":7,"cpuCritical":-3,"sustainSeconds":1e300,"diskWarning":0.5}"#
        let thresholds = try JSONDecoder().decode(ThresholdSettings.self, from: Data(json.utf8))
        #expect(thresholds.cpuWarning == 1)
        #expect(thresholds.cpuCritical == 0)
        #expect(thresholds.sustainSeconds == 600)
        #expect(thresholds.diskWarning == 0.5)
    }

    @Test func sustainSamplesIsBoundedForAnyInput() {
        var thresholds = ThresholdSettings()
        thresholds.sustainSeconds = 10
        #expect(thresholds.sustainSamples(interval: 2) == 5)
        for seconds in [Double.infinity, -.infinity, .nan, 1e300, -1, 0] {
            thresholds.sustainSeconds = seconds
            for interval in [0, 0.001, 2, .nan, .infinity] {
                #expect((1...300).contains(thresholds.sustainSamples(interval: interval)))
            }
        }
    }

    @Test func numberFormattingNeverTraps() {
        for value in [Double.infinity, .nan, 1e300, -1e300, Double(Int.max)] {
            #expect(Units.number(value, decimals: 1) == "—")
        }
        #expect(Units.number(12.34, decimals: 1) == "12.3")
    }

    @Test func implausibleSensorReadingsAreDropped() {
        #expect(SensorRange.watts(25) == 25)
        #expect(SensorRange.watts(-1) == nil)
        #expect(SensorRange.watts(.nan) == nil)
        #expect(SensorRange.watts(1e9) == nil)
        #expect(SensorRange.rpm(2_400) == 2_400)
        #expect(SensorRange.rpm(.infinity) == nil)
        #expect(SensorRange.rpm(nil) == nil)
    }

    @Test func overlongRegexFallsBackToPlainText() {
        let processes = [process(1, name: "aaaa")]
        var query = ProcessQuery()
        query.filter = "/a+/"
        #expect(ProcessListBuilder.rows(processes, query: query).count == 1)
        query.filter = "/" + String(repeating: "(a+)+", count: 60) + "/"  // 302 characters
        #expect(ProcessListBuilder.rows(processes, query: query).isEmpty)  // literal text, no match
    }
}
