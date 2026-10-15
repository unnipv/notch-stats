import SwiftUI

struct ActivityView: View {
    let store: AppStore

    var body: some View {
        VStack(spacing: 8) {
            if store.sessions.isEmpty {
                empty
            } else {
                ForEach(store.sessions) { session in
                    SessionRow(session: session)
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 20))
                .foregroundStyle(Theme.subtext)
            Text("No sessions yet")
                .font(.system(size: 12))
                .foregroundStyle(Theme.subtext)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

struct SessionRow: View {
    let session: AgentSession

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
                    .foregroundStyle(live ? accent : Theme.subtext)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(Format.ago(session.updatedAt))
                .font(.system(size: 10))
                .foregroundStyle(Theme.subtext)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.white.opacity(live ? 0.075 : 0.04))
        )
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onTapGesture { TerminalFocus.focusFrontmostTerminal() }
    }

    private var statusGlyph: some View {
        ZStack {
            Circle()
                .fill(accent.opacity(live ? 0.22 : 0.12))
                .frame(width: 26, height: 26)
            Image(systemName: session.state.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(live ? accent : Theme.subtext)
        }
    }

    private var subtitle: String {
        var parts = [session.agent.displayName, session.project]
        if let model = session.model { parts.append(model) }
        parts.append(session.state.label)
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
