import SwiftUI

#if DEBUG
/// Debug only, `-duoTestPage YES`: a page with a DuoGrid, a DuoPair, a DuoPanes with a text field and a + sheet, a
/// SheetScaffold sheet with a focused field, and a floating row, so G4–G6 can run before the wave pages exist. It needs
/// no server and no sign-in. It shows in place of the app (RootView), in a tab bar of its own, so the vertical bar has
/// tabs in it as the app's does. Every control has an identifier under `duoTest.` for the kit's scripts; tabs are
/// selected by label (P13): "Test" and "Other".
struct DuoTestPage: View {
    /// Launched with `-duoTestPage YES`.
    static var requested: Bool { UserDefaults.standard.bool(forKey: "duoTestPage") }

    var body: some View {
        TabView {
            NavigationStack {
                DuoTestContent()
                    .navigationTitle("Duo test")
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationDestination(for: String.self) { _ in DuoTestPanes().navigationTitle("Panes") }
            }
            .tabItem { Label("Test", systemImage: "square.split.2x1") }
            NavigationStack {
                Text("The other tab").navigationTitle("Other")
            }
            .tabItem { Label("Other", systemImage: "circle") }
        }
    }
}

/// The test page's own content: what drawn tests host (DuoKitTests) and what `-duoTestPage` shows.
struct DuoTestContent: View {
    @State private var typed = ""
    @State private var sheetOpen = false
    @State private var bareSheetOpen = false

    var body: some View {
        DuoPage { band in
            DuoScroll {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Band: \(String(describing: band))")
                        .font(.app(.footnote))
                        .foregroundStyle(Palette.ink2)
                        .accessibilityIdentifier("duoTest.band")
                    DuoGrid(1...5, id: \.self) { n in
                        DuoTestCard(title: "Card \(n)", id: "duoTest.card.\(n)")
                    }
                    DuoPair {
                        DuoTestCard(title: "Pair first", id: "duoTest.pair.first")
                    } second: {
                        DuoTestCard(title: "Pair second", id: "duoTest.pair.second", tall: true)
                    }
                    Button { sheetOpen = true } label: {
                        Text("Open the sheet").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.accentPill)
                    .accessibilityIdentifier("duoTest.openSheet")
                    .duoOneSide()
                    // A plain system sheet with a field, no SheetScaffold: what a fold does to a sheet's focus without
                    // the scaffold (G4(f)'s comparison).
                    Button { bareSheetOpen = true } label: {
                        Text("Open a plain sheet").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .accessibilityIdentifier("duoTest.openBareSheet")
                    .duoOneSide()
                    TextField("Type here", text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("duoTest.field")
                        .duoOneSide()
                    NavigationLink(value: "panes") {
                        Text("Two panes").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .accessibilityIdentifier("duoTest.panes")
                    .duoOneSide()
                    ForEach(1...12, id: \.self) { n in
                        Text("Row \(n)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                            .id("duoTest.row.\(n)")
                    }
                }
                .padding(.vertical, 16)
            }
        }
        .background(Palette.page.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            DuoFloatingRow {
                Button("Floating") {}
                    .buttonStyle(.accentPill)
                    .accessibilityIdentifier("duoTest.floating")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .sheet(isPresented: $sheetOpen) { DuoTestSheet() }
        .sheet(isPresented: $bareSheetOpen) { DuoBareSheet() }
    }
}

/// A card that's a button, as healthOS's cards are.
private struct DuoTestCard: View {
    let title: String
    let id: String
    var tall = false
    @Environment(\.duoBand) private var band

    var body: some View {
        Button {} label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.app(.headline)).foregroundStyle(Palette.ink)
                Text("band \(String(describing: band))").font(.app(.footnote)).foregroundStyle(Palette.ink2)
                if tall { Text("A second line, so this half is the taller one.").font(.app(.footnote)).foregroundStyle(Palette.ink3) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .card()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

/// A sheet with a field focused as it opens (G4(f)).
private struct DuoTestSheet: View {
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        SheetScaffold(eyebrow: "Duo test", title: "A sheet") {
            TextField("Type in the sheet", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .accessibilityIdentifier("duoTest.sheetField")
            Text("Typed: \(text.count) characters").accessibilityIdentifier("duoTest.sheetCount")
        }
        .onAppear { focused = true }
    }
}

/// A plain sheet with one field and no SheetScaffold (G4(f)'s comparison).
private struct DuoBareSheet: View {
    @State private var text = ""

    /// `-duoBareSheet <variant>`: what the sheet adds of SheetScaffold's, one piece at a time: `detents` (its
    /// `.presentationDetents([.large])`), `scope` (its DuoScope), `scaffold` (the whole SheetScaffold, with no
    /// FocusState); `scaffoldFocus`, `scaffoldFocusOnAppear` and `focusOnAppear` add a FocusState (set by a tap, or as the
    /// sheet appears). Nothing by default.
    private var variant: String { UserDefaults.standard.string(forKey: "duoBareSheet") ?? "" }

    var body: some View {
        switch variant {
        case "detents": column.presentationDetents([.large])
        case "scope": DuoScope(.sheet(maxWidth: 650, padding: 18)) { _ in ScrollView { column } }
        case "scaffold": SheetScaffold(title: "A plain sheet") { field }
        case "scaffoldFocus": SheetScaffold(title: "A plain sheet") { field.focused($focused) }
        case "scaffoldFocusOnAppear": SheetScaffold(title: "A plain sheet") { field.focused($focused) }.onAppear { focused = true }
        case "focusOnAppear": column.focused($focused).onAppear { focused = true }
        default: column
        }
    }

    @FocusState private var focused: Bool

    private var field: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Type in the plain sheet", text: $text)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("duoTest.bareField")
            Text("Typed: \(text.count) characters").accessibilityIdentifier("duoTest.bareCount")
        }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 14) {
            field
            Spacer()
        }
        .padding(18)
    }
}

/// Two panes (G5): a text field and a + in the leading pane, detail in the trailing one. The typed text and the +
/// sheet live here, above the panes (P4), so a swap keeps them.
struct DuoTestPanes: View {
    @State private var typed = ""
    @State private var plusOpen = false

    var body: some View {
        DuoPage { _ in
            DuoPanes {
                primary
            } secondary: {
                secondary
            } single: {
                primary
                secondary
            }
        }
        .background(Palette.page.ignoresSafeArea())
        .sheet(isPresented: $plusOpen) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Add").font(.app(.headline)).padding(16)
                Button("Close") { plusOpen = false }.padding(16).accessibilityIdentifier("duoTest.plusClose")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .duoMenuSheet(height: 140)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Duo test menu")
        }
    }

    private var primary: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Primary pane").font(.app(.headline)).accessibilityIdentifier("duoTest.primary")
            TextField("Type in the pane", text: $typed)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("duoTest.paneField")
            Button { plusOpen = true } label: { Label("Add", systemImage: "plus") }
                .accessibilityIdentifier("duoTest.plus")
            Text("Typed: \(typed.count) characters").accessibilityIdentifier("duoTest.paneCount")
        }
        .padding(.vertical, 16)
    }

    private var secondary: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Secondary pane").font(.app(.headline)).accessibilityIdentifier("duoTest.secondary")
            ForEach(1...6, id: \.self) { n in
                Button("Detail \(n)") {}.accessibilityIdentifier("duoTest.detail.\(n)")
            }
        }
        .padding(.vertical, 16)
    }
}
#endif
