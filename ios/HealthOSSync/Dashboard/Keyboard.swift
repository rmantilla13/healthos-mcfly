import SwiftUI
import UIKit

@MainActor
func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

extension View {
    /// Forms and scroll views: the keyboard follows a downward scroll away, and a Done button sits above
    /// keyboards (URL, number and code keyboards have no obvious way out). How Done sits there on iPhone Duo is
    /// DuoKeyboardDone's (Shell/Duo/DuoKeyboard.swift). On a sheet's view (outside its SheetScaffold) it also asks the
    /// scaffold for the Done: on iPhone Duo the scaffold sits in a navigation stack of its own, which a keyboard toolbar
    /// from outside doesn't reach, so the scaffold puts it inside (`duoKeyboardDoneAsked`).
    func keyboardDismissal() -> some View {
        modifier(KeyboardDismissal())
    }
}

private struct KeyboardDismissal: ViewModifier {
    /// A SheetScaffold above already holds the Done inside its stack: none here as well.
    @Environment(\.duoKeyboardDoneInSheet) private var inSheet

    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                // None at all where the bar holds no Done (iOS 27.1): number fields put theirs beside them (duoFieldDone).
                if !inSheet, DuoKeyboardDone.current.inBar { DuoKeyboardDone(action: hideKeyboard) }
            }
            .environment(\.duoKeyboardDoneAsked, true)
    }
}

/// Closes the keyboard when you tap anywhere that isn't a text field, on every screen. The tap still reaches
/// whatever was tapped (buttons, rows), so nothing else changes.
@MainActor
enum KeyboardDismisser {
    private static let handler = TapHandler()

    static func install() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where !(window.gestureRecognizers ?? []).contains(where: { $0.delegate === handler }) {
                let tap = UITapGestureRecognizer(target: handler, action: #selector(TapHandler.tapped))
                tap.cancelsTouchesInView = false
                tap.delegate = handler
                window.addGestureRecognizer(tap)
            }
        }
    }

    private final class TapHandler: NSObject, UIGestureRecognizerDelegate {
        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            gesture.view?.endEditing(true)
        }

        // Taps that land in a text field (or its clear button) are for typing.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let v = view {
                if v is UITextField || v is UITextView { return false }
                view = v.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
