import SwiftUI

/// The Body page (src/pages/Body.tsx). Until it's built here, the charts the Trends tab had for Body and Activity, as
/// two tabs. A link with tab=activity opens Activity (the web's #/activity, Home's steps and workouts).
struct BodyScreen: View {
    @Environment(Dashboard.self) private var dashboard
    @State private var section: TrendsSection = .body

    var body: some View {
        TrendsPage(sections: [.body, .activity], selection: $section)
            .onChange(of: dashboard.request(for: .body), initial: true) { _, request in
                guard let request else { return }
                section = request.route.query["tab"] == "activity" ? .activity : .body
            }
    }
}
