import AppKit
import DBCore
import SwiftUI

/// SSH tunnel fields, used in the connection form and the "connect through SSH" sheet.
struct SSHTunnelFields: View {
    @Binding var ssh: SSHTunnelConfig
    /// SSH password, or the private key's passphrase (optional).
    @Binding var secret: String
    @State private var portText = ""

    var body: some View {
        TextField("SSH host", text: $ssh.host, prompt: Text("bastion.example.com"))
        TextField("SSH port", text: $portText)
            .onAppear { portText = String(ssh.port) }
            .onChange(of: portText) { _, value in
                if let port = Int(value), (1...65535).contains(port) { ssh.port = port }
            }
        TextField("SSH user", text: $ssh.user, prompt: Text("ubuntu"))
        Picker("Authentication", selection: $ssh.authMethod) {
            ForEach(SSHTunnelConfig.AuthMethod.allCases) { Text($0.displayName).tag($0) }
        }
        switch ssh.authMethod {
        case .privateKey:
            HStack {
                TextField("Private key", text: $ssh.privateKeyPath, prompt: Text("~/.ssh/id_ed25519"))
                Button("Choose…", action: chooseKey)
            }
            SecureField("Key passphrase", text: $secret, prompt: Text("Only if the key has one"))
        case .password:
            SecureField("SSH password", text: $secret)
        case .agent:
            Text("Uses the keys loaded in your SSH agent (ssh-add).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.title = "Choose SSH Private Key"
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        ssh.privateKeyPath = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}

/// Offered when a connection fails: route it through an SSH server that can reach the database.
struct SSHTunnelSheet: View {
    var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var ssh = SSHTunnelConfig()
    @State private var secret = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect through an SSH tunnel").font(.headline)
                Text("DBJoy forwards a local port through this SSH server to \(model.config.host):\(model.config.port), so the database only has to be reachable from the SSH server.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 20)

            Form {
                SSHTunnelFields(ssh: $ssh, secret: $secret)
            }
            .formStyle(.grouped)

            HStack {
                if model.config.ssh.isEnabled {
                    Button("Stop using SSH") { apply(enabled: false) }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save & Connect") { apply(enabled: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ssh.isComplete)
            }
            .padding(20)
        }
        .frame(width: 500)
        .onAppear {
            ssh = model.config.ssh
            if ssh.host.isEmpty { ssh.user = NSUserName() }
            secret = Keychain.password(for: model.config.id, ssh: true) ?? ""
        }
    }

    private func apply(enabled: Bool) {
        var settings = ssh
        settings.isEnabled = enabled
        let usesSecret = settings.authMethod != .agent
        dismiss()
        Task { await model.applySSH(settings, secret: usesSecret ? secret : "") }
    }
}
