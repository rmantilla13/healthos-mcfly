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
        @Bindable var dashboard = dashboard
        TabView(selection: $dashboard.tab) {
            TodayScreen()
                .tabItem { Label("Today", systemImage: "heart.text.square") }
                .tag(AppTab.today)
            // Only on servers with the Family board (older ones don't name the setting, and answer 404).
            if dashboard.familyAvailable {
                FamilyScreen()
                    .tabItem { Label("Family", systemImage: "person.2") }
                    .tag(AppTab.family)
            }
            TrendsScreen()
                .tabItem { Label("Trends", systemImage: "chart.xyaxis.line") }
                .tag(AppTab.trends)
            // For everyone: while Nutrition is off, it explains it and turns it on.
            NutritionScreen()
                .tabItem { Label("Nutrition", systemImage: "fork.knife") }
                .tag(AppTab.nutrition)
            InsightsScreen()
                .tabItem { Label("Insights", systemImage: "lightbulb") }
                .tag(AppTab.insights)
        }
        // Settings opens over any tab: from each tab's gear, Today's avatar, and every "Open Settings".
        .sheet(isPresented: $dashboard.showingSettings) {
            SettingsScreen()
                .environment(dashboard)
                .environment(sync)
        }
        .environment(dashboard)
        .environment(sync)
        .tint(Palette.series1)
        .onAppear {
            sync.dashboard = dashboard
            KeyboardDismisser.install()
            openDigestIfTapped()
        }
        // The Family tab went away (another server, or one without the board) while it was showing.
        .onChange(of: dashboard.familyAvailable) { _, available in
            if !available, dashboard.tab == .family { dashboard.tab = .today }
        }
        // A server whose status doesn't name familySharing may still have the board: ask once, so the tab can show.
        .task(id: dashboard.generation) {
            if dashboard.status != nil, dashboard.status?.settings?.familySharing == nil, !dashboard.familyMissing, dashboard.familyBoard == nil {
                await dashboard.loadFamily()
            }
        }
        // The weekly digest notification was tapped: show it on the Insights tab.
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
        if DigestNotifications.takeOpenRequest() { dashboard.tab = .insights }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Before launch finishes, so a tap that launches the app still reaches didReceive.
        UNUserNotificationCenter.current().delegate = self
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
