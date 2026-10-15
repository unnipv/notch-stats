import SwiftUI

/// A circular progress ring. When `live` is set, a centre dot marks an agent
/// that is currently working.
struct Ring: View {
    var progress: Double
    var color: Color
    var size: CGFloat = 16
    var lineWidth: CGFloat = 3
    var live: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.20), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if live {
                Circle()
                    .fill(color)
                    .frame(width: max(3, size * 0.26), height: max(3, size * 0.26))
            }
        }
        .frame(width: size, height: size)
    }
}
