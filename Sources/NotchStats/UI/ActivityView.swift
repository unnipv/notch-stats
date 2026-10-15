import SwiftUI

struct ActivityView: View {
    let store: AppStore

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .overlay(alignment: store.sessions.isEmpty ? .center : .top) {
                    if store.sessions.isEmpty {
                        empty
                    } else {
                        VStack(spacing: 10) {
                            ForEach(store.sessions) { session in
                                SessionRow(session: session)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                }
                .mask(fadeMask(height: proxy.size.height))
                .clipped()
        }
    }

    /// More sessions than fit: fade the overflow out above the footer
    /// instead of letting rows spill past the panel edge.
    private func fadeMask(height: CGFloat) -> LinearGradient {
        let fadeStart = max(0, min(0.85, 1 - 26 / max(height, 1)))
        return LinearGradient(
            stops: [.init(color: .black, location: 0),
                    .init(color: .black, location: fadeStart),
                    .init(color: .clear, location: 1)],
            startPoint: .top, endPoint: .bottom)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 44, height: 44)
                Image(systemName: "moon.zzz")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.subtext)
            }
            VStack(spacing: 3) {
                Text("No active sessions")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                Text("Agent sessions will appear here as you work")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.faint)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct SessionRow: View {
    let session: AgentSession
    @State private var hovering = false

    private var accent: Color { Color(hex: session.agent.accentHex) }
    private var live: Bool { session.isLive() }

    var body: some View {
        HStack(spacing: 11) {
            statusGlyph

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(live ? accent.opacity(0.95) : Theme.subtext)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 5) {
                if live {
                    Circle()
                        .fill(accent)
                        .frame(width: 4, height: 4)
                }
                Text(Format.ago(session.updatedAt))
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(live ? accent.opacity(0.8) : Theme.faint)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Theme.card(hovering: hovering, tint: live ? accent : .white, strength: live ? 1.5 : 1))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(Theme.cardStroke(hovering: hovering,
                                                       tint: live ? accent : .white,
                                                       strength: live ? 2.2 : 1),
                                      lineWidth: 0.5)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onTapGesture { TerminalFocus.focusFrontmostTerminal() }
    }

    private var statusGlyph: some View {
        ZStack {
            Circle()
                .fill(accent.opacity(live ? 0.20 : 0.10))
                .frame(width: 26, height: 26)
            Image(systemName: session.state.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(live ? accent : Theme.subtext)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.pulse, options: .repeating.speed(0.5), isActive: live)
        }
    }

    private var subtitle: String {
        var parts = [session.agent.displayName, session.project]
        if let model = session.model { parts.append(model) }
        parts.append(session.state.label)
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
