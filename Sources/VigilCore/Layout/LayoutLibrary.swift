// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

/// All saved layouts and which one is showing (SPEC §3.5).
public struct LayoutLibrary: Codable, Sendable, Equatable {
    public private(set) var profiles: [LayoutProfile]
    public private(set) var activeID: String

    public init(profiles: [LayoutProfile], activeID: String? = nil) {
        // Never empty, ids unique, active id valid.
        var seen = Set<String>()
        var unique = profiles.filter { seen.insert($0.id).inserted }
        if unique.isEmpty { unique = [.standard] }
        self.profiles = unique
        self.activeID = activeID.flatMap { id in unique.contains { $0.id == id } ? id : nil } ?? unique[0].id
    }

    public var active: LayoutProfile {
        get { profiles.first { $0.id == activeID } ?? profiles[0] }
        set {
            if let index = profiles.firstIndex(where: { $0.id == newValue.id }) {
                profiles[index] = newValue
            }
        }
    }

    public subscript(id: String) -> LayoutProfile? { profiles.first { $0.id == id } }

    public mutating func activate(_ id: String) {
        if profiles.contains(where: { $0.id == id }) { activeID = id }
    }

    /// Adds a profile (renamed if its name is taken) and returns its id.
    @discardableResult
    public mutating func add(_ profile: LayoutProfile, activate: Bool = false) -> String {
        var copy = profile
        if profiles.contains(where: { $0.id == copy.id }) { copy.id = LayoutProfile.newID() }
        copy.name = uniqueName(copy.name)
        profiles.append(copy)
        if activate { activeID = copy.id }
        return copy.id
    }

    @discardableResult
    public mutating func duplicate(_ id: String) -> String? {
        guard var copy = self[id] else { return nil }
        copy.id = LayoutProfile.newID()
        copy.name = copy.name + " Copy"
        copy.displays = nil  // a copy is never auto-switched to the same displays
        return add(copy)
    }

    public mutating func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = trimmed == profiles[index].name ? trimmed : uniqueName(trimmed, excluding: id)
    }

    /// Removes a profile; the last one can't be removed.
    public mutating func remove(_ id: String) {
        guard profiles.count > 1, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles.remove(at: index)
        if activeID == id { activeID = profiles[min(index, profiles.count - 1)].id }
    }

    /// Binds a profile to a set of displays (and unbinds any other profile from
    /// that exact set, so auto-switching is never ambiguous). `nil` unbinds.
    public mutating func bind(_ id: String, to displays: Set<String>?) {
        let sorted = displays.map { $0.sorted() }
        for index in profiles.indices {
            if profiles[index].id == id {
                profiles[index].displays = sorted
            } else if let sorted, profiles[index].displays == sorted {
                profiles[index].displays = nil
            }
        }
    }

    /// The profile bound to exactly these displays, if any.
    public func profile(forDisplays displays: Set<String>) -> LayoutProfile? {
        let key = displays.sorted()
        return profiles.first { $0.displays == key }
    }

    public func uniqueName(_ name: String, excluding id: String? = nil) -> String {
        let taken = Set(profiles.filter { $0.id != id }.map(\.name))
        guard taken.contains(name) else { return name }
        var number = 2
        while taken.contains("\(name) \(number)") { number += 1 }
        return "\(name) \(number)"
    }
}

/// The layouts Vigil ships with (SPEC §3.5).
public enum LayoutPreset: String, CaseIterable, Sendable {
    case standard, minimal, btop, sidebar, developer

    public var name: String {
        switch self {
        case .standard: "Standard"
        case .minimal: "Minimal"
        case .btop: "btop"
        case .sidebar: "Sidebar"
        case .developer: "Developer"
        }
    }

    public var summary: String {
        switch self {
        case .standard: "CPU and Memory with Network and Disk, top right"
        case .minimal: "Two extra-small tiles: CPU and Memory"
        case .btop: "Six panels in a grid, solid backgrounds (lightest on the window server)"
        case .sidebar: "A column of small panels along the right edge"
        case .developer: "CPU, Memory, Top Processes and Network"
        }
    }

    public var profile: LayoutProfile {
        switch self {
        case .standard:
            return LayoutProfile.standard
        case .minimal:
            return Self.grid(name: name, columns: [[(.cpu, .extraSmall)], [(.memory, .extraSmall)]])
        case .btop:
            var solid = AppearanceOverrides()
            solid.material = .solid
            var byMemory = PanelOptions()
            byMemory.topSort = .memory
            return Self.grid(
                name: name,
                columns: [
                    [(.cpu, .medium), (.network, .medium), (.topProcesses, .medium)],
                    [(.memory, .medium), (.disk, .medium), (.topProcesses, .medium)],
                ], appearance: solid, options: [5: byMemory])
        case .sidebar:
            return Self.grid(
                name: name,
                columns: [
                    [(.cpu, .small), (.memory, .small), (.network, .small), (.disk, .small), (.topProcesses, .small)]
                ])
        case .developer:
            return Self.grid(
                name: name,
                columns: [[(.cpu, .medium), (.memory, .medium), (.topProcesses, .medium), (.network, .small)]])
        }
    }

    /// Columns of panels anchored top-right; the first column is the rightmost.
    /// `options` is keyed by the panel's position in reading order.
    private static func grid(
        name: String, columns: [[(PanelKind, SizeClass)]], appearance: AppearanceOverrides = AppearanceOverrides(),
        options: [Int: PanelOptions] = [:]
    ) -> LayoutProfile {
        let margin = 16.0, gap = 12.0
        var panels: [PanelInstance] = []
        var x = margin
        for column in columns {
            var y = margin
            for (kind, sizeClass) in column {
                let index = panels.count
                panels.append(
                    PanelInstance(
                        id: "\(kind.rawValue)-\(index)", kind: kind, sizeClass: sizeClass,
                        placement: Placement(
                            display: .main, anchor: .topTrailing, offset: Point(x: x, y: y), size: sizeClass.size),
                        appearance: appearance, options: options[index] ?? PanelOptions()))
                y += sizeClass.size.height + gap
            }
            x += (column.map(\.1.size.width).max() ?? 0) + gap
        }
        return LayoutProfile(name: name, panels: panels)
    }
}
