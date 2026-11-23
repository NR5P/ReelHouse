import SwiftUI

// Server address, sign-in status, the movie libraries, the audio settings and a connection log.
// Account administration stays on the web dashboard, where typing is practical.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var address = ""
    @State private var showingDiagnostics = false
    // Set when a new address didn't answer and the old one was put back.
    @State private var addressNotice: String?

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
                    Task { await switchServer(to: normalized(address)) }
                }
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let addressNotice {
                    Text(addressNotice)
                        .font(.caption)
                        .foregroundStyle(ReelHouseTheme.red)
                }
                // The servers discovery found, one click each - the way back from a mistyped
                // address without typing on the TV again.
                ForEach(model.discoveredServers.filter { $0.addressString != model.serverURL }) { server in
                    Button {
                        address = server.addressString
                        Task { await switchServer(to: server.addressString) }
                    } label: {
                        LabeledContent("Use \(server.name)", value: server.addressString)
                    }
                }
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
            // Focusable so the remote can reach it: a tvOS list only scrolls as far as the last
            // row that can take focus, and plain text can't.
            Section("About") {
                LabeledContent("App Version", value: Self.appVersion)
                    .focusable()
                Text("Movie and TV descriptions and artwork: The Movie Database (themoviedb.org). This product uses the TMDB API but is not endorsed or certified by TMDB.")
                    .font(.caption)
                    .focusable()
                Text("Music details and cover art: MusicBrainz, Cover Art Archive and Apple's iTunes Search; suggestions: ListenBrainz; lyrics: LRCLIB.")
                    .font(.caption)
                    .focusable()
                Text("ReelHouse is an independent project, not affiliated with any media company or service named in the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .focusable()
            }

            Section {
                Text("This Apple TV client manages its own connection. Accounts are managed from the ReelHouse web dashboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .focusable()
            }
        }
        .onAppear {
            address = model.serverURL
        }
        .onChange(of: model.serverURL) { _, newValue in address = newValue }
    }

    private func normalized(_ value: String) -> String { ServerSetupView.normalizedAddress(value) }

    // Tries `newAddress`; if nothing answers there and the old address was different, the old
    // one comes back rather than leaving the TV with a typo and nothing but this Settings tab.
    // A server that answers at all - even asking for a sign-in - counts as found.
    private func switchServer(to newAddress: String) async {
        let previous = model.serverURL
        addressNotice = nil
        // The way past a server whose certificate authority changed - see ServerIdentity.
        ServerIdentity.forget(newAddress)
        model.serverURL = newAddress
        await model.connect(resetNetworkSession: true)
        guard model.connectionState == .offline, !previous.isEmpty, previous != newAddress else { return }
        let reason = model.lastError ?? "No ReelHouse server answered."
        model.serverURL = previous
        address = previous
        await model.connect(resetNetworkSession: true)
        addressNotice = "Couldn't reach \(newAddress) (\(reason)) Still using \(previous)."
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
