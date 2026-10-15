import Foundation

enum AgentKind: String, Sendable {
    case opencode
    case codex
    case claude

    var displayName: String {
        switch self {
        case .opencode: return "OpenCode"
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }

    var accentHex: String {
        switch self {
        case .opencode: return "#B47BFF"
        case .codex: return "#10A37F"
        case .claude: return "#D97757"
        }
    }
}

enum SessionState: Equatable, Sendable {
    case thinking
    case tool(String)
    case responding
    case compacting
    case done
    case failed(String)

    var label: String {
        switch self {
        case .thinking: return "Thinking"
        case .tool(let name): return "Running \(name)"
        case .responding: return "Responding"
        case .compacting: return "Compacting"
        case .done: return "Done"
        case .failed(let reason): return reason.isEmpty ? "Failed" : reason
        }
    }

    var symbol: String {
        switch self {
        case .thinking: return "brain"
        case .tool: return "wrench.and.screwdriver.fill"
        case .responding: return "text.bubble.fill"
        case .compacting: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    /// Work in progress — drives the live indicator.
    var isActive: Bool {
        switch self {
        case .thinking, .tool, .responding, .compacting: return true
        case .done, .failed: return false
        }
    }
}

struct AgentSession: Identifiable, Sendable {
    let id: String
    let agent: AgentKind
    let title: String
    let project: String
    let state: SessionState
    let model: String?
    let updatedAt: Date

    /// Recently touched and still working — what the collapsed island pulses for.
    func isLive(now: Date = Date()) -> Bool {
        now.timeIntervalSince(updatedAt) < 120 && state.isActive
    }
}
