import UIKit

// MARK: - App entry point.  Classic UIApplicationDelegate + one UIWindow (no scene manifest in Info.plist).
// The whole game lives in GameViewController / GameContext; this file only owns the app life cycle.

@main
@MainActor
final class AppDelegate: UIResponder, UIApplicationDelegate {

    /// Posted on the main queue when iOS reports memory pressure (caches may be dropped by interested modules).
    static let memoryWarningNotification: Notification.Name = Notification.Name("SupercarsMemoryWarning")

    /// The GameContext of the running game (set by GameViewController). Weak: the view controller owns it.
    static weak var activeContext: GameContext?

    var window: UIWindow?

    // MARK: Launch

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        application.isIdleTimerDisabled = true

        let newWindow: UIWindow = UIWindow(frame: UIScreen.main.bounds)
        newWindow.backgroundColor = UIColor.black
        newWindow.rootViewController = GameViewController()
        newWindow.makeKeyAndVisible()
        window = newWindow
        return true
    }

    // MARK: Orientation lock (landscape only)

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return UIInterfaceOrientationMask.landscape
    }

    // MARK: Life cycle

    func applicationDidBecomeActive(_ application: UIApplication) {
        application.isIdleTimerDisabled = true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Phone call, control centre, app switcher ... pause the game (no-op unless on foot / driving) and persist progress.
        if let ctx = AppDelegate.activeContext {
            ctx.pause()
        }
        AppDelegate.saveActiveContext()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        AppDelegate.saveActiveContext()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        AppDelegate.saveActiveContext()
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        AppDelegate.saveActiveContext()
        URLCache.shared.removeAllCachedResponses()
        NotificationCenter.default.post(name: AppDelegate.memoryWarningNotification, object: nil)
    }

    // MARK: Helpers

    private static func saveActiveContext() {
        guard let ctx = AppDelegate.activeContext else { return }
        ctx.save.saveNow()
        ctx.settings.saveNow()
    }
}
