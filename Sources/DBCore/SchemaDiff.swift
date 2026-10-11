import Foundation

// MARK: - Snapshot

/// Everything schema compare looks at in one schema of one database, read in a few bulk queries.
public struct SchemaSnapshot: Sendable {
    public var schema: String
    /// False when the schema doesn't exist in this database; the other fields are then empty.
    public var exists: Bool
    /// Extensions installed in the database (not just the schema), since tables often depend on them.
    public var extensions: [String]
    public var tables: [TableStructure]
    public var views: [ViewSnapshot]
    public var routines: [RoutineSnapshot]
    public var enums: [EnumSnapshot]
    public var domains: [DomainSnapshot]
    public var sequences: [SequenceSnapshot]
    public var triggers: [TriggerSnapshot]

    public init(schema: String, exists: Bool = true, extensions: [String] = [], tables: [TableStructure] = [],
                views: [ViewSnapshot] = [], routines: [RoutineSnapshot] = [], enums: [EnumSnapshot] = [],
                domains: [DomainSnapshot] = [], sequences: [SequenceSnapshot] = [], triggers: [TriggerSnapshot] = []) {
        self.schema = schema
        self.exists = exists
        self.extensions = extensions
        self.tables = tables
        self.views = views
        self.routines = routines
        self.enums = enums
        self.domains = domains
        self.sequences = sequences
        self.triggers = triggers
    }
}

public struct ViewSnapshot: Hashable, Sendable {
    public var name: String
    public var isMaterialized: Bool
    /// The view's query.
    public var definition: String
    /// Output columns as "name type", to tell whether the view can be replaced in place.
    public var columns: [String]
    /// Tables and views in the same schema it selects from, so it's created after them.
    public var dependsOn: [String]
    /// The columns it reads, as "table.column", so it can be rebuilt around changes to them.
    public var usesColumns: [String]
    public var comment: String?

    public init(name: String, isMaterialized: Bool, definition: String, columns: [String] = [], dependsOn: [String] = [],
                usesColumns: [String] = [], comment: String? = nil) {
        self.name = name
        self.isMaterialized = isMaterialized
        self.definition = definition
        self.columns = columns
        self.dependsOn = dependsOn
        self.usesColumns = usesColumns
        self.comment = comment
    }
}

public struct RoutineSnapshot: Hashable, Sendable {
    public var name: String
    /// Identity arguments, which tell overloads apart.
    public var arguments: String
    public var isProcedure: Bool
    /// The complete `CREATE OR REPLACE …` statement.
    public var definition: String

    public init(name: String, arguments: String, isProcedure: Bool, definition: String) {
        self.name = name
        self.arguments = arguments
        self.isProcedure = isProcedure
        self.definition = definition
    }

    public var signature: String { "\(name)(\(arguments))" }
}

public struct EnumSnapshot: Hashable, Sendable {
    public var name: String
    public var labels: [String]

    public init(name: String, labels: [String]) {
        self.name = name
        self.labels = labels
    }
}

public struct DomainSnapshot: Hashable, Sendable {
    public var name: String
    public var baseType: String
    public var defaultValue: String?
    public var isNotNull: Bool
    public var constraints: [ConstraintInfo]

    public init(name: String, baseType: String, defaultValue: String? = nil, isNotNull: Bool = false,
                constraints: [ConstraintInfo] = []) {
        self.name = name
        self.baseType = baseType
        self.defaultValue = defaultValue
        self.isNotNull = isNotNull
        self.constraints = constraints
    }
}

public struct SequenceSnapshot: Hashable, Sendable {
    public var name: String
    public var dataType: String
    public var start: String
    public var increment: String
    public var minValue: String
    public var maxValue: String
    public var cache: String
    public var cycles: Bool
    /// The column that owns the sequence (serial columns), dropped along with it.
    public var ownedByTable: String?
    public var ownedByColumn: String?

    public init(name: String, dataType: String = "bigint", start: String = "1", increment: String = "1",
                minValue: String = "1", maxValue: String = "9223372036854775807", cache: String = "1",
                cycles: Bool = false, ownedByTable: String? = nil, ownedByColumn: String? = nil) {
        self.name = name
        self.dataType = dataType
        self.start = start
        self.increment = increment
        self.minValue = minValue
        self.maxValue = maxValue
        self.cache = cache
        self.cycles = cycles
        self.ownedByTable = ownedByTable
        self.ownedByColumn = ownedByColumn
    }
}

public struct TriggerSnapshot: Hashable, Sendable {
    public var table: String
    public var name: String
    /// The complete `CREATE TRIGGER …` statement.
    public var definition: String

    public init(table: String, name: String, definition: String) {
        self.table = table
        self.name = name
        self.definition = definition
    }
}

// MARK: - Changes

/// Where a statement goes in a migration script. Drops come before creates, tables before the
/// keys, views and triggers that need them, and types are removed only once nothing uses them.
public enum MigrationPhase: Int, Comparable, Sendable {
    case createSchema, createExtension, createType, alterType, createSequence
    case dropTrigger, dropView, dropForeignKey, dropConstraint, dropIndex, dropTable, dropColumn, dropRoutine
    case createTable, alterColumn, addConstraint, createIndex, addForeignKey, ownSequence
    case createRoutine, createView, createTrigger, comment
    case dropSequence, dropType, dropExtension

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct MigrationStep: Hashable, Sendable {
    public var phase: MigrationPhase
    /// Order within the phase, e.g. views after the views they read from.
    public var rank: Int
    public var sql: String

    public init(_ phase: MigrationPhase, _ sql: String, rank: Int = 0) {
        self.phase = phase
        self.rank = rank
        self.sql = sql
    }
}

/// One difference between the source and target schemas, and the statements that make the
/// target match the source.
public struct SchemaChange: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        /// In the source only: the migration creates it.
        case added
        /// In the target only: the migration drops it.
        case removed
        case changed
    }

    public var id: String
    public var kind: Kind
    /// "Table", "Column", "Index"…
    public var objectType: String
    /// The object's name, e.g. `users` or `users.email`.
    public var object: String
    /// What differs, e.g. "type text → character varying(255)".
    public var summary: String
    /// Loses data (dropping a table or column, or rebuilding a column).
    public var isDestructive: Bool
    /// May fail on existing data, e.g. adding NOT NULL to a column with NULLs.
    public var warning: String?
    /// The definition in each database, for side-by-side review.
    public var sourceDefinition: String?
    public var targetDefinition: String?
    public var steps: [MigrationStep]

    public init(id: String, kind: Kind, objectType: String, object: String, summary: String,
                isDestructive: Bool = false, warning: String? = nil, sourceDefinition: String? = nil,
                targetDefinition: String? = nil, steps: [MigrationStep]) {
        self.id = id
        self.kind = kind
        self.objectType = objectType
        self.object = object
        self.summary = summary
        self.isDestructive = isDestructive
        self.warning = warning
        self.sourceDefinition = sourceDefinition
        self.targetDefinition = targetDefinition
        self.steps = steps
    }

    /// The statements for a set of changes, in an order that runs: each change's steps are
    /// spread across the script by phase and rank, keeping the given order otherwise. A statement
    /// two changes share (such as rebuilding the same view) runs once.
    public static func migration(_ changes: [SchemaChange]) -> [String] {
        var seen: Set<String> = []
        return changes.flatMap(\.steps).enumerated()
            .sorted { ($0.element.phase, $0.element.rank, $0.offset) < ($1.element.phase, $1.element.rank, $1.offset) }
            .map(\.element.sql)
            .filter { seen.insert($0).inserted }
    }
}
