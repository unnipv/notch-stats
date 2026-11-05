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
                        VStack(spacing: AppStore.rowSpacing) {
                            ForEach(store.sessions) { session in
                                SessionRow(session: session)
                            }
                        }
                        .padding(.horizontal, Theme.margin)
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
        PanelMessage(symbol: "moon.zzz", title: "No active sessions",
                     detail: "Agent sessions appear here as you work")
    }
}

struct SessionRow: View {
    let session: AgentSession
    @State private var hovering = false

    private var accent: Color { Color(hex: session.agent.accentHex) }
    private var live: Bool { session.isLive() }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            statusGlyph

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Space.s)

            Text(Format.ago(session.updatedAt))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(live ? Theme.live : Color.secondary)
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 52)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.card(hovering: hovering))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.cardStroke(hovering: hovering), lineWidth: 0.5)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onTapGesture { TerminalFocus.focusFrontmostTerminal() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(session.title), \(session.agent.displayName), \(session.state.label), \(Format.ago(session.updatedAt))")
        .accessibilityHint("Brings your terminal forward")
        .accessibilityAddTraits(.isButton)
    }

    /// Static glyph — a working session is marked by colour and a filled disc,
    /// never by a looping animation.
    private var statusGlyph: some View {
        ZStack {
            Circle()
                .fill(accent.opacity(live ? 0.22 : 0.10))
                .frame(width: 28, height: 28)
            Image(systemName: session.state.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(live ? accent : Color.secondary)
        }
    }

    private var subtitle: String {
        var parts = [session.agent.displayName, session.project]
        if let model = session.model { parts.append(model) }
        parts.append(session.state.label)
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
