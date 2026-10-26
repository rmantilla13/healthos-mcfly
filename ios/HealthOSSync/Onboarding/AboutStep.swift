import SwiftUI

/// Step 2, "The context behind your numbers." (Onboarding.tsx AboutStep): how you describe yourself, your age (needed
/// to go on), and a card that says what Home and Body will show for the view chosen on step 1.
struct AboutStep: View {
    @Bindable var model: OnboardingModel
    let photo: PhotoMeta?
    @FocusState private var ageFocused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The age field grows with its digits.
    @ScaledMetric(relativeTo: .title) private var ageWidth: CGFloat = 120

    var body: some View {
        let answers = model.answers
        let variant = OnboardingFlow.figureOf(answers)
        // The title names the figure drawn: the man's until the woman's artwork is there, whichever is chosen.
        let card = OnboardingFlow.preview(answers, hasPhoto: photo != nil, drawn: variant.drawn)
        VStack(alignment: .leading, spacing: 0) {
            Text(OnboardingWords.genderQuestion)
                .font(.app(size: 14, relativeTo: .subheadline))
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            WrapLayout(spacing: 10) {
                ForEach(Gender.allCases) { gender in
                    // A choice, not a switch: tapping the one chosen keeps it.
                    GenderChip(title: gender.label, isOn: model.answers.gender == gender) { model.answers.gender = gender }
                        .accessibilityIdentifier("gender.\(gender.rawValue)")
                }
            }
            .padding(.top, 16)
            WelcomeNote(OnboardingWords.genderNote).padding(.top, 14)

            VStack(alignment: .leading, spacing: 18) {
                age
                preview(card, variant: variant)
            }
            .padding(.top, 26)
            WelcomeNote(OnboardingWords.ageNote).padding(.top, 14)
        }
        .padding(.top, 28)
        .onChange(of: model.focusAge, initial: true) { _, now in
            guard now else { return }
            model.focusAge = false
            // Once the step is on screen, so the field can take it.
            Task { @MainActor in ageFocused = true }
        }
    }

    private var age: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
        return VStack(alignment: .leading, spacing: 12) {
            Text(OnboardingWords.ageLabel)
                .font(.app(size: 12, relativeTo: .footnote))
                .foregroundStyle(Palette.ink2)
                .accessibilityHidden(true)
            HStack(spacing: 14) {
                TextField(OnboardingWords.ageLabel, text: Binding(get: { model.answers.age }, set: { model.setAge($0) }), prompt: Text(""))
                    .keyboardType(.numberPad)
                    .autocorrectionDisabled()
                    .focused($ageFocused)
                    .font(.app(size: 28, relativeTo: .title))
                    .foregroundStyle(Palette.ink)
                    .frame(minHeight: 62)
                    .padding(.horizontal, 16)
                    .frame(width: min(ageWidth, 170))
                    .background((reduceTransparency ? Palette.surface : WelcomeLook.field.color).clipShape(shape))
                    .overlay(shape.strokeBorder(model.ageError ? Palette.critical : WelcomeLook.fieldBorder.color))
                    .overlay {
                        if ageFocused { RoundedRectangle(cornerRadius: Radius.field + 3, style: .continuous).strokeBorder(Palette.focus, lineWidth: 2).padding(-3) }
                    }
                    .accessibilityValue(model.answers.age.isEmpty ? "" : "\(model.answers.age) years")
                    .accessibilityHint(model.ageError ? OnboardingWords.ageError : "Required")
                    .accessibilityIdentifier("age")
                Text(OnboardingWords.ageUnit)
                    .font(.app(size: 13, relativeTo: .footnote))
                    .foregroundStyle(Palette.ink3)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
            if model.ageError {
                Text(OnboardingWords.ageError)
                    .font(.app(size: 12, relativeTo: .footnote))
                    .foregroundStyle(Palette.critical)
                    .accessibilityIdentifier("ageError")
            }
        }
    }

    private func preview(_ card: (eyebrow: String, title: String, text: String), variant: FigureVariant) -> some View {
        let answers = model.answers
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        // At the accessibility text sizes the figure goes over the words, so they keep the card's width.
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14)) : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
        return layout {
            Group {
                if answers.perspective == .stats {
                    StatsArt(barWidth: 15, gap: 7, height: 72)
                } else if answers.perspective == .portrait, let photo {
                    CutoutPreview(photo: photo)
                } else {
                    HumanArt(variant: variant).frame(height: 96)
                }
            }
            .frame(width: 92, height: 96)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Eyebrow(card.eyebrow, size: 10)
                    Text(card.title)
                        .font(.app(size: 16, weight: .medium, relativeTo: .headline))
                        .foregroundStyle(Palette.ink)
                        .padding(.top, 10)
                    Text(card.text)
                        .font(.app(size: 12, relativeTo: .footnote))
                        .lineSpacing(2)
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("previewCard")
                if OnboardingFlow.choosesFigure(answers.gender), answers.perspective != .stats, !(answers.perspective == .portrait && photo != nil) {
                    FigurePick(value: variant) { model.answers.figure = $0 }.padding(.top, 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(minHeight: 136)
        .background { GradientLayers(layers: WelcomeLook.peach).clipShape(shape) }
        .overlay(shape.strokeBorder(Palette.cardEdge))
    }
}

/// One answer to "How do you describe yourself?" (.onb .onb-chip): 13pt words, 22pt either side, at least 44pt tall,
/// a soft field with a hairline edge, sage edge and pale green fill once chosen. Smaller than the shared ChipToggle, as
/// the web's welcome draws its chips; the field is solid under Reduce Transparency.
private struct GenderChip: View {
    let title: String
    let isOn: Bool
    let choose: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
        Button(action: choose) {
            Text(title)
                .font(.app(size: WelcomeLook.chipFont, relativeTo: .footnote))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, WelcomeLook.chipPadding)
                // Only shows at the largest text sizes, where a chip's words wrap: they keep off its edges.
                .padding(.vertical, 6)
                .frame(minHeight: WelcomeLook.chipHeight)
                .background(isOn ? WelcomeLook.chipOn.color : reduceTransparency ? Palette.surface : WelcomeLook.field.color, in: shape)
                .overlay(shape.strokeBorder(isOn ? Palette.choiceBorder : WelcomeLook.fieldBorder.color))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isOn) { _, now in now }
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// For Non-binary and Prefer not to say: which digital human to show (Settings.figure).
private struct FigurePick: View {
    let value: FigureVariant
    let pick: (FigureVariant) -> Void

    var body: some View {
        WrapLayout(spacing: 6) {
            Text(OnboardingWords.showMeAs).foregroundStyle(Palette.ink3).accessibilityHidden(true)
            option(.woman, "Woman")
            Text("·").foregroundStyle(Palette.ink3).accessibilityHidden(true)
            option(.man, "Man")
        }
        .font(.app(size: 12, relativeTo: .footnote))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(OnboardingWords.showMeAs)
    }

    private func option(_ figure: FigureVariant, _ label: String) -> some View {
        let on = value == figure
        return Button { pick(figure) } label: {
            Text(label)
                .fontWeight(on ? .medium : .regular)
                .foregroundStyle(on ? Palette.ink : Palette.ink2)
                .underline(on, color: Palette.choiceBorder)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: on) { _, now in now }
        .accessibilityLabel("Show me as \(label)")
        .accessibilityAddTraits(on ? [.isSelected] : [])
        .accessibilityIdentifier("figure.\(figure.rawValue)")
    }
}

/// The profile photo's cut-out, as the web's preview shows it (/api/profile/cutout.png, its own colours). Held in
/// memory for this card only.
private struct CutoutPreview: View {
    let photo: PhotoMeta
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
        }
        .task(id: photo.versionKey) {
            guard let client = APIClient.current() else { return }
            image = (try? await client.profileImage("cutout.png", version: photo.versionKey)).flatMap { UIImage(data: $0) }
        }
        .accessibilityHidden(true)
    }
}

/// Lays its views out in rows, wrapping to the next when one is full (the web's flex-wrap).
struct WrapLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + CGFloat(max(0, rows.count - 1)) * (lineSpacing ?? spacing)
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                x += min(size.width, bounds.width) + spacing
            }
            y += row.height + (lineSpacing ?? spacing)
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            let w = min(size.width, width)
            if !row.items.isEmpty, row.width + spacing + w > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.items.isEmpty ? 0 : spacing) + w
            row.height = max(row.height, size.height)
            row.items.append(index)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
