import Foundation

/// A source of usage data (Codex, OpenCode Go, OpenRouter, …).
protocol UsageProvider: Sendable {
    func fetch() async -> ProviderUsage
}
