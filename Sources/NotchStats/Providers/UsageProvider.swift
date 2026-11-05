import Foundation

/// A source of usage data (Codex, Claude, OpenCode Go, OpenRouter, …).
protocol UsageProvider: Sendable {
    var id: String { get }
    var name: String { get }
    var accentHex: String { get }
    var order: Int { get }

    /// Returns nil when the provider isn't configured, so its row is omitted
    /// rather than shown as an error.
    func fetch() async -> ProviderUsage?
}

extension UsageProvider {
    /// Placeholder shown when a provider exceeds its time budget.
    func timedOut() -> ProviderUsage {
        .failure(id: id, name: name, accentHex: accentHex, order: order,
                 message: "Timed out — will retry")
    }
}
