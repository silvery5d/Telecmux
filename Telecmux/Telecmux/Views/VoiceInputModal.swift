import SwiftUI

/// Sheet shown when the user taps the mic ribbon. Used in two scenarios:
/// - voice provider == .none: opens empty, user types
/// - voice provider == .superWhisper: opens prefilled with the transcript
///
/// API stays binding-based so callers can keep the editing state if they
/// want to (e.g. for retry / refine flows).
struct VoiceInputModal: View {
    @Binding var text: String
    var onSend: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var editorFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .focused($editorFocused)
                    .background(Color(.systemGroupedBackground))

                charCountFooter
            }
            .navigationTitle("Send text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .task {
                // task fires after view is in the hierarchy — more reliable
                // than onAppear for focusing TextEditor on iPad/iOS 17+.
                try? await Task.sleep(for: .milliseconds(80))
                editorFocused = true
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", action: dismiss.callAsFunction)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                onSend(text)
                dismiss()
            } label: {
                Label("Send", systemImage: "arrow.up.circle.fill")
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var charCountFooter: some View {
        HStack {
            Spacer()
            Text("\(text.count) chars")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial)
    }
}
