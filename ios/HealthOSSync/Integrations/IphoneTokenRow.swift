import SwiftUI

/// Set up this iPhone (the web's IphoneToken, G55): a token for the signed-in account, made on a tap and kept straight
/// in this iPhone's Keychain as that account's (IngestTokenOwner), then shown once with the server's address, for
/// another device. Revoke stops the account's token. Shown only signed in on a server with accounts.
///
/// Each account has one token and making one replaces it, so with one already made (another iPhone's, maybe) it asks
/// first, in the web's words.
struct IphoneTokenRow: View {
    let status: ServerStatus
    @Bindable var model: IntegrationsModel
    @Environment(Dashboard.self) private var dashboard
    @Environment(AppModel.self) private var sync: AppModel?

    var body: some View {
        // nil from a server older than the field: whether one exists isn't known, so neither line shows.
        let has = status.apple?.iphoneToken
        let busy = model.isBusy(.token)
        VStack(alignment: .leading, spacing: 10) {
            if has == true { Text(IntegrationsWords.tokenSet) } else if has == false { Text(IntegrationsWords.noToken) }
            if model.shown == nil, IntegrationsRules.phoneIsThisAccounts(hasToken: !(sync?.token ?? "").isEmpty,
                                                                        tokenOwner: dashboard.ingestOwner.account,
                                                                        signedIn: IntegrationsModel.account(dashboard)) {
                Text(IntegrationsWords.thisPhoneSetUp).accessibilityIdentifier("integrations.phoneIsSetUp")
            }
            if let shown = model.shown {
                Text(IntegrationsWords.tokenSavedHere + " " + IntegrationsWords.tokenShownOnce)
                field("Server") {
                    IntegrationsCopyField(value: shown.server, copyLabel: "Copy server address", field: "server", model: model)
                }
                field("Token") {
                    IntegrationsCopyField(value: shown.token, copyLabel: "Copy token", field: "token", secret: true, model: model)
                }
            } else {
                Text(IntegrationsWords.tokenScope)
            }
            WrapLayout(spacing: 8, lineSpacing: 8) {
                Button(IntegrationsWords.setUpPhone) {
                    if has == true { model.asking = .newToken } else { Task { await model.setUpThisPhone(dashboard) } }
                }
                .buttonStyle(.accentPill)
                .disabled(busy)
                .accessibilityIdentifier("integrations.setUpPhone")
                .confirmationDialog(IntegrationsWords.newTokenAsk, isPresented: model.isAsking(.newToken), titleVisibility: .visible) {
                    Button("Create a new token") { Task { await model.setUpThisPhone(dashboard) } }
                    Button("Cancel", role: .cancel) {}
                }
                if has == true {
                    Button("Revoke") { model.asking = .revokeToken }
                        .buttonStyle(IntegrationsQuietStyle())
                        .disabled(busy)
                        .accessibilityIdentifier("integrations.revokeToken")
                        .confirmationDialog(IntegrationsWords.revokeAsk, isPresented: model.isAsking(.revokeToken), titleVisibility: .visible) {
                            Button("Revoke", role: .destructive) { Task { await model.revoke(dashboard) } }
                            Button("Cancel", role: .cancel) {}
                        }
                }
                if busy { ProgressView().frame(minHeight: 44) }
            }
            if let error = model.tokenError { SourceProblem(text: error) }
        }
        .font(.app(.footnote))
        .foregroundStyle(Palette.ink2)
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface2, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.field, style: .continuous).strokeBorder(Palette.border))
    }

    /// A settings row (.settings-row): its name, then the value with its copy button.
    private func field(_ name: String, @ViewBuilder _ value: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.app(.caption, weight: .medium)).foregroundStyle(Palette.ink2)
            value()
        }
        .accessibilityElement(children: .contain)
    }
}
