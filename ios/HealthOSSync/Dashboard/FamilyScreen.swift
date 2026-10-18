import Charts
import SwiftUI
import UIKit

/// The Family board (GET /api/family), as on the web: everyone who shares, at a glance, each against their own last
/// 30 days and never against each other. Sharing is mutual, so turned off, you see no one and no one sees you.
struct FamilyScreen: View {
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.scenePhase) private var scenePhase
    /// The person page on screen, if any. Emptied whenever the board can't be shown (asked to sign in again, another
    /// server), so no one's page outlives the board it came from.
    @State private var path: [FamilyPersonRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if dashboard.signInRequired {
                    SignInView()
                } else if dashboard.phase == .noServer {
                    ContentUnavailableView("No server yet", systemImage: "server.rack", description: Text("Add your healthOS address in Settings."))
                } else {
                    FamilyContent()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.page)
            .navigationTitle("Family")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: FamilyPersonRoute.self) { FamilyPersonScreen(id: $0.id) }
        }
        .onChange(of: dashboard.phase) { _, phase in
            if phase != .ready { path = [] }
        }
        // Other people's changes don't move your data version, so the board re-reads itself: on opening the tab, on
        // returning to the app, after your own data reloads, then every five minutes while it's on screen. The task
        // ends when the tab is left or the app goes to the background.
        .task(id: "\(scenePhase == .active)|\(dashboard.phase == .ready)|\(dashboard.generation)") {
            guard scenePhase == .active, dashboard.phase == .ready else { return }
            await dashboard.loadFamily()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Dashboard.familyRefresh))
                if Task.isCancelled { break }
                await dashboard.loadFamily(force: true)
            }
        }
    }
}

private struct FamilyContent: View {
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        switch dashboard.familyDisplay {
        case .needsAccounts:
            FamilyNote(text: "The Family board needs sign-in, so each person has their own account.")
        case .sharingOff:
            scrolling { SharingOff() }
        case .board(let board):
            scrolling { FamilyBoardView(board: board) }
        case .missing:
            FamilyNote(text: "Family isn't available on this server yet.")
        case .failed(let error):
            ContentUnavailableView {
                Label("Couldn't load the family board", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await dashboard.loadFamily(force: true) } }
            }
        case .unavailable(let message):
            ContentUnavailableView {
                Label("Can't load the family board", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await dashboard.start() } }
            }
        case .loading:
            ProgressView()
        }
    }

    private func scrolling(@ViewBuilder _ content: () -> some View) -> some View {
        ScrollView { content().padding(16) }
            .refreshable { await dashboard.loadFamily(force: true) }
    }
}

/// A quiet line in place of the board.
private struct FamilyNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(Palette.ink3)
            .multilineTextAlignment(.center)
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Board

struct FamilyBoardView: View {
    let board: FamilyBoard
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let others = board.members.filter { !$0.isYou }
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your family, today.").font(.title.weight(.semibold)).foregroundStyle(Palette.ink)
                Text(FamilyText.groupLine(board.members) ?? "Each person against their own last 30 days.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .padding(.bottom, 4)
            ForEach(board.members) { member in
                FamilyTile(member: member, boardToday: board.today ?? member.today)
            }
            if others.isEmpty { FamilyEmpty(admin: dashboard.account?.role == "admin") }
            FamilyFoot()
        }
    }
}

private struct FamilyEmpty: View {
    let admin: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No one else is sharing yet.").font(.callout).foregroundStyle(Palette.ink2)
            if admin {
                Text("Invite someone from Admin on the web dashboard.").font(.footnote).foregroundStyle(Palette.ink3)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Palette.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .accessibilityElement(children: .combine)
    }
}

private struct FamilyFoot: View {
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        Text("Statuses compare each person with their own last 30 days. They're a nudge to check in, not medical advice. Change what you share in **[Settings](healthos://settings)**.")
            .font(.footnote)
            .foregroundStyle(Palette.ink3)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { _ in
                dashboard.tab = .settings
                return .handled
            })
    }
}

/// Family is off: the only thing to do here is turn it on.
private struct SharingOff: View {
    @Environment(Dashboard.self) private var dashboard
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Family is off: you don't see anyone, and nobody sees you.")
                .font(.callout)
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await turnOn() }
            } label: {
                HStack(spacing: 8) {
                    if busy { ProgressView().controlSize(.small) }
                    Text("Turn on sharing")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)
            if let error { Text(error).font(.footnote).foregroundStyle(Palette.critical) }
        }
        .card()
    }

    private func turnOn() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await dashboard.setFamilySharing(true)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Tile

/// One person: photo or initial, name, devices, status, then last night's sleep, recovery or HRV, today's steps and
/// resting heart rate, each against their own usual with its last 7 days below. Every tile opens that person's last
/// 30 days. From a server older than that (no history): the three figures only, and your own tile opens Today.
struct FamilyTile: View {
    let member: FamilyMember
    /// The viewer's today: a member a day ahead or behind gets "their Sun".
    let boardToday: String
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let label = FamilyText.accessibilitySummary(member, boardToday: boardToday)
        if member.history != nil {
            NavigationLink(value: FamilyPersonRoute(id: member.id)) { card.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .accessibilityHint(member.isYou ? "Opens your last 30 days" : "Opens their last 30 days")
        } else if member.isYou {
            Button { dashboard.tab = .today } label: { card.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .accessibilityHint("Opens Today")
        } else {
            card
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
        }
    }

    private var card: some View {
        let quiet = member.status == "quiet"
        return VStack(alignment: .leading, spacing: 12) {
            FamilyTileHead(member: member, boardToday: boardToday)
            if let reasons = FamilyText.reasons(member) {
                Text(reasons).font(.footnote).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
            }
            FamilySlots(member: member).opacity(quiet ? 0.6 : 1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(quiet ? Palette.surface2 : Palette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Palette.border))
    }
}

struct FamilyTileHead: View {
    let member: FamilyMember
    let boardToday: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            FamilyAvatar(member: member)
            VStack(alignment: .leading, spacing: 4) {
                // The pills follow the name and wrap below it when they don't fit, as on the web: the name keeps its
                // room at every text size.
                FamilyWrap(spacing: 6, rowSpacing: 4) {
                    Text(FamilyText.title(member))
                        .font(.headline)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let phase = FamilyText.phase(member.cyclePhase) { FamilyPill(text: phase, tone: .pink) }
                    if member.demo { FamilyPill(text: "Demo data", tone: .blue) }
                }
                Text(FamilyText.devicesLine(member, boardToday: boardToday))
                    .font(.caption)
                    .foregroundStyle(Palette.ink3)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                // On its own row: "No watch or WHOOP data since Tue" doesn't fit beside a name at phone width.
                if let text = FamilyText.status(member) { FamilyStatusChip(status: member.status ?? "", text: text) }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct FamilyPill: View {
    let text: String
    let tone: Tone

    var body: some View {
        // Not fixed width: at the largest text sizes a pill wider than the tile shortens instead of pushing the board
        // off screen.
        Text(text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tone.background, in: Capsule())
            .foregroundStyle(tone.ink)
    }
}

/// Lays its views out in rows like CSS flex-wrap: each goes beside the last if it fits, else starts a new row. One
/// wider than a whole row gets the row to itself, and wraps or shortens there.
struct FamilyWrap: Layout {
    var spacing: CGFloat = 6
    var rowSpacing: CGFloat = 4

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + rowSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            let ideal = subview.sizeThatFits(.unspecified)
            if !row.items.isEmpty, row.width + spacing + ideal.width > width {
                rows.append(row)
                row = Row()
            }
            let size = ideal.width > width ? subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) : ideal
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append((index, size))
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

/// The web's status pill: a neutral capsule with a coloured dot for good, off and check.
private struct FamilyStatusChip: View {
    let status: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            if let dot = FamilyText.dot(status) {
                Circle().fill(dot).frame(width: 8, height: 8)
            }
            Text(text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(status == "check" ? Palette.ink : Palette.ink2)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Palette.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.border))
    }
}

private struct FamilySlots: View {
    let member: FamilyMember

    var body: some View {
        let m = member
        let sleep = FamilySlot(icon: "bed.double", label: "Sleep", value: m.sleep.map { Fmt.hoursMinutes($0.hours) }, note: FamilyText.sleepNote(m),
                               spark: FamilyCharts.spark(.sleep, m))
        let readiness = FamilySlot(icon: "heart.text.square", label: FamilyText.readinessLabel(m), value: FamilyText.readinessValue(m),
                                   note: FamilyText.readinessNote(m), spark: FamilyCharts.spark(.readiness, m))
        let steps = FamilySlot(icon: "figure.walk", label: "Steps", value: m.steps.map { Fmt.number($0.value) }, note: FamilyText.stepsNote(m),
                               spark: FamilyCharts.spark(.steps, m))
        VStack(spacing: 12) {
            Rectangle().fill(Palette.border).frame(height: 1)
            if m.history != nil {
                // Two by two, as on the web at phone width: each figure gets room for its 7-day chart.
                VStack(spacing: 14) {
                    FamilySlotRow { sleep; readiness }
                    FamilySlotRow {
                        steps
                        FamilySlot(icon: "waveform.path.ecg", label: "Resting HR", value: FamilyText.restingValue(m), note: FamilyText.restingNote(m),
                                   spark: FamilyCharts.spark(.restingHr, m))
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 10) { sleep; readiness; steps }
            }
        }
    }
}

/// Equal columns of equal height, so the small charts in a row line up at the bottom whatever the notes above say.
private struct FamilySlotRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) { content }
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct FamilySlot: View {
    let icon: String
    let label: String
    let value: String?
    let note: String
    var spark: FamilySparkData? = nil

    /// Scales with Dynamic Type, so the figure stays bigger than its caption at every text size.
    static let valueFont = Font.system(.title3, design: .rounded, weight: .semibold)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(label)
            }
            .font(.caption)
            .foregroundStyle(Palette.ink3)
            .lineLimit(1)
            Text(value ?? "—")
                .font(Self.valueFont)
                .monospacedDigit()
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                // A third of the tile at the largest sizes: shrink "12,345" a little rather than cut it. Only for
                // width: never squeezed by the tile's height, which would shrink it next to a tall note or head.
                .minimumScaleFactor(0.5)
                .fixedSize(horizontal: false, vertical: true)
            Text(note)
                .font(.caption2)
                .foregroundStyle(Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
            if let spark {
                Spacer(minLength: 6)
                FamilySpark(data: spark)
            }
        }
        // minWidth 0: equal columns, whatever each note's length; maxHeight: as tall as the row, chart at the bottom.
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The last 7 days under a tile's figure: just a picture (hidden from VoiceOver), since the tile opens the person's
/// page where every value can be read. Bars for sleep and steps with the latest one darker; a line for the rest.
struct FamilySpark: View {
    let data: FamilySparkData
    static let height: CGFloat = 34

    var body: some View {
        let indexed = Array(data.points.enumerated())
        let last = data.points.count - 1
        Group {
            switch data.kind {
            case .bars:
                // One band per day (categorical x). Thin bars, as on the web, whether there are two days or seven.
                Chart(indexed, id: \.offset) { i, p in
                    BarMark(x: .value("Day", p.date), y: .value("Value", p.value), width: .fixed(8))
                        .foregroundStyle(i == last ? FamilyChartColor.barAccent : Palette.bar)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                }
                .chartYScale(domain: 0...data.domain.upperBound)
            case .line:
                Chart {
                    ForEach(indexed, id: \.offset) { i, p in
                        AreaMark(x: .value("Day", i), yStart: .value("Base", data.domain.lowerBound), yEnd: .value("Value", p.value))
                            .foregroundStyle(Palette.series1.opacity(0.1))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Day", i), y: .value("Value", p.value))
                            .foregroundStyle(Palette.series1)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.monotone)
                    }
                    if let p = data.points.last {
                        PointMark(x: .value("Day", last), y: .value("Value", p.value))
                            .foregroundStyle(Palette.series1)
                            .symbolSize(30)
                    }
                }
                .chartXScale(domain: 0...Double(max(last, 1)))
                .chartYScale(domain: data.domain)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: Self.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Their photo, graded black-and-white like your own, or their initial on the warm gradient when there's none
/// (or it can't be loaded any more: they stopped sharing).
struct FamilyAvatar: View {
    let member: FamilyMember
    var size: CGFloat = 56
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.colorScheme) private var scheme
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                RadialGradient(colors: [Color(UIColor(hex: 0xA58A73)), Color(UIColor(hex: 0x4C3B2F))], center: .topLeading, startRadius: 0, endRadius: size * 1.2)
                Text(FamilyText.initial(member.name)).font(.system(size: size * 0.36, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .padding(3)
        .background(Circle().fill(Palette.surface))
        .overlay(Circle().strokeBorder(Palette.border, lineWidth: 1))
        .task(id: "\(member.id)|\(member.avatarKey ?? "none")|\(scheme == .dark)") {
            image = nil
            guard let version = member.avatarKey, let data = await dashboard.familyAvatar(id: member.id, version: version),
                  let original = UIImage(data: data) else { return }
            let dark = scheme == .dark
            let graded = await Task.detached(priority: .userInitiated) { PhotoTone.apply(to: original, dark: dark) }.value
            if !Task.isCancelled { image = graded }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - One person, bigger

/// What the stack pushes: only an id. The page looks the person up on the board on screen, so it follows each
/// re-read and is gone the moment they (or you) stop sharing, or the board can't be shown.
struct FamilyPersonRoute: Hashable {
    let id: String
}

/// A person's last 30 days, as on the web's #/family?member=<id>.
private struct FamilyPersonScreen: View {
    let id: String
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let person = dashboard.familyPerson(id)
        Group {
            switch person {
            case .shown(let member, let boardToday):
                ScrollView {
                    FamilyPersonPage(member: member, boardToday: boardToday).padding(16)
                }
                .refreshable { await dashboard.loadFamily(force: true) }
            case .notOnBoard:
                FamilyNote(text: "This person isn't on the Family board right now.")
            case .noBoard:
                // Never the board itself: behind a sign-in screen it can still be in memory.
                switch dashboard.familyDisplay {
                case .sharingOff: ScrollView { SharingOff().padding(16) }
                case .loading: ProgressView()
                default: FamilyNote(text: "The Family board isn't available right now.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.page)
        .navigationTitle(person.member.map(FamilyText.name) ?? "Family")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// What a person's page may show.
enum FamilyPersonState {
    /// On the board on screen, as of its last read.
    case shown(FamilyMember, boardToday: String)
    /// The board is there and they're not on it: they stopped sharing (or left).
    case notOnBoard
    /// No board to show (sharing off, signed out, loading, another server): no one's page either.
    case noBoard

    var member: FamilyMember? { if case .shown(let m, _) = self { m } else { nil } }
}

extension Dashboard {
    /// A person's page draws only from the board the Family tab would show right now, never from a member kept from
    /// before: a board still in memory behind a sign-in screen, or one from before sharing went off, shows no one.
    func familyPerson(_ id: String) -> FamilyPersonState {
        guard phase == .ready, case .board(let board) = familyDisplay else { return .noBoard }
        guard let member = board.members.first(where: { $0.id == id }) else { return .notOnBoard }
        return .shown(member, boardToday: board.today ?? member.today)
    }
}

struct FamilyPersonPage: View {
    let member: FamilyMember
    let boardToday: String
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let m = member
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                FamilyAvatar(member: m, size: 72)
                VStack(alignment: .leading, spacing: 4) {
                    FamilyWrap(spacing: 6, rowSpacing: 4) {
                        Text(FamilyText.title(m))
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let phase = FamilyText.phase(m.cyclePhase) { FamilyPill(text: phase, tone: .pink) }
                        if m.demo { FamilyPill(text: "Demo data", tone: .blue) }
                    }
                    Text(FamilyText.pageDevicesLine(m, boardToday: boardToday))
                        .font(.caption)
                        .foregroundStyle(Palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let reasons = FamilyText.reasons(m) {
                        Text(reasons).font(.footnote).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                    if let text = FamilyText.status(m) { FamilyStatusChip(status: m.status ?? "", text: text) }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Palette.border))
            .accessibilityElement(children: .combine)

            ForEach(FamilyCharts.page(m)) { chart in
                FamilyChartCard(chart: chart, window: FamilyCharts.window(m))
            }

            Text(FamilyText.pageFoot(m))
                .font(.footnote)
                .foregroundStyle(Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.openURL, OpenURLAction { _ in
                    dashboard.tab = .today
                    return .handled
                })
        }
    }
}

/// One metric over their last 30 days: the figure, a note, and a chart you can scrub. Bars carry a dashed median of
/// the 30 days; lines a faint "usual": their average of the 30 days before the latest reading.
private struct FamilyChartCard: View {
    let chart: FamilyChartData
    /// Their 30 days, so a person with a few readings still sees where in the month they fall.
    let window: ClosedRange<Date>
    @State private var selected: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(chart.title).font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink2)
            Text(chart.value).font(.title2.weight(.semibold)).foregroundStyle(Palette.ink).monospacedDigit()
            if let note = chart.note { Text(note).font(.caption).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true) }
            if chart.points.isEmpty {
                Text("Nothing in the last 30 days.").font(.footnote).foregroundStyle(Palette.ink3).padding(.top, 6)
            } else {
                plot.frame(height: 180).padding(.top, 6)
            }
        }
        .card()
    }

    private var picked: Point? {
        guard let selected else { return nil }
        return chart.points.min { abs(Fmt.chartDate($0.date).timeIntervalSince(selected)) < abs(Fmt.chartDate($1.date).timeIntervalSince(selected)) }
    }

    private var plot: some View {
        let points = chart.points
        let segments = FamilyCharts.segments(points)
        let picked = picked
        let lastDate = points.last?.date
        return Chart {
            switch chart.kind {
            case .bars:
                ForEach(points) { p in
                    BarMark(x: .value("Day", Fmt.chartDate(p.date), unit: .day), y: .value(chart.title, p.value), width: .ratio(0.7))
                        .foregroundStyle(p.date == picked?.date || (picked == nil && p.date == lastDate) ? FamilyChartColor.barAccent : Palette.bar)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .accessibilityLabel(Fmt.day(p.date, "EEEMMMd"))
                        .accessibilityValue(chart.format(p.value))
                }
            case .line:
                ForEach(Array(points.enumerated()), id: \.element.date) { i, p in
                    AreaMark(x: .value("Day", Fmt.chartDate(p.date)), yStart: .value("Base", chart.domain.lowerBound), yEnd: .value(chart.title, p.value),
                             series: .value("Run", segments[i]))
                        .foregroundStyle(chart.color.opacity(0.1))
                        .interpolationMethod(.monotone)
                        .accessibilityHidden(true)
                    LineMark(x: .value("Day", Fmt.chartDate(p.date)), y: .value(chart.title, p.value), series: .value("Run", segments[i]))
                        .foregroundStyle(chart.color)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                        .accessibilityLabel(Fmt.day(p.date, "EEEMMMd"))
                        .accessibilityValue(chart.format(p.value))
                    // A day on its own between gaps has no line to sit on: a dot instead.
                    if FamilyCharts.isAlone(i, in: segments) {
                        PointMark(x: .value("Day", Fmt.chartDate(p.date)), y: .value(chart.title, p.value))
                            .foregroundStyle(chart.color)
                            .symbolSize(24)
                            .accessibilityHidden(true)
                    }
                }
                if let p = picked ?? points.last {
                    PointMark(x: .value("Day", Fmt.chartDate(p.date)), y: .value(chart.title, p.value))
                        .foregroundStyle(chart.color)
                        .symbolSize(60)
                        .accessibilityHidden(true)
                }
            }
            if let usual = chart.usual {
                RuleMark(y: .value("Usual", usual))
                    .foregroundStyle(Palette.ink3.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        FamilyChartTag(text: "usual", color: Palette.ink3)
                    }
                    .accessibilityLabel("Usual")
                    .accessibilityValue(chart.format(usual))
            }
            if let median = chart.median {
                RuleMark(y: .value("Median", median))
                    .foregroundStyle(Palette.ink2)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        FamilyChartTag(text: "Median \(chart.format(median))", color: Palette.ink2)
                    }
                    .accessibilityLabel("Median")
                    .accessibilityValue(chart.format(median))
            }
            if let picked {
                // At noon: the middle of a day's bar, and where a line plots that day.
                RuleMark(x: .value("Day", Fmt.chartDate(picked.date)))
                    .foregroundStyle(Palette.ink3.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 1) {
                            Text(chart.format(picked.value)).font(.caption.weight(.semibold))
                            Text(Fmt.day(picked.date, "EEEMMMd")).font(.caption2)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Palette.surface2, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(Palette.ink)
                    }
                    .accessibilityHidden(true)
            }
        }
        .chartXScale(domain: window)
        .chartYScale(domain: chart.domain)
        .chartXSelection(value: $selected)
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
            AxisGridLine().foregroundStyle(Palette.grid)
            AxisValueLabel { if let n = v.as(Double.self) { Text(chart.axis(n)).foregroundStyle(Palette.ink3) } }
        } }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in
            AxisValueLabel(format: .dateTime.month(.abbreviated).day()).foregroundStyle(Palette.ink3)
        } }
        .accessibilityLabel(chart.label)
    }
}

enum FamilyChartColor {
    /// The web's --bar-accent: the latest (or picked) bar. Lighter than the rest in dark mode, darker in light.
    static let barAccent = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x6DA7EC) : UIColor(hex: 0x2A78D6) })
}

/// A line's label on a backing of the card's colour, so it reads over the bars or the line it crosses.
private struct FamilyChartTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Palette.surface.opacity(0.9), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

// MARK: - Wording

/// The board's words, ported from src/pages/Family.tsx so the app and the web read the same. Warm and plain:
/// each person against their own usual, a nudge to check in, never a diagnosis.
enum FamilyText {
    private static let devices = ["whoop": "WHOOP", "watch": "Apple Watch", "iphone": "iPhone"]
    private static let reasonText = [
        "recovery": "Recovery lower than usual",
        "hrv": "HRV lower than usual",
        "resting_hr": "Resting heart rate above usual",
        "sleep": "Short night",
    ]
    /// Only these three words, ever: never "ovulation" or "fertile", and nothing near the next period.
    private static let phases = ["period": "Period", "follicular": "Follicular phase", "luteal": "Luteal phase"]
    /// The three statuses that say something, in the order the group line names them.
    private static let groups = [("check", "Check in"), ("off", "Off their usual"), ("good", "All good")]

    static func name(_ m: FamilyMember) -> String {
        let n = m.name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "Family member" : n
    }

    static func title(_ m: FamilyMember) -> String { m.isYou ? "\(name(m)) (you)" : name(m) }

    static func initial(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "·"
    }

    /// "Check in: Leo · Off their usual: Ana · All good: Maria, you"; nil when no one has one of those statuses.
    static func groupLine(_ members: [FamilyMember]) -> String? {
        let parts = groups.compactMap { status, label -> String? in
            let names = members.filter { $0.status == status }.map { $0.isYou ? "you" : name($0) }
            return names.isEmpty ? nil : "\(label): \(names.joined(separator: ", "))"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The status pill's words; nil (no pill) for phone-only people and for statuses the app doesn't know yet.
    static func status(_ m: FamilyMember) -> String? {
        let their = m.isYou ? "your" : "their"
        switch m.status {
        case "good": return "All good"
        case "off": return "Off \(their) usual"
        case "check": return "Check in"
        case "learning": return "Getting to know \(their) usual"
        case "quiet":
            guard let quietSince = m.quietSince else { return "No data yet" }
            let allQuiet = m.latestDataDate == nil || m.latestDataDate == quietSince
            return "No \(allQuiet ? "new data" : "watch or WHOOP data") since \(since(quietSince, today: m.today))"
        default: return nil
        }
    }

    static func dot(_ status: String?) -> Color? {
        switch status {
        case "good": Palette.good
        case "off": Palette.warning
        case "check": Palette.serious
        default: nil
        }
    }

    /// "today", "yesterday", a weekday within the week ("Tue"), else a date ("Oct 12").
    static func since(_ date: String, today: String) -> String {
        guard isDay(date), isDay(today) else { return date }
        let d = Fmt.daysBetween(date, today)
        return d <= 0 ? "today" : d == 1 ? "yesterday" : d < 7 ? Fmt.day(date, "EEE") : Fmt.day(date)
    }

    /// "WHOOP + iPhone · their Sun", or "No devices yet".
    static func devicesLine(_ m: FamilyMember, boardToday: String) -> String {
        let names = m.devices.compactMap { devices[$0] }.joined(separator: " + ")
        let theirDay = m.today != boardToday && isDay(m.today) ? "their \(Fmt.day(m.today, "EEE"))" : ""
        let parts = [names, theirDay].filter { !$0.isEmpty }
        return parts.isEmpty ? "No devices yet" : parts.joined(separator: " · ")
    }

    static func reasons(_ m: FamilyMember) -> String? {
        let r = m.reasons.compactMap { reasonText[$0] }
        return r.isEmpty ? nil : r.joined(separator: " · ")
    }

    static func phase(_ phase: String?) -> String? { phase.flatMap { phases[$0] } }

    static func sleepNote(_ m: FamilyMember) -> String {
        guard let s = m.sleep else { return "No sleep data for last night" }
        var parts: [String] = []
        // Sleep is dated by the morning they woke: yesterday's means last night's hasn't synced yet.
        if s.date != m.today { parts.append("the night before") }
        let inBed = s.inBed == true
        if inBed { parts.append("in bed") }
        if !inBed, let usual = s.usual {
            let diff = jsRound((s.hours - usual) * 60)
            parts.append(abs(diff) < 10 ? "about usual" : "\(diff > 0 ? "+" : "−")\(Fmt.hoursMinutes(abs(diff) / 60)) vs usual")
        }
        return parts.isEmpty ? "last night" : parts.joined(separator: " · ")
    }

    /// Readiness the app knows how to show: WHOOP recovery or HRV; anything newer hides the value.
    private static func readiness(_ m: FamilyMember) -> FamilyMember.Readiness? {
        guard let r = m.readiness, r.kind == "recovery" || r.kind == "hrv" else { return nil }
        return r
    }

    /// Their readiness over the 30 days, when it's a kind the app knows.
    static func readinessHistory(_ m: FamilyMember) -> FamilyMember.History.Series? {
        guard let r = m.history?.readiness, ["recovery", "hrv_rmssd", "hrv_sdnn"].contains(r.kind) else { return nil }
        return r
    }

    /// Today's reading decides; without one, what the 30 days hold; without those, the devices.
    static func readinessLabel(_ m: FamilyMember) -> String {
        if let r = readiness(m) { return r.kind == "hrv" ? "HRV" : "Recovery" }
        if let h = readinessHistory(m) { return h.kind == "recovery" ? "Recovery" : "HRV" }
        return m.devices.contains("whoop") ? "Recovery" : "HRV"
    }

    static func readinessFormat(_ m: FamilyMember, _ v: Double) -> String {
        readinessLabel(m) == "Recovery" ? "\(Fmt.number(v))%" : "\(Fmt.number(v)) ms"
    }

    static func readinessValue(_ m: FamilyMember) -> String? {
        guard let r = readiness(m) else { return nil }
        return r.kind == "recovery" ? "\(Fmt.number(r.value))%" : "\(Fmt.number(r.value)) ms"
    }

    static func readinessNote(_ m: FamilyMember) -> String {
        guard let r = readiness(m) else {
            let known = m.devices.filter { devices[$0] != nil }
            if known.contains(where: { $0 != "iphone" }) { return "None in the last few days" }
            return known.isEmpty ? "" : "Needs a watch or WHOOP"
        }
        let metric = r.metric == "hrv_sdnn" ? "SDNN" : "RMSSD"
        guard let usual = r.usual, usual > 0 else { return r.kind == "hrv" ? metric : "learning \(m.isYou ? "your" : "their") usual" }
        if r.kind == "recovery" { return "usual \(Fmt.number(usual))%" }
        let pct = jsRound((r.value - usual) / usual * 100)
        return "\(abs(pct) < 3 ? "about usual" : "\(pct > 0 ? "+" : "−")\(Fmt.number(abs(pct)))% vs usual") · \(metric)"
    }

    /// "by 15:00 · usually ~6.2K" when the phone or Watch counted them hour by hour.
    static func stepsNote(_ m: FamilyMember) -> String {
        guard let s = m.steps else { return "None yet today" }
        if s.source == "whoop" { return "WHOOP, since waking" }
        guard let hour = s.asOfHour else { return "today" }
        var note = "by \(String(format: "%02d:00", (hour + 1) % 24))"
        if let usual = s.usualByNow { note += " · usually ~\(Fmt.compact(jsRound(usual / 100) * 100))" }
        return note
    }

    /// Today's resting heart rate, else the latest of the 30 days (its note then says when).
    static func restingValue(_ m: FamilyMember) -> String? {
        if let r = m.restingHr, let v = r.value { return Fmt.number(v) }
        return FamilyCharts.clean(m.history?.restingHr ?? []).last.map { Fmt.number($0.value) }
    }

    static func restingNote(_ m: FamilyMember) -> String {
        guard let r = m.restingHr, r.value != nil else {
            // A reading without a verdict: either too new to have a usual, or not recent (then say when it was).
            guard let last = FamilyCharts.clean(m.history?.restingHr ?? []).last else { return "None lately" }
            guard isDay(m.today) else { return "bpm" }
            return Fmt.daysBetween(last.date, m.today) <= 2 ? "bpm · no usual yet" : "bpm · \(since(last.date, today: m.today))"
        }
        guard let usual = r.usual else { return "bpm" }
        switch r.status {
        case "normal": return "bpm · about usual"
        case "high": return "bpm · above usual \(Fmt.number(usual))"
        case "low": return "bpm · below usual \(Fmt.number(usual))"
        default: return "bpm"
        }
    }

    /// The person page's line under the name: "WHOOP + iPhone · their Sun · last 30 days".
    static func pageDevicesLine(_ m: FamilyMember, boardToday: String) -> String {
        let names = m.devices.compactMap { devices[$0] }.joined(separator: " + ")
        let theirDay = m.today != boardToday && isDay(m.today) ? "their \(Fmt.day(m.today, "EEE"))" : ""
        return [names, theirDay, "last 30 days"].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Under the sleep chart: why last night isn't in it, their usual, or that it's the phone's time in bed.
    static func sleepChartNote(_ m: FamilyMember) -> String? {
        let chartInBed = m.history?.sleep?.inBed == true
        if let s = m.sleep, s.inBed == true, !chartInBed {
            return "\(s.date == m.today ? "last night" : "the night before") in bed (phone), not in the chart"
        }
        if let s = m.sleep, s.inBed != true, let usual = s.usual { return "usual \(Fmt.hoursMinutes(usual))" }
        return chartInBed ? "from the iPhone" : nil
    }

    static func pageFoot(_ m: FamilyMember) -> AttributedString {
        let lines = "Dashed lines are the median of these 30 days; “usual” lines are \(m.isYou ? "your" : "their") average of the 30 days before the latest reading. "
        let more = m.isYou ? "**[Open your full dashboard](healthos://today)**" : "Only what they share is here."
        return (try? AttributedString(markdown: lines + more)) ?? AttributedString(lines + more)
    }

    /// One sentence per tile for VoiceOver.
    static func accessibilitySummary(_ m: FamilyMember, boardToday: String) -> String {
        let parts: [String?] = [
            title(m),
            phase(m.cyclePhase),
            m.demo ? "Demo data" : nil,
            devicesLine(m, boardToday: boardToday),
            status(m),
            reasons(m),
            "Sleep \(m.sleep.map { Fmt.hoursMinutes($0.hours) } ?? "none"), \(sleepNote(m))",
            "\(readinessLabel(m)) \(readinessValue(m) ?? "none")\(readinessNote(m).isEmpty ? "" : ", \(readinessNote(m))")",
            "Steps \(m.steps.map { Fmt.number($0.value) } ?? "none"), \(stepsNote(m))",
            // Only from servers with the 30-day board; older tiles have no resting heart rate figure.
            m.history == nil ? nil : restingValue(m).map { "Resting heart rate \($0) \(restingNote(m))" } ?? "Resting heart rate none, \(restingNote(m))",
        ]
        return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". ")
    }

    /// Math.round: halves go up, as on the web.
    private static func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }

    static func isDay(_ s: String) -> Bool { s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil }
}

// MARK: - Chart data

/// A tile's 7-day chart.
struct FamilySparkData: Equatable {
    enum Kind { case bars, line }
    let kind: Kind
    let points: [Point]
    /// Bars from zero; a line between its own lowest and highest, with a little room.
    let domain: ClosedRange<Double>
}

/// One chart on a person's page, worked out from their tile so it can be checked without drawing it.
struct FamilyChartData: Identifiable {
    enum Metric: String { case sleep, readiness, steps, restingHr, load }

    let metric: Metric
    var id: String { metric.rawValue }
    let title: String
    let value: String
    let note: String?
    let kind: FamilySparkData.Kind
    let points: [Point]
    let format: (Double) -> String
    /// The y axis's labels: "8h", "12K", "55".
    let axis: (Double) -> String
    let color: Color
    /// Bars: the dashed median of these 30 days, from 5 days on.
    let median: Double?
    /// Lines: their usual, the average of the 30 days before the latest reading.
    let usual: Double?
    let domain: ClosedRange<Double>
    /// For VoiceOver: "Ana's sleep per night, median 7h 30m".
    let label: String
}

/// The numbers behind the board's charts, ported from src/pages/Family.tsx and src/charts so both draw the same days.
enum FamilyCharts {
    /// How far back the board reaches (server HISTORY_DAYS).
    static let days = 30
    /// Fewer points than this and a "typical" level means little, so no median line.
    static let medianMinPoints = 5
    /// A line breaks where more than this many days are missing, rather than drawing through the gap.
    static let gapDays = 3

    /// Points the charts can place: a real day and a finite value.
    static func clean(_ points: [Point]) -> [Point] {
        points.filter { FamilyText.isDay($0.date) && $0.value.isFinite }
    }

    /// The last 7 days of the 30, by the person's own today.
    static func week(_ points: [Point], today: String) -> [Point] {
        let points = clean(points)
        guard FamilyText.isDay(today) else { return Array(points.suffix(7)) }
        return points.filter { Fmt.daysBetween($0.date, today) < 7 }
    }

    /// The tile's spark for one of its four figures; nil with fewer than two days to draw.
    static func spark(_ metric: FamilyChartData.Metric, _ m: FamilyMember) -> FamilySparkData? {
        guard let h = m.history else { return nil }
        let (kind, points): (FamilySparkData.Kind, [Point]) = switch metric {
        case .sleep: (.bars, h.sleep?.points ?? [])
        case .readiness: (.line, FamilyText.readinessHistory(m)?.points ?? [])
        case .steps: (.bars, h.steps)
        case .restingHr: (.line, h.restingHr)
        case .load: (.bars, loadHistory(m)?.points ?? [])
        }
        let shown = week(points, today: m.today)
        guard shown.count >= 2 else { return nil }
        let values = shown.map(\.value)
        let domain = kind == .bars ? 0...Swift.max(values.max() ?? 1, 1) : padded(values, by: 0.25)
        return FamilySparkData(kind: kind, points: shown, domain: domain)
    }

    /// The middle value; for an even count, the mean of the two middle ones. nil under `medianMinPoints`.
    static func median(_ points: [Point]) -> Double? {
        guard points.count >= medianMinPoints else { return nil }
        let s = points.map(\.value).sorted()
        let mid = s.count / 2
        return s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2
    }

    /// Which run of the line each point belongs to: a new run starts after a gap of more than `gapDays`.
    static func segments(_ points: [Point]) -> [Int] {
        var run = 0
        return points.indices.map { i in
            if i > 0, Fmt.daysBetween(points[i - 1].date, points[i].date) > gapDays { run += 1 }
            return run
        }
    }

    /// The only point in its run: drawn as a dot, since there's no line to sit on.
    static func isAlone(_ i: Int, in segments: [Int]) -> Bool {
        (i == 0 || segments[i - 1] != segments[i]) && (i == segments.count - 1 || segments[i + 1] != segments[i])
    }

    /// Their 30 days on the x axis, ending on their today (or their latest day, if that's later).
    static func window(_ m: FamilyMember) -> ClosedRange<Date> {
        let h = m.history
        let all = clean((h?.sleep?.points ?? []) + (h?.readiness?.points ?? []) + (h?.steps ?? []) + (h?.restingHr ?? []) + (h?.load?.points ?? []))
        let dates = all.map(\.date).sorted()
        let end = [FamilyText.isDay(m.today) ? m.today : nil, dates.last].compactMap { $0 }.max() ?? Day.today()
        let start = [Day.add(end, -(days - 1)), dates.first].compactMap { $0 }.min()!
        // Half a day either side: days plot at noon, and a day's bar spans all of it.
        return Fmt.chartDate(start).addingTimeInterval(-12 * 3600)...Fmt.chartDate(end).addingTimeInterval(12 * 3600)
    }

    /// Load the app knows: WHOOP strain or active energy.
    static func loadHistory(_ m: FamilyMember) -> FamilyMember.History.Series? {
        guard let l = m.history?.load, l.kind == "strain" || l.kind == "energy" else { return nil }
        return l
    }

    /// The person page's charts, in the web's order. Nothing without history (an older server).
    static func page(_ m: FamilyMember) -> [FamilyChartData] {
        guard let h = m.history else { return [] }
        let name = FamilyText.name(m)
        var charts: [FamilyChartData] = []

        let nights = clean(h.sleep?.points ?? [])
        charts.append(bars(.sleep, title: h.sleep?.inBed == true ? "Time in bed" : "Sleep", value: m.sleep.map { Fmt.hoursMinutes($0.hours) },
                           note: FamilyText.sleepChartNote(m), points: nights, format: Fmt.hoursMinutes, axis: { "\(Fmt.number($0))h" },
                           label: "\(name)'s sleep per night"))

        let readiness = FamilyText.readinessLabel(m)
        let readinessFormat = { FamilyText.readinessFormat(m, $0) }
        let readinessUsual = m.readiness?.kind == "recovery" || m.readiness?.kind == "hrv" ? m.readiness?.usual : nil
        charts.append(line(.readiness, title: readiness == "Recovery" ? "WHOOP recovery" : "Heart rate variability", value: FamilyText.readinessValue(m),
                           note: readinessUsual.map { "usual \(readinessFormat($0))" }, points: clean(FamilyText.readinessHistory(m)?.points ?? []),
                           format: readinessFormat, color: Palette.series3, usual: readinessUsual, label: "\(name)'s \(readiness) per day"))

        charts.append(bars(.steps, title: "Steps", value: m.steps.map { Fmt.number($0.value) }, note: m.steps == nil ? nil : "today so far",
                           points: clean(h.steps), format: { "\(Fmt.number($0)) steps" }, axis: Fmt.compact, label: "\(name)'s steps per day"))

        let restingUsual = m.restingHr?.usual
        charts.append(line(.restingHr, title: "Resting heart rate", value: FamilyText.restingValue(m).map { "\($0) bpm" },
                           note: restingUsual.map { "usual \(Fmt.number($0)) bpm" }, points: clean(h.restingHr), format: { "\(Fmt.number($0)) bpm" },
                           color: Palette.series2, usual: restingUsual, label: "\(name)'s resting heart rate per day"))

        if let load = loadHistory(m) {
            let strain = load.kind == "strain"
            let format: (Double) -> String = strain ? { Fmt.number($0, 1) } : { "\(Fmt.number($0)) kcal" }
            let points = clean(load.points)
            charts.append(bars(.load, title: strain ? "Day strain" : "Active energy", value: points.last.map { format($0.value) },
                               note: strain ? "WHOOP, 0–21" : "Apple Watch or iPhone", points: points, format: format, axis: Fmt.compact,
                               label: "\(name)'s training load per day"))
        }
        return charts
    }

    private static func bars(_ metric: FamilyChartData.Metric, title: String, value: String?, note: String?, points: [Point],
                             format: @escaping (Double) -> String, axis: @escaping (Double) -> String, label: String) -> FamilyChartData {
        let mid = median(points)
        let top = Swift.max(points.map(\.value).max() ?? 1, mid ?? 0, 1)
        return FamilyChartData(metric: metric, title: title, value: value ?? "—", note: note, kind: .bars, points: points, format: format, axis: axis,
                               color: Palette.series1, median: mid, usual: nil, domain: 0...(top * 1.1),
                               label: mid.map { "\(label), median \(format($0))" } ?? label)
    }

    private static func line(_ metric: FamilyChartData.Metric, title: String, value: String?, note: String?, points: [Point],
                             format: @escaping (Double) -> String, color: Color, usual: Double?, label: String) -> FamilyChartData {
        // The usual is part of the range, so its line is never off the chart.
        let domain = padded(points.map(\.value) + (usual.map { [$0] } ?? []), by: 0.15)
        return FamilyChartData(metric: metric, title: title, value: value ?? "—", note: note, kind: .line, points: points, format: format,
                               axis: { Fmt.number($0, $0.rounded() == $0 ? 0 : 1) }, color: color, median: nil, usual: usual, domain: domain,
                               label: usual.map { "\(label), usual \(format($0))" } ?? label)
    }

    /// Lowest to highest with `by` of the span either side (at least 1, so a flat run isn't a line on the edge).
    static func padded(_ values: [Double], by share: Double) -> ClosedRange<Double> {
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let pad = Swift.max((hi - lo) * share, 1)
        return (lo - pad)...(hi + pad)
    }
}
