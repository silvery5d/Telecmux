import SwiftUI

struct NewSessionView: View {
    @Environment(DataStore.self) private var dataStore
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var mode: SessionMode = .board
    @State private var cmuxSurfaceRef = ""
    @State private var selectedHostID: UUID?
    @State private var showingNewHost = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Session") {
                    TextField("Display Name", text: $displayName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Picker("Mode", selection: $mode) {
                        ForEach(SessionMode.allCases, id: \.self) { m in
                            Text(m.displayLabel).tag(m)
                        }
                    }
                }

                modeSpecificFields

                Section("Host") {
                    if dataStore.hosts.isEmpty {
                        Text("No hosts configured")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Select Host", selection: $selectedHostID) {
                            Text("None").tag(nil as UUID?)
                            ForEach(dataStore.hosts) { host in
                                Text(host.displayName).tag(host.id as UUID?)
                            }
                        }
                    }
                    Button("Create New Host") {
                        showingNewHost = true
                    }
                }

                if let hostID = selectedHostID,
                   let host = dataStore.hosts.first(where: { $0.id == hostID }) {
                    Section("Host Details") {
                        LabeledContent("Hostname", value: host.hostname)
                        LabeledContent("Port", value: "\(host.port)")
                        LabeledContent("Username", value: host.username)
                    }
                }
            }
            .navigationTitle("New Session")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: saveSession)
                        .disabled(displayName.isEmpty || selectedHostID == nil)
                }
            }
            .sheet(isPresented: $showingNewHost) {
                NewHostView { newHost in
                    selectedHostID = newHost.id
                }
            }
        }
    }

    @ViewBuilder
    private var modeSpecificFields: some View {
        switch mode {
        case .pane:
            Section {
                TextField("Surface ref (e.g. surface:34 or UUID)", text: $cmuxSurfaceRef)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("cmux pane")
            } footer: {
                Text("Get the surface ref from `cmux --json list-panes` on the Mac, or open this host in board mode first and tap a pane.")
                    .font(.caption)
            }
        case .board:
            Section {
                EmptyView()
            } footer: {
                Text("Lists all panes and pending agent notifications. Requires cmux ≥ 0.64 with Settings → Automation → Socket control mode set to \"Automation mode\".")
                    .font(.caption)
            }
        }
    }

    private func saveSession() {
        guard let hostID = selectedHostID else { return }
        let trimmedRef = cmuxSurfaceRef.trimmingCharacters(in: .whitespaces)
        let session = Session(
            displayName: displayName,
            hostID: hostID,
            mode: mode,
            cmuxSurfaceRef: mode == .pane && !trimmedRef.isEmpty ? trimmedRef : nil
        )
        dataStore.addSession(session)
        dismiss()
    }
}
