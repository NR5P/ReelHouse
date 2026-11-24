import SwiftUI

// tvOS port of ios/ReelHouse/Views/LoginView.swift.
struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var username = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var signingIn = false

    var body: some View {
        VStack(spacing: 36) {
            BrandHeader().frame(maxWidth: 520)
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sign in").font(.title2.bold())
                    if let host = URL(string: model.activeServerURL)?.host() {
                        Text("to ReelHouse on \(host)").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 8)
                TextField("Username", text: $username)
                    .textContentType(.username)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(ReelHouseTheme.red)
                }
                // The app's own button: frosted at rest, gold under focus. The prominent style
                // painted a gold pill with a pale label that was unreadable while it was disabled -
                // which is how it sits until both fields are filled in.
                Button {
                    Task { await signIn() }
                } label: {
                    Text(signingIn ? "Connecting…" : "Sign In")
                        .frame(maxWidth: .infinity)
                }
                .disabled(signingIn || username.isEmpty || password.isEmpty)
                .padding(.top, 8)
            }
            .padding(24)
            .reelHouseCard()
            .frame(maxWidth: 680)
        }
        .padding(80)
        .onSubmit {
            guard !signingIn, !username.isEmpty, !password.isEmpty else { return }
            Task { await signIn() }
        }
    }

    private func signIn() async {
        signingIn = true
        defer { signingIn = false }
        do {
            try await model.signIn(username: username, password: password)
            password = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
