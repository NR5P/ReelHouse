#if os(iOS)
import CarPlay
import UIKit

// CarPlay, in Apple's Audio category (com.apple.developer.carplay-audio): Music and Podcasts -
// browse, play, Now Playing. AudioPlayer already feeds MPNowPlayingInfoCenter and
// MPRemoteCommandCenter, which is what the CarPlay Now Playing screen reads and drives; this
// file only adds the browsing.
//
// The entitlement has to be granted by Apple per bundle id. Until it is added to the app's
// entitlements file, CarPlay never starts this scene and none of this runs.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        MainActor.assumeIsolated {
            CarPlayController.shared.connect(interfaceController)
        }
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        MainActor.assumeIsolated {
            CarPlayController.shared.disconnect()
        }
    }
}

@MainActor
final class CarPlayController: NSObject, CPNowPlayingTemplateObserver, CPTabBarTemplateDelegate, CPInterfaceControllerDelegate {
    static let shared = CarPlayController()

    private var interface: CPInterfaceController?
    private var model: AppModel { AppModel.shared }
    private var client: ReelHouseClient { model.client }
    private var player: AudioPlayer { AudioPlayer.shared }

    // Made afresh on every connect: a template belongs to the interface controller it was first
    // shown on, so one kept from an earlier connection (a wireless adapter that connects, drops
    // and reconnects while the car starts up) takes updates that never reach the car's screen,
    // which then says "Loading..." forever.
    private var musicTab = CPListTemplate(title: "Music", sections: [])
    private var podcastsTab = CPListTemplate(title: "Podcasts", sections: [])
    private var allTabs: [CPListTemplate] { [musicTab, podcastsTab] }
    private var pollTask: Task<Void, Never>?
    private var nowPlayingTask: Task<Void, Never>?

    func connect(_ interface: CPInterfaceController) {
        model.log("CarPlay connected (\(model.connectionState.label))")
        pollTask?.cancel()
        pollTask = nil
        self.interface = interface
        musicTab = CPListTemplate(title: "Music", sections: [])
        podcastsTab = CPListTemplate(title: "Podcasts", sections: [])
        musicTab.tabImage = UIImage(systemName: "music.note")
        podcastsTab.tabImage = UIImage(systemName: "mic")
        for tab in allTabs {
            tab.emptyViewTitleVariants = ["Loading\u{2026}"]
            show([], on: tab)
        }
        let root = CPTabBarTemplate(templates: [musicTab, podcastsTab])
        root.delegate = self
        tabBar = root
        interface.delegate = self
        configureNowPlaying()
        // Loading starts once the car has the tabs on screen. Sections set on the visible tab
        // before then were dropped: the first tab sat on "Loading" until another was picked.
        interface.setRootTemplate(root, animated: false) { [weak self] _, _ in
            MainActor.assumeIsolated {
                // CarPlay comes up with no tab selected at all - Music's list is drawn but isn't
                // the current tab, so it never refreshed until a tab was tapped. Pick Music.
                self?.selectMusicTab()
                if self?.pollTask == nil { self?.startPolling() }
            }
        }
        // Should the car never confirm, load anyway rather than show "Loading" for good.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.interface === interface, self.pollTask == nil else { return }
            self.selectMusicTab()
            self.startPolling()
        }
    }

    private var tabBar: CPTabBarTemplate?

    private func selectMusicTab() {
        guard let tabBar, tabBar.selectedTemplate !== musicTab else { return }
        tabBar.select(musicTab)
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            // Until connected, retried every 15 seconds - the car often comes up before the
            // phone has signal. Once connected, Music and Podcasts load once (re-read when their
            // tab is picked) and the loop ends.
            var audioLoaded = false
            while !Task.isCancelled, let self {
                guard await self.ready() else {
                    audioLoaded = false
                    try? await Task.sleep(for: .seconds(15))
                    continue
                }
                if !audioLoaded {
                    async let music: Void = self.loadMusic()
                    async let podcasts: Void = self.loadPodcasts()
                    _ = await (music, podcasts)
                    audioLoaded = true
                    // And once more a moment later, after the car has finished drawing.
                    try? await Task.sleep(for: .milliseconds(1500))
                    await self.reloadVisibleTab()
                }
                return
            }
        }
    }

    // Every tab update goes through here, and a tab is never left with no rows: "Loading" and
    // the other notices are a row of their own, not the empty-list text. CarPlay doesn't always
    // swap the empty-list text for rows on the first tab it draws - Music sat on "Loading" at
    // startup until another tab was tapped - while rows replacing rows always shows.
    private func show(_ sections: [CPListSection], on tab: CPListTemplate) {
        if sections.isEmpty {
            let notice = CPListItem(text: tab.emptyViewTitleVariants.first ?? "", detailText: nil)
            tab.updateSections([CPListSection(items: [notice])])
        } else {
            tab.updateSections(sections)
        }
    }

    // Re-reads the tab on screen with fresh rows - what tapping a tab does, which always worked.
    private func reloadVisibleTab() async {
        guard let shown = tabBar?.selectedTemplate else { return }
        if shown === musicTab { await loadMusic() }
        else if shown === podcastsTab { await loadPodcasts() }
    }

    // A tab coming on screen (the first one included, which no tab pick reports) is re-read.
    nonisolated func templateDidAppear(_ aTemplate: CPTemplate, animated: Bool) {
        MainActor.assumeIsolated {
            let shown = (aTemplate as? CPTabBarTemplate)?.selectedTemplate ?? aTemplate
            guard pollTask != nil else { return }
            Task {
                if shown === musicTab { await loadMusic() }
                else if shown === podcastsTab { await loadPodcasts() }
            }
        }
    }

    func disconnect() {
        model.log("CarPlay disconnected")
        pollTask?.cancel()
        nowPlayingTask?.cancel()
        interface = nil
    }

    func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        // A cheap re-read so "Up next" and "Recently played" follow what was played on the phone.
        Task {
            if selectedTemplate === musicTab { await loadMusic() }
            else if selectedTemplate === podcastsTab { await loadPodcasts() }
        }
    }

    // MARK: - Connection

    // CarPlay can be the first thing to launch the app (phone in a pocket), so nothing may have
    // connected yet. The wait is bounded: connect() loads the whole app,
    // each request with a 60-second timeout, and the car shouldn't sit on "Loading" through that.
    private func ready() async -> Bool {
        // `.online` is what connect() found, maybe at home before the drive started. Every request
        // re-picks the address when the home one stops answering (ReelHouseClient.withAddressRecovery),
        // but a screen showing stale rows sends nothing - so the address is looked at again here
        // every 30 seconds, falling through to a reconnect when nothing answers.
        if model.connectionState == .online, await model.confirmAddress() { return true }
        guard model.isConfigured else {
            showMessage("ReelHouse isn't set up yet. When it's safe, open it on your iPhone.")
            return false
        }
        // Unstructured, so the connection carries on (and the phone app gets it) if the wait
        // below gives up first. connect() coalesces with one already in flight.
        Task { await self.model.connect() }
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            if model.connectionState == .online { return true }
            if !model.isConnecting, model.connectionState != .checking { break }
        }
        model.log("CarPlay: not connected after 20s (\(model.connectionState.label)); retrying in 15s", level: .notice)
        showMessage(model.connectionState == .authenticationRequired
                    ? "Signed out. When it's safe, sign in on your iPhone."
                    : "Can't reach your ReelHouse server. Trying again\u{2026}")
        return false
    }

    // The empty-view text before the (empty) sections: CarPlay redraws on updateSections, so the
    // other order can leave the old text showing.
    private func showMessage(_ text: String) {
        for tab in allTabs {
            tab.emptyViewTitleVariants = [text]
            show([], on: tab)
        }
    }

    private var listLimit: Int { max(12, CPListTemplate.maximumItemCount) }

    // MARK: - Music

    private func loadMusic() async {
        let enabled = (try? await client.audioEnabled())?.music ?? model.musicEnabled
        guard enabled else {
            musicTab.emptyViewTitleVariants = ["Music is turned off on your server."]
            show([], on: musicTab)
            return
        }
        let home: MusicHome?
        do { home = try await client.musicHome() } catch {
            home = nil
            model.log("CarPlay: Music couldn't load: \(error.localizedDescription)", level: .error)
        }
        var sections: [CPListSection] = []

        let shuffle = item("Shuffle All", detail: "\(home?.trackCount ?? 0) songs", symbol: "shuffle") { [weak self] in
            self?.start { try await $0.client.musicShuffle() } play: { tracks, controller in
                controller.player.play(tracks: tracks, context: AudioPlayContext(type: "queue", id: "shuffle", name: "Shuffle All"))
            }
        }
        sections.append(CPListSection(items: [shuffle]))

        let recent = (home?.recentlyPlayed ?? []).prefix(6).compactMap { recentItem($0) }
        if !recent.isEmpty { sections.append(CPListSection(items: Array(recent), header: "Recently Played", sectionIndexTitle: nil)) }

        if let pinned = home?.pinned, !pinned.isEmpty {
            sections.append(CPListSection(items: pinned.prefix(6).map(playlistItem), header: "Pinned", sectionIndexTitle: nil))
        }

        let browse: [CPListItem] = [
            folder("Playlists", symbol: "music.note.list") { [weak self] in await self?.playlistsTemplate() },
            folder("Albums", symbol: "square.stack") { [weak self] in await self?.albumsTemplate() },
            folder("Artists", symbol: "music.mic") { [weak self] in await self?.artistsTemplate() },
            folder("Mixes", symbol: "dot.radiowaves.left.and.right") { [weak self] in await self?.mixesTemplate() },
            item("Loved Songs", symbol: "heart") { [weak self] in
                self?.start { try await $0.client.musicTracks(loved: true, limit: 500).items } play: { tracks, controller in
                    controller.player.play(tracks: tracks, context: AudioPlayContext(type: "queue", id: "loved", name: "Loved Songs"))
                }
            },
        ]
        sections.append(CPListSection(items: browse, header: "Library", sectionIndexTitle: nil))
        show(sections, on: musicTab)
        model.log("CarPlay: Music loaded (\(sections.count) sections)")
        if home == nil { musicTab.emptyViewTitleVariants = ["Can't reach your ReelHouse server."] }
    }

    private func recentItem(_ recent: MusicRecentItem) -> CPListItem? {
        if let album = recent.album { return albumItem(album) }
        if let playlist = recent.playlist { return playlistItem(playlist) }
        if let mix = recent.mix { return mixItem(mix) }
        if let artist = recent.artist { return artistItem(artist) }
        return nil
    }

    private func albumItem(_ album: MusicAlbum) -> CPListItem {
        let row = folder(album.title, detail: album.artist, art: album.artUrl) { [weak self] in
            await self?.albumTemplate(album)
        }
        return row
    }

    private func playlistItem(_ playlist: MusicPlaylist) -> CPListItem {
        folder(playlist.name, detail: playlist.trackCount.map { "\($0) songs" }, art: playlist.artUrls?.first) { [weak self] in
            await self?.playlistTemplate(playlist)
        }
    }

    private func mixItem(_ mix: MusicMix) -> CPListItem {
        item(mix.name, detail: "Mix", art: mix.artUrls?.first) { [weak self] in
            self?.start { try await $0.client.musicMix(id: mix.id).tracks } play: { tracks, controller in
                controller.player.play(tracks: tracks, context: AudioPlayContext(type: "mix", id: mix.id, name: mix.name))
            }
        }
    }

    private func artistItem(_ artist: MusicArtist) -> CPListItem {
        folder(artist.name, art: artist.artUrl) { [weak self] in await self?.artistTemplate(artist) }
    }

    private func playlistsTemplate() async -> CPTemplate {
        let playlists = (try? await client.musicPlaylists()) ?? []
        return list("Playlists", playlists.prefix(listLimit).map(playlistItem), empty: "No playlists yet.")
    }

    private func albumsTemplate() async -> CPTemplate {
        let albums = (try? await client.musicAlbums(limit: listLimit))?.items ?? []
        return list("Albums", albums.map(albumItem), empty: "No albums yet.")
    }

    private func artistsTemplate() async -> CPTemplate {
        let artists = (try? await client.musicArtists(albumArtistsOnly: true, limit: listLimit))?.items ?? []
        return list("Artists", artists.map(artistItem), empty: "No artists yet.")
    }

    private func mixesTemplate() async -> CPTemplate {
        let mixes = (try? await client.musicHome())?.mixes ?? []
        return list("Mixes", mixes.prefix(listLimit).map(mixItem), empty: "No mixes yet.")
    }

    private func artistTemplate(_ artist: MusicArtist) async -> CPTemplate {
        let detail = try? await client.musicArtist(id: artist.id)
        var sections: [CPListSection] = []
        let radio = item("\(artist.name) Radio", symbol: "dot.radiowaves.left.and.right") { [weak self] in
            self?.start { try await $0.client.musicRadio(seedType: "artist", seedId: artist.id).tracks } play: { tracks, controller in
                controller.player.play(tracks: tracks, context: AudioPlayContext(type: "radio", id: "artist:\(artist.id)", name: "\(artist.name) Radio"))
            }
        }
        sections.append(CPListSection(items: [radio]))
        if let top = detail?.topTracks, !top.isEmpty {
            sections.append(CPListSection(items: trackItems(Array(top.prefix(5)), context: AudioPlayContext(type: "artist", id: artist.id, name: artist.name)),
                                          header: "Top Songs", sectionIndexTitle: nil))
        }
        if let albums = detail?.albums, !albums.isEmpty {
            sections.append(CPListSection(items: albums.prefix(listLimit).map(albumItem), header: "Albums", sectionIndexTitle: nil))
        }
        return CPListTemplate(title: artist.name, sections: sections)
    }

    private func albumTemplate(_ album: MusicAlbum) async -> CPTemplate {
        let tracks = (try? await client.musicAlbum(id: album.id))?.tracks ?? []
        let context = AudioPlayContext(type: "album", id: album.id, name: album.title)
        return trackList(album.title, tracks, context: context)
    }

    private func playlistTemplate(_ playlist: MusicPlaylist) async -> CPTemplate {
        let tracks = (try? await client.musicPlaylist(id: playlist.id))?.tracks ?? []
        let context = AudioPlayContext(type: "playlist", id: playlist.id, name: playlist.name)
        return trackList(playlist.name, tracks, context: context)
    }

    private func trackList(_ title: String, _ tracks: [MusicTrack], context: AudioPlayContext) -> CPTemplate {
        guard !tracks.isEmpty else { return list(title, [], empty: "Nothing to play.") }
        let shuffle = item("Shuffle", symbol: "shuffle") { [weak self] in
            self?.player.play(tracks: tracks, context: context, shuffle: true)
            self?.showNowPlaying()
        }
        return CPListTemplate(title: title, sections: [
            CPListSection(items: [shuffle]),
            CPListSection(items: trackItems(Array(tracks.prefix(listLimit)), all: tracks, context: context)),
        ])
    }

    private func trackItems(_ shown: [MusicTrack], all: [MusicTrack]? = nil, context: AudioPlayContext) -> [CPListItem] {
        let queue = all ?? shown
        return shown.enumerated().map { index, track in
            let row = item(track.title, detail: track.artistLine, art: track.artUrl) { [weak self] in
                self?.player.play(tracks: queue, startAt: index, context: context)
                self?.showNowPlaying()
            }
            row.isPlaying = player.current?.track?.id == track.id
            return row
        }
    }

    // MARK: - Podcasts

    private func loadPodcasts() async {
        let enabled = (try? await client.audioEnabled())?.podcasts ?? model.podcastsEnabled
        guard enabled else {
            podcastsTab.emptyViewTitleVariants = ["Podcasts are turned off on your server."]
            show([], on: podcastsTab)
            return
        }
        let loaded: PodcastHome?
        do { loaded = try await client.podcastHome() } catch {
            loaded = nil
            model.log("CarPlay: Podcasts couldn't load: \(error.localizedDescription)", level: .error)
        }
        guard let home = loaded else {
            podcastsTab.emptyViewTitleVariants = ["Can't reach your ReelHouse server."]
            show([], on: podcastsTab)
            return
        }
        var sections: [CPListSection] = []
        let upNext = home.upNext ?? []
        if !upNext.isEmpty {
            sections.append(CPListSection(items: episodeItems(Array(upNext.prefix(8)), queue: upNext,
                                                              context: AudioPlayContext(type: "queue", id: "upnext", name: "Up Next")),
                                          header: "Up Next", sectionIndexTitle: nil))
        }
        let continuing = (home.continueListening ?? []).filter { e in !upNext.contains { $0.id == e.id } }
        if !continuing.isEmpty {
            sections.append(CPListSection(items: episodeItems(Array(continuing.prefix(5)), queue: continuing, context: nil),
                                          header: "Continue Listening", sectionIndexTitle: nil))
        }
        let newest = home.newEpisodes ?? []
        if !newest.isEmpty {
            sections.append(CPListSection(items: episodeItems(Array(newest.prefix(8)), queue: newest, context: nil),
                                          header: "New Episodes", sectionIndexTitle: nil))
        }
        let shows = home.subscriptions ?? []
        if !shows.isEmpty {
            sections.append(CPListSection(items: shows.prefix(listLimit).map(showItem), header: "Shows", sectionIndexTitle: nil))
        }
        podcastsTab.emptyViewTitleVariants = ["No podcasts yet. Subscribe on your phone."]
        show(sections, on: podcastsTab)
    }

    private func showItem(_ show: Podcast) -> CPListItem {
        let detail = (show.unplayedCount ?? 0) > 0 ? "\(show.unplayedCount ?? 0) unplayed" : show.author
        return folder(show.title, detail: detail, art: show.artUrl) { [weak self] in
            guard let self else { return nil }
            let episodes = (try? await self.client.podcastEpisodes(id: show.id, sort: nil, filter: nil, q: nil, season: nil, limit: self.listLimit))?.items ?? []
            return self.list(show.title,
                             self.episodeItems(episodes, queue: episodes, context: AudioPlayContext(type: "podcast", id: show.id, name: show.title)),
                             empty: "No episodes yet.")
        }
    }

    private func episodeItems(_ shown: [PodcastEpisode], queue: [PodcastEpisode], context: AudioPlayContext?) -> [CPListItem] {
        shown.map { episode in
            let detail = [episode.podcastTitle, episode.remainingLabel].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            let row = item(episode.title, detail: detail, art: episode.artUrl) { [weak self] in
                guard let self else { return }
                let rest = queue.drop { $0.id != episode.id }.dropFirst()
                self.player.play(episode: episode, queue: Array(rest), context: context)
                self.showNowPlaying()
            }
            if episode.isInProgress, let progress = episode.progress, let position = progress.positionSeconds,
               let duration = episode.durationSeconds, duration > 0 {
                row.playbackProgress = CGFloat(min(1, position / duration))
            }
            row.isPlaying = player.current?.episode?.id == episode.id
            return row
        }
    }

    // MARK: - Now Playing

    private func configureNowPlaying() {
        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.isUpNextButtonEnabled = true
        nowPlaying.upNextTitle = "Up Next"
        nowPlaying.isAlbumArtistButtonEnabled = false
        nowPlaying.add(self)
        // Music gets shuffle and repeat; podcasts get the speed button. Follows the player.
        nowPlayingTask?.cancel()
        nowPlayingTask = Task { [weak self] in
            var lastEpisode: Bool?
            while !Task.isCancelled, let self {
                let isEpisode = self.player.isEpisode
                if isEpisode != lastEpisode {
                    lastEpisode = isEpisode
                    self.updateNowPlayingButtons(episode: isEpisode)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func updateNowPlayingButtons(episode: Bool) {
        let buttons: [CPNowPlayingButton]
        if episode {
            buttons = [CPNowPlayingPlaybackRateButton { _ in
                MainActor.assumeIsolated {
                    let speeds: [Double] = [1, 1.25, 1.5, 2, 0.8]
                    let now = AudioPlayer.shared.speed
                    let next = speeds.first { $0 > now + 0.01 } ?? speeds[0]
                    AudioPlayer.shared.setSpeed(next == 0.8 && now < 1 ? 1 : next)
                }
            }]
        } else {
            buttons = [
                CPNowPlayingShuffleButton { _ in MainActor.assumeIsolated { AudioPlayer.shared.toggleShuffle() } },
                CPNowPlayingRepeatButton { _ in MainActor.assumeIsolated { AudioPlayer.shared.cycleRepeat() } },
            ]
        }
        CPNowPlayingTemplate.shared.updateNowPlayingButtons(buttons)
    }

    // Now Playing goes straight on top of the tab bar, whatever was browsed to get there - the
    // way Apple's own audio apps do it, and it keeps the stack inside the depth limit below.
    private func showNowPlaying() {
        guard let interface else { return }
        if interface.topTemplate === CPNowPlayingTemplate.shared { return }
        if interface.templates.count > 1 {
            interface.popToRootTemplate(animated: false, completion: nil)
        }
        interface.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    // CarPlay ends the app (clientExceededHierarchyDepthLimit) once the stack gets deeper than
    // its category allows. With the Driving Task entitlement that is three templates, the tab
    // bar included - stricter than Audio's five, and it applies to the music browsing too.
    // So at the limit the top list is swapped for the new one instead of stacked on it: Artists,
    // an artist, then an album shows Artists -> the album, and Back still makes sense.
    static let maximumDepth = 3

    private func push(_ template: CPTemplate) {
        guard let interface else { return }
        if interface.templates.count >= Self.maximumDepth {
            interface.popTemplate(animated: false, completion: nil)
        }
        interface.pushTemplate(template, animated: true, completion: nil)
    }

    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        MainActor.assumeIsolated {
            let start = player.index
            let items = player.queue.enumerated().dropFirst(start).prefix(listLimit).map { offset, entry in
                let row = item(entry.title, detail: entry.subtitle, art: entry.artPath) { [weak self] in
                    self?.player.jump(to: offset)
                    self?.interface?.popTemplate(animated: true, completion: nil)
                }
                row.isPlaying = offset == start
                return row
            }
            push(list("Up Next", Array(items), empty: "Nothing queued."))
        }
    }

    nonisolated func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {}

    // MARK: - Building blocks

    private func list(_ title: String, _ items: [CPListItem], empty: String) -> CPListTemplate {
        let template = CPListTemplate(title: title, sections: [CPListSection(items: items)])
        template.emptyViewTitleVariants = [empty]
        return template
    }

    private func item(_ text: String, detail: String? = nil, art: String? = nil, symbol: String? = nil,
                      action: @escaping @MainActor () -> Void) -> CPListItem {
        let row = CPListItem(text: text, detailText: detail, image: symbol.flatMap { UIImage(systemName: $0) })
        row.handler = { _, completion in
            MainActor.assumeIsolated { action() }
            completion()
        }
        loadArt(art, into: row)
        return row
    }

    // A row that opens another list. The list is fetched before it's pushed, with the row's
    // spinner showing meanwhile (CarPlay shows it until the completion is called).
    private func folder(_ text: String, detail: String? = nil, art: String? = nil, symbol: String? = nil,
                        next: @escaping @MainActor () async -> CPTemplate?) -> CPListItem {
        let row = CPListItem(text: text, detailText: detail, image: symbol.flatMap { UIImage(systemName: $0) },
                             accessoryImage: nil, accessoryType: .disclosureIndicator)
        row.handler = { [weak self] _, completion in
            MainActor.assumeIsolated {
                Task { @MainActor in
                    if let template = await next() {
                        self?.push(template)
                    }
                    completion()
                }
            }
        }
        loadArt(art, into: row)
        return row
    }

    private func loadArt(_ path: String?, into row: CPListItem) {
        guard let path, let url = client.audioArtURL(path, size: 120) else { return }
        Task { @MainActor in
            if let cg = await ArtworkLoader.cgImage(url, maxPixel: 120) {
                row.setImage(UIImage(cgImage: cg))
            }
        }
    }

    // Load-then-play for things that need a fetch first (shuffle, mixes, loved songs).
    private func start<T>(_ fetch: @escaping @MainActor (CarPlayController) async throws -> [T],
                          play: @escaping @MainActor ([T], CarPlayController) -> Void) {
        Task { @MainActor in
            do {
                let items = try await fetch(self)
                guard !items.isEmpty else { return alert("Nothing to play yet.") }
                play(items, self)
                showNowPlaying()
            } catch {
                alert("Couldn't start that. Can't reach your ReelHouse server.")
            }
        }
    }

    private func alert(_ text: String) {
        guard let interface else { return }
        let ok = CPAlertAction(title: "OK", style: .cancel) { _ in
            MainActor.assumeIsolated { CarPlayController.shared.interface?.dismissTemplate(animated: true, completion: nil) }
        }
        let template = CPAlertTemplate(titleVariants: [text], actions: [ok])
        if interface.presentedTemplate != nil {
            interface.dismissTemplate(animated: false, completion: nil)
        }
        interface.presentTemplate(template, animated: true, completion: nil)
        // Confirmations clear themselves; nobody should have to tap OK at a light.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if interface.presentedTemplate === template {
                interface.dismissTemplate(animated: true, completion: nil)
            }
        }
    }
}
#endif
