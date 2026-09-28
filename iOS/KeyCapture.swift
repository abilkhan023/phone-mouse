import SwiftUI
import UIKit

struct KeyCapture: UIViewRepresentable {
    let isActive: Bool
    let onKey: (KeyEvent.Kind, String) -> Void

    func makeUIView(context: Context) -> KeyCaptureField {
        KeyCaptureField()
    }

    func updateUIView(_ view: KeyCaptureField, context: Context) {
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

// A hidden text field, because only a real text input gets the keyboard's
// hold-to-delete repeat, which speeds up to whole words. The field keeps a
// copy of the current line behind some filler, and every edit is turned into
// key events by comparing the text before and after.
final class KeyCaptureField: UITextField, UITextFieldDelegate {
    var onKey: ((KeyEvent.Kind, String) -> Void)?

    private let filler = String(repeating: "x ", count: 32)
    private let lineLimit = 500
    private var last = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        inlinePredictionType = .no
        keyboardAppearance = .dark
        tintColor = .clear
        textColor = .clear
        reset(line: "")
        addTarget(self, action: #selector(edited), for: .editingChanged)
    }

    required init?(coder: NSCoder) { nil }

    override func caretRect(for position: UITextPosition) -> CGRect { .zero }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        action == #selector(paste(_:))
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onKey?(.enter, "")
        reset(line: "")
        return false
    }

    // Edits only make sense at the end, so the caret is kept there.
    func textFieldDidChangeSelection(_ textField: UITextField) {
        guard markedTextRange == nil else { return }
        let end = endOfDocument
        if selectedTextRange?.start != end || selectedTextRange?.end != end {
            selectedTextRange = textRange(from: end, to: end)
        }
    }

    @objc private func edited() {
        guard markedTextRange == nil else { return }
        let now = text ?? ""
        let old = Array(last)
        let new = Array(now)
        var common = 0
        while common < old.count, common < new.count, old[common] == new[common] {
            common += 1
        }
        for _ in common..<old.count {
            onKey?(.backspace, "")
        }
        if common < new.count {
            onKey?(.text, String(new[common...]))
        }
        let line = now.hasPrefix(filler) ? String(now.dropFirst(filler.count)) : ""
        if !now.hasPrefix(filler) || line.count > lineLimit {
            reset(line: String(line.suffix(lineLimit / 2)))
        } else {
            last = now
        }
    }

    private func reset(line: String) {
        text = filler + line
        last = text ?? ""
    }
}
