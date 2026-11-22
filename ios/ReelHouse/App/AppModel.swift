import Combine
import Foundation
import Network
import OSLog
#if os(iOS)
import UserNotifications
#endif

// A ReelHouse server found on the local network via Bonjour/mDNS - see
// AppModel.startServerDiscovery(). Purely a convenience for prefilling ServerSetupView's manual
// address field; nothing here is persisted directly.
struct DiscoveredServer: Identifiable, Equatable {
    let id: String
    let name: String
    let host: String
    let port: Int
    let scheme: String

    var addressString: String { "\(scheme)://\(host):\(port)" }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") }
    }
    // Optional Cloudflare Tunnel (or any other externally-reachable) address, used only when
    // the local address can't be reached - see connect() for the resolution order.
    @Published var remoteServerURL: String {
        didSet { UserDefaults.standard.set(remoteServerURL, forKey: "remoteServerURL") }
    }
    @Published private(set) var activeServerURL: String = ""
    @Published private(set) var isUsingRemote = false
    // True while this session is talking plain HTTP to an HTTPS-configured server because this
    // device doesn't trust the server's self-generated certificate - see connect(). Surfaced in
    // SettingsView so the downgrade is never silent.
    @Published private(set) var usingHttpFallback = false
    // Whether the server behind the current fallback proved its identity - see ServerIdentity.
    private var httpFallbackVerified = false
    // Whether the server this app is talking to is older than it expects. Advisory: nothing in the
    // app behaves differently, it just says so - see ServerCompatibility.
    @Published private(set) var serverCompatibility: ServerCompatibility = .unknown
    @Published var connectionState: ConnectionState = .checking
    @Published var authStatus: AuthStatus?
    @Published var accounts: [Account] = []
    // Whether the server has Movies & TV switched on - drives whether the Movies section exists.
    // Remembered, so the section is there from the first frame of the next launch (and offline)
    // rather than popping in once the server has answered. On until a server has said otherwise:
    // a media server with no media sections would be an empty app.
    @Published private(set) var moviesEnabled: Bool = AppModel.remembered("moviesEnabled") {
        didSet { UserDefaults.standard.set(moviesEnabled, forKey: "moviesEnabled") }
    }
    // Music and Podcasts each have their own switch (GET /api/audio/enabled, which answers even
    // when both are off). Remembered like Movies.
    @Published private(set) var musicEnabled: Bool = AppModel.remembered("musicEnabled") {
        didSet { UserDefaults.standard.set(musicEnabled, forKey: "musicEnabled") }
    }
    @Published private(set) var podcastsEnabled: Bool = AppModel.remembered("podcastsEnabled") {
        didSet { UserDefaults.standard.set(podcastsEnabled, forKey: "podcastsEnabled") }
    }

    private static func remembered(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    @Published var isLoading = false
    @Published var lastError: String?
    @Published var diagnostics: [DiagnosticEntry] = []
    @Published var lastUpdated: Date?
    @Published private(set) var discoveredServers: [DiscoveredServer] = []

    private(set) lazy var client = ReelHouseClient(model: self)
    private var localNetworkBrowser: NWBrowser?
    private(set) var isConnecting = false
    // One address re-pick at a time - a CarPlay screen fires several requests at once, and they
    // all fail together when the phone leaves home. See recoverAddress.
    private var addressRecovery: Task<Bool, Never>?
    private var lastAddressCheck: ContinuousClock.Instant?
    // Wi-Fi <-> cellular: the cue to check the address before a request has to fail first.
    private let pathMonitor = NWPathMonitor()
    private var lastPathSignature: String?

    #if os(iOS)
    // A tapped notification waiting for RootView to open it - see PushRoute.
    @Published var pendingPushRoute: PushRoute?
    // Server, account and token last registered this run, so a reconnect doesn't re-post it.
    private var registeredPushKey: String?
    private var pushObservers: [NSObjectProtocol] = []
    #endif

    init() {
        serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        remoteServerURL = UserDefaults.standard.string(forKey: "remoteServerURL") ?? ""
        startPathMonitor()
        #if os(iOS)
        observePush()
        #endif
    }

    var isConfigured: Bool { URL(string: serverURL)?.host != nil }
    var hasRemoteServerURL: Bool { URL(string: remoteServerURL)?.host != nil }
    var requiresLogin: Bool { authStatus?.enabled == true && authStatus?.authenticated == false }
    // Absent role (older server, or login not required) reads as Admin - matches the server's
    // own AuthGateMiddleware treatment of "no login required" as full access for everyone.
    var isAdmin: Bool { (authStatus?.role ?? "Admin") == "Admin" }

    func connect(resetNetworkSession: Bool = false) async {
        guard isConfigured else {
            connectionState = .notConfigured
            return
        }
        guard !isConnecting else {
            log("Connection request skipped because one is already active", level: .notice)
            return
        }

        isConnecting = true
        defer { isConnecting = false }
        // The configured address is logged rather than assumed. A field typed into but never
        // saved leaves this pointing somewhere else entirely, and "which address did it actually
        // use" turned out to be the single hardest thing to establish from outside the app.
        log("Connecting to \(serverURL)\(hasRemoteServerURL ? " (remote fallback \(remoteServerURL))" : "")")
        let wasOffline = connectionState == .offline
        if connectionState != .online {
            connectionState = .checking
        }
        // A URLSession created while local-network access was denied can retain the old
        // unsatisfied network path. Recreate it on each explicit connection attempt so a
        // newly-granted privacy decision takes effect immediately.
        if resetNetworkSession || wasOffline {
            client.resetSession()
        }
        startServerDiscovery()
        // Give macOS a moment to present/register the local-network permission before the
        // first HTTP request. The browser stays alive for the app's lifetime.
        try? await Task.sleep(for: .milliseconds(500))
        usingHttpFallback = false
        httpFallbackVerified = false
        await resolveActiveServerURL()
        lastAddressCheck = .now
        do {
            try await establishSession()
        } catch {
            if Self.isCancellation(error) {
                log("Connection task cancelled by the app lifecycle", level: .notice)
                return
            }
            // The server generates its own certificate authority, which no Apple device trusts
            // out of the box - so a fresh install pointed at the https:// address (the default
            // that server discovery advertises) would simply never connect. The server keeps its
            // plain-HTTP listener open precisely for app clients in this position (the Android
            // app uses nothing else), so fall back to it rather than stranding the user. Local
            // address only: a remote address crosses the open Internet, where quietly dropping
            // encryption is not an acceptable trade.
            //
            // Only for an actual certificate verdict, and only to a server that proves it is this
            // one (see ServerIdentity) - checked before any plain-HTTP request, because even the
            // reachability probe below carries the session cookie.
            if !isUsingRemote, Self.isUntrustedCertificate(error),
               let fallback = Self.httpFallbackAddress(for: activeServerURL) {
                let httpsAddress = activeServerURL
                let identity = await ServerIdentity.check(httpsAddress)
                switch identity {
                case .mismatch:
                    log("The server at \(httpsAddress) presented a certificate its own authority didn't sign - not falling back to plain HTTP", level: .error)
                    failConnection(message: Self.impostorMessage)
                    return
                case .unavailable:
                    log("Couldn't check the certificate at \(httpsAddress) before falling back to plain HTTP", level: .notice)
                    failConnection(with: error)
                    return
                case .verified:
                    break
                case .unknown:
                    // Not yet known to be this server, so none of the existing session goes to
                    // it - the probe below would otherwise carry the cookie. Signing in again
                    // is the price of the first fallback.
                    ServerIdentity.forgetSession(for: fallback)
                }
                log("This device does not trust the server's HTTPS certificate; trying the plain-HTTP port at \(fallback)", level: .notice)
                if await client.probeReachable(fallback) {
                    activeServerURL = fallback
                    usingHttpFallback = true
                    httpFallbackVerified = { if case .verified = identity { true } else { false } }()
                    do {
                        try await establishSession()
                        if case .unknown(let leaf) = identity {
                            await rememberServerIdentity(signing: leaf, httpsAddress: httpsAddress, httpAddress: fallback)
                        }
                        log("Connected over plain HTTP. For an encrypted connection instead, trust the server's certificate authority (ca.crt) on this device", level: .notice)
                    } catch {
                        usingHttpFallback = false
                        httpFallbackVerified = false
                        if Self.isCancellation(error) {
                            log("Connection task cancelled by the app lifecycle", level: .notice)
                            return
                        }
                        failConnection(with: error)
                    }
                    return
                }
                log("The plain-HTTP port at \(fallback) did not answer either", level: .notice)
            }
            failConnection(with: error)
        }
    }

    // The post-address-resolution half of connect(): everything from the first real request to
    // fully online. Split out so the certificate-trust fallback in connect() can run it a second
    // time against the plain-HTTP address.
    private func establishSession() async throws {
        authStatus = try await client.authStatus()
        // Never replay the Keychain password over the plain-HTTP fallback to a server that hasn't
        // proved who it is - it would go, in the clear, to whatever answered. The first fallback
        // (before the server's authority is remembered) shows the sign-in screen instead.
        let mayReplayLogin = !usingHttpFallback || httpFallbackVerified
        if requiresLogin, !mayReplayLogin {
            log("Not sending the saved login over an unverified plain-HTTP connection; sign in to continue", level: .notice)
        }
        if requiresLogin, mayReplayLogin, let credential = CredentialStore.load(for: serverURL) {
            log("The saved server session expired; renewing it with the Keychain login", level: .notice)
            do {
                try await client.login(username: credential.username, password: credential.password)
                authStatus = try await client.authStatus()
            } catch ClientError.authenticationRequired {
                // A password reset or deleted account must not cause a failed automatic login on
                // every launch. Forget the stale secret and show the normal sign-in screen.
                CredentialStore.delete(for: serverURL)
                authStatus = try await client.authStatus()
            }
        }
        // Before the requiresLogin return below, so the advisory is already known at the login
        // screen. Never throws - see checkServerCompatibility.
        await checkServerCompatibility()
        if requiresLogin {
            log("Server requires sign-in")
            connectionState = .authenticationRequired
            return
        }
        try await refreshAll()
        connectionState = .online
        log("Connection established")
    }

    // Deliberately swallows every failure. This is a diagnostic nicety layered on top of a
    // connection that has already succeeded - failing the connect() that called it, over a server
    // that merely declined to describe itself, would turn a cosmetic feature into an outage.
    private func checkServerCompatibility() async {
        do {
            serverCompatibility = ServerCompatibility.evaluate(try await client.serverHealth().build)
        } catch {
            serverCompatibility = .unknown
            log("Could not read the server's version: \(Self.describe(error))", level: .info)
            return
        }
        if let advisory = serverCompatibility.advisory {
            log(advisory, level: .notice)
        }
    }

    private func failConnection(with error: Error) {
        connectionState = .offline
        lastError = Self.userFacingMessage(for: error)
        log("Connection failed against \(activeServerURL): \(Self.describe(error))", level: .error)
    }

    private func failConnection(message: String) {
        connectionState = .offline
        lastError = message
    }

    static let impostorMessage =
        "Something at this address isn't your ReelHouse server - its certificate wasn't issued by your server. Nothing was sent to it. " +
        "If you're away from home, that's expected: use the remote address. If you reinstalled the server, save its address again in Settings."

    // Trust on first use - see ServerIdentity. Best effort: failing to remember just means the
    // next fallback is treated as a first one again.
    private func rememberServerIdentity(signing leaf: SecCertificate, httpsAddress: String, httpAddress: String) async {
        guard let authority = await ServerIdentity.fetchAuthority(from: httpAddress) else {
            log("Couldn't download the server's certificate authority to remember it", level: .notice)
            return
        }
        if ServerIdentity.remember(authority: authority, signing: leaf, for: httpsAddress) {
            log("Remembered this server's certificate authority; plain-HTTP fallback now only goes to this server")
        } else {
            log("The certificate authority the server offered didn't sign its HTTPS certificate - not remembering it", level: .notice)
        }
    }

    // URLError's wording is written for apps that talk to the public internet, so for the two
    // failures this app actually hits on a LAN it names the wrong problem. A distrusted
    // self-signed certificate ("...may be pretending to be...") reads as an active attack and
    // names no way out. A denied Local Network permission reports "The Internet connection
    // appears to be offline", which sends people to their router and their Wi-Fi when the fix is
    // a privacy toggle. Both get replaced with the real cause and a way out; everything else
    // keeps the system wording, which is accurate for the remaining cases.
    static func userFacingMessage(for error: Error) -> String {
        if isCertificateTrustFailure(error) {
            return "This device doesn't trust the certificate the server generated for itself. Use the http:// address, or install the server's ca.crt on this device to keep HTTPS."
        }
        if isLocalNetworkFailure(error) {
            return "Can't reach anything on your local network. Check this device is on the same network as the server - and if ReelHouse was denied Local Network access, turn it back on under \(localNetworkSettingsPath)."
        }
        return error.localizedDescription
    }

    // -1009 has two causes here and the error carries nothing that separates them: the network
    // really is down, or the OS is refusing this app's LAN traffic specifically. A denied grant is
    // the far more likely one for a server on the same subnet - it is also the one users cannot
    // guess - so the message has to raise it without asserting it over the mundane case.
    static func isLocalNetworkFailure(_ error: Error) -> Bool {
        (error as? URLError)?.code == .notConnectedToInternet
    }

    private static var localNetworkSettingsPath: String {
        #if os(macOS)
        "System Settings → Privacy & Security → Local Network"
        #else
        "Settings → Privacy & Security → Local Network"
        #endif
    }

    // Everything URLSession reports when a TLS handshake completed enough to judge the server's
    // certificate and the judgement was "no". Distinct from the host being unreachable: these
    // mean the server is up and answering, just not trusted by this particular device.
    static func isCertificateTrustFailure(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        switch code {
        case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    // What may start the plain-HTTP fallback: the server's certificate was judged and not trusted.
    // Narrower than isCertificateTrustFailure on purpose - that also counts a bare handshake
    // failure (-1200), which anything can produce without presenting a certificate at all.
    static func isUntrustedCertificate(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        switch code {
        case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            return true
        default:
            return false
        }
    }

    // https://host[:port] -> http://host:3350, the dashboard's shipped plain-HTTP port. A custom
    // HTTP port can't be derived from the HTTPS address, so the default is the only sensible
    // guess - and connect() probes the result before actually switching to it.
    static func httpFallbackAddress(for address: String) -> String? {
        guard var components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "https" else {
            return nil
        }
        components.scheme = "http"
        components.port = 3350
        return components.string
    }

    // Prefers the local address whenever it's reachable at all (any HTTP response counts,
    // not just 2xx) and only falls back to the remote address on an actual network failure -
    // this runs at the top of every connect(), so moving between home and away self-heals on
    // the next reconnect without any WiFi/SSID detection.
    private func resolveActiveServerURL() async {
        guard hasRemoteServerURL else {
            activeServerURL = serverURL
            isUsingRemote = false
            return
        }
        if await client.probeReachable(serverURL) {
            log("Local address \(serverURL) answered; using it")
            activeServerURL = serverURL
            isUsingRemote = false
        } else {
            log("Local address \(serverURL) unreachable; using remote address \(remoteServerURL)", level: .notice)
            activeServerURL = remoteServerURL
            isUsingRemote = true
        }
    }

    // The address this session is using stopped answering (a request failed before reaching the
    // server; see ReelHouseClient.withAddressRecovery). If the current address still answers, keep
    // it - the failure was something else. Otherwise re-pick exactly as connect() does: local if it
    // answers (through the plain-HTTP fallback only for a server that has proved who it is), else
    // remote. True when activeServerURL now points somewhere other than `failedOrigin` that
    // answered, so the caller may send its request again. Callers that pile up behind one
    // re-pick share its answer.
    func recoverAddress(after failedOrigin: String) async -> Bool {
        // Someone else already moved off the address that failed.
        if let current = AddressRecovery.origin(of: activeServerURL), current != failedOrigin { return true }
        // connect() is choosing right now; let it.
        guard isConfigured, !isConnecting else { return false }
        if let running = addressRecovery { return await running.value }
        let task = Task { await self.repickAddress() }
        addressRecovery = task
        let moved = await task.value
        addressRecovery = nil
        return moved
    }

    private func repickAddress() async -> Bool {
        lastAddressCheck = .now
        let current = activeServerURL
        if !current.isEmpty, await client.probe(current) != .unreachable { return false }
        let choice = await AddressRecovery.choose(
            local: serverURL,
            remote: hasRemoteServerURL ? remoteServerURL : nil,
            probe: { await self.client.probe($0) },
            fallback: { local in
                // No first-use exception here, where nobody may be
                // looking, so only a server whose authority is already remembered.
                guard let http = Self.httpFallbackAddress(for: local),
                      case .verified = await ServerIdentity.check(local),
                      await self.client.probeReachable(http) else { return nil }
                return http
            })
        guard let choice else {
            log("Server address \(current) stopped answering and neither the local nor the remote address answers", level: .notice)
            return false
        }
        guard AddressRecovery.origin(of: choice.address) != AddressRecovery.origin(of: current) else { return false }
        log("Server address \(current) stopped answering; using \(choice.isRemote ? "remote" : "local") address \(choice.address)", level: .notice)
        activeServerURL = choice.address
        isUsingRemote = choice.isRemote
        usingHttpFallback = choice.isHttpFallback
        httpFallbackVerified = choice.isHttpFallback
        return true
    }

    // For callers that act on `.online` without sending anything first (CarPlay's ready()): checks
    // the address still answers when it hasn't been looked at for `maxAge`, re-picking if not.
    // False when nothing answers - the app is then offline, and says so.
    func confirmAddress(maxAge: Duration = .seconds(30)) async -> Bool {
        guard connectionState == .online, !isConnecting else { return connectionState == .online }
        if let lastAddressCheck, lastAddressCheck.duration(to: .now) < maxAge { return true }
        guard let origin = AddressRecovery.origin(of: activeServerURL) else { return false }
        lastAddressCheck = .now
        if await client.probe(activeServerURL) != .unreachable { return true }
        if await recoverAddress(after: origin) { return true }
        if connectionState == .online {
            connectionState = .offline
            lastError = "Can't reach your ReelHouse server."
        }
        return false
    }

    // Moving between networks changes which address can answer. The first update is just the path
    // at launch; after that, a different set of interfaces while online re-checks the address, and
    // a network coming back while offline reconnects.
    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let signature = path.status == .satisfied
                ? path.availableInterfaces.map { "\($0.type)" }.sorted().joined(separator: ",")
                : "none"
            Task { @MainActor in self?.networkPathChanged(signature: signature, satisfied: path.status == .satisfied) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "ReelHouse.path"))
    }

    private func networkPathChanged(signature: String, satisfied: Bool) {
        defer { lastPathSignature = signature }
        guard let previous = lastPathSignature, previous != signature, satisfied, isConfigured, !isConnecting else { return }
        log("Network changed (\(previous) -> \(signature)); checking the server address")
        Task {
            // Give the new path a moment to settle - DHCP, the cellular radio, VPNs.
            try? await Task.sleep(for: .seconds(1))
            switch connectionState {
            case .online:
                if let origin = AddressRecovery.origin(of: activeServerURL) {
                    _ = await recoverAddress(after: origin)
                }
            case .offline:
                await connect()
            default:
                break
            }
        }
    }

    func refreshAll() async throws {
        isLoading = true
        defer { isLoading = false }

        // Each section has its own switch on the server, and each answer is independent: one
        // that fails must not hide the others. A request that never reached the server at all is
        // the one thing that fails the refresh - that is "offline", not "switched off".
        var firstError: Error?
        do {
            moviesEnabled = try await client.mediaEnabled().enabled
        } catch {
            if Self.isCancellation(error) { throw error }
            if case ClientError.server(status: 404, _) = error { moviesEnabled = false } else { firstError = error }
        }
        do {
            let audio = try await client.audioEnabled()
            musicEnabled = audio.music == true
            podcastsEnabled = audio.podcasts == true
            // Plays heard offline go up now that the server answers.
            await AudioReportQueue.shared.flush()
            SpeakerHost.shared.resumeIfEnabled()
        } catch {
            if Self.isCancellation(error) { throw error }
            if case ClientError.server(status: 404, _) = error {
                musicEnabled = false
                podcastsEnabled = false
            } else {
                firstError = firstError ?? error
            }
        }

        if let firstError {
            lastError = firstError.localizedDescription
            // Logged even when it isn't rethrown: a partial refresh still leaves the app looking
            // connected while quietly missing a section, and without this that left no trace.
            log("Refresh finished with an error: \(Self.describe(firstError))", level: .error)
            if firstError is URLError { throw firstError }
        } else {
            lastError = nil
        }
        lastUpdated = .now
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }

    // Mirrored into the unified log as well as the in-app Diagnostics screen. print() only reaches
    // a terminal that launched the app, which an app launched from the Finder or /Applications
    // never has - so when a connection problem had to be diagnosed, the only copy of the evidence
    // was on a screen someone had to read out loud. With this, the same lines are available to
    //   log show --predicate 'subsystem == "com.reelhouse.client"' --last 10m
    // from any terminal, on this Mac or over SSH.
    func log(_ message: String, level: DiagnosticLevel = .info) {
        diagnostics.insert(DiagnosticEntry(timestamp: .now, level: level, message: message), at: 0)
        if diagnostics.count > 100 {
            diagnostics.removeLast(diagnostics.count - 100)
        }
        // .public because none of this is personal data - it's server addresses and error codes,
        // and redacted logs would defeat the entire point of having them.
        Self.logger.log(level: level.osLogType, "\(message, privacy: .public)")
    }

    private static let logger = Logger(subsystem: "com.reelhouse.client", category: "connection")

    // localizedDescription alone is what produced "The Internet connection appears to be offline",
    // a message that covers a genuinely dead network, a sandboxed app denied local-network access,
    // and a server that isn't listening - three completely different problems with three
    // completely different fixes. The domain and code tell those apart, so they get logged too.
    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        var parts = ["\(error.localizedDescription) [\(nsError.domain) \(nsError.code)"]
        if let urlError = error as? URLError {
            parts.append(" \(Self.name(for: urlError.code))")
            if let failing = urlError.failingURL {
                parts.append(" url=\(failing.absoluteString)")
            }
        }
        parts.append("]")
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append(" underlying=(\(underlying.domain) \(underlying.code))")
        }
        return parts.joined()
    }

    // The handful of URLError codes this app actually runs into, named rather than numbered. Every
    // one of these has been mistaken for another at some point while debugging a connection.
    private static func name(for code: URLError.Code) -> String {
        switch code {
        case .notConnectedToInternet: "notConnectedToInternet - no usable network path; on a sandboxed Mac app this is also what a denied Local Network permission looks like"
        case .cannotConnectToHost: "cannotConnectToHost - reached the host, nothing listening on that port"
        case .cannotFindHost: "cannotFindHost - name did not resolve"
        case .timedOut: "timedOut - no response; typically a firewall dropping packets"
        case .secureConnectionFailed: "secureConnectionFailed - TLS handshake rejected"
        case .serverCertificateUntrusted: "serverCertificateUntrusted - the server's CA is not trusted on this device"
        case .serverCertificateHasBadDate: "serverCertificateHasBadDate"
        case .serverCertificateNotYetValid: "serverCertificateNotYetValid"
        case .appTransportSecurityRequiresSecureConnection: "appTransportSecurityRequiresSecureConnection - plain HTTP blocked by ATS"
        default: "URLError \(code.rawValue)"
        }
    }

    func clearDiagnostics() {
        diagnostics.removeAll()
    }

    // Browses for other ReelHouse servers on the LAN (used to populate ServerSetupView's
    // discovered-server list) and, as a side effect, is also what makes iOS/macOS prompt for
    // local-network permission in the first place - so this is started from ServerSetupView.onAppear
    // as well as from connect(), rather than gated behind isConfigured like the rest of connect() is.
    //
    // "_reelhouse._tcp" rather than "_http._tcp": a dedicated service type means every result
    // this browser ever sees is actually a ReelHouse server, with no further filtering needed.
    func startServerDiscovery() {
        guard localNetworkBrowser == nil else { return }

        let browser = NWBrowser(
            // WithTXTRecord, or results carry no TXT record (metadata is .none) - and the
            // server's https/port details live there.
            for: .bonjourWithTXTRecord(type: "_reelhouse._tcp", domain: nil),
            using: .tcp
        )
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.log("Local-network discovery is ready")
                    if self.connectionState != .online {
                        await self.connect(resetNetworkSession: true)
                    }
                case let .waiting(error):
                    self.log("Waiting for local-network permission: \(error)", level: .notice)
                case let .failed(error):
                    self.log("Local-network discovery failed: \(error)", level: .error)
                case .cancelled:
                    self.log("Local-network discovery was cancelled", level: .notice)
                case .setup:
                    self.log("Requesting local-network access")
                @unknown default:
                    self.log("Local-network discovery entered an unknown state", level: .notice)
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let currentIds = Set(results.compactMap(Self.serviceName(for:)))
            Task { @MainActor in
                self.discoveredServers.removeAll { !currentIds.contains($0.id) }
            }
            for result in results {
                guard let name = Self.serviceName(for: result) else { continue }
                // A server that sent no TXT record is still a server: it just defaults to http.
                let txtRecord: NWTXTRecord?
                if case let .bonjour(record) = result.metadata { txtRecord = record } else { txtRecord = nil }
                Task { @MainActor in
                    guard !self.discoveredServers.contains(where: { $0.id == name }) else { return }
                    self.resolveDiscoveredServer(endpoint: result.endpoint, name: name, txtRecord: txtRecord)
                }
            }
        }
        localNetworkBrowser = browser
        browser.start(queue: DispatchQueue(label: "com.reelhouse.local-network-discovery"))
    }

    // nonisolated: called from NWBrowser's browseResultsChangedHandler, which runs on the
    // browser's own dispatch queue rather than the MainActor.
    private nonisolated static func serviceName(for result: NWBrowser.Result) -> String? {
        guard case let .service(name, _, _, _) = result.endpoint else { return nil }
        return name
    }

    // A Bonjour NWBrowser.Result's endpoint identifies a service by name, not by host/port -
    // briefly opening a connection to it and reading back currentPath.remoteEndpoint is the
    // standard way to resolve the actual address, per Apple's Network framework guidance.
    private func resolveDiscoveredServer(endpoint: NWEndpoint, name: String, txtRecord: NWTXTRecord?) {
        let scheme: String
        if case let .string(value) = txtRecord?.getEntry(for: "scheme") {
            scheme = value
        } else {
            scheme = "http"
        }

        // Servers list their own LAN addresses ("addrs") and port: use those directly. Resolving
        // the service name with a connection (below) can sit in "preparing" for good on Apple
        // TV, which left the setup screen searching for ever. Older servers don't send them.
        if case let .string(list) = txtRecord?.getEntry(for: "addrs"),
           let host = list.split(separator: ",").map({ String($0).trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }),
           case let .string(portText) = txtRecord?.getEntry(for: "port"), let port = Int(portText) {
            discoveredServers.append(DiscoveredServer(id: name, name: name, host: host, port: port, scheme: scheme))
            return
        }

        // IPv4 only: otherwise the address read back is often the IPv6 link-local one
        // (fe80::...%en0), which doesn't survive being written into a URL.
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                defer { connection.cancel() }
                guard let self,
                      case let .hostPort(host, port) = connection.currentPath?.remoteEndpoint else { return }

                let hostString: String
                switch host {
                // Printing an IPv4Address can add the interface ("192.168.1.20%en0"), which
                // isn't valid in a URL.
                case .ipv4(let address): hostString = "\(address)".split(separator: "%").first.map(String.init) ?? "\(address)"
                case .ipv6(let address): hostString = "\(address)"
                case .name(let value, _): hostString = value
                @unknown default: return
                }

                Task { @MainActor in
                    guard !self.discoveredServers.contains(where: { $0.id == name }) else { return }
                    self.discoveredServers.append(DiscoveredServer(
                        id: name, name: name, host: hostString, port: Int(port.rawValue), scheme: scheme))
                }
            case .failed:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue(label: "com.reelhouse.local-network-discovery.resolve"))
    }

    func signIn(username: String, password: String) async throws {
        try await client.login(username: username, password: password)
        // Save only after the server accepted the credentials. A Keychain write failure should
        // not undo a valid login; it only means this session cannot renew itself automatically.
        do {
            try CredentialStore.save(StoredCredential(username: username, password: password), for: serverURL)
        } catch {
            log("Signed in, but could not save the login in Keychain: \(error.localizedDescription)", level: .error)
        }
        authStatus = try await client.authStatus()
        try await refreshAll()
        connectionState = .online
    }

    // Re-reads whether the server requires a login. Called after the Dashboard Login screen turns
    // that requirement on or off, so the rest of the app (the Account section, the sign-in gate)
    // stops describing the state it was in a moment ago.
    func refreshAuthStatus() async {
        authStatus = try? await client.authStatus()
        connectionState = requiresLogin ? .authenticationRequired : .online
    }

    func signOut() async {
        CredentialStore.delete(for: serverURL)
        #if os(iOS)
        // While the session cookie still works - unregistering needs it.
        await unregisterPushDevice()
        #endif
        try? await client.logout()
        authStatus = try? await client.authStatus()
        connectionState = requiresLogin ? .authenticationRequired : .online
    }
}

#if os(iOS)
// Push notifications - see PushNotificationCoordinator for the APNs side.
extension AppModel {
    fileprivate func observePush() {
        pushObservers.append(NotificationCenter.default.addObserver(
            forName: .reelHousePushTokenChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.syncPushRegistration() }
        })
        pushObservers.append(NotificationCenter.default.addObserver(
            forName: .reelHousePushOpened, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.takePendingPushRoute() }
        })
        pushObservers.append(NotificationCenter.default.addObserver(
            forName: .reelHousePushRegistrationFailed, object: nil, queue: .main
        ) { [weak self] notification in
            let message = notification.object as? String ?? "unknown error"
            Task { @MainActor in self?.log("APNs registration failed: \(message)", level: .error) }
        })
        takePendingPushRoute()
    }

    private func takePendingPushRoute() {
        if let route = PushNotificationCoordinator.shared.takePendingRoute() { pendingPushRoute = route }
    }

    static func pushAllowed(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional || status == .ephemeral
    }

    // Called by RootView each time the app is online with its window up: asks for permission the
    // first time (never before sign-in - nothing could be delivered yet), then registers. Not
    // from connect() itself, which also runs for a CarPlay-only launch with no window to ask in.
    func startPushNotifications() async {
        guard connectionState == .online else { return }
        let coordinator = PushNotificationCoordinator.shared
        if await coordinator.authorizationStatus() == .notDetermined {
            do {
                let granted = try await coordinator.requestAuthorization()
                log("Notification permission \(granted ? "granted" : "declined")")
            } catch {
                log("Notification permission request failed: \(error.localizedDescription)", level: .error)
            }
        }
        if Self.pushAllowed(await coordinator.authorizationStatus()) {
            // Usually the token from launch is already in hand; this covers a grant made since.
            coordinator.registerWithAPNs()
        }
        await syncPushRegistration()
    }

    // Sends the APNs token to the server whenever it, the server or the account changes.
    func syncPushRegistration() async {
        let coordinator = PushNotificationCoordinator.shared
        guard connectionState == .online, !requiresLogin,
              let token = coordinator.currentDeviceToken,
              Self.pushAllowed(await coordinator.authorizationStatus()) else { return }
        let key = "\(serverURL)|\(authStatus?.username ?? "")|\(token)"
        guard key != registeredPushKey else { return }
        let sandbox = PushNotificationCoordinator.apnsSandbox
        do {
            try await client.registerPushDevice(token: token, deviceName: coordinator.deviceName, apnsSandbox: sandbox)
            registeredPushKey = key
            log("Registered this device for push notifications (\(sandbox ? "sandbox" : "production") APNs)")
        } catch {
            log("Push registration failed: \(Self.describe(error))", level: .error)
        }
    }

    // Best effort, and before logout: the server only accepts it from the signed-in session. If
    // it fails the server keeps the token, so the log says so.
    fileprivate func unregisterPushDevice() async {
        registeredPushKey = nil
        guard let token = PushNotificationCoordinator.shared.currentDeviceToken else { return }
        do {
            try await client.unregisterPushDevice(token: token)
        } catch {
            log("Could not unregister this device from push notifications: \(Self.describe(error))", level: .notice)
        }
    }
}
#endif

struct DiagnosticEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: DiagnosticLevel
    let message: String
}

enum DiagnosticLevel: String {
    case info = "INFO"
    case notice = "NOTICE"
    case error = "ERROR"

    var osLogType: OSLogType {
        switch self {
        case .info: .info
        case .notice: .default
        case .error: .error
        }
    }
}

enum ConnectionState: Equatable {
    case notConfigured, checking, online, authenticationRequired, offline

    var label: String {
        switch self {
        case .notConfigured: "Set server"
        case .checking: "Connecting…"
        case .online: "Connected"
        case .authenticationRequired: "Sign in required"
        case .offline: "Offline"
        }
    }
}
