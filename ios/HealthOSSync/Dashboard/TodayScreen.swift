import SwiftUI

/// The home screen: the same cards as the web dashboard's Home page.
struct TodayScreen: View {
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        NavigationStack {
            Group {
                switch dashboard.phase {
                case .starting:
                    ProgressView()
                case .noServer:
                    ContentUnavailableView {
                        Label("No server yet", systemImage: "server.rack")
                    } description: {
                        Text("Add your healthOS address in Settings.")
                    } actions: {
                        Button("Open Settings") { dashboard.tab = .settings }
                    }
                case .signIn:
                    SignInView()
                case .unavailable(let message):
                    ContentUnavailableView {
                        Label("Can't load your dashboard", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try again") { Task { await dashboard.start() } }
                    }
                case .ready:
                    if let summary = dashboard.summary {
                        TodayContent(summary: summary)
                    } else {
                        ProgressView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.page)
            .toolbar(.hidden, for: .navigationBar)
        }
        .task { await dashboard.startIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .healthOSSynced)) { _ in
            Task { await dashboard.load() }
        }
    }
}

private struct TodayContent: View {
    let summary: Summary
    @Environment(Dashboard.self) private var dashboard
    @Environment(AppModel.self) private var sync

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Header(summary: summary, name: summary.name ?? dashboard.status?.settings?.name)
                SyncStatusLine()
                if let error = dashboard.error { Banner(text: error, icon: "wifi.exclamationmark", tone: .peach) }
                if summary.demo == true {
                    Banner(text: "Showing demo data. Connect Apple Health or WHOOP to see your own.", icon: "sparkles", tone: .blue)
                }
                if let week = summary.week { WeekCard(week: week, stepGoal: dashboard.stepGoal) }
                if let photo = dashboard.status?.photo {
                    PhotoFigure(photo: photo, vitals: summary.vitals, units: dashboard.units)
                }
                if let vitals = summary.vitals { VitalsRow(vitals: vitals, asOf: summary.date, units: dashboard.units) }
                LazyVGrid(columns: columns, spacing: 12) {
                    ReadinessCard(summary: summary)
                    Spo2Card(summary: summary)
                    HrvCard(summary: summary)
                    SleepCard(summary: summary)
                    LoadCard(summary: summary)
                    ActivityCard(summary: summary, goal: dashboard.stepGoal)
                }
                if let timeline = summary.timeline { TimelineCard(timeline: timeline, today: summary.today) }
                InsightsCard(insights: summary.insights ?? [], today: summary.today)
            }
            .padding(16)
            .opacity(dashboard.loading ? 0.6 : 1)
            .animation(.easeInOut(duration: 0.2), value: dashboard.loading)
        }
        .refreshable { await sync.syncAll() }
    }
}

// MARK: - Header

private struct Header: View {
    let summary: Summary
    let name: String?
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let isToday = summary.date == summary.today
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hello,").font(.system(size: 26)).foregroundStyle(Palette.ink2)
                    Text("\(name ?? "there").").font(.system(size: 40, weight: .bold)).foregroundStyle(Palette.ink)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text(isToday ? "Here's your health today." : "Here's your health on \(Fmt.day(summary.date, "EEEEMMMMd")).")
                        .font(.subheadline)
                        .foregroundStyle(Palette.ink3)
                }
                Spacer(minLength: 8)
                Button { dashboard.tab = .settings } label: {
                    Avatar(photo: dashboard.status?.photo, name: name)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens Settings")
            }
            HStack(spacing: 6) {
                Button { Task { await dashboard.show(date: Day.add(summary.date, -1)) } } label: {
                    Image(systemName: "chevron.left").frame(width: 34, height: 34)
                }
                .accessibilityLabel("Previous day")
                Button { Task { await dashboard.show(date: nil) } } label: {
                    Text(Fmt.day(summary.date, "EEEMMMdyyyy")).font(.subheadline.weight(.medium)).monospacedDigit()
                }
                .disabled(isToday)
                .accessibilityHint("Back to today")
                Button { Task { await dashboard.show(date: Day.add(summary.date, 1)) } } label: {
                    Image(systemName: "chevron.right").frame(width: 34, height: 34)
                }
                .disabled(isToday)
                .accessibilityLabel("Next day")
                Spacer()
                if let latest = summary.latestDataDate, latest < summary.date {
                    Text("Latest data \(Fmt.day(latest))").font(.caption).foregroundStyle(Palette.ink3)
                }
            }
            .foregroundStyle(Palette.ink)
            .buttonStyle(.plain)
            .padding(4)
            .background(Palette.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.border))
        }
    }
}

private struct Banner: View {
    let text: String
    let icon: String
    let tone: Tone

    var body: some View {
        Label(text, systemImage: icon)
            .font(.footnote)
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
            Text(WeekText.title(week)).font(.caption.weight(.semibold)).textCase(.uppercase).foregroundStyle(Palette.ink3)
            Text(WeekText.body(week, stepGoal: stepGoal)).font(.callout).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
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
                .font(.caption.weight(.medium))
                .foregroundStyle(Palette.ink2)
                .labelStyle(TintedIconLabel(color: color))
                .lineLimit(1)
            if let latest = vital?.latest {
                let (value, unit) = format(latest.value)
                BigValue(value: value, unit: unit, size: 24)
                Text(latest.date == asOf ? Self.statusText(vital?.status) : Fmt.day(latest.date))
                    .font(.caption2)
                    .foregroundStyle(vital?.status == "normal" || latest.date != asOf ? Palette.ink3 : Palette.serious)
            } else {
                Text("—").font(.title2.weight(.semibold)).foregroundStyle(Palette.ink3)
                Text("No reading").font(.caption2).foregroundStyle(Palette.ink3)
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
            Button { Task { await sync.syncAll() } } label: {
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
                .font(.footnote)
                .foregroundStyle(Palette.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            }
            .buttonStyle(.plain)
            .disabled(sync.syncingSources)
            .accessibilityHint("Syncs again")
            if !sync.syncingSources, let notes = sync.sources?.notes, !notes.isEmpty {
                ForEach(notes, id: \.self) { Text($0).font(.caption).foregroundStyle(Palette.ink3) }
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
