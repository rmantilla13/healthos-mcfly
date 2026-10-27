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
        /// iOS 27.1 (F0, kept by the shell stage): Done alone, with no flexible space. The bar centres it. No hang.
        case doneAlone
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
        (version.majorVersion, version.minorVersion) >= (27, 1) ? .doneAlone : .spacerThenDone
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
        switch Self.current {
        case .spacerThenDone:
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                done
            }
        case .doneAlone:
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
                    if asked { DuoKeyboardDone(action: hideKeyboard) }
                }
                .environment(\.duoKeyboardDoneInSheet, asked)
                .environment(\.duoKeyboardDoneAsked, false)
        } else {
            content
        }
    }
}
