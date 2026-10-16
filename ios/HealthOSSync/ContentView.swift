import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()
    @State private var confirmReupload = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://health.mcfly.bot", text: $model.serverText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("serverURL")
                    SecureField("Ingest token", text: $model.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("token")
                    Button("Test connection") { Task { await model.testConnection() } }
                        .disabled(!model.serverValid || model.token.isEmpty || model.working)
                } header: {
                    Text("Server")
                } footer: {
                    Text("Your healthOS address and its ingest token (HEALTHOS_INGEST_TOKEN on the server).")
                }

                Section {
                    Button {
                        Task { await model.syncNow() }
                    } label: {
                        HStack {
                            Text("Sync now").bold()
                            Spacer()
                            if model.syncing { ProgressView() }
                        }
                    }
                    .disabled(model.syncing || !model.serverValid || model.token.isEmpty)
                    .accessibilityIdentifier("syncNow")
                    if model.syncing, !model.progress.isEmpty {
                        Text(model.progress).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let last = model.last {
                        LabeledContent("Last sync") {
                            Text(last.finishedAt, format: .relative(presentation: .named))
                        }
                        Label(last.message, systemImage: last.ok ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(last.ok ? Color.secondary : Color.red)
                            .font(.footnote)
                            .accessibilityIdentifier("lastResult")
                    } else {
                        LabeledContent("Last sync", value: "Never")
                    }
                }

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

                #if targetEnvironment(simulator)
                Section("Simulator") {
                    Button("Add sample Health data") { Task { await model.addSampleData() } }
                        .disabled(model.working)
                        .accessibilityIdentifier("addSampleData")
                }
                #endif

                Section {
                    Button("Upload all history again", role: .destructive) { confirmReupload = true }
                        .disabled(model.syncing)
                } footer: {
                    Text("Use this after clearing Apple Health data on the server, or after deleting old entries in Health.")
                }
            }
            .navigationTitle("healthOS Sync")
            .alert(model.notice ?? "", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
                Button("OK", role: .cancel) {}
            }
            .confirmationDialog("Upload all history again?", isPresented: $confirmReupload, titleVisibility: .visible) {
                Button("Upload all history") { Task { await model.uploadAllHistory() } }
            } message: {
                Text("Every day back to \"\(model.history.label)\" is read from Health and sent again. Nothing is deleted.")
            }
        }
    }
}
