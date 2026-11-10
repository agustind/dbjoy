import DBCore
import SwiftUI

/// Database → Edit History: the commits made from table tabs on this connection, each revertible.
struct EditHistorySheet: View {
    var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var expanded: UUID?

    private var records: [EditRecord] { EditHistory.shared.records(for: model.config.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit History").font(.headline)
            Text("Commits made from table tabs on \(model.config.displayName). Reverting runs the reverse SQL in one "
                 + "transaction, and changes nothing if a row was edited again since.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if records.isEmpty {
                ContentUnavailableView("No commits yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Edits you commit with ⌘S show up here."))
                    .frame(maxHeight: .infinity)
            } else {
                List(records) { record in
                    row(record)
                }
                .listStyle(.inset)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 680, height: 480)
    }

    private func row(_ record: EditRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    expanded = expanded == record.id ? nil : record.id
                } label: {
                    Image(systemName: expanded == record.id ? "chevron.down" : "chevron.right")
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded == record.id ? "Hide SQL" : "Show SQL")
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(record.table.schema).\(record.table.name)").font(.system(size: 13, weight: .medium))
                    Text("\(record.summary) · \(record.date.formatted(date: .abbreviated, time: .shortened))"
                         + (record.database == model.currentDatabase ? "" : " · \(record.database)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let reverted = record.revertedAt {
                    Text("Reverted \(reverted.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Revert…") {
                        model.recordToRevert = record
                        dismiss()
                    }
                    .buttonStyle(.outline)
                }
            }
            if expanded == record.id {
                Text(record.statements.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            }
        }
        .padding(.vertical, 4)
    }
}
