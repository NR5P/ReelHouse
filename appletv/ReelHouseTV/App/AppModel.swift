import Combine
import Foundation
import Network

// A ReelHouse server found on the local network via Bonjour/mDNS - see
// AppModel.startServerDiscovery(). Purely a convenience for prefilling ServerSetupView's manual
// address field; nothing here is persisted directly. Mirrors ios/ReelHouse/App/AppModel.swift.
struct DiscoveredServer: Identifiable, Equatable {
    let id: String
    let name: String
    let host: String
    let port: Int
    let scheme: String

    var addressString: String { "\(scheme)://\(host):\(port)" }
}

// Connection, sign-in and server discovery for the tvOS app.
@MainActor
final class AppModel: ObservableObject {
    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") }
    }
    // No remote-address fallback here, unlike the iOS/macOS ports. That exists for a device that
    // leaves the house and has to reach the server the long way round; an Apple TV is bolted to a
    // TV on the same network as the server, so if the local address is unreachable the TV has no
    // working network either and a second address to try is just a reachability probe delaying
    // every connect.
    @Published private(set) var activeServerURL: String = ""
    // Whether the server this app is talking to is older than it expects. Advisory: nothing in the
    // app behaves differently, it just says so - see ServerCompatibility.
    @Published private(set) var serverCompatibility: ServerCompatibility = .unknown
    @Published var connectionState: ConnectionState = .checking
    @Published var authStatus: AuthStatus?
    // Whether the server has Movies & TV switched on - drives whether the Movies tab exists.
    // Remembered, so the tab is there from the first frame of the next launch rather than
    // popping in once the server has answered.
    @Published private(set) var moviesEnabled: Bool {
        didSet { UserDefaults.standard.set(moviesEnabled, forKey: "moviesEnabled") }
    }
    @Published var isLoading = false
    @Published var lastError: String?
    @Published var diagnostics: [DiagnosticEntry] = []
    @Published var lastUpdated: Date?
    @Published private(set) var discoveredServers: [DiscoveredServer] = []

    private(set) lazy var client = ReelHouseClient(model: self)

    private var localNetworkBrowser: NWBrowser?
    private var isConnecting = false

    init() {
        moviesEnabled = UserDefaults.standard.bool(forKey: "moviesEnabled")
        serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
    }


    var isConfigured: Bool { URL(string: serverURL)?.host != nil }
    var requiresLogin: Bool { authStatus?.enabled == true && authStatus?.authenticated == false }
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
        log("Connecting to \(serverURL)")
        let wasOffline = connectionState == .offline
        if connectionState != .online {
            connectionState = .checking
        }
        if resetNetworkSession || wasOffline {
            client.resetSession()
        }
        startServerDiscovery()
        try? await Task.sleep(for: .milliseconds(500))
        activeServerURL = serverURL
        do {
            try await establishSession()
        } catch {
            if Self.isCancellation(error) {
                log("Connection task cancelled by the app lifecycle", level: .notice)
                return
            }
            // The server generates its own certificate authority, which no Apple device trusts
            // out of the box - so an https:// address (the default that server discovery
            // advertises) would simply never connect on a fresh install. The server keeps its
            // plain-HTTP listener open precisely for app clients in this position, so fall back
            // to it rather than stranding the user. Mirrors the iOS/macOS app, including only
            // falling back to a server that proves it is this one (see ServerIdentity) - the
            // plain-HTTP requests carry the session cookie.
            if Self.isUntrustedCertificate(error),
               let fallback = Self.httpFallbackAddress(for: activeServerURL) {
                let httpsAddress = activeServerURL
                let identity = await ServerIdentity.check(httpsAddress)
                switch identity {
                case .mismatch:
                    log("The server at \(httpsAddress) presented a certificate its own authority didn't sign - not falling back to plain HTTP", level: .error)
                    connectionState = .offline
                    lastError = "Something at this address isn't your ReelHouse server - its certificate wasn't issued by your server. Nothing was sent to it. If you reinstalled the server, save its address again in Settings."
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
                    SessionCookieStore.clear()
                }
                log("This device does not trust the server's HTTPS certificate; trying the plain-HTTP port at \(fallback)", level: .notice)
                activeServerURL = fallback
                do {
                    try await establishSession()
                    if case .unknown(let leaf) = identity {
                        if let authority = await ServerIdentity.fetchAuthority(from: fallback),
                           ServerIdentity.remember(authority: authority, signing: leaf, for: httpsAddress) {
                            log("Remembered this server's certificate authority; plain-HTTP fallback now only goes to this server")
                        } else {
                            log("Couldn't remember the server's certificate authority; the next fallback is treated as a first one", level: .notice)
                        }
                    }
                    log("Connected over plain HTTP. For an encrypted connection instead, trust the server's certificate authority (ca.crt) on this device.", level: .notice)
                    return
                } catch {
                    if Self.isCancellation(error) {
                        log("Connection task cancelled by the app lifecycle", level: .notice)
                        return
                    }
                    activeServerURL = serverURL
                    failConnection(with: error)
                    return
                }
            }
            failConnection(with: error)
        }
    }

    // The post-address half of connect(), split out so the certificate-trust fallback above can
    // run it a second time against the plain-HTTP address.
    private func establishSession() async throws {
        authStatus = try await client.authStatus()
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
            log("Could not read the server's version: \(error.localizedDescription)", level: .info)
            return
        }
        if let advisory = serverCompatibility.advisory {
            log(advisory, level: .notice)
        }
    }

    private func failConnection(with error: Error) {
        connectionState = .offline
        lastError = Self.userFacingMessage(for: error)
        log("Connection failed: \(error.localizedDescription)", level: .error)
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
            return "Can't reach anything on your local network. Check this Apple TV is on the same network as the server - and if ReelHouse was denied Local Network access, turn it back on under Settings → General → Privacy & Security → Local Network."
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

    // https://host[:port] -> http://host:3350, the dashboard's shipped plain-HTTP port. A custom
    // HTTP port can't be derived from the HTTPS address, so the default is the only sensible guess.
    // What may start the plain-HTTP fallback: the certificate was judged and not trusted. Narrower
    // than isCertificateTrustFailure, which also counts a bare handshake failure (-1200) that
    // anything can produce without presenting a certificate. Mirrors the iOS/macOS app.
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

    static func httpFallbackAddress(for address: String) -> String? {
        guard var components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "https" else {
            return nil
        }
        components.scheme = "http"
        components.port = 3350
        return components.string
    }

    // What the tab bar needs from the server. Music and Podcasts ask for themselves - see
    // AudioCenter.connect.
    func refreshAll() async throws {
        isLoading = true
        defer { isLoading = false }
        // Its own endpoint that answers even while the section is off. A server that answers
        // with an error means "no Movies tab"; one that doesn't answer at all is a failed connection.
        do {
            moviesEnabled = try await client.mediaEnabled().enabled
            lastError = nil
        } catch let error as ClientError {
            if case .authenticationRequired = error { throw error }
            moviesEnabled = false
            lastError = nil
        } catch {
            if !Self.isCancellation(error) { lastError = error.localizedDescription }
            throw error
        }
        lastUpdated = .now
    }


    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }

    func log(_ message: String, level: DiagnosticLevel = .info) {
        diagnostics.insert(DiagnosticEntry(timestamp: .now, level: level, message: message), at: 0)
        if diagnostics.count > 100 {
            diagnostics.removeLast(diagnostics.count - 100)
        }
        print("[ReelHouseTV] [\(level.rawValue)] \(message)")
    }

    func clearDiagnostics() {
        diagnostics.removeAll()
    }

    // Browses for other ReelHouse servers on the LAN (used to populate ServerSetupView's
    // discovered-server list) and, as a side effect, is also what makes tvOS prompt for
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
                    // A browser that has failed never recovers on its own, and mDNS does hand
                    // back DefunctConnection (-65569) on a real Apple TV when the daemon's
                    // connection is torn out from under it. Without dropping the reference the
                    // guard at the top of startServerDiscovery() would refuse to ever build a
                    // new one, leaving the setup screen searching forever.
                    self.log("Local-network discovery failed: \(error); restarting", level: .error)
                    self.restartServerDiscovery()
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
        browser.start(queue: DispatchQueue(label: "com.reelhouse.tv.local-network-discovery"))
    }

    // Tears the failed browser down and builds a fresh one after a short pause. The delay keeps
    // a persistently unavailable mDNS daemon from turning into a tight rebuild loop; the results
    // are cleared because anything this browser found can no longer be trusted to still be there.
    private func restartServerDiscovery() {
        localNetworkBrowser?.cancel()
        localNetworkBrowser = nil
        discoveredServers.removeAll()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled else { return }
            self.startServerDiscovery()
        }
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
        connection.start(queue: DispatchQueue(label: "com.reelhouse.tv.local-network-discovery.resolve"))
    }

    func signIn(username: String, password: String) async throws {
        try await client.login(username: username, password: password)
        authStatus = try await client.authStatus()
        try await refreshAll()
        connectionState = .online
    }

    func signOut() async {
        try? await client.logout()
        authStatus = try? await client.authStatus()
        connectionState = requiresLogin ? .authenticationRequired : .online
    }

}

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
