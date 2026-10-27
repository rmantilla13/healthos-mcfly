import SafariServices
import SwiftUI

/// A web page inside the app (SFSafariViewController), for the server's public pages such as privacy.html. It has its
/// own cookies, not the app's session, so pages that need sign-in open in Safari instead (UIApplication.open).
///
///     .sheet(item: $page) { SafariView(url: $0.url).ignoresSafeArea() }
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.preferredControlTintColor = UIColor(Palette.tint)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
