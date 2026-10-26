import SwiftUI

/// The Nutrition page, a tab (src/pages/Nutrition.tsx). Everyone sees it; while Nutrition is off it explains what turning
/// it on means and turns it on the way the web's Nutrition settings do: first a choice of what to see, nothing chosen in
/// advance, then on. Nothing is read from Health or kept until then.
struct NutritionScreen: View {
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        Group {
            if dashboard.signInRequired {
                SignInView()
            } else if dashboard.phase == .noServer {
                Unavailable("No server yet", systemImage: "server.rack", description: "Add your healthOS address in Profile.") {
                    Button("Open Profile") { dashboard.tab = .settings }
                }
            } else if dashboard.status == nil {
                // Whether Nutrition is on comes with the status: until it arrives there's nothing honest to show.
                if case .unavailable(let message) = dashboard.phase {
                    Unavailable("Can't load your dashboard", systemImage: "wifi.exclamationmark", description: message)
                } else {
                    ProgressView()
                }
            } else if dashboard.nutritionOn {
                // Each of its tabs scrolls on its own (the Log is a List).
                NutritionTrends()
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("From the food app you log in, through Apple Health. Only you can see it.")
                            .font(.app(.footnote)).foregroundStyle(Palette.ink3)
                        if dashboard.nutritionAvailable {
                            NutritionOptIn { withAnimation { proxy.scrollTo(NutritionOptIn.choicesID, anchor: .bottom) } }
                        } else {
                            Text("This healthOS server doesn't have Nutrition yet.")
                                .font(.app(.footnote)).foregroundStyle(Palette.ink2)
                                .card()
                        }
                    }
                    .padding(16)
                }
                .refreshable { await dashboard.load() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.page)
    }
}

/// What a person can choose to see, in the web's words (CHOICES in src/pages/Nutrition.tsx).
struct NutritionChoice: Identifiable {
    let mode: NutritionMode
    let title: String
    let text: String
    var id: String { mode.rawValue }

    static let all = [
        NutritionChoice(mode: .all, title: "Everything", text: "Calories, protein, carbs, fat, fiber, sugar, sodium and drinks."),
        NutritionChoice(mode: .noEnergy, title: "Everything except calories", text: "The same, with no calories anywhere, Ask McFly included."),
        NutritionChoice(mode: .none, title: "No amounts", text: "No calories or nutrient amounts: only what you logged, and when."),
    ]
}

/// Nutrition is off: what it is, and turning it on. The choice comes first and nothing is preselected; the server
/// refuses to turn it on without one.
private struct NutritionOptIn: View {
    static let choicesID = "nutritionChoices"
    /// Brings the choices into view once they appear (they open below a long explanation).
    let showChoices: () -> Void
    @Environment(Dashboard.self) private var dashboard
    @Environment(AppModel.self) private var sync
    @State private var choosing = false
    @State private var saving: NutritionMode?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "fork.knife")
                    .font(.headline)
                    .foregroundStyle(Tone.green.ink)
                    .frame(width: 40, height: 40)
                    .background(Tone.green.background, in: Circle())
                    .accessibilityHidden(true)
                Text("Nutrition is off").font(.app(.title3, weight: .semibold)).foregroundStyle(Palette.ink)
                Text("Reads what you log in a food app (MyFitnessPal, Cronometer, Lose It!, MacroFactor, Yazio) from Apple Health, as daily totals. Only you can see it: never your family, never the admin screens. Ask McFly can read it while this is on, only as much as you choose to see. healthOS never suggests a target.")
                    .font(.app(.subheadline)).foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("While this is off, healthOS doesn't read or keep your food logs.")
                    .font(.app(.footnote)).foregroundStyle(Palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                if !choosing {
                    Button("Turn on Nutrition") {
                        choosing = true
                        DispatchQueue.main.async { showChoices() }
                    }
                        .buttonStyle(.accentPill)
                        .padding(.top, 4)
                        .accessibilityIdentifier("turnOnNutrition")
                }
            }
            .card()
            if choosing {
                VStack(alignment: .leading, spacing: 10) {
                    Text("First, choose what you want to see. You can change it any time.")
                        .font(.app(.subheadline, weight: .medium)).foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(NutritionChoice.all) { choice in
                        Button { turnOn(choice.mode) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(choice.title).font(.app(.subheadline, weight: .semibold)).foregroundStyle(Palette.ink)
                                    Text(choice.text).font(.app(.footnote)).foregroundStyle(Palette.ink2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                                if saving == choice.mode { ProgressView() }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.surface2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(saving != nil)
                        .accessibilityIdentifier("nutritionChoice-\(choice.mode.rawValue)")
                    }
                    if let error {
                        Text(error).font(.app(.footnote)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Not now") {
                        choosing = false
                        error = nil
                    }
                    .font(.app(.subheadline))
                    .disabled(saving != nil)
                }
                .card()
                .id(Self.choicesID)
            }
        }
    }

    private func turnOn(_ mode: NutritionMode) {
        saving = mode
        error = nil
        Task {
            do {
                try await dashboard.turnOnNutrition(mode)
                // The next sync hears it's on, asks Health about food and reads it: run that sync now, if this
                // iPhone sends its Health data.
                if Config.serverURL() != nil, !Config.token.isEmpty {
                    await sync.syncNow()
                    await dashboard.refreshIfChanged(includeStatus: false)
                }
            } catch {
                self.error = "Couldn't turn it on: \(error.localizedDescription)"
            }
            saving = nil
        }
    }
}
