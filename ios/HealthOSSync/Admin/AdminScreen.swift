import SwiftUI

/// Admin (src/pages/Admin.tsx): people, invites and platform settings, for admins only. Not built here yet.
struct AdminScreen: View {
    /// Built here: Admin opens this page. Until then the account menu opens the web dashboard's Admin page.
    static let native = false

    var body: some View { ComingSoon(page: .admin) }
}
