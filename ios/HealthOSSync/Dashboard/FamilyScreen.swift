import SwiftUI
import UIKit

/// The Family board (GET /api/family), as on the web: everyone who shares, at a glance, each against their own last
/// 30 days and never against each other. Sharing is mutual, so turned off, you see no one and no one sees you.
struct FamilyScreen: View {
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
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

/// One person: photo or initial, name, devices, status, then last night's sleep, recovery or HRV, and today's steps,
/// each against their own usual. Your own tile opens Today.
struct FamilyTile: View {
    let member: FamilyMember
    /// The viewer's today: a member a day ahead or behind gets "their Sun".
    let boardToday: String
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let label = FamilyText.accessibilitySummary(member, boardToday: boardToday)
        if member.isYou {
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
            // As on the web: resting heart rate shows only as a reason next to Off or Check in, and Settings tells
            // people their tile is sleep, recovery or HRV, and steps.
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
        VStack(spacing: 12) {
            Rectangle().fill(Palette.border).frame(height: 1)
            HStack(alignment: .top, spacing: 10) {
                FamilySlot(icon: "bed.double", label: "Sleep", value: member.sleep.map { Fmt.hoursMinutes($0.hours) }, note: FamilyText.sleepNote(member))
                FamilySlot(icon: "heart.text.square", label: FamilyText.readinessLabel(member), value: FamilyText.readinessValue(member), note: FamilyText.readinessNote(member))
                FamilySlot(icon: "figure.walk", label: "Steps", value: member.steps.map { Fmt.number($0.value) }, note: FamilyText.stepsNote(member))
            }
        }
    }
}

struct FamilySlot: View {
    let icon: String
    let label: String
    let value: String?
    let note: String

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
        }
        // minWidth 0: three equal columns, whatever each note's length.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
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

    static func readinessLabel(_ m: FamilyMember) -> String {
        if let r = readiness(m) { return r.kind == "hrv" ? "HRV" : "Recovery" }
        return m.devices.contains("whoop") ? "Recovery" : "HRV"
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
        ]
        return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". ")
    }

    /// Math.round: halves go up, as on the web.
    private static func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }

    private static func isDay(_ s: String) -> Bool { s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil }
}
