import SwiftUI

struct SessionListView: View {
    @Environment(DataStore.self) private var dataStore
    @State private var showingNewSession = false
    @State private var showingSettings = false
    @State private var selectedSession: Session?
    @State private var editingHost: Host?

    var body: some View {
        NavigationStack {
            Group {
                if dataStore.hosts.isEmpty {
                    ContentUnavailableView(
                        "No Sessions",
                        systemImage: "terminal",
                        description: Text("Add a session to get started.")
                    )
                } else {
                    sessionList
                }
            }
            .navigationTitle("Telecmux")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gear")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingNewSession = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingNewSession) {
                NewSessionView()
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(item: $editingHost) { host in
                NewHostView(existing: host)
            }
            .navigationDestination(item: $selectedSession) { session in
                destination(for: session)
            }
        }
    }

    @ViewBuilder
    private func destination(for session: Session) -> some View {
        switch session.mode {
        case .board:
            PaneBoardView(session: session)
        case .pane:
            PaneFocusView(session: session, initialPane: nil, sharedSSH: nil)
        }
    }

    private var sessionList: some View {
        List {
            ForEach(dataStore.hosts) { host in
                let hostSessions = dataStore.sessions(for: host)
                    .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                if !hostSessions.isEmpty {
                    Section {
                        ForEach(hostSessions) { session in
                            Button {
                                selectedSession = session
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.displayName)
                                        .font(.body)
                                    Text(session.mode.displayLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    dataStore.deleteSession(session)
                                }
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                dataStore.deleteSession(hostSessions[index])
                            }
                        }
                    } header: {
                        HStack {
                            Text(host.displayName)
                            Spacer()
                            Menu {
                                Button("Edit Host") { editingHost = host }
                                Button("Delete Host", role: .destructive) {
                                    dataStore.deleteHost(host)
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}
