import SwiftUI

/// A circular progress ring. When `live` is set, a centre dot marks an agent
/// that is currently working.
///
/// Deliberately static: no repeating animations. An endless animation here keeps
/// the window's display link active, so SwiftUI re-lays-out every frame and the
/// app never idles. The live dot is drawn always and toggled via opacity so the
/// view tree keeps a stable identity.
struct Ring: View {
    var progress: Double
    var color: Color
    var size: CGFloat = 16
    var lineWidth: CGFloat = 3
    var live: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clamped: Double { max(0.001, min(1, progress)) }

    var body: some View {
        ZStack {
            // Inset by half the stroke so the ring stays inside its frame.
            Circle()
                .inset(by: lineWidth / 2)
                .stroke(color.opacity(0.18), lineWidth: lineWidth)

            Circle()
                .inset(by: lineWidth / 2)
                .trim(from: 0, to: clamped)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Circle()
                .fill(color)
                .frame(width: max(3, size * 0.28), height: max(3, size * 0.28))
                .opacity(live ? 1 : 0)
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: progress)
        .accessibilityHidden(true)
    }
}
