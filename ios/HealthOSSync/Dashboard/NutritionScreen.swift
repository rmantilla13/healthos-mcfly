import SwiftUI

/// The Nutrition page, a tab (src/pages/Nutrition.tsx). Everyone sees it; while Nutrition is off it explains what turning
/// it on means and turns it on the way the web does: first a choice of what to see, nothing chosen in advance, then on.
/// Nothing is read from Health or kept until then. On, it's Today (a conversation with McFly, NutritionChat.tsx) and the
/// views over more days: Trends, Macros, Hydration and Log.
struct NutritionScreen: View {
    @Environment(Dashboard.self) private var dashboard
    /// The links to Nutrition already applied. Kept here, above the page, so a page made again (another person, Nutrition
    /// turned off and on) doesn't apply the last one again either.
    @State private var link = NutritionLink()

    var body: some View {
        PhaseGate {
            if dashboard.status == nil {
                // Whether Nutrition is on comes with the status: until it arrives there's nothing honest to show.
                if case .unavailable(let message) = dashboard.phase {
                    Unavailable("Can't load your dashboard", systemImage: "wifi.exclamationmark", description: message)
                } else {
                    ProgressView()
                }
            } else if let mode = dashboard.nutritionMode {
                // One person's, on one server: someone else signing in, or another server, never sees (or saves over)
                // another's conversation, as the web keys it by person. Signed out, PhaseGate shows sign-in instead,
                // and the conversation goes with the page.
                NutritionPage(mode: mode, link: $link).id(identity)
            } else {
                NutritionIntro()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.page)
    }

    private var identity: String {
        Self.identity(server: Config.serverURL(), user: dashboard.status?.user?.id ?? dashboard.account?.id)
    }

    /// Whose page this is: the server and the person. A change makes the page (and its conversation) anew.
    static func identity(server: URL?, user: String?) -> String {
        "\(server?.absoluteString ?? "")|\(user ?? "")"
    }
}

/// A link to Nutrition (#/nutrition?tab=macros, Profile's card places, Home's orb with compose=1), applied once. The
/// page comes back every time its tab is chosen again, and the last link stays on the dashboard until another comes,
/// so without this the page would jump back to that link's view (and raise the keyboard) on every return. On the web
/// the view and compose=1 are in the address, which changes once a view is picked.
struct NutritionLink {
    private(set) var handled: Int?

    /// The view a link asks for, and whether it asks for Today's composer: the first time its request is seen, then nil.
    mutating func take(_ request: RouteRequest?) -> (tab: NutritionTab, compose: Bool)? {
        guard let request, request.id != handled else { return nil }
        handled = request.id
        let compose = request.route.query["compose"] == "1"
        return (compose ? .today : NutritionTab.of(request.route.query["tab"]), compose)
    }
}

/// The page while Nutrition is on: the view chosen (Today first), from the views row or a link's ?tab=.
private struct NutritionPage: View {
    let mode: NutritionMode
    @Binding var link: NutritionLink
    @Environment(Dashboard.self) private var dashboard
    /// The view asked for; the one shown falls back where this server can't show it.
    @State private var asked: NutritionTab = .today
    /// Today's conversation: memory only, kept while the other views are looked at.
    @State private var thread = NutritionThread()
    /// The day Today views; nil is today.
    @State private var date: String?
    /// Macros' and Hydration's range, as the web's page keeps it.
    @State private var days = 30
    /// POST /nutrition/log/day: false once an older server has answered it doesn't have it.
    @State private var dayRoute = true
    /// A link asked for Today's composer (Home's orb, compose=1); Today sets it back once it's focused.
    @State private var compose = false

    var body: some View {
        let tabs = NutritionTab.visible(mode, today: dayRoute, logging: dashboard.foodLogAvailable != false)
        let current = NutritionTab.current(asked, in: tabs)
        Group {
            switch current {
            case .today:
                NutritionToday(mode: mode, thread: thread, date: $date, compose: $compose, routeMissing: { dayRoute = false }) {
                    NutritionViewsRow(tabs: tabs, current: current) { asked = $0 }
                }
            case .log:
                FoodLogTab { intro(tabs, current) }
            default:
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        intro(tabs, current)
                        switch current {
                        case .macros: NutritionLoader(days: days, insights: false) { NutritionMacros(data: $0) }
                        case .hydration: NutritionLoader(days: days, insights: false) { NutritionHydration(data: $0, units: dashboard.units, days: days) }
                        default: NutritionLoader(days: 14, insights: true) { NutritionOverview(data: $0, units: dashboard.units) }
                        }
                    }
                    .padding(16)
                }
                .background(Palette.page)
                .refreshable { await dashboard.load() }
            }
        }
        // A link to a view (#/nutrition?tab=macros, Profile's card places, Home's orb with compose=1), once each.
        .onChange(of: dashboard.request(for: .nutrition)?.id, initial: true) {
            guard let wanted = link.take(dashboard.request(for: .nutrition)) else { return }
            asked = wanted.tab
            if wanted.compose { compose = true }
        }
        // Whether this server has the food log decides the Log; Health catches up with the log on opening.
        .task(id: "\(dashboard.generation)|\(dashboard.nutritionOn)") {
            await dashboard.probeFoodLog()
            await dashboard.reconcileFoodHealth()
        }
    }

    private func intro(_ tabs: [NutritionTab], _ current: NutritionTab) -> some View {
        PageIntro(sub: "What you log here or in your food app. Only you can see it.", actions: { EmptyView() }) {
            VStack(alignment: .leading, spacing: 12) {
                NutritionViewsRow(tabs: tabs, current: current) { asked = $0 }
                if current == .macros || current == .hydration {
                    RangeFilters(days: $days, ranges: ChartRange.standard.filter { $0.days <= 90 })
                }
            }
        }
    }
}

/// The views (NutritionViews): a quiet row of words with a small dot between, rather than tabs, as Today is where
/// logging happens. The one shown is in ink.
struct NutritionViewsRow: View {
    let tabs: [NutritionTab]
    let current: NutritionTab
    let choose: (NutritionTab) -> Void

    var body: some View {
        NutritionFlow(spacing: 9, rowSpacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element) { i, tab in
                HStack(spacing: 9) {
                    if i > 0 { Circle().fill(Palette.ink3.opacity(0.55)).frame(width: 3, height: 3).accessibilityHidden(true) }
                    Button(tab.label) { choose(tab) }
                        .buttonStyle(.plain)
                        .font(.app(size: 12.5, weight: tab == current ? .medium : .regular, relativeTo: .footnote))
                        .foregroundStyle(tab == current ? Palette.ink : Palette.ink3)
                        .lineLimit(1)
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                        .accessibilityAddTraits(tab == current ? .isSelected : [])
                        .accessibilityIdentifier("nutritionView-\(tab.rawValue)")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Nutrition views")
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

/// Nutrition is off (NutritionIntro): turning it on, through the same choice as Profile → Nutrition (what to see first,
/// nothing preselected; the server refuses to turn it on without one), then what it shows and what stays private.
private struct NutritionIntro: View {
    @Environment(Dashboard.self) private var dashboard
    @Environment(AppModel.self) private var sync
    @State private var choosing = false
    @State private var saving: NutritionMode?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageIntro(sub: "A conversation about what nourishes you. Off until you turn it on.")
                if dashboard.nutritionAvailable {
                    hero
                    IntroCard(title: "What it shows", items: [
                        ("fork.knife", "What you log, here or in your food app",
                         "Search for a food or type a barcode (or scan one on iPhone), describe it or snap a photo for McFly to estimate, or type the amounts. Or read the daily totals from MyFitnessPal, Cronometer, Lose It!, MacroFactor or Yazio, through Apple Health."),
                        ("chart.bar.xaxis", "Macro balance, water and caffeine", "Your day by weight, the water you log as glasses, and your daily caffeine."),
                        ("moon", "How it goes with your sleep and HRV", "Patterns from your own days, worded as things that tend to go together, never as causes."),
                    ])
                    IntroCard(title: "What stays private", items: [
                        ("checkmark.shield", "Only you see it", "Never on the Family board, never in the admin screens."),
                        ("checkmark", "You choose how much you see", "Everything, everything except calories, or no calorie or nutrient amounts at all. Ask McFly sees only that much."),
                        ("sparkle", "No scores, streaks or set targets", "Set your own targets later if you like; they show only as a plain line. Turn it off or delete it any time in your Profile."),
                    ])
                } else {
                    Text("This healthOS server doesn't have Nutrition yet.")
                        .font(.app(.footnote)).foregroundStyle(Palette.ink2)
                        .card()
                }
            }
            .padding(16)
        }
        .background(Palette.page)
        .refreshable { await dashboard.load() }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            Orb(size: 48)
            VStack(alignment: .leading, spacing: 12) {
                Text("healthOS nutrition")
                    .textCase(.uppercase)
                    .font(.app(size: 11, weight: .medium, relativeTo: .caption2))
                    .tracking(1.3)
                    .foregroundStyle(Palette.ink3)
                Text(choosing ? "First, choose what you want to see" : "What's on your plate?")
                    .font(.app(size: 22, relativeTo: .title2))
                    .tracking(-0.44)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(choosing
                     ? "You can change it any time in your Profile."
                     : "Tell McFly what you ate in your own words, or show it a photo, and it works out the numbers for you to check. Nothing is read or kept until you turn it on.")
                    .font(.app(size: 14, relativeTo: .subheadline))
                    .foregroundStyle(Palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                if !choosing {
                    Button { choosing = true } label: { PillLabel("Turn on Nutrition") }
                        .buttonStyle(.accentPill)
                        .accessibilityIdentifier("turnOnNutrition")
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(NutritionChoice.all) { choice in
                            Button { turnOn(choice.mode) } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(choice.title).font(.app(size: 14, weight: .medium, relativeTo: .subheadline)).foregroundStyle(Palette.ink)
                                        Text(choice.text).mutedSmall()
                                    }
                                    Spacer(minLength: 0)
                                    if saving == choice.mode { ProgressView() }
                                }
                                .multilineTextAlignment(.leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Palette.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(saving != nil)
                            .accessibilityIdentifier("nutritionChoice-\(choice.mode.rawValue)")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("What you see")
                    Button("Cancel") {
                        choosing = false
                        error = nil
                    }
                    .buttonStyle(.quietPill)
                    .disabled(saving != nil)
                }
                if let error { NoteBad(error, size: 12) }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { CardSurface(shape: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)) }
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
                self.error = error.localizedDescription
            }
            saving = nil
        }
    }
}

/// One of the intro's two cards (.nutrition-intro): a title, then each item's icon, words and muted line.
private struct IntroCard: View {
    let title: String
    let items: [(symbol: String, title: String, text: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.app(.headline, weight: .medium)).foregroundStyle(Palette.ink).accessibilityAddTraits(.isHeader)
            ForEach(items, id: \.title) { item in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: item.symbol)
                        .font(.footnote)
                        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                        .foregroundStyle(Palette.ink2)
                        .frame(width: 30, height: 30)
                        .background(Palette.surface2, in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.app(size: 14, weight: .semibold, relativeTo: .subheadline)).foregroundStyle(Palette.ink)
                        Text(item.text).mutedSmall()
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .card()
    }
}
