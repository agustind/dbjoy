import DBCore
import SwiftUI

struct ConnectionFormView: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var config: ConnectionConfig
    @State private var password: String
    @State private var portText: String
    @State private var testState: TestState = .idle
    @State private var connectionString = ""
    @State private var importStatus: ImportStatus?
    /// A connection string found on the clipboard, offered as a one-click import.
    @State private var clipboardCandidate: (text: String, summary: String)?
    /// Name generated from a connection string; replaced on re-import unless the user edited it.
    @State private var autoName: String?
    private let isNew: Bool
    private let onConnect: (ConnectionConfig) -> Void

    enum TestState: Equatable {
        case idle, testing, success(String), failure(String)
    }

    enum ImportStatus: Equatable {
        case filled(String), failed(String)
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
                    if let candidate = clipboardCandidate, connectionString.isEmpty {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.on.clipboard").foregroundStyle(Theme.accentText)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Connection string on the clipboard").font(.system(size: 12, weight: .semibold))
                                Text(candidate.summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button("Use It") {
                                connectionString = candidate.text
                                applyConnectionString(reportErrors: true)
                            }
                            .buttonStyle(.primary)
                        }
                    }
                    HStack(spacing: 8) {
                        TextField("Connection string", text: $connectionString,
                                  prompt: Text("postgres://user:password@host:5432/database"))
                            .font(.system(.body, design: .monospaced))
                            .onSubmit { applyConnectionString(reportErrors: true) }
                            .onChange(of: connectionString) { _, _ in applyConnectionString(reportErrors: false) }
                        Button {
                            if let text = NSPasteboard.general.string(forType: .string) {
                                connectionString = text.trimmingCharacters(in: .whitespacesAndNewlines)
                                applyConnectionString(reportErrors: true)
                            }
                        } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                            .help("Paste a connection string from the clipboard")
                    }
                    switch importStatus {
                    case .filled(let message):
                        Label(message, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    case nil:
                        EmptyView()
                    }
                } header: {
                    Text("Quick setup")
                } footer: {
                    Text("Paste a postgres:// URL or key=value string to fill in the fields below. The string itself isn't saved; the password goes to the Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                    .accessibilityIdentifier("form-test")
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("form-cancel")
                Button("Save") { save() }
                    .accessibilityIdentifier("form-save")
                Button("Save & Connect") {
                    save()
                    onConnect(config)
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 540, height: 700)
        .onAppear(perform: detectClipboard)
        .navigationTitle(isNew ? "New Connection" : "Edit Connection")
    }

    /// Fills the form from `connectionString`. While typing, failures stay quiet.
    private func applyConnectionString(reportErrors: Bool) {
        let text = connectionString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            importStatus = nil
            return
        }
        do {
            let parsed = try ConnectionString.parse(text)
            if let autoName, config.name == autoName { config.name = "" }
            let hadName = !config.name.isEmpty
            parsed.apply(to: &config)
            if !hadName { autoName = config.name }
            portText = String(config.port)
            if let value = parsed.password { password = value }
            var filled: [String] = []
            if parsed.host != nil { filled.append("host") }
            if parsed.port != nil || parsed.host != nil { filled.append("port") }
            if parsed.user != nil { filled.append("user") }
            if parsed.password != nil { filled.append("password") }
            if parsed.database != nil { filled.append("database") }
            if parsed.sslMode != nil { filled.append("SSL mode") }
            if !parsed.options.isEmpty { filled.append(parsed.options.keys.sorted().joined(separator: ", ")) }
            var message = "Filled " + filled.joined(separator: ", ")
            if !parsed.ignored.isEmpty { message += ". Skipped unsupported: " + parsed.ignored.joined(separator: ", ") }
            importStatus = .filled(message)
            testState = .idle
        } catch {
            if reportErrors || importStatus != nil {
                importStatus = .failed(error.localizedDescription)
            }
        }
    }

    private func detectClipboard() {
        guard isNew, let text = NSPasteboard.general.string(forType: .string),
              ConnectionString.looksLikeConnectionString(text),
              let parsed = try? ConnectionString.parse(text) else { return }
        // Never show the password.
        let user = parsed.user.map { "\($0)@" } ?? ""
        let database = parsed.database.map { "/\($0)" } ?? ""
        clipboardCandidate = (text.trimmingCharacters(in: .whitespacesAndNewlines),
                              "\(user)\(parsed.host ?? "localhost")\(parsed.port.map { ":\($0)" } ?? "")\(database)")
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
