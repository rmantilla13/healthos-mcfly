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
    @Environment(\.profileCardsKeep) private var keep

    var body: some View {
        // Whose card it is: another server or another account starts from nothing.
        if let person = dashboard.signedInPerson {
            PortraitPhotosCard(person: person, keep: keep).id(person)
        }
    }

    /// When the list is read again: on showing Profile (for the count) and after every load; when the profile photo
    /// changes or goes (the portrait in use may have changed with it); when the welcome closes (its first step adds and
    /// replaces reference photos without a load); and when the person connects or removes their own OpenAI key (whether
    /// a portrait can be made). The web reads it again on each of these through notifyDataChanged.
    static func readKey(generation: Int, photo: String?, welcomeOpen: Bool, ownOpenAIKey: Bool) -> String {
        "\(generation)|\(photo ?? "none")|\(welcomeOpen ? "welcome" : "-")|\(ownOpenAIKey ? "key" : "-")"
    }
}

private struct PortraitPhotosCard: View {
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.profileCardsKeep) private var keep
    @State private var model: PortraitStudioModel

    /// The page's kept model for `person` when it keeps one (above its panes, so a fold's swap finds it again), else
    /// one of its own.
    init(person: String, keep: ProfileCardsKeep? = nil) {
        _model = State(initialValue: keep?.studio(for: person) ?? PortraitStudioModel())
        self.person = person
    }

    private let person: String

    var body: some View {
        // Open again after a fold's swap if it was open (the keep follows its open body).
        Collapsible("Your portrait photos", meta: Self.meta(model), systemImage: "camera", startsOpen: keep?.isOpen(.studio) ?? false) {
            // One view for the open body (the card's own stack, its 14 pt), so it's marked once.
            VStack(alignment: .leading, spacing: 14) {
                if model.missing {
                    PhotoSection()
                } else {
                    PortraitStudio(model: model)
                    PhotoSection()
                        .padding(.top, 16)
                        .overlay(alignment: .top) { Hairline() }
                }
            }
            .opensWith(keep, .studio)
        }
        .task(id: readKey) {
            if model.service == nil { model.service = .live(dashboard) }
            // Built again by a fold (the page's panes swapped) with nothing new since the last read: no second read.
            if let keep, keep.studioReadKey == readKey, keep.currentStudio(for: person) === model, model.list != nil || model.missing { return }
            await model.read()
            keep?.studioReadKey = readKey
        }
    }

    private var readKey: String {
        PortraitPhotosSection.readKey(generation: dashboard.generation, photo: dashboard.status?.photo?.versionKey,
                                      welcomeOpen: dashboard.onboarding != nil,
                                      ownOpenAIKey: dashboard.availability.ai.value?.key("openai") != nil)
    }

    /// "3 files", as the web counts them; nothing until the list is read, or on a server without portraits.
    static func meta(_ model: PortraitStudioModel) -> String? {
        guard let n = model.list?.portraits.count else { return nil }
        return "\(n) \(n == 1 ? "file" : "files")"
    }
}
