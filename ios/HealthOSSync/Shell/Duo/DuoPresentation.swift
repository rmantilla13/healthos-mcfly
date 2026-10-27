import SwiftUI

// iPhone Duo: how the app's menus and sheets present (§2.7, D11, O5), in one place: the one iOS 18 check this design
// adds, and the sheets' iOS 27.1 container.

extension View {
    /// The account menu and Nutrition's + (sheets): .presentationDetents([.height(height)]) as today, plus, on iOS 18+,
    /// .presentationSizing(.fitted), so the centred sheet at regular width fits the menu (§2.7, [U→G3]). Apply it where
    /// the menu sheet sets its detent today, in place of `.presentationDetents([.height(height)])`.
    func duoMenuSheet(height: CGFloat) -> some View {
        modifier(DuoMenuSheet(height: height))
    }
}

private struct DuoMenuSheet: ViewModifier {
    let height: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.presentationDetents([.height(height)]).presentationSizing(.fitted)
        } else {
            content.presentationDetents([.height(height)])
        }
    }
}

/// SheetScaffold's container (O5, D13): on iOS 27.1 and later, where the sheet can have a vertical bar of its own and a
/// fold can resize it, a NavigationStack, always, so the bar can hold Close and the sheet's structure never changes on a
/// fold. Before 27.1 neither can happen, so the sheet is exactly as it was, with no stack: every iPhone's sheets look and
/// behave as before (a keyboard toolbar attached outside the sheet, as Profile's two sheets attach `keyboardDismissal()`,
/// doesn't reach fields inside a NavigationStack). The stack draws no background of its own, so the sheet's
/// presentation background (its gradient) shows through.
struct DuoSheetStack<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if #available(iOS 27.1, *) {
            NavigationStack { content.containerBackground(.clear, for: .navigation) }
        } else {
            content
        }
    }
}
