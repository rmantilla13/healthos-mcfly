import SwiftUI

/// Profile (src/pages/Profile.tsx, the web's #/profile and #/settings), under More and in the account menu: a "Your
/// profile" card of rows (how you're shown, your AI, account, sources, the export, privacy, signing out), a "Your
/// settings" card whose rows each open a sheet (units and goal, cards, the Family board, cycle tracking, nutrition),
/// then the two cards that open in place, your age-group comparison and your portrait photos. Under them, "This
/// iPhone": the server, the Apple Health sync and the rest only the iPhone has. Shown in every phase, so the server
/// address can be changed before sign-in; the person's own parts only while someone's signed in. `query` is the web's:
/// ?connect=openai or ?connect=chatbot opens that key sheet once, as the web's links do.
struct ProfileScreen: View {
    var query: [String: String] = [:]
    @Environment(AppModel.self) private var model
    @Environment(Dashboard.self) private var dashboard
    @State private var confirmReupload = false
    @State private var confirmSample = false
    @State private var sheet: ProfileSheet?
    /// The sheet last shown, for what its closing does.
    @State private var shown: ProfileSheet?
    /// ?connect= was acted on: it opens its sheet once, not each time Profile shows again.
    @State private var linkHandled = false
    /// The server answered that it has no export: it's older than the export, so the row goes.
    @State private var exportMissing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Never the last person's: only while someone's signed in (or a server without sign-in is connected).
                if dashboard.phase == .ready, let settings = dashboard.status?.settings {
                    ProfileYoursCard(settings: settings, exportMissing: $exportMissing) { sheet = $0 }
                    ProfileSettingsCard(settings: settings) { sheet = $0 }
                    PeersSection()
                    PortraitPhotosSection()
                    // "Use a photo as is", here until the portrait photos take it in.
                    ProfilePhotoCard()
                }
                ProfileThisIPhone(confirmSample: { confirmSample = true }, confirmReupload: { confirmReupload = true })
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.page)
        .keyboardDismissal()
        .sheet(item: $sheet, onDismiss: closed) { sheet in
            Group {
                switch sheet {
                case .chatbot: ChatbotSheet(onClose: close)
                case .openai: OpenAIKeySheet(onClose: close)
                case .basics: ProfileBasicsSheet(settings: dashboard.status?.settings, close: close)
                case .cards: ProfileCardsSheet(close: close)
                case .family: ProfileFamilySheet(close: close)
                case .cycle: ProfileCycleSheet(close: close)
                case .nutrition: ProfileNutritionSheet(close: close)
                }
            }
            .environment(model)
            .environment(dashboard)
        }
        .onChange(of: sheet) { _, now in
            if let now { shown = now }
        }
        // Signed out (Sign out, a 401) or the server gone: no sheet stays up on the last person's settings or keys.
        .onChange(of: dashboard.phase) { _, phase in
            if phase != .ready { sheet = nil }
        }
        .task(id: "\(dashboard.phase == .ready)|\(dashboard.availability.aiMissing)") { openLinked() }
        .alert(model.notice ?? "", isPresented: noticeShown) {
            Button("OK", role: .cancel) {}
        }
        #if targetEnvironment(simulator)
        .confirmationDialog("Add fake Health data?", isPresented: $confirmSample, titleVisibility: .visible) {
            Button("Add sample data", role: .destructive) { Task { await model.addSampleData() } }
        } message: {
            Text(sampleWarning)
        }
        #endif
        .confirmationDialog("Upload all history again?", isPresented: $confirmReupload, titleVisibility: .visible) {
            Button("Upload all history") { Task { await model.uploadAllHistory() } }
        } message: {
            Text("Every day back to \"\(model.history.label)\" is read from Health and sent again. Nothing is deleted.")
        }
        .onDisappear { Task { await dashboard.startIfNeeded() } }
    }

    private func close() { sheet = nil }

    /// A key sheet closed: what the person's AI uses is read again, as the web's closeAi.
    private func closed() {
        if shown == .chatbot || shown == .openai { Task { await dashboard.loadAI(force: true) } }
        shown = nil
    }

    /// ?connect=openai (Nutrition's setup line) or ?connect=chatbot: that sheet, once, as soon as someone's signed in,
    /// and not on a server too old for keys.
    private func openLinked() {
        guard !linkHandled, let linked = ProfileSheet.linked(query) else { return }
        guard dashboard.phase == .ready, dashboard.status?.settings != nil else { return }
        linkHandled = true
        if !dashboard.availability.aiMissing { sheet = linked }
    }

    private var noticeShown: Binding<Bool> {
        Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })
    }

    private var sampleWarning: String {
        let target = Config.serverURL(model.serverText)?.absoluteString ?? "the server you set"
        return "Two weeks of made-up data goes into this simulator's Health store, and the next sync uploads it to \(target) as real Apple Health data. Only continue if that's a scratch server."
    }
}

/// The sheets Profile opens.
enum ProfileSheet: String, Identifiable {
    case chatbot, openai, basics, cards, family, cycle, nutrition
    var id: String { rawValue }

    /// The sheets other pages open by link (the web's LINKED): #/profile?connect=openai or ?connect=chatbot.
    static func linked(_ query: [String: String]) -> ProfileSheet? {
        switch query["connect"] {
        case "openai": .openai
        case "chatbot": .chatbot
        default: nil
        }
    }
}

/// "Your profile": how you're shown, your AI, your account, your sources, the export, privacy, and signing out.
private struct ProfileYoursCard: View {
    let settings: ServerStatus.Settings
    @Binding var exportMissing: Bool
    let open: (ProfileSheet) -> Void
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let availability = dashboard.availability
        // A server older than own keys (no GET /api/ai) has no key sheets, and, from the same change, no export.
        let keys = !availability.aiMissing
        let signedIn = dashboard.signOutOffered
        let openAIKey = availability.ai.value?.key("openai")
        ProfileCard("Your profile") {
            // Only where the status names how you're shown: an older server ignores what the welcome saves.
            if settings.perspective != nil {
                ProfileRow("Your profile & perspective") {
                    Text(ProfileWords.perspective(settings, drawn: FigureVariant.of(settings).drawn))
                    Text(ProfileWords.peers(settings))
                } action: {
                    Button("Edit preferences") { dashboard.open(.welcome) }
                        .buttonStyle(.quietPill(size: .compact))
                        .accessibilityIdentifier("editPreferences")
                }
            }
            if keys {
                ProfileRow("Chatbot") {
                    Text(ProfileWords.chatbot(byok: availability.byok))
                    if let own = ProfileWords.ownChat(availability.ai.value) { Text(own) }
                } action: {
                    Button("Manage chatbot AI") { open(.chatbot) }
                        .buttonStyle(.quietPill(size: .compact))
                        .accessibilityIdentifier("manageChatbot")
                }
            }
            ProfileAccountRow()
            if keys {
                ProfileRow("OpenAI · Nutrition & portraits") {
                    Text(ProfileWords.openAI(byok: availability.byok))
                    if let openAIKey { Text(ProfileWords.openAIConnected(last4: openAIKey.last4)).foregroundStyle(Palette.accentText) }
                } action: {
                    Button(openAIKey == nil ? "Connect AI key" : "Manage AI key") { open(.openai) }
                        .buttonStyle(.quietPill(size: .compact))
                        .accessibilityIdentifier("manageOpenAI")
                }
            }
            ProfileRow("Connected sources", lines: ["Manage what comes into your health profile."]) {
                Button("Manage sources") { dashboard.open(.integrations) }
                    .buttonStyle(.quietPill(size: .compact))
                    .accessibilityIdentifier("manageSources")
            }
            if keys, !exportMissing { ProfileExportRow(missing: $exportMissing) }
            ProfileRow("Privacy & data use", lines: ["Understand how files, food descriptions and recordings are handled."], divider: signedIn) {
                Button("Read details") { dashboard.showWeb("privacy.html") }
                    .buttonStyle(.quietPill(size: .compact))
                    .accessibilityHint("Opens the privacy page")
                    .accessibilityIdentifier("privacyDetails")
            }
            if signedIn {
                ProfileRow("End your session", lines: ["Sign out on this device."], divider: false) {
                    Button("Sign out") { Task { await dashboard.signOut() } }
                        .buttonStyle(.quietPill(size: .compact))
                        .accessibilityIdentifier("profileSignOut")
                }
            }
        }
    }
}

/// "Your settings": each row says how it's set and opens its sheet. A row shows only where the server's status names
/// its setting (an older server has no cards, Family board, cycle or nutrition to change), and the Family board only
/// with sign-in, where each person has their own account.
private struct ProfileSettingsCard: View {
    let settings: ServerStatus.Settings
    let open: (ProfileSheet) -> Void
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let cards = dashboard.cardsAvailable
        let family = dashboard.signOutOffered && settings.familySharing != nil
        let cycle = settings.cycleTracking != nil
        let nutrition = dashboard.nutritionAvailable
        // The card's last row has no line under it.
        let last: ProfileSheet = nutrition ? .nutrition : cycle ? .cycle : family ? .family : cards ? .cards : .basics
        ProfileCard("Your settings") {
            row(.basics, "Units & daily goal", ProfileWords.units(settings), "Edit", last: last)
            if cards { row(.cards, "Cards", ProfileWords.cardPages(nutrition: settings.nutrition == true), "Choose cards", last: last) }
            if family { row(.family, "Family board", ProfileWords.family(sharing: settings.familySharing == true), "Manage", last: last) }
            if cycle { row(.cycle, "Cycle tracking", ProfileWords.cycle(settings), "Manage", last: last) }
            if nutrition { row(.nutrition, "Nutrition", ProfileWords.nutrition(settings), "Manage", last: last) }
        }
    }

    private func row(_ sheet: ProfileSheet, _ title: String, _ line: String, _ action: String, last: ProfileSheet) -> some View {
        ProfileRow(title, lines: [line], divider: sheet != last) {
            Button(action) { open(sheet) }
                .buttonStyle(.quietPill(size: .compact))
                .accessibilityLabel("\(action), \(title)")
                .accessibilityIdentifier(sheet == .cards ? "cards" : "settings-\(sheet.rawValue)")
        }
    }
}

/// "Use a photo as is" (PhotoSection, the portrait photos' own), on a card of its own until it moves into the portrait
/// photos card.
private struct ProfilePhotoCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PhotoSection()
        }
        .font(.app(.footnote))
        .card()
    }
}
