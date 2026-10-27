import SwiftUI

/// Search: the web's ⌘K palette (src/components/Search.tsx) as a system sheet at the web's width (W14). A stub the
/// foundation hands to slice S, which builds it here (with its SearchCatalogue.swift) and then sets `ready`. Until then
/// the toolbar's Search item doesn't show, so nothing opens it. It's shown while `dashboard.searchOpen` is true, and
/// closing it sets that back.
struct SearchScreen: View {
    /// S sets this to true once Search is built: the toolbar's `Label("Search", systemImage: "magnifyingglass")` shows
    /// only while it's true.
    static let ready = false

    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        SheetScaffold(title: "Search", size: .md, onClose: { dashboard.searchOpen = false }) {
            Text("Search isn't here yet.")
                .font(.app(.body))
                .foregroundStyle(Palette.ink2)
        }
    }
}
