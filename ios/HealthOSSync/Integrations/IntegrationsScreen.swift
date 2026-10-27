import SwiftUI

/// The Integrations page (src/pages/Integrations.tsx), under More and in the account menu: "Bring your health
/// together." with the WHOOP, Fitbit / Google Health and Apple Watch / Health cards, "Measured. Always clear." and, on a
/// local server for its owner, the demo data. `query` is the web's (?whoop= after WHOOP's sign-in), applied again when
/// the same link opens the page while it's up.
///
/// On the open iPhone Duo (inner display in landscape) the cards go two a row, one each side of the fold, the intro on
/// the leading side; everywhere else one column, in the web's order. Everything the page holds is in its model, above
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

/// The page's content, one scroll in every state. Its cards go in one DuoGrid: one column on every iPhone, the outer
/// display and the inner display upright (the web's single column below 1080 px), and two a row on the open Duo, one
/// each side of the fold (WHOOP | Fitbit, then Apple | the note and the demo), so neither side is left empty while the
/// other scrolls and no card crosses the fold. The intro and the banner keep to the leading side. Nothing here is
/// rebuilt by a fold (no panes), so the scroll and every card's state stay; the rest is in the model, above (P4).
private struct IntegrationsContent: View {
    let status: ServerStatus
    @Bindable var model: IntegrationsModel

    var body: some View {
        DuoScroll {
            VStack(alignment: .leading, spacing: 14) {
                PageIntro(IntegrationsWords.title, sub: IntegrationsWords.sub)
                    .padding(.bottom, 4)
                    .duoOneSide()
                if let banner = IntegrationsRules.banner(query: model.query, hosted: status.hosted ?? true, admin: status.user?.role == "admin") {
                    IntegrationsBanner(text: banner.text, good: banner.good).duoOneSide()
                }
                DuoGrid(IntegrationsCell.cells(status), id: \.self, medium: 1) { cell in
                    self.cell(cell).id(cell.id)
                }
            }
            .padding(.vertical, 16)
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
        case .aside:
            VStack(alignment: .leading, spacing: 14) {
                SourcesNote()
                if IntegrationsRules.showsDemo(status) { DemoCard(status: status, model: model) }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

/// One cell of Integrations' grid, by a fixed id, so a source the server doesn't name moves nothing else.
enum IntegrationsCell: String, Hashable {
    case whoop, fitbit, apple, aside
    var id: String { "integrations.\(rawValue)" }

    /// What the grid holds: the sources the status names, then the note (with the demo card under it).
    static func cells(_ status: ServerStatus) -> [IntegrationsCell] {
        var cells: [IntegrationsCell] = []
        if status.whoop != nil { cells.append(.whoop) }
        // Only where the status names it: a server older than the Fitbit import would answer its routes 404.
        if status.fitbit != nil { cells.append(.fitbit) }
        cells.append(.apple)
        cells.append(.aside)
        return cells
    }
}
