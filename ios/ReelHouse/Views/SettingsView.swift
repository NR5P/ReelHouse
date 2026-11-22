import SwiftUI
#if os(iOS)
import UIKit
import UserNotifications
#endif

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var address = ""
    @State private var remoteAddress = ""
    @State private var showingDiagnostics = false
    @State private var showingChangePassword = false

    var body: some View {
        Form {
            // Which sections have a tab on an iPhone - also on the More tab, whenever there is one.
            if horizontalSizeClass == .compact {
                Section {
                    NavigationLink {
                        TabBarEditor(visible: AppSection.visibleCases(
                            moviesEnabled: model.moviesEnabled,
                            musicEnabled: model.musicEnabled,
                            podcastsEnabled: model.podcastsEnabled))
                    } label: {
                        Label("Customize Tab Bar", systemImage: "square.grid.2x2")
                    }
                }
            }
            Section("Server") {
                // Both addresses are typed in by hand, and the label has to survive being filled
                // in: a bare TextField in a Form draws no box, and its placeholder - the only
                // thing naming it - disappears the moment there's an address in it.
                ReelHouseTextField(
                    label: "Server address",
                    prompt: "http://192.168.1.50:3350",
                    text: $address)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                ReelHouseTextField(
                    label: "Remote address (optional)",
                    prompt: "https://reelhouse.example.com",
                    text: $remoteAddress)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                HStack {
                    Text("Status")
                    Spacer()
                    if model.hasRemoteServerURL {
                        Text(model.isUsingRemote ? "via Remote" : "via Local")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ConnectionBadge().frame(maxWidth: 190)
                }
                if model.usingHttpFallback {
                    Text("Connected over plain HTTP: this device doesn't trust the certificate the server generated for itself, so the https:// address can't be used yet. Everything works, and traffic stays on your local network. For an encrypted connection, install the server's certificate authority (certs/ca.crt on the server) on this device and mark it trusted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("A Cloudflare Tunnel (or any other externally-reachable) address to use when the local address can't be reached, such as away from home on cellular. Point it at the server's Internet Exposed port, not the normal port — that port always requires a login, while the normal one trusts the local network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Save and Reconnect") {
                    Task {
                        // Saving the address is the way past a server whose certificate authority
                        // changed (a reinstall) - see ServerIdentity.
                        ServerIdentity.forget(normalized(address))
                        model.serverURL = normalized(address)
                        model.remoteServerURL = remoteAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? ""
                            : normalized(remoteAddress, defaultScheme: "https")
                        await model.connect(resetNetworkSession: true)
                    }
                }
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if model.musicEnabled || model.podcastsEnabled {
                AudioSettingsSection()
            }

            Section("Account") {
                if let username = model.authStatus?.username {
                    LabeledContent("Signed in as", value: username)
                }
                if let role = model.authStatus?.role {
                    LabeledContent("Role", value: role.capitalized)
                }
                if model.authStatus?.enabled == true {
                    Button("Change Password") { showingChangePassword = true }
                    Button("Sign Out", role: .destructive) {
                        Task { await model.signOut() }
                    }
                } else {
                    Text("Server login is not enabled.")
                        .foregroundStyle(.secondary)
                }
            }

            #if os(iOS)
            NotificationsSection()
            #endif

            // Accounts, libraries and server settings are all AdminOnly on the server - hidden
            // entirely for a Viewer rather than shown-disabled.
            if model.isAdmin {
                Section {
                    NavigationLink("Manage Accounts") {
                        AccountAdminView()
                    }
                    // The switch itself, as opposed to the accounts it governs - the web
                    // UI's LOGIN section.
                    NavigationLink("Server Login") {
                        ServerLoginView()
                    }
                } header: {
                    Text("Accounts")
                } footer: {
                    Text("Whether ReelHouse requires a login at all, and who can sign in.")
                }
                Section {
                    NavigationLink("Movies & TV Libraries") {
                        MediaLibrariesAdminView()
                    }
                } header: {
                    Text("Movies & TV")
                } footer: {
                    Text("The folders the Movies tab is built from - on the server, or shared from another computer on your network.")
                }
                Section {
                    NavigationLink("Server Settings") {
                        ServerSettingsView()
                    }
                } header: {
                    Text("Server Configuration")
                } footer: {
                    Text("Every server setting the web UI has, editable from here.")
                }
            }

            if let lastError = model.lastError {
                Section("System") {
                    Text(lastError).foregroundStyle(ReelHouseTheme.red)
                }
            }

            Section("Diagnostics") {
                DisclosureGroup("Connection Log", isExpanded: $showingDiagnostics) {
                    if model.diagnostics.isEmpty {
                        Text("No requests recorded yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        // Monospace is kept here on purpose - this is genuinely tabular/log
                        // content, unlike the rest of the app's now-system-font text.
                        ForEach(model.diagnostics.prefix(30)) { entry in
                            VStack(alignment: .leading, spacing: 3) {
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
                                    .textSelection(.enabled)
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

            Section("About") {
                LabeledContent("App Version", value: Self.appVersion)
                NavigationLink("Acknowledgements") { AcknowledgementsView() }
            }

            Section {
                Text("This app manages its own connection. Server settings edited here and in the web UI are the same settings - a change in either place shows up in both.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .onAppear {
            address = model.serverURL
            remoteAddress = model.remoteServerURL
        }
        .onChange(of: model.serverURL) { _, newValue in address = newValue }
        .onChange(of: model.remoteServerURL) { _, newValue in remoteAddress = newValue }
        .sheet(isPresented: $showingChangePassword) {
            ChangePasswordSheet()
        }
    }

    // Local addresses default to http:// (a bare LAN IP typing "192.168.1.50" shouldn't force a
    // scheme nobody configured). The remote address defaults to https:// instead: it's meant to
    // reach a public internet-facing hostname (e.g. a Cloudflare Tunnel), and silently falling
    // back to plain HTTP there would send credentials/cookies over the internet in the clear.
    private func normalized(_ value: String, defaultScheme: String = "http") -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.contains("://") ? trimmed : "\(defaultScheme)://\(trimmed)"
        return withScheme.hasSuffix("/") ? String(withScheme.dropLast()) : withScheme
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

}

#if os(iOS)
// Push notifications: permission on this device, whether the server sends any, and a test send
// to this account's devices. Registration itself happens on its own once signed in - see
// AppModel.startPushNotifications.
private struct NotificationsSection: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL
    @State private var authorization: UNAuthorizationStatus?
    @State private var status: PushStatus?
    @State private var statusError: String?
    @State private var sendingTest = false
    @State private var testResult: String?
    @State private var testFailed = false

    private var isOnline: Bool { model.connectionState == .online }

    var body: some View {
        Section {
            LabeledContent("On This Device", value: permissionLabel)
            if authorization == .denied {
                Button("Open iOS Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
            } else if authorization == .notDetermined {
                Button("Turn On Notifications") {
                    Task {
                        await model.startPushNotifications()
                        await refresh()
                    }
                }
                .disabled(!isOnline)
            }
            if let serverLine {
                Text(serverLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(sendingTest ? "Sending…" : "Send Test Notification") {
                Task { await sendTest() }
            }
            .disabled(sendingTest || !isOnline)
            if let testResult {
                Text(testResult)
                    .font(.caption)
                    .foregroundStyle(testFailed ? ReelHouseTheme.red : .secondary)
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("New episodes of podcasts with Notify Me of New Episodes on, finished movie and TV downloads, and sign-ins to your account.")
        }
        .task(id: isOnline) { await refresh() }
        // Back from iOS Settings, where notifications may have just been switched on.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task {
                await refresh()
                if let authorization, AppModel.pushAllowed(authorization) { await model.startPushNotifications() }
            }
        }
    }

    private var permissionLabel: String {
        switch authorization {
        case .authorized, .ephemeral: "Allowed"
        case .provisional: "Delivered Quietly"
        case .denied: "Off"
        case .notDetermined: "Not Asked Yet"
        case nil: "…"
        @unknown default: "Unknown"
        }
    }

    private var serverLine: String? {
        if let statusError { return "Couldn't check the server: \(statusError)" }
        guard let status else { return nil }
        let adminHint = "an admin can turn it on in the web Settings → Push Notifications"
        if !status.enabled { return "Off on the server — \(adminHint)." }
        if !status.appleConfigured {
            return "On, but the server has no Apple push key set up yet — an admin can add one in the web Settings → Push Notifications."
        }
        let kinds = [
            status.newEpisodes ? "new episodes" : nil,
            status.downloads ? "downloads" : nil,
            status.loginAlerts ? "sign-in alerts" : nil
        ].compactMap { $0 }
        if kinds.isEmpty { return "On, but every kind of notification is switched off on the server." }
        let devices = status.myDevices == 1 ? "1 device" : "\(status.myDevices) devices"
        return "On for \(kinds.joined(separator: ", ")). \(devices) registered to your account."
    }

    private func refresh() async {
        authorization = await PushNotificationCoordinator.shared.authorizationStatus()
        guard isOnline else { return }
        do {
            status = try await model.client.pushStatus()
            statusError = nil
        } catch {
            status = nil
            statusError = error.localizedDescription
        }
    }

    private func sendTest() async {
        sendingTest = true
        defer { sendingTest = false }
        do {
            let report = try await model.client.testPushNotification()
            testFailed = report.delivered == 0
            var result = report.delivered > 0
                ? "Sent to \(report.delivered) of \(report.attempted) device\(report.attempted == 1 ? "" : "s")."
                : "The server tried \(report.attempted) device\(report.attempted == 1 ? "" : "s"), but none accepted it."
            if report.removed > 0 {
                result += " \(report.removed) no longer valid and removed."
            }
            testResult = result
            if !testFailed { SaveFeedback.hapticSuccess() }
        } catch {
            testFailed = true
            testResult = error.localizedDescription
        }
        await refresh()
    }
}
#endif

private struct ChangePasswordSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var canSave: Bool {
        !currentPassword.isEmpty && newPassword.count >= 8 && newPassword == confirmPassword
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ReelHouseTextField(label: "Current password", text: $currentPassword, secure: true)
                    ReelHouseTextField(label: "New password", prompt: "At least 8 characters", text: $newPassword, secure: true)
                    ReelHouseTextField(label: "Confirm new password", text: $confirmPassword, secure: true)
                }
                if !confirmPassword.isEmpty && newPassword != confirmPassword {
                    Section {
                        Text("New passwords don't match.").foregroundStyle(ReelHouseTheme.red)
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(ReelHouseTheme.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Change Password")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(isSaving || !canSave)
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        do {
            try await model.client.changeMyPassword(currentPassword: currentPassword, newPassword: newPassword)
            SaveFeedback.hapticSuccess()
            dismiss()

            // The server ends every session for the account when the password changes, this
            // device's included, so that a cookie somebody else is holding stops working.
            // Reconnecting immediately is what turns that into a sign-in prompt: without it the
            // app looks connected until whatever the user does next fails, which reads as a bug
            // rather than as the sign-out it is.
            await model.connect()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
