import PhotosUI
import SwiftUI

/// Step 1, "How would you like to see yourself?" (Onboarding.tsx PerspectiveStep): three radio cards, each on its
/// side at phone width, and with "Your own portrait" chosen, the photo the portrait is made from.
struct PerspectiveStep: View {
    @Bindable var model: OnboardingModel
    let reference: ReferencePhoto
    let hasPhoto: Bool

    /// The views (VIEWS).
    static let views: [(id: Perspective, title: String, text: String)] = [
        (.portrait, "Your own portrait", "Your likeness, rendered in the healthOS style from a photo."),
        (.digital, "Digital human", "A modern Vitruvian figure, no photo needed."),
        (.stats, "Just the statistics", "Your measurements take the whole stage."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 10) {
                ForEach(Self.views, id: \.id) { view in
                    PerspectiveCard(id: view.id, title: view.title, text: view.text, figure: OnboardingFlow.figureOf(model.answers),
                                    isOn: model.answers.perspective == view.id) {
                        model.answers.perspective = view.id
                    }
                }
            }
            .padding(.top, 26)
            if model.answers.perspective == .portrait, reference.available != false {
                ReferenceRow(reference: reference, hasPhoto: hasPhoto)
            }
        }
    }
}

/// One view to choose (.onb-choice): the illustration on the left, its name and line on the right, a radio mark in the
/// corner. VoiceOver reads it as one choice, selected or not.
private struct PerspectiveCard: View {
    let id: Perspective
    let title: String
    let text: String
    let figure: FigureVariant
    let isOn: Bool
    let choose: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        // At the accessibility text sizes the illustration goes over the words (the web's wide layout), so they keep the
        // card's width and no word breaks in the middle.
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0)) : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
        Button(action: choose) {
            layout {
                ZStack(alignment: .bottom) {
                    ArtShade()
                    art
                }
                .frame(maxWidth: stacked ? .infinity : 96)
                .frame(width: stacked ? nil : 96)
                .frame(minHeight: stacked ? 110 : 96, maxHeight: stacked ? 110 : .infinity)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: stacked ? 0 : 16, topTrailingRadius: stacked ? 16 : 0,
                                                  style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    WrapLayout(spacing: 8, lineSpacing: 2) {
                        Text(title)
                            .font(.app(size: 14, weight: .medium, relativeTo: .subheadline))
                            .foregroundStyle(Palette.ink)
                        if id == .portrait {
                            Text(OnboardingWords.defaultBadge)
                                .textCase(.uppercase)
                                .font(.app(size: 8.5, weight: .medium, relativeTo: .caption2))
                                .tracking(8.5 * 0.12)
                                .foregroundStyle(Palette.ink3)
                        }
                    }
                    Text(text)
                        .font(.app(size: 12, relativeTo: .footnote))
                        .lineSpacing(3)
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 16)
                .padding(.leading, stacked ? 16 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.trailing, 16)
            .background {
                if isOn { GradientFill(.choiceWash).clipShape(shape) }
                else { (reduceTransparency ? Palette.surface : WelcomeLook.cardBg.color).clipShape(shape) }
            }
            .overlay(shape.strokeBorder(isOn ? Palette.choiceBorder : Palette.border, lineWidth: isOn ? 1.5 : 1))
            .overlay(alignment: .topLeading) { OnbRadio(isOn: isOn).padding(10) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isOn) { _, on in on }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(id == .portrait ? "\(title), default" : title)
        .accessibilityValue(text)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("perspective.\(id.rawValue)")
    }

    @ViewBuilder
    private var art: some View {
        switch id {
        case .portrait: BustArt().frame(width: 84, height: 84)
        case .digital: HumanArt(variant: figure).frame(height: 78).padding(.bottom, 4)
        case .stats: StatsArt(barWidth: 12, gap: 6, height: 60).padding(.bottom, 8)
        }
    }
}

/// The web's radio (.onb-radio): a ring on the surface, filled ink-2 with a surface ring inside once chosen.
private struct OnbRadio: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            Circle().fill(isOn ? Palette.ink2 : Palette.surface)
            if isOn { Circle().strokeBorder(Palette.surface, lineWidth: 2.5) }
            Circle().strokeBorder(Palette.ink2, lineWidth: 1)
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

/// The portrait's reference photo (ReferenceRow): Choose photo, then its thumbnail with Change and Remove, and what
/// happens next on this server. The photo stays private: it's never shown on the dashboard.
private struct ReferenceRow: View {
    let reference: ReferencePhoto
    let hasPhoto: Bool
    @Environment(Dashboard.self) private var dashboard
    @State private var item: PhotosPickerItem?
    @State private var picking = false
    @State private var camera = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // At phone width Choose photo sits beside the words, as on the web; with a photo, Change and Remove go under
        // them, and at the accessibility text sizes so does Choose photo, so the words keep the row's width.
        let beside = reference.photo == nil && !typeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Palette.border).frame(height: 1).accessibilityHidden(true)
            HStack(alignment: .center, spacing: 16) {
                if let photo = reference.photo {
                    Image(uiImage: photo.preview)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .tokenShadow(.pill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityLabel(OnboardingWords.referenceAlt)
                        .accessibilityAddTraits(.isImage)
                        .accessibilityIdentifier("referenceThumb")
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(OnboardingWords.referenceTitle)
                        .font(.app(size: 13.5, weight: .medium, relativeTo: .subheadline))
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(OnboardingWords.referenceText)
                        .font(.app(size: 11.5, relativeTo: .caption))
                        .lineSpacing(2)
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let state {
                        state.padding(.top, 2)
                    }
                    if let note = reference.note {
                        Text(note)
                            .font(.app(size: 12, relativeTo: .caption))
                            .foregroundStyle(ColorToken.badgePeachInk.color)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                            .accessibilityIdentifier("referenceNote")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if beside { actions }
            }
            .padding(.top, 22)
            if !beside { actions.padding(.top, 12) }
            Text(after)
                .font(.app(size: 11.5, relativeTo: .caption))
                .lineSpacing(3)
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
                .accessibilityIdentifier("portraitNext")
        }
        .padding(.top, 22)
        .photosPicker(isPresented: $picking, selection: $item, matching: .images, photoLibrary: .shared())
        .onChange(of: item) { _, picked in
            guard let picked else { return }
            item = nil
            Task {
                let data = try? await picked.loadTransferable(type: Data.self)
                reference.choose { data.flatMap { PhotoPipeline.reference($0) } }
            }
        }
        .fullScreenCover(isPresented: $camera) {
            CameraPicker { image in
                camera = false
                if let image { reference.choose { PhotoPipeline.reference(image) } }
            }
            .ignoresSafeArea()
        }
        .task {
            await dashboard.loadAI()
            if reference.available == nil { await reference.load() }
        }
    }

    /// Choose photo, or Change and Remove: Photos, or the camera where there is one, as a phone's browser offers for the
    /// web's file field.
    private var actions: some View {
        HStack(spacing: 6) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Menu {
                    Button { picking = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                    Button { camera = true } label: { Label("Take Photo", systemImage: "camera") }
                } label: {
                    Text(reference.photo == nil ? OnboardingWords.choosePhoto : OnboardingWords.change)
                }
                .menuStyle(.button)
                .buttonStyle(.quietPill(size: .compact))
                .disabled(reference.saving)
                .accessibilityIdentifier("choosePhoto")
            } else {
                Button(reference.photo == nil ? OnboardingWords.choosePhoto : OnboardingWords.change) { picking = true }
                    .buttonStyle(.quietPill(size: .compact))
                    .disabled(reference.saving)
                    .accessibilityIdentifier("choosePhoto")
            }
            if reference.photo != nil {
                Button(OnboardingWords.remove) { Task { await reference.remove() } }
                    .buttonStyle(WelcomeLinkStyle(size: 13, color: Palette.ink3))
                    .padding(.horizontal, 10)
                    .disabled(reference.saving)
                    .accessibilityIdentifier("removePhoto")
            }
        }
        .fixedSize()
    }

    /// Saving, saved, or a photo kept before.
    private var state: AnyView? {
        switch reference.photo?.state {
        case .saving:
            return AnyView(Text(OnboardingWords.referenceSaving).font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink3))
        case .saved:
            return AnyView(Label(OnboardingWords.referenceSaved, systemImage: "checkmark")
                .font(.app(size: 12, relativeTo: .caption))
                .foregroundStyle(Palette.accentText)
                .accessibilityIdentifier("referenceSaved"))
        case .failed:
            return nil
        case nil:
            guard reference.earlier > 0 else { return nil }
            return AnyView(Text(OnboardingWords.referenceEarlier)
                .font(.app(size: 12, relativeTo: .caption))
                .foregroundStyle(Palette.ink3)
                .fixedSize(horizontal: false, vertical: true))
        }
    }

    /// What happens next on this server (portraitNext), then the privacy line.
    private var after: String {
        let next = OnboardingFlow.portraitNext(dashboard.availability.ai.value, hasPhoto: hasPhoto)
        return (next.map { "\($0) " } ?? "") + OnboardingWords.referenceAfter
    }
}
