import Foundation

/// Fictional data for screenshots and manual UI checks.
///
/// Enabled with `NOTCHSTATS_DEMO=1`. Real session titles and project names are
/// private, so documentation screenshots must never be captured against the
/// live store.
enum DemoData {

    static var providers: [ProviderUsage] {
        [
            ProviderUsage(
                id: CodexProvider.id, name: "Codex", accentHex: CodexProvider.accent,
                order: 0,
                windows: [
                    UsageWindow(id: "5h", label: "5h", percent: 0.32,
                                resetsAt: Date().addingTimeInterval(2 * 3600 + 22 * 60)),
                    UsageWindow(id: "7d", label: "Weekly", percent: 0.21,
                                resetsAt: Date().addingTimeInterval(4 * 86_400))
                ],
                note: "Plus plan", error: nil),

            ProviderUsage(
                id: OpenCodeGoProvider.id, name: "OpenCode Go", accentHex: OpenCodeGoProvider.accent,
                order: 1,
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
                order: 2,
                windows: [UsageWindow(id: "credits", label: "Credits", percent: 0.89, resetsAt: nil)],
                note: "$3.26", error: nil)
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
