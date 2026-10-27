import SwiftUI

/// Units & daily goal (G23, the web's BasicsSheet): name, daily step goal and units. Units save the moment they're
/// chosen and flash "✓ Saved"; name and goal save as the sheet closes (Done or ×), only if they changed, and the page
/// reads the day again. While they're unsaved the sheet doesn't swipe away, so closing always saves. A refusal keeps
/// the sheet open with the server's words. The server ignores a goal outside 500 to 100,000 without saying, so the
/// phone says it instead.
struct ProfileBasicsSheet: View {
    let close: () -> Void
    @Environment(Dashboard.self) private var dashboard
    @State private var name: String
    @State private var goal: String
    @FocusState private var goalFocused: Bool
    @State private var saved = false
    @State private var flash: Task<Void, Never>?
    @State private var busy = false
    @State private var error: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(settings: ServerStatus.Settings?, close: @escaping () -> Void) {
        self.close = close
        _name = State(initialValue: settings?.name ?? "")
        _goal = State(initialValue: settings?.stepGoal.map { String(Int($0.rounded())) } ?? "")
    }

    var body: some View {
        let settings = dashboard.status?.settings
        let patch = Self.patch(name: name, goal: goal, settings: settings)
        SheetScaffold(eyebrow: "Profile", title: "Units & daily goal", onClose: { Task { await done() } }) {
            VStack(alignment: .leading, spacing: 16) {
                ProfileField("Name") {
                    TextField("", text: $name)
                        .textContentType(.givenName)
                        .submitLabel(.done)
                        .onSubmit { Task { await done() } }
                        .profileInput()
                        .accessibilityLabel("Name")
                        .accessibilityIdentifier("profileName")
                }
                ProfileField("Daily step goal", hint: ProfileWords.stepGoalHint, hintIsBad: patch.goalOutOfRange) {
                    TextField("", text: $goal)
                        .keyboardType(.numberPad)
                        .focused($goalFocused)
                        .profileInput()
                        .accessibilityLabel("Daily step goal")
                        .accessibilityIdentifier("stepGoal")
                        // No return key on the number pad: on iPhone Duo (iOS 27.1) its Done sits beside the field.
                        .duoFieldDone(goalFocused)
                }
                ProfileField("Units") {
                    ProfileSegments(label: "Units", options: [("metric", ProfileWords.metric), ("imperial", ProfileWords.imperial)],
                                    selection: settings?.units ?? "metric", disabled: busy) { units in
                        Task { await save(units: units) }
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                    Text("Saved")
                }
                .font(.app(size: 12, relativeTo: .caption))
                .foregroundStyle(Palette.ink3)
                .opacity(saved ? 1 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: saved)
                .accessibilityHidden(!saved)
                .padding(.top, -6)
                if let error { ProfileNote(text: error, good: false) }
            }
            // Done over the number pad (the goal has no return key), inside the sheet: from iOS 27.1 the sheet sits in a
            // navigation stack (DuoSheetStack), and a keyboard toolbar from outside it doesn't reach these fields.
            .keyboardDismissal()
        } footer: {
            Button("Done") { Task { await done() } }
                .buttonStyle(.accentPill)
                .disabled(busy)
                .accessibilityIdentifier("basicsDone")
        }
        .interactiveDismissDisabled(patch.changed || busy)
        // The server keeps 40 characters of a name; the field holds no more, as the web's maxLength.
        .onChange(of: name) { _, typed in
            if typed.count > ProfileWords.nameLimit { name = String(typed.prefix(ProfileWords.nameLimit)) }
        }
        .onChange(of: goal) { _, typed in
            let digits = typed.filter(\.isASCIIDigit)
            if digits != typed { goal = digits }
        }
        .onDisappear { flash?.cancel() }
    }

    /// What closing the sheet sends: the name if its trimmed words changed, the goal if it's a new number (the web's
    /// done()). `goalOutOfRange`: one the server would ignore, a number too long to read included.
    struct Patch: Equatable {
        var fields: [String: String] = [:]
        var goal: Int?
        var goalOutOfRange = false
        var changed: Bool { !fields.isEmpty || goal != nil || goalOutOfRange }
    }

    static func patch(name: String, goal: String, settings: ServerStatus.Settings?) -> Patch {
        var patch = Patch()
        if name.trimmingCharacters(in: .whitespacesAndNewlines) != (settings?.name ?? "") { patch.fields["name"] = name }
        if let typed = Int(goal) {
            if Double(typed) != settings?.stepGoal {
                if ProfileWords.stepGoalRange.contains(typed) { patch.goal = typed } else { patch.goalOutOfRange = true }
            }
        } else if !goal.isEmpty {
            // Digits too many for a number: far over 100,000.
            patch.goalOutOfRange = true
        }
        return patch
    }

    private func done() async {
        guard !busy else { return }
        let patch = Self.patch(name: name, goal: goal, settings: dashboard.status?.settings)
        if patch.goalOutOfRange {
            error = "Daily step goal: \(ProfileWords.stepGoalHint.prefix(1).lowercased())\(ProfileWords.stepGoalHint.dropFirst())"
            return
        }
        var fields: [String: Any] = patch.fields
        if let goal = patch.goal { fields["stepGoal"] = goal }
        if !fields.isEmpty {
            busy = true
            defer { busy = false }
            error = nil
            do {
                // A new name or goal changes what the day shows: it's read again.
                try await dashboard.save(settings: fields, reload: true)
            } catch is CancellationError {
                return
            } catch {
                if dashboard.phase == .ready { self.error = error.localizedDescription }
                return
            }
        }
        close()
    }

    private func save(units: String) async {
        error = nil
        busy = true
        defer { busy = false }
        do {
            try await dashboard.save(settings: ["units": units], reload: true)
            saved = true
            flash?.cancel()
            flash = Task {
                try? await Task.sleep(for: .seconds(1.5))
                if !Task.isCancelled { saved = false }
            }
            UIAccessibility.post(notification: .announcement, argument: "Saved")
        } catch is CancellationError {
        } catch {
            if dashboard.phase == .ready { self.error = error.localizedDescription }
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
