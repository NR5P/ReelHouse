import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var username = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var signingIn = false

    var body: some View {
        VStack(spacing: 24) {
            BrandHeader().frame(maxWidth: 420)
            VStack(alignment: .leading, spacing: 14) {
                Text("Sign in").foregroundStyle(ReelHouseTheme.curtain).font(.headline)
                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(ReelHouseTheme.red)
                }
                Button(signingIn ? "Connecting…" : "Sign In") {
                    Task { await signIn() }
                }
                .buttonStyle(.reelHouseProminent)
                .disabled(signingIn || username.isEmpty || password.isEmpty)
            }
            .reelHouseCard()
            .frame(maxWidth: 460)
        }
        .padding()
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
