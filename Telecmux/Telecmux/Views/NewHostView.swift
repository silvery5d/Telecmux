import SwiftUI

/// Form for adding **or editing** an SSH Host. When `existing` is non-nil,
/// the form pre-populates and `Save` updates that record in place;
/// otherwise it creates a new record. The private key field never
/// round-trips through the JSON store — only the Keychain account string is
/// persisted there.
struct NewHostView: View {
    @Environment(DataStore.self) private var dataStore
    @Environment(\.dismiss) private var dismiss

    /// Existing host being edited, or nil when creating fresh.
    var existing: Host?
    /// Called after a successful create (not called on edit).
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

    private var isEditing: Bool { existing != nil }

    // MARK: - body

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                privateKeySection
                if let saveFailure { errorSection(saveFailure) }
            }
            .navigationTitle(isEditing ? "Edit Host" : "New Host")
            .toolbar { toolbar }
            .task {
                if let existing {
                    displayName = existing.displayName
                    hostname    = existing.hostname
                    portText    = String(existing.port)
                    username    = existing.username
                    // Don't reveal the stored private key; user can re-paste
                    // to replace, otherwise the Keychain value stays put.
                }
            }
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
            Text(isEditing ? "Private key (paste to replace)" : "Private key (PEM)")
        } footer: {
            if isEditing {
                Text("Leave blank to keep the existing key. Paste a new PEM blob to replace it.")
                    .font(.caption2)
            } else {
                Text("Paste the contents of \(Text("~/.ssh/id_ed25519").font(.caption.monospaced())) (or RSA). Stored in the iOS Keychain — never written to the synced JSON store.")
                    .font(.caption2)
            }
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
        let pasted = privateKey.trimmingCharacters(in: .whitespacesAndNewlines)

        // Determine the Keychain account for the key.
        var keyAccount = existing?.privateKeyRef ?? ""
        if !pasted.isEmpty {
            // New paste (either first time or replacing) → write a new
            // account so the old entry can be cleaned up if needed.
            let account = keyAccount.isEmpty ? "ssh-key-\(UUID().uuidString)" : keyAccount
            do {
                try KeychainStore.store(Data(pasted.utf8), as: account)
                keyAccount = account
            } catch {
                saveFailure = error.localizedDescription
                return
            }
        } else if !isEditing {
            // Creating a host without a key is allowed but rarely useful.
            // The SSH layer will surface "No SSH key set for this host"
            // on first connect attempt.
        }

        if var host = existing {
            host.displayName  = displayName
            host.hostname     = hostname
            host.port         = port
            host.username     = username
            host.privateKeyRef = keyAccount
            dataStore.updateHost(host)
        } else {
            let host = Host(
                displayName: displayName,
                hostname: hostname,
                port: port,
                username: username,
                privateKeyRef: keyAccount
            )
            dataStore.addHost(host)
            onCreated?(host)
        }
        dismiss()
    }
}
