import SwiftUI
import UIKit

struct KeyCapture: UIViewRepresentable {
    let isActive: Bool
    let onKey: (KeyEvent.Kind, String) -> Void

    func makeUIView(context: Context) -> KeyCaptureView {
        KeyCaptureView()
    }

    func updateUIView(_ view: KeyCaptureView, context: Context) {
        view.onKey = onKey
        let active = isActive
        DispatchQueue.main.async {
            if active, !view.isFirstResponder {
                view.becomeFirstResponder()
            } else if !active, view.isFirstResponder {
                view.resignFirstResponder()
            }
        }
    }
}

final class KeyCaptureView: UIView, UIKeyInput {
    var onKey: ((KeyEvent.Kind, String) -> Void)?

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardAppearance: UIKeyboardAppearance = .dark

    override var canBecomeFirstResponder: Bool { true }

    var hasText: Bool { true }

    func insertText(_ text: String) {
        if text == "\n" {
            onKey?(.enter, "")
        } else {
            onKey?(.text, text)
        }
    }

    func deleteBackward() {
        onKey?(.backspace, "")
    }
}
