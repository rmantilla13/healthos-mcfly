import SwiftUI
import UIKit

// iPhone Duo (D0 of the Duo design): the keyboard's Done. On iOS 27.1, the release only iPhone Duo runs, the
// keyboard's bar item group (a flexible space, then Done) sent healthOS's main thread into a layout cycle on the sign-in
// form, the welcome frame with its bars hidden, as soon as the accessibility tree was read with the keyboard up (seen
// with UI tests): SwiftUI sized the bar item forever. Profile and its sheets didn't hang. So on 27.1 Done goes up
// without that group, on every screen. Before 27.1 nothing changes. This is the only place that looks at the iOS version
// for it: `keyboardDismissal()` (Dashboard/Keyboard.swift) uses it, and pages use `keyboardDismissal()`.
//
// Where Done sits on 27.1 (the shell stage, gates.md G0): F0's Done alone is drawn centred over the keyboard. The other
// shapes below were each tried live on HOS Duo against the hang (the accessibility tree read with the keyboard up on the
// sign-in screen, closed and open). `shape(on:)` gives 27.1 the one that was kept; the rest stay, Debug-only, behind
// `-duoKeyboardShape <shape>`, for G0's control run and for anyone who has to try again on a later release.

/// The Done button above the keyboard, which closes it (URL, number and code keyboards have no other obvious way out).
struct DuoKeyboardDone: ToolbarContent {
    /// How Done sits above the keyboard.
    enum Shape: String, Equatable, CaseIterable {
        /// Before iOS 27.1: a flexible space, then Done, at the trailing end of the bar over the keyboard. On 27.1 this is
        /// the group that hung (G0).
        case spacerThenDone
        /// F0's shape, kept for 27.1 until build 23's check: Done alone, with no flexible space. The bar centres it. No
        /// hang, but centred is where the open Duo's fold is: flat, Done sat at x 401–466 against a fold at 455.5–495.5,
        /// and half-open still inside the fold's 12 pt clearance (D10). Debug-only since (`-duoKeyboardShape doneAlone`).
        case doneAlone
        /// iOS 27.1 (design §0.1, fix 2): no Done in the keyboard's bar at all, so nothing the system places can land on
        /// the fold. Tap-to-dismiss (`KeyboardDismisser`) and the interactive scroll dismissal stay, every field with a
        /// return key closes with it, and the number pads (no return key) put up a Done of their own beside the field
        /// while it's focused (`duoFieldDone(_:)`), where the page lays it out, on the field's side of the fold.
        case besideTheField
        /// iOS 26's own toolbar spacer (`ToolbarSpacer(.flexible, placement: .keyboard)`), then Done as an item of its own.
        /// G0: no hang, but the spacer collapses in the Duo's keyboard bar and Done stays centred.
        case toolbarSpacerThenDone
        /// One item holding a row: a SwiftUI Spacer, then Done, inside the item. G0: no hang; centred (sized to fit).
        case doneInTrailingRow
        /// The old group (Spacer, then Done), marked horizontal-only (`axisBehavior(.horizontalOnly)`, iOS 27.1). G0: hangs.
        case spacerThenDoneHorizontalOnly
        /// One item: Done in a frame as wide as the bar offers, aligned trailing. G0: no hang; centred.
        case doneInWideFrame
        /// An empty item with no background, iOS 26's toolbar spacer, then Done: the spacer has an item on each side.
        /// G0: no hang; the pair is centred, Done 30 pt right of centre.
        case blankThenToolbarSpacerThenDone
        /// One item: Done in a frame of a fixed width, the window's content width less 32 pt, aligned trailing. G0: no hang
        /// and Done at the trailing end, but the bar's pill then spans the whole width, covering what's behind it ("Have
        /// an invite code?"), and the width is the one read when the item was built, so a fold leaves it wrong.
        case doneInWindowWidth
    }

    /// The shape for an iOS release: the old group before 27.1; from 27.1, and anything after it (a later release that
    /// brings the Duo's bars to other iPhones shouldn't bring the hang back with them), the shape G0 kept.
    nonisolated static func shape(on version: OperatingSystemVersion) -> Shape {
        (version.majorVersion, version.minorVersion) >= (27, 1) ? .besideTheField : .spacerThenDone
    }

    /// This iPhone's. In Debug builds `-duoKeyboardShape <shape>` (a Shape's name) puts up another one, for G0's control
    /// run; a release build always takes `shape(on:)`, so it can never put up a shape that hangs.
    nonisolated static var current: Shape {
        #if DEBUG
        if let name = UserDefaults.standard.string(forKey: "duoKeyboardShape"), let forced = Shape(rawValue: name) {
            return forced
        }
        #endif
        return shape(on: ProcessInfo.processInfo.operatingSystemVersion)
    }

    let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    var body: some ToolbarContent {
        if Self.current.inBar { bar }
    }

    @ToolbarContentBuilder private var bar: some ToolbarContent {
        switch Self.current {
        case .spacerThenDone:
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                done
            }
        case .doneAlone, .besideTheField:
            // .besideTheField never gets here (body builds no bar for it).
            ToolbarItem(placement: .keyboard) { done }
        case .toolbarSpacerThenDone:
            if #available(iOS 26.0, *) {
                ToolbarSpacer(.flexible, placement: .keyboard)
                ToolbarItem(placement: .keyboard) { done }
            } else {
                ToolbarItem(placement: .keyboard) { done }
            }
        case .doneInTrailingRow:
            ToolbarItem(placement: .keyboard) {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    done
                }
            }
        case .doneInWideFrame:
            ToolbarItem(placement: .keyboard) {
                done.frame(maxWidth: .infinity, alignment: .trailing)
            }
        case .blankThenToolbarSpacerThenDone:
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .keyboard) {
                    Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.flexible, placement: .keyboard)
                ToolbarItem(placement: .keyboard) { done }
            } else {
                ToolbarItem(placement: .keyboard) { done }
            }
        case .doneInWindowWidth:
            ToolbarItem(placement: .keyboard) {
                done.frame(width: Self.windowContentWidth().map { max(80, $0 - 32) }, alignment: .trailing)
            }
        case .spacerThenDoneHorizontalOnly:
            if #available(iOS 27.1, *) {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    done
                }
                .axisBehavior(.horizontalOnly)
            } else {
                ToolbarItem(placement: .keyboard) { done }
            }
        }
    }

    private var done: some View {
        Button("Done", action: action).bold()
    }

    /// The key window's width inside its safe area (beside a vertical bar), for `.doneInWindowWidth`.
    @MainActor private static func windowContentWidth() -> CGFloat? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first else { return nil }
        return window.bounds.width - window.safeAreaInsets.left - window.safeAreaInsets.right
    }
}

extension DuoKeyboardDone.Shape {
    /// Whether this shape puts Done in the keyboard's bar. `keyboardDismissal()` and the sheet's stack build no keyboard
    /// item when it doesn't: not even an empty one, since a bar item's host is where the hang was (G0).
    nonisolated var inBar: Bool { self != .besideTheField }
}

// MARK: - Done beside a number field (iOS 27.1)

extension EnvironmentValues {
    /// Whether the keyboard's bar holds Done (`DuoKeyboardDone.current.inBar`): when it doesn't, `duoFieldDone(_:)` shows
    /// a Done beside its field. It only follows the iOS release (never the fold), so nothing changes on a hinge move; drawn
    /// tests, which run on 27.0, set it false to see the 27.1 Done.
    var duoKeyboardDoneInBar: Bool {
        get { self[DuoKeyboardDoneInBarKey.self] }
        set { self[DuoKeyboardDoneInBarKey.self] = newValue }
    }
}

private struct DuoKeyboardDoneInBarKey: EnvironmentKey {
    static var defaultValue: Bool { DuoKeyboardDone.current.inBar }
}

extension View {
    /// A number field's row (the field, and its unit if it has one): where the keyboard's bar has no Done (iOS 27.1,
    /// `DuoKeyboardDone.Shape.besideTheField`), a Done that closes the keyboard, beside the row while `focused`, or on a
    /// line of its own under it where the row leaves no room (the largest text sizes, the outer display). Elsewhere the
    /// row exactly as it is. The row's views are the same either way, so the field keeps its focus and what's typed.
    /// `under: true` always puts it on the line under, for a row that wraps (offered less width, it would rearrange).
    func duoFieldDone(_ focused: Bool, under: Bool = false) -> some View {
        modifier(DuoFieldDone(focused: focused, under: under))
    }
}

private struct DuoFieldDone: ViewModifier {
    let focused: Bool
    let under: Bool
    @Environment(\.duoKeyboardDoneInBar) private var inBar

    /// The row's scroll target: constant for the row's life.
    @State private var anchor = UUID()
    /// The row's foot (with its room under it) in the window, to tell whether the keyboard covers it.
    @State private var rowBottom: CGFloat = 0

    func body(content: Content) -> some View {
        ScrollViewReader { scroll in
            DuoFieldDoneLayout(besideIfItFits: !under) {
                content
                if focused && !inBar {
                    Button("Done", action: hideKeyboard)
                        .buttonStyle(.quietPill)
                        .accessibilityHint("Closes the keyboard")
                        .accessibilityIdentifier("fieldDone")
                }
            }
            // Room under the row when it's scrolled up to the keyboard.
            .padding(.bottom, focused && !inBar ? 12 : 0)
            .background { GeometryReader { g in Color.clear.onAppear { rowBottom = g.frame(in: .global).maxY }
                .onChange(of: g.frame(in: .global).maxY) { _, y in rowBottom = y } } }
            .id(anchor)
            // The keyboard's bar used to stand over the keyboard, and the system scrolled the field clear of it; with
            // no bar it scrolls only the text's own line clear, leaving the field's foot under the keys. So once the
            // keyboard is up (and again when a fold moves it), if the keys cover the row, the whole row and its Done go up above
            // them.
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { note in
                guard focused, !inBar,
                      let keys = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                      rowBottom > keys.minY else { return }
                withAnimation(.easeOut(duration: 0.2)) { scroll.scrollTo(anchor, anchor: .bottom) }
            }
        }
    }
}

/// The row, then Done 12 pt after it on the same line if the row fits in what Done leaves of the width offered (a field
/// that fills its width gives way to it), else Done under the row, leading.
struct DuoFieldDoneLayout: Layout {
    var spacing: CGFloat = 12
    var besideIfItFits = true

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (row, done, beside) = measure(proposal, subviews)
        guard let done else { return row }
        return beside
            ? CGSize(width: row.width + spacing + done.width, height: max(row.height, done.height))
            : CGSize(width: max(row.width, done.width), height: row.height + spacing + done.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let first = subviews.first else { return }
        let (row, done, beside) = measure(proposal, subviews)
        let height = done.map { beside ? max(row.height, $0.height) : row.height } ?? row.height
        first.place(at: CGPoint(x: bounds.minX, y: bounds.minY + (height - row.height) / 2), proposal: ProposedViewSize(row))
        guard let done, subviews.count > 1 else { return }
        let origin = beside
            ? CGPoint(x: bounds.minX + row.width + spacing, y: bounds.minY + (height - done.height) / 2)
            : CGPoint(x: bounds.minX, y: bounds.minY + row.height + spacing)
        subviews[1].place(at: origin, proposal: ProposedViewSize(done))
    }

    private func measure(_ proposal: ProposedViewSize, _ subviews: Subviews) -> (row: CGSize, done: CGSize?, beside: Bool) {
        guard let first = subviews.first else { return (.zero, nil, true) }
        guard subviews.count > 1 else { return (first.sizeThatFits(proposal), nil, true) }
        let done = subviews[1].sizeThatFits(.unspecified)
        let width = proposal.width ?? .infinity
        // Beside: the row offered what's left after Done (a field that fills its width gives way), if it fits in that.
        let left = width - spacing - done.width
        if besideIfItFits, left > 0 {
            let narrow = first.sizeThatFits(ProposedViewSize(width: left, height: proposal.height))
            if narrow.width <= left + 0.5 { return (narrow, done, true) }
        }
        return (first.sizeThatFits(proposal), CGSize(width: min(done.width, width), height: done.height), false)
    }
}

// MARK: - Inside a sheet's own NavigationStack

extension EnvironmentValues {
    /// `keyboardDismissal()` asked for the keyboard's Done here: set for the views it's attached to, so a SheetScaffold
    /// under it (Profile's basics and settings sheets attach it outside their scaffold) knows to put the Done inside its
    /// own NavigationStack on iOS 27.1, where the outer one can't reach the sheet's fields.
    var duoKeyboardDoneAsked: Bool {
        get { self[DuoKeyboardDoneAskedKey.self] }
        set { self[DuoKeyboardDoneAskedKey.self] = newValue }
    }

    /// A SheetScaffold above has already put the keyboard's Done inside its stack: a `keyboardDismissal()` inside the
    /// sheet adds none of its own, so there's only ever one Done.
    var duoKeyboardDoneInSheet: Bool {
        get { self[DuoKeyboardDoneInSheetKey.self] }
        set { self[DuoKeyboardDoneInSheetKey.self] = newValue }
    }
}

private struct DuoKeyboardDoneAskedKey: EnvironmentKey { static let defaultValue = false }
private struct DuoKeyboardDoneInSheetKey: EnvironmentKey { static let defaultValue = false }

extension View {
    /// SheetScaffold's, inside its DuoSheetStack: on iOS 27.1 and later, where the sheet sits in a NavigationStack of its
    /// own, a keyboard toolbar attached outside the sheet (`keyboardDismissal()` on the sheet's view) doesn't reach the
    /// fields inside the stack. So when `keyboardDismissal()` asked for Done around the sheet, the sheet puts the same
    /// DuoKeyboardDone inside its stack. Before 27.1 there's no stack and the outer Done works: nothing changes. Which it
    /// is depends only on the iOS release, so the sheet's structure never changes while the app runs (D13).
    func duoSheetKeyboardDone() -> some View { modifier(DuoSheetKeyboardDone()) }
}

private struct DuoSheetKeyboardDone: ViewModifier {
    @Environment(\.duoKeyboardDoneAsked) private var asked

    func body(content: Content) -> some View {
        if DuoSheetStack<EmptyView>.stacks {
            content
                .toolbar {
                    if asked, DuoKeyboardDone.current.inBar { DuoKeyboardDone(action: hideKeyboard) }
                }
                .environment(\.duoKeyboardDoneInSheet, asked)
                .environment(\.duoKeyboardDoneAsked, false)
        } else {
            content
        }
    }
}
