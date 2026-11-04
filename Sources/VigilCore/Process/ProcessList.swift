// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import Foundation

/// Columns a process list can be sorted by.
public enum ProcessSortKey: String, Codable, Sendable, CaseIterable {
    case name, pid, user, cpu, memory, threads, diskRead, diskWrite, started
}

/// How to present a process list: sort, filter and tree (SPEC §3.2 "Processes").
public struct ProcessQuery: Sendable, Equatable {
    public var sort: ProcessSortKey = .cpu
    public var ascending = false
    /// Case-insensitive substring on name, path, user or PID; `/…/` for a regular expression.
    public var filter = ""
    public var tree = false
    public var collapsed: Set<ProcessIdentity> = []

    public init() {}
}

/// One row of a presented list.
public struct ProcessRow: Sendable, Equatable {
    public var entry: ProcessEntry
    /// Indentation level in tree mode (0 in a flat list).
    public var depth: Int
    public var hasChildren: Bool
    public var isCollapsed: Bool
}

public enum ProcessListBuilder {
    /// Sorted, filtered rows; in tree mode, children follow their parent and the
    /// ancestors of every match are kept so the tree stays connected.
    public static func rows(_ processes: [ProcessEntry], query: ProcessQuery) -> [ProcessRow] {
        let matcher = Matcher(query.filter)
        guard query.tree else {
            return
                processes
                .filter { matcher.matches($0) }
                .sorted { isOrdered($0, $1, query) }
                .map { ProcessRow(entry: $0, depth: 0, hasChildren: false, isCollapsed: false) }
        }

        // Index the forest. A process whose parent isn't present (or is itself) is a root.
        var byPID: [Int32: ProcessEntry] = [:]
        for entry in processes { byPID[entry.pid] = entry }
        var children: [Int32: [ProcessEntry]] = [:]
        var roots: [ProcessEntry] = []
        for entry in processes {
            if entry.parentPID != entry.pid, byPID[entry.parentPID] != nil {
                children[entry.parentPID, default: []].append(entry)
            } else {
                roots.append(entry)
            }
        }

        // With a filter, keep matches and their ancestors.
        var visible: Set<Int32>?
        if !matcher.isEmpty {
            var keep = Set<Int32>()
            for entry in processes where matcher.matches(entry) {
                var pid: Int32? = entry.pid
                var steps = 0
                while let current = pid, keep.insert(current).inserted, steps < 512 {
                    let parent = byPID[current]?.parentPID
                    pid = (parent == current) ? nil : parent
                    steps += 1
                }
            }
            visible = keep
        }

        var rows: [ProcessRow] = []
        rows.reserveCapacity(processes.count)
        var emitted = Set<Int32>()  // cycle guard
        func emit(_ entry: ProcessEntry, depth: Int) {
            guard emitted.insert(entry.pid).inserted else { return }
            let kids = (children[entry.pid] ?? []).filter { visible?.contains($0.pid) ?? true }
            let collapsed = query.collapsed.contains(entry.id)
            rows.append(ProcessRow(entry: entry, depth: depth, hasChildren: !kids.isEmpty, isCollapsed: collapsed))
            guard !collapsed else { return }
            for child in kids.sorted(by: { isOrdered($0, $1, query) }) { emit(child, depth: depth + 1) }
        }
        for root in roots.filter({ visible?.contains($0.pid) ?? true }).sorted(by: { isOrdered($0, $1, query) }) {
            emit(root, depth: 0)
        }
        return rows
    }

    /// Sort order. Processes without a value (restricted, or no sample yet) always
    /// go last regardless of direction; ties fall back to PID for a stable order.
    static func isOrdered(_ a: ProcessEntry, _ b: ProcessEntry, _ query: ProcessQuery) -> Bool {
        func compare<T: Comparable>(_ x: T?, _ y: T?) -> Bool? {
            switch (x, y) {
            case (nil, nil): return nil
            case (nil, _): return false
            case (_, nil): return true
            case (let x?, let y?): return x == y ? nil : (query.ascending ? x < y : x > y)
            }
        }
        let result: Bool? =
            switch query.sort {
            case .name:
                a.name.localizedCaseInsensitiveCompare(b.name) == .orderedSame
                    ? nil : ((a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending) == query.ascending)
            case .pid: a.pid == b.pid ? nil : ((a.pid < b.pid) == query.ascending)
            case .user: a.user == b.user ? nil : ((a.user < b.user) == query.ascending)
            case .cpu: compare(a.cpu, b.cpu)
            case .memory: compare(a.memory, b.memory)
            case .threads: compare(a.threads, b.threads)
            case .diskRead: compare(a.diskReadPerSecond, b.diskReadPerSecond)
            case .diskWrite: compare(a.diskWritePerSecond, b.diskWritePerSecond)
            case .started:
                a.id.startMicroseconds == b.id.startMicroseconds
                    ? nil : ((a.id.startMicroseconds < b.id.startMicroseconds) == query.ascending)
            }
        return result ?? (a.pid < b.pid)
    }

    private struct Matcher {
        let text: String
        let regex: NSRegularExpression?

        init(_ filter: String) {
            let trimmed = filter.trimmingCharacters(in: .whitespaces)
            // Patterns are capped: the filter runs over ~800 processes every tick,
            // and a long pathological pattern could stall the UI.
            if trimmed.count > 2, trimmed.count <= 256, trimmed.hasPrefix("/"), trimmed.hasSuffix("/") {
                regex = try? NSRegularExpression(
                    pattern: String(trimmed.dropFirst().dropLast()), options: .caseInsensitive)
            } else {
                regex = nil
            }
            text = trimmed
        }

        var isEmpty: Bool { text.isEmpty }

        func matches(_ entry: ProcessEntry) -> Bool {
            guard !text.isEmpty else { return true }
            let fields = [entry.name, entry.path ?? "", entry.user, String(entry.pid)]
            if let regex {
                return fields.contains { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
            }
            return fields.contains { $0.localizedCaseInsensitiveContains(text) }
        }
    }
}
