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
    /// The link acted on (`linkRequest`): its sheet opens once, not each time Profile shows again, and again only when
    /// the same link is opened anew.
    @State private var linkHandled: Int?
    /// Change password's form, open or not and what's typed in it: kept here, above the open Duo's panes, so a fold
    /// that swaps the page's one column for its two panes keeps it (P4). Cleared when nobody's signed in any more.
    @State private var password = ProfilePasswordDraft()

    var body: some View {
        // One column on every iPhone, the outer display and the inner display upright; on the open iPhone Duo in
        // landscape (decisions.md Q5), the photo, the name and how you're shown on the leading side of the fold, staying
        // put, and the rest as cards in two columns on the trailing side.
        DuoPage { _ in
            DuoPanes(anchor: .secondary) {
                ProfileLead(password: password, confirmSample: $confirmSample, confirmReupload: $confirmReupload) { sheet = $0 }
            } secondary: {
                ProfileColumns(password: password, confirmSample: $confirmSample, confirmReupload: $confirmReupload) { sheet = $0 }
            } single: {
                ProfileColumn(password: password, confirmSample: $confirmSample, confirmReupload: $confirmReupload) { sheet = $0 }
            }
        }
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
        // Signed out (Sign out, a 401) or the server gone: no sheet stays up on the last person's settings or keys, and
        // nothing typed into Change password stays for whoever signs in next.
        // (An export on its way stops by itself, wherever the app is: ProfileExportJob.)
        .onChange(of: dashboard.phase) { _, phase in
            if phase != .ready {
                sheet = nil
                password.reset()
            }
        }
        .onChange(of: dashboard.signedInPerson) { _, _ in password.reset() }
        // Again once the settings come (the status can land after the phase is ready) and once the server has said
        // whether it has keys at all.
        .task(id: "\(dashboard.phase == .ready)|\(dashboard.status?.settings != nil)|\(ProfileSheet.aiKnown(dashboard.availability.ai))|\(linkRequest)") {
            await openLinked()
        }
        .alert(model.notice ?? "", isPresented: noticeShown) {
            Button("OK", role: .cancel) {}
        }
        .onDisappear {
            // Profile went (Back, another tab): the export's line goes with it, as the web's does. Not when a fold only
            // moves its row from the one column to a pane.
            ProfileExportJob.shared.rowGone()
            Task { await dashboard.startIfNeeded() }
        }
    }

    private func close() { sheet = nil }

    /// Which opening of this Profile's link this is: the link's own request (`Dashboard.open`), so the same link opened
    /// again while Profile is still up (its path doesn't change) is a new one; 0 when Profile wasn't opened by a link.
    private var linkRequest: Int {
        guard let request = dashboard.request(for: .profile), request.route.query == query else { return 0 }
        return request.id
    }

    /// A key sheet closed: what the person's AI uses is read again, as the web's closeAi.
    private func closed() {
        if shown == .chatbot || shown == .openai { Task { await dashboard.loadAI(force: true) } }
        shown = nil
    }

    /// ?connect=openai (Nutrition's setup line) or ?connect=chatbot: that sheet, once, as soon as someone's signed in
    /// and their settings are here, and not on a server too old for keys. Whether it has them is asked first
    /// (GET /api/ai); a read that fails says nothing either way, so the sheet opens and says what it can.
    private func openLinked() async {
        let request = linkRequest
        guard linkHandled != request, ProfileSheet.linked(query) != nil else { return }
        let ready = dashboard.phase == .ready
        let settings = dashboard.status?.settings != nil
        var asked = false
        if ready, settings, dashboard.availability.ai == .unknown {
            await dashboard.loadAI()
            // The answer changed what this task looks at: the next one decides.
            if Task.isCancelled { return }
            asked = true
        }
        switch ProfileSheet.link(query, ready: dashboard.phase == .ready, settings: dashboard.status?.settings != nil,
                                 ai: dashboard.availability.ai, asked: asked) {
        case .none, .wait: break
        case .drop: linkHandled = request
        case .open(let linked):
            linkHandled = request
            sheet = linked
        }
    }

    private var noticeShown: Binding<Bool> {
        Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })
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

    /// What a ?connect= link does now.
    enum Link: Equatable {
        /// No link.
        case none
        /// Not yet: nobody's signed in, the settings haven't come, or whether the server has keys hasn't been asked.
        case wait
        /// Open its sheet, once.
        case open(ProfileSheet)
        /// Never: the server is older than own keys.
        case drop
    }

    /// The link's sheet once someone's signed in with their settings here and the server has said it has keys, or a
    /// read of that has been tried and failed (unknown isn't "not there"). A server that answered it has no keys
    /// (GET /api/ai is a 404) never opens it.
    static func link(_ query: [String: String], ready: Bool, settings: Bool, ai: Availability.Read<AiStatus>, asked: Bool) -> Link {
        guard let linked = linked(query) else { return .none }
        guard ready, settings else { return .wait }
        switch ai {
        case .missing: return .drop
        case .known: return .open(linked)
        case .unknown: return asked ? .open(linked) : .wait
        }
    }

    /// For the task that decides: whether the server's answer about keys is in yet.
    static func aiKnown(_ ai: Availability.Read<AiStatus>) -> String {
        switch ai {
        case .unknown: "unknown"
        case .missing: "missing"
        case .known: "known"
        }
    }
}

/// Profile's one column (every iPhone, the outer display, the inner display upright, Split View): "Your profile", "Your
/// settings", the comparison and the portrait photos while someone's signed in, then "This iPhone".
private struct ProfileColumn: View {
    let password: ProfilePasswordDraft
    @Binding var confirmSample: Bool
    @Binding var confirmReupload: Bool
    let open: (ProfileSheet) -> Void
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        // One flat stack of rows with the same ids as the trailing pane's (ProfileRowID), so a fold hands the row at
        // the top between this column and that pane (DuoPanes' handoff).
        VStack(alignment: .leading, spacing: 18) {
            // Never the last person's: only while someone's signed in (or a server without sign-in is connected).
            if dashboard.phase == .ready, let settings = dashboard.status?.settings {
                ProfileYoursCard(settings: settings, password: password, open: open)
                    .id(ProfileRowID.yours)
                ProfileSettingsCard(settings: settings, open: open)
                    .id(ProfileRowID.settings)
                PeersSection()
                    .id(ProfileRowID.peers)
                // "Use a photo as is" (PhotoSection) is inside the portrait photos, not a card of its own here.
                PortraitPhotosSection()
                    .id(ProfileRowID.portraits)
            }
            ProfileThisIPhone(confirmSample: $confirmSample, confirmReupload: $confirmReupload)
                .id(ProfileRowID.iPhone)
        }
        .scrollTargetLayout()
        .padding(.vertical, 16)
    }
}

/// The open iPhone Duo's leading side (decisions.md Q5): the photo or the initial, the name, and how you're shown with
/// Edit preferences, staying put while the trailing side scrolls. Signed out, it's "This iPhone", so the server can be
/// changed there as in one column.
private struct ProfileLead: View {
    let password: ProfilePasswordDraft
    @Binding var confirmSample: Bool
    @Binding var confirmReupload: Bool
    let open: (ProfileSheet) -> Void
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if dashboard.phase == .ready, let settings = dashboard.status?.settings {
                ProfileIdentity()
                if ProfileItem.yours(settings: settings, dashboard: dashboard).contains(.perspective) {
                    ProfilePaneCard {
                        ProfileYoursRow(item: .perspective, settings: settings, password: password, divider: false, open: open)
                    }
                }
            } else {
                ProfileThisIPhone(confirmSample: $confirmSample, confirmReupload: $confirmReupload)
            }
        }
        .padding(.vertical, 16)
    }
}

/// The photo (or the initial on sage, as the avatar everywhere), the name, and the email under it.
private struct ProfileIdentity: View {
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let name = (dashboard.summary?.name ?? dashboard.status?.settings?.name).flatMap { $0.isEmpty ? nil : $0 }
        let email = (dashboard.status?.user ?? dashboard.account)?.email ?? dashboard.account?.email
        VStack(spacing: 12) {
            Avatar(photo: dashboard.status?.photo, name: name, size: 128)
            VStack(spacing: 4) {
                Text(name ?? "Your profile")
                    .font(.app(size: 26, weight: .medium, relativeTo: .title2))
                    .tracking(-0.4)
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                if let email, !email.isEmpty {
                    Text(email)
                        .font(.app(.footnote))
                        .foregroundStyle(Palette.ink3)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("profileIdentity")
    }
}

/// The open iPhone Duo's trailing side (decisions.md Q5): every other row as a card of its own, two to a row, under its
/// card's heading; what needs the width (Account with its password form open, the server and the sync) across both
/// columns; the comparison and the portrait photos, which open in place, across both too, and This iPhone under them.
private struct ProfileColumns: View {
    let password: ProfilePasswordDraft
    @Binding var confirmSample: Bool
    @Binding var confirmReupload: Bool
    let open: (ProfileSheet) -> Void
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        // One flat stack of rows, each heading with its grid as one, with the one column's ids (ProfileRowID): the fold's
        // handoff finds the row at the top on both sides.
        VStack(alignment: .leading, spacing: 14) {
            if dashboard.phase == .ready, let settings = dashboard.status?.settings {
                let yours = ProfileItem.yours(settings: settings, dashboard: dashboard).filter { $0 != .perspective }
                if !yours.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        ProfilePaneHeading("Your profile")
                        DuoGrid(yours, id: \.self, paneColumns: 2) { item in
                            let card = ProfilePaneCard {
                                ProfileYoursRow(item: item, settings: settings, password: password, divider: false, open: open)
                            }
                            if item == .account, password.open { card.duoSpans() } else { card }
                        }
                    }
                    .id(ProfileRowID.yours)
                }
                VStack(alignment: .leading, spacing: 14) {
                    ProfilePaneHeading("Your settings").padding(.top, 8)
                    DuoGrid(ProfileItem.settings(settings: settings, dashboard: dashboard), id: \.self, paneColumns: 2) { item in
                        ProfilePaneCard { ProfileSettingsRow(item: item, settings: settings, divider: false, open: open) }
                    }
                }
                .id(ProfileRowID.settings)
                PeersSection()
                    .padding(.top, 4)
                    .id(ProfileRowID.peers)
                PortraitPhotosSection()
                    .padding(.top, 4)
                    .id(ProfileRowID.portraits)
                VStack(alignment: .leading, spacing: 14) {
                    ProfilePaneHeading("This iPhone").padding(.top, 8)
                    ProfileThisIPhoneGrid(confirmSample: $confirmSample, confirmReupload: $confirmReupload)
                }
                .id(ProfileRowID.iPhone)
            }
        }
        .scrollTargetLayout()
        .padding(.vertical, 16)
    }
}

/// Profile's rows as the fold's scroll handoff knows them: the same row has the same id in the one column and in the
/// open Duo's trailing pane, so unfolding (or folding) opens the other on the row that was at the top.
enum ProfileRowID {
    static let yours = "profile.yours"
    static let settings = "profile.settings"
    static let peers = "profile.peers"
    static let portraits = "profile.portraits"
    static let iPhone = "profile.iphone"
}

/// A heading over the open Duo's cards, as a Profile card's own title.
private struct ProfilePaneHeading: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.app(size: 17, weight: .medium, relativeTo: .headline))
            .tracking(-0.17)
            .foregroundStyle(Palette.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One row as a card of its own (the open Duo's two columns): the row's own 16 pt above and below, padded to the card's
/// 18, filling its row of the grid so the two cards side by side are the same height.
struct ProfilePaneCard<Content: View>: View {
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(.horizontal, 18)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background { CardSurface(shape: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)) }
    }
}

/// Profile's rows, in the web's order: which show for this person on this server (an older server has no keys, no export,
/// no cards, Family board, cycle or nutrition to change).
enum ProfileItem: String, Hashable, CaseIterable {
    // "Your profile"
    case perspective, chatbot, account, openai, sources, export, privacy, signOut
    // "Your settings": each opens its sheet.
    case basics, cards, family, cycle, nutrition

    /// "Your profile"'s rows. A server older than own keys (no GET /api/ai) has no key sheets, and, from the same
    /// change, no export; Account only with something to say; End your session only with sign-in.
    @MainActor
    static func yours(settings: ServerStatus.Settings, dashboard: Dashboard) -> [ProfileItem] {
        let keys = !dashboard.availability.aiMissing
        var items: [ProfileItem] = []
        // Only where the status names how you're shown: an older server ignores what the welcome saves.
        if settings.perspective != nil { items.append(.perspective) }
        if keys { items.append(.chatbot) }
        if ProfileAccountRow.shown(dashboard) { items.append(.account) }
        if keys { items.append(.openai) }
        items.append(.sources)
        if keys { items.append(.export) }
        items.append(.privacy)
        if dashboard.signOutOffered { items.append(.signOut) }
        return items
    }

    /// "Your settings"' rows: each only where the server's status names its setting, and the Family board only with
    /// sign-in, where each person has their own account.
    @MainActor
    static func settings(settings: ServerStatus.Settings, dashboard: Dashboard) -> [ProfileItem] {
        var items: [ProfileItem] = [.basics]
        if dashboard.cardsAvailable { items.append(.cards) }
        if dashboard.signOutOffered && settings.familySharing != nil { items.append(.family) }
        if settings.cycleTracking != nil { items.append(.cycle) }
        if dashboard.nutritionAvailable { items.append(.nutrition) }
        return items
    }

    /// The sheet a settings row opens.
    var sheet: ProfileSheet? {
        switch self {
        case .basics: .basics
        case .cards: .cards
        case .family: .family
        case .cycle: .cycle
        case .nutrition: .nutrition
        default: nil
        }
    }
}

/// "Your profile": how you're shown, your AI, your account, your sources, the export, privacy, and signing out.
private struct ProfileYoursCard: View {
    let settings: ServerStatus.Settings
    let password: ProfilePasswordDraft
    let open: (ProfileSheet) -> Void
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let items = ProfileItem.yours(settings: settings, dashboard: dashboard)
        ProfileCard("Your profile") {
            // The card's last row has no line under it.
            ForEach(items, id: \.self) { item in
                ProfileYoursRow(item: item, settings: settings, password: password, divider: item != items.last, open: open)
            }
        }
    }
}

/// One of "Your profile"'s rows.
private struct ProfileYoursRow: View {
    let item: ProfileItem
    let settings: ServerStatus.Settings
    let password: ProfilePasswordDraft
    let divider: Bool
    let open: (ProfileSheet) -> Void
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let availability = dashboard.availability
        switch item {
        case .perspective:
            ProfileRow("Your profile & perspective", divider: divider) {
                Text(ProfileWords.perspective(settings, drawn: FigureVariant.of(settings).drawn))
                Text(ProfileWords.peers(settings))
            } action: {
                Button("Edit preferences") { dashboard.open(.welcome) }
                    .buttonStyle(ProfilePillStyle())
                    .accessibilityIdentifier("editPreferences")
            }
        case .chatbot:
            ProfileRow("Chatbot", divider: divider) {
                Text(ProfileWords.chatbot(byok: availability.byok))
                if let own = ProfileWords.ownChat(availability.ai.value) { Text(own) }
            } action: {
                Button("Manage chatbot AI") { open(.chatbot) }
                    .buttonStyle(ProfilePillStyle())
                    .accessibilityIdentifier("manageChatbot")
            }
        case .account:
            ProfileAccountRow(draft: password, divider: divider)
        case .openai:
            let openAIKey = availability.ai.value?.key("openai")
            ProfileRow("OpenAI · Nutrition & portraits", divider: divider) {
                Text(ProfileWords.openAI(byok: availability.byok))
                if let openAIKey { Text(ProfileWords.openAIConnected(last4: openAIKey.last4)).foregroundStyle(Palette.accentText) }
            } action: {
                Button(openAIKey == nil ? "Connect AI key" : "Manage AI key") { open(.openai) }
                    .buttonStyle(ProfilePillStyle())
                    .accessibilityIdentifier("manageOpenAI")
            }
        case .sources:
            ProfileRow("Connected sources", lines: ["Manage what comes into your health profile."], divider: divider) {
                Button("Manage sources") { dashboard.open(.integrations) }
                    .buttonStyle(ProfilePillStyle())
                    .accessibilityIdentifier("manageSources")
            }
        case .export:
            ProfileExportRow(divider: divider)
        case .privacy:
            ProfileRow("Privacy & data use", lines: ["Understand how files, food descriptions and recordings are handled."], divider: divider) {
                Button("Read details") { dashboard.showWeb("privacy.html") }
                    .buttonStyle(ProfilePillStyle())
                    .accessibilityHint("Opens the privacy page")
                    .accessibilityIdentifier("privacyDetails")
            }
        case .signOut:
            ProfileRow("End your session", lines: ["Sign out on this device."], divider: divider) {
                Button("Sign out") { Task { await dashboard.signOut() } }
                    .buttonStyle(ProfilePillStyle())
                    .accessibilityIdentifier("profileSignOut")
            }
        case .basics, .cards, .family, .cycle, .nutrition:
            ProfileSettingsRow(item: item, settings: settings, divider: divider, open: open)
        }
    }
}

/// "Your settings": each row says how it's set and opens its sheet.
private struct ProfileSettingsCard: View {
    let settings: ServerStatus.Settings
    let open: (ProfileSheet) -> Void
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let items = ProfileItem.settings(settings: settings, dashboard: dashboard)
        ProfileCard("Your settings") {
            // The card's last row has no line under it.
            ForEach(items, id: \.self) { item in
                ProfileSettingsRow(item: item, settings: settings, divider: item != items.last, open: open)
            }
        }
    }
}

/// One of "Your settings"' rows: how it's set, and the button that opens its sheet.
private struct ProfileSettingsRow: View {
    let item: ProfileItem
    let settings: ServerStatus.Settings
    let divider: Bool
    let open: (ProfileSheet) -> Void

    var body: some View {
        if let sheet = item.sheet {
            let (title, line, action) = words
            ProfileRow(title, lines: [line], divider: divider) {
                Button(action) { open(sheet) }
                    .buttonStyle(ProfilePillStyle())
                    .accessibilityLabel("\(action), \(title)")
                    .accessibilityIdentifier(sheet == .cards ? "cards" : "settings-\(sheet.rawValue)")
            }
        }
    }

    private var words: (title: String, line: String, action: String) {
        switch item {
        case .cards: ("Cards", ProfileWords.cardPages(nutrition: settings.nutrition == true), "Choose cards")
        case .family: ("Family board", ProfileWords.family(sharing: settings.familySharing == true), "Manage")
        case .cycle: ("Cycle tracking", ProfileWords.cycle(settings), "Manage")
        case .nutrition: ("Nutrition", ProfileWords.nutrition(settings), "Manage")
        default: ("Units & daily goal", ProfileWords.units(settings), "Edit")
        }
    }
}
