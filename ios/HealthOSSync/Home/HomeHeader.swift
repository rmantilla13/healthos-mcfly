import SwiftUI

// Home's header as the web's phone shows it (src/components/shell/ShellHeader.tsx and TopBar.tsx): "Hello," over your
// name and the day's line, your avatar (Home has no bar, so it sits here), and under them the top bar: the demo note,
// the day with previous and next, Refresh and Edit widgets. Then the banners above the page (App.tsx) and the
// tagline under the figure (Home.tsx).

/// The greeting and the top bar. On the open iPhone Duo's leading pane (`wide`, decisions.md Q5) it's the web's wide
/// header (ShellHeader at 1081px and up): the greeting on the leading side and its controls as one group on the
/// trailing side, wrapping from the right (the demo note, the day, Refresh, Edit widgets and your avatar), above the
/// cards they act on; at the accessibility text sizes, the phone's, which wraps further.
struct HomeHeader: View {
    let summary: Summary
    /// Edit widgets' sheet, which Home shows.
    @Binding var editing: Bool
    var wide = false
    @Environment(Dashboard.self) private var dashboard
    @Environment(AppModel.self) private var sync
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var width: CGFloat = 343

    /// "Here's your health today.", or on a past day "Here's your health on Friday, October 23." (ShellHeader).
    static func subtitle(date: String, today: String) -> String {
        date >= today ? "Here's your health today." : "Here's your health on \(Fmt.day(date, "EEEEMMMMd"))."
    }

    /// The name in the greeting: the one in your settings, else the summary's, else "there".
    static func name(settings: String?, summary: String?) -> String {
        for n in [settings, summary] {
            if let n = n?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
        }
        return "there"
    }

    /// The day after `date`, or nil (today) once that's today: the web's next button goes back to today rather than to
    /// a date (TopBar.tsx).
    static func next(after date: String, today: String) -> String? {
        let next = Day.add(date, 1)
        return next >= today ? nil : next
    }

    var body: some View {
        if wide && !typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                HomeHeaderRow(spacing: 16) {
                    greeting
                    HomeFlowRow(spacing: 10, lineSpacing: 6, alignment: .trailing) {
                        if demo { demoPill }
                        dayPicker
                        refresh
                        edit()
                        AccountMenu(size: 34)
                    }
                }
                SyncStatusLine()
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    greeting
                    Spacer(minLength: 0)
                    // Home hides its navigation bar, so your avatar and its account menu sit here, top right as on the
                    // other pages.
                    AccountMenu(size: 34)
                }
                topBar
                SyncStatusLine()
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Hello,").font(.app(size: 14, relativeTo: .subheadline)).foregroundStyle(Palette.ink2).padding(.bottom, 2)
            Text("\(Self.name(settings: dashboard.status?.settings?.name, summary: summary.name)).")
                .font(.app(size: 34, weight: .medium, relativeTo: .largeTitle))
                .tracking(-0.68)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(Self.subtitle(date: summary.date, today: summary.today))
                .font(.app(.footnote)).foregroundStyle(Palette.ink2).padding(.top, 6)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: The top bar

    private var demo: Bool { dashboard.status?.demo ?? summary.demo ?? false }

    /// Edit widgets, where the server can hide cards (its status names the list).
    private var editable: Bool { dashboard.status != nil && dashboard.cardsAvailable }

    /// The web's top bar wraps (styles.css .topbar on a phone: flex-start, the date pushing what follows to the right): on
    /// one line when it fits, else the demo note and the day, with Refresh and Edit widgets on the line below.
    private var topBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                if demo { demoPill }
                dayPicker
                Spacer(minLength: 0)
                // On one line only where all of it fits at its own width (the iPhone Duo's inner display upright, or a
                // phone without the demo note), and there Edit widgets keeps its words on one line, as the web's at 669.
                HStack(spacing: 10) { refresh; edit(oneLine: true) }
                    .fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if demo { demoPill }
                    dayPicker
                }
                actions
            }
            VStack(alignment: .leading, spacing: 8) {
                if demo { demoPill }
                dayPicker
                actions
            }
        }
    }

    private var demoPill: some View {
        Button("Demo data · Connect yours") { dashboard.open(.integrations) }
            .buttonStyle(HomePillStyle())
            .accessibilityHint("Opens Integrations")
            .accessibilityIdentifier("demoPill")
    }

    private var dayPicker: some View {
        let isToday = summary.date >= summary.today
        return HStack(spacing: 6) {
            Text(Fmt.day(summary.date, "EEEMMMd")).font(.app(.caption)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 2) {
                DayButton(symbol: "chevron.left", label: "Previous day") {
                    Task { await dashboard.show(date: Day.add(summary.date, -1)) }
                }
                .accessibilityIdentifier("previousDay")
                DayButton(symbol: "chevron.right", label: "Next day") {
                    Task { await dashboard.show(date: Self.next(after: summary.date, today: summary.today)) }
                }
                .disabled(isToday)
                .accessibilityIdentifier("nextDay")
            }
        }
    }

    private var actions: some View {
        // Side by side, or at the largest text sizes one above the other, so neither is cut off.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { refresh; edit() }
            VStack(alignment: .leading, spacing: 8) { refresh; edit() }
        }
    }

    private var refresh: some View {
        RefreshPill(running: sync.syncingSources) { Task { await sync.syncAll(force: true) } }
    }

    /// Edit widgets. With `oneLine` (the top bar's one-line form) its words never wrap: the pill takes their width.
    @ViewBuilder private func edit(oneLine: Bool = false) -> some View {
        if editable {
            // Its words go on a narrow phone (the web hides them at 420px and below); VoiceOver still says them.
            Button { editing = true } label: { EditWidgetsLabel(words: width + 32 > 420, oneLine: oneLine) }
            .buttonStyle(HomePillStyle())
            .accessibilityLabel("Edit widgets")
            .accessibilityHint("Choose what Home shows")
            .accessibilityIdentifier("editWidgets")
        }
    }
}

/// Edit widgets' gear and, where there's room, its words; with `oneLine`, kept to one line (the pill grows to fit them)
/// rather than wrapping as they may in the stacked forms at the accessibility text sizes.
struct EditWidgetsLabel: View {
    var words = true
    var oneLine = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "gearshape").font(.system(size: 14, weight: .medium))
            if words { Text("Edit widgets").fixedSize(horizontal: oneLine, vertical: false) }
        }
    }
}

/// The wide header's one row: the greeting on the leading side, as wide as its words up to two fifths of the row, and
/// the controls in the rest, on the trailing side; as tall as the taller.
struct HomeHeaderRow: Layout {
    var spacing: CGFloat = 16

    private func widths(_ subviews: Subviews, width: CGFloat) -> (greeting: CGFloat, controls: CGFloat) {
        guard subviews.count == 2 else { return (width, 0) }
        let greeting = min(subviews[0].sizeThatFits(.unspecified).width, width * 0.4)
        return (greeting, max(0, width - greeting - spacing))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        let w = widths(subviews, width: width)
        let heights = zip(subviews, [w.greeting, w.controls]).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
        return CGSize(width: width, height: heights.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = widths(subviews, width: bounds.width)
        guard subviews.count == 2 else {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
            return
        }
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: w.greeting, height: nil))
        subviews[1].place(at: CGPoint(x: bounds.maxX - w.controls, y: bounds.minY), proposal: ProposedViewSize(width: w.controls, height: nil))
    }
}

/// The top bar's pills (.pill): ink-2 words on a white pill with a soft shadow, 34pt tall at least, as QuietPillStyle
/// draws them, except that at the largest text sizes its words wrap rather than being cut off.
struct HomePillStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.app(.footnote, weight: .medium))
            .foregroundStyle(configuration.isPressed ? Palette.ink : Palette.ink2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 15)
            .padding(.vertical, 7)
            .frame(minHeight: 34)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .tokenShadow(.pill, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// The day's previous and next: a small round button (.day-btn, 24pt) with a full-size place to tap.
private struct DayButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.ink3)
                .frame(width: 24, height: 24)
                .frame(width: 34, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }
}

/// Refresh (TopBar.tsx RefreshButton): here it syncs Apple Health and WHOOP (`AppModel.syncAll`, which also sends
/// POST /api/sync), and its icon turns while that runs, except with Reduce Motion.
struct RefreshPill: View {
    let running: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if running && !reduceMotion {
                    TimelineView(.animation) { context in
                        Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .medium))
                            .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360))
                    }
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .medium))
                }
                Text("Refresh")
            }
        }
        .buttonStyle(HomePillStyle())
        .disabled(running)
        .accessibilityLabel(running ? "Refreshing" : "Refresh")
        .accessibilityHint("Syncs Apple Health and WHOOP")
        .accessibilityIdentifier("refresh")
    }
}

/// How fresh this person's data is, for the sync line's dot: syncing now (orange), synced within the last 24 hours
/// (green), or not for longer than that, or never (red).
enum SyncFreshness: Equatable {
    case syncing
    case synced(Date)
    case stale(Date?)

    /// Longer than this since the last sync that went through, and the dot goes red.
    static let staleAfter: TimeInterval = 24 * 60 * 60

    static func of(syncing: Bool, last: Date?, now: Date) -> SyncFreshness {
        if syncing { return .syncing }
        guard let last, now.timeIntervalSince(last) <= staleAfter else { return .stale(last) }
        return .synced(last)
    }

    /// The last sync that went through, from what's kept across launches as well as this launch's: this iPhone's last
    /// Apple Health push (background ones too) when it worked, a Sync this launch where a source synced (one where every
    /// source was skipped, signed out say, synced nothing), and the server's own last Apple Health and WHOOP syncs (another
    /// device's, or the server's hourly WHOOP refresh).
    static func lastSynced(report: SyncReport?, sources: SourcesSyncStatus?, status: ServerStatus?) -> Date? {
        var dates: [Date] = []
        if let report, report.ok { dates.append(report.finishedAt) }
        if let sources, sources.apple == .ok || sources.whoop == .ok { dates.append(sources.finishedAt) }
        if let s = status?.apple?.lastSync?.syncedAt, let d = ISO8601DateFormatter.flexible.flexibleDate(s) { dates.append(d) }
        if status?.whoop?.connected == true, let s = status?.whoop?.lastSync, let d = ISO8601DateFormatter.flexible.flexibleDate(s) { dates.append(d) }
        return dates.max()
    }

    var color: Color {
        switch self {
        case .syncing: Palette.warning
        case .synced: Palette.good
        case .stale: Palette.critical
        }
    }

    /// "Syncing…", "Synced just now", "Synced 4 minutes ago", "Last synced 2 days ago", "Not synced yet".
    func words(now: Date) -> String {
        switch self {
        case .syncing: return "Syncing…"
        case .synced(let d): return now.timeIntervalSince(d) < 60 ? "Synced just now" : "Synced \(Self.ago(d, now))"
        case .stale(let d?): return "Last synced \(Self.ago(d, now))"
        case .stale(nil): return "Not synced yet"
        }
    }

    private static func ago(_ d: Date, _ now: Date) -> String {
        RelativeDateTimeFormatter.named.localizedString(for: min(d, now), relativeTo: now)
    }
}

private extension RelativeDateTimeFormatter {
    static let named: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.dateTimeStyle = .named
        f.unitsStyle = .full
        return f
    }()
}

/// The sync's dot and its words under the top bar: "Syncing…" orange, "Synced 4 minutes ago" green, and red once it's
/// been more than 24 hours. How each source went, and why one didn't, is in Profile → This iPhone. Nothing while no
/// source is connected (the banner above says so).
struct SyncStatusLine: View {
    @Environment(AppModel.self) private var sync
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let status = dashboard.status
        if !NoSourcesBanner.shows(status) {
            let last = SyncFreshness.lastSynced(report: sync.last, sources: sync.sources, status: status)
            // Once a minute, so "4 minutes ago" moves on and the dot turns red at 24 hours with the app open.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                SyncFreshnessLine(freshness: .of(syncing: sync.syncingSources || sync.syncing, last: last, now: context.date), now: context.date)
            }
        }
    }
}

/// The dot and the words, as on Home and in Profile.
struct SyncFreshnessLine: View {
    let freshness: SyncFreshness
    let now: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle()
                .fill(freshness.color)
                .frame(width: 8, height: 8)
                .opacity(freshness == .syncing && pulse ? 0.35 : 1)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 0.5 }
                .accessibilityHidden(true)
            Text(freshness.words(now: now))
        }
        .font(.app(.caption))
        .foregroundStyle(Palette.ink3)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { startPulse() }
        .onChange(of: freshness == .syncing) { startPulse() }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("syncStatus")
    }

    /// While syncing the dot breathes, unless Reduce Motion is on.
    private func startPulse() {
        guard freshness == .syncing, !reduceMotion else { return pulse = false }
        pulse = false
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
    }
}

/// The web's quiet button (.btn-quiet): its words only, in ink-3, with a full-size place to tap. Home's own, by name:
/// Nutrition (slice G) has a quiet text style of its own.
struct HomeQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.app(.footnote, weight: .medium))
            .foregroundStyle(configuration.isPressed ? Palette.ink : Palette.ink3)
            // Its words wrap rather than being cut off, at the largest text sizes.
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

// MARK: - Banners

/// A line above Home's page (.banner.banner-start): an icon, words, and what it opens or a button of its own, on the
/// surface with a hairline edge.
struct HomeBanner<Trailing: View>: View {
    let icon: String
    var iconColor: Color = Palette.ink
    var background: Color = Palette.surface
    var ink: Color = Palette.ink
    /// The banner's words are medium (.banner); the family notice's regular.
    var weight: Font.Weight = .medium
    /// Its button under the words rather than beside them (the accessibility text sizes).
    var stacked = false
    let text: Text
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let words = HStack(alignment: .center, spacing: 8) {
            Image(systemName: icon).font(.system(size: 15, weight: .medium)).foregroundStyle(iconColor).accessibilityHidden(true)
            text
                .font(.app(size: 14, weight: weight, relativeTo: .subheadline))
                .foregroundStyle(ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 0) {
                    words
                    trailing
                }
            } else {
                HStack(alignment: .center, spacing: 8) {
                    words
                    trailing
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border))
    }
}

/// Nothing connected yet (App.tsx noSources): no demo data, no Apple Health import or sync, no WHOOP and no Fitbit
/// import. It links to Integrations.
struct NoSourcesBanner: View {
    @Environment(Dashboard.self) private var dashboard

    static let text = "Your dashboard fills in once you connect WHOOP or the healthOS iPhone app, or import a Fitbit export."

    /// App.tsx noSources, on what the status says; a status that names neither Apple Health nor WHOOP says nothing.
    static func shows(_ s: ServerStatus?) -> Bool {
        guard let s, s.apple != nil || s.whoop != nil else { return false }
        return s.demo != true && s.apple?.lastImport == nil && s.apple?.lastSync == nil && s.whoop?.connected != true && s.fitbit?.lastImport == nil
    }

    var body: some View {
        Button { dashboard.open(.integrations) } label: {
            HomeBanner(icon: "powerplug", text: Text(Self.text)) {
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPressStyle())
        .accessibilityHint("Opens Integrations")
        .accessibilityIdentifier("noSources")
    }
}

/// Once, for everyone: sharing is on by default, so say so where people will see it (App.tsx FamilyNotice). Got it sits
/// at the right, or under the words at the accessibility text sizes (the web's phone layout lets it wrap).
struct FamilyNotice: View {
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.dynamicTypeSize) private var typeSize

    static let text = "Your family can see your daily status and your last 30 days on the **[Family](healthos://family)** board. Change this in **[your Profile](healthos://profile)**."

    var body: some View {
        HomeBanner(icon: "person.2", weight: .regular, stacked: typeSize.isAccessibilitySize, text: Text(.init(Self.text))) { gotIt }
            .tint(Palette.ink)
        .environment(\.openURL, OpenURLAction { url in dashboard.open(url: url) ? .handled : .systemAction })
    }

    private var gotIt: some View {
        Button("Got it") { Task { await dashboard.dismissFamilyNotice() } }
            .buttonStyle(HomeQuietButtonStyle())
            // Beside the words, it keeps its own width; they wrap.
            .layoutPriority(1)
            .accessibilityHint("Hides this note")
            .accessibilityIdentifier("familyNoticeGotIt")
    }
}

// MARK: - Tagline and the last line

/// The last line of the page (src/components/shell/AppFooter.tsx): on Home only its left-hand line, as Ask McFly's pill
/// takes the right.
struct HomeFooter: View {
    static let text = "A little more clarity, every day."

    var body: some View {
        Text(Self.text)
            .font(.app(size: 11, relativeTo: .caption2))
            .foregroundStyle(Palette.ink3)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.top, 28)
    }
}


/// "A clearer picture. / A healthier you." under the figure, and the way on to every measurement, Vitals (Home.tsx
/// Tagline). With just the statistics, one small line under the cards.
struct HomeTagline: View {
    var compact = false
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        if compact {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("A clearer picture. A healthier you.")
                    Spacer(minLength: 12)
                    link
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("A clearer picture. A healthier you.")
                    link
                }
            }
            .font(.app(.caption))
            .foregroundStyle(Palette.ink3)
            .padding(.top, 4)
            .padding(.horizontal, 4)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("A clearer picture.\nA healthier you.")
                    .font(.app(.footnote))
                    .lineSpacing(5)
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                link.font(.app(.caption)).foregroundStyle(Palette.ink2)
            }
            .padding(.top, 8)
            .padding(.horizontal, 4)
        }
    }

    private var link: some View {
        Button { dashboard.open(.vitals) } label: {
            HStack(spacing: 18) {
                Text("Your measurements")
                Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .medium))
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Vitals")
        .accessibilityIdentifier("yourMeasurements")
    }
}
