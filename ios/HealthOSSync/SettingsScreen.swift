import SwiftUI

/// Server, sign-in, and the Apple Health sync that feeds the dashboard.
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(Dashboard.self) private var dashboard
    @State private var confirmReupload = false
    @State private var confirmSample = false

    var body: some View {
        NavigationStack {
            // One section per view: a single Form builder this size is too slow for the Release type checker.
            Form {
                ServerSection()
                SyncSection()
                HealthSection()
                #if targetEnvironment(simulator)
                Section {
                    Button("Add sample Health data") { confirmSample = true }
                        .disabled(model.working)
                        .accessibilityIdentifier("addSampleData")
                } header: {
                    Text("Simulator")
                } footer: {
                    Text("Fake data for testing. Use a scratch server only, never your real dashboard.")
                }
                #endif
                Section {
                    Button("Upload all history again", role: .destructive) { confirmReupload = true }
                        .disabled(model.syncing)
                } footer: {
                    Text("Use this after clearing Apple Health data on the server, or after deleting old entries in Health.")
                }
            }
            .navigationTitle("Settings")
            .keyboardDismissal()
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
        }
        .onDisappear { Task { await dashboard.startIfNeeded() } }
    }

    private var noticeShown: Binding<Bool> {
        Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })
    }

    private var sampleWarning: String {
        let target = Config.serverURL(model.serverText)?.absoluteString ?? "the server you set"
        return "Two weeks of made-up data goes into this simulator's Health store, and the next sync uploads it to \(target) as real Apple Health data. Only continue if that's a scratch server."
    }
}

private struct ServerSection: View {
    @Environment(AppModel.self) private var model
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        @Bindable var model = model
        Section {
            TextField("https://health.mcfly.bot", text: $model.serverText)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { Task { await dashboard.start() } }
                .accessibilityIdentifier("serverURL")
            LabeledContent("Dashboard", value: accountText)
            if dashboard.phase == .signIn {
                Button("Sign in") { dashboard.tab = .today }
            } else if dashboard.authMode == "required", dashboard.phase == .ready {
                Button("Sign out", role: .destructive) { Task { await dashboard.signOut() } }
            }
        } header: {
            Text("Server")
        } footer: {
            Text("The dashboard reads from your healthOS server, which merges Apple Health with WHOOP.")
        }
    }

    private var accountText: String {
        switch dashboard.phase {
        case .starting: "Connecting…"
        case .noServer: "No server"
        case .signIn: "Signed out"
        case .unavailable: "Unavailable"
        case .ready:
            // A server with sign-in off reports a placeholder owner with no email.
            if dashboard.authMode == "required", let email = dashboard.account?.email, !email.isEmpty { "Signed in as \(email)" }
            else { dashboard.authMode == "required" ? "Signed in" : "Connected" }
        }
    }
}

private struct SyncSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            Button {
                Task { await model.syncAll() }
            } label: {
                HStack {
                    Text("Sync now").bold()
                    Spacer()
                    if model.syncingSources { ProgressView() }
                }
            }
            .disabled(model.syncingSources || !model.serverValid)
            .accessibilityIdentifier("syncNow")
            if model.syncingSources, !model.progress.isEmpty {
                Text(model.progress).font(.footnote).foregroundStyle(.secondary)
            }
            LastSyncRows(status: model.sources, report: model.last)
            SecureField("Ingest token", text: $model.token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .accessibilityIdentifier("token")
            Button("Test connection") { Task { await model.testConnection() } }
                .disabled(!model.serverValid || model.token.isEmpty || model.working)
        } header: {
            Text("Sync")
        } footer: {
            Text("One tap syncs both: this iPhone's Apple Health data goes to your account, and the server refreshes WHOOP. It also runs when you open the app. Get your ingest token on the dashboard under Integrations → iPhone app.")
        }
    }
}

private struct LastSyncRows: View {
    let status: SourcesSyncStatus?
    let report: SyncReport?

    var body: some View {
        if let status {
            LabeledContent("Last sync") {
                Text(status.finishedAt, format: .relative(presentation: .named))
            }
            Label(status.summary, systemImage: status.ok ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(status.ok ? Color.secondary : Color.red)
                .font(.footnote)
                .accessibilityIdentifier("lastResult")
            ForEach(status.notes, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
        } else if let report {
            // Before the first combined sync this launch: the last Apple Health push (possibly from the background).
            LabeledContent("Apple Health") {
                Text(report.finishedAt, format: .relative(presentation: .named))
            }
            Label(report.message, systemImage: report.ok ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(report.ok ? Color.secondary : Color.red)
                .font(.footnote)
        } else {
            LabeledContent("Last sync", value: "Never")
        }
    }
}

private struct HealthSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            if !model.healthRequested {
                Button("Allow Health access") { Task { await model.requestHealthAccess() } }
            }
            Toggle("Sync in the background", isOn: $model.backgroundSync)
            Picker("First upload covers", selection: $model.history) {
                ForEach(History.allCases) { Text($0.label).tag($0) }
            }
        } header: {
            Text("Health data")
        } footer: {
            Text("Background sync runs when Health gets new data, as often as iOS allows (hourly for steps). Health data can't be read while the phone is locked.")
        }
    }
}
