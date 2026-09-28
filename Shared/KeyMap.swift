import Foundation

struct KeyModifiers: OptionSet, Hashable {
    let rawValue: UInt8

    static let control = KeyModifiers(rawValue: 1 << 0)
    static let option = KeyModifiers(rawValue: 1 << 1)
    static let command = KeyModifiers(rawValue: 1 << 2)
    static let shift = KeyModifiers(rawValue: 1 << 3)
}

// Mac virtual key codes of the ANSI keyboard. A shortcut has to be sent as a
// key code, not as text, so characters typed together with a modifier are
// looked up here. Russian letters map to the same physical keys.
enum KeyMap {
    static let tab: UInt8 = 48
    static let space: UInt8 = 49
    static let backspace: UInt8 = 51
    static let returnKey: UInt8 = 36
    static let escape: UInt8 = 53
    static let forwardDelete: UInt8 = 117
    static let home: UInt8 = 115
    static let end: UInt8 = 119
    static let pageUp: UInt8 = 116
    static let pageDown: UInt8 = 121
    static let left: UInt8 = 123
    static let right: UInt8 = 124
    static let down: UInt8 = 125
    static let up: UInt8 = 126
    static let function: [UInt8] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

    static func lookup(_ character: Character) -> (code: UInt8, shift: Bool)? {
        let lower = Character(character.lowercased())
        let shifted = lower != character
        if let code = base[lower] { return (code, shifted) }
        if let code = russian[lower] { return (code, shifted) }
        if let code = shiftedSymbols[character] { return (code, true) }
        return nil
    }

    private static let base: [Character: UInt8] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50, " ": 49,
    ]

    private static let shiftedSymbols: [Character: UInt8] = [
        "!": 18, "@": 19, "#": 20, "$": 21, "^": 22, "%": 23, "+": 24, "(": 25, "&": 26,
        "_": 27, "*": 28, ")": 29, "}": 30, "{": 33, "\"": 39, ":": 41, "|": 42,
        "<": 43, "?": 44, ">": 47, "~": 50,
    ]

    private static let russian: [Character: UInt8] = [
        "й": 12, "ц": 13, "у": 14, "к": 15, "е": 17, "н": 16, "г": 32, "ш": 34, "щ": 31,
        "з": 35, "х": 33, "ъ": 30, "ф": 0, "ы": 1, "в": 2, "а": 3, "п": 5, "р": 4,
        "о": 38, "л": 40, "д": 37, "ж": 41, "э": 39, "я": 6, "ч": 7, "с": 8, "м": 9,
        "и": 11, "т": 45, "ь": 46, "б": 43, "ю": 47, "ё": 50,
    ]
}
