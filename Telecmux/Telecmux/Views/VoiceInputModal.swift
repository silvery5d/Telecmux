import SwiftUI

/// Sheet shown when the user taps the mic ribbon. Inside:
/// - a TextEditor showing the working transcript (editable any time)
/// - a record button that toggles `LiveTranscriber` start/stop; while
///   recording, partial transcripts flow into the editor live
/// - Cancel / Send in the navigation bar
struct VoiceInputModal: View {
    @Binding var text: String
    var onSend: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var editorFocused: Bool
    @State private var transcriber = LiveTranscriber()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .focused($editorFocused)
                    .background(Color(.systemGroupedBackground))

                statusFooter
                recordingControl
            }
            .navigationTitle("Send text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .onChange(of: transcriber.transcript) { _, newValue in
                // Stream partial recognition into the editor as the user speaks.
                text = newValue
            }
            .onDisappear { transcriber.stop() }
        }
    }

    // MARK: - bars

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
                transcriber.stop()
                dismiss()
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                transcriber.stop()
                onSend(text)
                dismiss()
            } label: {
                Label("Send", systemImage: "arrow.up.circle.fill")
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var statusFooter: some View {
        HStack {
            statusText
            Spacer()
            Text("\(text.count) chars")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial)
    }

    @ViewBuilder
    private var statusText: some View {
        switch transcriber.status {
        case .idle:
            Text("Idle").font(.caption2).foregroundStyle(.secondary)
        case .requestingPermission:
            Text("Requesting permission…").font(.caption2).foregroundStyle(.secondary)
        case .recording:
            Label("Recording", systemImage: "waveform")
                .font(.caption2.bold())
                .foregroundStyle(.red)
        case .denied(let msg):
            Label(msg, systemImage: "mic.slash.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .error(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(1)
        }
    }

    private var recordingControl: some View {
        let recording = transcriber.status == .recording
        return Button {
            Task {
                if recording { transcriber.stop() }
                else { await transcriber.start() }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(recording ? Color.red : Color.accentColor)
                    .frame(width: 64, height: 64)
                Image(systemName: recording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
            }
            .shadow(radius: recording ? 8 : 3)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}
