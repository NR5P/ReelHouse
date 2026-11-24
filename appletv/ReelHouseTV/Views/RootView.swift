import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: AppSection = .movies
    // Music & Podcasts: one player and speaker for the whole app, whichever tab is showing.
    @ObservedObject private var audio = AudioCenter.shared

    private var sections: [AppSection] {
        AppSection.visibleCases(moviesEnabled: model.moviesEnabled, musicEnabled: audio.musicEnabled,
                                podcastsEnabled: audio.podcastsEnabled)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Above the login screen as well as the main UI: "this server is too old" explains a
            // login that behaves oddly just as much as it explains an empty screen afterwards. It
            // renders nothing at all unless there's something to say.
            if model.isConfigured { ServerVersionBanner() }

            Group {
                if !model.isConfigured {
                    ServerSetupView()
                } else if model.requiresLogin || Self.debugShowsLogin {
                    LoginView()
                } else {
                    TabView(selection: $selection) {
                        ForEach(sections) { section in
                            tab(section)
                        }
                    }
                    // Rebuilt whenever the set of tabs changes. Adding tabs to a live TabView left
                    // the tvOS tab controller with pages it never showed: on the first launch after
                    // signing in (when only Settings is known until the server answers) the app sat
                    // on Settings, and every page, Settings included, drew as an empty backdrop.
                    .id(sections)
                    // A section switched off on the server takes its tab with it, and Settings -
                    // the only tab before the server has answered - gives way to the first real one.
                    .onChange(of: sections) { old, visible in
                        let onlyFallback = selection == .settings && old == [.settings]
                        if !visible.contains(selection) || onlyFallback, let first = visible.first { selection = first }
                    }
                    .onAppear {
                        if !sections.contains(selection), let first = sections.first { selection = first }
                        #if DEBUG
                        // Simulator testing without a remote: `-debugSection movies` as a launch argument.
                        if let name = UserDefaults.standard.string(forKey: "debugSection"),
                           let section = AppSection(rawValue: name) { selection = section }
                        DebugFocusWalker.startIfRequested()
                        #endif
                    }
                    // An announcement spoken while Now Playing is closed still shows its words.
                    .overlay { SpokenLineOverlay(hidden: audio.showNowPlaying) }
                    // Now Playing covers everything, opened from either audio tab, a speaker
                    // command or "Continue from…". Menu closes it; playback carries on.
                    .fullScreenCover(isPresented: $audio.showNowPlaying) {
                        NowPlayingTVView()
                            .environmentObject(audio)
                            .environmentObject(model)
                    }
                }
            }
        }
        // Full screen whatever is showing: the sign-in card alone sized this stack to itself, and
        // the backdrop drew as a box around it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { ReelHouseBackdrop() }
        .tint(ReelHouseTheme.gold)
        .buttonStyle(FocusContrastButtonStyle())
        .task(id: model.serverURL) {
            // Connection setup may replace a certificate-rejected HTTPS URL with HTTP. Keep it
            // alive when that state change invalidates this view task; connect owns its own
            // request cancellation and the replacement task will reuse the in-flight work.
            Task { await model.connect(resetNetworkSession: true) }
        }
        .environmentObject(audio)
        // Music & Podcasts follow the connection: tabs, the speaker heartbeat, "Continue from…".
        .task(id: "\(model.connectionState == .online)|\(model.activeServerURL)") {
            await audio.connect(model: model)
        }
    }

    // `-debugShowLogin YES`: the sign-in screen while still signed in, to check its look.
    #if DEBUG
    private static let debugShowsLogin = UserDefaults.standard.bool(forKey: "debugShowLogin")
    #else
    private static let debugShowsLogin = false
    #endif

    private func tab(_ section: AppSection) -> some View {
        NavigationStack {
            sectionView(section)
        }
        .formRowButtons(section == .settings)
        .tabItem { Label(section.title, systemImage: section.icon) }
        .tag(section)
    }

    @ViewBuilder private func sectionView(_ section: AppSection) -> some View {
        switch section {
        case .movies: MoviesTVView(isActive: selection == .movies)
        case .music: MusicTVView(isActive: selection == .music)
        case .podcasts: PodcastsTVView(isActive: selection == .podcasts)
        case .settings: SettingsView()
        }
    }
}

private extension View {
    // Settings (and the library admin it opens) is all Form rows, which already go white with a
    // dark label on focus and keep the green and red their titles are drawn in - so they keep the
    // platform's style rather than the app-wide FocusContrastButtonStyle.
    @ViewBuilder func formRowButtons(_ enabled: Bool) -> some View {
        // Plain labels too: a Form draws every button and toggle title in the tint, which made
        // half the Settings rows gold - the same gold that means "focused" everywhere else.
        if enabled { buttonStyle(FormRowButtonStyle()).tint(.primary) } else { self }
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case movies, music, podcasts, settings
    var id: Self { self }
    var title: String {
        switch self {
        case .movies: "Movies"
        case .music: "Music"
        case .podcasts: "Podcasts"
        case .settings: "Settings"
        }
    }
    var icon: String {
        switch self {
        case .movies: "film.stack"
        case .music: "music.note"
        case .podcasts: "antenna.radiowaves.left.and.right"
        case .settings: "gearshape.fill"
        }
    }

    // Movies & TV, Music and Podcasts can each be switched off server-side; Settings is always there.
    static func visibleCases(moviesEnabled: Bool, musicEnabled: Bool, podcastsEnabled: Bool) -> [AppSection] {
        allCases.filter {
            ($0 != .movies || moviesEnabled) && ($0 != .music || musicEnabled) && ($0 != .podcasts || podcastsEnabled)
        }
    }
}

// The wordmark: a popcorn bucket and REELHOUSE in heavy, wide-tracked caps, lit like a marquee.
// .fixedSize() keeps it on one line - tvOS's larger type sizes made the name wrap and
// hyphenate mid-word inside the narrower frame(maxWidth:) callers use to center it.
struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "popcorn.fill").foregroundStyle(ReelHouseTheme.curtain)
            Text("REELHOUSE")
                .fontWeight(.black)
                .tracking(6)
                .foregroundStyle(ReelHouseTheme.marquee)
        }
        .font(.title3)
        .shadow(color: ReelHouseTheme.gold.opacity(0.45), radius: 10)
        .fixedSize()
    }
}

// Advisory, never blocking - the app works normally behind it. Amber rather than red for that
// reason: this is "you'll want to update the server soon", not "something is broken". Collapses to
// nothing whenever the server is current, or when its version simply couldn't be read.
//
// Not focusable, and carries no button: an Apple TV is generally watched rather than operated, and
// there is nothing to do about this from the couch anyway - the fix is on the server.
struct ServerVersionBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let advisory = model.serverCompatibility.advisory {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(ReelHouseTheme.amber)
                Text(advisory)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 50)
            .padding(.vertical, 14)
            .background(ReelHouseTheme.amber.opacity(0.12))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Server version warning: \(advisory)")
        }
    }
}

struct ConnectionBadge: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .shadow(color: statusColor, radius: 5)
            Text(model.connectionState.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Server status: \(model.connectionState.label)")
    }

    private var statusColor: Color {
        switch model.connectionState {
        case .online: ReelHouseTheme.online
        case .checking, .authenticationRequired: ReelHouseTheme.amber
        case .offline: ReelHouseTheme.red
        case .notConfigured: .secondary
        }
    }
}
