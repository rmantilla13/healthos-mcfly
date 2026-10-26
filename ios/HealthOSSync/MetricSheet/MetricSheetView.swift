import SwiftUI

/// A metric's detail sheet (src/components/MetricSheet.tsx, GET /api/metric/:key), shown over the app by the shell for
/// `dashboard.showMetric(_:page:)`. Slice C builds it here; until then it says so, and "Open {Page}" goes to the
/// card's page as the web's does.
struct MetricSheetView: View {
    let request: MetricRequest
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        SheetScaffold(eyebrow: request.section, title: "Details") {
            Text("The detail sheet is coming in this build.").font(.app(.subheadline)).foregroundStyle(Palette.ink2)
        } footer: {
            Button("Open \(request.page.title)") {
                dashboard.metricSheet = nil
                dashboard.open(request.page)
            }
            .buttonStyle(.accentPill(arrow: true))
        }
    }
}
