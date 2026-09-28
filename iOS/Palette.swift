import SwiftUI

enum Palette {
    static let shellTop = Color(hex: 0x34373C)
    static let shellBottom = Color(hex: 0x232529)
    static let groove = Color(hex: 0x141517)
    static let pressed = Color(hex: 0x1D1F22)
    static let wheel = Color(hex: 0x55595F)
    static let ridge = Color(hex: 0x2E3034)
    static let ink = Color(hex: 0xDFE1E4)
    static let led = Color(hex: 0xFF331A)
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
