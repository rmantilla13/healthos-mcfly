import SwiftUI
import UIKit

@main
struct HealthOSSyncApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        #if targetEnvironment(simulator)
        // Scripted runs: `xcrun simctl launch booted dev.healthos.sync -healthosToken <token>`.
        if let token = UserDefaults.standard.string(forKey: "healthosToken") { Config.token = token }
        #endif
        // HealthKit relaunches the app in the background for new data; the observer queries have to be
        // registered again before launch finishes, or that delivery is missed.
        Background.apply()
        return true
    }
}
