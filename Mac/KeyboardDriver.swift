import AppKit

final class KeyboardDriver {
    private let source = CGEventSource(stateID: .hidSystemState)
    private let backspaceKey: CGKeyCode = 51
    private let returnKey: CGKeyCode = 36
    private let chunk = 20

    func apply(_ event: KeyEvent) {
        switch event.kind {
        case .text:
            let units = Array(event.text.utf16)
            for start in stride(from: 0, to: units.count, by: chunk) {
                type(Array(units[start..<min(start + chunk, units.count)]))
            }
        case .backspace:
            press(backspaceKey)
        case .enter:
            press(returnKey)
        }
    }

    private func type(_ units: [UniChar]) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event.post(tap: .cghidEventTap)
        }
    }

    private func press(_ key: CGKeyCode) {
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)?.post(tap: .cghidEventTap)
        }
    }
}
