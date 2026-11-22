import SwiftUI

struct ServerSetupView: View {
    @EnvironmentObject private var model: AppModel
    @State private var address = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                BrandHeader().frame(maxWidth: 420)
                welcome
                VStack(alignment: .leading, spacing: 14) {
                    Text("Connect to your server")
                        .foregroundStyle(ReelHouseTheme.curtain)
                        .font(.headline)

                    discoverySection

                    // verbatim: a plain string literal gets its example URLs turned into links.
                    Text(verbatim: "Or enter its address: the one on your home network, like http://192.168.1.50:3350, or a web address such as https://home.example.com.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("http://192.168.1.50:3350", text: $address)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        #endif
                    Button("Connect") {
                        connect()
                    }
                    .buttonStyle(.reelHouseProminent)
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .reelHouseCard()
                .frame(maxWidth: 500)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            address = model.serverURL
            model.startServerDiscovery()
        }
        .onSubmit(connect)
    }

    // What someone who just found the app in a store needs before an address field means anything:
    // what the app is for, and that it talks to a server in their own home.
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Welcome to ReelHouse")
                .foregroundStyle(ReelHouseTheme.gold)
                .font(.headline)
            Text("This app connects to ReelHouse, a media server that runs on a computer in your own home: movies and TV, music and podcasts. Your library stays on that computer; this app is how you watch and listen to it.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Don't have a server yet? Install the ReelHouse server on a computer at home first, then come back here.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .reelHouseCard()
        .frame(maxWidth: 500)
    }

    // Purely an assist on top of manual entry below, which always stays visible - discovery can
    // legitimately find nothing (client/AP isolation, a different VLAN, local-network permission
    // denied, ...), and that must never block getting connected by typing the address instead.
    @ViewBuilder
    private var discoverySection: some View {
        if model.discoveredServers.isEmpty {
            Text("Searching your local network for a server…")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Found on your network")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(model.discoveredServers) { server in
                    Button {
                        address = server.addressString
                        connect()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name).foregroundStyle(.primary)
                                Text(server.addressString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(ReelHouseTheme.curtain.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func connect() {
        ServerIdentity.forget(normalized(address))
        model.serverURL = normalized(address)
    }

    // A home-network address (an IP, a .local name, a bare computer name) gets http://, which is
    // how the dashboard ships. Anything else is an internet address and gets https://: typing
    // "home.example.com" must never send a password across the internet in plain text.
    private func normalized(_ value: String) -> String { Self.normalizedAddress(value) }

    // A home-network address typed with no port also gets the dashboard's :3350. "192.168.1.50"
    // on its own is what a new owner types, and it used to land on port 80 and an app that just
    // said Offline. Only when nothing was typed but the address: a scheme or a port means the
    // owner chose it.
    static func normalizedAddress(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme: String
        if trimmed.contains("://") {
            withScheme = trimmed
        } else if isHomeNetworkAddress(trimmed) {
            withScheme = withDefaultPort("http://\(trimmed)")
        } else {
            withScheme = "https://\(trimmed)"
        }
        return withScheme.hasSuffix("/") ? String(withScheme.dropLast()) : withScheme
    }

    static let defaultPort = 3350

    private static func withDefaultPort(_ address: String) -> String {
        guard var components = URLComponents(string: address), components.host?.isEmpty == false,
              components.port == nil else { return address }
        components.port = defaultPort
        return components.string ?? address
    }

    static func isHomeNetworkAddress(_ typed: String) -> Bool {
        guard let host = URLComponents(string: "x://\(typed)")?.host?.lowercased(), !host.isEmpty else { return true }
        if host == "localhost" || !host.contains(".") || host.contains(":") { return true }
        if host.split(separator: ".").allSatisfy({ Int($0) != nil }) { return true }
        return [".local", ".lan", ".home", ".internal", ".home.arpa"].contains { host.hasSuffix($0) }
    }
}
