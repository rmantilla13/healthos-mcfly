import SwiftUI
import UIKit

@MainActor
func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

extension View {
    /// Forms and scroll views: the keyboard follows a downward scroll away, and a Done button sits above
    /// keyboards (URL, number and code keyboards have no obvious way out).
    func keyboardDismissal() -> some View {
        scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done", action: hideKeyboard).bold()
                }
            }
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
