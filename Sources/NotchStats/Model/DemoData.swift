import Foundation

/// Fictional data for screenshots and manual UI checks.
///
/// Enabled with `NOTCHSTATS_DEMO=1`. Real session titles and project names are
/// private, so documentation screenshots must never be captured against the
/// live store.
enum DemoData {

    static var providers: [ProviderUsage] {
        providers(variant: "1")
    }

    /// `1` is the healthy set; `errors`, `urgent` and `empty` exercise the other
    /// states the panel has to look right in.
    static func providers(variant: String) -> [ProviderUsage] {
        switch variant {
        case "empty": return []
        case "errors": return errorSet
        case "urgent": return urgentSet
        case "three": return [healthy[0], healthy[1], healthy[3]]
        case "four": return Array(healthy.prefix(4))
        default: return healthy
        }
    }

    private static var healthy: [ProviderUsage] {
        [
            ProviderUsage(
                id: CodexProvider.id, name: "Codex", accentHex: CodexProvider.accent,
                order: 0,
                windows: [
                    UsageWindow(id: "5h", label: "5h", percent: 0.32,
                                resetsAt: Date().addingTimeInterval(2 * 3600 + 22 * 60))
                ],
                note: "Plus plan", error: nil),

            ProviderUsage(
                id: ClaudeProvider.id, name: "Claude", accentHex: ClaudeProvider.accent,
                order: 1,
                windows: [
                    UsageWindow(id: "5h", label: "5h", percent: 0.14,
                                resetsAt: Date().addingTimeInterval(3 * 3600 + 12 * 60)),
                    UsageWindow(id: "7d", label: "Weekly", percent: 0.46,
                                resetsAt: Date().addingTimeInterval(5 * 86_400))
                ],
                note: "Max plan", error: nil),

            ProviderUsage(
                id: AnthropicAPIProvider.id, name: "Anthropic API",
                accentHex: AnthropicAPIProvider.accent,
                order: 2,
                windows: [],
                note: "$12.40 spent this month · $1.85 today", error: nil,
                metrics: [UsageMetric(label: "This month", value: "$12.40", detail: "$1.85 today")]),

            ProviderUsage(
                id: OpenCodeGoProvider.id, name: "OpenCode Go", accentHex: OpenCodeGoProvider.accent,
                order: 3,
                windows: [
                    UsageWindow(id: "rolling", label: "5h", percent: 0.0,
                                resetsAt: Date().addingTimeInterval(4 * 3600 + 59 * 60)),
                    UsageWindow(id: "weekly", label: "Weekly", percent: 0.62,
                                resetsAt: Date().addingTimeInterval(3 * 86_400)),
                    UsageWindow(id: "monthly", label: "Monthly", percent: 0.88,
                                resetsAt: Date().addingTimeInterval(9 * 86_400))
                ],
                note: nil, error: nil),

            ProviderUsage(
                id: OpenRouterProvider.id, name: "OpenRouter", accentHex: OpenRouterProvider.accent,
                order: 4,
                windows: [UsageWindow(id: "credits", label: "Credits", percent: 0.89, resetsAt: nil)],
                note: "$3.26", error: nil)
        ]
    }

    private static var urgentSet: [ProviderUsage] {
        var list = healthy
        list[0] = ProviderUsage(
            id: CodexProvider.id, name: "Codex", accentHex: CodexProvider.accent, order: 0,
            windows: [
                UsageWindow(id: "5h", label: "5h", percent: 0.93,
                            resetsAt: Date().addingTimeInterval(48 * 60))
            ],
            note: "Plus plan", error: nil)
        return list
    }

    private static var errorSet: [ProviderUsage] {
        var stale = healthy[0]
        stale.isStale = true
        stale.hint = "Can't reach ChatGPT"
        return [
            stale,
            ClaudeProvider.expired(),
            healthy[2],
            .failure(id: OpenCodeGoProvider.id, name: "OpenCode Go", accentHex: OpenCodeGoProvider.accent,
                     order: 3, message: "OpenCode token expired", hint: "Open OpenCode to refresh it",
                     issue: .rejected)
        ]
    }

    static var sessions: [AgentSession] {
        let now = Date()
        return [
            AgentSession(id: "demo-1", agent: .opencode,
                         title: "Add cursor pagination to /search",
                         project: "api-server", state: .tool("shell"),
                         model: "sonnet-4.6", updatedAt: now.addingTimeInterval(-19)),

            AgentSession(id: "demo-2", agent: .codex,
                         title: "Investigate flaky integration tests",
                         project: "checkout-service", state: .thinking,
                         model: "gpt-6.1", updatedAt: now.addingTimeInterval(-3 * 60)),

            AgentSession(id: "demo-3", agent: .opencode,
                         title: "Extract billing rules into a module",
                         project: "web-app", state: .done,
                         model: "opus-5.2", updatedAt: now.addingTimeInterval(-42 * 60)),

            AgentSession(id: "demo-4", agent: .opencode,
                         title: "Write migration for the events table",
                         project: "data-pipeline", state: .done,
                         model: "sonnet-4.6", updatedAt: now.addingTimeInterval(-3 * 3600))
        ]
    }
}
