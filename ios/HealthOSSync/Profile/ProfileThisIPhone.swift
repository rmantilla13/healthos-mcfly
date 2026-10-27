import SwiftUI

/// What only the iPhone has, under the web's Profile: the server it reads from (reachable before sign-in, so the
/// address can be changed from the sign-in screen), the Apple Health sync and its ingest token, Health access and
/// background sync, the weekly digest reminder, the simulator's sample data, and sending all history again. Drawn
/// with Profile's own rows, in the web's ink. The two that ask first (sample data, sending everything again) ask from
/// their own buttons, so on a wide screen the question points at what was tapped (design §2.7, P10).
struct ProfileThisIPhone: View {
    @Binding var confirmSample: Bool
    @Binding var confirmReupload: Bool
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let items = ProfileIPhoneItem.shown(dashboard)
        ProfileCard("This iPhone") {
            // The card's last row has no line under it.
            ForEach(items, id: \.self) { item in
                ProfileIPhoneRow(item: item, divider: item != items.last, confirmSample: $confirmSample, confirmReupload: $confirmReupload)
            }
        }
    }
}

/// "This iPhone" on the open iPhone Duo's trailing side (decisions.md Q5): each row a card of its own; the server and the
/// sync (fields and long lines) and the two with switches (their words beside the switch) across both columns, the
/// sample data and sending everything again two to a row.
struct ProfileThisIPhoneGrid: View {
    @Binding var confirmSample: Bool
    @Binding var confirmReupload: Bool
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        DuoGrid(ProfileIPhoneItem.shown(dashboard), id: \.self, paneColumns: 2) { item in
            let card = ProfilePaneCard {
                ProfileIPhoneRow(item: item, divider: false, confirmSample: $confirmSample, confirmReupload: $confirmReupload)
            }
            if item.wide { card.duoSpans() } else { card }
        }
    }
}

/// The iPhone's rows, in order.
enum ProfileIPhoneItem: String, Hashable, CaseIterable {
    case server, sync, health, digest, simulator, upload

    /// The rows this iPhone shows now: the weekly digest while someone's signed in (or while it's on), the sample data
    /// only in the simulator.
    @MainActor
    static func shown(_ dashboard: Dashboard) -> [ProfileIPhoneItem] {
        var items: [ProfileIPhoneItem] = [.server, .sync, .health]
        if dashboard.phase == .ready || DigestNotifications.enabled { items.append(.digest) }
        #if targetEnvironment(simulator)
        items.append(.simulator)
        #endif
        items.append(.upload)
        return items
    }

    /// Needs a row of its own in two columns: a text field and long lines, or a switch with its words beside it.
    var wide: Bool { self != .simulator && self != .upload }
}

/// One of the iPhone's rows.
private struct ProfileIPhoneRow: View {
    let item: ProfileIPhoneItem
    let divider: Bool
    @Binding var confirmSample: Bool
    @Binding var confirmReupload: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        switch item {
        case .server: ProfileServerRow(divider: divider)
        case .sync: ProfileSyncRow(divider: divider)
        case .health: ProfileHealthRow(divider: divider)
        case .digest: ProfileDigestRow(divider: divider)
        case .simulator:
            #if targetEnvironment(simulator)
            ProfileBlock("Simulator", divider: divider) {
                ProfileFine("Fake data for testing. Use a scratch server only, never your real dashboard.")
                Button("Add sample Health data") { confirmSample = true }
                    .buttonStyle(ProfilePillStyle())
                    .disabled(model.working)
                    .accessibilityIdentifier("addSampleData")
                    .confirmationDialog("Add fake Health data?", isPresented: $confirmSample, titleVisibility: .visible) {
                        Button("Add sample data", role: .destructive) { Task { await model.addSampleData() } }
                    } message: {
                        Text(sampleWarning)
                    }
            }
            #else
            EmptyView()
            #endif
        case .upload:
            ProfileBlock("Upload all history again", divider: divider) {
                ProfileFine("Use this after clearing Apple Health data on the server, or after deleting old entries in Health.")
                Button("Upload all history again", role: .destructive) { confirmReupload = true }
                    .buttonStyle(ProfilePillStyle(.danger))
                    .disabled(model.syncing)
                    .accessibilityIdentifier("uploadAgain")
                    .confirmationDialog("Upload all history again?", isPresented: $confirmReupload, titleVisibility: .visible) {
                        Button("Upload all history") { Task { await model.uploadAllHistory() } }
                    } message: {
                        Text("Every day back to \"\(model.history.label)\" is read from Health and sent again. Nothing is deleted.")
                    }
            }
        }
    }

    private var sampleWarning: String {
        let target = Config.serverURL(model.serverText)?.absoluteString ?? "the server you set"
        return "Two weeks of made-up data goes into this simulator's Health store, and the next sync uploads it to \(target) as real Apple Health data. Only continue if that's a scratch server."
    }
}

/// One of the iPhone's rows, as ProfileRow draws a row: its title in ink, whatever it holds under it, and a hairline
/// under the row unless it's the card's last.
struct ProfileBlock<Content: View>: View {
    let title: String
    var divider = true
    @ViewBuilder var content: Content

    init(_ title: String, divider: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.divider = divider
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.app(.subheadline, weight: .medium))
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if divider { Rectangle().fill(Palette.border).frame(height: 1) }
        }
    }
}

private struct ProfileServerRow: View {
    var divider = true
    @Environment(AppModel.self) private var model
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        @Bindable var model = model
        ProfileBlock("Server", divider: divider) {
            TextField("https://health.mcfly.bot", text: $model.serverText)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { Task { await dashboard.start() } }
                .profileInput()
                .accessibilityLabel("Server address")
                .accessibilityIdentifier("serverURL")
            Text(accountText)
                .font(.app(.footnote))
                .foregroundStyle(Palette.ink2)
                .accessibilityIdentifier("serverState")
            ProfileFine("The dashboard reads from your healthOS server, which merges Apple Health with WHOOP.")
            if dashboard.phase == .signIn {
                // The sign-in screen is on Home.
                Button("Sign in") { dashboard.open(.home) }
                    .buttonStyle(ProfilePillStyle(.accent))
                    .accessibilityIdentifier("profileSignIn")
            }
        }
    }

    private var accountText: String {
        switch dashboard.phase {
        case .starting: "Connecting…"
        case .noServer: "No server"
        case .signIn: "Signed out"
        case .misconfigured: "Sign-in isn't set up"
        case .unavailable(let message): message
        case .ready:
            // A server with sign-in off reports a placeholder owner with no email.
            if dashboard.authMode == "required", let email = dashboard.account?.email ?? dashboard.status?.user?.email, !email.isEmpty { "Signed in as \(email)" }
            else { dashboard.authMode == "required" ? "Signed in" : "Connected" }
        }
    }
}

private struct ProfileSyncRow: View {
    var divider = true
    @Environment(AppModel.self) private var model
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        @Bindable var model = model
        ProfileBlock("Sync", divider: divider) {
            // The token sends to one account (IngestTokenOwner): say why nothing goes up.
            if dashboard.ingestOwner.paused {
                ProfileIconLine("pause.circle", "Signed out. This iPhone's Health data isn't sent until someone signs in.")
                    .accessibilityIdentifier("syncPaused")
            } else if dashboard.ingestOwner.setUpAgain, model.token.isEmpty {
                ProfileIconLine("exclamationmark.triangle", "This iPhone's token may belong to another account, so it was removed and nothing more goes there. Set this iPhone up again for your account in Integrations on the dashboard (Integrations → iPhone app), then paste the new token below.")
                    .accessibilityIdentifier("setUpAgain")
            }
            HStack(spacing: 10) {
                Button("Sync now") { Task { await model.syncAll(force: true) } }
                    .buttonStyle(ProfilePillStyle(.accent))
                    .disabled(model.syncingSources || !model.serverValid)
                    .accessibilityIdentifier("syncNow")
                if model.syncingSources { ProgressView() }
            }
            if model.syncingSources, !model.progress.isEmpty {
                ProfileFine(model.progress)
            }
            ProfileLastSync(status: model.sources, report: model.last)
            if model.backfillLeft > 0 {
                ProfileIconLine("clock.arrow.circlepath", "Sending older history: \(model.backfillLeft) day\(model.backfillLeft == 1 ? "" : "s") left. Continues while the app is open.")
            }
            ProfileField("Ingest token") {
                SecureField("", text: $model.token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .profileInput()
                    .accessibilityLabel("Ingest token")
                    .accessibilityIdentifier("token")
            }
            Button("Test connection") { Task { await model.testConnection() } }
                .buttonStyle(ProfilePillStyle())
                .disabled(!model.serverValid || model.token.isEmpty || model.working)
                .accessibilityIdentifier("testConnection")
            ProfileFine("One tap syncs both: this iPhone's Apple Health data goes to your account, and the server refreshes WHOOP. It also runs when you open the app. Get your ingest token on the dashboard under Integrations → iPhone app.")
        }
    }
}

/// When it last synced and how it went: the last Sync this launch, or before one, the last Apple Health push (maybe
/// from the background).
private struct ProfileLastSync: View {
    let status: SourcesSyncStatus?
    let report: SyncReport?

    var body: some View {
        if let status {
            when("Last sync", status.finishedAt)
            ProfileIconLine(status.ok ? "checkmark.circle" : "exclamationmark.triangle", status.summary, bad: !status.ok)
                .accessibilityIdentifier("lastResult")
            ForEach(status.notes, id: \.self) { ProfileFine($0) }
        } else if let report {
            when("Apple Health", report.finishedAt)
            ProfileIconLine(report.ok ? "checkmark.circle" : "exclamationmark.triangle", report.message, bad: !report.ok)
        } else {
            pair(Text("Last sync"), Text("Never"))
        }
    }

    private func when(_ title: String, _ date: Date) -> some View {
        pair(Text(title), Text(date, format: .relative(presentation: .named)))
    }

    /// A name and its value: the value on the right, or under the name when they don't fit on one line.
    private func pair(_ name: Text, _ value: Text) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                name.fixedSize()
                Spacer(minLength: 12)
                value.foregroundStyle(Palette.ink3).fixedSize()
            }
            VStack(alignment: .leading, spacing: 2) {
                name
                value.foregroundStyle(Palette.ink3)
            }
        }
        .font(.app(.footnote))
        .foregroundStyle(Palette.ink2)
        .accessibilityElement(children: .combine)
    }
}

private struct ProfileHealthRow: View {
    var divider = true
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ProfileBlock("Health data", divider: divider) {
            if !model.healthRequested {
                Button("Allow Health access") { Task { await model.requestHealthAccess() } }
                    .buttonStyle(ProfilePillStyle(.accent))
                    .accessibilityIdentifier("allowHealth")
            }
            ProfileSwitch("Sync in the background", text: "Background sync runs when Health gets new data, as often as iOS allows (hourly for steps). Health data can't be read while the phone is locked.",
                          isOn: $model.backgroundSync)
                .accessibilityIdentifier("backgroundSync")
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("First upload covers")
                    .font(.app(size: 14, weight: .medium, relativeTo: .subheadline))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
                Menu {
                    Picker("First upload covers", selection: $model.history) {
                        ForEach(History.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(model.history.label)
                        Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                    }
                    .font(.app(size: 14, relativeTo: .subheadline))
                    .foregroundStyle(Palette.accentText)
                }
                .accessibilityLabel("First upload covers")
                .accessibilityValue(model.history.label)
                .accessibilityIdentifier("firstUpload")
            }
        }
    }
}

/// The Monday reminder for McFly's weekly digest (Insights under More).
private struct ProfileDigestRow: View {
    var divider = true
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.openURL) private var openURL
    @State private var on = DigestNotifications.enabled
    /// Notifications are off for the app in iOS Settings.
    @State private var denied = false

    var body: some View {
        // Whether McFly answers on this server (Availability, read after every load); nil: not known yet.
        let mcfly: Bool? = switch dashboard.availability.mcflyState {
        case .unknown: nil
        case .available: true
        case .notSetUp, .off: false
        }
        ProfileBlock("Notifications", divider: divider) {
            ProfileSwitch("Weekly digest", text: footer(mcfly: mcfly), isOn: toggle)
                .disabled(mcfly == false && !on)
                .accessibilityIdentifier("weeklyDigest")
            if denied {
                Button("Open notification settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
                .buttonStyle(ProfilePillStyle())
            }
        }
        .task {
            // Turned off in iOS Settings since: show it off, with the way back.
            if on, await DigestNotifications.denied() {
                DigestNotifications.disable()
                on = false
                denied = true
            }
        }
    }

    private var toggle: Binding<Bool> {
        Binding(get: { on }, set: { wanted in
            on = wanted
            denied = false
            Task {
                if wanted {
                    // The permission prompt shows the first time; a no turns the switch back off.
                    let scheduled = await DigestNotifications.enable()
                    on = scheduled
                    denied = !scheduled
                } else {
                    DigestNotifications.disable()
                }
            }
        })
    }

    private func footer(mcfly: Bool?) -> String {
        if denied { return "Notifications are off for healthOS. Allow them in the Settings app, then turn this on again." }
        if mcfly == false, !on { return "The weekly digest needs McFly set up on your healthOS server." }
        return "A reminder every Monday at 9:00 to read McFly's short recap of last week in Insights, under More."
    }
}

/// A line with a small icon before it, muted, or in the critical colour for something that went wrong.
private struct ProfileIconLine: View {
    let systemImage: String
    let text: String
    var bad = false

    init(_ systemImage: String, _ text: String, bad: Bool = false) {
        self.systemImage = systemImage
        self.text = text
        self.bad = bad
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage).imageScale(.small).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.app(.footnote))
        .foregroundStyle(bad ? Palette.critical : Palette.ink2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
