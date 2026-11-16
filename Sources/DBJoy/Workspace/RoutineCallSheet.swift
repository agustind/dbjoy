import DBCore
import SwiftUI

/// Asks for a function's or procedure's input parameters before running it.
struct RoutineCallSheet: View {
    enum Choice: Hashable { case value, null, useDefault }

    var request: RoutineCallRequest
    var run: ([RoutineArgument]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var texts: [String]
    @State private var choices: [Choice]

    private let inputs: [RoutineParameter]

    init(request: RoutineCallRequest, run: @escaping ([RoutineArgument]) -> Void) {
        self.request = request
        self.run = run
        inputs = request.parameters.filter(\.isInput)
        _texts = State(initialValue: inputs.map { _ in "" })
        _choices = State(initialValue: inputs.map { $0.defaultValue == nil ? .value : .useDefault })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(request.routine.kind == .procedure ? "Call" : "Run") \(request.routine.schema).\(request.routine.name)")
                .font(.headline)
            Text("DBJoy casts each value to the parameter's type and runs the call in a new query tab, where you can edit it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    ForEach(inputs.indices, id: \.self) { index in
                        row(index)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.outline)
                    .keyboardShortcut(.cancelAction)
                Button(request.routine.kind == .procedure ? "Call" : "Run") {
                    run(arguments)
                    dismiss()
                }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    @ViewBuilder private func row(_ index: Int) -> some View {
        let parameter = inputs[index]
        GridRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(parameter.name.isEmpty ? "$\(index + 1)" : parameter.name)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                Text((parameter.mode == .variadic ? "VARIADIC " : "") + parameter.type)
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(minWidth: 110, alignment: .leading)
            TextField(placeholder(parameter, choices[index]), text: Binding(
                get: { texts[index] },
                set: {
                    texts[index] = $0
                    choices[index] = .value
                }))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .accessibilityLabel(parameter.name.isEmpty ? "Parameter \(index + 1)" : parameter.name)
            Picker("", selection: Binding(
                get: { choices[index] },
                set: {
                    choices[index] = $0
                    if $0 != .value { texts[index] = "" }
                })) {
                Text("Value").tag(Choice.value)
                Text("NULL").tag(Choice.null)
                if parameter.defaultValue != nil { Text("Default").tag(Choice.useDefault) }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Pass for \(parameter.name.isEmpty ? "parameter \(index + 1)" : parameter.name)")
        }
    }

    private func placeholder(_ parameter: RoutineParameter, _ choice: Choice) -> String {
        switch choice {
        case .value: parameter.mode == .variadic ? "{1,2,3}" : parameter.type
        case .null: "NULL"
        case .useDefault: "Default: \(parameter.defaultValue ?? "")"
        }
    }

    private var arguments: [RoutineArgument] {
        zip(choices, texts).map { choice, text in
            switch choice {
            case .value: .value(text)
            case .null: .null
            case .useDefault: .useDefault
            }
        }
    }
}
