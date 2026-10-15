import SwiftUI

struct IslandRootView: View {
    let store: AppStore
    let geometry: IslandGeometry

    var body: some View {
        liveBody
    }

    private var liveBody: some View {
        let size = store.islandSize(for: geometry)
        return ZStack(alignment: .top) {
            IslandBackground(geometry: geometry, expanded: store.state == .expanded)
            content
                .id(store.state)
                .transition(.opacity)
                .frame(width: size.width, height: size.height, alignment: .top)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onHover { store.setHover($0) }
        .onTapGesture { store.toggleExpanded() }
        .animation(.spring(response: 0.38, dampingFraction: 0.85), value: store.state)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var content: some View {
        switch store.state {
        case .collapsed: BarView(store: store, geometry: geometry, detailed: false)
        case .peek: BarView(store: store, geometry: geometry, detailed: true)
        case .expanded: ExpandedView(store: store)
        }
    }
}

struct IslandBackground: View {
    let geometry: IslandGeometry
    var expanded: Bool = false

    private static let debugFill: Color? =
        ProcessInfo.processInfo.environment["NOTCHSTATS_DEBUG_BG"].map { _ in Color(hex: "#243244") }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: geometry.topRadius,
                               bottomLeadingRadius: expanded ? 22 : geometry.bottomRadius,
                               bottomTrailingRadius: expanded ? 22 : geometry.bottomRadius,
                               topTrailingRadius: geometry.topRadius,
                               style: .continuous)
    }

    private var hairline: some View {
        shape.strokeBorder(Theme.hairline(expanded: expanded), lineWidth: 0.5)
    }

    var body: some View {
        if let debugFill = Self.debugFill {
            // Test hook: flat, screenshot-friendly fill.
            shape.fill(debugFill).overlay(hairline)
        } else if expanded {
            shape
                .fill(Theme.panelGradient)
                .overlay(shape.fill(Theme.panelSheen))
                .overlay(hairline)
        } else {
            // Collapsed/peek: pure black so the ear merges with the housing.
            shape.fill(Color.black).overlay(hairline)
        }
    }
}

// MARK: - Collapsed & peek bar

enum EarSide { case left, right }

struct BarView: View {
    let store: AppStore
    let geometry: IslandGeometry
    var detailed: Bool

    var body: some View {
        let codex = store.provider("codex")
        let opencode = store.provider("opencode")

        return Group {
            if geometry.hasNotch {
                HStack(spacing: 0) {
                    Ear(provider: codex, side: .left, detailed: detailed,
                        live: store.isAgentLive(.codex), ringSize: detailed ? 24 : 14)
                        .frame(width: geometry.earWidth, alignment: .leading)
                    Spacer(minLength: 0)
                    Ear(provider: opencode, side: .right, detailed: detailed,
                        live: store.isAgentLive(.opencode), ringSize: detailed ? 24 : 14)
                        .frame(width: geometry.earWidth, alignment: .trailing)
                }
            } else {
                HStack(spacing: 16) {
                    Ear(provider: codex, side: .left, detailed: detailed,
                        live: store.isAgentLive(.codex), ringSize: detailed ? 24 : 15)
                    Ear(provider: opencode, side: .right, detailed: detailed,
                        live: store.isAgentLive(.opencode), ringSize: detailed ? 24 : 15)
                }
                .padding(.horizontal, 16)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

struct Ear: View {
    let provider: ProviderUsage?
    var side: EarSide = .left
    var detailed: Bool = false
    var live: Bool = false
    var ringSize: CGFloat = 14

    var body: some View {
        if let provider, let headline = provider.headline {
            let color = Theme.urgency(headline.percent, base: Color(hex: provider.accentHex))
            let ring = Ring(progress: headline.percent, color: color,
                            size: ringSize, lineWidth: detailed ? 4 : 3, live: live)

            HStack(spacing: detailed ? 8 : 5) {
                if side == .left { ring; label(provider, headline) } else { label(provider, headline); ring }
            }
            .padding(.horizontal, 6)
        } else {
            Circle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 6, height: 6)
        }
    }

    @ViewBuilder
    private func label(_ provider: ProviderUsage, _ window: UsageWindow) -> some View {
        VStack(alignment: side == .left ? .leading : .trailing, spacing: 1) {
            Text(Format.percent(window.percent))
                .font(.system(size: detailed ? 15 : 11.5,
                              weight: detailed ? .bold : .semibold,
                              design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .numericFlip(window.percent)
            if detailed, let reset = Format.countdown(to: window.resetsAt) {
                Text("resets \(reset)")
                    .font(.system(size: 9))
                    .tracking(0.2)
                    .monospacedDigit()
                    .foregroundStyle(Theme.subtext)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    let store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            switch store.page {
            case .usage:
                usageList
                Spacer(minLength: 0)
            case .activity:
                ActivityView(store: store)
                    .frame(maxHeight: .infinity)
            }
            footer
        }
        .padding(.bottom, 12)
    }

    private var header: some View {
        HStack(spacing: 8) {
            tab("USAGE", .usage)
            tab("ACTIVITY", .activity, badge: store.liveAgents.isEmpty ? nil : store.liveAgents.count)
            Spacer()
            if store.refreshing {
                ProgressView().controlSize(.small).scaleEffect(0.6).tint(Theme.faint)
            } else if let last = store.lastRefresh {
                Text("updated \(Format.ago(last))")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private func tab(_ title: String, _ page: AppStore.Page, badge: Int? = nil) -> some View {
        let selected = store.page == page
        return Button {
            store.page = page
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                if let badge {
                    Text("\(badge)")
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Theme.opencode))
                }
            }
            .foregroundStyle(selected ? .white : Theme.subtext)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(selected ? Color.white.opacity(0.10) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: selected)
    }

    @ViewBuilder private var usageList: some View {
        VStack(spacing: 12) {
            if store.providers.isEmpty {
                VStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.05))
                            .frame(width: 44, height: 44)
                        Image(systemName: "circle.dotted")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Theme.subtext)
                    }
                    VStack(spacing: 3) {
                        Text("Loading usage…")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                        Text("Talking to your providers")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.faint)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                ForEach(store.providers) { provider in
                    ProviderRow(provider: provider)
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 0.5)
                .padding(.horizontal, 18)
            HStack(spacing: 6) {
                switch store.page {
                case .usage:
                    ForEach(store.providers) { provider in
                        Circle()
                            .fill(provider.error != nil
                                  ? Theme.crit
                                  : Theme.urgency(provider.headline?.percent ?? 0,
                                                  base: Color(hex: provider.accentHex)))
                            .frame(width: 4.5, height: 4.5)
                    }
                    Text(store.providers.isEmpty ? "Connecting…" : "\(store.providers.count) providers")
                    Spacer()
                    if let next = store.providers.compactMap({ $0.headline?.resetsAt }).min(),
                       let countdown = Format.countdown(to: next) {
                        Text("next reset \(countdown)")
                    }
                case .activity:
                    Circle()
                        .fill(store.liveAgents.isEmpty ? Theme.faint : Color(hex: "#34C759"))
                        .frame(width: 4.5, height: 4.5)
                    Text(store.sessions.isEmpty
                         ? "No sessions"
                         : "\(store.sessions.count) sessions · \(store.liveAgents.count) live")
                    Spacer()
                }
            }
            .font(.system(size: 9.5))
            .foregroundStyle(Theme.faint)
            .padding(.horizontal, 18)
            .padding(.top, 9)
        }
        .padding(.top, 10)
    }
}

struct ProviderRow: View {
    let provider: ProviderUsage
    @State private var hovering = false

    var body: some View {
        let accent = Color(hex: provider.accentHex)
        let tint = Theme.urgency(provider.headline?.percent ?? 0, base: accent)
        HStack(spacing: 12) {
            if provider.error != nil {
                ZStack {
                    Circle()
                        .stroke(Theme.crit.opacity(0.35), lineWidth: 2)
                        .frame(width: 34, height: 34)
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.crit)
                }
                .frame(width: 38, height: 38)
            } else {
                Ring(progress: provider.headline?.percent ?? 0,
                     color: tint,
                     size: 38, lineWidth: 5)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                HStack(spacing: 4) {
                    if provider.error != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8.5))
                    }
                    Text(subtitle)
                        .lineLimit(1)
                }
                .font(.system(size: 11))
                .foregroundStyle(provider.error == nil ? Theme.subtext : Theme.crit.opacity(0.9))
            }

            Spacer(minLength: 8)

            ForEach(provider.windows.dropFirst()) { window in
                MiniStat(window: window, color: accent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.card(hovering: hovering))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.cardStroke(hovering: hovering), lineWidth: 0.5)
                )
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private var subtitle: String {
        if let error = provider.error { return error }
        var parts: [String] = []
        if let headline = provider.headline {
            var text = headline.label
            if let reset = Format.countdown(to: headline.resetsAt) { text += " · resets \(reset)" }
            parts.append(text)
        }
        if let note = provider.note { parts.append(note) }
        return parts.joined(separator: " · ")
    }
}

struct MiniStat: View {
    let window: UsageWindow
    let color: Color

    var body: some View {
        let tint = Theme.urgency(window.percent, base: color)
        VStack(spacing: 3) {
            Text(window.label.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.subtext)
            Text(Format.percent(window.percent))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .numericFlip(window.percent)
            Capsule()
                .fill(tint.opacity(0.18))
                .frame(width: 36, height: 3)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(3, 36 * min(1, max(0, window.percent))), height: 3)
                }
        }
        .frame(minWidth: 44)
        .animation(.easeOut(duration: 0.5), value: window.percent)
    }
}
