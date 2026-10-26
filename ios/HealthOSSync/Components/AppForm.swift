import SwiftUI

extension View {
    /// A Form (or a grouped List) on the web's colours rather than the system's: the warm page behind it, and with
    /// `appFormRows()` its rows on the surface (white, the card's #1a1c1a in dark mode). Its text keeps the system's
    /// label colours, so headers, footers, values and buttons keep their greys and tint: a foreground style set on a Form
    /// turns all of them the one ink. A page built from the web's own pieces (ProfileCard, ProfileRow) uses ink itself.
    ///
    ///     Form { Group { … }.appFormRows() }.appForm()
    func appForm() -> some View {
        scrollContentBackground(.hidden).background(Palette.page)
    }

    /// The surface behind each row of a Form's sections (apply it to the sections, or a Group of them). A row that
    /// sets its own background (a clear intro line) keeps it.
    func appFormRows() -> some View { listRowBackground(Palette.surface) }
}
