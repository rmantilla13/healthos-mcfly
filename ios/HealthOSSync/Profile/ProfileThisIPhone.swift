import SwiftUI

/// What only the iPhone has, under the web's Profile: the server it reads from (reachable before sign-in, so the
/// address can be changed from the sign-in screen), the Apple Health sync and its ingest token, Health access and
/// background sync, the weekly digest reminder, the simulator's sample data, and sending all history again. Drawn
/// with Profile's own rows, in the web's ink.
struct ProfileThisIPhone: View {
    let confirmSample: () -> Void
    let confirmReupload: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        ProfileCard("This iPhone") {
            ProfileServerRow()
            ProfileSyncRow()
            ProfileHealthRow()
            if dashboard.phase == .ready || DigestNotifications.enabled { ProfileDigestRow() }
            #if targetEnvironment(simulator)
            ProfileBlock("Simulator") {
                ProfileFine("Fake data for testing. Use a scratch server only, never your real dashboard.")
                Button("Add sample Health data", action: confirmSample)
                    .buttonStyle(.quietPill(size: .compact))
                    .disabled(model.working)
                    .accessibilityIdentifier("addSampleData")
            }
            #endif
            ProfileBlock("Upload all history again", divider: false) {
                ProfileFine("Use this after clearing Apple Health data on the server, or after deleting old entries in Health.")
                Button("Upload all history again", role: .destructive, action: confirmReupload)
                    .buttonStyle(ProfileDangerStyle())
                    .disabled(model.syncing)
                    .accessibilityIdentifier("uploadAgain")
            }
        }
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
    @Environment(AppModel.self) private var model
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        @Bindable var model = model
        ProfileBlock("Server") {
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
                    .buttonStyle(.accentPill(size: .compact))
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
    @Environment(AppModel.self) private var model
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        @Bindable var model = model
        ProfileBlock("Sync") {
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
                    .buttonStyle(.accentPill(size: .compact))
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
                .buttonStyle(.quietPill(size: .compact))
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
            HStack {
                Text("Last sync")
                Spacer()
                Text("Never").foregroundStyle(Palette.ink3)
            }
            .font(.app(.footnote))
            .foregroundStyle(Palette.ink2)
        }
    }

    private func when(_ title: String, _ date: Date) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(date, format: .relative(presentation: .named)).foregroundStyle(Palette.ink3)
        }
        .font(.app(.footnote))
        .foregroundStyle(Palette.ink2)
        .accessibilityElement(children: .combine)
    }
}

private struct ProfileHealthRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ProfileBlock("Health data") {
            if !model.healthRequested {
                Button("Allow Health access") { Task { await model.requestHealthAccess() } }
                    .buttonStyle(.accentPill(size: .compact))
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
        ProfileBlock("Notifications") {
            ProfileSwitch("Weekly digest", text: footer(mcfly: mcfly), isOn: toggle)
                .disabled(mcfly == false && !on)
                .accessibilityIdentifier("weeklyDigest")
            if denied {
                Button("Open notification settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.quietPill(size: .compact))
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
