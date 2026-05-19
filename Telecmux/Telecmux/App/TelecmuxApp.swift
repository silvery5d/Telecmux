import SwiftUI

@main
struct TelecmuxApp: App {
    @State private var dataStore = DataStore()
    @State private var voice = VoiceInputCoordinator()
    @State private var showAboutOnLaunch = !AboutView.hasSeenAbout

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
