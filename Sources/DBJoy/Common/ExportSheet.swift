import DBCore
import SwiftUI

struct ExportSheet: View {
    @Bindable var model: ExportModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Export from \(model.workspace?.currentDatabase ?? "") · \(model.schema)").font(.headline)
                Spacer()
            }

            Picker("Format", selection: $model.kind) {
                ForEach(ExportKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isRunning)

            Text(model.kind.explanation).font(.callout).foregroundStyle(.secondary)
            if model.kind == .dump {
                if let tool = ExportModel.pgDumpURL {
                    Text(verbatim: "Uses \(tool.path). The table selection doesn't apply to backups.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("pg_dump not found. Install it with `brew install libpq`.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            HStack {
                Text("\(model.selectedRefs.count) of \(model.visibleObjects.count) selected").font(.callout)
                Spacer()
                Toggle("Include views", isOn: $model.includeViews)
                    .disabled(model.kind == .dump)
                Button("All") { model.selectAll(true) }
                Button("None") { model.selectAll(false) }
            }
            .controlSize(.small)
            .disabled(model.isRunning || model.kind == .dump)

            List(model.visibleObjects) { object in
                Toggle(isOn: Binding(
                    get: { model.selected.contains(object.ref) },
                    set: { if $0 { model.selected.insert(object.ref) } else { model.selected.remove(object.ref) } })
                ) {
                    Label(object.name, systemImage: object.kind.systemImage)
                }
            }
            .frame(minHeight: 200)
            .disabled(model.isRunning || model.kind == .dump)
            .opacity(model.kind == .dump ? 0.5 : 1)

            status

            HStack {
                Spacer()
                switch model.phase {
                case .running:
                    Button("Stop") { model.cancel() }
                case .finished:
                    Button("Show in Finder") { model.revealInFinder() }
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                default:
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Export…") { model.chooseDestinationAndStart() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.kind == .dump ? ExportModel.pgDumpURL == nil : model.selectedRefs.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 560)
        .onChange(of: model.kind) { _, kind in
            if kind == .dump { model.includeViews = false }
        }
        .interactiveDismissDisabled(model.isRunning)
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .configuring:
            EmptyView()
        case .running:
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(model.tablesDone), total: Double(max(model.selectedRefs.count, 1)))
                Text("Exporting \(model.currentTable)… \(model.rowsExported.formatted()) rows")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .finished(let message):
            Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).textSelection(.enabled)
        }
    }
}
