import Foundation
import UIKit

/// Stateless adapter for handing speech-to-text duties off to the
/// [Super Whisper](https://superwhisper.com) iOS app via URL scheme.
///
/// Wire shape:
///   we open  `superwhisper://transcribe?callback=telecmux://voice-callback`
///   it sends `telecmux://voice-callback?text=<percent-encoded-transcript>`
///   our `App.onOpenURL` picks that up and feeds `VoiceInputCoordinator`.
enum SuperWhisperProvider {
    /// Super Whisper's launch URL.
    static let scheme = "superwhisper"
    /// What we ask Super Whisper to call back into when it's done.
    static let callbackURL = "telecmux://voice-callback"

    /// `true` iff Super Whisper is installed on the device.
    static var isAvailable: Bool {
        guard let url = URL(string: "\(scheme)://transcribe") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    /// Open Super Whisper's transcribe screen, passing the callback target.
    static func openForTranscription() {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "transcribe"
        components.queryItems = [URLQueryItem(name: "callback", value: callbackURL)]
        guard let url = components.url else { return }
        UIApplication.shared.open(url)
    }
}
