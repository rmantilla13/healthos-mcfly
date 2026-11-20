import SwiftUI
import UIKit

// The web's source cards (src/pages/Integrations.tsx, src/styles/integrations.css): each a letter tile, its name and a
// state chip, what it brings, then its pills and a footnote along the bottom. The pills wrap onto more rows rather than
// being cut off, and at the accessibility text sizes their words wrap too.

/// One source: its letter tile, name and state, what it brings, then its actions and a footnote (SourceCard).
struct SourceCard<Content: View, Actions: View, Foot: View>: View {
    let tile: String
    let title: String
    let chip: IntegrationsRules.Chip?
    var showsEnd = true
    /// False when the card has no buttons now: its footnote then sits alone at the bottom, as the web's.
    var showsActions = true
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions
    @ViewBuilder var foot: Foot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tile)
                .font(.app(size: 11, weight: .semibold, relativeTo: .caption2))
                .foregroundStyle(Palette.ink)
                .padding(6)
                .frame(minWidth: 36, minHeight: 36)
                .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Palette.cardEdge))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 9) {
                Text(title)
                    .font(.app(.subheadline, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let chip { SourceChip(chip: chip) }
            }
            .padding(.top, 18)
            VStack(alignment: .leading, spacing: 8) { content }
                .font(.app(.footnote))
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            if showsEnd {
                VStack(alignment: .leading, spacing: 12) {
                    if showsActions { WrapLayout(spacing: 8, lineSpacing: 8) { actions } }
                    foot
                }
                .padding(.top, 22)
            }
        }
        // Beside another card on the open Duo, as tall as its row.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }
}

/// The state chip (.badge.source-chip): Badge's colours, its words wrapping at the largest text sizes instead of
/// being cut off ("Needs a developer app" at AX5 on a phone).
struct SourceChip: View {
    let chip: IntegrationsRules.Chip

    var body: some View {
        Text(chip.text)
            .font(.app(size: 11, weight: .medium, relativeTo: .caption2))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(chip.tone.ink)
            .background(chip.tone.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A status line under a card's description (.source-state): when it last synced, what an import covered.
struct SourceState: View {
    let text: String
    var body: some View { Text(text).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true) }
}

/// A footnote along a card's bottom (.source-foot).
struct SourceFoot: View {
    let text: String
    var body: some View {
        Text(text).font(.app(.caption)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
    }
}

/// A refusal or failure in a card (.note-bad), read out as it shows.
struct SourceProblem: View {
    let text: String
    var body: some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "exclamationmark.triangle") }
            .font(.app(.footnote))
            .foregroundStyle(Palette.critical)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// The web's .btn-quiet for Disconnect and the Remove buttons: its words only, in the muted ink, ink while pressed, with
/// a full-size place to tap. Integrations' own, by name (Home, Profile and others have theirs).
struct IntegrationsQuietStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.app(.subheadline, weight: .medium))
            .foregroundStyle(configuration.isPressed ? Palette.ink : Palette.ink3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// A disclosure that opens in place (.source-more): its words and a chevron that turns.
struct SourceMore<Content: View>: View {
    let title: String
    @Binding var open: Bool
    var id: String
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { open.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(title).font(.app(.footnote, weight: .medium)).foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.ink2)
                        .rotationEffect(.degrees(open ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "Open" : "Closed")
            .accessibilityIdentifier(id)
            if open { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A value with a copy button beside it (CopyField): a redirect URL, the server's address, the token shown once.
struct IntegrationsCopyField: View {
    let value: String
    let copyLabel: String
    let field: String
    var secret = false
    @Bindable var model: IntegrationsModel

    var body: some View {
        let copied = model.copied == field
        HStack(alignment: .center, spacing: 6) {
            Text(value)
                .font(.app(size: 11.5, relativeTo: .caption))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                // A secret isn't read out or written into the accessibility tree: Copy takes it.
                .accessibilityLabel(secret ? Text("\(fieldName), shown only now") : Text(value))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.copy(value, field: field, secret: secret) } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.ink2)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copied ? "Copied" : copyLabel)
            .accessibilityIdentifier("integrations.copy.\(field)")
        }
    }

    private var fieldName: String { field.prefix(1).uppercased() + field.dropFirst() }
}

/// The ?whoop= banner after WHOOP's sign-in (.banner-good, .banner-bad).
struct IntegrationsBanner: View {
    let text: String
    let good: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: good ? "checkmark" : "exclamationmark.triangle").accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.app(.footnote, weight: .medium))
        .foregroundStyle(good ? Palette.goodText : Palette.bannerBadInk)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(good ? Palette.bannerGoodBg : Palette.bannerBadBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - WHOOP

struct WhoopCard: View {
    let status: ServerStatus
    let whoop: ServerStatus.Whoop
    @Bindable var model: IntegrationsModel
    @Environment(Dashboard.self) private var dashboard

    private var hosted: Bool { status.hosted ?? true }
    private var admin: Bool { status.user?.role == "admin" }

    var body: some View {
        let busy = model.isBusy(.whoop)
        let syncing = whoop.syncing == true
        SourceCard(tile: "W", title: "WHOOP", chip: IntegrationsRules.whoopChip(whoop, hosted: hosted, admin: admin),
                   showsEnd: whoop.connected == true || whoop.configured == true) {
            Text(IntegrationsWords.whoopBody)
            if let state = IntegrationsRules.whoopState(whoop, hosted: hosted) {
                SourceState(text: state).accessibilityAddTraits(.updatesFrequently)
            }
            if whoop.configured == true, whoop.connected != true {
                SourceState(text: IntegrationsWords.whoopAway)
                SourceState(text: IntegrationsWords.whoopInSafari)
            }
            if whoop.configured != true, hosted {
                SourceState(text: admin ? IntegrationsWords.whoopAdminSetup : IntegrationsWords.whoopMemberOff)
            }
            if whoop.configured != true, !hosted {
                SourceMore(title: IntegrationsWords.whoopDeveloperApp, open: $model.whoopStepsOpen, id: "integrations.whoopSteps") { steps }
            }
            if let error = whoop.lastError, !error.isEmpty { SourceProblem(text: IntegrationsWords.whoopLastError(error)) }
            if let error = model.whoopError { SourceProblem(text: error) }
        } actions: {
            if whoop.connected == true {
                Button { Task { await model.whoopSyncNow(dashboard) } } label: {
                    Label(syncing ? "Syncing…" : "Sync now", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.quietPill)
                .disabled(syncing || busy)
                .accessibilityIdentifier("integrations.whoopSync")
                Button("Re-sync full year") { Task { await model.whoopFullYear(dashboard) } }
                    .buttonStyle(.quietPill)
                    .disabled(syncing || busy)
                    .accessibilityIdentifier("integrations.whoopFull")
                Button("Disconnect") { Task { await model.whoopDisconnect(dashboard) } }
                    .buttonStyle(IntegrationsQuietStyle())
                    .disabled(busy)
                    .accessibilityIdentifier("integrations.whoopDisconnect")
            } else if whoop.configured == true {
                Button("Connect WHOOP") { connect() }
                    .buttonStyle(.quietPill)
                    .accessibilityHint("Opens healthOS in Safari")
                    .accessibilityIdentifier("integrations.whoopConnect")
            }
        } foot: {
            EmptyView()
        }
    }

    /// Real Safari, not the app's sheet: the connection needs the web's own session, and Safari may have one already.
    private func connect() {
        guard let base = Config.serverURL(), let url = IntegrationsRules.connectURL(server: base) else { return }
        UIApplication.shared.open(url)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 10) {
            // One sentence that wraps, its link opened in Safari.
            step(1) { Text(.init("Sign in at [developer.whoop.com](https://developer.whoop.com) " + IntegrationsWords.whoopStepSignIn)) }
            step(2) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(IntegrationsWords.whoopStepRedirect)
                    if let uri = whoop.redirectUri, !uri.isEmpty {
                        IntegrationsCopyField(value: uri, copyLabel: "Copy redirect URL", field: "redirect", model: model)
                    }
                }
            }
            step(3) { Text(IntegrationsWords.whoopStepScopes) }
            step(4) { Text(IntegrationsWords.whoopStepEnv) }
        }
        .font(.app(.footnote))
        .foregroundStyle(Palette.ink2)
    }

    private func step(_ n: Int, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n).").foregroundStyle(Palette.ink3).accessibilityHidden(true)
            content().fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - WHOOP strap with NOOP

/// A WHOOP strap read by the NOOP app (Integrations.tsx NoopCard). NOOP's export is a .zip read in the browser, so
/// Import opens the website's Integrations in Safari, where Files offers the .zip NOOP saved; Remove works from here.
struct NoopCard: View {
    let noop: ServerStatus.Noop
    @Bindable var model: IntegrationsModel
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let last = noop.lastImport
        SourceCard(tile: "N", title: IntegrationsWords.noopTitle, chip: IntegrationsRules.noopChip(noop)) {
            Text(IntegrationsWords.noopBody)
            if let state = IntegrationsRules.noopState(noop) { SourceState(text: state) }
            SourceState(text: IntegrationsWords.noopInSafari)
            if let error = model.noopError { SourceProblem(text: error) }
        } actions: {
            Button(last != nil ? "Import again" : "Import NOOP export") { openImport() }
                .buttonStyle(.quietPill)
                .accessibilityHint("Opens healthOS in Safari")
                .accessibilityIdentifier("integrations.noopImport")
            if last != nil {
                Button("Remove NOOP data") { model.asking = .removeNoop }
                    .buttonStyle(IntegrationsQuietStyle())
                    .disabled(model.isBusy(.noopRemove))
                    .accessibilityIdentifier("integrations.noopRemove")
                    // P10: on the button that opens it, its anchor at regular width.
                    .confirmationDialog(IntegrationsWords.noopRemoveAsk, isPresented: model.isAsking(.removeNoop), titleVisibility: .visible) {
                        Button("Remove NOOP data", role: .destructive) { Task { await model.removeNoop(dashboard) } }
                        Button("Cancel", role: .cancel) {}
                    }
            }
        } foot: {
            // The web's foot, its link to NOOP opened in Safari.
            Text(.init("[NOOP](\(IntegrationsWords.noopLink)) " + IntegrationsWords.noopFoot))
                .font(.app(.caption)).foregroundStyle(Palette.ink3).tint(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Real Safari, as Connect WHOOP: the import needs the web's session, and Safari's file picker reaches Files.
    private func openImport() {
        guard let base = Config.serverURL(), let url = IntegrationsRules.connectURL(server: base) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Fitbit / Google Health

struct FitbitCard: View {
    let fitbit: ServerStatus.Fitbit
    @Bindable var model: IntegrationsModel
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let last = fitbit.lastImport
        SourceCard(tile: "G", title: IntegrationsWords.fitbitTitle, chip: IntegrationsRules.fitbitChip(fitbit)) {
            Text(IntegrationsWords.fitbitBody)
            if let state = IntegrationsRules.fitbitState(fitbit) { SourceState(text: state) }
            if let error = model.fitbitError { SourceProblem(text: error) }
        } actions: {
            Button(last != nil ? "Import again" : "Import Fitbit data") { model.fitbitOpen = true }
                .buttonStyle(.quietPill)
                .accessibilityIdentifier("integrations.fitbitImport")
            if last != nil {
                Button("Remove Fitbit data") { model.asking = .removeFitbit }
                    .buttonStyle(IntegrationsQuietStyle())
                    .disabled(model.isBusy(.fitbitRemove))
                    .accessibilityIdentifier("integrations.fitbitRemove")
                    // P10: on the button that opens it, its anchor at regular width.
                    .confirmationDialog(IntegrationsWords.fitbitRemoveAsk, isPresented: model.isAsking(.removeFitbit), titleVisibility: .visible) {
                        Button("Remove Fitbit data", role: .destructive) { Task { await model.removeFitbit(dashboard) } }
                        Button("Cancel", role: .cancel) {}
                    }
            }
        } foot: {
            SourceFoot(text: IntegrationsWords.fitbitFoot)
        }
    }
}

// MARK: - Apple Watch / Health

struct AppleCard: View {
    let status: ServerStatus
    @Bindable var model: IntegrationsModel
    @Environment(Dashboard.self) private var dashboard

    private var hosted: Bool { status.hosted ?? true }

    var body: some View {
        let apple = status.apple
        let busy = IntegrationsRules.appleBusy(apple)
        SourceCard(tile: "⌘", title: IntegrationsWords.appleTitle, chip: IntegrationsRules.appleChip(apple),
                   showsActions: IntegrationsRules.showsRemoveApple(apple)) {
            Text(IntegrationsWords.appleBody)
            SourceState(text: IntegrationsWords.appleExportOnMac + (hosted && status.user?.role == "admin" ? " " + IntegrationsWords.appleAdminImport : ""))
            if let line = IntegrationsRules.appleImportState(apple) { SourceState(text: line) }
            if busy {
                SourceState(text: apple?.job?.state == "uploading" ? IntegrationsWords.appleUploading
                            : IntegrationsWords.appleReading(Int(apple?.job?.records ?? 0).formatted()))
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if IntegrationsRules.appleStale(apple, hosted: hosted) { SourceState(text: IntegrationsWords.appleStale) }
            if let error = model.appleError { SourceProblem(text: error) }
        } actions: {
            if IntegrationsRules.showsRemoveApple(apple) {
                Button("Remove Apple Health data") { model.asking = .removeApple }
                    .buttonStyle(IntegrationsQuietStyle())
                    .disabled(model.isBusy(.appleRemove))
                    .accessibilityIdentifier("integrations.appleRemove")
                    .confirmationDialog(IntegrationsWords.appleRemoveAsk, isPresented: model.isAsking(.removeApple), titleVisibility: .visible) {
                        Button("Remove Apple Health data", role: .destructive) { Task { await model.removeAppleHealth(dashboard) } }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(IntegrationsWords.appleRemoveResends)
                    }
            }
        } foot: {
            if !IntegrationsRules.phone(apple) { SourceFoot(text: IntegrationsWords.appleNotSetUp) }
            if let synced = apple?.lastSync?.syncedAt, let ago = IntegrationsWords.ago(synced) {
                SourceFoot(text: IntegrationsWords.appleSynced(ago))
            }
            if IntegrationsRules.showsPhoneSetup(authMode: dashboard.authMode, phase: dashboard.phase) {
                SourceMore(title: IntegrationsWords.setUpPhone, open: $model.phoneSetupOpen, id: "integrations.phoneSetup") {
                    IphoneTokenRow(status: status, model: model)
                }
            }
        }
    }
}

// MARK: - The note and the demo card

struct SourcesNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(IntegrationsWords.noteTitle)
                .font(.app(.subheadline, weight: .medium))
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            Text(IntegrationsWords.note)
                .font(.app(.footnote))
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// Demo data (local, the owner only): Automatic, Always or Off, saved at once and read again.
struct DemoCard: View {
    let status: ServerStatus
    @Bindable var model: IntegrationsModel
    @Environment(Dashboard.self) private var dashboard

    var body: some View {
        let mode = status.settings?.demo
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(IntegrationsWords.demoTitle)
                    .font(.app(.subheadline, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(IntegrationsWords.demoLine(showing: status.demo == true))
                    .font(.app(.footnote))
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // One row where it fits; at the largest text sizes the choices wrap inside the well (as RangeFilters).
            ViewThatFits(in: .horizontal) {
                well(HStack(spacing: 0) { choices(mode) }).fixedSize()
                well(WrapLayout(spacing: 0, lineSpacing: 0) { choices(mode) }).fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.demoError { SourceProblem(text: error) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func choices(_ mode: String?) -> some View {
                ForEach(IntegrationsWords.demoModes, id: \.value) { choice in
                    let on = mode == choice.value
                    Button(choice.title) { Task { await model.setDemo(choice.value, dashboard) } }
                        .buttonStyle(.plain)
                        .font(.app(size: 13, weight: .medium, relativeTo: .footnote))
                        .foregroundStyle(on ? Palette.ink : Palette.ink2)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.surface)
                                    .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                        .disabled(model.isBusy(.demo))
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .accessibilityIdentifier("integrations.demo.\(choice.value)")
                }
    }

    private func well(_ choices: some View) -> some View {
        choices
            .padding(3)
            .background(Palette.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(IntegrationsWords.demoTitle)
    }
}

extension IntegrationsModel {
    /// A confirmation dialog's binding to the model's one question: up while it's this one, and closing it forgets it.
    func isAsking(_ question: Question) -> Binding<Bool> {
        Binding(get: { self.asking == question }, set: { up in
            if up { self.asking = question } else if self.asking == question { self.asking = nil }
        })
    }
}
