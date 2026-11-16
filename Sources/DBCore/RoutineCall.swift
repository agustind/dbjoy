import Foundation

/// One parameter of a function or procedure, in declaration order.
public struct RoutineParameter: Hashable, Sendable {
    public enum Mode: String, Sendable {
        case `in` = "i", out = "o", inOut = "b", variadic = "v", table = "t"
    }

    /// Empty when the parameter has no name.
    public var name: String
    public var type: String
    public var mode: Mode
    /// The default expression, when callers may leave the parameter out.
    public var defaultValue: String?

    public init(name: String, type: String, mode: Mode = .in, defaultValue: String? = nil) {
        self.name = name
        self.type = type
        self.mode = mode
        self.defaultValue = defaultValue
    }

    /// Whether callers pass a value. OUT and TABLE parameters are part of the result.
    public var isInput: Bool { mode == .in || mode == .inOut || mode == .variadic }
}

/// What to pass for one input parameter.
public enum RoutineArgument: Hashable, Sendable {
    /// Text that the database casts to the parameter's type.
    case value(String)
    case null
    /// Leave the parameter out so the database uses its default.
    case useDefault
}

public extension SQLDialect {
    /// SQL that calls `routine`: `SELECT * FROM f(…)` for a function, `CALL p(…)` for a procedure.
    /// `arguments` holds one entry per input parameter, in order.
    func callStatement(for routine: ObjectRef, parameters: [RoutineParameter], arguments: [RoutineArgument]) -> String {
        var inputs = arguments.makeIterator()
        // Procedures take a placeholder for OUT parameters too (PostgreSQL 14+); functions don't.
        let passed: [(RoutineParameter, String?)] = parameters.compactMap { parameter in
            if parameter.isInput {
                let argument = inputs.next() ?? .null
                switch argument {
                case .value(let text): return (parameter, "\(quoteLiteral(text))::\(parameter.type)")
                case .null: return (parameter, "NULL::\(parameter.type)")
                case .useDefault: return (parameter, nil)
                }
            }
            return routine.kind == .procedure && parameter.mode == .out ? (parameter, "NULL::\(parameter.type)") : nil
        }
        func prefix(_ parameter: RoutineParameter) -> String { parameter.mode == .variadic ? "VARIADIC " : "" }

        let list: [String]
        if passed.allSatisfy({ !$0.0.name.isEmpty }) {
            // Named notation can leave out any parameter that has a default.
            list = passed.compactMap { parameter, value in
                value.map { "\(prefix(parameter))\(quoteIdentifier(parameter.name)) => \($0)" }
            }
        } else {
            // Positional notation can only leave out trailing ones; earlier gaps get the default spelled out.
            let used = passed.prefix((passed.lastIndex { $0.1 != nil } ?? -1) + 1)
            list = used.map { parameter, value in prefix(parameter) + (value ?? parameter.defaultValue ?? "NULL") }
        }
        let call = "\(qualifiedName(routine))(\(list.joined(separator: ", ")))"
        return routine.kind == .procedure ? "CALL \(call);" : "SELECT * FROM \(call);"
    }
}
