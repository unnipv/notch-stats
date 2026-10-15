import SwiftUI

enum Theme {
    static let codex = Color(hex: "#10A37F")
    static let opencode = Color(hex: "#B47BFF")
    static let openrouter = Color(hex: "#7E8BF5")
    static let warn = Color(hex: "#FFB020")
    static let crit = Color(hex: "#FF5A4E")
    static let subtext = Color.white.opacity(0.55)

    static func urgency(_ percent: Double, base: Color) -> Color {
        if percent >= 0.90 { return crit }
        if percent >= 0.75 { return warn }
        return base
    }
}

extension Color {
    init(hex: String) {
        var string = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.hasPrefix("#") { string.removeFirst() }

        var value: UInt64 = 0
        Scanner(string: string).scanHexInt64(&value)

        let r, g, b, a: Double
        if string.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
