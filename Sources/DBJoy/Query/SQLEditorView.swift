import AppKit
import DBCore
import SwiftUI

struct SQLEditorView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    @Binding var requestedSelection: NSRange?
    var isEditable = true
    var catalog: () -> CompletionCatalog = { CompletionCatalog() }
    var onRun: (QueryTabModel.Scope) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 200)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SQLTextView(usingTextLayoutManager: false)
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = SQLTextView.editorFont
        textView.textColor = .textColor
        textView.backgroundColor = Theme.contentBackgroundNS
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.typingAttributes = [.font: SQLTextView.editorFont, .foregroundColor: NSColor.textColor]
        textView.string = text
        textView.isEditable = isEditable
        textView.setAccessibilityIdentifier("sql-editor")
        textView.setAccessibilityLabel("SQL editor")

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = Theme.contentBackgroundNS
        scrollView.documentView = textView

        let ruler = LineNumberRulerView(textView: textView, scrollView: scrollView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        context.coordinator.textView = textView
        textView.highlight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        textView.isEditable = isEditable
        if textView.string != text {
            textView.string = text
            textView.highlight()
            scrollView.verticalRulerView?.needsDisplay = true
        }
        if let requested = requestedSelection {
            let length = (textView.string as NSString).length
            let range = NSRange(location: min(requested.location, length), length: min(requested.length, max(0, length - requested.location)))
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            textView.window?.makeFirstResponder(textView)
            DispatchQueue.main.async { self.requestedSelection = nil }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLEditorView
        weak var textView: SQLTextView?

        init(parent: SQLEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            textView.highlight()
            parent.text = textView.string
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            let range = textView.selectedRange()
            if parent.selection != range {
                DispatchQueue.main.async { self.parent.selection = range }
            }
        }
    }
}

// MARK: - Text view

final class SQLTextView: NSTextView {
    static let editorFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    weak var coordinator: SQLEditorView.Coordinator?
    private let completion = CompletionPopup()
    private var completionRange: Range<Int>?
    private var shouldComplete = false

    // MARK: Highlighting

    func highlight() {
        guard let storage = textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: Self.editorFont, .foregroundColor: NSColor.textColor], range: full)
        if storage.length < 500_000 {
            for token in SQLLexer.tokens(in: storage.string) {
                guard let color = Self.color(for: token.kind) else { continue }
                storage.addAttribute(.foregroundColor, value: color, range: token.nsRange)
            }
        }
        storage.endEditing()
    }

    private static func color(for kind: SQLToken.Kind) -> NSColor? {
        switch kind {
        case .keyword: Theme.accentTextNS
        case .string: .systemRed
        case .number: .systemBlue
        case .comment: .secondaryLabelColor
        case .parameter: .systemOrange
        case .quotedIdentifier: .systemTeal
        case .identifier, .op, .punctuation: nil
        }
    }

    // MARK: Keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 36 || event.keyCode == 76, flags.contains(.command) {
            completion.dismiss()
            coordinator?.parent.onRun(flags.contains(.shift) ? .all : .current)
            return true
        }
        if flags == .command, event.charactersIgnoringModifiers == "/" {
            toggleLineComment()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if completion.isVisible {
            switch event.keyCode {
            case 125: completion.move(1); return // down
            case 126: completion.move(-1); return // up
            case 36, 48, 76: acceptCompletion(); return // return, tab, enter
            case 53: completion.dismiss(); return // escape
            default: break
            }
        }
        if flags == .control, event.keyCode == 49 { // ctrl-space
            updateCompletion(explicit: true)
            return
        }
        if event.keyCode == 53 { // escape: explicit completion
            updateCompletion(explicit: true)
            return
        }
        super.keyDown(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        if let text = string as? String, text.count == 1, let scalar = text.unicodeScalars.first {
            let c = UInt16(truncatingIfNeeded: scalar.value)
            shouldComplete = SQLLexer.isIdentChar(c) || text == "."
        } else {
            shouldComplete = false
        }
        if shouldComplete || completion.isVisible { updateCompletion(explicit: false) }
    }

    override func deleteBackward(_ sender: Any?) {
        super.deleteBackward(sender)
        if completion.isVisible { updateCompletion(explicit: false) }
    }

    override func insertNewline(_ sender: Any?) {
        // Keep the current line's indentation.
        let ns = string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let line = ns.substring(with: lineRange)
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        super.insertNewline(sender)
        if !indent.isEmpty { super.insertText(String(indent), replacementRange: selectedRange()) }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if stillSelecting { completion.dismiss() }
    }

    override func resignFirstResponder() -> Bool {
        completion.dismiss()
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        completion.dismiss()
        super.mouseDown(with: event)
    }

    private func toggleLineComment() {
        let ns = string as NSString
        let lines = ns.lineRange(for: selectedRange())
        let text = ns.substring(with: lines)
        var parts = text.components(separatedBy: "\n")
        let trailingEmpty = parts.last == ""
        if trailingEmpty { parts.removeLast() }
        let allCommented = parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }
        let toggled = parts.map { line -> String in
            if allCommented {
                guard let range = line.range(of: "--") else { return line }
                var result = line
                result.removeSubrange(range)
                if result[range.lowerBound...].hasPrefix(" ") { result.remove(at: range.lowerBound) }
                return result
            }
            return line.trimmingCharacters(in: .whitespaces).isEmpty ? line : "-- " + line
        }
        let replacement = toggled.joined(separator: "\n") + (trailingEmpty ? "\n" : "")
        if shouldChangeText(in: lines, replacementString: replacement) {
            replaceCharacters(in: lines, with: replacement)
            didChangeText()
            setSelectedRange(NSRange(location: lines.location, length: (replacement as NSString).length))
        }
    }

    // MARK: Completion

    private func updateCompletion(explicit: Bool) {
        guard let coordinator, selectedRange().length == 0 else {
            completion.dismiss()
            return
        }
        let cursor = selectedRange().location
        guard let result = CompletionEngine.complete(sql: string, cursor: cursor, catalog: coordinator.parent.catalog(),
                                                     explicit: explicit) else {
            completion.dismiss()
            return
        }
        completionRange = result.replacementRange
        let anchor = NSRange(location: result.replacementRange.lowerBound, length: 0)
        let rect = firstRect(forCharacterRange: anchor, actualRange: nil)
        completion.show(result.items, below: rect, parent: window) { [weak self] in
            self?.acceptCompletion()
        }
    }

    private func acceptCompletion() {
        guard let item = completion.selectedItem, let range = completionRange else {
            completion.dismiss()
            return
        }
        completion.dismiss()
        let nsRange = NSRange(location: range.lowerBound, length: range.count)
        guard NSMaxRange(nsRange) <= (string as NSString).length else { return }
        super.insertText(item.insertText, replacementRange: nsRange)
    }
}

// MARK: - Completion popup

@MainActor
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var panel: NSPanel?
    private var tableView: NSTableView?
    private var items: [CompletionItem] = []
    private var onAccept: (() -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    var selectedItem: CompletionItem? {
        guard let row = tableView?.selectedRow, row >= 0, row < items.count else { return nil }
        return items[row]
    }

    func show(_ items: [CompletionItem], below rect: NSRect, parent: NSWindow?, onAccept: @escaping () -> Void) {
        self.items = items
        self.onAccept = onAccept
        let panel = self.panel ?? makePanel()
        tableView?.reloadData()
        tableView?.selectRowIndexes([0], byExtendingSelection: false)
        tableView?.scrollRowToVisible(0)
        let height = min(CGFloat(items.count), 10) * 22 + 6
        panel.setFrame(NSRect(x: rect.minX - 24, y: rect.minY - height - 2, width: 360, height: height), display: true)
        if let parent, panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func move(_ delta: Int) {
        guard let tableView, !items.isEmpty else { return }
        let row = min(max(tableView.selectedRow + delta, 0), items.count - 1)
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    func dismiss() {
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu

        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 6
        effect.layer?.masksToBounds = true

        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 22
        table.backgroundColor = .clear
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.addTableColumn(NSTableColumn(identifier: .init("item")))
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: effect.topAnchor, constant: 3),
            scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -3),
        ])
        panel.contentView = effect
        self.panel = panel
        self.tableView = table
        return panel
    }

    @objc private func doubleClicked() { onAccept?() }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let identifier = NSUserInterfaceItemIdentifier("CompletionCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? CompletionCellView ?? CompletionCellView()
        cell.identifier = identifier
        cell.configure(item)
        return cell
    }
}

private final class CompletionCellView: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [icon, label, detail] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .right
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ item: CompletionItem) {
        let (symbol, color): (String, NSColor) = switch item.kind {
        case .keyword: ("textformat", .systemPink)
        case .table: ("tablecells", .systemBlue)
        case .column: ("line.3.horizontal", .systemGreen)
        case .function: ("function", .systemPurple)
        case .schema: ("folder", .systemOrange)
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = color
        label.stringValue = item.label
        detail.stringValue = item.detail ?? ""
    }
}

// MARK: - Line numbers

final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        NotificationCenter.default.addObserver(self, selector: #selector(invalidate),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        scrollView.contentView.postsBoundsChangedNotifications = true
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func invalidate() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        Theme.contentBackgroundNS.setFill()
        bounds.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: Theme.textTertiaryNS,
        ]
        let text = textView.string as NSString
        let visible = textView.visibleRect
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)

        var line = 1
        text.enumerateSubstrings(in: NSRange(location: 0, length: chars.location),
                                 options: [.byLines, .substringNotRequired]) { _, _, _, _ in line += 1 }
        if chars.location > 0, chars.location <= text.length,
           text.character(at: chars.location - 1) != 10 { line -= 1 }

        func draw(_ number: Int, y: CGFloat) {
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            let point = convert(NSPoint(x: 0, y: y), from: textView)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: point.y + 2), withAttributes: attributes)
        }

        var index = chars.location
        while index < NSMaxRange(chars) {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            draw(line, y: fragment.minY + textView.textContainerOrigin.y)
            line += 1
            index = NSMaxRange(lineRange)
        }
        // Trailing empty line after a final newline.
        if text.length == 0 || text.character(at: text.length - 1) == 10 {
            let extra = layoutManager.extraLineFragmentRect
            if !extra.isEmpty, extra.minY + textView.textContainerOrigin.y <= visible.maxY {
                draw(text.length == 0 ? 1 : line, y: extra.minY + textView.textContainerOrigin.y)
            }
        }
    }
}
