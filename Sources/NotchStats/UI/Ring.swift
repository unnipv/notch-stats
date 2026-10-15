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

    private var clamped: Double { max(0.001, min(1, progress)) }
    private var showsGlow: Bool { size >= 22 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.16), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: clamped)
                .stroke(
                    AngularGradient(colors: [color.opacity(0.45), color],
                                    center: .center,
                                    startAngle: .degrees(-90),
                                    endAngle: .degrees(270)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: showsGlow ? color.opacity(0.5) : .clear,
                        radius: showsGlow ? size * 0.15 : 0)

            Circle()
                .fill(color)
                .frame(width: max(3, size * 0.26), height: max(3, size * 0.26))
                .opacity(live ? 1 : 0)
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.5), value: progress)
    }
}
