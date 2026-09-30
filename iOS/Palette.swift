import SwiftUI

// Looks for the mouse, chosen in settings. Every color the app draws with
// comes from the skin in use.
enum Skin: String, CaseIterable, Identifiable {
    case graphite
    case white
    case platinum
    case bondi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .graphite: "Graphite"
        case .white: "White"
        case .platinum: "Platinum"
        case .bondi: "Bondi"
        }
    }

    // System controls follow the shell: light ones on a light shell.
    var scheme: ColorScheme {
        switch self {
        case .graphite, .bondi: .dark
        case .white, .platinum: .light
        }
    }

    fileprivate var colors: SkinColors {
        switch self {
        case .graphite:
            SkinColors(shellTop: 0x34373C, shellBottom: 0x232529, groove: 0x141517, pressed: 0x1D1F22,
                       wheel: 0x55595F, ridge: 0x2E3034, ink: 0xDFE1E4, led: 0xFF331A)
        case .white:
            SkinColors(shellTop: 0xF6F7F9, shellBottom: 0xDCDFE3, groove: 0xB3B7BD, pressed: 0xE7E9EC,
                       wheel: 0xC5C9CE, ridge: 0xCFD2D7, ink: 0x2A2C30, led: 0xFF3B30)
        case .platinum:
            SkinColors(shellTop: 0xE4DECF, shellBottom: 0xC8C1AF, groove: 0x9C9584, pressed: 0xD5CEBD,
                       wheel: 0xB4AD9A, ridge: 0xBEB7A5, ink: 0x3A3732, led: 0x2FA84F)
        case .bondi:
            SkinColors(shellTop: 0x33A8BD, shellBottom: 0x0A6A80, groove: 0x064456, pressed: 0x0C5B6E,
                       wheel: 0x62C6D8, ridge: 0x15839A, ink: 0xECF9FC, led: 0xFF8A1F)
        }
    }

    // For the skin picker.
    var previewTop: Color { Color(hex: colors.shellTop) }
    var previewBottom: Color { Color(hex: colors.shellBottom) }
    var previewLED: Color { Color(hex: colors.led) }
}

private struct SkinColors {
    let shellTop: UInt32
    let shellBottom: UInt32
    let groove: UInt32
    let pressed: UInt32
    let wheel: UInt32
    let ridge: UInt32
    let ink: UInt32
    let led: UInt32
}

enum Palette {
    // Set from settings; the screen is drawn again when it changes.
    static var skin = Skin.graphite

    static var shellTop: Color { Color(hex: skin.colors.shellTop) }
    static var shellBottom: Color { Color(hex: skin.colors.shellBottom) }
    static var groove: Color { Color(hex: skin.colors.groove) }
    static var pressed: Color { Color(hex: skin.colors.pressed) }
    static var wheel: Color { Color(hex: skin.colors.wheel) }
    static var ridge: Color { Color(hex: skin.colors.ridge) }
    static var ink: Color { Color(hex: skin.colors.ink) }
    static var led: Color { Color(hex: skin.colors.led) }
}

extension Font {
    static func marking(_ size: CGFloat) -> Font {
        .custom("DINAlternate-Bold", size: size)
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
