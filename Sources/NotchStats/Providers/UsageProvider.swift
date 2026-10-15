import Foundation

/// A source of usage data (Codex, Claude, OpenCode Go, OpenRouter, …).
protocol UsageProvider: Sendable {
    var id: String { get }
    var name: String { get }
    var accentHex: String { get }
    var order: Int { get }

    func fetch() async -> ProviderUsage
}

extension UsageProvider {
    /// Placeholder shown when a provider exceeds its time budget.
    func timedOut() -> ProviderUsage {
        .failure(id: id, name: name, accentHex: accentHex, order: order,
                 message: "Timed out — will retry")
    }
}
