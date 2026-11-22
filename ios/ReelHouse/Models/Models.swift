import Foundation

// SettingsSecrets.Mask on the server. Any stored secret is replaced by this on its way out, and
// sending it back unchanged means "keep the one you have" - the contract every secret on
// the settings screen follows.
enum ReelHouseSecrets {
    static let mask = "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}"
}

struct AuthStatus: Codable {
    let enabled: Bool
    let configured: Bool
    let authenticated: Bool
    let username: String?
    // Absent on servers older than the multi-account update - treated as Admin everywhere it's
    // read, since that's what every pre-upgrade single-account login effectively was.
    let role: String?
}

struct Account: Codable, Identifiable, Hashable {
    let id: UUID
    let username: String
    let displayName: String?
    let role: String
    let createdAt: Date
}

// The server answers a bad request two different ways: its own {error}/{errors} shape from the
// validation paths, and ASP.NET's RFC 7807 ProblemDetails from Results.Problem, whose message
// lives in `detail`. Only the first two were read, so every Results.Problem in the app surfaced as
// a bare "Server request failed (HTTP 502)" with the sentence explaining what to do about it
// thrown away.
struct APIError: Codable {
    let error: String?
    let errors: [String]?
    let detail: String?
}

struct LoginBody: Encodable {
    let username: String
    let password: String
}

struct CreateAccountBody: Encodable {
    let username: String
    let password: String
    let role: String
    let displayName: String?
}

struct UpdateRoleBody: Encodable {
    let role: String
}

struct ResetPasswordBody: Encodable {
    let newPassword: String
}

struct ChangePasswordBody: Encodable {
    let currentPassword: String
    let newPassword: String
}

// GET /api/push/status. `enabled` is the server-wide switch (web Settings → Push Notifications);
// myDevices counts this account's registered phones and TVs.
struct PushStatus: Codable {
    let enabled: Bool
    let appleConfigured: Bool
    let androidConfigured: Bool
    let myDevices: Int
    let newEpisodes: Bool
    let downloads: Bool
    let loginAlerts: Bool
}

// POST /api/push/devices and /unregister. The optional fields are left out of the unregister
// body (nil optionals aren't encoded).
struct PushDeviceBody: Encodable {
    let platform: String
    let token: String
    var deviceName: String?
    // "ios" or "tvos" - the server picks the APNs topic (bundle id) from it.
    var appVariant: String?
    // Which APNs gateway the token belongs to - see PushNotificationCoordinator.apnsSandbox.
    var apnsSandbox: Bool?
}

struct PushDeliveryReport: Codable {
    let attempted: Int
    let delivered: Int
    let failed: Int
    let removed: Int
}

extension JSONDecoder {
    static let reelHouse: JSONDecoder = {
        let decoder = JSONDecoder()
        // ASP.NET Core emits DateTimeOffset values with fractional seconds. Foundation's
        // built-in `.iso8601` strategy rejects those on some OS releases, so accept both
        // shapes explicitly.
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) {
                return date
            }
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid ISO-8601 date: \(value)"
            )
        }
        return decoder
    }()
}
