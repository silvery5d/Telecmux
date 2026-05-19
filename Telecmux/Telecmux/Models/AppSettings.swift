import Foundation

/// Where transcribed speech comes from when the user taps the mic ribbon.
enum VoiceProvider: String, Codable, CaseIterable {
    /// No transcription — open the modal with an empty text field.
    case none
    /// Hand off to Super Whisper via URL scheme, receive transcript on callback.
    case superWhisper

    var displayLabel: String {
        switch self {
        case .none:         "Off"
        case .superWhisper: "Super Whisper"
        }
    }
}

/// Global, device-local settings. Persists through `UserDefaults` so it
/// survives launches without touching the iCloud-synced session store.
/// Add new fields with explicit defaults so older builds keep decoding.
struct AppSettings: Codable {
    var voiceProvider: VoiceProvider = .none

    init(voiceProvider: VoiceProvider = .none) {
        self.voiceProvider = voiceProvider
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        voiceProvider = (try? c.decodeIfPresent(VoiceProvider.self, forKey: .voiceProvider)) ?? .none
    }
}

extension AppSettings {
    private static let defaultsKey = "telecmux.appSettings.v1"

    /// Read the current settings, falling back to defaults if nothing is
    /// stored yet or the stored blob is corrupt.
    static func load(from store: UserDefaults = .standard) -> AppSettings {
        guard let data = store.data(forKey: defaultsKey) else { return AppSettings() }
        return (try? JSONDecoder().decode(AppSettings.self, from: data)) ?? AppSettings()
    }

    /// Write to `UserDefaults`. Silently no-ops if encoding fails (which would
    /// require a Codable bug in this file — not user input).
    func save(to store: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        store.set(data, forKey: Self.defaultsKey)
    }
}
