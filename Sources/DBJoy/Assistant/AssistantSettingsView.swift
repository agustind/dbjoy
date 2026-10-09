import SwiftUI

/// Settings → AI Assistant: provider, API keys, model and whether the assistant may change data.
struct AssistantSettingsView: View {
    @AppStorage(AssistantSettings.providerKey) private var provider: AIProvider = .anthropic
    @AppStorage(AssistantSettings.allowWritesKey) private var allowWrites = false
    @AppStorage(AssistantSettings.confirmWritesKey) private var confirmWrites = true
    @State private var apiKey = ""
    @State private var model = ""

    var body: some View {
        Form {
            Picker("Provider", selection: $provider) {
                ForEach(AIProvider.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)

            Section {
                SecureField("API key", text: $apiKey, prompt: Text(provider.keyPlaceholder))
                    .onChange(of: apiKey) { _, key in AssistantSettings.setAPIKey(key, for: provider) }
                TextField("Model", text: $model, prompt: Text(provider.defaultModel))
                    .onChange(of: model) { _, value in
                        UserDefaults.standard.set(value.trimmingCharacters(in: .whitespaces),
                                                  forKey: AssistantSettings.modelKey(provider))
                    }
            } footer: {
                HStack(spacing: 4) {
                    Text("Stored in your login keychain.")
                    Link("Get a \(provider.displayName) key", destination: provider.keysURL)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Allow the assistant to change data", isOn: $allowWrites)
                Toggle("Ask before running each change", isOn: $confirmWrites)
                    .disabled(!allowWrites)
            } footer: {
                Text(allowWrites
                     ? "The assistant can run INSERT, UPDATE, DELETE and schema changes, each in its own transaction. "
                        + "Production connections always ask first; read-only connections never allow changes."
                     : "The assistant only reads: its queries run in read-only transactions. It can still write SQL "
                        + "into a query tab for you to review and run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                EmptyView()
            } footer: {
                Text("Your questions, table structures and the query results the assistant needs are sent to "
                     + "\(provider.displayName) to answer. Nothing is sent until you ask something.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
        .onAppear(perform: load)
        .onChange(of: provider) { load() }
    }

    private func load() {
        apiKey = AssistantSettings.apiKey(for: provider) ?? ""
        model = UserDefaults.standard.string(forKey: AssistantSettings.modelKey(provider)) ?? ""
    }
}
