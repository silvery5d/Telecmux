import SwiftUI

/// Form for adding a new SSH Host. The private key field is the only one
/// that doesn't round-trip through plain JSON — it's written to the Keychain
/// under a fresh UUID account and only the account string is saved.
struct NewHostView: View {
    @Environment(DataStore.self) private var dataStore
    @Environment(\.dismiss) private var dismiss

    var onCreated: ((Host) -> Void)?

    // MARK: - form state

    @State private var displayName: String = ""
    @State private var hostname: String   = ""
    @State private var portText: String   = "22"
    @State private var username: String   = ""
    @State private var privateKey: String = ""

    @State private var saveFailure: String?

    private var canSave: Bool {
        !displayName.isEmpty && !hostname.isEmpty && !username.isEmpty
    }

    // MARK: - body

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                privateKeySection
                if let saveFailure { errorSection(saveFailure) }
            }
            .navigationTitle("New Host")
            .toolbar { toolbar }
        }
    }

    // MARK: - sections

    private var connectionSection: some View {
        Section {
            TextField("Display Name", text: $displayName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Hostname or IP", text: $hostname)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Port", text: $portText)
                .keyboardType(.numberPad)
            TextField("Username", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Connection")
        } footer: {
            Text("Tip: hostnames work too — e.g. 100.x.x.x for a Tailscale node, or my-mac.local on the same WiFi.")
                .font(.caption2)
        }
    }

    private var privateKeySection: some View {
        Section {
            TextEditor(text: $privateKey)
                .font(.system(.caption, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 140)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Private key (PEM)")
        } footer: {
            Text("Paste the contents of \(Text("~/.ssh/id_ed25519").font(.caption.monospaced())) (or RSA). Stored in the iOS Keychain — never written to the synced JSON store.")
                .font(.caption2)
        }
    }

    private func errorSection(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", action: dismiss.callAsFunction)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save", action: save).disabled(!canSave)
        }
    }

    // MARK: - save

    private func save() {
        saveFailure = nil
        let port = Int(portText) ?? 22

        // Stash the key in Keychain (if provided) and remember the account
        // string so SSHConnectionManager can find it later.
        var keyAccount = ""
        let pasted = privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pasted.isEmpty {
            keyAccount = "ssh-key-\(UUID().uuidString)"
            do {
                try KeychainStore.store(Data(pasted.utf8), as: keyAccount)
            } catch {
                saveFailure = error.localizedDescription
                return
            }
        }

        let host = Host(
            displayName: displayName,
            hostname: hostname,
            port: port,
            username: username,
            privateKeyRef: keyAccount
        )
        dataStore.addHost(host)
        onCreated?(host)
        dismiss()
    }
}
