import SwiftUI

/// The welcome (src/pages/Onboarding.tsx), "Make this space yours": a new account's three steps, or the same steps
/// again from Profile's Edit preferences and Body's "Change my representation" (`.edit`). The shell shows it full
/// screen whenever `dashboard.onboarding` says (Shell/Welcome.swift): for a new account, after any sign-in, until it's
/// done; it goes with a sign-out.
///
/// Each step forward saves the steps it leaves (OnboardingModel), so a relaunch resumes at the step reached. A new
/// account finishes by saving `onboarding: null` and lands on Home; an edit never sends `onboarding`, and goes back to
/// Profile (`dashboard.closeWelcome()`). As on the web, a new account's only ways past it are finishing and Sign out.
struct OnboardingView: View {
    let mode: OnboardingMode
    @Environment(Dashboard.self) private var dashboard
    @State private var model: OnboardingModel?
    @State private var reference: ReferencePhoto?

    var body: some View {
        // A navigation stack, hidden, for the keyboard's Done (the age field's number pad has no return key).
        NavigationStack {
            Group {
                if let model, let reference {
                    OnboardingSteps(model: model, reference: reference)
                } else {
                    Palette.page.ignoresSafeArea()
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .onAppear {
            guard model == nil else { return }
            let dashboard = dashboard
            let mode = mode
            model = OnboardingModel(mode: mode, settings: dashboard.status?.settings, save: { body, finishing in
                // The last save reads the dashboard again (the web's reload and notifyDataChanged).
                try await dashboard.save(settings: body, reload: finishing)
            }, finish: {
                if mode == .edit { dashboard.closeWelcome() } else { dashboard.open(.home) }
            })
            reference = ReferencePhoto(add: { try await dashboard.addReference($0) },
                                       delete: { try await dashboard.deletePortrait(id: $0) },
                                       list: { try await dashboard.portraits() })
        }
        // Signed out (Sign out, or a session that ended): the photo on its way stops, and nothing of it stays.
        .onDisappear {
            if dashboard.phase != .ready { reference?.forget() }
        }
        .onChange(of: dashboard.phase) { _, phase in
            if phase != .ready { reference?.forget() }
        }
        .font(.app(.body))
        .tint(Palette.tint)
        .toggleStyle(.appSwitch)
    }
}

/// The card: step tabs, the step's heading, the step, and Back, the helper line and the main button.
private struct OnboardingSteps: View {
    @Bindable var model: OnboardingModel
    let reference: ReferencePhoto
    @Environment(Dashboard.self) private var dashboard
    @AccessibilityFocusState private var headingFocused: Bool
    /// Goes up for each new step that starts at the top.
    @State private var toTop = 0

    var body: some View {
        WelcomeFrame(spacing: 30, scrollTop: toTop) {
            if model.mode == .edit {
                Button(OnboardingWords.backToProfile) { dashboard.closeWelcome() }
                    .buttonStyle(.welcomeTopLink)
                    .accessibilityIdentifier("backToProfile")
            } else if dashboard.signOutOffered {
                Button(OnboardingWords.signOut) { Task { await dashboard.signOut() } }
                    .buttonStyle(.welcomeTopLink)
                    .accessibilityIdentifier("welcomeSignOut")
            }
        } content: {
            WelcomeCard(narrow: false) {
                StepTabs(step: model.step, furthest: model.furthest, busy: model.busy) { target in
                    Task { await model.go(target) }
                }
                WelcomeHead(eyebrow: OnboardingWords.eyebrow, title: model.step.title, lede: model.step.lede, lede14: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($headingFocused)
                    .padding(.top, 30)
                    .accessibilityIdentifier("stepTitle")
                switch model.step {
                case .perspective: PerspectiveStep(model: model, reference: reference, hasPhoto: dashboard.status?.photo != nil)
                case .about: AboutStep(model: model, photo: dashboard.status?.photo)
                case .community: CommunityStep(model: model)
                }
                if let error = model.error {
                    ErrorNote(error).padding(.top, 18).accessibilityIdentifier("stepError")
                }
                WelcomeFoot(top: 22) {
                    WrapLayout(spacing: 18, lineSpacing: 2) {
                        back
                        Text(model.step.hint)
                            .font(.app(size: 12, relativeTo: .footnote))
                            .foregroundStyle(Palette.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 6)
                    }
                } main: {
                    Button { Task { await model.next() } } label: {
                        WelcomeButtonLabel(model.busy ? OnboardingWords.saving : model.nextTitle,
                                           arrow: !model.busy && !(model.step == .community && model.mode == .edit))
                    }
                    .buttonStyle(.accentPill)
                    .disabled(model.busy)
                    .accessibilityIdentifier("stepNext")
                }
            }
            // A new step starts at the top, and VoiceOver moves to its heading. Sent back for the age, the age field
            // takes the focus instead, and the page follows it there.
            .onChange(of: model.step) { _, step in
                guard !(step == .about && model.ageError) else { return }
                toTop += 1
                headingFocused = true
            }
        }
        .keyboardDismissal()
    }

    @ViewBuilder
    private var back: some View {
        if let previous = model.step.previous {
            Button { Task { await model.go(previous) } } label: { BackLabel() }
                .buttonStyle(.welcomeLink)
                .disabled(model.busy)
                .accessibilityIdentifier("stepBack")
        } else if model.mode == .edit {
            Button { dashboard.closeWelcome() } label: { BackLabel() }
                .buttonStyle(.welcomeLink)
                .accessibilityLabel(OnboardingWords.backToProfile)
                .accessibilityIdentifier("stepBack")
        }
    }
}

/// 01 Your perspective · 02 A little about you · 03 Your community. A step reached opens again; at phone width only the
/// current one keeps its name on screen (VoiceOver reads them all).
private struct StepTabs: View {
    let step: OnboardingStep
    let furthest: OnboardingStep
    let busy: Bool
    let open: (OnboardingStep) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            ForEach(OnboardingStep.allCases) { tab in
                let reached = tab <= furthest
                let current = tab == step
                let opens = reached && !current && !busy
                Button { if opens { open(tab) } } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(tab.numeral)
                            .font(.app(size: 11, relativeTo: .caption2))
                            .overlay(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 1).frame(height: 1.5).offset(y: 7)
                            }
                        if current {
                            Text(tab.label).font(.app(size: 12.5, relativeTo: .footnote)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                    }
                    .foregroundStyle(reached ? Palette.ink : WelcomeLook.stepOff.color)
                    .padding(.bottom, 8)
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .allowsHitTesting(opens)
                .accessibilityRemoveTraits(opens ? [] : .isButton)
                .accessibilityLabel("Step \(tab.rawValue) of 3, \(tab.label)")
                .accessibilityValue(current ? "Current step" : reached ? "" : "Not reached yet")
                .accessibilityAddTraits(current ? [.isSelected] : [])
                .accessibilityIdentifier("stepTab.\(tab.rawValue)")
            }
            Spacer(minLength: 0)
        }
        // The tabs stop growing at the first accessibility size, so the three keep one line; VoiceOver reads each.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Steps")
    }
}
