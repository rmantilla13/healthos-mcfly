import SwiftUI

// iPhone Duo (D0 of the Duo design): the keyboard's Done. On iOS 27.1, the release only iPhone Duo runs, the
// keyboard's bar item group (a flexible space, then Done) sent healthOS's main thread into a layout cycle on the sign-in
// form, the welcome frame with its bars hidden, as soon as the accessibility tree was read with the keyboard up (seen
// with UI tests): SwiftUI sized the bar item forever. Profile and its sheets didn't hang. Flexible spaces mean nothing
// in the Duo's floating keyboard bar, so on 27.1 Done goes up on its own, one `.keyboard` item, on every screen; the
// bar then centres it. Before 27.1 nothing changes. This is the only place that looks at the iOS version for it:
// `keyboardDismissal()` (Dashboard/Keyboard.swift) uses it, and pages use `keyboardDismissal()`.

/// The Done button above the keyboard, which closes it (URL, number and code keyboards have no other obvious way out).
struct DuoKeyboardDone: ToolbarContent {
    /// How Done sits above the keyboard.
    enum Shape: Equatable {
        /// Before iOS 27.1: a flexible space, then Done, at the trailing end of the bar over the keyboard.
        case spacerThenDone
        /// iOS 27.1 and later: Done alone, with no flexible space.
        case doneAlone
    }

    /// 27.1 and anything after it: a later release that brings the Duo's bars to other iPhones shouldn't bring the
    /// hang back with them.
    nonisolated static func shape(on version: OperatingSystemVersion) -> Shape {
        (version.majorVersion, version.minorVersion) >= (27, 1) ? .doneAlone : .spacerThenDone
    }

    /// This iPhone's.
    nonisolated static var current: Shape { shape(on: ProcessInfo.processInfo.operatingSystemVersion) }

    let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    var body: some ToolbarContent {
        if Self.current == .doneAlone {
            ToolbarItem(placement: .keyboard) { done }
        } else {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                done
            }
        }
    }

    private var done: some View {
        Button("Done", action: action).bold()
    }
}
