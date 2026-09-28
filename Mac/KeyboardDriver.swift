import AppKit

final class KeyboardDriver {
    private let source = CGEventSource(stateID: .hidSystemState)
    private let chunk = 20
    private let mediaKeySubtype: Int16 = 8
    private let modifierKeys: [(modifier: KeyModifiers, code: CGKeyCode, flag: CGEventFlags)] = [
        (.control, 59, .maskControl),
        (.option, 58, .maskAlternate),
        (.shift, 56, .maskShift),
        (.command, 55, .maskCommand),
    ]

    func apply(_ event: KeyEvent) {
        switch event.kind {
        case .text:
            let units = Array(event.text.utf16)
            let keyCode = event.text.count == 1 ? event.text.first.flatMap(KeyMap.lookup)?.code ?? 0 : 0
            for start in stride(from: 0, to: units.count, by: chunk) {
                type(Array(units[start..<min(start + chunk, units.count)]), keyCode: CGKeyCode(keyCode))
            }
        case .backspace:
            press(CGKeyCode(KeyMap.backspace))
        case .enter:
            press(CGKeyCode(KeyMap.returnKey))
        case .stroke:
            press(CGKeyCode(event.keyCode), modifiers: event.modifiers)
        }
    }

    // Volume goes through the media keys, so macOS shows its own volume overlay
    // and changes whichever output device is active.
    func apply(_ event: VolumeEvent) {
        let key: Int32 = event.direction == .up ? NX_KEYTYPE_SOUND_UP : NX_KEYTYPE_SOUND_DOWN
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: mediaKeySubtype,
                data1: Int((key << 16) | ((down ? 0xa : 0xb) << 8)),
                data2: -1
            )?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    // macOS offers no public way to post trackpad gestures, so each one runs
    // the system action it stands for through its default shortcut.
    func apply(_ event: GestureEvent) {
        switch event.kind {
        case .swipeUp: open("/System/Applications/Mission Control.app")
        case .swipeDown: press(CGKeyCode(KeyMap.down), modifiers: .control)
        case .swipeLeft: press(CGKeyCode(KeyMap.right), modifiers: .control)
        case .swipeRight: press(CGKeyCode(KeyMap.left), modifiers: .control)
        case .spreadOut: press(CGKeyCode(KeyMap.function[10]))
        case .lookUp: press(CGKeyCode(KeyMap.lookup("d")?.code ?? 2), modifiers: [.control, .command])
        case .zoomIn: press(CGKeyCode(KeyMap.lookup("=")?.code ?? 24), modifiers: .command)
        case .zoomOut: press(CGKeyCode(KeyMap.lookup("-")?.code ?? 27), modifiers: .command)
        case .pinchIn:
            if !open("/System/Applications/Apps.app") {
                open("/System/Applications/Launchpad.app")
            }
        }
    }

    @discardableResult
    private func open(_ path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
        return true
    }

    private func type(_ units: [UniChar], keyCode: CGKeyCode) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event.post(tap: .cghidEventTap)
        }
    }

    // Modifier keys are pressed around the key as well as set in its flags,
    // because some apps only look at one of the two.
    private func press(_ key: CGKeyCode, modifiers: KeyModifiers = []) {
        let held = modifierKeys.filter { modifiers.contains($0.modifier) }
        var flags = CGEventFlags()
        for entry in held {
            flags.insert(entry.flag)
            post(entry.code, down: true, flags: flags)
        }
        post(key, down: true, flags: flags.union(keyFlags(key)))
        post(key, down: false, flags: flags.union(keyFlags(key)))
        for entry in held.reversed() {
            flags.remove(entry.flag)
            post(entry.code, down: false, flags: flags)
        }
    }

    // A real keyboard marks arrows as keypad keys and both arrows and the
    // function row as fn keys. System shortcuts such as ⌃← only match events
    // that carry the same marks.
    private func keyFlags(_ key: CGKeyCode) -> CGEventFlags {
        let code = UInt8(truncatingIfNeeded: key)
        if [KeyMap.left, KeyMap.right, KeyMap.up, KeyMap.down].contains(code) {
            return [.maskNumericPad, .maskSecondaryFn]
        }
        if KeyMap.function.contains(code) || [KeyMap.home, KeyMap.end, KeyMap.pageUp, KeyMap.pageDown, KeyMap.forwardDelete].contains(code) {
            return .maskSecondaryFn
        }
        return []
    }

    private func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}
