import SwiftUI

/// Profile's "Your age-group comparison" (src/pages/Profile.tsx PeerComparison): a card that opens in place, with how
/// the person's numbers sit among people their age (GET /api/peers). Profile places it; what it shows is built here.
/// Not built yet: it says so, and reads nothing.
struct PeersSection: View {
    var body: some View {
        Collapsible("Your age-group comparison", meta: "Private to you", systemImage: "chart.bar") {
            Text("Your age-group comparison is coming in this build.").foregroundStyle(Palette.ink2)
        }
    }
}
