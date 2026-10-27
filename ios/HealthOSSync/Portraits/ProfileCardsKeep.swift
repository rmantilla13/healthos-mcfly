import PhotosUI
import SwiftUI

/// What Profile's two open-in-place cards (the age-group comparison and the portrait photos) hold, kept above a page's
/// panes so a fold that swaps them (DuoPanes going between one column and two, duo/design.md §4, P4) doesn't start the
/// cards afresh: whether each is open, the portrait list and its thumbnails, the comparison as last read, "Use a photo
/// as is", and the studio's dialogs, photo picker and camera, which are presented from the page itself while it keeps
/// them.
///
/// The page makes one and puts it above its panes:
///
///     @State private var cards = ProfileCardsKeep()
///     …
///     DuoPage { _ in DuoPanes { … } secondary: { … PeersSection() … PortraitPhotosSection() } single: { … } }
///         .profileCards(cards)
///
/// Without one (any page that doesn't), each card keeps its own, as before. One person's at a time: everything goes the
/// moment someone else signs in, the server changes, or nobody is signed in, so nothing of the last person stays in
/// memory behind a sign-in screen. It isn't observed: the models in it are, and the cards read those.
@MainActor
final class ProfileCardsKeep {
    /// "<server>|<account>" these are for.
    private(set) var person: String?
    private var studioModel: PortraitStudioModel?
    private var peerReader: PeerReader?
    private var photoModel: PhotoAsIsModel?
    /// The studio's dialogs, picker and camera. The same one for the page's life (the page presents from it); emptied
    /// when the person changes.
    let asks = PortraitAsks()
    /// The read key the portrait list was last read for (PortraitPhotosSection.readKey): a card built again after a pane
    /// swap with nothing new to read doesn't read again.
    var studioReadKey: String?
    /// The same for the comparison (PeersSection.readKey), set once an answer is on screen.
    var peersReadKey: String?

    /// Whether the comparison's open body skips its read: it was last read for `key` and that answer is still on
    /// screen in `reader` (a failure, or nothing yet, reads again).
    func skipsPeersRead(key: String, reader: PeerReader) -> Bool {
        peersReadKey == key && reader.data != nil && reader.error == nil
    }

    /// Which of the two cards. Whether one is open is the card's own (Collapsible keeps it, and a slice doesn't change
    /// Components/), so the keep follows it from the open body: each body on screen holds a token here while it's
    /// shown (`.opensWith(_:_:)`), and a card built again by a fold's swap starts open if any body still holds one.
    /// A set of tokens, not a flag, because the new pane's card is built before the old one's body has gone: the old
    /// token is still here when the new card asks, and taking it away afterwards leaves the new one's.
    enum Card { case studio, peers }
    private var openBodies: [Card: Set<UUID>] = [:]

    /// Whether `card` was open when last seen: the `startsOpen` for a card built again.
    func isOpen(_ card: Card) -> Bool { !(openBodies[card] ?? []).isEmpty }

    func shown(_ card: Card, token: UUID) { openBodies[card, default: []].insert(token) }

    func gone(_ card: Card, token: UUID) { openBodies[card]?.remove(token) }

    init() {}

    /// The studio's model for `person`, made the first time (and again for someone else).
    func studio(for person: String) -> PortraitStudioModel {
        hold(person)
        if let studioModel { return studioModel }
        let made = PortraitStudioModel()
        studioModel = made
        return made
    }

    func peers(for person: String) -> PeerReader {
        hold(person)
        if let peerReader { return peerReader }
        let made = PeerReader()
        peerReader = made
        return made
    }

    func photo(for person: String, make: () -> PhotoAsIsModel) -> PhotoAsIsModel {
        hold(person)
        if let photoModel { return photoModel }
        let made = make()
        photoModel = made
        return made
    }

    /// The studio's model now, if it's still `person`'s (the camera's and the picker's answers go to it).
    func currentStudio(for person: String?) -> PortraitStudioModel? {
        person != nil && person == self.person ? studioModel : nil
    }

    /// Keeps only `person`'s: anyone else's (or everything, for nil) goes.
    func retain(only person: String?) {
        guard person != self.person else { return }
        self.person = person
        studioModel = nil
        peerReader = nil
        photoModel = nil
        studioReadKey = nil
        peersReadKey = nil
        openBodies = [:]
        asks.clear()
    }

    private func hold(_ person: String) { retain(only: person) }
}

/// The portrait studio's questions and pickers: Add's "Choose or take a photo", Delete's and "Replace your photo?"'s
/// dialogs, each shown on the button that asked (P10), and the photo picker and camera they open.
@MainActor
@Observable
final class PortraitAsks {
    var askSource = false
    var pickerShown = false
    var cameraShown = false
    var picked: PhotosPickerItem?
    var deleting: Portrait?
    var replacing: Portrait?

    /// Add: the camera or Photos where there's a camera, straight to Photos otherwise.
    func add(camera: Bool) {
        if camera { askSource = true } else { pickerShown = true }
    }

    func clear() {
        askSource = false
        pickerShown = false
        cameraShown = false
        picked = nil
        deleting = nil
        replacing = nil
    }
}

extension View {
    /// Marks this as `card`'s open body for the page's keep (nil: nothing to mark), so a fold's swap builds the card
    /// open again. Put it on one view that's shown exactly while the card is open.
    func opensWith(_ keep: ProfileCardsKeep?, _ card: ProfileCardsKeep.Card) -> some View {
        modifier(OpenBodyMark(keep: keep, card: card))
    }
}

private struct OpenBodyMark: ViewModifier {
    let keep: ProfileCardsKeep?
    let card: ProfileCardsKeep.Card
    @State private var token = UUID()

    func body(content: Content) -> some View {
        if let keep {
            content
                .onAppear { keep.shown(card, token: token) }
                .onDisappear { keep.gone(card, token: token) }
        } else {
            content
        }
    }
}

private struct ProfileCardsKeepKey: EnvironmentKey {
    static let defaultValue: ProfileCardsKeep? = nil
}

extension EnvironmentValues {
    /// The page's keep for its two cards (`View.profileCards(_:)`); nil where a page has none.
    var profileCardsKeep: ProfileCardsKeep? {
        get { self[ProfileCardsKeepKey.self] }
        set { self[ProfileCardsKeepKey.self] = newValue }
    }
}

extension View {
    /// Profile's two cards keep what they hold in `keep`, above the page's panes (P4): put it on the view that persists,
    /// the `DuoPage` or the page's root. It also presents the studio's photo picker and camera from there, and forgets
    /// everything when the person signed in changes.
    func profileCards(_ keep: ProfileCardsKeep) -> some View { modifier(ProfileCardsRoot(keep: keep)) }
}

private struct ProfileCardsRoot: ViewModifier {
    let keep: ProfileCardsKeep
    @Environment(Dashboard.self) private var dashboard

    func body(content: Content) -> some View {
        content
            .environment(\.profileCardsKeep, keep)
            .portraitPickers(keep.asks) { keep.currentStudio(for: dashboard.signedInPerson) }
            .onChange(of: dashboard.signedInPerson, initial: true) { _, person in keep.retain(only: person) }
    }
}

extension View {
    /// The studio's photo picker and camera, for `asks`; what they bring goes to the model `studio` gives then (nil: the
    /// person changed, so it goes nowhere).
    func portraitPickers(_ asks: PortraitAsks, studio: @escaping @MainActor () -> PortraitStudioModel?) -> some View {
        modifier(PortraitPickers(asks: asks, studio: studio))
    }
}

private struct PortraitPickers: ViewModifier {
    let asks: PortraitAsks
    let studio: @MainActor () -> PortraitStudioModel?

    func body(content: Content) -> some View {
        @Bindable var asks = asks
        content
            .photosPicker(isPresented: $asks.pickerShown, selection: $asks.picked, matching: .images, photoLibrary: .shared())
            .onChange(of: asks.picked) { _, item in
                guard let item else { return }
                asks.picked = nil
                guard let model = studio() else { return }
                Task { await Self.add(item, to: model) }
            }
            .fullScreenCover(isPresented: $asks.cameraShown) {
                CameraPicker { image in
                    asks.cameraShown = false
                    guard let image, let model = studio() else { return }
                    Task { await model.add { PhotoPipeline.reference(image) } }
                }
                .ignoresSafeArea()
            }
    }

    private static func add(_ item: PhotosPickerItem, to model: PortraitStudioModel) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return model.notAnImage() }
        await model.add { PhotoPipeline.reference(data) }
    }
}
