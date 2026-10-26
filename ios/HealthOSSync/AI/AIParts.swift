import SwiftUI

// What the two key sheets share (src/components/ai/AiSheets.tsx and src/styles/ai.css): the status they read and
// write, and the pieces drawn alike in both. Built on the theme's tokens only, so dark mode follows them.

/// A line under a sheet's form: what went through, or what went wrong (note-good / note-bad).
struct AINote: Equatable {
    let ok: Bool
    let text: String
}

/// One key sheet's AiStatus and its requests. The sheet reads GET /api/ai when it opens, as the web's does, and each
/// write answers with the status it shows next. Memory only: it goes with the sheet. Nothing here ever holds a key.
@MainActor
@Observable
final class AIKeysModel {
    var status: AiStatus?
    /// The server is older than own keys (GET /api/ai answered 404).
    var missing = false
    var loadError: String?
    var busy = false
    var note: AINote?

    /// GET /api/ai, fresh each time a sheet opens. Signed out, nothing is read.
    func load(_ dashboard: Dashboard) async {
        guard dashboard.phase == .ready else { return }
        #if targetEnvironment(simulator)
        switch UserDefaults.standard.string(forKey: "aiPreview") {
        case "older":
            missing = true
            return
        case let state?:
            if let preview = Self.preview(state) {
                status = preview
                return
            }
        case nil: break
        }
        #endif
        let who = dashboard.personID
        do {
            let s = try await dashboard.fetch { try await $0.aiStatus() }
            guard dashboard.phase == .ready, dashboard.personID == who else { return }
            if let s {
                status = s
                dashboard.availability.heard(ai: s)
            } else {
                missing = true
            }
        } catch {
            if APIClient.isCancellation(error) { return }
            loadError = error.aiMessage
        }
    }

    /// One save or removal: the status it answers with, and `done` once it went through; the server's words if not.
    /// The rest of the app hears the new status, and what it changed (Ask McFly's provider, what reads a meal) is read
    /// again, as the web's notifyDataChanged does.
    @discardableResult
    func run(_ dashboard: Dashboard, done: String, _ work: (APIClient) async throws -> AiStatus) async -> Bool {
        guard !busy, dashboard.phase == .ready else { return false }
        let who = dashboard.personID
        busy = true
        note = nil
        defer { busy = false }
        do {
            let s = try await dashboard.fetch(work)
            // Signed out, or someone else signed in, while it was on its way: nothing of it lands.
            guard dashboard.phase == .ready, dashboard.personID == who else { return false }
            status = s
            note = AINote(ok: true, text: done)
            dashboard.availability.heard(ai: s)
            dashboard.mcfly.attach(to: dashboard)
            Task {
                await dashboard.mcfly.refreshStatus()
                await dashboard.refreshIfChanged(includeStatus: false)
            }
            return true
        } catch {
            note = AINote(ok: false, text: APIClient.isCancellation(error) ? "Something went wrong. Try again in a moment." : error.aiMessage)
            return false
        }
    }
}

#if targetEnvironment(simulator)
extension AIKeysModel {
    /// Scripted runs in the Simulator only, for screenshots of states a local server can't reach with made-up keys:
    /// `-aiPreview keys` (an OpenAI key in use and a Claude key that needs attention, made up), `-aiPreview shared`
    /// (keys can't be stored; the shared Claude answers), `-aiPreview older` (a server without own keys). Writes still
    /// go to the server. Never in a device build.
    static func preview(_ state: String) -> AiStatus? {
        switch state {
        case "keys":
            return AiStatus(byok: true, shared: true,
                            keys: [AiStatus.Key(provider: "openai", last4: "Q7xa", model: nil, addedAt: 1, lastUsedAt: 2, lastError: nil),
                                   AiStatus.Key(provider: "anthropic", last4: "9fKe", model: "claude-sonnet-4-5", addedAt: 1, lastUsedAt: nil, lastError: "auth")],
                            chat: AiStatus.Use(provider: "openai", source: "own", model: "gpt-5.1"), chatChoice: "openai",
                            estimate: AiStatus.Use(provider: "openai", source: "own"), voice: true, portraits: true)
        case "shared":
            return AiStatus(byok: false, shared: true, chat: AiStatus.Use(provider: "anthropic", source: "shared", model: "claude-sonnet-4-5"),
                            estimate: AiStatus.Use(provider: "anthropic", source: "shared"))
        default:
            return nil
        }
    }
}
#endif

extension Dashboard {
    /// Who the server says is signed in, to tell a reply that lands after someone else signed in from one that didn't.
    var personID: String? { status?.user?.id ?? account?.id }
}

/// What Ask McFly uses right now: the orb, then the words and the model in small type (.ai-using).
struct AIStatusLine: View {
    let status: AiStatus

    var body: some View {
        HStack(spacing: 12) {
            Orb(size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(AIWords.using(status))
                    .font(.app(size: 14, weight: .medium, relativeTo: .subheadline))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if status.chat != nil, let model = status.chat?.model, !model.isEmpty {
                    Text(model).font(.app(size: 12, relativeTo: .caption)).foregroundStyle(Palette.ink3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
        .tokenShadow(.pill, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// This server can't store keys: what happens instead (.ai-not-here).
struct AINotHere: View {
    var detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.shield")
                .font(.app(size: 17, relativeTo: .body))
                .foregroundStyle(Palette.accentText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(AIWords.notHere).font(.app(size: 13.5, weight: .medium, relativeTo: .subheadline)).foregroundStyle(Palette.ink)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.app(size: 13.5, relativeTo: .subheadline)).foregroundStyle(Palette.ink3)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A field's label above it (.ai-field span).
private struct FieldLabel: View {
    let text: String
    var optional = false

    var body: some View {
        (Text(text).foregroundStyle(Palette.ink2) + Text(optional ? " (optional)" : "").foregroundStyle(Palette.ink3))
            .font(.app(size: 12.5, weight: .medium, relativeTo: .footnote))
    }
}

/// A soft white input (.ai-field input).
private struct FieldBox: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.app(size: 14, relativeTo: .subheadline))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.field, style: .continuous).strokeBorder(Palette.border))
    }
}

/// The masked field a key is pasted into. Never suggested by, or saved to, a password manager or the Keychain; no
/// autocorrection, capitals or spelling, and redacted where the system hides private things.
struct AIKeyField: View {
    let provider: AIProvider
    @Binding var key: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: "Your \(provider.label) API key")
            SecureField("", text: $key, prompt: Text("Paste your key").foregroundStyle(Palette.ink3))
                .textContentType(nil)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .submitLabel(.go)
                .privacySensitive()
                .focused(focused)
                .modifier(FieldBox())
                .accessibilityLabel("Your \(provider.label) API key")
                .accessibilityIdentifier("aiKey")
        }
    }
}

/// The optional model for a provider's key (the server checks it's one of that provider's ids).
struct AIModelField: View {
    @Binding var model: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: "Model", optional: true)
            TextField("", text: $model, prompt: Text("The default model").foregroundStyle(Palette.ink3))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .modifier(FieldBox())
                .onChange(of: model) { _, value in if value.count > 100 { model = String(value.prefix(100)) } }
                .accessibilityLabel("Model, optional")
                .accessibilityIdentifier("aiModel")
        }
    }
}

/// A stored key: its last four characters, what the server last saw of it, and Replace / Remove (.ai-connected).
struct AIConnectedKey: View {
    let info: AiStatus.Key
    let busy: Bool
    let onReplace: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    words
                    Spacer(minLength: 0)
                    actions
                }
                VStack(alignment: .leading, spacing: 10) {
                    words
                    actions
                }
            }
            if info.lastError != nil, let problem = AIWords.problem(info.lastError) {
                Text(problem)
                    .font(.app(size: 12.5, relativeTo: .footnote))
                    .foregroundStyle(ColorToken.badgePeachInk.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 14)
        .padding([.vertical, .trailing], 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.field, style: .continuous).strokeBorder(Palette.border))
    }

    private var words: some View {
        HStack(spacing: 8) {
            if info.lastError != nil {
                Badge("Needs attention", tone: .peach, systemImage: "exclamationmark.triangle")
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(ColorToken.badgeSageInk.color)
                    .frame(width: 20, height: 20)
                    .background(ColorToken.badgeSageBg.color, in: Circle())
                    .accessibilityHidden(true)
            }
            (Text(info.lastError != nil ? "Key ending " : "Connected · key ending ")
                + Text(info.last4).fontWeight(.semibold).monospacedDigit().tracking(0.5))
                .font(.app(size: 13.5, relativeTo: .subheadline))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(info.lastError != nil ? "Key ending \(spelled), needs attention" : "Connected, key ending \(spelled)")
        }
    }

    /// The last four read one character at a time.
    private var spelled: String { info.last4.map(String.init).joined(separator: " ") }

    private var actions: some View {
        HStack(spacing: 6) {
            Button("Replace", action: onReplace).buttonStyle(.quietPill(size: .compact)).accessibilityIdentifier("aiReplace")
            Button("Remove key", action: onRemove).buttonStyle(AITextButtonStyle(color: ColorToken.badgeBadInk.color, size: .compact))
                .accessibilityIdentifier("aiRemove")
        }
        .disabled(busy)
    }
}

/// "Remove your key?" in place of the stored key, on the soft red wash (.ai-confirm). VoiceOver lands on the safe
/// choice, as the web's focus does.
struct AIConfirmRemove: View {
    let text: String
    let provider: AIProvider
    let busy: Bool
    let onRemove: () -> Void
    let onKeep: () -> Void
    @AccessibilityFocusState private var keepFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text)
                .font(.app(size: 13.5, relativeTo: .subheadline))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(busy ? "Removing…" : "Remove key", action: onRemove).buttonStyle(AIDangerPillStyle()).accessibilityIdentifier("aiRemoveConfirm")
                Button("Keep it", action: onKeep)
                    .accessibilityIdentifier("aiKeep")
                    .buttonStyle(AITextButtonStyle())
                    .accessibilityFocused($keepFocused)
            }
            .disabled(busy)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ColorToken.badgeBadBg.color, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Remove your \(provider.label) key")
        .onAppear { keepFocused = true }
    }
}

/// Where questions and photos go (.ai-where): the shield, then the lines.
struct AIWherePanel<Lines: View>: View {
    @ViewBuilder var lines: Lines

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield")
                .font(.app(size: 15, relativeTo: .footnote))
                .foregroundStyle(Palette.accentText)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) { lines }
                .font(.app(size: 12.5, relativeTo: .footnote))
                .lineSpacing(3)
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
    }
}

/// What went through or what went wrong (.ai-feedback), read out by VoiceOver as it changes.
struct AIFeedback: View {
    let note: AINote?

    var body: some View {
        if let note {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: note.ok ? "checkmark" : "exclamationmark.triangle").accessibilityHidden(true)
                Text(note.text).fixedSize(horizontal: false, vertical: true)
            }
            .font(.app(size: 13, relativeTo: .footnote))
            .foregroundStyle(note.ok ? Palette.goodText : Palette.critical)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("aiFeedback")
        }
    }
}

/// Loading, or why it couldn't load.
struct AILoading: View {
    let error: String?

    var body: some View {
        if let error {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
                Text(error).fixedSize(horizontal: false, vertical: true)
            }
            .font(.app(size: 13, relativeTo: .footnote))
            .foregroundStyle(Palette.critical)
        } else {
            Text("Loading…").font(.app(.subheadline)).foregroundStyle(Palette.ink3)
        }
    }
}

/// A sheet's two buttons, the quiet one then the main one, side by side; at the accessibility text sizes the main one
/// goes first, above, so neither is cut short.
struct AIFooterButtons<Quiet: View, Primary: View>: View {
    @ViewBuilder var quiet: Quiet
    @ViewBuilder var primary: Primary
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .trailing, spacing: 8) {
                primary
                quiet
            }
        } else {
            HStack(spacing: 10) {
                quiet
                primary
            }
        }
    }
}

/// The web's quiet button (.btn-quiet): words only, no pill, in the muted ink, or a colour of its own (Remove key's
/// red). Close, Cancel, Keep it.
struct AITextButtonStyle: ButtonStyle {
    var color: Color = Palette.ink3
    var size: PillSize = .regular
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size.font)
            .foregroundStyle(configuration.isPressed && color == Palette.ink3 ? Palette.ink : color)
            .lineLimit(1)
            .padding(.horizontal, size.padding - 4)
            .frame(minHeight: size.height)
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.5)
    }
}

/// Remove key's own pill (.ai-danger): the red words on a white pill.
struct AIDangerPillStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PillSize.regular.font)
            .foregroundStyle(ColorToken.badgeBadInk.color)
            .lineLimit(1)
            .padding(.horizontal, 18)
            .frame(minHeight: 40)
            .background(Palette.surface, in: Capsule())
            .tokenShadow(.pill, in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
    }
}
