import Foundation

/// OpenRouter credit balance from `GET https://openrouter.ai/api/v1/credits`.
struct OpenRouterProvider: UsageProvider {
    static let id = "openrouter"
    static let name = "OpenRouter"
    static let accent = "#7E8BF5"
    static let order = 5

    var id: String { Self.id }
    var name: String { Self.name }
    var accentHex: String { Self.accent }
    var order: Int { Self.order }


    func fetch() async -> ProviderUsage? {
        let lookup = OpenCodeDB.lookupCredential(integrationIDs: ["openrouter"])
        let credential: [String: Any]
        switch lookup {
        case .unavailable:
            return Self.issue(.busy, "OpenCode database busy", "Retrying shortly")
        case .none:
            return Self.issue(.notSignedIn, "No OpenRouter key", "Add one with `opencode auth login`")
        case let .found(json):
            credential = json
        }
        guard let key = (credential["key"] as? String) ?? (credential["access"] as? String) else {
            return Self.issue(.notSignedIn, "No OpenRouter key", "Add one with `opencode auth login`")
        }

        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/credits")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await HTTP.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200: return Self.parse(data)
            case 401, 403: return Self.issue(.rejected, "OpenRouter key rejected", "Check the key in OpenCode")
            case 429: return Self.issue(.rateLimited, "Rate limited", "Retrying shortly")
            case 500...599: return Self.issue(.unreachable, "OpenRouter unavailable", "HTTP \(status) — retrying")
            default: return Self.failure("HTTP \(status)")
            }
        } catch {
            return Self.issue(.unreachable, "Can't reach OpenRouter", "Check your connection — retrying")
        }
    }

    private static func issue(_ issue: ProviderIssue, _ message: String, _ hint: String) -> ProviderUsage {
        .failure(id: id, name: name, accentHex: accent, order: order,
                 message: message, hint: hint, issue: issue)
    }

    // MARK: - Pure parsing (unit-tested)

    static func parse(_ data: Data) -> ProviderUsage {
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let object = any as? [String: Any],
              let payload = object["data"] as? [String: Any],
              let total = asDouble(payload["total_credits"]),
              let used = asDouble(payload["total_usage"]) else {
            return failure("Parse error")
        }

        let remaining = max(0, total - used)
        let percent = total > 0 ? max(0, min(1, used / total)) : 0
        let window = UsageWindow(id: "credits", label: "Credits", percent: percent, resetsAt: nil)

        return ProviderUsage(id: id, name: name, accentHex: accent, order: order,
                             windows: [window],
                             note: String(format: "$%.2f", remaining),
                             error: nil)
    }

    static func failure(_ message: String) -> ProviderUsage {
        .failure(id: id, name: name, accentHex: accent, order: order, message: message)
    }
}
