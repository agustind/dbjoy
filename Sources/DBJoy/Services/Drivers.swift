import DBCore
import PostgresDriver

/// Maps database kinds to their drivers. Register new engines here.
enum Drivers {
    static func driver(for kind: DatabaseKind) -> any DatabaseDriver {
        switch kind {
        case .postgres: PostgresDriver()
        }
    }
}
