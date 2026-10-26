import SwiftUI

// Home's header as the web's phone shows it (src/components/shell/ShellHeader.tsx and TopBar.tsx): "Hello," over your
// name and the day's line, your avatar (Home has no bar, so it sits here), and under them the top bar: the demo note,
// the day with previous and next, Refresh and Edit widgets. Then the banners above the page (App.tsx) and the
// tagline under the figure (Home.tsx).

/// The greeting and the top bar.
struct HomeHeader: View {
    let summary: Summary
    /// Edit widgets' sheet, which Home shows.
    @Binding var editing: Bool
    @Environment(Dashboard.self) private var dashboard
    @Environment(AppModel.self) private var sync
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
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
                actions
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
            HStack(spacing: 10) { refresh; editButton }
            VStack(alignment: .leading, spacing: 8) { refresh; editButton }
        }
    }

    private var refresh: some View {
        RefreshPill(running: sync.syncingSources) { Task { await sync.syncAll(force: true) } }
    }

    @ViewBuilder private var editButton: some View {
        if editable {
            // Its words go on a narrow phone (the web hides them at 420px and below); VoiceOver still says them.
            let words = width + 32 > 420
            Button { editing = true } label: {
                HStack(spacing: 7) {
                    Image(systemName: "gearshape").font(.system(size: 14, weight: .medium))
                    if words { Text("Edit widgets") }
                }
            }
            .buttonStyle(HomePillStyle())
            .accessibilityLabel("Edit widgets")
            .accessibilityHint("Choose what Home shows")
            .accessibilityIdentifier("editWidgets")
        }
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

/// "Synced 2 min ago · Apple Health ✓ · WHOOP ✓" under the top bar, and problems in plain words: the iPhone's own Apple
/// Health push, which the web doesn't have. Nothing until a sync has run or is running.
struct SyncStatusLine: View {
    @Environment(AppModel.self) private var sync

    var body: some View {
        if sync.syncingSources || sync.sources != nil {
            VStack(alignment: .leading, spacing: 4) {
                // The mark beside the first line when the line wraps.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if sync.syncingSources {
                        ProgressView().controlSize(.mini)
                        Text(sync.progress.isEmpty ? "Syncing Apple Health and WHOOP…" : sync.progress)
                    } else if let s = sync.sources {
                        Image(systemName: s.ok ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(s.ok ? Palette.good : Palette.serious)
                        Text("Synced \(s.finishedAt.formatted(.relative(presentation: .named))) · \(s.summary)")
                    }
                }
                .font(.app(.caption))
                .foregroundStyle(Palette.ink3)
                // In full at every text size: each source's state is in it.
                .fixedSize(horizontal: false, vertical: true)
                if !sync.syncingSources, let notes = sync.sources?.notes, !notes.isEmpty {
                    ForEach(notes, id: \.self) { Text($0).font(.app(.caption)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true) }
                }
            }
            .accessibilityElement(children: .combine)
        }
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
