import SwiftUI
import UIKit

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
    @State private var dashboard = Dashboard()
    @State private var sync = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var dashboard = dashboard
        TabView(selection: $dashboard.tab) {
            TodayScreen()
                .tabItem { Label("Today", systemImage: "heart.text.square") }
                .tag(AppTab.today)
            TrendsScreen()
                .tabItem { Label("Trends", systemImage: "chart.xyaxis.line") }
                .tag(AppTab.trends)
            SettingsScreen()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .environment(dashboard)
        .environment(sync)
        .tint(Palette.series1)
        .onAppear {
            sync.dashboard = dashboard
            KeyboardDismisser.install()
        }
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
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        #if targetEnvironment(simulator)
        // Scripted runs: `xcrun simctl launch booted health.mcfly.sync -healthosToken <token>`.
        if let token = UserDefaults.standard.string(forKey: "healthosToken") { Config.token = token }
        #endif
        // HealthKit relaunches the app in the background for new data; the observer queries have to be
        // registered again before launch finishes, or that delivery is missed.
        Background.register()
        Background.apply()
        return true
    }
}
