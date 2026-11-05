import SwiftUI

/// Design tokens. The island hangs off a black camera housing, so the whole
/// surface is rendered in the dark appearance; text uses the system's
/// hierarchical styles (`.primary` / `.secondary`) rather than hard-coded
/// whites, and every spacing value is on a 4 pt grid.
enum Theme {
    static let codex = Color(hex: "#10A37F")
    static let opencode = Color(hex: "#B47BFF")
    static let openrouter = Color(hex: "#7E8BF5")
    static let warn = Color(hex: "#FFB020")
    static let crit = Color(hex: "#FF5A4E")
    static let live = Color(hex: "#34C759")

    /// 4 pt rhythm.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
    }

    /// Colour for a window that is `percent` used: the provider's own accent
    /// until it gets tight, then amber, then red — the same thresholds
    /// everywhere (rings, bars, numbers).
    static func urgency(_ percent: Double, base: Color) -> Color {
        if percent >= 0.90 { return crit }
        if percent >= 0.75 { return warn }
        return base
    }

    static func isUrgent(_ percent: Double) -> Bool { percent >= 0.75 }

    // MARK: - Surfaces

    /// Expanded glass: a blurred material darkened by a black wash that is
    /// fully opaque through the menu-bar band, so the panel melts into the
    /// camera housing and only turns translucent below it.
    static func glassWash(bandFraction: Double) -> LinearGradient {
        LinearGradient(stops: [
            .init(color: .black, location: 0),
            .init(color: .black, location: bandFraction),
            .init(color: .black.opacity(0.62), location: min(1, bandFraction + 0.12)),
            .init(color: .black.opacity(0.52), location: 1)
        ], startPoint: .top, endPoint: .bottom)
    }

    static func hairline(expanded: Bool) -> LinearGradient {
        LinearGradient(
            colors: [Color.white.opacity(expanded ? 0.14 : 0.08),
                     Color.white.opacity(expanded ? 0.06 : 0.03)],
            startPoint: .top, endPoint: .bottom)
    }

    static func card(hovering: Bool) -> Color {
        Color.white.opacity(hovering ? 0.095 : 0.06)
    }

    static func cardStroke(hovering: Bool) -> Color {
        Color.white.opacity(hovering ? 0.16 : 0.08)
    }
}

extension View {
    /// Rolls numerals when the value changes — unless Reduce Motion is on.
    func numericFlip(_ value: Double) -> some View {
        modifier(NumericFlip(value: value))
    }
}

private struct NumericFlip: ViewModifier {
    let value: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.3), value: value)
        }
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
