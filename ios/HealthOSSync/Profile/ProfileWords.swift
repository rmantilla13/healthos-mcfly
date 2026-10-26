import Foundation

/// Profile's words, as the web writes them (src/pages/Profile.tsx and the settings it borrows from Cycle.tsx,
/// Family.tsx and Nutrition.tsx), in one place so a test can check each against those files. The web's curly
/// apostrophes stay where it has them ("It can’t be undone.").
enum ProfileWords {
    // MARK: Your profile

    /// "Digital man · 33 years": how Home and Body show you (the digital human as drawn), and your age (perspectiveLine).
    static func perspective(_ s: ServerStatus.Settings, drawn: FigureVariant) -> String {
        let look = switch s.perspective {
        case "digital": "Digital \(drawn.rawValue)"
        case "stats": "Just the statistics"
        default: "Your portrait"
        }
        return s.age.map { "\(look) · \($0) years" } ?? "\(look) · no age given"
    }

    static func peers(_ s: ServerStatus.Settings) -> String {
        "\(s.peerComparison == true ? "Peer comparisons enabled." : "Peer comparisons off.") Change your image, age or participation anytime."
    }

    /// The Chatbot row's line; `byok` false says keys can't be stored on this server (unknown says nothing of it).
    static func chatbot(byok: Bool?) -> String {
        byok == false
            ? "Ask McFly can answer on your own OpenAI, Claude or Gemini key, but storing your own AI keys isn't set up on this server."
            : "Choose OpenAI, Claude or Gemini and connect your own API key."
    }

    /// "Ask McFly uses your own Claude key." while the chat answers on the person's own key.
    static func ownChat(_ ai: AiStatus?) -> String? {
        guard let chat = ai?.chat, chat.source == "own" else { return nil }
        return "Ask McFly uses your own \(providerLabel(chat.provider)) key."
    }

    static func openAI(byok: Bool?) -> String {
        byok == false
            ? "For meal photos, descriptions, voice notes and portraits. Storing your own AI keys isn't set up on this server."
            : "Connect your own OpenAI API key for meal photos, descriptions, voice notes and portraits."
    }

    static func openAIConnected(last4: String) -> String { "Connected · key ending ••••\(last4)" }

    /// shared/ai.ts AI_PROVIDERS.
    static let providers: [(provider: String, label: String)] = [("openai", "OpenAI"), ("anthropic", "Claude"), ("gemini", "Gemini")]

    static func providerLabel(_ provider: String) -> String { providers.first { $0.provider == provider }?.label ?? provider }

    /// The Account row: the email, " · admin" for an admin; a server without sign-in ("open") is this Mac's. While
    /// the sign-in mode isn't known (offline at launch, /auth/me not answered yet), the email kept from the last status,
    /// never "no sign-in"; nil when there's nothing known to say.
    static func account(mode: String?, email: String?, role: String?) -> String? {
        if mode == "open" { return "This Mac, no sign-in" }
        guard let email, !email.isEmpty else { return nil }
        return email + (role == "admin" ? " · admin" : "")
    }

    // MARK: Your settings

    static func units(_ s: ServerStatus.Settings) -> String {
        let name = s.name.flatMap { $0.isEmpty ? nil : "\($0) · " } ?? ""
        let units = s.units == "imperial" ? imperial : metric
        return "\(name)\(units) · \(Fmt.number(s.stepGoal ?? 10_000)) steps a day"
    }

    static let metric = "Metric (kg, °C, km)"
    static let imperial = "Imperial (lb, °F, mi)"

    /// The Cards row's line and the Cards sheet's lede start the same way.
    static func cardPages(nutrition: Bool) -> String { "Choose the cards you see on Home, Sleep\(nutrition ? ", Body and Nutrition" : " and Body")." }

    static func family(sharing: Bool) -> String {
        sharing ? "Sharing on. Members who share see your tile and its last 30 days." : "Sharing off. You see no one, and no one sees you."
    }

    static func cycle(_ s: ServerStatus.Settings) -> String {
        let sex = switch s.sex {
        case "female": "female"
        case "male": "male"
        case "unspecified": "prefer not to say"
        default: "not set"
        }
        return "\(s.cycleTracking == true ? "On" : "Off") · Sex for health calculations: \(sex)"
    }

    static func nutrition(_ s: ServerStatus.Settings) -> String {
        guard s.nutrition == true else { return "Off" }
        let seen = switch s.nutritionNumbers {
        case "no_energy": "nutrients without calories"
        case "none": "what you logged, no amounts"
        default: "calories and nutrients"
        }
        return "On · \(seen)"
    }

    // MARK: Units & daily goal

    static let stepGoalHint = "Between 500 and 100,000."
    /// The goal the server keeps: anything else it ignores without saying, so the phone says it first.
    static let stepGoalRange = 500...100_000
    /// The longest name the server keeps (it trims and cuts the rest).
    static let nameLimit = 40

    // MARK: Cards

    static let cardsNote = "Hiding one only changes the page; your data stays."

    // MARK: Family

    static let familyTile = "Your Family board tile: last night's sleep, recovery or HRV, today's steps, resting heart rate and training load, the last 30 days of each, and how they compare with your own usual."
    static let familyShare = "Members who share see your tile and its last 30 days. Turn it off and you see no one, and no one sees you."

    static func sharingWith(_ names: [String]) -> String? { names.isEmpty ? nil : "Sharing with: \(names.joined(separator: ", "))." }

    // MARK: Cycle

    static let healthProfile = "Only you can see this, except a phase you share with family. Admin screens never show it."
    static let sexChoices: [(value: String, title: String)] = [("female", "Female"), ("male", "Male"), ("unspecified", "Prefer not to say")]
    static let trackCycle = "Adds a Cycle page for periods, ovulation tests, symptoms and temperature, with estimates of your next period and fertile window. It reads your Apple Watch or WHOOP nightly temperature to find ovulation. Ask McFly can read it while this is on."
    static let trackWhenever = " Turn it on whenever you like."
    static let sharePhase = "One word on your Family board tile (period, follicular or luteal), never dates or logs. Hidden as your next period approaches. Members will know you track your cycle, and looking day after day shows roughly when your period starts."
    static let cycleOff = "While this is off, cycle data from Apple Health is still saved, hidden from every page and from Ask McFly, so your history is there if you turn it on."
    static let deleteCycle = "Removes every cycle entry healthOS stores for you. Entries from Apple Health come back with your next import or iPhone sync unless you delete them in the Health app or turn off healthOS's access to cycle data in iPhone Settings. Your Watch and WHOOP temperatures stay with your other health data."
    /// The web's confirm(), as an alert's title and message.
    static let deleteCycleAsk = "Delete all your cycle data?"
    static let deleteCycleWarning = "This removes everything cycle-related healthOS stores for you, from Apple Health and logged here. It can’t be undone."

    static func cycleDeleted(_ n: Int) -> String { n > 0 ? "Deleted \(n) \(n == 1 ? "entry" : "entries")." : "There was nothing to delete." }

    // MARK: Nutrition

    static let nutritionAbout = "Log food here, or read what you log in a food app (MyFitnessPal, Cronometer, Lose It!, MacroFactor, Yazio) from Apple Health as daily totals. Only you can see it: never your family, never the admin screens. Ask McFly can read it while this is on, only as much as you choose to see. healthOS never suggests a target."
    /// Nutrition.tsx CHOICES: what the person sees of their nutrition.
    static let numbersChoices: [(value: String, title: String, text: String)] = [
        ("all", "Everything", "Calories, protein, carbs, fat, fiber, sugar, sodium and drinks."),
        ("no_energy", "Everything except calories", "The same, with no calories anywhere, Ask McFly included."),
        ("none", "No amounts", "No calories or nutrient amounts: only what you logged, and when."),
    ]
    static let chooseFirst = "First, choose what you want to see. You can change it any time."
    static let targetsTitle = "Your targets (optional)"
    static let targetsNote = "Leave blank for none. A target you set shows as a plain line on your charts, nothing more."
    static let nutritionOff = "While this is off, healthOS doesn't read or keep your food logs."
    /// The web says "from the healthOS iPhone app (1.1, build 16 or later)": on the iPhone, that's this one.
    static let nutritionHosted = "Your food log comes in from this iPhone at its next sync."
    static let nutritionMac = "History comes in with your next Health export import, or from this iPhone at its next sync."
    static let deleteNutrition = "Removes every food total healthOS stores for you and everything you logged here, whether nutrition is on or off. With nutrition on, your next import or iPhone sync brings back what's still in Apple Health."
    static let deleteNutritionAsk = "Delete all your nutrition data?"
    static let deleteNutritionWarning = "This removes every food total healthOS stores for you and everything you logged here. It can’t be undone."

    static func nutritionDeleted(_ n: Int) -> String { n > 0 ? "Deleted." : "There was nothing to delete." }

    // MARK: Password

    static let passwordMinimum = 10
    static let passwordHint = "At least 10 characters."
    static let passwordsDiffer = "The passwords don't match."
    static let passwordChanged = "Password changed. Other devices are signed out."

    /// The web's PasswordForm `valid`: a current password, a new one of at least 10 characters, typed the same twice.
    static func passwordReady(current: String, next: String, confirm: String) -> Bool {
        !current.isEmpty && next.count >= passwordMinimum && next == confirm
    }

    // MARK: Export

    static let exportLine = "Download your complete meal history, readings, lab results and file metadata."
    static let exportUnreachable = "Couldn't reach healthOS. Check your connection and try again."
    static let exportFailed = "Couldn't prepare your export. Try again in a moment."
    static let exportStopped = "The download stopped before it finished. Try again in a minute."
    /// Not the web's (its own server always has the route): an older server "Change server" points at.
    static let exportNotHere = "This server can't export your data yet. Update healthOS to download it."

    static func exportSaved(_ name: String) -> String { "Saved \(name)." }
}
