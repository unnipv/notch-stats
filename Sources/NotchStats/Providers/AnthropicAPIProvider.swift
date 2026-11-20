import Foundation

/// Pay-as-you-go Anthropic API spend, read from OpenCode's local ledger.
///
/// Anthropic has no public credit-balance endpoint: `/v1/organizations/*`
/// requires an Admin API key, and even then reports historical usage/cost, not
/// the remaining balance shown in the Console. So rather than invent a number,
/// NotchStats sums the `cost` OpenCode already records on each Anthropic
/// assistant message and reports month-to-date (plus today's) spend.
///
/// The row only appears when OpenCode holds an Anthropic *API key*. An OAuth
/// login belongs to a Claude subscription and isn't billed per use, so there is
/// nothing to total.
struct AnthropicAPIProvider: UsageProvider {
    static let id = "anthropic-api"
    static let name = "Anthropic API"
    static let accent = "#D97757"
    static let order = 2

    var id: String { Self.id }
    var name: String { Self.name }
    var accentHex: String { Self.accent }
    var order: Int { Self.order }

    func fetch() async -> ProviderUsage? {
        switch OpenCodeDB.anthropicKeyState() {
        case .none:
            return nil
        case .unavailable:
            return .failure(id: Self.id, name: Self.name, accentHex: Self.accent, order: Self.order,
                            message: "OpenCode database busy", hint: "Retrying shortly", issue: .busy)
        case .apiKey:
            break
        }
        guard let spend = AnthropicSpendLedger.shared.update() else {
            return .failure(id: Self.id, name: Self.name, accentHex: Self.accent, order: Self.order,
                            message: "Can't read OpenCode usage", hint: "Retrying shortly", issue: .busy)
        }
        return Self.usage(spend)
    }

    // MARK: - Presentation (unit-tested)

    static func usage(_ spend: OpenCodeDB.AnthropicSpend) -> ProviderUsage {
        ProviderUsage(id: id, name: name, accentHex: accent, order: order,
                      windows: [], note: note(spend), error: nil,
                      metrics: [UsageMetric(label: "This month",
                                            value: money(spend.monthToDate),
                                            detail: spend.today > 0 ? "\(money(spend.today)) today" : nil)])
    }

    static func note(_ spend: OpenCodeDB.AnthropicSpend) -> String {
        var text = "\(money(spend.monthToDate)) spent this month"
        if spend.today > 0 {
            text += " · \(money(spend.today)) today"
        }
        return text
    }

    /// Keeps sub-cent usage visible instead of rounding it away to `$0.00`.
    static func money(_ value: Double) -> String {
        if value > 0, value < 0.005 { return "<$0.01" }
        // Anthropic bills in USD; don't let the user's locale rewrite the decimal.
        return String(format: "$%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func failure(_ message: String) -> ProviderUsage {
        .failure(id: id, name: name, accentHex: accent, order: order, message: message)
    }
}
