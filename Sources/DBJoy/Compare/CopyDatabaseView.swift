import DBCore
import SwiftUI

/// Database → Copy Database…: replaces everything in a target database with a copy of a source database.
struct CopyDatabaseView: View {
    @State private var model: CopyDatabaseModel
    @State private var isConfirming = false

    init(request: CompareRequest) {
        _model = State(initialValue: CopyDatabaseModel(request: request))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                SideCard(model: model, side: model.source, title: "Source", caption: "The database to copy")
                Button {
                    Task { await model.swap() }
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .buttonStyle(.ghost)
                .help("Swap source and target")
                .padding(.top, 34)
                .disabled(model.isCopying)
                SideCard(model: model, side: model.target, title: "Target", caption: "Everything in it is replaced")
            }
            .disabled(model.isCopying)

            options
            notes
            Spacer(minLength: 0)
            status
            footer
        }
        .padding(16)
        .frame(minWidth: 820, minHeight: 440)
        .background(Theme.contentBackground)
        .tint(Theme.accent)
        .navigationTitle("Copy Database")
        .task { await model.start() }
        .onDisappear { Task { await model.close() } }
        .sheet(isPresented: $isConfirming) {
            ConfirmCopySheet(model: model)
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $model.includeData) {
                Text("Copy data")
                Text("When off, only the structure is copied and the tables are empty.")
            }
            .accessibilityIdentifier("copy-include-data")
            Toggle(isOn: $model.keepOwnership) {
                Text("Copy owners and privileges")
                Text("When off, the target's user owns everything and no grants are copied. When on, the source's roles must exist on the target server.")
            }
            .accessibilityIdentifier("copy-keep-ownership")
        }
        .disabled(model.isCopying)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.border, lineWidth: 1))
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DBJoy drops every schema in the target, then copies the source in with pg_dump: schemas, tables, views, materialized views, functions, procedures, types, sequences, triggers, extensions and data. It all runs in one transaction, so if anything fails, the target stays as it was.")
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.sameDatabase {
                Label("Pick two different databases.", systemImage: "exclamationmark.circle")
                    .foregroundStyle(Theme.textSecondary)
            }
            if model.targetIsReadOnly {
                Label("The target connection is read-only.", systemImage: "lock")
                    .foregroundStyle(Theme.textSecondary)
            }
            if let warning = model.versionWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .font(.callout)
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .copying:
            TimelineView(.periodic(from: model.startedAt, by: 1)) { context in
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.progress.step).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(progressDetail(now: context.date))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .font(.callout)
            .accessibilityIdentifier("copy-progress")
        case .done(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.callout)
                .textSelection(.enabled)
                .accessibilityIdentifier("copy-result")
        case .failed(let message):
            ScrollView {
                Label {
                    Text(message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                .font(.callout)
            }
            .frame(maxHeight: 160)
            .accessibilityIdentifier("copy-result")
        }
    }

    private func progressDetail(now: Date) -> String {
        let elapsed = Duration.seconds(max(0, Int(now.timeIntervalSince(model.startedAt))))
        let time = elapsed.formatted(.time(pattern: .minuteSecond))
        guard model.progress.bytes > 0 else { return time }
        return ByteCountFormatter.string(fromByteCount: model.progress.bytes, countStyle: .file) + " · " + time
    }

    private var footer: some View {
        HStack {
            Spacer()
            if model.isCopying {
                Button("Cancel") { model.cancel() }
                    .buttonStyle(.outline)
                    .help("Stop the copy. The target isn't changed.")
            } else {
                Button("Copy to Target…") { isConfirming = true }
                    .buttonStyle(.primary)
                    .disabled(!model.canCopy)
                    .accessibilityIdentifier("copy-start")
            }
        }
    }
}

/// Asks for the target database's name before replacing it.
private struct ConfirmCopySheet: View {
    var model: CopyDatabaseModel
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""

    private var targetName: String { model.target.config?.displayName ?? "the target" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Replace \(model.target.database) on \(targetName)?")
                    .font(.headline)
                Spacer()
                if let environment = model.target.config?.environment { EnvironmentBadge(environment: environment) }
            }
            Text("Everything in \(model.target.database) is deleted and replaced with a copy of \(model.source.database) from \(model.source.config?.displayName ?? "the source")\(model.includeData ? "" : ", without its data").")
                .fixedSize(horizontal: false, vertical: true)
            Text("Type \(model.target.database) to confirm.")
                .foregroundStyle(Theme.textSecondary)
            TextField(model.target.database, text: $typed)
                .textFieldStyle(.roundedBorder)
                .onSubmit(confirm)
                .accessibilityIdentifier("copy-confirm-name")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Replace", action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(typed != model.target.database)
                    .accessibilityIdentifier("copy-confirm")
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func confirm() {
        guard typed == model.target.database else { return }
        dismiss()
        model.copy()
    }
}
