import SwiftUI

/// The Integrations page (src/pages/Integrations.tsx), under More and in the account menu. Not built here yet. `query`
/// is the web's (?connect=, ?whoop=).
struct IntegrationsScreen: View {
    var query: [String: String] = [:]

    var body: some View { ComingSoon(page: .integrations) }
}
