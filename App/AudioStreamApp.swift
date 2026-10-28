import SwiftUI
import UIKit
import Combine

enum QuickAction: String {
    case shuffleAll = "com.saihgupr.audiostream.quickaction.shuffleall"
    case recentlyAdded = "com.saihgupr.audiostream.quickaction.recentlyadded"
    case randomAlbum = "com.saihgupr.audiostream.quickaction.randomalbum"
}

final class QuickActionManager: ObservableObject {
    static let shared = QuickActionManager()

    @Published private(set) var pendingAction: QuickAction?
    private var lastHandledAction: (action: QuickAction, date: Date)?

    private init() {}

    func handle(_ shortcutItem: UIApplicationShortcutItem) {
        guard let action = QuickAction(rawValue: shortcutItem.type) else { return }

        // The shortcut may be delivered through both launch options and
        // performActionFor during a cold launch; ignore the duplicate.
        if let last = lastHandledAction,
           last.action == action,
           Date().timeIntervalSince(last.date) < 2 {
            return
        }

        lastHandledAction = (action, Date())
        pendingAction = action
    }

    func consumePendingAction() -> QuickAction? {
        guard let action = pendingAction else { return nil }
        pendingAction = nil
        return action
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let shortcutItem = connectionOptions.shortcutItem {
            QuickActionManager.shared.handle(shortcutItem)
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        QuickActionManager.shared.handle(shortcutItem)
        completionHandler(true)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if let shortcutItem = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
            QuickActionManager.shared.handle(shortcutItem)
        }
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if let shortcutItem = options.shortcutItem {
            QuickActionManager.shared.handle(shortcutItem)
        }

        let configuration = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        QuickActionManager.shared.handle(shortcutItem)
        completionHandler(true)
    }
}

@main
struct AudioStreamApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var connectionService = ServerConnectionService()
    @StateObject private var audioService = AudioPlayerService()
    // MusicLibraryService depends on ConnectionService, so we might need to initialize it differently 
    // or just pass connectionService to it in views for now.
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(connectionService)
                .environmentObject(audioService)
                .preferredColorScheme(.dark)
        }
    }
}
