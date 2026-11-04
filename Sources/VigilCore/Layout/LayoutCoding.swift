// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

// Lenient decoding: a layout file written by a newer or older Vigil must still
// load. Missing optional fields take defaults; panels that can't be decoded
// (e.g. a kind this version doesn't know) are skipped instead of failing the file.

extension PanelInstance {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        guard id.count <= 100 else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "id too long")
        }
        self.init(
            id: id,
            kind: try container.decode(PanelKind.self, forKey: .kind),
            sizeClass: (try? container.decodeIfPresent(SizeClass.self, forKey: .sizeClass)) ?? .medium,
            placement: try container.decode(Placement.self, forKey: .placement),
            level: (try? container.decodeIfPresent(PanelLevel.self, forKey: .level)) ?? .desktop,
            appearance: Self.decodeAppearance(container),
            options: container.lenient(.options, default: PanelOptions()),
            clickThrough: (try? container.decodeIfPresent(Bool.self, forKey: .clickThrough)) ?? false,
            isVisible: (try? container.decodeIfPresent(Bool.self, forKey: .isVisible)) ?? true)
    }
}

extension PanelInstance {
    fileprivate static func decodeAppearance(_ container: KeyedDecodingContainer<CodingKeys>) -> AppearanceOverrides {
        var appearance = container.lenient(.appearance, default: AppearanceOverrides())
        // M2 stored "material" (glass / clearGlass / solid) directly on the panel.
        if appearance.material == nil, let legacy: String = container.lenient(.legacyMaterial) {
            switch legacy {
            case "solid": appearance.material = .solid
            case "clearGlass":
                appearance.material = .glass
                appearance.transparency = 0.65
            default: break
            }
        }
        return appearance
    }
}

extension Placement {
    /// Window sizes from a file are kept within what a screen can show.
    static func sanitized(_ size: Size) -> Size {
        func clamp(_ value: Double, _ low: Double) -> Double { value.isFinite ? min(max(value, low), 10_000) : low }
        return Size(width: clamp(size.width, 60), height: clamp(size.height, 40))
    }

    /// Offsets are kept to a sane range (the resolver also keeps panels on screen).
    static func sanitized(_ offset: Point) -> Point {
        func clamp(_ value: Double) -> Double { value.isFinite ? min(max(value, -20_000), 20_000) : 0 }
        return Point(x: clamp(offset.x), y: clamp(offset.y))
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            display: (try? container.decodeIfPresent(DisplayRef.self, forKey: .display)) ?? .main,
            anchor: (try? container.decodeIfPresent(Anchor.self, forKey: .anchor)) ?? .topTrailing,
            offset: Self.sanitized(
                (try? container.decodeIfPresent(Point.self, forKey: .offset)) ?? Point(x: 16, y: 16)),
            size: Self.sanitized(try container.decode(Size.self, forKey: .size)),
            desktop: (try? container.decodeIfPresent(DesktopRef.self, forKey: .desktop)) ?? .all)
    }
}

extension LayoutProfile {
    /// Decodes each element on its own so one bad entry doesn't lose the rest.
    private struct Lossy<Wrapped: Decodable>: Decodable {
        let value: Wrapped?
        init(from decoder: any Decoder) throws { value = try? Wrapped(from: decoder) }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = String(((try? container.decodeIfPresent(String.self, forKey: .name)) ?? "Layout").prefix(100))
        // Every panel is a window: cap them so a hostile file can't open thousands.
        let panels = try container.decode([Lossy<PanelInstance>].self, forKey: .panels).compactMap(\.value)
            .prefix(LayoutProfile.maximumPanels)
        // Ids must be unique; keep the first of any duplicates.
        var seen = Set<String>()
        self.init(
            id: container.lenient(.id, default: LayoutProfile.newID()), name: name,
            panels: panels.filter { seen.insert($0.id).inserted }, displays: container.lenient(.displays))
        if id.count > 100 { id = LayoutProfile.newID() }
    }
}
