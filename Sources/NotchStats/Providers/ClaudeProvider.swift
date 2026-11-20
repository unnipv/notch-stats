import Foundation

/// Claude Code / Anthropic plan limits.
///
/// Anthropic ships no public usage endpoint for end users; Claude Code itself
/// calls `api.anthropic.com/api/oauth/usage`, so we do the same. The token is
/// read from Claude Code's own credentials file (or, if the user opted in, its
/// keychain item) and never refreshed here.
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

    func fetch() async -> ProviderUsage? {
        let resolution = await ClaudeCredentials.resolveAsync()

        guard case let .found(credential, _) = resolution else {
            if case let .missing(failure) = resolution { return Self.failure(failure) }
            return Self.failure(.notSignedIn)
        }

        // Don't spend a request on an OAuth token we already know is stale.
        // Claude Code renews it itself; we re-read on the normal cadence.
        if credential.isExpired() { return Self.expired() }

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
            let (data, response) = try await HTTP.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 {
                // The credential may have been rotated underneath us; forget
                // the remembered one so the next attempt reads the sources again.
                ClaudeCredentials.invalidate()
            }
            return Self.response(status: status, data: data, kind: credential.kind)
        } catch {
            return Self.transportFailure(error)
        }
    }

    // MARK: - Failure states (unit-tested)

    /// Nothing usable was found locally.
    static func failure(_ failure: ClaudeCredentials.Failure) -> ProviderUsage {
        switch failure {
        case .notSignedIn:
            return issue(.notSignedIn, "Not signed in to Claude", "Run `claude` to sign in")
        case .keychainNotAllowed:
            return issue(.keychainNotAllowed, "Claude login found, not readable",
                         "Menu bar ▸ Allow Keychain Access")
        case .keychainDenied:
            return issue(.keychainDenied, "Keychain access denied",
                         "Unlock the keychain, or re-enable it in the menu")
        case .fileUnreadable:
            return issue(.unreadable, "Claude credentials unreadable", "File is being rewritten — retrying")
        }
    }

    static func expired() -> ProviderUsage {
        issue(.tokenExpired, "Claude token expired", "Open Claude Code to renew it")
    }

    /// Maps the usage endpoint's answer to a reading or a specific failure.
    static func response(status: Int, data: Data, kind: ClaudeCredentials.Kind) -> ProviderUsage {
        switch status {
        case 200:
            return parse(data)
        case 400 where isAPIOrganisationError(data):
            return failure("API key login — usage limits don't apply")
        case 401:
            return kind == .oauth
                ? issue(.rejected, "Claude token rejected", "Open Claude Code to sign in again")
                : issue(.rejected, "API key rejected", "Check the key Claude Code is using")
        case 403:
            return issue(.rejected, "Token lacks usage scope", "Run `claude` and sign in again")
        case 429:
            return issue(.rateLimited, "Rate limited", "Retrying shortly")
        case 500...599:
            return issue(.unreachable, "Anthropic unavailable", "HTTP \(status) — retrying")
        default:
            return failure("HTTP \(status)")
        }
    }

    static func transportFailure(_ error: Error) -> ProviderUsage {
        issue(.unreachable, "Can't reach Anthropic", "Check your connection — retrying")
    }

    private static func issue(_ issue: ProviderIssue, _ message: String, _ hint: String) -> ProviderUsage {
        .failure(id: id, name: name, accentHex: accent, order: order,
                 message: message, hint: hint, issue: issue)
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
