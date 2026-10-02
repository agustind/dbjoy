import DBCore
import SwiftUI

struct ConnectionFormView: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var config: ConnectionConfig
    @State private var password: String
    @State private var portText: String
    @State private var testState: TestState = .idle
    private let isNew: Bool
    private let onConnect: (ConnectionConfig) -> Void

    enum TestState: Equatable {
        case idle, testing, success(String), failure(String)
    }

    init(draft: ConnectionDraft, onConnect: @escaping (ConnectionConfig) -> Void) {
        _config = State(initialValue: draft.config)
        _password = State(initialValue: draft.isNew ? "" : (Keychain.password(for: draft.config.id) ?? ""))
        _portText = State(initialValue: String(draft.config.port))
        isNew = draft.isNew
        self.onConnect = onConnect
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $config.name, prompt: Text("My database"))
                    Picker("Environment", selection: $config.environment) {
                        ForEach(ConnectionEnvironment.allCases) { env in
                            Label(env.displayName, systemImage: "circle.fill")
                                .foregroundStyle(env.color)
                                .tag(env)
                        }
                    }
                    TextField("Group", text: $config.group, prompt: Text("Optional, e.g. Acme"))
                    Picker("Type", selection: $config.kind) {
                        ForEach(DatabaseKind.allCases) { Text($0.displayName).tag($0) }
                    }
                }
                Section("Server") {
                    TextField("Host", text: $config.host, prompt: Text("localhost or /tmp socket dir"))
                    TextField("Port", text: $portText)
                        .onChange(of: portText) { _, value in
                            if let port = Int(value) { config.port = port }
                        }
                    TextField("User", text: $config.user)
                    SecureField("Password", text: $password)
                    Toggle("Save password in Keychain", isOn: $config.savePassword)
                    TextField("Database", text: $config.database, prompt: Text("postgres"))
                    Picker("SSL mode", selection: $config.sslMode) {
                        ForEach(SSLMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                Section("Safety") {
                    Toggle("Read-only (enforced by the server)", isOn: $config.readOnly)
                    if config.environment.requiresWriteConfirmation {
                        Label("Writes on production connections always ask for confirmation.", systemImage: "exclamationmark.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                switch testState {
                case .idle: EmptyView()
                case .testing: ProgressView().controlSize(.small)
                case .success(let message):
                    Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green).lineLimit(1)
                case .failure(let message):
                    Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(2).help(message)
                }
                Spacer()
                Button("Test") { Task { await test() } }
                    .disabled(testState == .testing)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                Button("Save & Connect") {
                    save()
                    onConnect(config)
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 620)
        .navigationTitle(isNew ? "New Connection" : "Edit Connection")
    }

    private func save() {
        store.save(config, password: password)
        dismiss()
    }

    private func test() async {
        testState = .testing
        do {
            let connection = try await Drivers.driver(for: config.kind).connect(config, password: password, database: nil)
            let version = connection.serverVersion
            await connection.close()
            testState = .success("Connected — server \(version)")
        } catch {
            testState = .failure(error.localizedDescription)
        }
    }
}
