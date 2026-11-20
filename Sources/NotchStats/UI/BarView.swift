import SwiftUI

// MARK: - Collapsed & peek bar
//
// The bar is read at a glance, at notch size. One idea per ear: a ring and the
// number of percent *left*. An agent that is working has a dot in its ring and
// a brighter number; a reading that is out of date is dimmed; a provider that
// can't be read shows a single warning glyph instead of a number.

enum EarSide { case left, right }

/// One provider shown in the collapsed/peek bar.
struct BarEntry: Identifiable {
    let provider: ProviderUsage
    let live: Bool
    var id: String { provider.id }
}

struct BarView: View {
    let store: AppStore
    let geometry: IslandGeometry
    var detailed: Bool

    /// Codex owns the left ear; Claude and OpenCode Go share the right one.
    /// A provider with an error keeps its slot (as a warning) rather than
    /// silently disappearing.
    private var entries: [BarEntry] {
        [(CodexProvider.id, AgentKind.codex),
         (ClaudeProvider.id, AgentKind.claude),
         (OpenCodeGoProvider.id, AgentKind.opencode)]
            .compactMap { id, kind in
                guard let provider = store.provider(id),
                      provider.headline != nil || provider.error != nil else { return nil }
                return BarEntry(provider: provider, live: store.isAgentLive(kind))
            }
    }

    var body: some View {
        let codex = entries.first { $0.provider.id == CodexProvider.id }
        let others = entries.filter { $0.provider.id != CodexProvider.id }

        return Group {
            if geometry.hasNotch {
                // The peek island is 70 pt wider; each ear gets half of it.
                let ear = geometry.earWidth + (detailed ? 35 : 0)
                HStack(spacing: 0) {
                    LeftEar(entry: codex, detailed: detailed)
                        .frame(width: ear, alignment: .leading)
                    Spacer(minLength: 0)
                    EarStack(entries: others, side: .right, detailed: detailed)
                        .frame(width: ear, alignment: .trailing)
                }
            } else {
                HStack(spacing: Theme.Space.l) {
                    ForEach(entries) { entry in
                        Ear(entry: entry,
                            side: entry.provider.id == CodexProvider.id ? .left : .right,
                            detailed: detailed)
                    }
                }
                .padding(.horizontal, Theme.Space.l)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// Codex owns the left ear. It shows its 5-hour and weekly windows as two
/// rows built exactly like the right ear's, so both ears carry the same weight
/// and the same ring size and stroke.
private struct LeftEar: View {
    let entry: BarEntry?
    let detailed: Bool

    var body: some View {
        if let entry {
            let windows = Array(entry.provider.windows.prefix(2))
            if windows.count == 2 {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(windows) { window in
                        CompactEarRow(entry: entry, window: window, side: .left, detailed: detailed)
                    }
                }
                .padding(.horizontal, Theme.Space.m)
            } else {
                CompactEarRow(entry: entry, window: windows.first, side: .left, detailed: detailed)
                    .padding(.horizontal, Theme.Space.m)
            }
        } else {
            Circle().fill(Color.white.opacity(0.18)).frame(width: 6, height: 6)
                .padding(.horizontal, Theme.Space.m)
        }
    }
}

/// An ear holding one or more indicators. Two providers stack vertically so
/// the island can stay notch-wide.
private struct EarStack: View {
    let entries: [BarEntry]
    var side: EarSide
    var detailed: Bool

    var body: some View {
        if entries.isEmpty {
            Circle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 6, height: 6)
        } else if entries.count == 1, let entry = entries.first {
            CompactEarRow(entry: entry, side: side, detailed: detailed)
                .padding(.horizontal, Theme.Space.m)
        } else {
            VStack(alignment: side == .left ? .leading : .trailing, spacing: 2) {
                ForEach(entries) { entry in
                    CompactEarRow(entry: entry, side: side, detailed: detailed)
                }
            }
            // Keep clear of the island's rounded bottom corner.
            .padding(.horizontal, Theme.Space.m)
        }
    }
}

/// What the bar says about one provider, shared by every layout.
private struct BarReading {
    let entry: BarEntry

    var provider: ProviderUsage { entry.provider }
    var window: UsageWindow? { provider.headline }
    var tint: Color {
        Theme.urgency(window?.percent ?? 0, base: Color(hex: provider.accentHex))
    }
    /// A reading that is current and from an agent that is working is the
    /// brightest thing in the bar.
    var numberStyle: Color {
        if provider.isStale { return .white.opacity(0.62) }
        return entry.live ? .white : .white.opacity(0.9)
    }

    var accessibilityLabel: String {
        if let error = provider.error { return "\(provider.name): \(error)" }
        guard let window else { return provider.name }
        var text = "\(provider.name): \(Format.percent(window.remaining)) left"
        if entry.live { text += ", working" }
        if provider.isStale { text += ", last reading" }
        return text
    }
}

private struct Warning: View {
    let issue: ProviderIssue?
    let size: CGFloat
    var showsText: Bool

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Theme.warn)
            if showsText, let issue {
                Text(issue.shortLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}

private struct CompactEarRow: View {
    let entry: BarEntry
    var window: UsageWindow?
    let side: EarSide
    let detailed: Bool

    init(entry: BarEntry, window: UsageWindow? = nil, side: EarSide, detailed: Bool) {
        self.entry = entry
        self.window = window ?? entry.provider.headline
        self.side = side
        self.detailed = detailed
    }

    /// One ring size and one stroke for every indicator in the bar.
    static func ring(detailed: Bool) -> (size: CGFloat, line: CGFloat) {
        detailed ? (14, 2.5) : (12, 2.5)
    }

    var body: some View {
        let reading = BarReading(entry: entry)
        Group {
            if let window {
                let metrics = Self.ring(detailed: detailed)
                let tint = Theme.urgency(window.percent, base: Color(hex: entry.provider.accentHex))
                let ring = Ring(progress: window.remaining, color: tint,
                                size: metrics.size, lineWidth: metrics.line,
                                live: entry.live && window.id == entry.provider.headline?.id)
                let label = Text(Format.percent(window.remaining))
                    .font(.system(size: detailed ? 12 : 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(reading.numberStyle)
                    .lineLimit(1)
                    .fixedSize()
                    .numericFlip(window.remaining)
                // The peek adds when the window resets, in the same row.
                let reset = detailed ? Format.countdown(to: window.resetsAt) : nil
                let resetLabel = Text(reset ?? "")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .fixedSize()
                HStack(spacing: Theme.Space.xs) {
                    if side == .left {
                        ring; label
                        if reset != nil { resetLabel }
                    } else {
                        if reset != nil { resetLabel }
                        label; ring
                    }
                }
            } else {
                Warning(issue: reading.provider.issue, size: detailed ? 11 : 10, showsText: detailed)
            }
        }
        // Two rows must fit the bar: pin the row height so the line height
        // of the text can't push the stack past the notch.
        .frame(height: detailed ? 14 : 13)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.map { "\(entry.provider.name) \($0.label): \(Format.percent($0.remaining)) left" }
                            ?? reading.accessibilityLabel)
    }
}

struct Ear: View {
    let entry: BarEntry
    var side: EarSide = .left
    var detailed: Bool = false

    var body: some View {
        let reading = BarReading(entry: entry)
        Group {
            if let window = reading.window {
                let ring = Ring(progress: window.remaining, color: reading.tint,
                                size: detailed ? 24 : 16,
                                lineWidth: detailed ? 3.5 : 2.5, live: entry.live)
                HStack(spacing: detailed ? Theme.Space.s : 6) {
                    if side == .left { ring; label(reading, window) } else { label(reading, window); ring }
                }
            } else {
                Warning(issue: reading.provider.issue, size: detailed ? 14 : 12, showsText: detailed)
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reading.accessibilityLabel)
    }

    @ViewBuilder
    private func label(_ reading: BarReading, _ window: UsageWindow) -> some View {
        VStack(alignment: side == .left ? .leading : .trailing, spacing: 0) {
            Text(Format.percent(window.remaining))
                .font(.system(size: detailed ? 15 : 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(reading.numberStyle)
                .lineLimit(1)
                .fixedSize()
                .numericFlip(window.remaining)
            if detailed, let reset = Format.countdown(to: window.resetsAt) {
                Text("resets \(reset)")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}
