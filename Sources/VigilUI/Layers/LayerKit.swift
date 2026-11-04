// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.
//
// A tiny Core Animation toolkit for panel content. Panels are drawn with layers
// rather than SwiftUI: the M1 rendering spike measured 0.014% CPU and 0.5 MB per
// panel for layers vs 0.10% and 0.9 MB for SwiftUI (SPEC §2.1).
//
// Conventions: all layers live in a flipped host view (origin top-left), never
// animate implicitly, only re-render when a value actually changed, and keep
// colors as NSColor until `resolveColors(in:)` turns them into CGColors for the
// current light/dark appearance.

import AppKit
import QuartzCore
import VigilCore

/// The colors of one theme (SPEC §3.6 "Theme / graph palette").
public struct PanelPalette: Sendable {
    public var calm, warm, hot: NSColor
    public var receive, send, read, write: NSColor
    public var memoryApp, memoryWired, memoryCompressed, memoryCached: NSColor
    /// Track behind bars: a faint wash of the text color.
    public var track: NSColor

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    public static func make(_ theme: PanelTheme) -> PanelPalette {
        let track = NSColor.labelColor.withAlphaComponent(0.12)
        switch theme {
        case .system:
            let calm = rgb(0.30, 0.80, 0.45), warm = rgb(0.95, 0.80, 0.25), hot = rgb(0.95, 0.35, 0.30)
            let read = rgb(0.40, 0.65, 1.00)
            return PanelPalette(
                calm: calm, warm: warm, hot: hot,
                receive: rgb(0.30, 0.75, 0.95), send: rgb(0.95, 0.45, 0.70), read: read, write: rgb(1.00, 0.62, 0.30),
                memoryApp: warm, memoryWired: hot, memoryCompressed: rgb(0.70, 0.50, 0.95), memoryCached: read,
                track: track)
        case .btop:
            // Bright terminal colors, as in btop's default theme.
            let green = rgb(0.38, 0.86, 0.36), yellow = rgb(0.98, 0.85, 0.20), red = rgb(0.96, 0.26, 0.24)
            let cyan = rgb(0.20, 0.82, 0.90), magenta = rgb(0.86, 0.36, 0.86)
            return PanelPalette(
                calm: green, warm: yellow, hot: red,
                receive: cyan, send: magenta, read: cyan, write: magenta,
                memoryApp: yellow, memoryWired: red, memoryCompressed: magenta, memoryCached: cyan,
                track: track)
        case .mono:
            let label = NSColor.labelColor
            return PanelPalette(
                calm: label.withAlphaComponent(0.45), warm: label.withAlphaComponent(0.7),
                hot: label.withAlphaComponent(0.95),
                receive: label.withAlphaComponent(0.8), send: label.withAlphaComponent(0.45),
                read: label.withAlphaComponent(0.8), write: label.withAlphaComponent(0.45),
                memoryApp: label.withAlphaComponent(0.8), memoryWired: label.withAlphaComponent(0.6),
                memoryCompressed: label.withAlphaComponent(0.4), memoryCached: label.withAlphaComponent(0.2),
                track: track)
        }
    }

    /// Utilization color for a 0...1 value.
    public func utilization(_ fraction: Double) -> NSColor {
        fraction < 0.6 ? calm : fraction < 0.85 ? warm : hot
    }

    /// The color bucket of a value (0 calm, 1 warm, 2 hot); changes are what trigger recoloring.
    static func bucket(_ fraction: Double) -> Int { fraction < 0.6 ? 0 : fraction < 0.85 ? 1 : 2 }
}

/// Tint colors for the background (SPEC §3.6 "Tint color").
extension TintColor {
    public var color: NSColor {
        switch self {
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .graphite: .systemGray
        }
    }
}

extension CALayer {
    /// Disables implicit animations for the properties panels change each tick.
    func disableImplicitAnimations() {
        actions = [
            "bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "contents": NSNull(),
            "backgroundColor": NSNull(), "path": NSNull(), "hidden": NSNull(), "sublayers": NSNull(),
            "foregroundColor": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull(), "colors": NSNull(),
            "opacity": NSNull(), "cornerRadius": NSNull(), "borderColor": NSNull(), "borderWidth": NSNull(),
        ]
    }
}

/// Resolves a (possibly dynamic) color for the given appearance.
@MainActor
func resolved(_ color: NSColor, in appearance: NSAppearance) -> CGColor {
    var result = color.cgColor
    appearance.performAsCurrentDrawingAppearance { result = color.cgColor }
    return result
}

// MARK: - Text

/// A single-line text layer that only re-renders when its text changes.
final class TextLayer: CATextLayer {
    enum Style {
        case title, caption, body, headline
        /// The value in Extra small tiles.
        case headlineSmall

        var font: NSFont {
            switch self {
            case .title: .systemFont(ofSize: 11, weight: .semibold)
            case .caption: .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            case .body: .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            case .headline: .monospacedDigitSystemFont(ofSize: 26, weight: .semibold)
            case .headlineSmall: .monospacedDigitSystemFont(ofSize: 19, weight: .semibold)
            }
        }
    }

    private(set) var textStyle: Style = .caption
    var color: NSColor = .labelColor

    var text: String = "" {
        didSet { if text != oldValue { string = text } }
    }

    init(_ style: Style, color: NSColor = .labelColor, alignment: CATextLayerAlignmentMode = .left) {
        self.textStyle = style
        self.color = color
        super.init()
        let font = style.font
        self.font = font
        fontSize = font.pointSize
        alignmentMode = alignment
        truncationMode = .end
        isWrapped = false
        disableImplicitAnimations()
    }

    override init(layer: Any) {
        if let other = layer as? TextLayer {
            textStyle = other.textStyle
            color = other.color
            text = other.text
        }
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Height that fits one line of this style.
    var lineHeight: CGFloat { ceil(textStyle.font.ascender - textStyle.font.descender + textStyle.font.leading) }

    /// Width of the current text.
    var textWidth: CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: textStyle.font]).width)
    }

    @MainActor func resolveColors(in appearance: NSAppearance) {
        foregroundColor = resolved(color, in: appearance)
    }
}

// MARK: - Graph

/// A live graph of one or more ring-buffer series, newest at the right. One
/// shape layer per series (plus a line); paths rebuilt per tick.
final class GraphLayer: CALayer {
    enum Fill {
        /// Utilization (0...1): graded calm → warm → hot by height.
        case utilization
        /// A rate in one color.
        case rate(NSColor)
    }

    private var fills: [Fill] = []
    private var graphStyle: GraphStyle = .area
    private var palette = PanelPalette.make(.system)
    private var areas: [CAShapeLayer] = []
    private var lines: [CAShapeLayer] = []
    private var gradients: [CAGradientLayer] = []

    init(_ fills: [Fill], style: GraphStyle, palette: PanelPalette) {
        self.fills = fills
        self.graphStyle = style
        self.palette = palette
        super.init()
        disableImplicitAnimations()
        for fill in fills {
            let area = CAShapeLayer()
            area.disableImplicitAnimations()
            let line = CAShapeLayer()
            line.disableImplicitAnimations()
            line.fillColor = nil
            line.lineWidth = style == .line ? 1.5 : 1.2
            line.lineJoin = .round
            switch fill {
            case .utilization:
                // The gradient shows through the area (or the line) used as its mask.
                let gradient = CAGradientLayer()
                gradient.disableImplicitAnimations()
                gradient.locations = [0, 0.6, 1]
                gradient.startPoint = CGPoint(x: 0.5, y: 1)  // flipped: bottom
                gradient.endPoint = CGPoint(x: 0.5, y: 0)
                area.fillColor = NSColor.white.cgColor
                line.strokeColor = NSColor.white.cgColor
                gradient.mask = style == .area ? area : line
                addSublayer(gradient)
                gradients.append(gradient)
            case .rate:
                if style == .area { addSublayer(area) }
                addSublayer(line)
            }
            areas.append(area)
            lines.append(line)
        }
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSublayers() {
        super.layoutSublayers()
        for layer in areas + lines + gradients { layer.frame = bounds }
    }

    @MainActor func resolveColors(in appearance: NSAppearance) {
        let colors = [palette.calm, palette.warm, palette.hot].map { resolved($0, in: appearance) }
        for gradient in gradients { gradient.colors = colors }
        for (index, fill) in fills.enumerated() {
            guard case .rate(let color) = fill else { continue }
            areas[index].fillColor = resolved(color.withAlphaComponent(color.alphaComponent * 0.35), in: appearance)
            lines[index].strokeColor = resolved(color, in: appearance)
        }
    }

    /// Redraws from `series` (same order as the fills). `ceiling` maps to the top edge.
    func update(_ series: [RingBuffer<Float>], capacity: Int, ceiling: Double) {
        let size = bounds.size
        for index in areas.indices {
            guard index < series.count else { break }
            let (area, line) = Self.paths(series[index], capacity: capacity, ceiling: ceiling, size: size)
            if graphStyle == .area { areas[index].path = area }
            lines[index].path = line
        }
    }

    private static func paths(
        _ values: RingBuffer<Float>, capacity: Int, ceiling: Double, size: CGSize
    ) -> (area: CGPath?, line: CGPath?) {
        guard values.count > 1, capacity > 1, ceiling > 0, size.width > 0 else { return (nil, nil) }
        let step = size.width / CGFloat(capacity - 1)
        let count = values.count
        let line = CGMutablePath()
        var firstX: CGFloat = 0
        for (index, value) in values.enumerated() {
            let x = size.width - CGFloat(count - 1 - index) * step
            let y = size.height * (1 - CGFloat(min(max(Double(value), 0) / ceiling, 1)))
            if index == 0 {
                firstX = x
                line.move(to: CGPoint(x: x, y: y))
            } else {
                line.addLine(to: CGPoint(x: x, y: y))
            }
        }
        let area = line.mutableCopy() ?? CGMutablePath()
        area.addLine(to: CGPoint(x: size.width, y: size.height))
        area.addLine(to: CGPoint(x: firstX, y: size.height))
        area.closeSubpath()
        return (area, line)
    }
}

// MARK: - Bars

/// One small vertical bar per core, colored by load.
final class CoreBarsLayer: CALayer {
    private var tracks: [CALayer] = []
    private var bars: [CALayer] = []
    private var loads: [Double] = []
    private var palette = PanelPalette.make(.system)
    /// Resolved colors for buckets calm / warm / hot.
    private var bucketColors: [CGColor] = []

    init(count: Int, palette: PanelPalette) {
        self.palette = palette
        super.init()
        disableImplicitAnimations()
        for _ in 0..<count {
            let track = CALayer()
            track.disableImplicitAnimations()
            track.cornerRadius = 1.5
            let bar = CALayer()
            bar.disableImplicitAnimations()
            bar.cornerRadius = 1.5
            addSublayer(track)
            addSublayer(bar)
            tracks.append(track)
            bars.append(bar)
        }
        loads = Array(repeating: 0, count: count)
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSublayers() {
        super.layoutSublayers()
        let count = CGFloat(bars.count), gap: CGFloat = 2
        guard count > 0 else { return }
        let width = max(1, (bounds.width - gap * (count - 1)) / count)
        for index in bars.indices {
            let x = CGFloat(index) * (width + gap)
            tracks[index].frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            let height = max(1, bounds.height * CGFloat(min(max(loads[index], 0), 1)))
            bars[index].frame = CGRect(x: x, y: bounds.height - height, width: width, height: height)
        }
    }

    /// Updates bars; layers are only touched when a bar's height moves by at
    /// least half a point or its color bucket changes.
    func update(_ loads: ArraySlice<CPULoad>) {
        var changed = false
        let height = max(bounds.height, 1)
        for (index, load) in zip(bars.indices, loads) {
            let old = self.loads[index], new = load.total
            let moved = abs(new - old) * height >= 0.5
            let recolored = PanelPalette.bucket(new) != PanelPalette.bucket(old)
            guard moved || recolored else { continue }
            self.loads[index] = new
            if recolored, bucketColors.count == 3 {
                bars[index].backgroundColor = bucketColors[PanelPalette.bucket(new)]
            }
            changed = true
        }
        if changed { setNeedsLayout() }
    }

    @MainActor func resolveColors(in appearance: NSAppearance) {
        bucketColors = [palette.calm, palette.warm, palette.hot].map { resolved($0, in: appearance) }
        let track = resolved(palette.track, in: appearance)
        for (index, bar) in bars.enumerated() {
            tracks[index].backgroundColor = track
            bar.backgroundColor = bucketColors[PanelPalette.bucket(loads[index])]
        }
    }
}

/// A horizontal capsule split into colored segments (one segment = a fill bar).
final class SegmentedBarLayer: CALayer {
    private let track = CALayer()
    private var segments: [CALayer] = []
    private var colors: [NSColor] = []
    private var fractions: [Double] = []
    private var trackColor: NSColor = NSColor.labelColor.withAlphaComponent(0.12)

    init(colors: [NSColor], track trackColor: NSColor) {
        self.colors = colors
        self.trackColor = trackColor
        super.init()
        disableImplicitAnimations()
        masksToBounds = true
        track.disableImplicitAnimations()
        addSublayer(track)
        for _ in colors {
            let segment = CALayer()
            segment.disableImplicitAnimations()
            addSublayer(segment)
            segments.append(segment)
        }
        fractions = Array(repeating: 0, count: colors.count)
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSublayers() {
        super.layoutSublayers()
        cornerRadius = bounds.height / 2
        track.frame = bounds
        var x: CGFloat = 0
        for (segment, fraction) in zip(segments, fractions) {
            let width = bounds.width * CGFloat(min(max(fraction, 0), 1))
            segment.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            x += width
        }
    }

    func update(_ fractions: [Double]) {
        guard fractions != self.fractions else { return }
        self.fractions = fractions
        setNeedsLayout()
    }

    /// Recolors one segment (e.g. disk fullness); applied at the next color resolution
    /// and immediately with the given appearance.
    @MainActor func setColor(_ color: NSColor, segment: Int = 0, in appearance: NSAppearance) {
        guard segment < segments.count, colors[segment] != color else { return }
        colors[segment] = color
        segments[segment].backgroundColor = resolved(color, in: appearance)
    }

    @MainActor func resolveColors(in appearance: NSAppearance) {
        track.backgroundColor = resolved(trackColor, in: appearance)
        for (segment, color) in zip(segments, colors) { segment.backgroundColor = resolved(color, in: appearance) }
    }
}

/// A small filled circle.
final class DotLayer: CALayer {
    override init() {
        super.init()
        disableImplicitAnimations()
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSublayers() {
        super.layoutSublayers()
        cornerRadius = bounds.width / 2
    }
}
