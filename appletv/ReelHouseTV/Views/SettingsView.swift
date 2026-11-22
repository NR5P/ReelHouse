import SwiftUI

// Server address, sign-in status, the movie libraries, the audio settings and a connection log.
// Account administration stays on the web dashboard, where typing is practical.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var address = ""
    @State private var showingDiagnostics = false

    var body: some View {
        #if DEBUG
        // Simulator testing without a remote: `-debugSection settings -debugSettingsPage
        // mediaLibraries` (or `folderPicker`) shows that screen in place of Settings.
        if let page = UserDefaults.standard.string(forKey: "debugSettingsPage") {
            if page == "folderPicker" {
                MediaFolderPickerView(path: .constant(""))
            } else if page == "music" {
                MusicSettingsTV()
            } else if page == "podcasts" {
                PodcastSettingsTV()
            } else if page == "speaker" {
                AudioPlaybackSettingsTV()
            } else if page == "audioFolderPicker" {
                AudioFolderPickerTV(path: .constant(""), noun: "music")
            } else {
                MediaLibrariesAdminView()
            }
        } else {
            settingsForm
        }
        #else
        settingsForm
        #endif
    }

    private var settingsForm: some View {
        Form {
            Section("Server") {
                TextField("Server address", text: $address)
                HStack {
                    Text("Status")
                    Spacer()
                    ConnectionBadge()
                }
                Button("Save and Reconnect") {
                    Task {
                        // The way past a server whose certificate authority changed - see ServerIdentity.
                        ServerIdentity.forget(normalized(address))
                        model.serverURL = normalized(address)
                        await model.connect(resetNetworkSession: true)
                    }
                }
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section("Account") {
                if let username = model.authStatus?.username {
                    LabeledContent("Signed in as", value: username)
                }
                if let role = model.authStatus?.role {
                    LabeledContent("Role", value: role.capitalized)
                }
                if model.authStatus?.enabled == true {
                    Button("Sign Out", role: .destructive) {
                        Task { await model.signOut() }
                    }
                } else {
                    Text("Dashboard login is not enabled.")
                        .foregroundStyle(.secondary)
                }
            }

            if let lastError = model.lastError {
                Section("System") {
                    Text(lastError).foregroundStyle(ReelHouseTheme.red)
                }
            }

            // The one piece of server management kept on the TV: the movie folders, since this is
            // where the family watches them. Typing goes through the system keyboard (or the
            // iPhone's Apple TV Remote keyboard).
            if model.isAdmin {
                Section("Movies & TV") {
                    NavigationLink("Movies & TV Libraries") {
                        MediaLibrariesAdminView()
                    }
                }
            }

            // "Let others play here", this TV's playback preferences, and (admin) the server's
            // MUSIC and PODCASTS settings with Music → Libraries and Podcasts → Download folder.
            AudioSettingsGroup()

            // DisclosureGroup isn't available on tvOS - a plain toggle button standing in for
            // the expand/collapse chevron.
            Section("Diagnostics") {
                Button(showingDiagnostics ? "Hide Connection Log" : "Show Connection Log") {
                    showingDiagnostics.toggle()
                }
                if showingDiagnostics {
                    if model.diagnostics.isEmpty {
                        Text("No requests recorded yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.diagnostics.prefix(30)) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(entry.level.rawValue)
                                        .foregroundStyle(entry.level == .error ? ReelHouseTheme.red : ReelHouseTheme.curtain)
                                    Spacer()
                                    Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                        .foregroundStyle(.secondary)
                                }
                                .font(.caption2)
                                Text(entry.message)
                                    .font(.caption)
                            }
                            .fontDesign(.monospaced)
                        }
                    }
                    Button("Clear Log") { model.clearDiagnostics() }
                }
                Text("Request bodies, passwords, cookies, and server response contents are never written here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Credits, as on the iPhone's Acknowledgements screen (AcknowledgementsView.swift). A TV
            // can't open links, so the sites are named instead. TMDB's terms ask for its notice
            // wherever its data is shown.
            Section("About") {
                LabeledContent("App Version", value: Self.appVersion)
                Text("Movie and TV descriptions and artwork: The Movie Database (themoviedb.org). This product uses the TMDB API but is not endorsed or certified by TMDB.")
                    .font(.caption)
                Text("Music details and cover art: MusicBrainz and Cover Art Archive; suggestions: ListenBrainz; lyrics: LRCLIB.")
                    .font(.caption)
                Text("ReelHouse is an independent project, not affiliated with any media company or service named in the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("This Apple TV client manages its own connection. Accounts are managed from the ReelHouse web dashboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            address = model.serverURL
        }
        .onChange(of: model.serverURL) { _, newValue in address = newValue }
    }

    private func normalized(_ value: String) -> String { ServerSetupView.normalizedAddress(value) }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
