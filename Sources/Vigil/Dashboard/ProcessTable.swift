// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import AppKit
import VigilCore

/// The Dashboard's process table: a view-based `NSTableView` with row reuse and
/// targeted reloads (SwiftUI `Table` re-diffs everything and stutters at ~1000
/// rows per second; SPEC §4.5). Selection is pinned to a process identity, so it
/// survives re-sorting and refreshes.
@MainActor
final class ProcessTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    enum Column: String, CaseIterable {
        case name, pid, user, cpu, memory, threads, diskRead, diskWrite, started

        var title: String {
            switch self {
            case .name: "Name"
            case .pid: "PID"
            case .user: "User"
            case .cpu: "% CPU"
            case .memory: "Memory"
            case .threads: "Threads"
            case .diskRead: "Read/s"
            case .diskWrite: "Write/s"
            case .started: "Started"
            }
        }

        var width: CGFloat {
            switch self {
            case .name: 240
            case .pid: 60
            case .user: 90
            case .cpu: 64
            case .memory: 80
            case .threads: 60
            case .diskRead, .diskWrite: 80
            case .started: 104
            }
        }

        var sortKey: ProcessSortKey {
            switch self {
            case .name: .name
            case .pid: .pid
            case .user: .user
            case .cpu: .cpu
            case .memory: .memory
            case .threads: .threads
            case .diskRead: .diskRead
            case .diskWrite: .diskWrite
            case .started: .started
            }
        }

        /// Text columns sort A→Z first; numeric ones biggest first.
        var defaultAscending: Bool { self == .name || self == .user }
    }

    let tableView = KeyboardTableView()
    private(set) var rows: [ProcessRow] = []
    var query = ProcessQuery() {
        didSet { if query != oldValue { reload(force: true) } }
    }
    var units = UnitSettings()
    private(set) var selected: ProcessIdentity?
    private var metrics: ProcessMetrics?
    private var applyingSelection = false
    private var icons: [String: NSImage] = [:]
    private let startFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
    private let oldStartFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    var onSelectionChange: ((ProcessIdentity?) -> Void)?

    override init() {
        super.init()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.allowsColumnReordering = true
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.style = .fullWidth
        tableView.rowHeight = 20
        tableView.autosaveName = "VigilProcessTable"
        tableView.autosaveTableColumns = true
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column == .name ? 120 : 44
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(
                key: column.rawValue, ascending: column.defaultAscending)
            if column != .name {
                tableColumn.headerCell.alignment = column == .user || column == .started ? .left : .right
            }
            tableView.addTableColumn(tableColumn)
        }
        tableView.sortDescriptors = [NSSortDescriptor(key: Column.cpu.rawValue, ascending: false)]
        tableView.dataSource = self
        tableView.delegate = self
    }

    // MARK: - Data

    func update(_ metrics: ProcessMetrics) {
        self.metrics = metrics
        reload(force: false)
    }

    func select(_ identity: ProcessIdentity?) {
        selected = identity
        applySelection(scroll: true)
        onSelectionChange?(identity)
    }

    /// Re-sorting reorders rows on most ticks, so instead of `reloadData` (which
    /// rebuilds every visible row view; measured ~4 % CPU) the cells already on
    /// screen are reconfigured in place. Only a change in row count touches the
    /// table's structure. Selection follows the process, not the row index.
    private func reload(force: Bool) {
        guard let metrics else { return }
        rows = ProcessListBuilder.rows(metrics.processes, query: query)
        if force || tableView.numberOfRows != rows.count {
            tableView.noteNumberOfRowsChanged()
        }
        let visible = tableView.rows(in: tableView.visibleRect)
        for row in visible.location..<(visible.location + visible.length) where row < rows.count {
            for (columnIndex, tableColumn) in tableView.tableColumns.enumerated() {
                guard let column = Column(rawValue: tableColumn.identifier.rawValue),
                    let cell = tableView.view(atColumn: columnIndex, row: row, makeIfNecessary: false) as? ProcessCell
                else { continue }
                configure(cell, column: column, row: rows[row], rowIndex: row)
            }
        }
        applySelection(scroll: false)
    }

    private func applySelection(scroll: Bool) {
        applyingSelection = true
        defer { applyingSelection = false }
        guard let selected, let index = rows.firstIndex(where: { $0.entry.id == selected }) else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes([index], byExtendingSelection: false)
        if scroll { tableView.scrollRowToVisible(index) }
    }

    var selectedEntry: ProcessEntry? { selected.flatMap { id in rows.first { $0.entry.id == id }?.entry } }

    // MARK: - Data source & delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue), row < rows.count else {
            return nil
        }
        let identifier = NSUserInterfaceItemIdentifier("cell.\(column.rawValue)")
        let cell =
            (tableView.makeView(withIdentifier: identifier, owner: nil) as? ProcessCell)
            ?? {
                let cell = ProcessCell(showsIcon: column == .name)
                cell.identifier = identifier
                return cell
            }()
        configure(cell, column: column, row: rows[row], rowIndex: row)
        return cell
    }

    private func configure(_ cell: ProcessCell, column: Column, row: ProcessRow, rowIndex: Int) {
        let entry = row.entry
        let dash = "—"
        var text: String
        var alignment: NSTextAlignment = .right
        var dimmed = false
        switch column {
        case .name:
            text = entry.name
            alignment = .left
            let indentation = query.tree ? CGFloat(row.depth) * 14 : 0
            if cell.indentation != indentation { cell.indentation = indentation }
            cell.disclosure = query.tree && row.hasChildren ? (row.isCollapsed ? .collapsed : .expanded) : .none
            cell.onToggle = { [weak self] in self?.toggle(entry.id) }
            let image = icon(for: entry)
            if cell.icon !== image { cell.icon = image }
        case .pid: text = String(entry.pid)
        case .user:
            text = entry.user
            alignment = .left
        case .cpu:
            text = entry.cpu.map { Units.percent($0, decimals: 1) } ?? dash
            dimmed = entry.cpu == nil
        case .memory:
            text = entry.memory.map { Units.bytes(Double($0), style: units.bytes) } ?? dash
            dimmed = entry.memory == nil
        case .threads:
            text = entry.threads.map(String.init) ?? dash
            dimmed = entry.threads == nil
        case .diskRead:
            text = entry.diskReadPerSecond.map { Units.rate(bytesPerSecond: $0, style: units.bytes) } ?? dash
            dimmed = entry.diskReadPerSecond == nil
        case .diskWrite:
            text = entry.diskWritePerSecond.map { Units.rate(bytesPerSecond: $0, style: units.bytes) } ?? dash
            dimmed = entry.diskWritePerSecond == nil
        case .started:
            let date = Date(timeIntervalSince1970: entry.startDate)
            text =
                Calendar.current.isDateInToday(date)
                ? startFormatter.string(from: date) : oldStartFormatter.string(from: date)
            alignment = .left
        }
        cell.set(text: text, alignment: alignment, dimmed: dimmed)
        cell.setAccessibilityLabel("\(column.title) \(text)")
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applyingSelection else { return }
        let index = tableView.selectedRow
        selected = index >= 0 && index < rows.count ? rows[index].entry.id : nil
        onSelectionChange?(selected)
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key,
            let column = Column(rawValue: key)
        else { return }
        query.sort = column.sortKey
        query.ascending = descriptor.ascending
    }

    // MARK: - Actions

    func toggle(_ identity: ProcessIdentity) {
        if query.collapsed.contains(identity) {
            query.collapsed.remove(identity)
        } else {
            query.collapsed.insert(identity)
        }
    }

    /// Moves the sort to the previous/next column (h/l), keeping each column's natural direction.
    func shiftSortColumn(by offset: Int) {
        let columns = tableView.tableColumns.compactMap { Column(rawValue: $0.identifier.rawValue) }
        guard let current = columns.firstIndex(where: { $0.sortKey == query.sort }) else { return }
        let next = columns[(current + offset + columns.count) % columns.count]
        tableView.sortDescriptors = [NSSortDescriptor(key: next.rawValue, ascending: next.defaultAscending)]
    }

    func reverseSort() {
        guard let descriptor = tableView.sortDescriptors.first else { return }
        tableView.sortDescriptors = [descriptor.reversedSortDescriptor as? NSSortDescriptor ?? descriptor]
    }

    /// App icon for processes inside an .app bundle, a generic one otherwise.
    /// Cached as a single 32×32 px bitmap: workspace icons carry every size up
    /// to 1024 px, which made the cache the bulk of the Dashboard's memory.
    func icon(for entry: ProcessEntry) -> NSImage? {
        guard let path = entry.path else { return nil }
        let key = path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" } ?? path
        if let cached = icons[key] { return cached }
        let small = Self.thumbnail(NSWorkspace.shared.icon(forFile: key), points: 16)
        if icons.count > 500 { icons.removeAll() }
        icons[key] = small
        return small
    }

    static func thumbnail(_ image: NSImage, points: CGFloat) -> NSImage {
        let pixels = Int(points * 2)
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: NSSize(width: points, height: points))
        result.addRepresentation(bitmap)
        return result
    }
}

/// Lets the Dashboard handle btop-style keys before the table does.
final class KeyboardTableView: NSTableView {
    var keyHandler: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// A table cell: optional disclosure triangle and icon, then one text field.
/// Laid out by hand (no Auto Layout) since hundreds are reused per second.
final class ProcessCell: NSTableCellView {
    enum Disclosure { case none, expanded, collapsed }

    private let label = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let toggleButton = NSButton()
    private let showsIcon: Bool
    var indentation: CGFloat = 0 { didSet { needsLayout = true } }
    private static let expandImage = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Expand")
    private static let collapseImage = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Collapse")

    var disclosure: Disclosure = .none {
        didSet {
            guard disclosure != oldValue else { return }
            toggleButton.isHidden = disclosure == .none
            toggleButton.image = disclosure == .collapsed ? Self.expandImage : Self.collapseImage
        }
    }
    var icon: NSImage? {
        get { iconView.image }
        set { iconView.image = newValue }
    }
    var onToggle: (() -> Void)?

    init(showsIcon: Bool) {
        self.showsIcon = showsIcon
        super.init(frame: .zero)
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        textField = label
        if showsIcon {
            iconView.imageScaling = .scaleProportionallyDown
            addSubview(iconView)
            imageView = iconView
            toggleButton.isBordered = false
            toggleButton.imagePosition = .imageOnly
            toggleButton.target = self
            toggleButton.action = #selector(toggle)
            toggleButton.isHidden = true
            addSubview(toggleButton)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func toggle() { onToggle?() }

    /// Touches the text field only when something visible changed.
    func set(text: String, alignment: NSTextAlignment, dimmed: Bool) {
        if label.stringValue != text { label.stringValue = text }
        if label.alignment != alignment { label.alignment = alignment }
        let color: NSColor = dimmed ? .tertiaryLabelColor : .labelColor
        if label.textColor != color { label.textColor = color }
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 2
        let height = bounds.height
        if showsIcon {
            x += indentation
            toggleButton.frame = CGRect(x: x, y: (height - 14) / 2, width: 14, height: 14)
            x += 16
            iconView.frame = CGRect(x: x, y: (height - 16) / 2, width: 16, height: 16)
            x += 20
        }
        let textHeight = label.intrinsicContentSize.height
        label.frame = CGRect(
            x: x, y: (height - textHeight) / 2, width: max(bounds.width - x - 2, 0), height: textHeight)
    }
}
