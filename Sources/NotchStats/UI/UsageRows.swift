import SwiftUI

struct UsageList: View {
    let store: AppStore

    var body: some View {
        if store.providers.isEmpty {
            PanelMessage(
                symbol: store.lastRefresh == nil ? "circle.dotted" : "person.crop.circle.badge.questionmark",
                title: store.lastRefresh == nil ? "Loading usage…" : "No providers found",
                detail: store.lastRefresh == nil
                    ? "Reading your Claude, Codex and OpenCode logins"
                    : "Sign in to Claude Code, Codex or OpenCode to see limits here")
        } else {
            VStack(spacing: AppStore.rowSpacing) {
                ForEach(store.providers) { provider in
                    ProviderRow(provider: provider)
                }
            }
            .padding(.horizontal, Theme.margin)
        }
    }
}

/// Empty / loading state: a quiet glyph and two lines, centred in the space
/// the rows would have taken.
struct PanelMessage: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Theme.label)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.white.opacity(0.06)))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(Theme.label)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Theme.Space.l * 2)
        .accessibilityElement(children: .combine)
    }
}

/// The one grid every row sits on: three equal slots, right-aligned, with the
/// same gutter between them. A row with three figures fills all three slots; two
/// figures take the right-hand two; a lone figure (spend, credits) spans the
/// right-hand two. Whatever the count, every left edge lands on the same set of
/// vertical lines and every row ends on the same right edge.
enum UsageGrid {
    static let slot: CGFloat = 104
    static let gutter: CGFloat = 16
    static var span: CGFloat { slot * 2 + gutter }
    static var total: CGFloat { slot * 3 + gutter * 2 }

    static func width(forFigures count: Int) -> CGFloat { count == 1 ? span : slot }
}

/// One provider: identity on the left, its figures on the grid on the right.
///
/// Every number is "left", never "used", and the big figure is always the
/// first thing in a column. A provider with no quota (dollar spend) shows a
/// figure instead of a gauge, so nothing implies a limit that doesn't exist; a
/// provider that can't be read says why, and what to do.
struct ProviderRow: View {
    let provider: ProviderUsage
    @State private var hovering = false

    private var accent: Color { Color(hex: provider.accentHex) }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            identity
                .frame(maxWidth: .infinity, alignment: .leading)
            if let error = provider.error {
                failure(error)
                    .frame(width: UsageGrid.total, alignment: .trailing)
            } else {
                figures
                    .frame(width: UsageGrid.total, alignment: .trailing)
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(height: AppStore.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.card(hovering: hovering))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.cardStroke(hovering: hovering), lineWidth: 0.5)
                )
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private var figures: some View {
        let count = provider.windows.count + provider.metrics.count
        let width = UsageGrid.width(forFigures: count)
        return HStack(spacing: UsageGrid.gutter) {
            ForEach(provider.windows) { window in
                WindowFigure(window: window, accent: accent, width: width,
                             detail: detail(for: window), dimmed: provider.isStale)
            }
            ForEach(provider.metrics, id: \.label) { metric in
                MetricFigure(metric: metric, width: width)
            }
        }
    }

    /// A window without a reset time (credits) shows the provider's own note —
    /// the dollar balance — where a countdown would go, unless that note is a
    /// plan label already shown under the provider's name.
    static func detail(for window: UsageWindow, in provider: ProviderUsage,
                       now: Date = Date()) -> WindowFigure.Detail? {
        if let reset = Format.countdown(to: window.resetsAt, now: now) { return .reset(reset) }
        if provider.windows.count == 1, planLabel(for: provider) == nil, let note = provider.note {
            return .text(note)
        }
        return nil
    }

    static func planLabel(for provider: ProviderUsage) -> String? {
        guard provider.error == nil, !provider.windows.isEmpty else { return nil }
        return provider.note.flatMap { $0.hasSuffix("plan") || provider.id == ClaudeProvider.id ? $0 : nil }
    }

    private func detail(for window: UsageWindow) -> WindowFigure.Detail? {
        Self.detail(for: window, in: provider)
    }

    private var identity: some View {
        HStack(spacing: Theme.Space.s) {
            Circle()
                .fill(accent)
                .frame(width: 8, height: 8)
                .opacity(provider.error == nil ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let line = secondary {
                    Text(line)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.label)
                        .lineLimit(1)
                }
            }
        }
    }

    /// The plan, or — when the reading is old — why.
    private var secondary: String? {
        if provider.isStale { return "Last reading" }
        guard provider.error == nil else { return nil }
        if provider.windows.isEmpty { return provider.metrics.isEmpty ? provider.note : "API usage" }
        return Self.planLabel(for: provider)
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warn)
                Text(message)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            if let hint = provider.hint {
                Text(hint)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var spoken: String {
        if let error = provider.error {
            return [provider.name, error, provider.hint].compactMap { $0 }.joined(separator: ". ")
        }
        var parts = [provider.name]
        if provider.isStale { parts.append("last reading") }
        for window in provider.windows {
            var text = "\(window.label) window, \(Format.percent(window.remaining)) left"
            if let reset = Format.countdown(to: window.resetsAt) { text += ", resets in \(reset)" }
            parts.append(text)
        }
        for metric in provider.metrics {
            parts.append("\(metric.label) \(metric.value)" + (metric.detail.map { ", \($0)" } ?? ""))
        }
        return parts.joined(separator: ". ")
    }
}

/// One quota window: label and reset time on a line, the remaining share as
/// the figure, and a hairline bar underneath. A tight window turns the figure
/// and bar warning-coloured *and* gains a glyph.
struct WindowFigure: View {
    enum Detail: Equatable {
        case reset(String)
        case text(String)
    }

    let window: UsageWindow
    let accent: Color
    var width: CGFloat = UsageGrid.slot
    var detail: Detail?
    var dimmed = false

    var body: some View {
        let urgent = Theme.isUrgent(window.percent)
        let tint = Theme.urgency(window.percent, base: accent)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(window.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.label)
                Spacer(minLength: 0)
                switch detail {
                case let .reset(time):
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.glyph)
                    Text(time)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.label)
                case let .text(text):
                    Text(text)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.label)
                case nil:
                    EmptyView()
                }
            }
            .lineLimit(1)
            HStack(spacing: 4) {
                if urgent, let glyph = Theme.urgencyGlyph(window.percent) {
                    Image(systemName: glyph)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                }
                Text(Format.percent(window.remaining))
                    .font(.system(size: 20, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(urgent ? tint : .primary)
                    .numericFlip(window.remaining)
            }
            Capsule()
                .fill(Theme.track)
                .frame(height: 3)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(tint)
                            .frame(width: max(3, proxy.size.width * window.remaining))
                    }
                }
        }
        .frame(width: width)
        .opacity(dimmed ? 0.55 : 1)
    }
}

/// A figure with no quota behind it (spend). Same structure as a window —
/// label and detail on one line, the figure beneath — with no gauge.
struct MetricFigure: View {
    let metric: UsageMetric
    var width: CGFloat = UsageGrid.span

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(metric.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.label)
                Spacer(minLength: 0)
                if let detail = metric.detail {
                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.label)
                }
            }
            .lineLimit(1)
            Text(metric.value)
                .font(.system(size: 20, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
            // Where a window draws its bar; keeps the baselines aligned.
            Color.clear.frame(height: 3)
        }
        .frame(width: width, alignment: .leading)
    }
}
