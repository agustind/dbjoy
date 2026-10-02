import DBCore
import Foundation
import Observation

struct DiagramNode: Identifiable {
    var id: String { name }
    var name: String
    var kind: ObjectKind
    var columns: [ColumnInfo]
    var foreignKeyColumns: Set<String>
    var position: CGPoint

    static let width: CGFloat = 230
    static let headerHeight: CGFloat = 30
    static let rowHeight: CGFloat = 20

    var size: CGSize {
        CGSize(width: Self.width, height: Self.headerHeight + CGFloat(columns.count) * Self.rowHeight + 8)
    }

    var frame: CGRect { CGRect(origin: position, size: size) }

    /// Vertical center of a column row, in diagram coordinates.
    func anchorY(for column: String) -> CGFloat {
        let index = columns.firstIndex { $0.name == column } ?? 0
        return position.y + Self.headerHeight + (CGFloat(index) + 0.5) * Self.rowHeight
    }
}

/// Entity-relationship diagram of the tables in one schema.
@MainActor @Observable
final class DiagramModel: Identifiable {
    let id = UUID()
    let schema: String
    @ObservationIgnored weak var workspace: WorkspaceModel?
    var nodes: [DiagramNode] = []
    var edges: [ForeignKeyInfo] = []
    var isLoading = false
    var error: String?
    var zoom: CGFloat = 1
    var selectedNode: String?
    var includeViews = false

    init(workspace: WorkspaceModel, schema: String) {
        self.workspace = workspace
        self.schema = schema
    }

    var canvasSize: CGSize {
        let maxX = nodes.map { $0.frame.maxX }.max() ?? 0
        let maxY = nodes.map { $0.frame.maxY }.max() ?? 0
        return CGSize(width: maxX + 80, height: maxY + 80)
    }

    func node(named name: String) -> DiagramNode? {
        nodes.first { $0.name == name }
    }

    func load() async {
        guard let connection = workspace?.connection else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let objects = try await connection.listObjects(schema: schema)
            let columns = try await connection.columnsByTable(schema: schema)
            let foreignKeys = try await connection.foreignKeys(schema: schema)
                .filter { $0.referencedTable.schema == schema }
            let kinds: Set<ObjectKind> = includeViews ? [.table, .view, .materializedView, .foreignTable] : [.table, .foreignTable]
            let tables = objects.filter { kinds.contains($0.kind) }
            edges = foreignKeys
            nodes = Self.layout(tables: tables, columns: columns, foreignKeys: foreignKeys)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func move(_ name: String, by delta: CGSize) {
        guard let index = nodes.firstIndex(where: { $0.name == name }) else { return }
        nodes[index].position.x = max(0, nodes[index].position.x + delta.width)
        nodes[index].position.y = max(0, nodes[index].position.y + delta.height)
    }

    /// Layered layout: referenced tables to the left, referencing tables to the right.
    /// Tables without relationships are placed in a grid after the connected ones.
    static func layout(tables: [SchemaObject], columns: [String: [ColumnInfo]], foreignKeys: [ForeignKeyInfo]) -> [DiagramNode] {
        let names = Set(tables.map(\.name))
        var references: [String: Set<String>] = [:]
        var connected = Set<String>()
        for fk in foreignKeys where names.contains(fk.table.name) && names.contains(fk.referencedTable.name) {
            if fk.table.name != fk.referencedTable.name {
                references[fk.table.name, default: []].insert(fk.referencedTable.name)
            }
            connected.insert(fk.table.name)
            connected.insert(fk.referencedTable.name)
        }

        var levels: [String: Int] = [:]
        func level(_ name: String, visiting: Set<String>) -> Int {
            if let known = levels[name] { return known }
            guard !visiting.contains(name) else { return 0 }
            let value = (references[name] ?? []).map { level($0, visiting: visiting.union([name])) + 1 }.max() ?? 0
            levels[name] = value
            return value
        }

        let fkColumns = Dictionary(grouping: foreignKeys, by: { $0.table.name }).mapValues { Set($0.flatMap(\.columns)) }
        func makeNode(_ object: SchemaObject, at point: CGPoint) -> DiagramNode {
            DiagramNode(name: object.name, kind: object.kind, columns: columns[object.name] ?? [],
                        foreignKeyColumns: fkColumns[object.name] ?? [], position: point)
        }

        let columnGap: CGFloat = 110
        let rowGap: CGFloat = 40
        let maxColumnHeight: CGFloat = 1600
        var nodes: [DiagramNode] = []
        var x: CGFloat = 40

        let connectedTables = tables.filter { connected.contains($0.name) }
        let byLevel = Dictionary(grouping: connectedTables) { level($0.name, visiting: []) }
        for levelIndex in byLevel.keys.sorted() {
            // Most-connected tables first so hubs sit near the top.
            let members = byLevel[levelIndex]!.sorted {
                (references[$0.name]?.count ?? 0) > (references[$1.name]?.count ?? 0)
            }
            var y: CGFloat = 40
            for object in members {
                var node = makeNode(object, at: CGPoint(x: x, y: y))
                if y > 40, y + node.size.height > maxColumnHeight {
                    x += DiagramNode.width + columnGap / 2
                    y = 40
                    node.position = CGPoint(x: x, y: y)
                }
                nodes.append(node)
                y += node.size.height + rowGap
            }
            x += DiagramNode.width + columnGap
        }

        // Unrelated tables in a grid.
        let isolated = tables.filter { !connected.contains($0.name) }
        let perRow = 4
        let gridX = x
        var y: CGFloat = 40
        for start in stride(from: 0, to: isolated.count, by: perRow) {
            var rowHeight: CGFloat = 0
            for (offset, object) in isolated[start..<min(start + perRow, isolated.count)].enumerated() {
                let node = makeNode(object, at: CGPoint(x: gridX + CGFloat(offset) * (DiagramNode.width + 40), y: y))
                rowHeight = max(rowHeight, node.size.height)
                nodes.append(node)
            }
            y += rowHeight + rowGap
        }
        return nodes
    }
}
