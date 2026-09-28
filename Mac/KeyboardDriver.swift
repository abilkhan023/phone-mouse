import AppKit
import Carbon

final class KeyboardDriver {
    // Modifiers the phone holds down right now.
    private(set) var held: KeyModifiers = []
    private let source = CGEventSource(stateID: .hidSystemState)
    private let chunk = 20
    private let eraseLimit = 5000
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
            for _ in 0..<min(Int(event.text) ?? 1, eraseLimit) {
                press(CGKeyCode(KeyMap.backspace))
            }
        case .enter:
            press(CGKeyCode(KeyMap.returnKey))
        case .stroke:
            let modifiers = event.modifiers.subtracting(.function)
            if let index = KeyMap.function.firstIndex(of: event.keyCode), !event.modifiers.contains(.function) {
                topRow(index)
            } else if event.keyCode == KeyMap.globe
                        || (event.keyCode == KeyMap.space && modifiers.union(held) == .control) {
                switchInputSource()
            } else {
                press(CGKeyCode(event.keyCode), modifiers: modifiers)
            }
        case .hold:
            hold(event.modifiers.subtracting(held))
        case .release:
            release(event.modifiers.intersection(held))
        }
    }

    var heldFlags: CGEventFlags {
        modifierKeys.filter { held.contains($0.modifier) }.reduce(into: CGEventFlags()) { $0.insert($1.flag) }
    }

    func releaseAll() {
        release(held)
    }

    private func hold(_ modifiers: KeyModifiers) {
        for entry in modifierKeys where modifiers.contains(entry.modifier) {
            held.insert(entry.modifier)
            postModifier(entry.code, flags: heldFlags)
        }
    }

    private func release(_ modifiers: KeyModifiers) {
        for entry in modifierKeys.reversed() where modifiers.contains(entry.modifier) {
            held.remove(entry.modifier)
            postModifier(entry.code, flags: heldFlags)
        }
    }

    // Synthetic shortcuts such as ⌃Space often miss the input source switcher,
    // so the Mac switches to the next keyboard layout itself.
    private func switchInputSource() {
        let filter = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource,
            kTISPropertyInputSourceIsSelectCapable: true,
        ] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
              list.count > 1,
              let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
        let ids = list.map { sourceID($0) }
        let index = ids.firstIndex(of: sourceID(current)) ?? -1
        TISSelectInputSource(list[(index + 1) % list.count])
    }

    private func sourceID(_ source: TISInputSource) -> String {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    // Volume goes through the media keys, so macOS shows its own volume overlay
    // and changes whichever output device is active.
    func apply(_ event: VolumeEvent) {
        mediaKey(event.direction == .up ? NX_KEYTYPE_SOUND_UP : NX_KEYTYPE_SOUND_DOWN)
    }

    // The top row does what it does on a MacBook keyboard: brightness,
    // Mission Control, Spotlight, media and volume. With fn it sends F1 to F12.
    private func topRow(_ index: Int) {
        switch index {
        case 0: mediaKey(NX_KEYTYPE_BRIGHTNESS_DOWN)
        case 1: mediaKey(NX_KEYTYPE_BRIGHTNESS_UP)
        case 2: open("/System/Applications/Mission Control.app")
        case 3: press(CGKeyCode(KeyMap.space), modifiers: .command)
        case 6: mediaKey(NX_KEYTYPE_PREVIOUS)
        case 7: mediaKey(NX_KEYTYPE_PLAY)
        case 8: mediaKey(NX_KEYTYPE_NEXT)
        case 9: mediaKey(NX_KEYTYPE_MUTE)
        case 10: mediaKey(NX_KEYTYPE_SOUND_DOWN)
        case 11: mediaKey(NX_KEYTYPE_SOUND_UP)
        default: press(CGKeyCode(KeyMap.function[index]))
        }
    }

    private func mediaKey(_ key: Int32) {
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
    // Modifiers the phone already holds stay down; the rest are pressed
    // around the key.
    private func press(_ key: CGKeyCode, modifiers: KeyModifiers = []) {
        let pressed = modifierKeys.filter { modifiers.contains($0.modifier) && !held.contains($0.modifier) }
        var flags = heldFlags
        for entry in pressed {
            flags.insert(entry.flag)
            postModifier(entry.code, flags: flags)
        }
        post(key, down: true, flags: flags.union(keyFlags(key)))
        post(key, down: false, flags: flags.union(keyFlags(key)))
        for entry in pressed.reversed() {
            flags.remove(entry.flag)
            postModifier(entry.code, flags: flags)
        }
    }

    // A modifier key reaches apps as a change of flags, not as a key press.
    private func postModifier(_ key: CGKeyCode, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true) else { return }
        event.type = .flagsChanged
        event.flags = flags
        event.post(tap: .cghidEventTap)
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
