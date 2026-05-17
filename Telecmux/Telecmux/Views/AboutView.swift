import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    ZStack {
                        LinearGradient(
                            colors: [Color(red: 0.30, green: 0.20, blue: 0.60),
                                     Color(red: 0.55, green: 0.30, blue: 0.95)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 64, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 128, height: 128)
                    .clipShape(RoundedRectangle(cornerRadius: 28))
                    .padding(.top, 40)

                    Text("Telecmux")
                        .font(.largeTitle.bold())

                    Text("An iOS remote for cmux. Reach into your Mac's panes, see what your AI agents are waiting on, and answer in one tap.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    Divider()
                        .padding(.horizontal, 32)

                    VStack(alignment: .leading, spacing: 16) {
                        Label {
                            Text("Talks to cmux over SSH using its native CLI — no third party in the loop.")
                        } icon: {
                            Image(systemName: "lock.shield")
                                .foregroundStyle(.green)
                        }

                        Label {
                            Text("Open source so you can audit exactly what runs on your device and how your SSH credentials are handled.")
                        } icon: {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .foregroundStyle(.blue)
                        }

                        Label {
                            Text("Builds on cmux by manaflow.")
                        } icon: {
                            Image(systemName: "heart")
                                .foregroundStyle(.pink)
                        }
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 32)

                    Button {
                        dismiss()
                    } label: {
                        Text("Get Started")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal, 32)

                    Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 40)
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    static var hasSeenAbout: Bool {
        get { UserDefaults.standard.bool(forKey: "hasSeenAbout") }
        set { UserDefaults.standard.set(newValue, forKey: "hasSeenAbout") }
    }
}
