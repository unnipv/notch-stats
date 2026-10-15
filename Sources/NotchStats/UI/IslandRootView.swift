import SwiftUI

struct IslandRootView: View {
    let store: AppStore

    var body: some View {
        let size = store.islandSize
        ZStack(alignment: .top) {
            IslandBackground(bottomRadius: store.state == .expanded ? 22 : 9)
            content
                .frame(width: size.width, height: size.height, alignment: .top)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onHover { store.setHover($0) }
        .onTapGesture { store.toggleExpanded() }
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: store.state)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var content: some View {
        switch store.state {
        case .collapsed: CollapsedView(store: store)
        case .peek: PeekView(store: store)
        case .expanded: ExpandedView(store: store)
        }
    }
}

struct IslandBackground: View {
    var bottomRadius: CGFloat = 9

    private static let debugFill: Color? =
        ProcessInfo.processInfo.environment["NOTCHSTATS_DEBUG_BG"].map { _ in Color(hex: "#243244") }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 0,
                               bottomLeadingRadius: bottomRadius,
                               bottomTrailingRadius: bottomRadius,
                               topTrailingRadius: 0,
                               style: .continuous)
    }

    var body: some View {
        shape
            .fill(Self.debugFill ?? Color.black)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.10), .white.opacity(0.02)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.5
                )
            )
    }
}

// MARK: - Collapsed

struct CollapsedView: View {
    let store: AppStore

    var body: some View {
        HStack(spacing: 0) {
            Ear(provider: store.provider("codex"), live: store.isAgentLive(.codex))
                .frame(width: store.earWidth, alignment: .leading)
            Spacer(minLength: 0)
            Ear(provider: store.provider("opencode"), live: store.isAgentLive(.opencode))
                .frame(width: store.earWidth, alignment: .trailing)
        }
        .frame(maxHeight: .infinity)
    }
}

struct Ear: View {
    let provider: ProviderUsage?
    var live: Bool = false

    var body: some View {
        if let provider, let headline = provider.headline {
            let color = Theme.urgency(headline.percent, base: Color(hex: provider.accentHex))
            HStack(spacing: 5) {
                Ring(progress: headline.percent, color: color, size: 14, lineWidth: 3, live: live)
                Text(Format.percent(headline.percent))
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 6)
        } else {
            Circle()
                .fill(Color.white.opacity(0.22))
                .frame(width: 6, height: 6)
        }
    }
}

// MARK: - Peek

struct PeekView: View {
    let store: AppStore

    var body: some View {
        HStack(spacing: 0) {
            PeekItem(provider: store.provider("codex"), alignment: .leading)
            Spacer(minLength: 0)
            PeekItem(provider: store.provider("opencode"), alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
    }
}

struct PeekItem: View {
    let provider: ProviderUsage?
    var alignment: HorizontalAlignment

    var body: some View {
        if let provider, let headline = provider.headline {
            let color = Theme.urgency(headline.percent, base: Color(hex: provider.accentHex))
            HStack(spacing: 7) {
                if alignment == .trailing {
                    textBlock(provider, headline, color)
                    Ring(progress: headline.percent, color: color, size: 24, lineWidth: 4)
                } else {
                    Ring(progress: headline.percent, color: color, size: 24, lineWidth: 4)
                    textBlock(provider, headline, color)
                }
            }
        } else {
            Text(provider?.name ?? "—")
                .font(.system(size: 11))
                .foregroundStyle(Theme.subtext)
        }
    }

    @ViewBuilder
    private func textBlock(_ provider: ProviderUsage, _ window: UsageWindow, _ color: Color) -> some View {
        VStack(alignment: alignment == .trailing ? .trailing : .leading, spacing: 1) {
            Text(Format.percent(window.percent))
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
            if let reset = Format.countdown(to: window.resetsAt) {
                Text("resets \(reset)")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.subtext)
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
            case .usage: usageList
            case .activity: ActivityView(store: store)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 14)
    }

    private var header: some View {
        HStack(spacing: 12) {
            tab("USAGE", .usage)
            tab("ACTIVITY", .activity, badge: store.liveAgents.isEmpty ? nil : store.liveAgents.count)
            Spacer()
            if store.refreshing {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            } else if let last = store.lastRefresh {
                Text("updated \(Format.ago(last))")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.subtext)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private func tab(_ title: String, _ page: AppStore.Page, badge: Int? = nil) -> some View {
        let selected = store.page == page
        return Button {
            store.page = page
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.1)
                if let badge {
                    Text("\(badge)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.opencode))
                }
            }
            .foregroundStyle(selected ? .white : Theme.subtext)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: selected)
    }

    @ViewBuilder private var usageList: some View {
        VStack(spacing: 8) {
            if store.providers.isEmpty {
                Text("Loading…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.subtext)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                ForEach(store.providers) { provider in
                    ProviderRow(provider: provider)
                }
            }
        }
        .padding(.horizontal, 12)
    }
}

struct ProviderRow: View {
    let provider: ProviderUsage

    var body: some View {
        let accent = Color(hex: provider.accentHex)
        HStack(spacing: 12) {
            Ring(progress: provider.headline?.percent ?? 0,
                 color: Theme.urgency(provider.headline?.percent ?? 0, base: accent),
                 size: 34, lineWidth: 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(provider.error == nil ? Theme.subtext : Theme.crit)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            ForEach(provider.windows.dropFirst()) { window in
                MiniStat(window: window, color: accent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)))
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
        VStack(spacing: 3) {
            Text(window.label.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.subtext)
            Text(Format.percent(window.percent))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .frame(minWidth: 44)
    }
}
