import Foundation

/// Codex / ChatGPT plan limits from `~/.codex/auth.json` → `chatgpt.com/backend-api/wham/usage`.
struct CodexProvider: UsageProvider {
    static let id = "codex"
    static let name = "Codex"
    static let accent = "#10A37F"
    static let order = 0

    var id: String { Self.id }
    var name: String { Self.name }
    var accentHex: String { Self.accent }
    var order: Int { Self.order }


    func fetch() async -> ProviderUsage? {
        var read = Self.readToken()
        if read == .unreadable {
            // `codex` rewrites auth.json in place; a read can land mid-write.
            try? await Task.sleep(nanoseconds: 250_000_000)
            read = Self.readToken()
        }
        guard case let .token(token) = read else { return Self.failure(read) }

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("NotchStats", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await HTTP.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return Self.response(status: status, data: data)
        } catch {
            return Self.issue(.unreachable, "Can't reach ChatGPT", "Check your connection — retrying")
        }
    }

    // MARK: - Failure states (unit-tested)

    static func response(status: Int, data: Data) -> ProviderUsage {
        switch status {
        case 200: return parse(data)
        case 401, 403: return issue(.rejected, "Codex login rejected", "Run `codex login`")
        case 429: return issue(.rateLimited, "Rate limited", "Retrying shortly")
        case 500...599: return issue(.unreachable, "ChatGPT unavailable", "HTTP \(status) — retrying")
        default: return failure("HTTP \(status)")
        }
    }

    static func failure(_ read: TokenRead) -> ProviderUsage {
        switch read {
        case .missing, .token:
            return issue(.notSignedIn, "Not signed in to Codex", "Run `codex login`")
        case .unreadable:
            return issue(.busy, "Codex login unreadable", "auth.json was being rewritten — retrying")
        }
    }

    private static func issue(_ issue: ProviderIssue, _ message: String, _ hint: String) -> ProviderUsage {
        .failure(id: id, name: name, accentHex: accent, order: order,
                 message: message, hint: hint, issue: issue)
    }

    // MARK: - Pure parsing (unit-tested)

    static func parse(_ data: Data) -> ProviderUsage {
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let object = any as? [String: Any] else {
            return failure("Parse error")
        }

        let rateLimit = object["rate_limit"] as? [String: Any] ?? [:]
        var windows: [UsageWindow] = []
        if let window = window(id: "5h", label: "5h", rateLimit["primary_window"]) { windows.append(window) }
        if let window = window(id: "7d", label: "Weekly", rateLimit["secondary_window"]) { windows.append(window) }

        let plan = object["plan_type"] as? String
        return ProviderUsage(id: id, name: name, accentHex: accent, order: order,
                             windows: windows,
                             note: plan.map { "\($0.capitalized) plan" },
                             error: windows.isEmpty ? "No data" : nil)
    }

    static func failure(_ message: String) -> ProviderUsage {
        .failure(id: id, name: name, accentHex: accent, order: order, message: message)
    }

    static func window(id: String, label: String, _ object: Any?) -> UsageWindow? {
        guard let dict = object as? [String: Any], let used = asDouble(dict["used_percent"]) else { return nil }
        let reset = asDouble(dict["reset_at"]).map { Date(timeIntervalSince1970: $0) }
        return UsageWindow(id: id, label: label, percent: max(0, min(1, used / 100)), resetsAt: reset)
    }

    enum TokenRead: Equatable {
        case token(String)
        /// No auth file: the user isn't signed in.
        case missing
        /// The file exists but isn't valid yet (half-written, or an unexpected shape).
        case unreadable
    }

    static func readToken(path: String = NSHomeDirectory() + "/.codex/auth.json") -> TokenRead {
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        guard let data = FileManager.default.contents(atPath: path),
              let object = jsonObject(data),
              let tokens = object["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else { return .unreadable }
        return .token(token)
    }

    static func accessToken() -> String? {
        if case let .token(token) = readToken() { return token }
        return nil
    }
}
