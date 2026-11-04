// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import Foundation
import Testing

@testable import VigilCore

@Suite struct AppearanceResolverTests {
    let none = AccessibilityDisplay()

    @Test func defaultsAreRegularGlassWithNoTint() {
        let resolved = AppearanceResolver.resolve(
            global: AppearanceSettings(), overrides: AppearanceOverrides(), accessibility: none)
        #expect(resolved.background == .glass(clear: false, glassOpacity: 1, backingOpacity: 0))
        #expect(resolved.tint == nil)
        #expect(resolved.refreshTicks == 1)
        #expect(resolved.animates)
    }

    @Test func overridesWinOverGlobalDefaults() {
        var global = AppearanceSettings()
        global.theme = .btop
        global.hover = .fade
        var overrides = AppearanceOverrides()
        overrides.material = .solid
        overrides.theme = .mono
        overrides.refresh = .everyFifthTick
        let resolved = AppearanceResolver.resolve(global: global, overrides: overrides, accessibility: none)
        #expect(resolved.background == .solid)
        #expect(resolved.theme == .mono)
        #expect(resolved.hover == .fade)  // not overridden → inherited
        #expect(resolved.refreshTicks == 5)
    }

    @Test func overrideCanForceNoTintOverAGlobalTint() {
        var global = AppearanceSettings()
        global.tint = .color(.blue)
        var overrides = AppearanceOverrides()
        overrides.tint = TintChoice.none
        #expect(AppearanceResolver.resolve(global: global, overrides: overrides, accessibility: none).tint == nil)
        #expect(
            AppearanceResolver.resolve(global: global, overrides: AppearanceOverrides(), accessibility: none).tint
                == .blue)
    }

    @Test func reduceTransparencyForcesSolidGlass() {
        var global = AppearanceSettings()
        global.transparency = 1
        let resolved = AppearanceResolver.resolve(
            global: global, overrides: AppearanceOverrides(),
            accessibility: AccessibilityDisplay(reduceTransparency: true))
        #expect(resolved.background == .solid)
    }

    @Test func reduceTransparencyLeavesNoBackgroundAlone() {
        var global = AppearanceSettings()
        global.material = .none
        let resolved = AppearanceResolver.resolve(
            global: global, overrides: AppearanceOverrides(),
            accessibility: AccessibilityDisplay(reduceTransparency: true))
        #expect(resolved.background == .none)
    }

    @Test func increaseContrastAddsABorderAndALegibilityBacking() {
        let resolved = AppearanceResolver.resolve(
            global: AppearanceSettings(), overrides: AppearanceOverrides(),
            accessibility: AccessibilityDisplay(increaseContrast: true))
        #expect(resolved.border == .hairline)
        #expect(resolved.background == .glass(clear: false, glassOpacity: 1, backingOpacity: 1))
    }

    @Test func increaseContrastKeepsAnExplicitAccentBorder() {
        var global = AppearanceSettings()
        global.border = .accent
        let resolved = AppearanceResolver.resolve(
            global: global, overrides: AppearanceOverrides(),
            accessibility: AccessibilityDisplay(increaseContrast: true))
        #expect(resolved.border == .accent)
    }

    @Test func reduceMotionStopsAnimations() {
        let resolved = AppearanceResolver.resolve(
            global: AppearanceSettings(), overrides: AppearanceOverrides(),
            accessibility: AccessibilityDisplay(reduceMotion: true))
        #expect(!resolved.animates)
    }

    @Test func outOfRangeValuesAreClamped() {
        var global = AppearanceSettings()
        global.contentOpacity = 0
        global.cornerRadius = 99
        let resolved = AppearanceResolver.resolve(global: global, overrides: AppearanceOverrides(), accessibility: none)
        #expect(resolved.contentOpacity == 0.2)  // never fully invisible
        #expect(resolved.cornerRadius == 32)
    }
}

@Suite struct TransparencyCurveTests {
    @Test func opaqueEndHasAFullBacking() {
        #expect(TransparencyCurve.background(for: 0) == .glass(clear: false, glassOpacity: 1, backingOpacity: 1))
    }

    @Test func middleIsPlainRegularThenClearGlass() {
        #expect(TransparencyCurve.background(for: 0.4) == .glass(clear: false, glassOpacity: 1, backingOpacity: 0))
        #expect(TransparencyCurve.background(for: 0.6) == .glass(clear: true, glassOpacity: 1, backingOpacity: 0))
    }

    @Test func clearEndFadesTheGlassButNeverToZero() {
        guard case .glass(true, let opacity, 0) = TransparencyCurve.background(for: 1) else {
            Issue.record("expected clear glass")
            return
        }
        #expect(abs(opacity - 0.15) < 1e-9)
    }

    @Test func curveIsMonotonic() {
        // As the slider goes up, the panel never gets more opaque.
        func opacity(_ t: Double) -> Double {
            guard case .glass(let clear, let glass, let backing) = TransparencyCurve.background(for: t) else {
                return 1
            }
            return backing + (1 - backing) * glass * (clear ? 0.5 : 0.75)
        }
        var previous = opacity(0)
        for step in 1...100 {
            let current = opacity(Double(step) / 100)
            #expect(current <= previous + 1e-9, "t = \(Double(step) / 100)")
            previous = current
        }
    }
}

@Suite struct ThresholdTests {
    func history(_ values: [Float]) -> RingBuffer<Float> {
        var buffer = RingBuffer<Float>(capacity: 20, filler: 0)
        for value in values { buffer.append(value) }
        return buffer
    }

    @Test func aBriefSpikeDoesNotAlert() {
        let level = ThresholdEvaluator.level(
            history: history([0.2, 0.3, 0.99, 0.4, 0.3]), warning: 0.85, critical: 0.95, samples: 5)
        #expect(level == .normal)
    }

    @Test func sustainedLoadAlerts() {
        #expect(
            ThresholdEvaluator.level(
                history: history([0.1, 0.9, 0.9, 0.88, 0.97, 0.9]), warning: 0.85, critical: 0.95, samples: 5)
                == .warning)
        #expect(
            ThresholdEvaluator.level(
                history: history([0.96, 0.97, 0.99, 0.98, 0.96]), warning: 0.85, critical: 0.95, samples: 5)
                == .critical)
    }

    @Test func notEnoughHistoryIsNormal() {
        #expect(
            ThresholdEvaluator.level(history: history([0.99, 0.99]), warning: 0.85, critical: 0.95, samples: 5)
                == .normal)
    }

    @Test func memoryUsesPressureAndDiskUsesFullness() {
        #expect(ThresholdEvaluator.level(memoryPressure: .warning) == .warning)
        #expect(ThresholdEvaluator.level(memoryPressure: .unknown) == .normal)
        #expect(ThresholdEvaluator.level(fullness: 0.93, warning: 0.9, critical: 0.95) == .warning)
        #expect(ThresholdEvaluator.level(fullness: 0.5, warning: 0.9, critical: 0.95) == .normal)
    }
}

@Suite struct SettingsCodingTests {
    @Test func emptySettingsJSONGivesDefaults() throws {
        let settings = try JSONDecoder().decode(VigilSettings.self, from: Data("{}".utf8))
        #expect(settings == VigilSettings())
    }

    @Test func unknownValuesFallBackPerField() throws {
        let json = #"{"appearance":{"theme":"vaporwave","hover":"fade"},"units":{"networkInBits":true}}"#
        let settings = try JSONDecoder().decode(VigilSettings.self, from: Data(json.utf8))
        #expect(settings.appearance.theme == .system)  // unknown → default
        #expect(settings.appearance.hover == .fade)  // known value kept
        #expect(settings.units.networkInBits)
        #expect(settings.thresholds == ThresholdSettings())
    }

    @Test func settingsRoundTrip() throws {
        var settings = VigilSettings()
        settings.appearance.tint = .color(.purple)
        settings.appearance.material = PanelMaterial.none
        settings.thresholds.cpuWarning = 0.7
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(VigilSettings.self, from: data) == settings)
    }

    @Test func m2MaterialFieldMigratesToOverrides() throws {
        let json = #"""
            {"name":"M2","panels":[
              {"id":"a","kind":"cpu","material":"solid","placement":{"size":{"width":320,"height":180}}},
              {"id":"b","kind":"cpu","material":"clearGlass","placement":{"size":{"width":320,"height":180}}},
              {"id":"c","kind":"cpu","material":"glass","placement":{"size":{"width":320,"height":180}}}
            ]}
            """#
        let panels = try JSONDecoder().decode(LayoutProfile.self, from: Data(json.utf8)).panels
        #expect(panels[0].appearance.material == .solid)
        #expect(panels[1].appearance.material == .glass)
        #expect(panels[1].appearance.transparency == 0.65)
        #expect(panels[2].appearance.isEmpty)  // plain glass is the default: nothing to override
    }

    @Test func emptyOverridesAreNotWritten() throws {
        let data = try JSONEncoder().encode(LayoutProfile.standard)
        #expect(!String(decoding: data, as: UTF8.self).contains("appearance"))
    }
}
