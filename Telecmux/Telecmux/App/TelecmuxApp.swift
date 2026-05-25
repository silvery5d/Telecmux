import SwiftUI

@main
struct TelecmuxApp: App {
    @State private var dataStore = DataStore()
    @State private var voice = VoiceInputCoordinator()
    // Skip the About sheet when capturing App Store screenshots.
    @State private var showAboutOnLaunch =
        !AboutView.hasSeenAbout
        && ProcessInfo.processInfo.environment["TELECMUX_SCREENSHOT"] == nil

    var body: some Scene {
        WindowGroup {
            SessionListView()
                .environment(dataStore)
                .environment(voice)
                .onOpenURL(perform: voice.handleCallbackURL)
                .sheet(isPresented: $showAboutOnLaunch, onDismiss: { AboutView.hasSeenAbout = true }) {
                    AboutView()
                }
        }
    }
}
