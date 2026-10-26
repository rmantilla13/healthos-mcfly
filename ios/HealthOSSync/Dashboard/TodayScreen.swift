import SwiftUI

/// The Home page: the same cards as the web dashboard's Home. Its header greets you and has your avatar, so the
/// navigation bar is hidden here.
struct TodayScreen: View {
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        // No server, sign-in and a server whose sign-in isn't set up are the shell's (PhaseGate); the rest is Home's.
        PhaseGate {
            switch dashboard.phase {
            case .unavailable(let message):
                Unavailable("Can't load your dashboard", systemImage: "wifi.exclamationmark", description: message) {
                    Button("Try again") { Task { await dashboard.start() } }
                }
            case .ready:
                if let summary = dashboard.summary {
                    TodayContent(summary: summary)
                } else {
                    ProgressView()
                }
            default:
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.page)
        .toolbar(.hidden, for: .navigationBar)
        .task { await dashboard.startIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .healthOSSynced)) { _ in
            Task { await dashboard.refreshIfChanged(includeStatus: false) }
        }
    }
}

private struct TodayContent: View {
    let summary: Summary
    @Environment(Dashboard.self) private var dashboard
    @Environment(AppModel.self) private var sync
    /// The day by hour (GET /api/day) and the cycle (GET /api/cycle): nil hides their cards.
    @State private var day: DayData?
    @State private var cycle: CycleData?
    /// Today's path's marker, shared with the portrait: while it's moved, the portrait's heart shows that hour.
    @State private var scrub = TodayScrub()

    /// Under a resting heart rate flag, in the luteal or menstrual phase. The summary never mentions the cycle.
    private static let cycleNote = "Temperature and resting heart rate often run a little higher in this part of your cycle."

    var body: some View {
        let isToday = summary.date == summary.today
        // The phase is about today, so it says nothing about a past day on screen.
        let phase = isToday && dashboard.cycleTrackingOn ? cycle?.phase : nil
        // Cards hidden in Profile → Cards (here or on the web), and optional ones not turned on, leave no gap; the
        // rest move up.
        let hidden = dashboard.cardsOff
        let gridIds = Cards.visible(Cards.todayGrid, hidden: hidden)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                OrganicHeader(summary: summary, name: summary.name ?? dashboard.status?.settings?.name)
                if let error = dashboard.error { Banner(text: error, icon: "wifi.exclamationmark", tone: .peach) }
                if summary.demo == true {
                    Banner(text: "Showing demo data. Connect Apple Health or WHOOP to see your own.", icon: "sparkles", tone: .blue)
                }
                ForEach(summary.flags) { flag in
                    let showNote = flag.id.hasPrefix("rhr") && phase?.luteal == true
                    FlagBanner(flag: flag, note: showNote ? Self.cycleNote : nil)
                }
                if dashboard.showsFamilyNotice { FamilyNotice() }
                HomeFigure(summary: summary, scrub: summary.timeline?.date == summary.date ? scrub.heart(on: summary.date) : nil)
                if let timeline = summary.timeline, !hidden.contains("home.timeline") { TodayPath(timeline: timeline, scrubbed: scrub) }
                if let cycle, let phase { CycleCard(cycle: cycle, phase: phase) }
                if let day, !day.metrics.isEmpty { DayCard(data: day, date: isToday ? nil : summary.date) }
                if let week = summary.week, !hidden.contains("home.week") { WeekCard(week: week, stepGoal: dashboard.stepGoal) }
                // Left out with all six hidden, so no extra gap is left where the grid was.
                if !gridIds.isEmpty { TodayGrid(summary: summary, ids: gridIds, goal: dashboard.stepGoal) }
                if !hidden.contains("home.insights") { InsightsCard(insights: summary.insights ?? [], today: summary.today) }
                if Cards.allHidden(in: .home, hidden: hidden) { AllCardsHiddenNote() }
            }
            .padding(16)
            .opacity(dashboard.loading ? 0.6 : 1)
            .animation(.easeInOut(duration: 0.2), value: dashboard.loading)
        }
        .refreshable { await sync.syncAll(force: true) }
        // Ask McFly's pill floats over this, from the shell (Shell/AppShell.swift).
        // Newer endpoints: a server without them, or a failed fetch, just hides the card.
        .task(id: "\(summary.date)|\(dashboard.generation)") {
            day = try? await dashboard.day(date: summary.date == summary.today ? nil : summary.date)
        }
        .task(id: "\(dashboard.generation)|\(dashboard.cycleTrackingOn)") {
            cycle = try? await dashboard.cycle()
        }
    }
}

private struct Banner: View {
    let text: String
    let icon: String
    let tone: Tone

    var body: some View {
        Label(text, systemImage: icon)
            .font(.app(.footnote))
            .foregroundStyle(tone.ink)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tone.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// A gentle heads-up from the summary (resting heart rate up, maybe with a raised temperature). Opens its page, Vitals
/// unless it names another.
private struct FlagBanner: View {
    let flag: Flag
    /// Cycle context the app adds itself.
    let note: String?
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let tone: Tone = flag.caution ? .peach : .blue
        let route = flag.page.flatMap { AppRoute(page: $0) } ?? .vitals
        Button { dashboard.open(route) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: flag.caution ? "heart.text.square" : "waveform.path.ecg").font(.subheadline.weight(.semibold))
                VStack(alignment: .leading, spacing: 3) {
                    Text(flag.title).font(.app(.subheadline, weight: .semibold))
                    Text(flag.text).font(.app(.footnote))
                    if let note { Text(note).font(.app(.footnote)).opacity(0.85).padding(.top, 3) }
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).opacity(0.6)
            }
            .foregroundStyle(tone.ink)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tone.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens \(route.title)")
    }
}

/// Once, for everyone: sharing is on by default, so say so where people will see it.
private struct FamilyNotice: View {
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let tone = Tone.blue
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.2").font(.subheadline.weight(.semibold)).accessibilityHidden(true)
            Text("Your family can see your daily status and your last 30 days on the **[Family](healthos://family)** board. Change this in **[your Profile](healthos://profile)**.")
                .font(.app(.footnote))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.openURL, OpenURLAction { url in dashboard.open(url: url) ? .handled : .systemAction })
            Button("Got it") { Task { await dashboard.dismissFamilyNotice() } }
                .font(.app(.footnote, weight: .semibold))
                .buttonStyle(.plain)
                .accessibilityHint("Hides this note")
        }
        .foregroundStyle(tone.ink)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct WeekCard: View {
    let week: WeekSummary
    let stepGoal: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(WeekText.title(week)).font(.app(.caption, weight: .semibold)).textCase(.uppercase).foregroundStyle(Palette.ink3)
            Text(WeekText.body(week, stepGoal: stepGoal)).font(.app(.callout)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }
}

// MARK: - Vitals

private struct VitalsRow: View {
    let vitals: Summary.Vitals
    let asOf: String
    let units: Units

    var body: some View {
        HStack(spacing: 10) {
            tile(vitals.heart, icon: "heart.fill", color: Palette.critical, title: "Heart") { (Fmt.number($0), "bpm") }
            tile(vitals.breathing, icon: "lungs.fill", color: Palette.series1, title: "Breathing") { (Fmt.number($0, 1), "rpm") }
            tile(vitals.temp, icon: "thermometer.medium", color: Palette.series2, title: (vitals.temp?.label ?? "").lowercased().contains("wrist") ? "Wrist temp" : "Temp") {
                let m = units.temp($0)
                return (Fmt.number(m.value, 1), m.unit)
            }
        }
    }

    /// Short titles: three tiles share a phone-width row. The server's longer label goes to VoiceOver.
    private func tile(_ vital: Vital?, icon: String, color: Color, title: String, format: (Double) -> (String, String)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.app(.caption, weight: .medium))
                .foregroundStyle(Palette.ink2)
                .labelStyle(TintedIconLabel(color: color))
                .lineLimit(1)
            if let latest = vital?.latest {
                let (value, unit) = format(latest.value)
                BigValue(value: value, unit: unit, size: 24)
                Text(latest.date == asOf ? Self.statusText(vital?.status) : Fmt.day(latest.date))
                    .font(.app(.caption2))
                    .foregroundStyle(vital?.status == "normal" || latest.date != asOf ? Palette.ink3 : Palette.serious)
            } else {
                Text("—").font(.app(.title2, weight: .semibold)).foregroundStyle(Palette.ink3)
                Text("No reading").font(.app(.caption2)).foregroundStyle(Palette.ink3)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(vital?.label ?? title)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.border))
    }

    static func statusText(_ status: String?) -> String {
        switch status {
        case "low": "Below your range"
        case "high": "Above your range"
        case "normal": "Normal"
        default: "Building your range"
        }
    }
}

struct TintedIconLabel: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(color)
            configuration.title
        }
    }
}

// MARK: - Sync status

/// "Synced 2 min ago · Apple Health ✓ · WHOOP ✓", tap to sync again. Problems in plain words underneath.
struct SyncStatusLine: View {
    @Environment(AppModel.self) private var sync

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { Task { await sync.syncAll(force: true) } } label: {
                HStack(spacing: 6) {
                    if sync.syncingSources {
                        ProgressView().controlSize(.small)
                        Text(sync.progress.isEmpty ? "Syncing Apple Health and WHOOP…" : sync.progress)
                    } else if let s = sync.sources {
                        Image(systemName: s.ok ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(s.ok ? Palette.good : Palette.serious)
                        Text("Synced \(s.finishedAt.formatted(.relative(presentation: .named))) · \(s.summary)")
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Sync Apple Health and WHOOP")
                    }
                    Spacer(minLength: 0)
                }
                .font(.app(.footnote))
                .foregroundStyle(Palette.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            }
            .buttonStyle(.plain)
            .disabled(sync.syncingSources)
            .accessibilityHint("Syncs again")
            if !sync.syncingSources, let notes = sync.sources?.notes, !notes.isEmpty {
                ForEach(notes, id: \.self) { Text($0).font(.app(.caption)).foregroundStyle(Palette.ink3) }
            }
        }
    }
}

extension ISO8601DateFormatter {
    /// Accepts timestamps with or without fractional seconds.
    static let flexible: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func flexibleDate(_ s: String) -> Date? {
        date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
