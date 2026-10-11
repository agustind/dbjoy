import DBCore
import Foundation

extension PostgresDialect {
    /// Compares two snapshots of the same schema and returns the changes that make `target` match
    /// `source`, each with its statements. Objects are matched by name; constraints and indexes that
    /// only differ in name count as the same.
    public func schemaChanges(from source: SchemaSnapshot, to target: SchemaSnapshot) -> [SchemaChange] {
        SchemaDiffer(dialect: self, source: source, target: target).changes()
    }
}

private struct SchemaDiffer {
    let dialect: PostgresDialect
    let source: SchemaSnapshot
    let target: SchemaSnapshot
    private var found: [SchemaChange] = []
    /// Serial sequences already created or dropped along with their table or column.
    private var handledSequences: Set<String> = []

    init(dialect: PostgresDialect, source: SchemaSnapshot, target: SchemaSnapshot) {
        self.dialect = dialect
        self.source = source
        self.target = target
    }

    private var schema: String { source.schema }

    func changes() -> [SchemaChange] {
        var differ = self
        differ.diffAll()
        return differ.found
    }

    private mutating func diffAll() {
        if source.exists, !target.exists {
            found.append(SchemaChange(id: "schema:\(schema)", kind: .added, objectType: "Schema", object: schema,
                                        summary: "Create the schema", steps: [MigrationStep(.createSchema, "CREATE SCHEMA \(q(schema));")]))
        }
        // Extensions are database-wide, so only the ones the source needs are added; extra ones stay.
        for name in source.extensions where !target.extensions.contains(name) {
            found.append(SchemaChange(id: "extension:\(name)", kind: .added, objectType: "Extension", object: name,
                                        summary: "Install the extension",
                                        steps: [MigrationStep(.createExtension, "CREATE EXTENSION IF NOT EXISTS \(q(name));")]))
        }
        diffEnums()
        diffDomains()
        diffTables()
        diffSequences()
        diffRoutines()
        diffViews()
        diffTriggers()
    }

    // MARK: Names

    private func q(_ identifier: String) -> String { dialect.quoteIdentifier(identifier) }
    private func name(_ object: String) -> String { q(schema) + "." + q(object) }
    private func lit(_ value: String) -> String { dialect.quoteLiteral(value) }

    // MARK: Types

    private mutating func diffEnums() {
        let targets = Dictionary(target.enums.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for type in source.enums {
            let create = "CREATE TYPE \(name(type.name)) AS ENUM (\(type.labels.map(lit).joined(separator: ", ")));"
            guard let existing = targets[type.name] else {
                found.append(SchemaChange(id: "enum:\(type.name)", kind: .added, objectType: "Type", object: type.name,
                                            summary: "Enum with \(type.labels.count) values", sourceDefinition: create,
                                            steps: [MigrationStep(.createType, create)]))
                continue
            }
            guard existing.labels != type.labels else { continue }
            var steps: [MigrationStep] = []
            var known = existing.labels
            for (index, label) in type.labels.enumerated() where !known.contains(label) {
                // Place the value after the nearest preceding one the target has, or before its first.
                let placement = type.labels[..<index].last(where: known.contains).map { " AFTER \(lit($0))" }
                    ?? known.first.map { " BEFORE \(lit($0))" } ?? ""
                steps.append(MigrationStep(.alterType, "ALTER TYPE \(name(type.name)) ADD VALUE \(lit(label))\(placement);"))
                known.append(label)
            }
            let extra = existing.labels.filter { !type.labels.contains($0) }
            var warnings: [String] = []
            if !extra.isEmpty {
                let values = extra.map { "'\($0)'" }.joined(separator: ", ")
                warnings.append("Postgres can't remove enum values, so \(values) \(extra.count == 1 ? "stays" : "stay") in the target.")
            }
            if steps.isEmpty, extra.isEmpty {
                warnings.append("Only the order of the values differs, which Postgres can't change in place.")
            }
            let added = type.labels.filter { !existing.labels.contains($0) }
            found.append(SchemaChange(
                id: "enum:\(type.name)", kind: .changed, objectType: "Type", object: type.name,
                summary: added.isEmpty ? "Values differ" : "Add " + added.map { "'\($0)'" }.joined(separator: ", "),
                warning: warnings.isEmpty ? nil : warnings.joined(separator: " "), sourceDefinition: create,
                targetDefinition: "CREATE TYPE \(name(existing.name)) AS ENUM (\(existing.labels.map(lit).joined(separator: ", ")));",
                steps: steps))
        }
        let sourceNames = Set(source.enums.map(\.name))
        for type in target.enums where !sourceNames.contains(type.name) {
            found.append(SchemaChange(id: "enum:\(type.name)", kind: .removed, objectType: "Type", object: type.name,
                                        summary: "Drop the enum",
                                        targetDefinition: "CREATE TYPE \(name(type.name)) AS ENUM (\(type.labels.map(lit).joined(separator: ", ")));",
                                        steps: [MigrationStep(.dropType, "DROP TYPE \(name(type.name));")]))
        }
    }

    private func domainDDL(_ domain: DomainSnapshot) -> String {
        var sql = "CREATE DOMAIN \(name(domain.name)) AS \(domain.baseType)"
        if let value = domain.defaultValue { sql += " DEFAULT \(value)" }
        if domain.isNotNull { sql += " NOT NULL" }
        for constraint in domain.constraints { sql += " CONSTRAINT \(q(constraint.name)) \(constraint.definition)" }
        return sql + ";"
    }

    private mutating func diffDomains() {
        let targets = Dictionary(target.domains.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for domain in source.domains {
            let ddl = domainDDL(domain)
            guard let existing = targets[domain.name] else {
                found.append(SchemaChange(id: "domain:\(domain.name)", kind: .added, objectType: "Domain", object: domain.name,
                                            summary: "Domain over \(domain.baseType)", sourceDefinition: ddl,
                                            steps: [MigrationStep(.createType, ddl)]))
                continue
            }
            guard existing != domain else { continue }
            let alter = "ALTER DOMAIN \(name(domain.name))"
            var steps: [MigrationStep] = []
            var notes: [String] = []
            var warning: String?
            if existing.baseType != domain.baseType {
                notes.append("base type \(existing.baseType) → \(domain.baseType)")
                warning = "Postgres can't change a domain's base type; recreate the domain and the columns that use it by hand."
            } else {
                if existing.defaultValue != domain.defaultValue {
                    notes.append("default changed")
                    steps.append(MigrationStep(.alterType, domain.defaultValue.map { "\(alter) SET DEFAULT \($0);" } ?? "\(alter) DROP DEFAULT;"))
                }
                if existing.isNotNull != domain.isNotNull {
                    notes.append(domain.isNotNull ? "NOT NULL added" : "NOT NULL removed")
                    steps.append(MigrationStep(.alterType, "\(alter) \(domain.isNotNull ? "SET" : "DROP") NOT NULL;"))
                }
                let targetChecks = Dictionary(existing.constraints.map { ($0.name, $0.definition) }, uniquingKeysWith: { a, _ in a })
                let sourceChecks = Dictionary(domain.constraints.map { ($0.name, $0.definition) }, uniquingKeysWith: { a, _ in a })
                for constraint in existing.constraints where sourceChecks[constraint.name] != constraint.definition {
                    steps.append(MigrationStep(.alterType, "\(alter) DROP CONSTRAINT \(q(constraint.name));"))
                }
                for constraint in domain.constraints where targetChecks[constraint.name] != constraint.definition {
                    steps.append(MigrationStep(.alterType, "\(alter) ADD CONSTRAINT \(q(constraint.name)) \(constraint.definition);"))
                }
                if sourceChecks != targetChecks { notes.append("checks changed") }
                if domain.isNotNull && !existing.isNotNull || sourceChecks != targetChecks {
                    warning = "Fails if existing values break the new rules."
                }
            }
            found.append(SchemaChange(id: "domain:\(domain.name)", kind: .changed, objectType: "Domain", object: domain.name,
                                        summary: notes.joined(separator: "; ").capitalizedFirst, warning: warning,
                                        sourceDefinition: ddl, targetDefinition: domainDDL(existing), steps: steps))
        }
        let sourceNames = Set(source.domains.map(\.name))
        for domain in target.domains where !sourceNames.contains(domain.name) {
            found.append(SchemaChange(id: "domain:\(domain.name)", kind: .removed, objectType: "Domain", object: domain.name,
                                        summary: "Drop the domain", targetDefinition: domainDDL(domain),
                                        steps: [MigrationStep(.dropType, "DROP DOMAIN \(name(domain.name));")]))
        }
    }

    // MARK: Sequences

    private func sequenceOptions(_ sequence: SequenceSnapshot) -> String {
        "AS \(sequence.dataType) INCREMENT BY \(sequence.increment) MINVALUE \(sequence.minValue) "
            + "MAXVALUE \(sequence.maxValue) START WITH \(sequence.start) CACHE \(sequence.cache)"
            + (sequence.cycles ? " CYCLE" : " NO CYCLE")
    }

    private func createSequenceSteps(_ sequence: SequenceSnapshot) -> [MigrationStep] {
        var steps = [MigrationStep(.createSequence, "CREATE SEQUENCE \(name(sequence.name)) \(sequenceOptions(sequence));")]
        if let table = sequence.ownedByTable, let column = sequence.ownedByColumn {
            steps.append(MigrationStep(.ownSequence, "ALTER SEQUENCE \(name(sequence.name)) OWNED BY \(name(table)).\(q(column));"))
        }
        return steps
    }

    /// Steps for the serial sequences a new table or column needs, if the target lacks them.
    private mutating func ownedSequenceSteps(table: String, column: String? = nil) -> [MigrationStep] {
        let targetNames = Set(target.sequences.map(\.name))
        var steps: [MigrationStep] = []
        for sequence in source.sequences where sequence.ownedByTable == table && (column == nil || sequence.ownedByColumn == column) {
            handledSequences.insert(sequence.name)
            if !targetNames.contains(sequence.name) { steps += createSequenceSteps(sequence) }
        }
        return steps
    }

    private mutating func diffSequences() {
        let targets = Dictionary(target.sequences.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for sequence in source.sequences where !handledSequences.contains(sequence.name) {
            guard let existing = targets[sequence.name] else {
                found.append(SchemaChange(id: "sequence:\(sequence.name)", kind: .added, objectType: "Sequence",
                                            object: sequence.name, summary: "Create the sequence",
                                            steps: createSequenceSteps(sequence)))
                continue
            }
            var steps: [MigrationStep] = []
            var withoutOwner = existing
            withoutOwner.ownedByTable = sequence.ownedByTable
            withoutOwner.ownedByColumn = sequence.ownedByColumn
            if withoutOwner != sequence {
                steps.append(MigrationStep(.createSequence, "ALTER SEQUENCE \(name(sequence.name)) \(sequenceOptions(sequence));"))
            }
            if existing.ownedByTable != sequence.ownedByTable || existing.ownedByColumn != sequence.ownedByColumn {
                let owner = sequence.ownedByTable.flatMap { table in sequence.ownedByColumn.map { "\(name(table)).\(q($0))" } } ?? "NONE"
                steps.append(MigrationStep(.ownSequence, "ALTER SEQUENCE \(name(sequence.name)) OWNED BY \(owner);"))
            }
            guard !steps.isEmpty else { continue }
            found.append(SchemaChange(id: "sequence:\(sequence.name)", kind: .changed, objectType: "Sequence",
                                        object: sequence.name, summary: "Options changed",
                                        sourceDefinition: "CREATE SEQUENCE \(name(sequence.name)) \(sequenceOptions(sequence));",
                                        targetDefinition: "CREATE SEQUENCE \(name(existing.name)) \(sequenceOptions(existing));",
                                        steps: steps))
        }
        let sourceNames = Set(source.sequences.map(\.name))
        for sequence in target.sequences where !sourceNames.contains(sequence.name) && !handledSequences.contains(sequence.name) {
            found.append(SchemaChange(id: "sequence:\(sequence.name)", kind: .removed, objectType: "Sequence",
                                        object: sequence.name, summary: "Drop the sequence",
                                        steps: [MigrationStep(.dropSequence, "DROP SEQUENCE IF EXISTS \(name(sequence.name));")]))
        }
    }

    // MARK: Tables

    private func columnDDL(_ column: ColumnInfo) -> String {
        var line = "\(q(column.name)) \(column.dataType)"
        if let value = column.defaultValue {
            line += value.hasPrefix("GENERATED ") ? " \(value)" : " DEFAULT \(value)"
        }
        if !column.isNullable, !column.isIdentity { line += " NOT NULL" }
        return line
    }

    private func isForeignKey(_ constraint: ConstraintInfo) -> Bool { constraint.type == .foreignKey }

    private func addConstraint(_ constraint: ConstraintInfo, table: String) -> MigrationStep {
        MigrationStep(isForeignKey(constraint) ? .addForeignKey : .addConstraint,
                      "ALTER TABLE \(name(table)) ADD CONSTRAINT \(q(constraint.name)) \(constraint.definition);")
    }

    private func dropConstraint(_ constraint: ConstraintInfo, table: String) -> MigrationStep {
        MigrationStep(isForeignKey(constraint) ? .dropForeignKey : .dropConstraint,
                      "ALTER TABLE \(name(table)) DROP CONSTRAINT \(q(constraint.name));")
    }

    private func commentSQL(on object: String, _ comment: String?) -> String {
        "COMMENT ON \(object) IS \(comment.map(lit) ?? "NULL");"
    }

    /// CREATE TABLE with its non-foreign-key constraints, then foreign keys, indexes and comments.
    private func createTableSteps(_ table: TableStructure) -> [MigrationStep] {
        let tableName = table.ref.name
        var lines = table.columns.map { "  " + columnDDL($0) }
        lines += table.constraints.filter { !isForeignKey($0) }.map { "  CONSTRAINT \(q($0.name)) \($0.definition)" }
        var steps = [MigrationStep(.createTable, "CREATE TABLE \(name(tableName)) (\n\(lines.joined(separator: ",\n"))\n);")]
        steps += table.constraints.filter(isForeignKey).map { addConstraint($0, table: tableName) }
        steps += table.indexes.filter { $0.constraintName == nil }.map { MigrationStep(.createIndex, $0.definition + ";") }
        if let comment = table.comment {
            steps.append(MigrationStep(.comment, commentSQL(on: "TABLE \(name(tableName))", comment)))
        }
        for column in table.columns where column.comment != nil {
            steps.append(MigrationStep(.comment, commentSQL(on: "COLUMN \(name(tableName)).\(q(column.name))", column.comment)))
        }
        return steps
    }

    private func tableDDL(_ table: TableStructure) -> String {
        createTableSteps(table).map(\.sql).joined(separator: "\n")
    }

    private mutating func diffTables() {
        let targets = Dictionary(target.tables.map { ($0.ref.name, $0) }, uniquingKeysWith: { a, _ in a })
        for table in source.tables {
            guard let existing = targets[table.ref.name] else {
                var steps = ownedSequenceSteps(table: table.ref.name)
                steps += createTableSteps(table)
                steps += source.triggers.filter { $0.table == table.ref.name }.map { MigrationStep(.createTrigger, $0.definition + ";") }
                found.append(SchemaChange(id: "table:\(table.ref.name)", kind: .added, objectType: "Table", object: table.ref.name,
                                            summary: "\(table.columns.count) column\(table.columns.count == 1 ? "" : "s")",
                                            sourceDefinition: tableDDL(table), steps: steps))
                continue
            }
            diffColumns(table, existing)
            diffConstraints(table, existing)
            diffIndexes(table, existing)
            if table.comment != existing.comment {
                found.append(SchemaChange(id: "table:\(table.ref.name)/comment", kind: .changed, objectType: "Comment",
                                            object: table.ref.name, summary: "Table comment changed",
                                            sourceDefinition: table.comment, targetDefinition: existing.comment,
                                            steps: [MigrationStep(.comment, commentSQL(on: "TABLE \(name(table.ref.name))", table.comment))]))
            }
        }
        let sourceNames = Set(source.tables.map(\.ref.name))
        for table in target.tables where !sourceNames.contains(table.ref.name) {
            // Serial sequences go with the table.
            for sequence in target.sequences where sequence.ownedByTable == table.ref.name { handledSequences.insert(sequence.name) }
            found.append(SchemaChange(id: "table:\(table.ref.name)", kind: .removed, objectType: "Table", object: table.ref.name,
                                        summary: "Drop the table and its rows", isDestructive: true,
                                        targetDefinition: tableDDL(table),
                                        // Its foreign keys go first, in case it references another dropped table.
                                        steps: table.constraints.filter(isForeignKey).map { dropConstraint($0, table: table.ref.name) }
                                            + [MigrationStep(.dropTable, "DROP TABLE \(name(table.ref.name));")]))
        }
    }

    private enum DefaultKind: Equatable {
        case none
        case value(String)
        case identity(always: Bool)
        case generated(String)

        init(_ value: String?) {
            switch value {
            case nil: self = .none
            case "GENERATED ALWAYS AS IDENTITY": self = .identity(always: true)
            case "GENERATED BY DEFAULT AS IDENTITY": self = .identity(always: false)
            case let value? where value.hasPrefix("GENERATED ALWAYS AS ("): self = .generated(value)
            case let value?: self = .value(value)
            }
        }

        var isGenerated: Bool { if case .generated = self { true } else { false } }
    }

    private mutating func diffColumns(_ table: TableStructure, _ existing: TableStructure) {
        let tableName = name(table.ref.name)
        let targets = Dictionary(existing.columns.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for column in table.columns {
            let id = "table:\(table.ref.name)/column:\(column.name)"
            let object = "\(table.ref.name).\(column.name)"
            let addColumn = MigrationStep(.alterColumn, "ALTER TABLE \(tableName) ADD COLUMN \(columnDDL(column));")
            let comment = column.comment.map { MigrationStep(.comment, commentSQL(on: "COLUMN \(tableName).\(q(column.name))", $0)) }
            guard let current = targets[column.name] else {
                let needsValue = !column.isNullable && column.defaultValue == nil
                found.append(SchemaChange(id: id, kind: .added, objectType: "Column", object: object, summary: column.dataType,
                                            warning: needsValue ? "Fails if the table has rows: the column is NOT NULL with no default." : nil,
                                            sourceDefinition: columnDDL(column),
                                            steps: ownedSequenceSteps(table: table.ref.name, column: column.name) + [addColumn] + (comment.map { [$0] } ?? [])))
                continue
            }
            let alter = "ALTER TABLE \(tableName) ALTER COLUMN \(q(column.name))"
            let wanted = DefaultKind(column.defaultValue), have = DefaultKind(current.defaultValue)
            var steps: [MigrationStep] = []
            var notes: [String] = []
            var warnings: [String] = []
            var isDestructive = false

            if wanted != have, wanted.isGenerated || have.isGenerated {
                // A generated column's expression can't be altered in place: rebuild the column.
                notes.append(wanted.isGenerated ? (have.isGenerated ? "generated expression changed" : "becomes generated")
                                                : "no longer generated")
                isDestructive = !have.isGenerated
                if isDestructive { warnings.append("The column is dropped and recreated, so its values are lost.") }
                steps = [MigrationStep(.dropColumn, "ALTER TABLE \(tableName) DROP COLUMN \(q(column.name));"), addColumn]
                if let comment { steps.append(comment) }
            } else {
                if column.dataType != current.dataType {
                    notes.append("type \(current.dataType) → \(column.dataType)")
                    warnings.append("Existing values are converted to \(column.dataType); fails if one can't be.")
                    steps.append(MigrationStep(.alterColumn, "\(alter) TYPE \(column.dataType) USING \(q(column.name))::\(column.dataType);"))
                }
                if column.isNullable != current.isNullable {
                    notes.append(column.isNullable ? "NOT NULL removed" : "NOT NULL added")
                    if !column.isNullable { warnings.append("Fails if any row has NULL in this column.") }
                    steps.append(MigrationStep(.alterColumn, "\(alter) \(column.isNullable ? "DROP" : "SET") NOT NULL;"))
                }
                if wanted != have {
                    switch (have, wanted) {
                    case (.identity, .identity(let always)):
                        notes.append("identity changed")
                        steps.append(MigrationStep(.alterColumn, "\(alter) SET GENERATED \(always ? "ALWAYS" : "BY DEFAULT");"))
                    case (_, .identity(let always)):
                        notes.append("becomes an identity column")
                        if case .value = have { steps.append(MigrationStep(.alterColumn, "\(alter) DROP DEFAULT;")) }
                        steps.append(MigrationStep(.alterColumn, "\(alter) ADD GENERATED \(always ? "ALWAYS" : "BY DEFAULT") AS IDENTITY;"))
                    case (.identity, _):
                        notes.append("no longer an identity column")
                        steps.append(MigrationStep(.alterColumn, "\(alter) DROP IDENTITY IF EXISTS;"))
                        if case .value(let value) = wanted { steps.append(MigrationStep(.alterColumn, "\(alter) SET DEFAULT \(value);")) }
                    case (_, .value(let value)):
                        notes.append("default \(current.defaultValue ?? "none") → \(value)")
                        steps.append(MigrationStep(.alterColumn, "\(alter) SET DEFAULT \(value);"))
                    default:
                        notes.append("default removed")
                        steps.append(MigrationStep(.alterColumn, "\(alter) DROP DEFAULT;"))
                    }
                }
                if column.comment != current.comment {
                    notes.append("comment changed")
                    steps.append(MigrationStep(.comment, commentSQL(on: "COLUMN \(tableName).\(q(column.name))", column.comment)))
                }
            }
            guard !steps.isEmpty else { continue }
            // Views reading the column block changing its type or dropping it.
            if column.dataType != current.dataType || steps.contains(where: { $0.phase == .dropColumn }) {
                let views = targetViews(readingFrom: table.ref.name, column: column.name)
                steps += rebuild(views)
                if let warning = rebuildWarning(views) { warnings.append(warning) }
            }
            found.append(SchemaChange(id: id, kind: .changed, objectType: "Column", object: object,
                                        summary: notes.joined(separator: "; ").capitalizedFirst, isDestructive: isDestructive,
                                        warning: warnings.isEmpty ? nil : warnings.joined(separator: " "),
                                        sourceDefinition: columnDDL(column), targetDefinition: columnDDL(current), steps: steps))
        }
        let sourceNames = Set(table.columns.map(\.name))
        for column in existing.columns where !sourceNames.contains(column.name) {
            for sequence in target.sequences where sequence.ownedByTable == table.ref.name && sequence.ownedByColumn == column.name {
                handledSequences.insert(sequence.name)
            }
            let views = targetViews(readingFrom: table.ref.name, column: column.name)
            found.append(SchemaChange(id: "table:\(table.ref.name)/column:\(column.name)", kind: .removed, objectType: "Column",
                                        object: "\(table.ref.name).\(column.name)", summary: "Drop the column and its values",
                                        isDestructive: true, warning: rebuildWarning(views), targetDefinition: columnDDL(column),
                                        steps: [MigrationStep(.dropColumn, "ALTER TABLE \(tableName) DROP COLUMN \(q(column.name));")]
                                            + rebuild(views)))
        }
    }

    /// Pairs objects by name, or failing that by identical definition (the same thing under another name).
    private func match<T>(_ sources: [T], _ targets: [T], name: (T) -> String, key: (T) -> String)
        -> (added: [T], removed: [T], changed: [(T, T)]) {
        var unmatched = targets
        var added: [T] = [], changed: [(T, T)] = []
        var pending: [T] = []
        for item in sources {
            if let index = unmatched.firstIndex(where: { name($0) == name(item) }) {
                let other = unmatched.remove(at: index)
                if key(other) != key(item) { changed.append((item, other)) }
            } else {
                pending.append(item)
            }
        }
        // Whatever is left in `unmatched` has a name no source object uses.
        for item in pending {
            if let index = unmatched.firstIndex(where: { key($0) == key(item) }) {
                unmatched.remove(at: index)
            } else {
                added.append(item)
            }
        }
        return (added, unmatched, changed)
    }

    private mutating func diffConstraints(_ table: TableStructure, _ existing: TableStructure) {
        let tableName = table.ref.name
        let result = match(table.constraints, existing.constraints, name: \.name, key: \.definition)
        func id(_ constraint: ConstraintInfo) -> String { "table:\(tableName)/constraint:\(constraint.name)" }
        func label(_ constraint: ConstraintInfo) -> String { constraint.type.displayName.lowercased().capitalizedFirst }
        let validates = "Fails if existing rows break it."
        for constraint in result.added {
            found.append(SchemaChange(id: id(constraint), kind: .added, objectType: "Constraint", object: "\(tableName).\(constraint.name)",
                                        summary: label(constraint), warning: validates, sourceDefinition: constraint.definition,
                                        steps: [addConstraint(constraint, table: tableName)]))
        }
        for (constraint, current) in result.changed {
            found.append(SchemaChange(id: id(constraint), kind: .changed, objectType: "Constraint", object: "\(tableName).\(constraint.name)",
                                        summary: "\(label(constraint)) definition changed", warning: validates,
                                        sourceDefinition: constraint.definition, targetDefinition: current.definition,
                                        steps: [dropConstraint(current, table: tableName), addConstraint(constraint, table: tableName)]))
        }
        for constraint in result.removed {
            found.append(SchemaChange(id: id(constraint), kind: .removed, objectType: "Constraint", object: "\(tableName).\(constraint.name)",
                                        summary: "Drop the \(constraint.type.displayName.lowercased()) constraint",
                                        targetDefinition: constraint.definition, steps: [dropConstraint(constraint, table: tableName)]))
        }
    }

    /// An index definition without its name, to recognize the same index under another name.
    private static func indexKey(_ definition: String) -> String {
        guard let range = definition.range(of: #"INDEX ("([^"]|"")*"|\S+) ON "#, options: .regularExpression) else { return definition }
        return definition.replacingCharacters(in: range, with: "INDEX ON ")
    }

    private mutating func diffIndexes(_ table: TableStructure, _ existing: TableStructure) {
        let tableName = table.ref.name
        let result = match(table.indexes.filter { $0.constraintName == nil }, existing.indexes.filter { $0.constraintName == nil },
                           name: \.name, key: { Self.indexKey($0.definition) })
        func id(_ index: IndexInfo) -> String { "table:\(tableName)/index:\(index.name)" }
        func drop(_ index: IndexInfo) -> MigrationStep { MigrationStep(.dropIndex, "DROP INDEX \(name(index.name));") }
        for index in result.added {
            found.append(SchemaChange(id: id(index), kind: .added, objectType: "Index", object: "\(tableName).\(index.name)",
                                        summary: (index.isUnique ? "Unique " : "") + "\(index.method) on \(index.columns.joined(separator: ", "))",
                                        warning: index.isUnique ? "Fails if existing rows have duplicates." : nil,
                                        sourceDefinition: index.definition, steps: [MigrationStep(.createIndex, index.definition + ";")]))
        }
        for (index, current) in result.changed {
            found.append(SchemaChange(id: id(index), kind: .changed, objectType: "Index", object: "\(tableName).\(index.name)",
                                        summary: "Definition changed", sourceDefinition: index.definition,
                                        targetDefinition: current.definition,
                                        steps: [drop(current), MigrationStep(.createIndex, index.definition + ";")]))
        }
        for index in result.removed {
            found.append(SchemaChange(id: id(index), kind: .removed, objectType: "Index", object: "\(tableName).\(index.name)",
                                        summary: "Drop the index", targetDefinition: index.definition, steps: [drop(index)]))
        }
    }

    // MARK: Routines, views and triggers

    private mutating func diffRoutines() {
        func ddl(_ routine: RoutineSnapshot) -> String {
            let text = routine.definition.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.hasSuffix(";") ? text : text + ";"
        }
        func kind(_ routine: RoutineSnapshot) -> String { routine.isProcedure ? "Procedure" : "Function" }
        let targets = Dictionary(target.routines.map { ($0.signature, $0) }, uniquingKeysWith: { a, _ in a })
        for routine in source.routines {
            let id = "routine:\(routine.signature)"
            if let existing = targets[routine.signature] {
                guard existing.definition != routine.definition else { continue }
                found.append(SchemaChange(id: id, kind: .changed, objectType: kind(routine), object: routine.signature,
                                            summary: "Definition changed", sourceDefinition: ddl(routine),
                                            targetDefinition: ddl(existing), steps: [MigrationStep(.createRoutine, ddl(routine))]))
            } else {
                found.append(SchemaChange(id: id, kind: .added, objectType: kind(routine), object: routine.signature,
                                            summary: "Create the \(kind(routine).lowercased())", sourceDefinition: ddl(routine),
                                            steps: [MigrationStep(.createRoutine, ddl(routine))]))
            }
        }
        let sourceSignatures = Set(source.routines.map(\.signature))
        for routine in target.routines where !sourceSignatures.contains(routine.signature) {
            let drop = "DROP \(routine.isProcedure ? "PROCEDURE" : "FUNCTION") \(name(routine.name))(\(routine.arguments));"
            found.append(SchemaChange(id: "routine:\(routine.signature)", kind: .removed, objectType: kind(routine),
                                        object: routine.signature, summary: "Drop the \(kind(routine).lowercased())",
                                        targetDefinition: ddl(routine), steps: [MigrationStep(.dropRoutine, drop)]))
        }
    }

    /// Views in an order where each comes after the views it reads from.
    private static func dependencyOrder(_ views: [ViewSnapshot]) -> [ViewSnapshot] {
        let byName = Dictionary(views.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var ordered: [ViewSnapshot] = [], visited: Set<String> = []
        func visit(_ view: ViewSnapshot) {
            guard visited.insert(view.name).inserted else { return }
            for dependency in view.dependsOn { if let other = byName[dependency] { visit(other) } }
            ordered.append(view)
        }
        views.forEach(visit)
        return ordered
    }

    private func viewBody(_ view: ViewSnapshot) -> String {
        var body = view.definition.trimmingCharacters(in: .whitespacesAndNewlines)
        while body.hasSuffix(";") { body = String(body.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
        return body
    }

    private func viewKeyword(_ view: ViewSnapshot) -> String { view.isMaterialized ? "MATERIALIZED VIEW" : "VIEW" }

    private func createView(_ view: ViewSnapshot, replace: Bool = false) -> String {
        "CREATE \(replace ? "OR REPLACE " : "")\(viewKeyword(view)) \(name(view.name)) AS\n\(viewBody(view));"
    }

    /// Drops come in reverse dependency order (readers first), creates in dependency order.
    private func dropViewStep(_ view: ViewSnapshot) -> MigrationStep {
        let rank = Self.dependencyOrder(target.views).firstIndex { $0.name == view.name } ?? 0
        return MigrationStep(.dropView, "DROP \(viewKeyword(view)) IF EXISTS \(name(view.name));", rank: -rank)
    }

    private func createViewSteps(_ view: ViewSnapshot, replace: Bool = false) -> [MigrationStep] {
        let rank = Self.dependencyOrder(source.views).firstIndex { $0.name == view.name } ?? 0
        var steps = [MigrationStep(.createView, createView(view, replace: replace), rank: rank)]
        if let comment = view.comment {
            steps.append(MigrationStep(.comment, commentSQL(on: "\(viewKeyword(view)) \(name(view.name))", comment)))
        }
        return steps
    }

    /// Target views that read `column` of `table` (any column when nil), directly or through other views.
    private func targetViews(readingFrom table: String, column: String? = nil) -> [ViewSnapshot] {
        var result: [ViewSnapshot] = [], seen: Set<String> = []
        var queue = target.views.filter { view in
            column.map { view.usesColumns.contains("\(table).\($0)") } ?? view.dependsOn.contains(table)
        }
        while !queue.isEmpty {
            let view = queue.removeFirst()
            guard seen.insert(view.name).inserted else { continue }
            result.append(view)
            queue += target.views.filter { $0.dependsOn.contains(view.name) }
        }
        return result
    }

    /// Steps that drop views in the way of a change and recreate them, as the source defines them, afterwards.
    private func rebuild(_ views: [ViewSnapshot]) -> [MigrationStep] {
        let wanted = Dictionary(source.views.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        return views.flatMap { view in [dropViewStep(view)] + (wanted[view.name].map { createViewSteps($0) } ?? []) }
    }

    private func rebuildWarning(_ views: [ViewSnapshot]) -> String? {
        guard !views.isEmpty else { return nil }
        let names = views.map(\.name).joined(separator: ", ")
        return views.count == 1
            ? "Drops and recreates the view \(names); grant privileges on it again if needed."
            : "Drops and recreates the views \(names); grant privileges on them again if needed."
    }

    private mutating func diffViews() {
        let targets = Dictionary(target.views.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for view in Self.dependencyOrder(source.views) {
            let type = view.isMaterialized ? "Materialized View" : "View"
            guard let existing = targets[view.name] else {
                found.append(SchemaChange(id: "view:\(view.name)", kind: .added, objectType: type, object: view.name,
                                          summary: "Create the \(type.lowercased())", sourceDefinition: createView(view),
                                          steps: createViewSteps(view)))
                continue
            }
            var steps: [MigrationStep] = []
            var notes: [String] = []
            var warning: String?
            if viewBody(existing) != viewBody(view) || existing.isMaterialized != view.isMaterialized {
                notes.append("definition changed")
                // A plain view can be replaced in place while it keeps its columns and only adds new ones at the end.
                let keepsColumns = existing.columns.count <= view.columns.count
                    && Array(view.columns.prefix(existing.columns.count)) == existing.columns
                if !view.isMaterialized, !existing.isMaterialized, keepsColumns {
                    steps.append(MigrationStep(.createView, createView(view, replace: true),
                                               rank: Self.dependencyOrder(source.views).firstIndex { $0.name == view.name } ?? 0))
                } else {
                    let rebuilt = [existing] + targetViews(readingFrom: existing.name)
                    steps += rebuild(rebuilt)
                    warning = rebuildWarning(rebuilt)
                }
            }
            if view.comment != existing.comment, !steps.contains(where: { $0.phase == .comment }) {
                notes.append("comment changed")
                steps.append(MigrationStep(.comment, commentSQL(on: "\(viewKeyword(view)) \(name(view.name))", view.comment)))
            }
            guard !steps.isEmpty else { continue }
            found.append(SchemaChange(id: "view:\(view.name)", kind: .changed, objectType: type, object: view.name,
                                      summary: notes.joined(separator: "; ").capitalizedFirst, warning: warning,
                                      sourceDefinition: createView(view), targetDefinition: createView(existing), steps: steps))
        }
        let sourceNames = Set(source.views.map(\.name))
        for view in target.views where !sourceNames.contains(view.name) {
            found.append(SchemaChange(id: "view:\(view.name)", kind: .removed, objectType: view.isMaterialized ? "Materialized View" : "View",
                                      object: view.name, summary: "Drop the \(viewKeyword(view).lowercased())",
                                      targetDefinition: createView(view), steps: [dropViewStep(view)]))
        }
    }

    private mutating func diffTriggers() {
        // Triggers of new tables were created with the table, and dropped tables take theirs along.
        let targetTables = Set(target.tables.map(\.ref.name)), sourceTables = Set(source.tables.map(\.ref.name))
        let sourceTriggers = source.triggers.filter { !sourceTables.contains($0.table) || targetTables.contains($0.table) }
        let targetTriggers = target.triggers.filter { !targetTables.contains($0.table) || sourceTables.contains($0.table) }
        func key(_ trigger: TriggerSnapshot) -> String { "\(trigger.table).\(trigger.name)" }
        func create(_ trigger: TriggerSnapshot) -> MigrationStep { MigrationStep(.createTrigger, trigger.definition + ";") }
        func drop(_ trigger: TriggerSnapshot) -> MigrationStep {
            MigrationStep(.dropTrigger, "DROP TRIGGER \(q(trigger.name)) ON \(name(trigger.table));")
        }
        let targets = Dictionary(targetTriggers.map { (key($0), $0) }, uniquingKeysWith: { a, _ in a })
        for trigger in sourceTriggers {
            if let existing = targets[key(trigger)] {
                guard existing.definition != trigger.definition else { continue }
                found.append(SchemaChange(id: "trigger:\(key(trigger))", kind: .changed, objectType: "Trigger", object: key(trigger),
                                            summary: "Definition changed", sourceDefinition: trigger.definition + ";",
                                            targetDefinition: existing.definition + ";", steps: [drop(existing), create(trigger)]))
            } else {
                found.append(SchemaChange(id: "trigger:\(key(trigger))", kind: .added, objectType: "Trigger", object: key(trigger),
                                            summary: "Create the trigger", sourceDefinition: trigger.definition + ";",
                                            steps: [create(trigger)]))
            }
        }
        let sourceKeys = Set(sourceTriggers.map(key))
        for trigger in targetTriggers where !sourceKeys.contains(key(trigger)) {
            found.append(SchemaChange(id: "trigger:\(key(trigger))", kind: .removed, objectType: "Trigger", object: key(trigger),
                                        summary: "Drop the trigger", targetDefinition: trigger.definition + ";", steps: [drop(trigger)]))
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
