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
                // Only on the signed-in person's own status: one read before they signed in (a save of the last
                // person's that landed after their Sign out) shows nothing until theirs comes.
                if let model, let reference, statusIsTheirs {
                    OnboardingSteps(model: model, reference: reference)
                } else {
                    Palette.page.ignoresSafeArea()
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        // Built from the person's settings, and again if the status turns out to be someone else's than the one it was
        // built from: never one person's answers on another's welcome, to be saved to their account.
        .onChange(of: person, initial: true) { before, now in
            if model == nil || OnboardingFlow.personChanged(from: before, to: now) { build() }
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

    /// Whose status the welcome reads (nil from servers that don't say).
    private var person: String? { dashboard.status?.user?.id }

    private var statusIsTheirs: Bool { OnboardingFlow.statusIsTheirs(statusUser: person, signedIn: dashboard.account?.id) }

    private func build() {
        reference?.forget()
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
}

/// The card: step tabs, the step's heading, the step, and Back, the helper line and the main button. The model and the
/// reference photo are OnboardingView's, above the frame, and the frame is never rebuilt by a fold (P4, P14). Tests draw
/// it on its own, without OnboardingView's navigation stack.
struct OnboardingSteps: View {
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
                // Not while a step saves: its answer, landing after the sign-out, would put this person's settings
                // back in memory behind the sign-in screen.
                Button(OnboardingWords.signOut) { Task { await dashboard.signOut() } }
                    .buttonStyle(.welcomeTopLink)
                    .disabled(model.busy)
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
            // A new step starts at the top (as the web scrolls to it on every step), and VoiceOver moves to its heading.
            // Sent back for the age by this very move, the age field takes the focus instead (AboutStep), and the
            // page follows it there; an age error left from before doesn't count.
            .onChange(of: model.step) { _, _ in
                toTop += 1
                if !model.takeSentForAge() { headingFocused = true }
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
/// current one keeps its name on screen (VoiceOver reads them all). Wider (the open Duo upright, the medium band: the
/// web above 560), every step keeps its name, 30pt apart, as long as the three fit on one line.
private struct StepTabs: View {
    let step: OnboardingStep
    let furthest: OnboardingStep
    let busy: Bool
    let open: (OnboardingStep) -> Void
    @Environment(\.duoBand) private var band

    var body: some View {
        Group {
            if band >= .medium {
                ViewThatFits(in: .horizontal) {
                    tabs(named: true)
                    tabs(named: false)
                }
            } else {
                tabs(named: false)
            }
        }
    }

    /// The row; `named`: every step's name shows, not only the current one's.
    private func tabs(named: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: named ? 30 : 18) {
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
                        if current || named {
                            Text(tab.label)
                                .font(.app(size: 12.5, relativeTo: .footnote))
                                .lineLimit(1)
                                .minimumScaleFactor(named ? 1 : 0.8)
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
