import SwiftUI

/// The Integrations page (src/pages/Integrations.tsx), under More and in the account menu: "Bring your health
/// together." with the WHOOP, Fitbit / Google Health and Apple Watch / Health cards, "Measured. Always clear." and, on a
/// local server for its owner, the demo data. `query` is the web's (?whoop= after WHOOP's sign-in), applied again when
/// the same link opens the page while it's up.
///
/// On the open iPhone Duo (inner display in landscape) the page takes decisions.md Q5's frame: the intro and Apple Watch /
/// Health on the leading side of the fold, the other cards in two columns on the trailing side; everywhere else one
/// column, in the web's order. Everything the page holds is in its model, above
/// the DuoPage (P4): the token shown once, the dialogs and disclosures, what's running.
struct IntegrationsScreen: View {
    var query: [String: String] = [:]
    @Environment(Dashboard.self) private var dashboard
    @Environment(AppModel.self) private var sync: AppModel?
    @State private var model: IntegrationsModel
    /// Drawn tests pass their own model, whose phone and requests never reach this iPhone or a server.
    private let ownModel: Bool

    init(query: [String: String] = [:]) {
        self.query = query
        _model = State(initialValue: IntegrationsModel(query: query))
        ownModel = false
    }

    #if DEBUG
    init(model: IntegrationsModel) {
        query = model.query
        _model = State(initialValue: model)
        ownModel = true
    }
    #endif

    var body: some View {
        PhaseGate { page }
    }

    private var page: some View {
        DuoPage { _ in
            if let status = dashboard.status {
                IntegrationsContent(status: status, model: model)
            } else if case .unavailable(let message) = dashboard.phase {
                Unavailable("Integrations", systemImage: AppPage.integrations.symbol, description: message)
            } else {
                ProgressView()
            }
        }
        .background(Palette.page.ignoresSafeArea())
        // P4: the sheet, the loaders and pull to refresh live here, above the panes a fold swaps.
        .sheet(isPresented: $model.fitbitOpen, onDismiss: { Task { await dashboard.load() } }) {
            FitbitImportSheet(onClose: { model.fitbitOpen = false })
        }
        .refreshable { await dashboard.load() }
        .task {
            if !ownModel, let sync { model.phone = .app(sync) }
            // The status may be older than WHOOP connected in Safari, or a sync on the web.
            await model.refresh(dashboard)
        }
        .task(id: dashboard.status?.whoop?.syncing == true) { await model.watchWhoopSync(dashboard) }
        .onChange(of: dashboard.session, initial: true) { _, now in model.follow(now) }
        // The same link again while the page is up: its query again (README, "A link opened again under More").
        .onChange(of: dashboard.request(for: .integrations)?.id) { _, _ in
            if let request = dashboard.request(for: .integrations), request.route.page == .integrations {
                model.query = request.route.query
            }
        }
    }
}

/// The page's content. On every iPhone, the outer display and the inner display upright: one column in the web's order
/// (the web's single column below 1080 px). On the open Duo held sideways, the no-picture frame (decisions.md Q5): the
/// lead on the leading side of the fold (the intro, the banner and Apple Watch / Health, this iPhone's own source, with
/// Set up this iPhone and the token shown once), scrolling on its own since the setup grows; the other sources, the
/// note and the demo card on the trailing side, each across that side's two columns, scrolling together. No card crosses the fold, and an open
/// setup leaves no side empty beside the other. Everything a fold's swap of panes would lose is in the model (P4); the
/// confirmation dialogs stay on their buttons, their anchor at regular width, so a swap may close one (P10, accepted).
private struct IntegrationsContent: View {
    let status: ServerStatus
    @Bindable var model: IntegrationsModel

    var body: some View {
        DuoPanes(anchor: .secondary, leadScrolls: true) {
            VStack(alignment: .leading, spacing: 14) {
                lead
                AppleCard(status: status, model: model).id(IntegrationsCell.apple.id)
            }
            .padding(.vertical, 16)
        } secondary: {
            VStack(alignment: .leading, spacing: 14) {
                // Q5: a card that needs the width spans the side's two columns. Each of these does at the open Duo's
                // sizes: half a side cuts WHOOP's and Fitbit's buttons ("Re-sync full…") and wraps the demo choices.
                DuoGrid(IntegrationsCell.trailing(status), id: \.self, paneColumns: 2) { cell in
                    self.cell(cell).duoSpans().id(cell.id)
                }
            }
            .scrollTargetLayout()
            .padding(.vertical, 16)
        } single: {
            VStack(alignment: .leading, spacing: 14) {
                lead
                ForEach(IntegrationsCell.cells(status), id: \.self) { cell in
                    self.cell(cell).id(cell.id)
                }
            }
            .scrollTargetLayout()
            .padding(.vertical, 16)
        }
    }

    @ViewBuilder private var lead: some View {
        PageIntro(IntegrationsWords.title, sub: IntegrationsWords.sub)
            .padding(.bottom, 4)
        if let banner = IntegrationsRules.banner(query: model.query, hosted: status.hosted ?? true, admin: status.user?.role == "admin") {
            IntegrationsBanner(text: banner.text, good: banner.good)
        }
    }

    @ViewBuilder private func cell(_ cell: IntegrationsCell) -> some View {
        switch cell {
        case .whoop:
            if let whoop = status.whoop { WhoopCard(status: status, whoop: whoop, model: model) }
        case .fitbit:
            if let fitbit = status.fitbit { FitbitCard(fitbit: fitbit, model: model) }
        case .apple:
            AppleCard(status: status, model: model)
        case .note:
            SourcesNote()
        case .demo:
            DemoCard(status: status, model: model)
        }
    }
}

/// One card of Integrations, by a fixed id, so a source the server doesn't name moves nothing else.
enum IntegrationsCell: String, Hashable {
    case whoop, fitbit, apple, note, demo
    var id: String { "integrations.\(rawValue)" }

    /// The web's order: the sources the status names, the note, then (a local server's owner) the demo card.
    static func cells(_ status: ServerStatus) -> [IntegrationsCell] {
        var cells: [IntegrationsCell] = []
        if status.whoop != nil { cells.append(.whoop) }
        // Only where the status names it: a server older than the Fitbit import would answer its routes 404.
        if status.fitbit != nil { cells.append(.fitbit) }
        cells.append(.apple)
        cells.append(.note)
        if IntegrationsRules.showsDemo(status) { cells.append(.demo) }
        return cells
    }

    /// The open Duo's trailing side: everything but Apple Watch / Health, which leads on the leading side.
    static func trailing(_ status: ServerStatus) -> [IntegrationsCell] { cells(status).filter { $0 != .apple } }
}
