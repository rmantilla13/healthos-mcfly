import SwiftUI

/// A page's empty or error state ("Couldn't load trends"): the system's ContentUnavailableView, with its words in
/// DM Sans. The system view sets its own system fonts and colours, whatever the app's, so the title, the line under it
/// and the actions get theirs here, at the system's sizes, in the web's ink; the icon keeps the system's size.
///
///     Unavailable("Can't load your dashboard", systemImage: "wifi.exclamationmark", description: message) {
///         Button("Try again") { … }
///     }
struct Unavailable<Actions: View>: View {
    let title: String
    let systemImage: String
    var description: String?
    @ViewBuilder var actions: Actions

    init(_ title: String, systemImage: String, description: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.actions = actions()
    }

    var body: some View {
        ContentUnavailableView {
            Label {
                // The system view makes its title bold; the web's headings are semibold at most.
                Text(title).font(.app(.title3)).fontWeight(.semibold).foregroundStyle(Palette.ink)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(Palette.ink3)
            }
        } description: {
            if let description { Text(description).font(.app(.body)).foregroundStyle(Palette.ink2) }
        } actions: {
            actions.font(.app(.subheadline))
        }
    }
}

extension Unavailable where Actions == EmptyView {
    init(_ title: String, systemImage: String, description: String? = nil) {
        self.init(title, systemImage: systemImage, description: description) { EmptyView() }
    }
}
