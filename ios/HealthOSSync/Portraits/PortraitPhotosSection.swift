import SwiftUI

/// Profile's "Your portrait photos" (src/pages/Profile.tsx PortraitPhotos): a card that opens in place, with how many
/// files there are on its line, the portrait studio (reference photos and the portraits made from them) and, under a
/// hairline, "Use a photo as is". Profile places it.
///
/// Only while signed in, and one person's at a time: everything it read (the list, the thumbnails) is held by the card
/// for the person and server it was read for, and goes when they sign out or someone else signs in. On a server older
/// than portraits the studio is left out and "Use a photo as is" stays.
struct PortraitPhotosSection: View {
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        // Whose card it is: another server or another account starts from nothing.
        if let person = dashboard.signedInPerson {
            PortraitPhotosCard().id(person)
        }
    }
}

private struct PortraitPhotosCard: View {
    @Environment(Dashboard.self) private var dashboard
    @State private var model = PortraitStudioModel()

    var body: some View {
        Collapsible("Your portrait photos", meta: Self.meta(model), systemImage: "camera") {
            if model.missing {
                PhotoSection()
            } else {
                PortraitStudio(model: model)
                PhotoSection()
                    .padding(.top, 16)
                    .overlay(alignment: .top) { Hairline() }
            }
        }
        // Read on showing Profile (for the count) and after every load; a new profile photo or none means the portrait
        // in use may have changed.
        .task(id: "\(dashboard.generation)|\(dashboard.status?.photo?.versionKey ?? "none")") {
            if model.service == nil { model.service = .live(dashboard) }
            await model.read()
        }
    }

    /// "3 files", as the web counts them; nothing until the list is read, or on a server without portraits.
    static func meta(_ model: PortraitStudioModel) -> String? {
        guard let n = model.list?.portraits.count else { return nil }
        return "\(n) \(n == 1 ? "file" : "files")"
    }
}
