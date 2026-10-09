import AppKit
import DBCore
import SwiftUI

/// Callbacks for an editable grid. Read-only grids leave these nil.
struct GridActions {
    var setValue: ((CellValue, Int, Int) -> Void)?
    var deleteRows: ((IndexSet) -> Void)?
    var duplicateRows: ((IndexSet) -> Void)?
    var sort: ((String) -> Void)?
    var filter: ((String, String?) -> Void)?
    /// Opens the row referenced by a foreign-key column value.
    var followForeignKey: ((String, String) -> Void)?
    var copyAsInsert: ((IndexSet) -> String)?
}

/// Spreadsheet-like grid backed by a view-based NSTableView.
struct DataGridView: NSViewRepresentable {
    var columns: [ResultColumn]
    var rowCount: Int
    /// Change this to force a reload.
    var version: Int
    var value: (Int, Int) -> (value: CellValue, state: CellState)
    var isEditable = false
    var sort: [SortKey] = []
    var primaryKeyColumns: Set<String> = []
    var foreignKeyColumns: Set<String> = []
    @Binding var selection: IndexSet
    var actions = GridActions()
    /// Closed set of values for a column (booleans, enums, CHECK lists): edited with a menu.
    var columnOptions: (Int) -> [String]? = { _ in nil }
    var isColumnEditable: (Int) -> Bool = { _ in true }
    var isColumnNullable: (Int) -> Bool = { _ in true }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// Take the space offered. Without this SwiftUI may size the grid to fit every row,
    /// which in stacks pushes surrounding views out of the window.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 300)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = GridTableView()
        tableView.coordinator = context.coordinator
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = Theme.contentBackgroundNS
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.gridColor = Theme.gridLineNS
        tableView.headerView = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: GridMetrics.headerHeight))
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = GridMetrics.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.doubleClicked(_:))
        tableView.action = #selector(Coordinator.clicked(_:))
        let menu = NSMenu()
        menu.delegate = context.coordinator
        tableView.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.contentBackgroundNS
        context.coordinator.tableView = tableView
        context.coordinator.rebuildColumns()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let previous = coordinator.parent
        coordinator.parent = self
        guard let tableView = coordinator.tableView else { return }
        if previous.columns != columns {
            coordinator.rebuildColumns()
            tableView.reloadData()
        } else if previous.version != version || previous.rowCount != rowCount || previous.isEditable != isEditable {
            if tableView.currentEditor() == nil { tableView.reloadData() }
        }
        coordinator.updateSortIndicators()
        if tableView.selectedRowIndexes != selection {
            tableView.selectRowIndexes(selection, byExtendingSelection: false)
            if let last = selection.last { tableView.scrollRowToVisible(last) }
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
        var parent: DataGridView
        weak var tableView: GridTableView?
        /// Column used for keyboard editing.
        var focusedColumn = 0
        private var editingCell: (row: Int, column: Int)?
        private var editCancelled = false

        init(parent: DataGridView) {
            self.parent = parent
        }

        func rebuildColumns() {
            guard let tableView else { return }
            for column in tableView.tableColumns.reversed() { tableView.removeTableColumn(column) }
            for (index, column) in parent.columns.enumerated() {
                let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(index)"))
                let header = GridHeaderCell(textCell: column.name)
                header.isPrimaryKey = parent.primaryKeyColumns.contains(column.name)
                header.isSortable = parent.actions.sort != nil
                tableColumn.headerCell = header
                tableColumn.headerToolTip = "\(column.name) — \(column.typeName)"
                tableColumn.width = idealWidth(for: index)
                tableColumn.minWidth = 48
                tableColumn.maxWidth = 2000
                tableView.addTableColumn(tableColumn)
            }
            focusedColumn = 0
            updateSortIndicators()
        }

        private func idealWidth(for column: Int) -> CGFloat {
            let name = parent.columns[column].name
            // Uppercase header + key icon + sort chevron.
            let header = CGFloat(name.count) * 8 + (parent.primaryKeyColumns.contains(name) ? 18 : 0) + 44
            var longest = 0
            for row in 0..<min(parent.rowCount, 60) {
                if case .value(let text) = parent.value(row, column).value {
                    longest = max(longest, min(text.count, 60))
                }
            }
            return min(max(max(header, CGFloat(longest) * 7.6 + 2 * GridMetrics.cellPadding + 4), 72), 420)
        }

        func updateSortIndicators() {
            guard let tableView else { return }
            var changed = false
            for tableColumn in tableView.tableColumns {
                guard let columnIndex = Int(tableColumn.identifier.rawValue), columnIndex < parent.columns.count,
                      let header = tableColumn.headerCell as? GridHeaderCell else { continue }
                let name = parent.columns[columnIndex].name
                let state = parent.sort.first(where: { $0.column == name }).map(\.ascending)
                if header.sortAscending != state {
                    header.sortAscending = state
                    changed = true
                }
            }
            if changed { tableView.headerView?.needsDisplay = true }
        }

        private func columnIndex(_ tableColumn: NSTableColumn?) -> Int? {
            tableColumn.flatMap { Int($0.identifier.rawValue) }
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { parent.rowCount }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let identifier = NSUserInterfaceItemIdentifier("GridRow")
            if let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? GridRowView { return view }
            let view = GridRowView()
            view.identifier = identifier
            return view
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = columnIndex(tableColumn), column < parent.columns.count, row < parent.rowCount else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("GridCell")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? GridCellView) ?? {
                let cell = GridCellView()
                cell.identifier = identifier
                cell.textField?.delegate = self
                return cell
            }()
            let (value, state) = parent.value(row, column)
            cell.configure(value: value, state: state, category: parent.columns[column].category)
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView else { return }
            let selection = tableView.selectedRowIndexes
            if parent.selection != selection {
                DispatchQueue.main.async { self.parent.selection = selection }
            }
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard let column = columnIndex(tableColumn), column < parent.columns.count else { return }
            parent.actions.sort?(parent.columns[column].name)
        }

        // MARK: Editing

        @objc func clicked(_ sender: NSTableView) {
            if sender.clickedColumn >= 0, let column = columnIndex(sender.tableColumns[sender.clickedColumn]) {
                focusedColumn = column
            }
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            guard sender.clickedRow >= 0, sender.clickedColumn >= 0 else { return }
            beginEditing(row: sender.clickedRow, viewColumn: sender.clickedColumn)
        }

        func beginEditingFocusedCell() {
            guard let tableView, tableView.selectedRow >= 0 else { return }
            let viewColumn = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("\(focusedColumn)"))
            beginEditing(row: tableView.selectedRow, viewColumn: max(viewColumn, 0))
        }

        private func beginEditing(row: Int, viewColumn: Int) {
            guard parent.isEditable, let tableView, viewColumn < tableView.numberOfColumns,
                  let column = columnIndex(tableView.tableColumns[viewColumn]),
                  parent.isColumnEditable(column),
                  parent.value(row, column).state != .deleted else { return }
            if let options = parent.columnOptions(column) {
                showOptions(options, row: row, column: column, viewColumn: viewColumn)
                return
            }
            guard let cell = tableView.view(atColumn: viewColumn, row: row, makeIfNecessary: true) as? GridCellView,
                  let field = cell.textField else { return }
            focusedColumn = column
            editingCell = (row, column)
            editCancelled = false
            field.stringValue = parent.value(row, column).value.editingText
            field.placeholderString = parent.columns[column].category == .temporal
                ? "Value, or NOW() / =expression" : "Value, or =expression"
            field.font = GridCellView.editingFont
            field.textColor = Theme.textPrimaryNS
            field.isEditable = true
            tableView.scrollColumnToVisible(viewColumn)
            tableView.window?.makeFirstResponder(field)
        }

        private var optionTarget: (row: Int, column: Int, options: [String])?

        /// Pops up a menu of the column's allowed values under the cell.
        private func showOptions(_ options: [String], row: Int, column: Int, viewColumn: Int) {
            guard let tableView else { return }
            focusedColumn = column
            optionTarget = (row, column, options)
            let current = parent.value(row, column).value
            let menu = NSMenu()
            var selected: NSMenuItem?
            for (index, option) in options.enumerated() {
                let item = NSMenuItem(title: option, action: #selector(pickOption(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                if current == .value(option) {
                    item.state = .on
                    selected = item
                }
                menu.addItem(item)
            }
            if parent.isColumnNullable(column) {
                menu.addItem(.separator())
                let item = NSMenuItem(title: "NULL", action: #selector(pickOption(_:)), keyEquivalent: "")
                item.target = self
                item.tag = -1
                if current == .null {
                    item.state = .on
                    selected = item
                }
                menu.addItem(item)
            }
            tableView.scrollColumnToVisible(viewColumn)
            let rect = tableView.frameOfCell(atColumn: viewColumn, row: row)
            menu.popUp(positioning: selected, at: NSPoint(x: rect.minX, y: rect.maxY), in: tableView)
        }

        @objc private func pickOption(_ sender: NSMenuItem) {
            guard let (row, column, options) = optionTarget else { return }
            optionTarget = nil
            let value: CellValue = sender.tag >= 0 && sender.tag < options.count ? .value(options[sender.tag]) : .null
            if value != parent.value(row, column).value {
                parent.actions.setValue?(value, row, column)
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                editCancelled = true
                control.abortEditing()
                finishEditing(control as? NSTextField)
                return true
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
                guard let (row, column) = editingCell, let tableView else { return false }
                tableView.window?.makeFirstResponder(tableView) // commits via controlTextDidEndEditing
                let viewColumn = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("\(column)"))
                let next = viewColumn + (selector == #selector(NSResponder.insertTab(_:)) ? 1 : -1)
                if next >= 0, next < tableView.numberOfColumns {
                    DispatchQueue.main.async { self.beginEditing(row: row, viewColumn: next) }
                }
                return true
            case #selector(NSResponder.insertNewline(_:)):
                tableView?.window?.makeFirstResponder(tableView)
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if !editCancelled, let (row, column) = editingCell, row < parent.rowCount {
                let text = field.stringValue
                let original = parent.value(row, column).value
                let edited = CellValue.parseInput(text, category: parent.columns[column].category)
                let unchanged = edited == original || (text.isEmpty && (original == .null || original == .defaultValue))
                if !unchanged { parent.actions.setValue?(edited, row, column) }
            }
            finishEditing(field)
        }

        private func finishEditing(_ field: NSTextField?) {
            field?.isEditable = false
            editingCell = nil
            if tableView?.window?.firstResponder !== tableView {
                tableView?.window?.makeFirstResponder(tableView)
            }
            tableView?.reloadData()
        }

        // MARK: Clipboard

        func tsv(rows: IndexSet) -> String {
            let order = visibleColumnOrder()
            return rows.map { row in
                order.map { column -> String in
                    switch parent.value(row, column).value {
                    case .value(let text): text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
                    case .null: "NULL"
                    case .defaultValue: "DEFAULT"
                    case .expression(let expression): expression
                    }
                }.joined(separator: "\t")
            }.joined(separator: "\n")
        }

        private func visibleColumnOrder() -> [Int] {
            tableView?.tableColumns.compactMap { columnIndex($0) } ?? Array(parent.columns.indices)
        }

        func copySelection() {
            guard let rows = tableView?.selectedRowIndexes, !rows.isEmpty else { return }
            setPasteboard(tsv(rows: rows))
        }

        private func setPasteboard(_ string: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        }

        func deleteSelection() {
            guard parent.isEditable, let rows = tableView?.selectedRowIndexes, !rows.isEmpty else { return }
            parent.actions.deleteRows?(rows)
        }

        // MARK: Context menu

        private var menuTarget: (rows: IndexSet, column: Int?) = ([], nil)

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tableView, tableView.clickedRow >= 0 else { return }
            let clickedRow = tableView.clickedRow
            let rows = tableView.selectedRowIndexes.contains(clickedRow) ? tableView.selectedRowIndexes : IndexSet(integer: clickedRow)
            let column = tableView.clickedColumn >= 0 ? columnIndex(tableView.tableColumns[tableView.clickedColumn]) : nil
            menuTarget = (rows, column)

            func add(_ title: String, _ action: Selector, enabled: Bool = true) {
                let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }

            if column != nil {
                add("Copy Cell Value", #selector(copyCell))
                add("Copy Column Name", #selector(copyColumnName))
            }
            add(rows.count > 1 ? "Copy \(rows.count) Rows" : "Copy Row", #selector(copyRows))
            if parent.actions.copyAsInsert != nil {
                add("Copy as INSERT", #selector(copyAsInsert))
            }

            if let column, parent.actions.filter != nil || parent.actions.followForeignKey != nil {
                menu.addItem(.separator())
                let value = parent.value(clickedRow, column).value
                if parent.actions.filter != nil {
                    let label: String = switch value {
                    case .value(let text): "Filter \(parent.columns[column].name) = \(text.prefix(30))"
                    default: "Filter \(parent.columns[column].name) IS NULL"
                    }
                    add(label, #selector(filterByValue))
                }
                if parent.actions.followForeignKey != nil, parent.foreignKeyColumns.contains(parent.columns[column].name),
                   case .value = value {
                    add("Open Referenced Row", #selector(followForeignKey))
                }
            }

            if parent.isEditable {
                menu.addItem(.separator())
                if let column, parent.isColumnEditable(column) {
                    let info = parent.columns[column]
                    if info.category == .temporal { add("Set to NOW()", #selector(setNow)) }
                    if info.typeName == "uuid" { add("Generate UUID", #selector(setUUID)) }
                    add("Set SQL Expression…", #selector(setExpression))
                    if parent.isColumnNullable(column) { add("Set NULL", #selector(setNull)) }
                    add("Set DEFAULT", #selector(setDefault))
                    add("Set Empty String", #selector(setEmpty))
                    add("Edit Cell", #selector(editCell))
                    menu.addItem(.separator())
                }
                add(rows.count > 1 ? "Duplicate \(rows.count) Rows" : "Duplicate Row", #selector(duplicateRows))
                add(rows.count > 1 ? "Delete \(rows.count) Rows" : "Delete Row", #selector(deleteRows))
            }
        }

        @objc private func copyCell() {
            guard let column = menuTarget.column, let row = menuTarget.rows.first else { return }
            if case .value(let text) = parent.value(row, column).value { setPasteboard(text) } else { setPasteboard("NULL") }
        }

        @objc private func copyColumnName() {
            guard let column = menuTarget.column else { return }
            setPasteboard(parent.columns[column].name)
        }

        @objc private func copyRows() { setPasteboard(tsv(rows: menuTarget.rows)) }

        @objc private func copyAsInsert() {
            if let sql = parent.actions.copyAsInsert?(menuTarget.rows) { setPasteboard(sql) }
        }

        @objc private func filterByValue() {
            guard let column = menuTarget.column, let row = menuTarget.rows.first else { return }
            let text: String? = if case .value(let text) = parent.value(row, column).value { text } else { nil }
            parent.actions.filter?(parent.columns[column].name, text)
        }

        @objc private func followForeignKey() {
            guard let column = menuTarget.column, let row = menuTarget.rows.first,
                  case .value(let text) = parent.value(row, column).value else { return }
            parent.actions.followForeignKey?(parent.columns[column].name, text)
        }

        private func setTargetCells(_ value: CellValue) {
            guard let column = menuTarget.column else { return }
            for row in menuTarget.rows { parent.actions.setValue?(value, row, column) }
        }

        @objc private func setNull() { setTargetCells(.null) }
        @objc private func setNow() { setTargetCells(.expression("now()")) }
        @objc private func setUUID() { setTargetCells(.expression("gen_random_uuid()")) }

        @objc private func setExpression() {
            guard let column = menuTarget.column, let row = menuTarget.rows.first else { return }
            let alert = NSAlert()
            alert.messageText = "SQL expression for \(parent.columns[column].name)"
            alert.informativeText = "Evaluated by the server when you commit, e.g. now() + interval '1 day', lower(email), gen_random_uuid()."
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            input.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            if case .expression(let current) = parent.value(row, column).value { input.stringValue = current }
            input.placeholderString = "now()"
            alert.accessoryView = input
            alert.addButton(withTitle: "Set")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = input
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let expression = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expression.isEmpty else { return }
            setTargetCells(.expression(expression))
        }
        @objc private func setDefault() { setTargetCells(.defaultValue) }
        @objc private func setEmpty() { setTargetCells(.value("")) }

        @objc private func editCell() {
            guard let tableView, let column = menuTarget.column, let row = menuTarget.rows.first else { return }
            beginEditing(row: row, viewColumn: tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("\(column)")))
        }

        @objc private func duplicateRows() { parent.actions.duplicateRows?(menuTarget.rows) }
        @objc private func deleteRows() { parent.actions.deleteRows?(menuTarget.rows) }
    }
}

// MARK: - Table view and cells

final class GridTableView: NSTableView {
    weak var coordinator: DataGridView.Coordinator?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: // delete, forward delete
            coordinator?.deleteSelection()
        case 36, 76: // return, enter
            coordinator?.beginEditingFocusedCell()
        default:
            super.keyDown(with: event)
        }
    }

    /// Edit ▸ Delete.
    @objc func delete(_ sender: Any?) {
        coordinator?.deleteSelection()
    }

    @objc func copy(_ sender: Any?) {
        coordinator?.copySelection()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selectedRow >= 0 }
        return super.validateUserInterfaceItem(item)
    }
}

enum GridMetrics {
    static let rowHeight: CGFloat = 32
    static let headerHeight: CGFloat = 36
    static let cellPadding: CGFloat = 12
}

final class GridCellView: NSTableCellView {
    private static let font = NSFont.systemFont(ofSize: 13)
    private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    static let editingFont = NSFont.systemFont(ofSize: 13)
    private static let expressionFont = NSFontManager.shared.convert(NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                                                                     toHaveTrait: .italicFontMask)

    override init(frame: NSRect) {
        super.init(frame: frame)
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.isEditable = false
        field.focusRingType = .none
        field.drawsBackground = false
        addSubview(field)
        textField = field
        wantsLayer = true
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: GridMetrics.cellPadding),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -GridMetrics.cellPadding),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(value: CellValue, state: CellState, category: ValueCategory) {
        guard let field = textField else { return }
        field.isEditable = false
        field.placeholderString = nil
        field.font = category == .number ? Self.numberFont : Self.font
        field.alignment = category == .number ? .right : .left
        var attributes: [NSAttributedString.Key: Any] = [:]
        switch value {
        case .value(let text):
            let display = text.count > 500 ? String(text.prefix(500)) + "…" : text
            field.stringValue = display.replacingOccurrences(of: "\n", with: " ↵ ")
            field.textColor = Theme.textPrimaryNS
        case .null:
            field.stringValue = "NULL"
            field.textColor = Theme.textTertiaryNS
        case .defaultValue:
            field.stringValue = "DEFAULT"
            field.textColor = Theme.textTertiaryNS
        case .expression(let expression):
            // Pending SQL expression; the real value appears after commit.
            field.stringValue = expression.replacingOccurrences(of: "\n", with: " ")
            field.textColor = Theme.accentTextNS
            field.font = Self.expressionFont
        }
        if state == .deleted {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.foregroundColor] = Theme.textSecondaryNS
            attributes[.font] = field.font
            field.attributedStringValue = NSAttributedString(string: field.stringValue, attributes: attributes)
        }
        let background: NSColor? = switch state {
        case .normal: nil
        case .modified: NSColor.systemYellow.withAlphaComponent(0.28)
        case .inserted: NSColor.systemGreen.withAlphaComponent(0.2)
        case .deleted: NSColor.systemRed.withAlphaComponent(0.2)
        }
        layer?.backgroundColor = background?.cgColor
    }
}


// MARK: - Header and rows

/// Uppercase, letter-spaced header with a key icon for primary keys and sort chevrons.
final class GridHeaderCell: NSTableHeaderCell {
    var isPrimaryKey = false
    var isSortable = true
    /// `nil` when the column isn't sorted.
    var sortAscending: Bool?

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        Theme.contentBackgroundNS.setFill()
        cellFrame.fill()
        Theme.separatorNS.setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.maxY - 1, width: cellFrame.width, height: 1).fill()
        Theme.gridLineNS.setFill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + 9, width: 1, height: cellFrame.height - 18).fill()

        var x = cellFrame.minX + GridMetrics.cellPadding
        if isPrimaryKey {
            drawSymbol("key.fill", color: Theme.accentNS, size: 9.5, at: NSPoint(x: x, y: cellFrame.midY), in: controlView)
            x += 16
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let title = NSAttributedString(string: stringValue.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .kern: 0.6,
            .foregroundColor: sortAscending == nil ? Theme.textSecondaryNS : Theme.textPrimaryNS,
            .paragraphStyle: paragraph,
        ])
        let chevronSpace: CGFloat = isSortable ? 20 : 0
        let available = max(0, cellFrame.maxX - x - GridMetrics.cellPadding - chevronSpace)
        let size = title.size()
        let width = min(size.width, available)
        title.draw(with: NSRect(x: x, y: cellFrame.midY - size.height / 2, width: available, height: size.height),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if isSortable, !stringValue.isEmpty {
            let symbol = sortAscending.map { $0 ? "chevron.up" : "chevron.down" } ?? "chevron.up.chevron.down"
            drawSymbol(symbol, color: sortAscending == nil ? Theme.textTertiaryNS : Theme.accentNS, size: 8.5,
                       at: NSPoint(x: x + width + 7, y: cellFrame.midY), in: controlView)
        }
    }

    private func drawSymbol(_ name: String, color: NSColor, size: CGFloat, at point: NSPoint, in view: NSView) {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let rect = NSRect(x: point.x, y: point.y - image.size.height / 2, width: image.size.width, height: image.size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// Row with a soft accent selection and a faint bottom separator.
final class GridRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawBackground(in dirtyRect: NSRect) {
        Theme.contentBackgroundNS.setFill()
        bounds.fill()
        Theme.separatorNS.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        Theme.selectionNS.setFill()
        bounds.fill()
        Theme.accentNS.setFill()
        NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
    }
}
