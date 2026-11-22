import SwiftUI
#if os(iOS)
import UIKit
#endif

@main
struct ReelHouseApp: App {
    // The one AppModel, shared with CarPlay: the car can launch the app with no window, and
    // still needs it to reach the server.
    @StateObject private var appModel = AppModel.shared
    #if os(iOS)
    // APNs hands the device token to an app delegate, and there is no SwiftUI equivalent.
    @UIApplicationDelegateAdaptor(ReelHouseApplicationDelegate.self) private var appDelegate
    #endif

    init() {
        #if os(iOS)
        // Only large titles get this treatment (not the .inline titles on detail screens) -
        // largeTitleTextAttributes is a distinct attribute set from titleTextAttributes, so this
        // scopes itself automatically to exactly the top-level tabs (Movies, Music, Podcasts,
        // Settings) without touching anything pushed on top of them. Echoes BrandHeader's
        // glowing marquee-gold REELHOUSE wordmark.
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        let shadow = NSShadow()
        shadow.shadowColor = UIColor(ReelHouseTheme.gold).withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 8
        appearance.largeTitleTextAttributes = [
            .foregroundColor: UIColor(ReelHouseTheme.gold),
            .font: UIFont.systemFont(ofSize: 34, weight: .black),
            .shadow: shadow
        ]
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 760)
        .commands {
            AudioCommands()
        }
        #endif

        #if os(macOS)
        // Music and Podcasts' Now Playing, in a window of its own as on the Mac's Music app.
        Window("Now Playing", id: NowPlayingView.windowId) {
            NowPlayingView()
                .environmentObject(appModel)
        }
        .defaultSize(width: 980, height: 680)

        // Cmd+, and the app-menu "Settings…" item. The same screen is also a sidebar row in the
        // main window (see AppSection) - this is the Mac convention on top of it, not instead
        // of it.
        //
        // The NavigationStack is load-bearing, not decoration: SettingsView's Manage Accounts,
        // Movies & TV Libraries and Server Settings rows are NavigationLinks, and a Settings
        // scene provides no navigation container of its own.
        Settings {
            NavigationStack {
                SettingsView()
            }
            .environmentObject(appModel)
            .frame(minWidth: 480, minHeight: 520)
        }
        #endif
    }
}
