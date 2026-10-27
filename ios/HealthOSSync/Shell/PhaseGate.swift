import SwiftUI

/// What a page shows while there's no dashboard to show: no server set yet, the sign-in screen (SignInView), or a server
/// whose sign-in isn't set up (SignInUnavailable). The sign-in screens are slice A's (Auth/, SignInView.swift), so
/// they're drawn the same wherever they show. Starting and offline-with-nothing-kept are the page's own, since pages
/// treat them differently (Home waits, Family keeps its board): `content` gets those phases and `.ready`.
///
///     PhaseGate { InsightsContent() }
struct PhaseGate<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        switch dashboard.phase {
        case .noServer: NoServer()
        case .signIn: SignInView()
        case .misconfigured: SignInUnavailable()
        default: content
        }
    }
}

/// No server address yet: where to add it.
private struct NoServer: View {
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        Unavailable("No server yet", systemImage: "server.rack", description: "Add your healthOS address in Profile.") {
            Button("Open Profile") { dashboard.tab = .settings }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.page)
    }
}
