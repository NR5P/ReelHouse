// Push notifications on the iPhone and iPad: new podcast episodes, finished movie downloads and
// sign-in alerts, sent by the server through APNs. Ported from SentinelCore's coordinator.
// iOS only - the Mac build has no push entitlement and never registers.
#if os(iOS)
import Foundation
import UIKit
@preconcurrency import UserNotifications

extension Notification.Name {
    static let reelHousePushTokenChanged = Notification.Name("reelHousePushTokenChanged")
    static let reelHousePushOpened = Notification.Name("reelHousePushOpened")
    static let reelHousePushRegistrationFailed = Notification.Name("reelHousePushRegistrationFailed")
}

// Where tapping a notification takes the person - read from the payload's custom top-level keys
// (`type`, `itemId`, `podcastId`). Login and test alerts just open the app.
enum PushRoute: Equatable, Sendable {
    case podcast(podcastId: String?, episodeId: String?)
    case download(itemId: String?)

    init?(userInfo: [AnyHashable: Any]) {
        switch userInfo["type"] as? String {
        case "podcast":
            self = .podcast(podcastId: Self.string(userInfo["podcastId"]), episodeId: Self.string(userInfo["itemId"]))
        case "download":
            self = .download(itemId: Self.string(userInfo["itemId"]))
        default:
            return nil
        }
    }

    // Ids are strings, but a number shouldn't silently drop the route.
    private static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: text.isEmpty ? nil : text
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }
}

@MainActor
final class PushNotificationCoordinator {
    static let shared = PushNotificationCoordinator()

    private(set) var currentDeviceToken: String?
    private var pendingRoute: PushRoute?

    private init() {}

    func configure() {
        UNUserNotificationCenter.current().delegate = PushAppDelegate.shared
    }

    // Asking APNs for a token shows nothing to the person, so it happens at every launch; the
    // permission prompt waits until they're signed in (AppModel.startPushNotifications).
    func registerWithAPNs() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    func requestAuthorization() async throws -> Bool {
        let granted = try await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge, .sound])
        if granted {
            registerWithAPNs()
        }
        return granted
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func receivedDeviceToken(_ data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        currentDeviceToken = token
        NotificationCenter.default.post(name: .reelHousePushTokenChanged, object: token)
    }

    func registrationFailed(_ error: Error) {
        NotificationCenter.default.post(
            name: .reelHousePushRegistrationFailed,
            object: error.localizedDescription
        )
    }

    // Kept as well as posted: a tap that cold-launches the app can arrive before AppModel is
    // listening.
    func openedNotification(_ route: PushRoute) {
        pendingRoute = route
        NotificationCenter.default.post(name: .reelHousePushOpened, object: nil)
    }

    func takePendingRoute() -> PushRoute? {
        defer { pendingRoute = nil }
        return pendingRoute
    }

    var deviceName: String { UIDevice.current.name }

    // Which APNs gateway this build's tokens belong to. An Xcode or devicectl install is signed
    // with a development profile whose aps-environment is "development" (sandbox gateway);
    // TestFlight and the App Store are "production". A token sent to the wrong gateway is
    // rejected as BadDeviceToken, so the server needs to know.
    static let apnsSandbox: Bool = {
        #if targetEnvironment(simulator)
        return true
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else {
            // App Store builds carry no profile at all.
            return false
        }
        return ProvisioningProfile.apsEnvironment(in: data) == "development"
        #endif
    }()
}

enum ProvisioningProfile {
    // embedded.mobileprovision is a signed CMS envelope with the profile's plist inside it as
    // plain text, so cutting the plist out and parsing it is enough - no CMS decoding needed.
    static func apsEnvironment(in data: Data) -> String? {
        if let start = data.range(of: Data("<?xml".utf8)) ?? data.range(of: Data("<plist".utf8)),
           let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
           let plist = try? PropertyListSerialization.propertyList(
               from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any],
           let entitlements = plist["Entitlements"] as? [String: Any] {
            return entitlements["aps-environment"] as? String
        }
        // Couldn't parse it; fall back to looking for the key/value pair as text.
        let text = String(decoding: data, as: UTF8.self)
        let development = #"<key>aps-environment</key>\s*<string>development</string>"#
        return text.range(of: development, options: .regularExpression) != nil ? "development" : nil
    }
}

final class PushAppDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = PushAppDelegate()

    // Shown while the app is open too - a new episode or a finished download is just as worth
    // seeing then.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let route = PushRoute(userInfo: response.notification.request.content.userInfo) else { return }
        await MainActor.run {
            PushNotificationCoordinator.shared.openedNotification(route)
        }
    }
}

@MainActor
final class ReelHouseApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PushNotificationCoordinator.shared.configure()
        PushNotificationCoordinator.shared.registerWithAPNs()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushNotificationCoordinator.shared.receivedDeviceToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        PushNotificationCoordinator.shared.registrationFailed(error)
    }
}
#endif
