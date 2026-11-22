import Foundation

@MainActor
final class ReelHouseClient {
    private unowned let model: AppModel
    private var session: URLSession

    init(model: AppModel) {
        self.model = model
        session = Self.makeSession()
    }

    // For the parts of the app that talk to the server through this client but live outside a
    // view, so their diagnostics land in the same Settings log as requests do.
    func log(_ message: String, level: DiagnosticLevel = .info) {
        model.log(message, level: level)
    }

    // Separate from `session` only for its timeouts: the main session gives up on any request
    // after 15 seconds, which would cut off the speakers' long poll, slow playback starts and
    // any upload bigger than a few megabytes. Same shared cookie storage, so it is signed in
    // exactly when the rest of the app is.
    lazy var transferSession: URLSession = Self.makeTransferSession()

    private static func makeTransferSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = .shared
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    func resetSession() {
        let retired = [session, transferSession]
        session = Self.makeSession()
        transferSession = Self.makeTransferSession()
        // Cancel what's in flight now, but invalidate later. URLSession.data(for:) leaves the
        // main actor before it creates its task, so a poll that picked up the old session just
        // before this ran creates its task a moment afterwards - and creating a task in an
        // invalidated session raises an Objective-C exception, which kills the app instead of
        // throwing (seen: a background poll during an offline reconnect).
        for old in retired {
            old.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        }
        Task {
            try? await Task.sleep(for: .seconds(30))
            for old in retired { old.invalidateAndCancel() }
        }
        model.log("Created a fresh network session")
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = .shared
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        // This client only targets a server on the current LAN. Waiting for a network path
        // can leave the UI in CONNECTING for the full resource timeout when that host is
        // powered off or the Mac/device is on a different network. Fail promptly so the
        // user gets LINK LOST and can retry as soon as the server is available.
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    func authStatus() async throws -> AuthStatus {
        try await get("/api/auth/status")
    }

    // Unauthenticated on the server side, so this is readable at the login screen too - which is
    // where knowing the server is too old is arguably most useful.
    func serverHealth() async throws -> ServerHealth {
        try await get("/api/health")
    }

    func accounts() async throws -> [Account] {
        try await get("/api/accounts")
    }

    func createAccount(username: String, password: String, role: String, displayName: String?) async throws -> Account {
        try await send(
            "/api/accounts",
            method: "POST",
            body: CreateAccountBody(username: username, password: password, role: role, displayName: displayName)
        )
    }

    func updateAccountRole(id: UUID, role: String) async throws {
        let _: EmptyResponse = try await send(
            "/api/accounts/\(id.uuidString)/role",
            method: "PUT",
            body: UpdateRoleBody(role: role)
        )
    }

    func resetAccountPassword(id: UUID, newPassword: String) async throws {
        let _: EmptyResponse = try await send(
            "/api/accounts/\(id.uuidString)/reset-password",
            method: "POST",
            body: ResetPasswordBody(newPassword: newPassword)
        )
    }

    func deleteAccount(id: UUID) async throws {
        let _: EmptyResponse = try await send(
            "/api/accounts/\(id.uuidString)",
            method: "DELETE",
            body: Optional<String>.none
        )
    }

    // The server deliberately leaves the current session alone (doesn't invalidate it) - no
    // separate re-login needed here, the existing cookie just keeps working.
    func changeMyPassword(currentPassword: String, newPassword: String) async throws {
        let _: EmptyResponse = try await send(
            "/api/accounts/change-password",
            method: "POST",
            body: ChangePasswordBody(currentPassword: currentPassword, newPassword: newPassword)
        )
    }

    func login(username: String, password: String) async throws {
        let _: EmptyResponse = try await send(
            "/api/auth/login",
            method: "POST",
            body: LoginBody(username: username, password: password)
        )
    }

    func logout() async throws {
        let _: EmptyResponse = try await send("/api/auth/logout", method: "POST", body: Optional<String>.none)
    }

    // MARK: Push notifications (signed-in session required)

    func pushStatus() async throws -> PushStatus {
        try await get("/api/push/status")
    }

    func registerPushDevice(token: String, deviceName: String, apnsSandbox: Bool) async throws {
        let _: EmptyResponse = try await send(
            "/api/push/devices",
            method: "POST",
            body: PushDeviceBody(
                platform: "apple", token: token, deviceName: deviceName, appVariant: "ios", apnsSandbox: apnsSandbox)
        )
    }

    func unregisterPushDevice(token: String) async throws {
        let _: EmptyResponse = try await send(
            "/api/push/devices/unregister",
            method: "POST",
            body: PushDeviceBody(platform: "apple", token: token)
        )
    }

    // Sends to this account's own devices; a 400 carries the server's reason (push off, no
    // devices registered, APNs not configured) as ClientError.server's message.
    func testPushNotification() async throws -> PushDeliveryReport {
        try await send("/api/push/test", method: "POST", body: Optional<String>.none)
    }

    // Turning the dashboard's login requirement on creates the first admin account in the same
    // step - there is deliberately no way to require a login with nobody able to satisfy it.
    func enableServerLogin(username: String, password: String) async throws {
        let _: EmptyResponse = try await send(
            "/api/auth/enable",
            method: "POST",
            body: ["username": username, "password": password])
    }

    func disableServerLogin() async throws {
        let _: EmptyResponse = try await send(
            "/api/auth/disable",
            method: "POST",
            body: Optional<String>.none)
    }

    // MARK: - Movies & TV (see core/docs/MOVIES.md)
    // Twin of the Apple TV app's group - keep the two identical.

    // Whether the Movies section should exist at all. Its own endpoint, readable by a Viewer, and
    // it answers even while the section is switched off; a 404 is an older server and means off too.
    func mediaEnabled() async throws -> MediaEnabled {
        try await get("/api/media/enabled")
    }

    func mediaStatus() async throws -> MediaStatus {
        try await get("/api/media/status")
    }

    // MARK: Library management (admin)

    func mediaLibraries() async throws -> [MediaLibrary] {
        try await get("/api/media/libraries")
    }

    func saveMediaLibrary(id: String?, _ input: MediaLibraryInput) async throws -> MediaLibrary {
        if let id {
            return try await send("/api/media/libraries/\(id)", method: "PUT", body: input)
        }
        return try await send("/api/media/libraries", method: "POST", body: input)
    }

    func deleteMediaLibrary(id: String) async throws {
        let _: EmptyResponse = try await send("/api/media/libraries/\(id)", method: "DELETE", body: Optional<String>.none)
    }

    // nil scans every library. A 409 means a scan is already running.
    func scanMediaLibrary(id: String?) async throws {
        let path = id.map { "/api/media/libraries/\($0)/scan" } ?? "/api/media/scan"
        let _: EmptyResponse = try await send(path, method: "POST", body: Optional<String>.none)
    }

    // "" is the picker's first page; a local path or smb://host/Share/… anything below it.
    func mediaBrowse(path: String) async throws -> MediaBrowseListing {
        try await get("/api/media/browse", query: path.isEmpty ? [] : [URLQueryItem(name: "path", value: path)])
    }

    func mediaMakeFolder(parent: String, name: String) async throws -> MediaBrowseListing {
        try await send("/api/media/browse/folder", method: "POST", body: MediaNewFolderInput(parent: parent, name: name))
    }

    func mediaNetworkComputers() async throws -> [MediaNetworkComputer] {
        try await get("/api/media/network")
    }

    // Signs in (the server tests it before saving) and answers with the computer's shares.
    func saveMediaNetworkComputer(id: String?, _ input: MediaNetworkComputerInput) async throws -> MediaNetworkSignIn {
        if let id {
            return try await send("/api/media/network/\(id)", method: "PUT", body: input)
        }
        return try await send("/api/media/network", method: "POST", body: input)
    }

    func deleteMediaNetworkComputer(id: String) async throws {
        let _: EmptyResponse = try await send("/api/media/network/\(id)", method: "DELETE", body: Optional<String>.none)
    }

    // Takes about three seconds: the server listens for file-sharing computers over mDNS.
    func discoverMediaComputers() async throws -> [MediaDiscoveredComputer] {
        try await get("/api/media/network/discover")
    }

    func mediaHome() async throws -> MediaHome {
        try await get("/api/media/home")
    }

    // kind nil returns movies and shows together (never episodes). Sort and order in the server's
    // vocabulary; it picks a sensible default order for each sort when none is given. inList keeps
    // only the signed-in account's My List.
    func mediaItems(
        kind: String?, query: String? = nil, genre: String? = nil, sort: MediaSort? = nil, order: String? = nil,
        unwatched: Bool = false, inList: Bool = false, offset: Int = 0, limit: Int = 60
    ) async throws -> MediaItemsPage {
        var items: [URLQueryItem] = []
        if let kind { items.append(.init(name: "kind", value: kind)) }
        if let query, !query.isEmpty { items.append(.init(name: "q", value: query)) }
        if let genre, !genre.isEmpty { items.append(.init(name: "genre", value: genre)) }
        if let sort { items.append(.init(name: "sort", value: sort.rawValue)) }
        if let order { items.append(.init(name: "order", value: order)) }
        if unwatched { items.append(.init(name: "unwatched", value: "true")) }
        if inList { items.append(.init(name: "list", value: "true")) }
        items.append(.init(name: "offset", value: String(offset)))
        items.append(.init(name: "limit", value: String(limit)))
        return try await get("/api/media/items", query: items)
    }

    func mediaItem(id: String) async throws -> MediaItemDetail {
        try await get("/api/media/items/\(id)")
    }

    // "Surprise me": one movie or show at random, unwatched ones first. 404 with the server's own
    // "nothing matches" message when the library is empty.
    func mediaRandom() async throws -> MediaItemSummary {
        try await get("/api/media/random")
    }

    // start nil resumes from the saved progress, 0 starts over. The codec lists are what every
    // Apple device decodes in hardware; the server remuxes or transcodes anything else.
    //
    // Over the long-timeout session: for anything that isn't direct play the server starts ffmpeg
    // and only answers once the first segments exist, which can take over a minute for a
    // transcode - the main session gives up after 15 seconds.
    func mediaPlayback(id: String, start: Double?) async throws -> MediaPlayback {
        var items: [URLQueryItem] = [
            .init(name: "video", value: "h264,hevc"),
            .init(name: "audio", value: "aac,ac3,eac3,mp3"),
        ]
        if let start { items.append(.init(name: "start", value: String(Int(start.rounded(.down))))) }
        guard let url = url(path: "/api/media/items/\(id)/playback", query: items) else {
            throw ClientError.invalidServerAddress
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 100
        model.log("GET \(url.absoluteString)")
        let (data, response) = try await transferSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        model.log("GET \(http.statusCode) (media playback)")
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw ClientError.authenticationRequired }
            let message = (try? JSONDecoder.reelHouse.decode(APIError.self, from: data))
                .flatMap { $0.error ?? $0.errors?.joined(separator: "\n") }
            throw ClientError.server(status: http.statusCode, message: message)
        }
        return try JSONDecoder.reelHouse.decode(MediaPlayback.self, from: data)
    }

    // Fire-and-forget on purpose: the reply is the new progress object, but nothing here needs
    // it, and an older or oddly-configured server answering with an empty body must not read as
    // a failure ten seconds into every film.
    func reportMediaProgress(id: String, position: Double, duration: Double?) async throws {
        let _: EmptyResponse = try await send(
            "/api/media/items/\(id)/progress",
            method: "POST",
            body: MediaProgressBody(positionSeconds: position, durationSeconds: duration)
        )
    }

    func setMediaWatched(id: String, watched: Bool) async throws -> MediaProgress {
        try await send("/api/media/items/\(id)/watched", method: "POST", body: MediaWatchedBody(watched: watched))
    }

    // Adds to (or with false removes from) the signed-in account's My List.
    // Deletes a movie's files from the server's disk. Cannot be undone.
    func deleteMediaItem(id: String) async throws {
        let _: EmptyResponse = try await send("/api/media/items/\(id)", method: "DELETE", body: Optional<String>.none)
    }

    func setMediaInList(id: String, inList: Bool) async throws -> MediaListResult {
        try await send("/api/media/items/\(id)/list", method: "POST", body: MediaListBody(inList: inList))
    }

    func setMediaSeasonWatched(showId: String, season: Int, watched: Bool) async throws {
        let _: EmptyResponse = try await send(
            "/api/media/items/\(showId)/seasons/\(season)/watched",
            method: "POST",
            body: MediaWatchedBody(watched: watched)
        )
    }

    // The wire gives artwork and stream paths relative to the server ("/api/media/items/x/poster").
    // Always resolved against the address in use *now*, so a poster fetched after the plain-HTTP
    // fallback kicked in goes to the address that works. An absolute URL passes through untouched.
    func mediaURL(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return URL(string: path) }
        guard let question = path.firstIndex(of: "?") else { return url(path: path) }
        let query = URLComponents(string: "?" + path[path.index(after: question)...])?.queryItems ?? []
        return url(path: String(path[..<question]), query: query)
    }

    func mediaPosterURL(id: String) -> URL? { url(path: "/api/media/items/\(id)/poster") }
    func mediaBackdropURL(id: String) -> URL? { url(path: "/api/media/items/\(id)/backdrop") }
    func mediaThumbURL(id: String) -> URL? { url(path: "/api/media/items/\(id)/thumb") }
    func mediaSeasonPosterURL(showId: String, season: Int) -> URL? {
        url(path: "/api/media/items/\(showId)/seasons/\(season)/poster")
    }

    // MARK: - Movie downloads (see core/docs/MOVIE_DOWNLOADS.md)

    // Answers while the feature is off, so the Movies tab can decide whether to show "+ Add". An
    // older server answers 404, which the caller reads as off.
    func mediaDownloadsStatus() async throws -> MediaDownloadsStatus {
        return try await get("/api/media/downloads/status")
    }

    // kind is "movie" or "show".
    func mediaDownloadLookup(query: String, kind: String) async throws -> MediaDownloadLookup {
        try await get("/api/media/downloads/lookup", query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "kind", value: kind),
        ])
    }

    // One request to TMDB per season, so the long-timeout session.
    func mediaDownloadShow(tmdbId: Int) async throws -> MediaDownloadShow {
        try await mediaDownloadsRequest("/api/media/downloads/show/\(tmdbId)", method: "GET")
    }

    // Answers 202 straight away; the search itself runs on the server. Poll mediaDownloadSearch.
    func startMediaDownloadSearch(_ input: MediaDownloadSearchInput) async throws -> MediaDownloadSearch {
        try await send("/api/media/downloads/search", method: "POST", body: input)
    }

    func mediaDownloadSearch(id: String) async throws -> MediaDownloadSearch {
        try await get("/api/media/downloads/search/\(id)")
    }

    func mediaDownloads() async throws -> MediaDownloadList {
        try await get("/api/media/downloads")
    }

    // The server fetches the torrent through the VPN before it answers, so the long timeout.
    // Throws MediaAlreadyInLibrary when the movie is already there and `replace` is nil.
    func startMediaDownload(searchId: String, releaseId: String, libraryId: String? = nil, replace: Bool? = nil) async throws -> MediaDownload {
        try await mediaDownloadsRequest(
            "/api/media/downloads", method: "POST",
            body: MediaDownloadGrabInput(searchId: searchId, releaseId: releaseId, libraryId: libraryId, replace: replace))
    }

    func mediaDownload(id: String) async throws -> MediaDownload {
        try await get("/api/media/downloads/\(id)")
    }

    // Cancels an active download (its files are deleted) or removes a finished one from the list.
    func deleteMediaDownload(id: String) async throws {
        let _: EmptyResponse = try await send("/api/media/downloads/\(id)", method: "DELETE", body: Optional<String>.none)
    }

    func retryMediaDownload(id: String) async throws -> MediaDownload {
        try await send("/api/media/downloads/\(id)/retry", method: "POST", body: Optional<String>.none)
    }

    // Connects the VPN if it is idle and proves the sites see its address, not the home one. Can
    // take up to about a minute, so the long-timeout session.
    func testMediaDownloadsVpn() async throws -> MediaVpnTestResult {
        try await mediaDownloadsRequest("/api/media/downloads/vpn/test", method: "POST", timeout: 90)
    }

    // MARK: Import a list (Music and Movies; MOVIE_DOWNLOADS.md "Import a list")
    // The same routes under /api/music/downloads and /api/media/downloads - `kind` picks which.

    // The server reads the files and looks every album or film up in the library, so a big
    // export gets the long timeout. Nothing is saved.
    func mediaImportPreview(kind: MediaImportKind, files: [MediaImportFile]) async throws -> MediaImportPreview {
        try await mediaDownloadsRequest(
            "\(kind.base)/import/preview", method: "POST", body: MediaImportPreviewInput(files: files), timeout: 120)
    }

    func startMediaImport(kind: MediaImportKind, _ input: MediaImportStartInput) async throws -> MediaImportJob {
        try await mediaDownloadsRequest("\(kind.base)/imports", method: "POST", body: input)
    }

    func mediaImports(kind: MediaImportKind) async throws -> [MediaImportJob] {
        let list: MediaImportJobList = try await get("\(kind.base)/imports")
        return list.imports ?? []
    }

    func mediaImport(kind: MediaImportKind, id: String) async throws -> MediaImportJob {
        try await get("\(kind.base)/imports/\(id)")
    }

    func pauseMediaImport(kind: MediaImportKind, id: String, paused: Bool) async throws -> MediaImportJob {
        try await send("\(kind.base)/imports/\(id)/pause", method: "POST", body: MediaImportPauseInput(paused: paused))
    }

    // Everything not found or failed is searched for again.
    func retryMediaImport(kind: MediaImportKind, id: String) async throws -> MediaImportJob {
        try await send("\(kind.base)/imports/\(id)/retry", method: "POST", body: Optional<String>.none)
    }

    // Leaves one album or film out.
    func skipMediaImportItem(kind: MediaImportKind, id: String, itemId: String) async throws -> MediaImportJob {
        try await send("\(kind.base)/imports/\(id)/items/\(itemId)", method: "DELETE", body: Optional<String>.none)
    }

    // Stops and forgets the list; downloads it already queued carry on.
    func deleteMediaImport(kind: MediaImportKind, id: String) async throws {
        let _: EmptyResponse = try await send("\(kind.base)/imports/\(id)", method: "DELETE", body: Optional<String>.none)
    }

    // MARK: Sites (admin)
    // Prowlarr lives inside the VPN, so each of these may start it and wait up to ~25 s - past the
    // main session's 15 s - before answering 503 { starting: true }, thrown as
    // MediaDownloadsStartingError for the screen to show and try again.

    func mediaDownloadSites() async throws -> [MediaDownloadSite] {
        try await mediaDownloadsRequest("/api/media/downloads/sites", method: "GET")
    }

    func mediaDownloadSiteCatalog(query: String) async throws -> [MediaDownloadSiteDefinition] {
        try await mediaDownloadsRequest(
            "/api/media/downloads/sites/catalog", method: "GET",
            query: [URLQueryItem(name: "q", value: query)])
    }

    func addMediaDownloadSite(_ input: MediaDownloadSiteInput) async throws -> MediaDownloadSite {
        try await mediaDownloadsRequest("/api/media/downloads/sites", method: "POST", body: input)
    }

    func setMediaDownloadSiteEnabled(id: Int, enabled: Bool) async throws {
        let _: EmptyResponse = try await mediaDownloadsRequest(
            "/api/media/downloads/sites/\(id)", method: "PUT", body: MediaDownloadSiteUpdate(enabled: enabled))
    }

    func deleteMediaDownloadSite(id: Int) async throws {
        let _: EmptyResponse = try await mediaDownloadsRequest("/api/media/downloads/sites/\(id)", method: "DELETE")
    }

    private func mediaDownloadsRequest<T: Decodable>(
        _ path: String, method: String, query: [URLQueryItem] = [], body: (any Encodable)? = nil,
        timeout: TimeInterval = 60
    ) async throws -> T {
        guard let url = url(path: path, query: query) else { throw ClientError.invalidServerAddress }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let started = ContinuousClock.now
        model.log("\(method) \(url.absoluteString)")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transferSession.data(for: request)
        } catch {
            model.log("\(method) failed after \(elapsed(from: started)): \(describe(error))", level: .error)
            throw error
        }
        if let http = response as? HTTPURLResponse {
            model.log("\(method) \(http.statusCode) in \(elapsed(from: started))")
            if http.statusCode == 503,
               let busy = try? JSONDecoder.reelHouse.decode(MediaDownloadsBusy.self, from: data),
               busy.starting == true {
                throw MediaDownloadsStartingError(message: busy.error ?? "Connecting to the VPN... try again in a moment.")
            }
            if http.statusCode == 409,
               let duplicate = try? JSONDecoder.reelHouse.decode(MediaAlreadyInLibrary.self, from: data),
               duplicate.code == "alreadyInLibrary" {
                throw duplicate
            }
        }
        let valid = try validated(data, response)
        if T.self == EmptyResponse.self { return EmptyResponse() as! T }
        do {
            return try JSONDecoder.reelHouse.decode(T.self, from: valid)
        } catch {
            model.log("Could not decode \(url.absoluteString): \(error)", level: .error)
            throw error
        }
    }

    // MARK: Server settings (schema-driven, Admin-only server-side)

    func settingsSchema() async throws -> [SettingsSectionSchema] {
        try await get("/api/settings/schema")
    }

    // The full settings snapshot, untyped on purpose: its shape is described by the schema
    // above, and hard-coding it here is exactly what the schema exists to avoid. Secrets arrive
    // masked (••••••••) and are sent back unchanged to mean "keep the stored value".
    func settingsSnapshot() async throws -> [String: SettingsValue] {
        try await get("/api/settings")
    }

    // The values for a section that isn't in the bulk snapshot, fetched from the dataEndpoint the
    // schema gives it. Only INTERNET EXPOSED MODE needs this - it configures the dashboard
    // project's own Kestrel binding and so lives in a different settings file - but nothing here
    // knows that, which is the point: the section says where its values are and this fetches them.
    func settingsSectionData(endpoint: String) async throws -> [String: SettingsValue] {
        try await get(endpoint)
    }

    func saveSettingsSection(endpoint: String, values: [String: SettingsValue]) async throws -> SettingsSaveResult {
        try await send(endpoint, method: "PUT", body: values)
    }

    // Runs a settings field's lookup (SettingsLookupSchema) - the endpoint and the meaning of the
    // results both come from the schema, so this stays one method however many fields grow one.
    func settingsLookup(_ lookup: SettingsLookupSchema, query: String) async throws -> [SettingsLookupCandidate] {
        let response: SettingsLookupResponse = try await get(
            lookup.endpoint,
            query: [URLQueryItem(name: "query", value: query)]
        )
        return response.results
    }

    // Fetches the values a settings field can hold (SettingsOptionsSource). Same shape of method
    // as settingsLookup above and for the same reason: the endpoint comes from the schema, so one
    // method serves however many fields grow a list.
    func settingsOptions(_ source: SettingsOptionsSource) async throws -> [SettingsFieldOption] {
        let response: SettingsOptionsResponse = try await get(source.endpoint)
        return response.options
    }

    // Returns whatever the action had to say for itself, when it says anything. The test sends
    // report which address the mail actually went to; the setup reset has nothing to report and
    // answers with a body of a different shape entirely. So the detail is decoded leniently - an
    // action that succeeded but couldn't be read is still an action that succeeded, and a failure
    // has already been thrown by then with the server's own message.
    func runSettingsAction(_ action: SettingsActionSchema) async throws -> String? {
        let data = try await sendForData(action.endpoint, method: action.method)
        return (try? JSONDecoder.reelHouse.decode(SettingsActionResult.self, from: data))?.detail
    }

    // `service` names what to restart, as the settings schema gives it. The server answers 202
    // and restarts only when running under a supervisor (systemd etc.); otherwise it refuses with
    // an explanation, which surfaces through ClientError.server like any other error message.
    func restartServer(service: String) async throws {
        let _: EmptyResponse = try await send("/api/system/restart", method: "POST", body: ["service": service])
    }


    func url(path: String, query: [URLQueryItem] = []) -> URL? {
        guard var components = URLComponents(string: model.activeServerURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        guard var components = URLComponents(url: try baseURL(), resolvingAgainstBaseURL: false) else {
            throw ClientError.invalidServerAddress
        }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw ClientError.invalidServerAddress }
        return try await perform(URLRequest(url: url))
    }

    // Like send, but hands back the raw body rather than decoding it - for a caller that has to
    // cope with an answer of any shape, including none. See runSettingsAction.
    private func sendForData(_ path: String, method: String) async throws -> Data {
        guard let url = url(path: path) else { throw ClientError.invalidServerAddress }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await performData(request)
    }

    private func send<T: Decodable, Body: Encodable>(
        _ path: String,
        method: String,
        body: Body?
    ) async throws -> T {
        guard let url = url(path: path) else { throw ClientError.invalidServerAddress }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        return try await perform(request)
    }

    // Shared by `perform` (JSON) and `performData` (raw bytes, e.g. the reference-frame JPEG) -
    // runs the request, logs it, and turns a non-2xx response into a ClientError with the
    // server's message extracted, without assuming the success body is JSON.
    private func executeAndValidate(_ request: URLRequest) async throws -> Data {
        let started = ContinuousClock.now
        let method = request.httpMethod ?? "GET"
        let displayURL = request.url?.absoluteString ?? "(invalid URL)"
        model.log("\(method) \(displayURL)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await withAddressRecovery(request) { try await self.session.data(for: $0) }
        } catch {
            model.log("\(method) failed after \(elapsed(from: started)): \(describe(error))", level: .error)
            throw error
        }

        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        model.log("\(method) \(http.statusCode) in \(elapsed(from: started))")
        return try validated(data, response)
    }

    // The one rule for turning a response into a result or a ClientError, on its own so the
    // audio requests (AudioClient.swift), which run on transferSession rather than
    // `session`, fail exactly the way every other request does: 401 is "sign in", anything else
    // non-2xx carries the server's own message.
    func validated(_ data: Data, _ response: URLResponse) throws -> Data {
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder.reelHouse.decode(APIError.self, from: data))
                .flatMap { $0.error ?? $0.errors?.joined(separator: "\n") ?? $0.detail }
            if http.statusCode == 401 { throw ClientError.authenticationRequired }
            throw ClientError.server(status: http.statusCode, message: message)
        }
        return data
    }

    private func performData(_ request: URLRequest) async throws -> Data {
        try await executeAndValidate(request)
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        if T.self == EmptyResponse.self {
            _ = try await executeAndValidate(request)
            return EmptyResponse() as! T
        }
        let data = try await executeAndValidate(request)
        do {
            return try JSONDecoder.reelHouse.decode(T.self, from: data)
        } catch {
            let displayURL = request.url?.absoluteString ?? "(invalid URL)"
            model.log("Could not decode \(displayURL): \(error)", level: .error)
            throw error
        }
    }

    private func baseURL() throws -> URL {
        guard let url = URL(string: model.activeServerURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "http" || url.scheme == "https",
              url.host != nil else {
            throw ClientError.invalidServerAddress
        }
        return url
    }

    // Used to decide between the local and remote server addresses before a real connect -
    // any HTTP response counts as "reachable" (even a 401 or 500), since the point is just to
    // detect whether the host is reachable at all, not to validate the response itself. A
    // per-request timeout override (rather than a whole separate URLSessionConfiguration) keeps
    // this from disturbing the session's normal 10s/15s timeouts used for everything else.
    func probeReachable(_ urlString: String, timeout: TimeInterval = 2.5) async -> Bool {
        await probe(urlString, timeout: timeout) != .unreachable
    }

    // probeReachable, telling an untrusted certificate apart from a plain answer - the address
    // recovery needs to know whether the local server wants the plain-HTTP fallback.
    func probe(_ urlString: String, timeout: TimeInterval = 2.5) async -> AddressRecovery.Probe {
        guard let url = URL(string: "\(urlString.trimmingCharacters(in: .whitespacesAndNewlines))/api/auth/status") else {
            return .unreachable
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        do {
            _ = try await session.data(for: request)
            return .answered
        } catch {
            // A rejected certificate still proves a server answered - it takes a completed-enough
            // TLS handshake to have a certificate to reject. Treating it as unreachable here would
            // wrongly send connect() to the remote address when the local server is fine.
            if AppModel.isUntrustedCertificate(error) { return .untrustedCertificate }
            return AppModel.isCertificateTrustFailure(error) ? .answered : .unreachable
        }
    }

    // Runs a request against the current address; when it fails the way a vanished address does
    // (the phone left home Wi-Fi), has the model re-pick between the local and remote address and,
    // if that moved somewhere that answers, sends the request once more there. The retry is only
    // for failures that provably never reached the server, or for reads - see AddressRecovery - so
    // a command can't run twice. Anything else comes back exactly as it failed.
    func withAddressRecovery<T>(
        _ request: URLRequest, _ run: (URLRequest) async throws -> T
    ) async throws -> T {
        do {
            return try await run(request)
        } catch {
            guard AddressRecovery.shouldRecheckAddress(error), !Task.isCancelled,
                  let failedOrigin = AddressRecovery.origin(of: request.url),
                  await model.recoverAddress(after: failedOrigin),
                  AddressRecovery.mayRetry(error, method: request.httpMethod ?? "GET"),
                  let retry = AddressRecovery.rebase(request, onto: model.activeServerURL),
                  AddressRecovery.origin(of: retry.url) != failedOrigin else {
                throw error
            }
            model.log("Sending \(request.httpMethod ?? "GET") \(retry.url?.path ?? "") again at \(model.activeServerURL)", level: .notice)
            return try await run(retry)
        }
    }

    private func elapsed(from start: ContinuousClock.Instant) -> String {
        let duration = start.duration(to: .now)
        return duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated))
    }

    private func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return "URLError \(urlError.code.rawValue) (\(urlError.code)): \(urlError.localizedDescription)"
        }
        return "\(type(of: error)): \(error.localizedDescription)"
    }
}

struct EmptyResponse: Decodable {}

// A movie-downloads sites route answered 503 { starting: true }: the VPN is still coming up.
// Not a failure - show the message and ask again in a few seconds.
struct MediaDownloadsStartingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum ClientError: LocalizedError {
    case invalidServerAddress
    case invalidResponse
    case authenticationRequired
    case server(status: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidServerAddress: "Enter a valid server address, such as http://192.168.1.50:3350."
        case .invalidResponse: "The server returned an invalid response."
        case .authenticationRequired: "This server requires you to sign in."
        case let .server(status, message): message ?? "Server request failed (HTTP \(status))."
        }
    }
}
