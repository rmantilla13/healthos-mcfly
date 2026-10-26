import SwiftUI
import UIKit
import UserNotifications

@main
struct HealthOSSyncApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @State private var dashboard = Dashboard(tokenStore: KeychainTokenStore())
    @State private var sync = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        AppShell()
            .environment(dashboard)
            .environment(sync)
            // DM Sans for any text that doesn't set its own font (Form rows, labels, fields).
            .font(.app(.body))
            .tint(Palette.tint)
            .onAppear {
                sync.dashboard = dashboard
                KeyboardDismisser.install()
                openDigestIfTapped()
            }
            // A server whose status doesn't name familySharing may still have the board: ask once, so More can list it.
            .task(id: dashboard.generation) {
                if dashboard.status != nil, dashboard.status?.settings?.familySharing == nil, !dashboard.familyMissing, dashboard.familyBoard == nil {
                    await dashboard.loadFamily()
                }
            }
            // The weekly digest notification was tapped: show it on Insights, under More.
            .onReceive(NotificationCenter.default.publisher(for: .openWeeklyDigest)) { _ in openDigestIfTapped() }
            // On open and on every return to the app: one Sync for Apple Health and WHOOP.
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .background { Background.schedule() }
                guard phase == .active else { return }
                Task {
                    // After an update that reads a new type, Health asks about it now; it shows nothing otherwise.
                    if Config.healthRequested { await sync.requestHealthAccess() }
                    await dashboard.startIfNeeded()
                    await sync.syncAllIfStale()
                }
            }
            // While the app is open: a cheap check every minute; summary and trends download only when data changed.
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    if Task.isCancelled { break }
                    await dashboard.refreshIfChanged(includeStatus: false)
                }
            }
    }

    private func openDigestIfTapped() {
        if DigestNotifications.takeOpenRequest() { dashboard.open(.insights) }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Before launch finishes, so a tap that launches the app still reaches didReceive.
        UNUserNotificationCenter.current().delegate = self
        AppFont.styleBars()
        #if targetEnvironment(simulator)
        // Scripted runs: `xcrun simctl launch booted health.mcfly.sync -healthosToken <token>`. As if pasted while signed
        // out: whoever signs in next is its owner, and nothing of an earlier run's owner or pause is kept.
        if let token = UserDefaults.standard.string(forKey: "healthosToken") {
            Config.token = token
            Config.ingestOwner = IngestTokenOwner(claim: .nextSignIn)
        }
        #endif
        // HealthKit relaunches the app in the background for new data; the observer queries have to be
        // registered again before launch finishes, or that delivery is missed.
        Background.register()
        Background.apply()
        return true
    }

    /// The weekly digest reminder shows even while the app is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.identifier == DigestNotifications.id {
            Task { @MainActor in DigestNotifications.requestOpen() }
        }
        completionHandler()
    }
}
