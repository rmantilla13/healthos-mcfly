import SwiftUI

// The settings Profile opens in sheets that other pages own on the web (FamilySettings in src/pages/Family.tsx,
// CycleSettings in Cycle.tsx, NutritionSettings in Nutrition.tsx), laid flat on the sheet as Profile lays them
// (.profile-sheet). Every change goes through `dashboard.save(settings:)` and shows the status the server answers.

extension APIClient {
    /// POST /api/cycle/delete or /api/nutrition/delete: everything of that kind the server stores for the person.
    /// Answers how many rows went.
    func profileDeleteAll(_ path: String) async throws -> Int {
        struct Reply: Decodable { let deleted: Double? }
        let reply: Reply = try await sendJSON("POST", path)
        return Int(reply.deleted ?? 0)
    }
}

/// What a sheet's switch shows while its change is on its way; the server's setting otherwise.
private struct Pending<Key: Hashable> {
    private var values: [Key: Bool] = [:]
    subscript(_ key: Key) -> Bool? {
        get { values[key] }
        set { values[key] = newValue }
    }
    var any: Bool { !values.isEmpty }
}

// MARK: Family board (G25)

/// "Share with family": mutual, so off you see no one and no one sees you, and the board read before goes at once
/// (Dashboard.apply(status:)). With sharing on, who you share with.
struct ProfileFamilySheet: View {
    let close: () -> Void
    @Environment(Dashboard.self) private var dashboard
    @State private var pending: Bool?
    @State private var error: String?

    var body: some View {
        let sharing = pending ?? dashboard.status?.settings?.familySharing ?? false
        SheetScaffold(eyebrow: "Profile", title: "Family board", onClose: close) {
            ProfileSheetPart("Family", text: ProfileWords.familyTile) {
                ProfileSwitch("Share with family", text: shareText(on: sharing), isOn: Binding(get: { sharing }, set: { set($0) }))
                    .disabled(pending != nil)
                    .accessibilityIdentifier("familySharing")
                if let error { ProfileNote(text: error, good: false) }
            }
        }
        // For "Sharing with: …".
        .task(id: dashboard.status?.settings?.familySharing == true) {
            if dashboard.status?.settings?.familySharing == true { await dashboard.loadFamily() }
        }
    }

    private func shareText(on: Bool) -> String {
        var text = ProfileWords.familyShare
        if on, let board = dashboard.familyBoard, board.sharing {
            let names = board.members.filter { !$0.isYou }.map { m in
                let name = m.name.trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? "Family member" : name
            }
            if let line = ProfileWords.sharingWith(names) { text += " \(line)" }
        }
        return text
    }

    private func set(_ on: Bool) {
        pending = on
        error = nil
        Task {
            do {
                try await dashboard.setFamilySharing(on)
            } catch is CancellationError {
            } catch {
                if dashboard.phase == .ready { self.error = error.localizedDescription }
            }
            pending = nil
        }
    }
}

// MARK: Cycle tracking (G26)

/// The health profile (sex for health calculations), Track my cycle, the phase on your Family tile (with tracking and
/// sharing on), and deleting every cycle entry, after asking. Turning tracking on also has the next sync ask Health for
/// the cycle types (Config.cycleTracking follows the status).
struct ProfileCycleSheet: View {
    let close: () -> Void
    @Environment(Dashboard.self) private var dashboard
    @State private var pending = Pending<String>()
    @State private var sexPending: String?
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var deleted: Int?

    var body: some View {
        let s = dashboard.status?.settings
        let tracking = pending["cycleTracking"] ?? s?.cycleTracking ?? false
        let sex = sexPending ?? s?.sex
        // The web's `family`: signed in, with sharing on.
        let family = dashboard.signOutOffered && s?.familySharing == true
        let busy = pending.any || sexPending != nil
        SheetScaffold(eyebrow: "Profile", title: "Cycle tracking", onClose: close) {
            ProfileSheetPart("Health profile", text: ProfileWords.healthProfile) {
                ProfileField("Sex for health calculations") {
                    ProfileSegments(label: "Sex for health calculations", options: ProfileWords.sexChoices, selection: sex, disabled: busy) { value in
                        saveSex(value)
                    }
                }
                ProfileSwitch("Track my cycle", text: ProfileWords.trackCycle + (sex == "female" && !tracking ? ProfileWords.trackWhenever : ""),
                              isOn: Binding(get: { tracking }, set: { save("cycleTracking", $0) }))
                    .disabled(busy)
                    .accessibilityIdentifier("cycleTracking")
                if tracking, family {
                    ProfileSwitch("Show my cycle phase to family", text: ProfileWords.sharePhase,
                                  isOn: Binding(get: { pending["shareCyclePhase"] ?? s?.shareCyclePhase ?? false }, set: { save("shareCyclePhase", $0) }))
                        .disabled(busy)
                        .accessibilityIdentifier("shareCyclePhase")
                }
                if !tracking { ProfileFine(ProfileWords.cycleOff) }
                if let error { ProfileNote(text: error, good: false) }
            }
            ProfileSheetPart("Delete cycle data", text: ProfileWords.deleteCycle, divided: true) {
                ProfileDeleteLine(title: "Delete all cycle data", id: "deleteCycle", busy: deleting, done: deleted.map(ProfileWords.cycleDeleted)) { confirmDelete = true }
            }
        }
        // The web asks with confirm(): an alert, with its Cancel in view.
        .alert(ProfileWords.deleteCycleAsk, isPresented: $confirmDelete) {
            Button("Delete all cycle data", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ProfileWords.deleteCycleWarning)
        }
    }

    private func saveSex(_ value: String) {
        sexPending = value
        error = nil
        Task {
            do {
                try await dashboard.save(settings: ["sex": value], reload: true)
            } catch is CancellationError {
            } catch {
                if dashboard.phase == .ready { self.error = error.localizedDescription }
            }
            sexPending = nil
        }
    }

    private func save(_ key: String, _ on: Bool) {
        pending[key] = on
        error = nil
        Task {
            do {
                if key == "shareCyclePhase" {
                    try await dashboard.setShareCyclePhase(on)
                } else {
                    // What the pages show changes with it (the Cycle page, Home's cycle line): read again.
                    try await dashboard.save(settings: [key: on], reload: true)
                }
            } catch is CancellationError {
            } catch {
                if dashboard.phase == .ready { self.error = error.localizedDescription }
            }
            pending[key] = nil
        }
    }

    private func delete() async {
        deleting = true
        error = nil
        defer { deleting = false }
        do {
            deleted = try await dashboard.fetch { try await $0.profileDeleteAll("/cycle/delete") }
            // Every page reads again, as the web's notifyDataChanged.
            await dashboard.load()
        } catch is CancellationError {
        } catch {
            if dashboard.phase == .ready { self.error = error.localizedDescription }
        }
    }
}

// MARK: Nutrition (G27)

/// The Nutrition switch (on only after choosing what you see, as the server requires), "What you see" while it's on,
/// your own targets while amounts show, and deleting every food total and entry, after asking. Turned off, the phone
/// stops reading food from Health at its next sync (the ingest reply says it's off).
struct ProfileNutritionSheet: View {
    let close: () -> Void
    @Environment(Dashboard.self) private var dashboard
    @State private var choosing = false
    @State private var busy = false
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var deleted: Int?

    var body: some View {
        let s = dashboard.status?.settings
        let on = s?.nutrition == true
        let numbers = s?.nutritionNumbers
        SheetScaffold(eyebrow: "Profile", title: "Nutrition", onClose: close) {
            ProfileSheetPart {
                // On while choosing too: it turns on once a choice is made.
                ProfileSwitch("Nutrition", text: ProfileWords.nutritionAbout,
                              isOn: Binding(get: { on || choosing }, set: { wanted in
                                  if on { if !wanted { save(["nutrition": false]) } } else { choosing = wanted }
                              }))
                    .disabled(busy)
                    .accessibilityIdentifier("nutritionOn")
                if choosing || on {
                    ProfileField(on ? "What you see" : ProfileWords.chooseFirst) {
                        VStack(spacing: 8) {
                            ForEach(ProfileWords.numbersChoices, id: \.value) { choice in
                                ProfileChoice(title: choice.title, text: choice.text, isOn: on && numbers == choice.value) {
                                    guard !(on && numbers == choice.value) else { return }
                                    save(on ? ["nutritionNumbers": choice.value] : ["nutrition": true, "nutritionNumbers": choice.value])
                                }
                                .disabled(busy)
                                .accessibilityIdentifier("numbers-\(choice.value)")
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("What you see")
                    }
                }
                if on, let numbers, let mode = NutritionMode(rawValue: numbers), mode != .none {
                    ProfileNutritionTargets(mode: mode, busy: busy)
                }
                ProfileFine(!on ? ProfileWords.nutritionOff : dashboard.status?.hosted == true ? ProfileWords.nutritionHosted : ProfileWords.nutritionMac)
                if let error { ProfileNote(text: error, good: false) }
            }
            ProfileSheetPart("Delete nutrition data", text: ProfileWords.deleteNutrition, divided: true) {
                ProfileDeleteLine(title: "Delete all nutrition data", id: "deleteNutrition", busy: deleting, done: deleted.map(ProfileWords.nutritionDeleted)) { confirmDelete = true }
            }
        }
        .keyboardDismissal()
        .alert(ProfileWords.deleteNutritionAsk, isPresented: $confirmDelete) {
            Button("Delete all nutrition data", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ProfileWords.deleteNutritionWarning)
        }
    }

    private func save(_ fields: [String: Any]) {
        busy = true
        error = nil
        Task {
            do {
                // What every page shows of food changes with it: read again.
                try await dashboard.save(settings: fields, reload: true)
            } catch is CancellationError {
            } catch {
                if dashboard.phase == .ready { self.error = error.localizedDescription }
            }
            busy = false
            choosing = false
        }
    }

    private func delete() async {
        deleting = true
        error = nil
        defer { deleting = false }
        do {
            deleted = try await dashboard.fetch { try await $0.profileDeleteAll("/nutrition/delete") }
            await dashboard.load()
        } catch is CancellationError {
        } catch {
            if dashboard.phase == .ready { self.error = error.localizedDescription }
        }
    }
}

/// The person's own targets (the web's TargetInputs), each optional and blank by default; calories only while those
/// show. A target is a plain line on the charts, never a score. Saved when the field is left, as the web's on blur.
/// The server leaves a value outside its range as it was, which would look saved: the phone says so instead.
private struct ProfileNutritionTargets: View {
    let mode: NutritionMode
    let busy: Bool
    @Environment(Dashboard.self) private var dashboard
    /// What's being typed, by key; nil shows the server's value.
    @State private var drafts: [String: String] = [:]
    @State private var error: String?
    @FocusState private var focus: String?

    var body: some View {
        ProfileField(ProfileWords.targetsTitle) {
            VStack(alignment: .leading, spacing: 12) {
                ProfileFine(ProfileWords.targetsNote)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) { fields }
                    VStack(alignment: .leading, spacing: 12) { fields }
                }
                if let error { ProfileNote(text: error, good: false) }
            }
        }
        .onChange(of: focus) { old, _ in
            if let old { commit(old) }
        }
    }

    @ViewBuilder
    private var fields: some View {
        ForEach(NutritionTargetField.all.filter { $0.key != "energy_kcal" || mode == .all }) { f in
            VStack(alignment: .leading, spacing: 4) {
                Text(f.label).font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink3)
                HStack(spacing: 6) {
                    TextField("None", text: Binding(get: { drafts[f.key] ?? current(f.key) }, set: { drafts[f.key] = $0.filter(\.isNumber) }))
                        .keyboardType(.numberPad)
                        .focused($focus, equals: f.key)
                        .disabled(busy)
                        .profileInput()
                        .frame(width: 96)
                        .accessibilityLabel("\(f.label) target in \(f.unit)")
                        .accessibilityIdentifier("target-\(f.key)")
                    Text(f.unit).font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink3)
                }
            }
        }
    }

    private func current(_ key: String) -> String {
        let t = dashboard.status?.settings?.nutritionTargets
        let v = key == "energy_kcal" ? t?.energy_kcal : key == "protein_g" ? t?.protein_g : t?.water_ml
        return v.map { String(Int($0.rounded())) } ?? ""
    }

    private func commit(_ key: String) {
        guard let draft = drafts[key], let field = NutritionTargetField.all.first(where: { $0.key == key }) else { return }
        guard draft != current(key) else { drafts[key] = nil; return }
        let value = draft.isEmpty ? nil : Double(draft)
        if let message = field.problem(value) {
            error = message
            return
        }
        error = nil
        Task {
            do {
                try await dashboard.setNutritionTarget(key, value)
                drafts[key] = nil
            } catch is CancellationError {
            } catch {
                if dashboard.phase == .ready { self.error = "Couldn't save: \(error.localizedDescription)" }
            }
        }
    }
}

/// The targets the server takes, with its ranges (TARGET_RANGE in server/query.ts).
struct NutritionTargetField: Identifiable {
    let key: String
    let label: String
    let unit: String
    let range: ClosedRange<Double>
    var id: String { key }

    static let all = [
        NutritionTargetField(key: "energy_kcal", label: "Calories", unit: "kcal", range: 500...10_000),
        NutritionTargetField(key: "protein_g", label: "Protein", unit: "g", range: 10...500),
        NutritionTargetField(key: "water_ml", label: "Water", unit: "mL", range: 250...8_000),
    ]

    /// Why the server wouldn't keep `value` (nil clears the target, and is always kept).
    func problem(_ value: Double?) -> String? {
        guard let value, !range.contains(value) else { return nil }
        return "\(label): between \(Fmt.number(range.lowerBound)) and \(Fmt.number(range.upperBound)) \(unit), or blank for none."
    }
}

/// A delete button in the critical colour, and how it went beside it ("Deleted 3 entries.").
private struct ProfileDeleteLine: View {
    let title: String
    let id: String
    let busy: Bool
    let done: String?
    let action: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { content }
            VStack(alignment: .leading, spacing: 8) { content }
        }
    }

    @ViewBuilder
    private var content: some View {
        Button(title, role: .destructive, action: action)
            .buttonStyle(ProfilePillStyle(.danger, size: .regular))
            .disabled(busy)
            .accessibilityIdentifier(id)
        if busy {
            ProgressView()
        } else if let done {
            Text(done).font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
        }
    }
}
