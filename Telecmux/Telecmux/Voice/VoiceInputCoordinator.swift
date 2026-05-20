import Foundation

/// State holder + dispatcher for the mic ribbon button.
///
/// Two responsibilities:
/// 1. When the user taps the mic, decide whether to hand off to an external
///    transcription app (Super Whisper) or open an empty text-input modal.
/// 2. When the external app calls back into the app via the
///    `telecmux://voice-callback?text=...` URL, surface the transcript and
///    open the modal so the user can review + send.
///
/// Views observe `isModalPresented` and `transcribedText`.
@Observable
final class VoiceInputCoordinator {
    /// `true` once the modal should be presented. Views flip this back to
    /// `false` after they consume the value.
    var isShowingVoiceModal: Bool = false
    /// Text to seed the modal's TextEditor with. Empty for manual entry.
    var transcribedText: String = ""

    /// Called from ribbon button. With voiceProvider == .superWhisper we
    /// hand off to that app; otherwise we open the in-app modal, which
    /// hosts the on-device SFSpeechRecognizer-based live transcriber.
    func handleVoiceButton(settings: AppSettings) {
        if settings.voiceProvider == .superWhisper, SuperWhisperProvider.isAvailable {
            SuperWhisperProvider.openForTranscription()
            return
        }
        present(prefill: "")
    }

    /// Called from `App.onOpenURL` when an external app sends us a transcript.
    func handleCallbackURL(_ url: URL) {
        guard url.scheme == "telecmux",
              url.host == "voice-callback",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let item = comps.queryItems?.first(where: { $0.name == "text" }),
              let value = item.value
        else { return }
        present(prefill: value)
    }

    private func present(prefill: String) {
        transcribedText = prefill
        isShowingVoiceModal = true
    }
}
