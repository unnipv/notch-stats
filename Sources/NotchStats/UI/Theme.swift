import SwiftUI

/// Design tokens. The island hangs off a black camera housing, so the whole
/// surface is rendered in the dark appearance; text uses the system's
/// hierarchical styles (`.primary` / `.secondary`) rather than hard-coded
/// whites, and every spacing value is on a 4 pt grid.
enum Theme {
    static let codex = Color(hex: "#10A37F")
    static let gemini = Color(hex: "#4285F4")
    static let opencode = Color(hex: "#B47BFF")
    static let openrouter = Color(hex: "#7E8BF5")
    static let live = Color(hex: "#34C759")

    // Warnings own two hues no provider accent can produce (accents are green,
    // terracotta, blue, purple and indigo), and in the panel they always come
    // with a glyph as well, so colour never has to carry the meaning alone.
    static let warn = Color(hex: "#FFD60A")
    static let crit = Color(hex: "#FF3B6B")

    /// Labels and countdowns: the second-most-read text on a row.
    static let label = Color.white.opacity(0.88)
    /// Decorative glyphs next to a label.
    static let glyph = Color.white.opacity(0.65)
    /// The unfilled part of a bar: enough to show how much is left.
    static let track = Color.white.opacity(0.22)

    /// Left and right margin shared by the header, the cards and the footer.
    static let margin: CGFloat = 16

    /// 4 pt rhythm.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
    }

    /// Colour for a window that is `percent` used: the provider's own accent
    /// until it gets tight, then yellow, then pink-red — the same thresholds
    /// everywhere (rings, bars, numbers).
    static func urgency(_ percent: Double, base: Color) -> Color {
        if percent >= 0.90 { return crit }
        if percent >= 0.75 { return warn }
        return base
    }

    static func isUrgent(_ percent: Double) -> Bool { percent >= 0.75 }

    /// The shape cue that accompanies a warning colour in the panel.
    static func urgencyGlyph(_ percent: Double) -> String? {
        if percent >= 0.90 { return "exclamationmark.octagon.fill" }
        if percent >= 0.75 { return "exclamationmark.triangle.fill" }
        return nil
    }

    // MARK: - Surfaces

    /// Expanded glass: `.ultraThinMaterial` with only a light black wash over it
    /// (~0.30) so the desktop shows through the blur. The wash is fully opaque
    /// through the menu-bar band — where the notch and the ears sit — and eases
    /// out just below it.
    static func glassWash(bandFraction: Double) -> LinearGradient {
        LinearGradient(stops: [
            .init(color: .black, location: 0),
            .init(color: .black, location: bandFraction),
            .init(color: .black.opacity(0.30), location: min(1, bandFraction + 0.05)),
            .init(color: .black.opacity(0.30), location: 1)
        ], startPoint: .top, endPoint: .bottom)
    }

    /// A soft shadow just under the notch band, so the opaque band doesn't end
    /// in a hard line against the translucent panel.
    static let notchShadow = LinearGradient(
        colors: [Color.black.opacity(0.45), Color.black.opacity(0)],
        startPoint: .top, endPoint: .bottom)

    /// Edge hairline with a brighter highlight along the top.
    static func hairline(expanded: Bool) -> LinearGradient {
        LinearGradient(
            colors: [Color.white.opacity(expanded ? 0.34 : 0.08),
                     Color.white.opacity(expanded ? 0.10 : 0.03)],
            startPoint: .top, endPoint: .bottom)
    }

    /// Cards carry the legibility that the lighter wash no longer provides:
    /// a stronger fill and stroke than they would need on flat black.
    static func card(hovering: Bool) -> Color {
        Color.white.opacity(hovering ? 0.15 : 0.11)
    }

    static func cardStroke(hovering: Bool) -> Color {
        Color.white.opacity(hovering ? 0.26 : 0.16)
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
