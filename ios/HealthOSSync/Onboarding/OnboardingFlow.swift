import Foundation
import Observation

// The rules behind "Make this space yours" (src/pages/onboardingFlow.ts, and the page's go() in Onboarding.tsx), kept
// apart from the views so they can be tested without a screen: where a person starts, what each step saves, what a step
// tab that jumps ahead saves, and what the preview card on step 2 says. OnboardingTests checks them against the web's
// own tests and its file.

/// How Home and Body show you (shared/types.ts Perspective).
enum Perspective: String, CaseIterable, Identifiable {
    case portrait, digital, stats
    var id: String { rawValue }
}

/// How a person describes themselves (shared/types.ts Gender). Never used for health calculations (that's `sex`).
enum Gender: String, CaseIterable, Identifiable {
    case woman, man, nonbinary, unsaid
    var id: String { rawValue }

    /// Step 2's chips (GENDER_CHOICES).
    var label: String {
        switch self {
        case .woman: "Woman"
        case .man: "Man"
        case .nonbinary: "Non-binary"
        case .unsaid: "Prefer not to say"
        }
    }
}

/// One of the three steps (shared/types.ts OnboardingStep).
enum OnboardingStep: Int, CaseIterable, Comparable, Identifiable {
    case perspective = 1, about = 2, community = 3
    var id: Int { rawValue }

    static func < (a: OnboardingStep, b: OnboardingStep) -> Bool { a.rawValue < b.rawValue }

    /// The tab's words and the step's heading, lede and helper line (STEPS in Onboarding.tsx).
    var label: String {
        switch self {
        case .perspective: "Your perspective"
        case .about: "A little about you"
        case .community: "Your community"
        }
    }

    var title: String {
        switch self {
        case .perspective: "How would you like to see yourself?"
        case .about: "The context behind your numbers."
        case .community: "Your progress, in perspective."
        }
    }

    var lede: String {
        switch self {
        case .perspective: "Choose a view for your Home and Body pages. You can change it anytime."
        case .about: "A few details help make your workspace more personal."
        case .community: "See where your readings sit among people your age. Participation is optional."
        }
    }

    var hint: String {
        switch self {
        case .perspective: "Your image is the default. Your choice is always yours."
        case .about: "Just a little context."
        case .community: "Your preferences can be changed anytime."
        }
    }

    /// "01", "02", "03".
    var numeral: String { String(format: "%02d", rawValue) }

    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
}

/// Everything the three steps ask, held while the person moves between them (Answers).
struct OnboardingAnswers: Equatable {
    var perspective: Perspective = .portrait
    var gender: Gender?
    var figure: FigureVariant?
    /// As typed: digits only, up to three.
    var age = ""
    var peer = false
}

enum OnboardingFlow {
    /// A new account resumes at the step it reached (a relaunch keeps its place); editing always starts at the first.
    static func startStep(onboarding: Int?, mode: OnboardingMode) -> OnboardingStep {
        if mode == .edit { return .perspective }
        let step = onboarding ?? 1
        return step == 2 || step == 3 ? OnboardingStep(rawValue: step)! : .perspective
    }

    /// What the steps show first: the person's settings as they are (a new account has the server's defaults), and the
    /// defaults for anything an older server doesn't send.
    static func answers(from s: ServerStatus.Settings?) -> OnboardingAnswers {
        OnboardingAnswers(perspective: s?.perspective.flatMap(Perspective.init(rawValue:)) ?? .portrait,
                          gender: s?.gender.flatMap(Gender.init(rawValue:)),
                          figure: s?.figure.flatMap(FigureVariant.init(rawValue:)),
                          age: s?.age.map(String.init) ?? "",
                          peer: s?.peerComparison == true)
    }

    /// The age as typed, when it's a whole number of years the server takes (1–120); otherwise nil. ASCII digits only,
    /// as the web's \d.
    static func parseAge(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard (1...3).contains(t.count), t.allSatisfy({ ("0"..."9").contains($0) }), let n = Int(t) else { return nil }
        return (1...120).contains(n) ? n : nil
    }

    /// What the age field keeps of what's typed or pasted: its ASCII digits, three at most.
    static func ageInput(_ text: String) -> String {
        String(text.filter { ("0"..."9").contains($0) }.prefix(3))
    }

    static func canJoinPeers(_ age: Int?) -> Bool { (age ?? 0) >= Peers.minAge }

    /// Woman and Man show their own digital human; anyone else picks one (the man until they do).
    static func choosesFigure(_ g: Gender?) -> Bool { g == .nonbinary || g == .unsaid }

    static func figureOf(gender: Gender?, figure: FigureVariant?) -> FigureVariant {
        switch gender {
        case .woman: .woman
        case .man: .man
        default: figure ?? .man
        }
    }

    static func figureOf(_ a: OnboardingAnswers) -> FigureVariant { figureOf(gender: a.gender, figure: a.figure) }

    /// PUT /api/settings for leaving a step forward: that step's answers and, for a new account, the step it moves on
    /// to (null finishes). Editing from Profile never touches the onboarding marker. A JSON null is `NSNull()`.
    static func stepSave(_ step: OnboardingStep, _ a: OnboardingAnswers, mode: OnboardingMode, to: OnboardingStep?) -> [String: Any] {
        var body: [String: Any] = [:]
        switch step {
        case .perspective:
            body["perspective"] = a.perspective.rawValue
        case .about:
            // Woman and Man follow their gender, so a figure picked for another answer earlier doesn't stick. No
            // answer leaves both as they are.
            if let gender = a.gender {
                body["gender"] = gender.rawValue
                body["figure"] = choosesFigure(gender) ? a.figure.map { $0.rawValue as Any } ?? NSNull() : NSNull()
            }
            // The page asks for a valid age before leaving step 2; an unreadable one is never sent as a null (which
            // deletes).
            if let age = parseAge(a.age) { body["age"] = age }
        case .community:
            // Only ever on with an adult age: someone who went back and changed it never sends a switch the server
            // refuses.
            body["peerComparison"] = a.peer && canJoinPeers(parseAge(a.age))
        }
        if mode == .new { body["onboarding"] = to.map { $0.rawValue as Any } ?? NSNull() }
        return body
    }

    /// The steps a move forward leaves behind: from the one open up to the one it opens (all of them, to finish).
    static func stepsLeft(from: OnboardingStep, to: OnboardingStep?) -> [OnboardingStep] {
        let end = to?.rawValue ?? 4
        return (from.rawValue..<max(from.rawValue, end)).compactMap(OnboardingStep.init(rawValue:))
    }

    /// The one PUT for moving forward, by Continue or a step tab: every step left behind, merged. A tab can jump past a
    /// step whose answers were changed and not saved (Back saves nothing), and they'd be lost, or a stale age would
    /// switch peer comparisons off. The page checks the age first whenever step 2 is among them.
    static func forwardSave(from: OnboardingStep, _ a: OnboardingAnswers, mode: OnboardingMode, to: OnboardingStep?) -> [String: Any] {
        stepsLeft(from: from, to: to).reduce(into: [:]) { body, step in
            body.merge(stepSave(step, a, mode: mode, to: to)) { _, new in new }
        }
    }

    /// Step 2's preview card: what Home and Body will show, for the view chosen on step 1. `drawn` is the digital human
    /// the app can actually draw (FigureVariant.drawn): the man's, while the woman's artwork isn't there.
    static func preview(_ a: OnboardingAnswers, hasPhoto: Bool, drawn: FigureVariant) -> (eyebrow: String, title: String, text: String) {
        let human = "Digital \(drawn.rawValue)"
        switch a.perspective {
        case .digital: return ("Your digital human", human, "A Vitruvian-inspired view for your Home and Body pages.")
        case .stats: return ("Your view", "Just the statistics", "Your Home and Body pages show your measurements, without a figure.")
        case .portrait:
            return hasPhoto
                ? ("Your view", "Your portrait", "Your Home and Body pages show the portrait from your photo.")
                : ("Your view", "Your portrait", "Until your portrait is made, your Home and Body pages show the \(human.lowercased()).")
        }
    }

    /// Step 1's line under the portrait's reference photo, true for this server (GET /api/ai): a portrait is made on the
    /// person's own OpenAI key, on one they can connect, on the server's, or not yet at all. nil until the server has
    /// said, so nothing untrue shows first.
    static func portraitNext(_ ai: AiStatus?, hasPhoto: Bool) -> String? {
        guard let ai else { return nil }
        let studio = "After saving, open the portrait studio in your Profile to generate and review your likeness"
        if ai.keys.contains(where: { $0.provider == "openai" }) { return "\(studio) on your OpenAI key." }
        if ai.byok { return "\(studio) with an OpenAI key (connect your own there)." }
        if ai.portraits { return "\(studio) on this healthOS server's OpenAI key." }
        return "Portraits aren't available on this server yet, so your Home and Body pages show \(hasPhoto ? "your cut-out photo" : "the digital human") meanwhile."
    }
}

/// The welcome's state as the page holds it (Onboarding.tsx): the step open, the furthest reached, the answers, and the
/// one request on its way. `save` is PUT /api/settings (the last one, finishing, reads the dashboard again); `finish`
/// leaves the welcome. Tests pass their own.
@MainActor
@Observable
final class OnboardingModel {
    let mode: OnboardingMode
    private(set) var step: OnboardingStep
    /// The furthest step reached: its tab and every one before it open again. Editing has every answer already.
    private(set) var furthest: OnboardingStep
    var answers: OnboardingAnswers
    private(set) var busy = false
    /// The server's refusal, in its words ("Enter your age in whole years.").
    private(set) var error: String?
    /// Step 2's age is needed and isn't a whole number of years.
    var ageError = false
    /// Sent back to step 2 for its age: the field takes the focus once it's there, not the heading.
    var focusAge = false

    @ObservationIgnored private let save: ([String: Any], _ finishing: Bool) async throws -> Void
    @ObservationIgnored private let finish: () -> Void

    init(mode: OnboardingMode, settings: ServerStatus.Settings?,
         save: @escaping ([String: Any], _ finishing: Bool) async throws -> Void, finish: @escaping () -> Void) {
        self.mode = mode
        let start = OnboardingFlow.startStep(onboarding: settings?.onboarding, mode: mode)
        step = start
        furthest = mode == .edit ? .community : start
        answers = OnboardingFlow.answers(from: settings)
        self.save = save
        self.finish = finish
    }

    /// The main button's words.
    var nextTitle: String {
        if step != .community { return OnboardingWords.continueButton }
        return mode == .edit ? OnboardingWords.savePreferences : OnboardingWords.enterWorkspace
    }

    /// Continue, or finish on the last step.
    func next() async {
        guard !busy else { return }
        await go(step.next)
    }

    /// Back (saves nothing), a step tab, Continue, or finishing (nil). Forward saves every step it leaves behind in one
    /// go, so a tab that jumps past step 2 still saves its answers, and first asks for its age.
    func go(_ target: OnboardingStep?) async {
        error = nil
        if let target, target < step {
            step = target
            return
        }
        if target == step { return }
        if OnboardingFlow.stepsLeft(from: step, to: target).contains(.about), OnboardingFlow.parseAge(answers.age) == nil {
            ageError = true
            focusAge = true
            step = .about
            return
        }
        busy = true
        do {
            try await save(OnboardingFlow.forwardSave(from: step, answers, mode: mode, to: target), target == nil)
        } catch is CancellationError {
            busy = false
            return
        } catch {
            busy = false
            self.error = error.localizedDescription
            return
        }
        guard let target else {
            // A new account lands on Home; editing goes back to Profile. Busy stays on until the welcome has gone.
            finish()
            return
        }
        busy = false
        step = target
        if target > furthest { furthest = target }
    }

    /// The age as typed: under 18, taking part is off, so the box on the next step starts empty if the age goes back up.
    func setAge(_ text: String) {
        let age = OnboardingFlow.ageInput(text)
        let n = OnboardingFlow.parseAge(age)
        if n != nil { ageError = false }
        answers.age = age
        if let n, n < Peers.minAge { answers.peer = false }
    }
}
