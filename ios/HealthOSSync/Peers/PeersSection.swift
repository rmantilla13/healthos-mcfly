import SwiftUI

/// Profile's "Your age-group comparison" (src/pages/Profile.tsx PeerComparison): a card that opens in place, "Private
/// to you". Opened, it reads GET /api/peers and shows where the person's own 30-day averages sit among people their age
/// who also take part: a quarter, never a rank, and never anyone else's values. Profile places it.
///
/// Shown only signed in, on a server whose settings name `peerComparison` (the setting came with /api/peers, so an
/// older server shows nothing). A server that answers the read with its catch-all 404 hides it too.
struct PeersSection: View {
    @Environment(Dashboard.self) private var dashboard
    /// The server, by address, that answered GET /api/peers with its catch-all 404.
    @State private var missingOn: String?

    /// Signed in, on a server whose settings name the comparison's switch: never behind a sign-in screen, never on a
    /// server older than it.
    static func shown(phase: Dashboard.Phase, status: ServerStatus?) -> Bool {
        phase == .ready && status?.settings?.peerComparison != nil
    }

    var body: some View {
        if Self.shown(phase: dashboard.phase, status: dashboard.status), missingOn != server {
            Collapsible(PeerWords.title, meta: PeerWords.meta, systemImage: "chart.bar") {
                PeerBody(editLink: dashboard.status?.settings?.perspective != nil) { missingOn = server }
            }
        }
    }

    private var server: String { Config.serverURL()?.absoluteString ?? "" }
}

/// What the card shows once open: read when it opens and after each load, as the web reads it on opening and when
/// data changes. The last answer stays on screen while the next is read.
private struct PeerBody: View {
    let editLink: Bool
    let routeMissing: () -> Void
    @Environment(Dashboard.self) private var dashboard
    @State private var data: PeerData?
    @State private var error: String?

    var body: some View {
        PeerContent(data: data, error: error, editLink: editLink)
            .task(id: dashboard.generation) { await read() }
            .environment(\.openURL, OpenURLAction { url in dashboard.open(url: url) ? .handled : .systemAction })
    }

    private func read() async {
        do {
            guard let answer = try await dashboard.peers() else { return routeMissing() }
            data = answer
            error = nil
        } catch {
            if Task.isCancelled || APIClient.isCancellation(error) { return }
            self.error = error.localizedDescription
        }
    }
}

/// The comparison for an answer (or its absence), drawn as the web's PeerBody: loading, a failure, why the person
/// isn't taking part, or the window, the sample-group pill, the gathering note and a row per measurement; the fine
/// print under both.
struct PeerContent: View {
    let data: PeerData?
    let error: String?
    var editLink = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let error {
                Text(PeerWords.loadFailed(error)).foregroundStyle(Palette.critical).fixedSize(horizontal: false, vertical: true)
            } else if let data {
                if !data.participating {
                    if let note = PeerWords.notTakingPart(data.reason, editLink: editLink) { PeerNote(markdown: note) }
                } else {
                    if let band = data.ageBand, let window = data.window {
                        Text(PeerWords.window(ageBand: band, from: window.from, to: window.to)).modifier(PeerFine())
                    }
                    if data.demo == true {
                        Text(PeerWords.demo)
                            .font(.app(size: 12, relativeTo: .caption))
                            .foregroundStyle(ColorToken.badgePeachInk.color)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            // A pill on one line; rounded corners, not a blob, when large text wraps it.
                            .background(ColorToken.badgePeachBg.color, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if data.gathering { PeerNote(markdown: PeerWords.gathering) }
                    if data.metrics.isEmpty {
                        PeerNote(markdown: PeerWords.noReadings)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(data.metrics) { PeerRow(m: $0) }
                        }
                    }
                }
                Text(PeerWords.fine).modifier(PeerFine())
            } else {
                Text(PeerWords.loading).font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// .profile-peer-note: the body size in ink-2, with its link in the accent, underlined.
private struct PeerNote: View {
    let markdown: String

    var body: some View {
        Text(attributed)
            .foregroundStyle(Palette.ink2)
            .lineSpacing(3)
            .tint(Palette.accentText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        var text = (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
        for run in text.runs where run.link != nil {
            text[run.range].underlineStyle = .single
            text[run.range].foregroundColor = Palette.accentText
        }
        return text
    }
}

/// .profile-peer-window and .profile-fine: 12 px in ink-3.
private struct PeerFine: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink3).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
    }
}

/// One measurement (the web's PeerRow): its name and source, then where you sit, your average and the group's rounded
/// figures with its size as a range; or how many days you have so far; or that the group is still gathering. A ready
/// one ends with the four-quarter bar. VoiceOver reads the row as one, the bar left out: its words say the same.
struct PeerRow: View {
    let m: PeerMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(PeerWords.heading(m))
                    .font(.app(size: 13, weight: .medium, relativeTo: .footnote))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if m.status == "ready", let band = m.quarter, let group = m.group {
                    Text(PeerWords.bandLabel(band))
                        .font(.app(size: 13.5, weight: .medium, relativeTo: .footnote))
                        .foregroundStyle(Palette.accentText)
                        .fixedSize(horizontal: false, vertical: true)
                    if let yours = PeerWords.yours(m) { line(yours) }
                    line(PeerWords.group(group, m))
                } else if m.status == "not_enough_days" {
                    line(PeerWords.notEnoughDays(m))
                } else {
                    line(PeerWords.waiting(m))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if m.status == "ready", let band = m.quarter, m.group != nil {
                PeerBar(yours: band).padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Palette.border))
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(.app(size: 12, relativeTo: .caption))
            .foregroundStyle(Palette.ink3)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The group's four quarters, equal by definition, the middle two its middle half; yours lit whole. No dot: the
/// answer says which quarter, not where in it.
struct PeerBar: View {
    let yours: Peers.Band

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Peers.Band.allCases, id: \.self) { q in
                Capsule().fill(PeerColors.quarter(q, yours: yours))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}
