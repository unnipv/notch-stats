import SwiftUI

enum Theme {
    static let codex = Color(hex: "#10A37F")
    static let opencode = Color(hex: "#B47BFF")
    static let openrouter = Color(hex: "#7E8BF5")
    static let warn = Color(hex: "#FFB020")
    static let crit = Color(hex: "#FF5A4E")
    static let subtext = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.35)

    static func urgency(_ percent: Double, base: Color) -> Color {
        if percent >= 0.90 { return crit }
        if percent >= 0.75 { return warn }
        return base
    }

    // MARK: - Panel surfaces

    /// Expanded-panel surface: pure black at the top so it melts into the
    /// camera housing, easing into a deep graphite blue at the bottom edge.
    static let panelGradient = LinearGradient(
        colors: [Color.black, Color(hex: "#04060A"), Color(hex: "#0B111A")],
        startPoint: .top, endPoint: .bottom)

    /// Soft light spill from the top edge that makes the panel read as glass.
    static let panelSheen = LinearGradient(
        colors: [Color.white.opacity(0.06), Color.white.opacity(0)],
        startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.16))

    /// Edge hairline. Near-invisible when collapsed so the black ear blends
    /// into the physical notch; a touch more present when expanded.
    static func hairline(expanded: Bool) -> LinearGradient {
        LinearGradient(
            colors: [Color.white.opacity(expanded ? 0.16 : 0.09),
                     Color.white.opacity(expanded ? 0.05 : 0.03)],
            startPoint: .top, endPoint: .bottom)
    }

    // MARK: - Cards

    /// Row card fill: a faint top-lit wash of `tint` that lifts on hover.
    static func card(hovering: Bool, tint: Color = .white, strength: Double = 1) -> LinearGradient {
        let lift = hovering ? 1.6 : 1.0
        return LinearGradient(
            colors: [tint.opacity(0.062 * lift * strength),
                     tint.opacity(0.034 * lift * strength)],
            startPoint: .top, endPoint: .bottom)
    }

    static func cardStroke(hovering: Bool, tint: Color = .white, strength: Double = 1) -> Color {
        tint.opacity((hovering ? 0.14 : 0.07) * strength)
    }
}

extension View {
    /// Rolls monospaced numerals when the rendered value changes.
    func numericFlip(_ value: Double) -> some View {
        self
            .contentTransition(.numericText())
            .animation(.easeOut(duration: 0.35), value: value)
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
