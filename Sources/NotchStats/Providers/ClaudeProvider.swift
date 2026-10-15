import Foundation

/// Claude Code / Anthropic plan limits.
///
/// Anthropic ships no public usage endpoint for end users; Claude Code itself
/// calls `api.anthropic.com/api/oauth/usage`, so we do the same. The token is
/// read from Claude Code's own credential store and never refreshed here.
///
/// What you get depends on how you signed in:
/// - **OAuth** (`sk-ant-oat…`, Pro/Max): the 5-hour and weekly windows.
/// - **API key** (`sk-ant-api…`): Anthropic reports that usage limits do not
///   apply to API organisations, which we surface verbatim-ish.
struct ClaudeProvider: UsageProvider {
    static let id = "claude"
    static let name = "Claude"
    static let accent = "#D97757"
    static let order = 1

    var id: String { Self.id }
    var name: String { Self.name }
    var accentHex: String { Self.accent }
    var order: Int { Self.order }

    func fetch() async -> ProviderUsage {
        let resolution = await ClaudeCredentials.resolveAsync()

        guard case let .found(credential, _) = resolution else {
            if case let .missing(message) = resolution { return Self.failure(message) }
            return Self.failure("No Claude credentials")
        }

        // Don't spend a request on an OAuth token we already know is stale.
        if credential.kind == .oauth,
           let expiresAt = credential.expiresAt, expiresAt <= Date() {
            return Self.failure("Token expired — run `claude`")
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("claude-code/2.1.301", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if credential.kind == .oauth {
            request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        } else {
            request.setValue(credential.token, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200:
                return Self.parse(data)
            case 400 where Self.isAPIOrganisationError(data):
                return Self.failure("API key login — usage limits don't apply")
            case 401:
                // The credential may have been rotated underneath us.
                ClaudeCredentials.invalidate()
                return Self.failure(credential.kind == .oauth
                                    ? "Auth expired — run `claude`"
                                    : "API key rejected")
            case 403:
                return Self.failure("Token lacks usage scope — run `claude`")
            case 429:
                return Self.failure("Rate limited — try again shortly")
            default:
                return Self.failure("HTTP \(status)")
            }
        } catch {
            return Self.failure(error.localizedDescription)
        }
    }

    // MARK: - Pure parsing (unit-tested)

    static func isAPIOrganisationError(_ data: Data) -> Bool {
        guard let object = jsonObject(data),
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String else { return false }
        return message.contains("not applicable to API organizations")
    }

    static func parse(_ data: Data) -> ProviderUsage {
        guard let object = jsonObject(data) else { return failure("Parse error") }

        // The endpoint can also return 200 with an error body.
        if let error = object["error"] as? [String: Any],
           (error["type"] as? String) == "rate_limit_error" {
            return failure("Rate limited")
        }

        var windows: [UsageWindow] = []
        if let window = window(id: "5h", label: "5h", object["five_hour"]) { windows.append(window) }
        if let window = window(id: "7d", label: "Weekly", object["seven_day"]) { windows.append(window) }

        let plan = (object["subscriptionType"] as? String)
            ?? (object["subscription_type"] as? String)
        return ProviderUsage(id: id, name: name, accentHex: accent, order: order,
                             windows: windows,
                             note: plan?.capitalized,
                             error: windows.isEmpty ? "No data" : nil)
    }

    static func failure(_ message: String) -> ProviderUsage {
        .failure(id: id, name: name, accentHex: accent, order: order, message: message)
    }

    static func window(id: String, label: String, _ object: Any?) -> UsageWindow? {
        guard let dict = object as? [String: Any] else { return nil }
        // `utilization` is a percentage in 0...100, not a 0...1 fraction.
        guard let raw = asDouble(dict["utilization"]) ?? asDouble(dict["used_percent"]) else { return nil }
        return UsageWindow(id: id, label: label,
                           percent: max(0, min(1, raw / 100)),
                           resetsAt: resetDate(dict["resets_at"]))
    }

    private static func resetDate(_ value: Any?) -> Date? {
        if let seconds = asDouble(value) { return Date(timeIntervalSince1970: seconds) }
        return isoDate(value as? String)
    }
}
