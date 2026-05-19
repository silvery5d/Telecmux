import SwiftUI

/// Global app preferences. Modeless surface from the gear icon in the
/// SessionList toolbar. Currently:
///   - voice provider selection
///   - iCloud sync status indicator (read-only)
///   - About modal entry
struct SettingsView: View {
    @Environment(DataStore.self) private var dataStore
    @Environment(\.dismiss) private var dismiss

    @State private var settings = AppSettings.load()
    @State private var showingAbout = false

    var body: some View {
        NavigationStack {
            Form {
                voiceSection
                cloudSection

                Section {
                    Button("About Telecmux") { showingAbout = true }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss.callAsFunction)
                }
            }
            .sheet(isPresented: $showingAbout) { AboutView() }
        }
    }

    // MARK: - sections

    private var voiceSection: some View {
        Section {
            Picker("Provider", selection: $settings.voiceProvider) {
                ForEach(VoiceProvider.allCases, id: \.self) { provider in
                    Text(provider.displayLabel).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: settings.voiceProvider) { _, _ in settings.save() }
        } header: {
            Text("Voice input")
        } footer: {
            switch settings.voiceProvider {
            case .none:
                Text("The mic ribbon button opens an empty text editor.")
            case .superWhisper:
                Text("Mic ribbon hands off to Super Whisper for transcription. If Super Whisper isn't installed, falls back to an empty editor.")
            }
        }
    }

    private var cloudSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: dataStore.iCloudAvailable ? "checkmark.icloud.fill" : "xmark.icloud")
                    .foregroundStyle(dataStore.iCloudAvailable ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(dataStore.iCloudAvailable ? "Syncing via iCloud Drive" : "Local-only storage")
                        .font(.body)
                    Text(dataStore.iCloudAvailable
                         ? "Hosts and sessions mirror to every device signed into this Apple ID."
                         : "Sign in to iCloud Drive to share configuration across devices.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Cross-device sync")
        }
    }
}
