import PhotosUI
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
                if dashboard.phase == .ready { PhotoSection() }
                // Servers with the Family board name the setting; it needs sign-in, so each person has their own account.
                if dashboard.phase == .ready, dashboard.status?.settings?.familySharing != nil, dashboard.authMode != "open" { FamilySection() }
                if dashboard.phase == .ready, let mode = dashboard.nutritionMode, mode != .none { NutritionTargetsSection(mode: mode) }
                SyncSection()
                HealthSection()
                if dashboard.phase == .ready || DigestNotifications.enabled { DigestSection() }
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
                Task { await model.syncAll(force: true) }
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
            if model.backfillLeft > 0 {
                Label("Sending older history: \(model.backfillLeft) day\(model.backfillLeft == 1 ? "" : "s") left. Continues while the app is open.", systemImage: "clock.arrow.circlepath")
                    .font(.footnote).foregroundStyle(.secondary)
            }
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

/// The person's own nutrition targets, each optional and blank by default, only while Nutrition is on with amounts
/// shown (calories only when those are shown too). A target is a plain line on the charts, never a score.
private struct NutritionTargetsSection: View {
    let mode: NutritionMode
    @Environment(Dashboard.self) private var dashboard
    /// What's being typed, by key; nil shows the server's value.
    @State private var drafts: [String: String] = [:]
    @State private var error: String?
    @FocusState private var focus: String?

    var body: some View {
        Section {
            ForEach(NutritionTargetField.all.filter { $0.key != "energy_kcal" || mode == .all }) { f in
                LabeledContent(f.label) {
                    HStack(spacing: 6) {
                        TextField("None", text: Binding(get: { drafts[f.key] ?? current(f.key) }, set: { drafts[f.key] = $0.filter(\.isNumber) }))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .focused($focus, equals: f.key)
                            .frame(maxWidth: 110)
                            .accessibilityLabel("\(f.label) target in \(f.unit)")
                            .accessibilityIdentifier("target-\(f.key)")
                        Text(f.unit).foregroundStyle(.secondary)
                    }
                }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        } header: {
            Text("Nutrition targets")
        } footer: {
            Text("Optional. Leave blank for none. A target you set shows as a plain line on your Nutrition charts, nothing more.")
        }
        // Saved when the field is left (or the keyboard's Done), like the web's on blur.
        .onChange(of: focus) { old, _ in
            if let old { commit(old) }
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
        // The server leaves a value out of range as it was, which would look saved: say so here instead.
        if let value, !field.range.contains(value) {
            error = "\(field.label): between \(Fmt.number(field.range.lowerBound)) and \(Fmt.number(field.range.upperBound)) \(field.unit), or blank for none."
            return
        }
        error = nil
        Task {
            do {
                try await dashboard.setNutritionTarget(key, value)
                drafts[key] = nil
            } catch {
                self.error = "Couldn't save: \(error.localizedDescription)"
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
}

/// The Family board: sharing is mutual, and a cycle phase can go on your tile while tracking and sharing are on.
/// The switches move at once and go back if the server says no.
private struct FamilySection: View {
    @Environment(Dashboard.self) private var dashboard
    /// What a switch shows while its change is on the way; nil shows the server's setting.
    @State private var pendingSharing: Bool?
    @State private var pendingPhase: Bool?
    @State private var error: String?

    var body: some View {
        let settings = dashboard.status?.settings
        let sharing = pendingSharing ?? settings?.familySharing ?? false
        Section {
            Toggle(isOn: Binding(get: { sharing }, set: { setSharing($0) })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Share with family")
                    Text(sharingNote(on: sharing)).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .disabled(pendingSharing != nil)
            .accessibilityIdentifier("familySharing")
            if settings?.cycleTracking == true, sharing {
                Toggle(isOn: Binding(get: { pendingPhase ?? settings?.shareCyclePhase ?? false }, set: { setPhase($0) })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Show my cycle phase to family")
                        Text("One word on your Family board tile (period, follicular or luteal), never dates or logs. Hidden as your next period approaches. Members will know you track your cycle, and looking day after day shows roughly when your period starts.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .disabled(pendingPhase != nil || pendingSharing != nil)
                .accessibilityIdentifier("shareCyclePhase")
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        } header: {
            Text("Family")
        } footer: {
            Text("Your Family board tile: last night's sleep, recovery or HRV, today's steps, resting heart rate and training load, the last 30 days of each, and how they compare with your own usual.")
        }
        // For "Sharing with: …"; the board keeps itself fresh while the Family tab is open.
        .task(id: settings?.familySharing == true) {
            if settings?.familySharing == true { await dashboard.loadFamily() }
        }
    }

    private func sharingNote(on: Bool) -> String {
        var note = "Members who share see your tile and its last 30 days. Turn it off and you see no one, and no one sees you."
        if on, let board = dashboard.familyBoard, board.sharing {
            let others = board.members.filter { !$0.isYou }.map(FamilyText.name)
            if !others.isEmpty { note += " Sharing with: \(others.joined(separator: ", "))." }
        }
        return note
    }

    private func setSharing(_ on: Bool) {
        pendingSharing = on
        error = nil
        Task {
            do {
                try await dashboard.setFamilySharing(on)
            } catch {
                self.error = "Couldn't change sharing. \(error.localizedDescription)"
            }
            pendingSharing = nil
        }
    }

    private func setPhase(_ on: Bool) {
        pendingPhase = on
        error = nil
        Task {
            do {
                try await dashboard.setShareCyclePhase(on)
            } catch {
                self.error = "Couldn't change your cycle phase sharing. \(error.localizedDescription)"
            }
            pendingPhase = nil
        }
    }
}

/// The Monday reminder for McFly's weekly digest on the Insights tab.
private struct DigestSection: View {
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.openURL) private var openURL
    @State private var on = DigestNotifications.enabled
    /// Notifications are off for the app in iOS Settings.
    @State private var denied = false
    /// McFly is set up on the server (nil: not known yet).
    @State private var mcfly: Bool?

    var body: some View {
        Section {
            Toggle("Weekly digest", isOn: toggle)
                .disabled(mcfly == false && !on)
                .accessibilityIdentifier("weeklyDigest")
                .task(id: dashboard.phase == .ready) { await check() }
            if denied {
                Button("Open notification settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text(footer)
        }
    }

    private var toggle: Binding<Bool> {
        Binding(get: { on }, set: { wanted in
            on = wanted
            denied = false
            Task {
                if wanted {
                    // The permission prompt shows the first time; a no turns the toggle back off.
                    let scheduled = await DigestNotifications.enable()
                    on = scheduled
                    denied = !scheduled
                } else {
                    DigestNotifications.disable()
                }
            }
        })
    }

    private var footer: String {
        if denied { return "Notifications are off for healthOS. Allow them in the Settings app, then turn this on again." }
        if mcfly == false, !on { return "The weekly digest needs McFly set up on your healthOS server." }
        return "A reminder every Monday at 9:00 to read McFly's short recap of last week on the Insights tab."
    }

    private func check() async {
        // Turned off in iOS Settings since: show it off, with the way back.
        if on, await DigestNotifications.denied() {
            DigestNotifications.disable()
            on = false
            denied = true
        }
        // Only while signed in: a 401 here would drop the session.
        if dashboard.phase == .ready, let client = APIClient.current(), let status = try? await client.mcflyStatus() {
            mcfly = status.available
        }
    }
}

/// Change the profile photo from the phone: pick one, process it here with Vision, preview, then upload.
private struct PhotoSection: View {
    @Environment(Dashboard.self) private var dashboard
    @State private var item: PhotosPickerItem?
    @State private var processing = false
    @State private var result: PhotoCutout?
    @State private var error: String?

    var body: some View {
        let label = dashboard.status?.photo == nil ? "Add photo" : "Change photo"
        Section {
            HStack(spacing: 14) {
                Avatar(photo: dashboard.status?.photo, name: dashboard.summary?.name, size: 48)
                PhotosPicker(selection: $item, matching: .images, photoLibrary: .shared()) {
                    Text(label)
                }
                .disabled(processing)
                Spacer()
                if processing { ProgressView() }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        } header: {
            Text("Profile photo")
        } footer: {
            Text("A portrait with your face and shoulders works best. It's cut out on this iPhone; only the result is uploaded.")
        }
        .onChange(of: item) { _, picked in
            guard let picked else { return }
            Task { await process(picked) }
        }
        .sheet(item: Binding(get: { result.map(PreviewItem.init) }, set: { if $0 == nil { result = nil } })) { preview in
            PhotoPreview(photo: preview.photo) {
                result = nil
                await dashboard.load()
            }
        }
    }

    private func process(_ picked: PhotosPickerItem) async {
        processing = true
        error = nil
        defer {
            processing = false
            item = nil
        }
        do {
            guard let data = try await picked.loadTransferable(type: Data.self) else { throw PhotoCutout.Failure(message: "Couldn't load that photo.") }
            result = try await Task.detached(priority: .userInitiated) { try PhotoCutout.process(data) }.value
        } catch {
            self.error = error.localizedDescription
        }
    }

    private struct PreviewItem: Identifiable {
        let photo: PhotoCutout
        let id = UUID()
    }
}

/// The processed photo before it's saved, as on the web: Save uploads it, Cancel drops it.
private struct PhotoPreview: View {
    let photo: PhotoCutout
    let saved: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(uiImage: UIImage(cgImage: photo.cutout))
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 420)
                    .accessibilityLabel("Your cut-out photo")
                Image(uiImage: UIImage(cgImage: photo.avatar))
                    .resizable()
                    .frame(width: 72, height: 72)
                    .clipShape(Circle())
                    .accessibilityLabel("Your avatar")
                if let error { Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center) }
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.page)
            .navigationTitle("New photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else { Button("Save") { Task { await save() } }.bold() }
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private func save() async {
        guard let client = APIClient.current() else { return }
        saving = true
        defer { saving = false }
        do {
            try await client.uploadPhoto(photo)
            await saved()
            dismiss()
        } catch APIError.server(404, _) {
            error = "This server can't take photos from the app yet. Update healthOS, or use the website."
        } catch APIError.server(413, _) {
            error = "That photo is too large to upload. Try another one."
        } catch {
            self.error = error.localizedDescription
        }
    }
}
