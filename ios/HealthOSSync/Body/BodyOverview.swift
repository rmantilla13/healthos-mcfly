import SwiftUI

// The top of the Body page (Body.tsx Overview, FigureCard.tsx, MeasurementCard.tsx): the page's line and "Change my
// representation ↗", the tabs, your figure as a picture (never a measurement), and the three measurements you can add
// to, with the story of what they're for.

/// The page's lead (PageIntro with IntroTools): its line, "Change my representation ↗" on Overview, the tabs, and the
/// tab's tools (the range picker, Activity's day picker) trailing under them.
struct BodyLead<Tools: View>: View {
    @Binding var tab: BodyTab
    /// The tabs show on Overview only once a device has sent anything (as on the web), and on every other tab.
    let showsTabs: Bool
    @ViewBuilder var tools: Tools
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        PageIntro(BodyOverviewMath.title, sub: BodyOverviewMath.sub) {
            if tab == .overview, BodyLeadMath.canChangeRepresentation(dashboard.status?.settings) {
                BodyRepresentationPill()
            }
        } slot: {
            if showsTabs { BodyTabs(tab: $tab) }
            BodyTools { tools }
        }
        .padding(.top, 16)
    }
}

/// The page's tabs (IntroTools' PageTabs). At the accessibility text sizes they wrap onto more lines instead, as the
/// app's pills and chip rows do there, so every tab shows and none sits out of sight past the row's end (on the open
/// Duo, past the leading pane's edge, over the fold).
struct BodyTabs: View {
    @Binding var tab: BodyTab
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let selection = Binding(get: { tab.rawValue }, set: { tab = BodyTab(rawValue: $0) ?? .overview })
        if typeSize.isAccessibilitySize {
            BodyWrap(spacing: 4, lineSpacing: 6) {
                ForEach(BodyTab.pageTabs) { t in
                    let on = t.id == selection.wrappedValue
                    Button(t.label) { selection.wrappedValue = t.id }
                        .buttonStyle(.plain)
                        .font(.app(size: 13, weight: .medium, relativeTo: .footnote))
                        .foregroundStyle(on ? Palette.surface : Palette.ink2)
                        .lineLimit(1)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(on ? Palette.ink : .clear, in: Capsule())
                        .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Body sections")
            .accessibilityIdentifier("body.tabs")
        } else {
            PageTabs(tabs: BodyTab.pageTabs, selection: selection, label: "Body sections")
                .accessibilityIdentifier("body.tabs")
        }
    }
}

/// Items in a row from the leading edge, onto the next line when the row is full (flex-wrap).
struct BodyWrap: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    private func frames(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width {
                x = 0
                y += line + lineSpacing
                line = 0
            }
            let w = min(size.width, width)
            frames.append(CGRect(x: x, y: y, width: w, height: size.height))
            x += w + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return (frames, CGSize(width: widest, height: y + line))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .greatestFiniteMagnitude
        let size = frames(subviews, width: width).size
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (sub, frame) in zip(subviews, frames(subviews, width: bounds.width).frames) {
            sub.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }
}

/// A tab's tools (the range picker, Activity's day picker), trailing: in a row when they fit, else one under the other.
struct BodyTools<Tools: View>: View {
    @ViewBuilder var tools: Tools

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                tools
            }
            VStack(alignment: .trailing, spacing: 10) { tools }.frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// The page's top on the open Duo when the page is split on the fold (a tab's charts, or the Overview without a
/// figure): the page's line and "Change my representation" on the leading side, the tabs and the tab's tools on the
/// trailing side, so both sides carry the top and nothing on it meets the fold. Unsplit, the lead as on the phone.
struct BodyHeader<Tools: View>: View {
    @Binding var tab: BodyTab
    let showsTabs: Bool
    @ViewBuilder var tools: Tools
    /// Read here, inside the page's scroll.
    @Environment(\.duoFold) private var fold

    var body: some View {
        if fold.splits {
            DuoPair {
                BodyLead(tab: $tab, showsTabs: false) { EmptyView() }
            } second: {
                VStack(alignment: .leading, spacing: 14) {
                    if showsTabs { BodyTabs(tab: $tab) }
                    BodyTools { tools }
                }
                .padding(.top, 16)
            }
        } else {
            BodyLead(tab: $tab, showsTabs: showsTabs) { tools }
        }
    }
}

enum BodyLeadMath {
    /// "Change my representation" shows only where the server's settings name a perspective: an older server ignores the
    /// welcome's settings, so its steps would change nothing there.
    static func canChangeRepresentation(_ settings: ServerStatus.Settings?) -> Bool { settings?.perspective != nil }

    /// The figure card's caption (FigureCard.tsx): a portrait only when there's a photo to draw it from; else the digital
    /// human the person sees, named.
    static func caption(portrait: Bool, variant: FigureVariant) -> String {
        portrait ? "Your portrait · A visual representation, not a measurement"
            : "Digital \(variant == .woman ? "woman" : "man") · Illustrative artwork · Not a body composition scan"
    }
}

/// "Change my representation ↗" as a pill: the welcome's first step again, in its edit mode (`open(.welcome)`).
struct BodyRepresentationPill: View {
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        Button { dashboard.open(.welcome) } label: {
            HStack(spacing: 6) {
                Text("Change my representation")
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .medium)).accessibilityHidden(true)
            }
        }
        .buttonStyle(.quietPill)
        .accessibilityHint("Opens your perspective, to pick your portrait, a digital human or just the statistics")
        .accessibilityIdentifier("body.changeRepresentation")
    }
}

// MARK: - The figure card

/// Your figure in the perspective you chose (FigureCard.tsx): your portrait or the digital human, with blood oxygen,
/// breathing and heart pointing at it, and a caption saying what it is. None for "Just the statistics".
struct BodyFigureCard: View {
    let summary: Summary
    /// Fitted to the height it's offered (the open Duo's leading pane, which doesn't scroll); else its own size.
    var fitted = false
    @Environment(Dashboard.self) private var dashboard
    /// The photo's version whose cut-out couldn't be loaded: the digital human stands in for it.
    @State private var failedPhoto: Double?

    var body: some View {
        let settings = dashboard.status?.settings
        let perspective = Perspective.of(settings)
        let photo = dashboard.status?.photo
        let shown = HomeFigure.shown(perspective, photo: photo, failed: failedPhoto)
        let variant = FigureVariant.of(settings).drawn
        VStack(spacing: 22) {
            if fitted {
                // The open Duo's leading pane offers a height too: the figure as big as fits it.
                BodyFigureFit(cap: 380, fillsHeight: shown == .portrait && photo != nil) { figure(shown, photo: photo, variant: variant) }
                    .frame(maxWidth: .infinity)
            } else {
                figure(shown, photo: photo, variant: variant)
                    .frame(maxWidth: 380)
                    .frame(maxWidth: .infinity)
            }
            VStack(spacing: 12) {
                // A portrait without a photo draws the digital human, so it's captioned as one.
                Text(BodyLeadMath.caption(portrait: perspective == .portrait && photo != nil && shown == .portrait, variant: variant))
                    .font(.app(size: 11, relativeTo: .caption2))
                    .foregroundStyle(Palette.ink3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if BodyLeadMath.canChangeRepresentation(settings) {
                    Button { dashboard.open(.welcome) } label: {
                        HStack(spacing: 4) {
                            Text("Change my representation")
                            Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .medium)).accessibilityHidden(true)
                        }
                        .font(.app(size: 12, relativeTo: .caption))
                        .foregroundStyle(Palette.ink2)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("body.figure.change")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, -6)
        .padding(.top, 6)
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your figure")
        .accessibilityIdentifier("body.figure")
    }

    @ViewBuilder private func figure(_ shown: HomeFigure.Shown, photo: PhotoMeta?, variant: FigureVariant) -> some View {
        if shown == .portrait, let photo {
            PortraitFigure(vitals: summary.vitals, asOf: summary.date, photo: photo, units: dashboard.units,
                           onFailed: { failedPhoto = photo.version })
        } else {
            DigitalFigure(vitals: summary.vitals, asOf: summary.date, variant: variant, units: dashboard.units)
        }
    }
}

/// The figure inside a height (the open Duo's leading pane): a photo takes the height and width it's offered; the
/// digital human is as wide as keeps it within the height, down to the narrowest its callouts fit beside it
/// (HomeLeadLayout.fit). Without a height, as wide as offered up to `cap`.
struct BodyFigureFit: Layout {
    var cap: CGFloat
    var fillsHeight: Bool

    func proposal(_ subviews: Subviews, _ proposal: ProposedViewSize) -> ProposedViewSize {
        let width = min(cap, proposal.width ?? cap)
        guard let figure = subviews.first, let room = proposal.height, room.isFinite else { return ProposedViewSize(width: width, height: nil) }
        if fillsHeight { return ProposedViewSize(width: width, height: room) }
        let fitted = HomeLeadLayout.fit(width: width, room: room) { figure.sizeThatFits(ProposedViewSize(width: $0, height: nil)).height }
        return ProposedViewSize(width: fitted, height: nil)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let figure = subviews.first else { return .zero }
        return figure.sizeThatFits(self.proposal(subviews, proposal))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let figure = subviews.first else { return }
        let offer = self.proposal(subviews, proposal)
        let size = figure.sizeThatFits(offer)
        figure.place(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.minY), proposal: ProposedViewSize(width: size.width, height: offer.height))
    }
}

/// The open Duo's leading pane on the Overview (decisions.md Q5): the page's lead, then the figure card, the figure
/// fitted so both stay inside the pane, which doesn't scroll. At the accessibility text sizes each keeps its own size
/// (the lead alone is so tall there that the pane scrolls whatever the figure's size).
struct BodyLeadPane<Lead: View>: View {
    let summary: Summary
    @ViewBuilder var lead: Lead
    /// The pane's height, read here inside it.
    @Environment(\.duoScopeHeight) private var height
    @Environment(\.dynamicTypeSize) private var typeSize

    static var bottom: CGFloat { 16 }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 14) {
                    lead
                    BodyFigureCard(summary: summary)
                }
            } else {
                BodyLeadPaneLayout(height: height.map { $0 - Self.bottom }) {
                    lead
                    BodyFigureCard(summary: summary, fitted: true)
                }
            }
        }
        .padding(.bottom, Self.bottom)
    }
}

/// The lead above the figure card: with a height, the card is offered what the lead leaves of it.
struct BodyLeadPaneLayout: Layout {
    var height: CGFloat?
    var spacing: CGFloat = 14

    private func offers(_ subviews: Subviews, width: CGFloat?) -> [ProposedViewSize] {
        let plain = ProposedViewSize(width: width, height: nil)
        guard subviews.count == 2, let height else { return subviews.map { _ in plain } }
        let lead = subviews[0].sizeThatFits(plain).height
        return [plain, ProposedViewSize(width: width, height: max(0, height - lead - spacing))]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let offers = offers(subviews, width: proposal.width)
        let sizes = zip(subviews, offers).map { $0.sizeThatFits($1) }
        let h = sizes.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, sizes.count - 1))
        return CGSize(width: proposal.width ?? sizes.map(\.width).max() ?? 0, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for (view, offer) in zip(subviews, offers(subviews, width: bounds.width)) {
            let size = view.sizeThatFits(offer)
            view.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: size.height))
            y += size.height + spacing
        }
    }
}

// MARK: - Measurement cards

/// One measurement's card (MeasurementCard.tsx): the latest value in your units, its change since about a month before,
/// the last 120 days and where it came from; its ↗ opens the metric's sheet. Without a reading, a dash and "Your
/// measurement, when you're ready". "+ Add entry" opens the form, except on a server without entries.
struct BodyMeasurementCard: View {
    let metric: BodyMetric
    /// The last 120 days, as stored (kg or %).
    let stored: [Point]
    /// Where the latest value came from; nil while it loads or when it isn't known.
    let latest: BodyLatestValue?
    /// The day the card shows: the sheet's window ends on it.
    let asOf: String
    /// nil hides "Add entry": a server without body entries.
    let onAdd: ((BodyMetric) -> Void)?
    @Environment(Dashboard.self) private var dashboard

    /// What the card says, worked out apart from drawing so the tests check it against the web's words.
    struct Words: Equatable {
        var value: String?
        var unit: String
        var note: String?
        var foot: String?
    }

    static func words(_ metric: BodyMetric, stored: [Point], latest: BodyLatestValue?, units: Units) -> Words {
        let unit = metric.unit(units)
        let points = stored.map { Point(date: $0.date, value: metric.inUnits($0.value, units)) }
        guard let last = points.last else { return Words(value: nil, unit: unit, note: "Your measurement, when you're ready", foot: nil) }
        // The footer names the source only when it's the same day the chart ends on.
        let source = latest?.date == last.date ? latest?.sourceName : nil
        return Words(value: Fmt.number(last.value, 1), unit: unit, note: BodyMath.change(points, unit: unit),
                     foot: "Latest \(Fmt.day(last.date))" + (source.map { " · \($0)" } ?? ""))
    }

    var body: some View {
        let units = dashboard.units
        let w = Self.words(metric, stored: stored, latest: latest, units: units)
        let points = stored.map { Point(date: $0.date, value: metric.inUnits($0.value, units)) }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Text(metric.label).font(.app(.footnote, weight: .medium)).foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
                if w.value != nil {
                    Button {
                        dashboard.showMetric(metric.sheetKey, section: "Body", page: AppRoute(.body, query: ["tab": "metabolism"]), date: asOf)
                    } label: {
                        Image(systemName: "arrow.up.right").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink2)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, -12)
                    .padding(.trailing, -12)
                    .accessibilityLabel("\(metric.label) details")
                    .accessibilityIdentifier("body.\(metric.rawValue).details")
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 16) {
                    value(w)
                    Spacer(minLength: 0)
                    if let note = w.note { noteText(note).multilineTextAlignment(.trailing).frame(maxWidth: 150, alignment: .trailing) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    value(w)
                    if let note = w.note { noteText(note) }
                }
            }
            .padding(.top, 14)
            if points.count > 1 {
                MiniLine(points: points, color: Palette.series1).frame(height: 36).padding(.top, 10)
            }
            Spacer(minLength: 0)
            BodyFlow(spacing: 12, lineSpacing: 8) {
                if let onAdd { BodyAddEntryButton(metric: metric) { onAdd(metric) } }
                if let foot = w.foot { Text(foot).font(.app(size: 11.5, relativeTo: .caption)).foregroundStyle(Palette.ink2) }
            }
            .padding(.top, 14)
        }
        .frame(minHeight: 132 - 38, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .card(metric.tint)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("body.\(metric.rawValue)")
    }

    private func value(_ w: Words) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            if let v = w.value {
                Text(v).font(.app(size: 38, weight: .medium, relativeTo: .largeTitle)).tracking(-0.03 * 38).foregroundStyle(Palette.ink)
                    .lineLimit(1).minimumScaleFactor(0.6)
            } else {
                Capsule().fill(Palette.ink).frame(width: 22, height: 4).padding(.bottom, 6).accessibilityLabel("No reading")
            }
            Text(w.unit).font(.app(size: 11, relativeTo: .caption2)).foregroundStyle(Palette.ink2)
        }
        .accessibilityElement(children: .combine)
    }

    private func noteText(_ note: String) -> some View {
        Text(note).font(.app(size: 11.5, relativeTo: .caption)).foregroundStyle(Palette.ink2).lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// "+ Add entry" (.measure-add): a small white pill.
struct BodyAddEntryButton: View {
    let metric: BodyMetric
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).accessibilityHidden(true)
                Text("Add entry")
            }
            .font(.app(size: 11.5, weight: .medium, relativeTo: .caption))
            .foregroundStyle(Palette.ink2)
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .frame(minHeight: 28)
            .background(Palette.surface, in: Capsule())
            .tokenShadow(.pill, in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add entry for \(metric.name)")
        .accessibilityIdentifier("body.\(metric.rawValue).add")
    }
}

/// The story card (Body.tsx StoryCard): what a scale, a scan or your records can add, and beside a figure, that the
/// figure isn't a measurement.
struct BodyStoryCard: View {
    let figure: Bool

    static func fine(figure: Bool) -> String {
        "No wearable connection needed." + (figure ? " Your portrait is a visual representation, not a measurement." : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("A picture of your progress")
            Text("Make your measurements part of the story.")
                .font(.app(.headline, weight: .medium)).foregroundStyle(Palette.ink).padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Add your weight, body fat or lean mass directly from a scale, a scan or your records. Each entry keeps its date so you can follow changes over time.")
                .font(.app(size: 12.5, relativeTo: .footnote)).foregroundStyle(Palette.ink2).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.fine(figure: figure))
                .font(.app(size: 10.5, relativeTo: .caption2)).foregroundStyle(Palette.ink3).padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("body.story")
    }
}

/// A row of small things that wraps onto more lines when they don't fit (the web's flex-wrap), each line's items spread
/// to its ends as `justify-content: space-between` does.
struct BodyFlow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    private func lines(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var out: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if !out[out.count - 1].isEmpty, x + spacing + size.width > width {
                out.append([])
                x = 0
            }
            x += (out[out.count - 1].isEmpty ? 0 : spacing) + size.width
            out[out.count - 1].append((i, size))
        }
        return out.map { $0.map { (index: $0.0, size: $0.1) } }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 10_000
        let ls = lines(subviews, width: width)
        let height = ls.map { $0.map(\.size.height).max() ?? 0 }.reduce(0, +) + lineSpacing * CGFloat(max(0, ls.count - 1))
        return CGSize(width: proposal.width ?? ls.map { $0.map(\.size.width).reduce(0, +) }.max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(subviews, width: bounds.width) {
            let h = line.map(\.size.height).max() ?? 0
            let used = line.map(\.size.width).reduce(0, +)
            let gap = line.count > 1 ? max(spacing, (bounds.width - used) / CGFloat(line.count - 1)) : 0
            var x = bounds.minX
            for item in line {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (h - item.size.height) / 2),
                                           proposal: ProposedViewSize(width: min(item.size.width, bounds.width), height: item.size.height))
                x += item.size.width + gap
            }
            y += h + lineSpacing
        }
    }
}
