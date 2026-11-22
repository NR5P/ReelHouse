import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: AppSection? = .movies
    @State private var morePath: [AppSection] = []
    @AppStorage(TabBarLayout.storageKey) private var tabBarSections = ""
    @State private var editingTabBar = false

    var body: some View {
        VStack(spacing: 0) {
            // Above the login screen as well as the main UI: "this server is too old" explains a
            // login that behaves oddly just as much as it explains an empty screen afterwards. It
            // renders nothing at all unless there's something to say.
            if model.isConfigured { ServerVersionBanner() }

            Group {
                if !model.isConfigured {
                    ServerSetupView()
                } else if model.requiresLogin {
                    LoginView()
                } else {
                    if horizontalSizeClass == .compact {
                        compactNavigation
                    } else {
                        splitNavigation
                    }
                }
            }
        }
        .tint(ReelHouseTheme.gold)
        // Reconnect whenever setup/settings changes the address. Keeping this task on the
        // persistent root normally prevents SwiftUI from cancelling it when a child disappears.
        // macOS can still recreate this root modifier while switching split-view sections,
        // though, which used to cancel an in-flight refresh after several successful requests
        // and leave connectionState stuck offline/checking. The unstructured task deliberately
        // outlives that transient view update; AppModel's isConnecting guard coalesces any
        // duplicate trigger produced by the replacement view.
        .task(id: model.serverURL) {
            Task { await model.connect(resetNetworkSession: true) }
        }
        #if os(iOS)
        // Push notifications: permission and registration once signed in (online means signed
        // in, or a server with no login), and a tapped notification opened once the server is
        // there to load what it names.
        .task(id: model.connectionState == .online) {
            await model.startPushNotifications()
        }
        .onChange(of: model.connectionState == .online ? model.pendingPushRoute : nil, initial: true) { _, route in
            guard let route else { return }
            model.pendingPushRoute = nil
            openPush(route)
        }
        #endif
        // A section switched off on the server while it was selected (or the remembered default
        // on a server without it): fall back to the first one that exists.
        .onChange(of: visibleSections) { _, visible in
            if let selection, !visible.contains(selection) { self.selection = visible.first }
        }
        .onAppear {
            if let selection, !visibleSections.contains(selection) { self.selection = visibleSections.first }
        }
        // The Now Playing sheet, and "Go to Album" / "Go to Show" from the player above every tab.
        .modifier(AudioRootPresenter(selection: $selection))
        #if DEBUG
        // Simulator testing without taps: `-debugSection music` as a launch argument, like the
        // Apple TV app's.
        .onAppear {
            if let name = UserDefaults.standard.string(forKey: "debugSection"),
               let section = AppSection(rawValue: name) { selection = section }
        }
        #endif
        // Again, outside the sheets attached above: the .tint at the top only reaches views
        // inside it, so Add to Playlist came up in the system blue.
        .tint(ReelHouseTheme.gold)
    }

    private var splitNavigation: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                BrandHeader()
                List(visibleSections, selection: $selection) { section in
                    Label(section.title, systemImage: section.icon)
                        .tag(section)
                }
                .listStyle(.sidebar)

                ConnectionBadge()
                    .padding()
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            NavigationStack {
                sectionView(selection ?? visibleSections.first ?? .settings)
            }
            .audioMiniPlayer()
        }
    }

    private var compactLayout: TabBarLayout {
        TabBarLayout(pinned: TabBarLayout.decode(tabBarSections), visible: visibleSections)
    }

    private var visibleSections: [AppSection] {
        AppSection.visibleCases(
            moviesEnabled: model.moviesEnabled, musicEnabled: model.musicEnabled,
            podcastsEnabled: model.podcastsEnabled)
    }

    private var compactNavigation: some View {
        let layout = compactLayout
        return TabView(selection: compactSelection) {
            ForEach(layout.bar) { section in
                NavigationStack {
                    sectionView(section)
                }
                .audioMiniPlayer()
                .tabItem { Label(section.title, systemImage: section.icon) }
                .tag(CompactTab.section(section))
            }
            if layout.showsMore {
                NavigationStack(path: $morePath) {
                    MoreSectionsView(sections: layout.more) { editingTabBar = true }
                        .navigationDestination(for: AppSection.self) { section in
                            sectionView(section)
                        }
                }
                .audioMiniPlayer()
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
                .tag(CompactTab.more)
            }
        }
        // Changing which tabs exist in place leaves UIKit's tab controller showing a blank page
        // for the selected one, so a new bar is a new TabView.
        .id(layout.bar)
        .sheet(isPresented: $editingTabBar) {
            NavigationStack { TabBarEditor(visible: visibleSections, inSheet: true) }
        }
        // `selection` stays the one answer to "which section is on screen", on the tab bar and
        // in the sidebar alike. A section without a tab is on screen when it is pushed on More,
        // so whatever sends the app to one ("Go to Album" from the player) lands there.
        .onChange(of: selection) { _, section in showUnderMoreIfNeeded(section) }
        .onChange(of: layout) { _, _ in showUnderMoreIfNeeded(selection) }
        .onAppear { showUnderMoreIfNeeded(selection) }
        .onChange(of: morePath) { _, path in
            // Only while More is the tab on screen - a section with a tab owns `selection` then.
            if selection.map({ !compactLayout.bar.contains($0) }) ?? true {
                selection = path.last
            }
        }
    }

    private func showUnderMoreIfNeeded(_ section: AppSection?) {
        let layout = compactLayout
        guard let section, !layout.bar.contains(section) else { return }
        if layout.more.contains(section) {
            if morePath.last != section { morePath = [section] }
        } else {
            // Switched off server-side while it was on screen.
            selection = layout.bar.first
        }
    }

    private var compactSelection: Binding<CompactTab> {
        Binding(
            get: {
                if let selection, compactLayout.bar.contains(selection) { return .section(selection) }
                return .more
            },
            set: { tab in
                switch tab {
                case .section(let section): selection = section
                case .more: selection = morePath.last
                }
            }
        )
    }

    #if os(iOS)
    // A new episode opens the episode (its page links to the show); a finished download opens
    // the item's detail page. Both go through the routers the player's "Go to Show" uses.
    private func openPush(_ route: PushRoute) {
        AudioPlayer.shared.showNowPlaying = false
        switch route {
        case .podcast(let podcastId, let episodeId):
            if let episodeId {
                AudioRouter.shared.open(.episode(episodeId))
            } else if let podcastId {
                AudioRouter.shared.open(.show(podcastId))
            } else {
                selection = .podcasts
            }
        case .download(let itemId):
            if let itemId { MediaRouter.shared.route = MediaRoute(id: itemId, title: "Movies & TV") }
            selection = .movies
        }
    }
    #endif

    @ViewBuilder private func sectionView(_ section: AppSection) -> some View {
        switch section {
        case .movies: MoviesView(isActive: selection == .movies)
        case .music: MusicView(isActive: selection == .music)
        case .podcasts: PodcastsView(isActive: selection == .podcasts)
        case .settings: SettingsView()
        }
    }
}

private enum CompactTab: Hashable {
    case section(AppSection)
    case more
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
        case .podcasts: "mic.fill"
        case .settings: "gearshape.fill"
        }
    }

    // Movies & TV, Music and Podcasts can each be switched off server-side, so every list of
    // sections is filtered rather than using allCases directly. Which of these get a tab on an
    // iPhone is up to the person - see TabBarLayout. The same list is the sidebar on iPad and Mac.
    static func visibleCases(moviesEnabled: Bool, musicEnabled: Bool, podcastsEnabled: Bool) -> [AppSection] {
        allCases.filter {
            ($0 != .movies || moviesEnabled) && ($0 != .music || musicEnabled)
                && ($0 != .podcasts || podcastsEnabled)
        }
    }
}

// The wordmark: a popcorn bucket and REELHOUSE in heavy, wide-tracked caps, lit like a marquee.
struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "popcorn.fill").foregroundStyle(ReelHouseTheme.curtain)
            Text("REELHOUSE")
                .fontWeight(.black)
                .tracking(4)
                .foregroundStyle(ReelHouseTheme.marquee)
            Spacer()
        }
        .font(.title3)
        .shadow(color: ReelHouseTheme.gold.opacity(0.45), radius: 8)
        .padding()
    }
}

// Advisory, never blocking - the app works normally behind it. Amber rather than red for that
// reason: this is "you'll want to update the server soon", not "something is broken". Collapses to
// nothing whenever the server is current, or when its version simply couldn't be read.
struct ServerVersionBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let advisory = model.serverCompatibility.advisory {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(ReelHouseTheme.amber)
                Text(advisory)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
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
                .frame(width: 8, height: 8)
                .shadow(color: statusColor, radius: 5)
            Text(model.connectionState.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Server status: \(model.connectionState.label)")
    }

    private var statusColor: Color {
        switch model.connectionState {
        case .online: ReelHouseTheme.gold
        case .checking, .authenticationRequired: ReelHouseTheme.amber
        case .offline: ReelHouseTheme.red
        case .notConfigured: .secondary
        }
    }
}
