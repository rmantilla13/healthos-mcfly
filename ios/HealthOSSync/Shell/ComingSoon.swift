import SwiftUI

/// A page that isn't built in the app yet. Each one's own file shows this until its page is built there. Never in a
/// release: the redesign ships once every page is done.
struct ComingSoon: View {
    let page: AppPage

    var body: some View {
        Unavailable(page.title, systemImage: page.symbol, description: "\(page.title) is coming in this build.")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.page)
    }
}
