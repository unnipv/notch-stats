import Foundation

/// OpenCode Go subscription windows from the official quota endpoint:
/// `GET https://opencode.ai/zen/go/v1/usage`.
///
/// The bearer token is read from OpenCode's own credential store. We never
/// refresh it ourselves — the CLI keeps its token current.
struct OpenCodeGoProvider: UsageProvider {
    static let id = "opencode"
    static let name = "OpenCode Go"
    static let accent = "#B47BFF"
    static let order = 4

    private static let windowLabels: [(key: String, label: String)] = [
        ("rolling", "5h"),
        ("weekly", "Weekly"),
        ("monthly", "Monthly")
    ]

    var id: String { Self.id }
    var name: String { Self.name }
    var accentHex: String { Self.accent }
    var order: Int { Self.order }


    func fetch() async -> ProviderUsage? {
        let lookup = OpenCodeDB.lookupCredential(integrationIDs: ["opencode-go", "opencode"])
        let credential: [String: Any]
        switch lookup {
        case .unavailable:
            return Self.issue(.busy, "OpenCode database busy", "Retrying shortly")
        case .none:
            return Self.issue(.notSignedIn, "No OpenCode credential", "Sign in with `opencode auth login`")
        case let .found(json):
            credential = json
        }
        guard let token = (credential["access"] as? String) ?? (credential["key"] as? String) else {
            return Self.issue(.notSignedIn, "No OpenCode credential", "Sign in with `opencode auth login`")
        }

        var request = URLRequest(url: URL(string: "https://opencode.ai/zen/go/v1/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await HTTP.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return Self.response(status: status, data: data)
        } catch {
            return Self.issue(.unreachable, "Can't reach OpenCode", "Check your connection — retrying")
        }
    }

    static func response(status: Int, data: Data) -> ProviderUsage {
        switch status {
        case 200: return parse(data)
        case 401, 403: return issue(.rejected, "OpenCode token expired", "Open OpenCode to refresh it")
        case 429: return issue(.rateLimited, "Rate limited", "Retrying shortly")
        case 500...599: return issue(.unreachable, "OpenCode unavailable", "HTTP \(status) — retrying")
        default: return failure("HTTP \(status)")
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
              let usage = object["usage"] as? [String: Any] else {
            return failure("Parse error")
        }

        let windows: [UsageWindow] = windowLabels.compactMap { entry in
            guard let dict = usage[entry.key] as? [String: Any] else { return nil }
            let percent = max(0, min(1, (asDouble(dict["percent"]) ?? 0) / 100))
            return UsageWindow(id: entry.key, label: entry.label,
                               percent: percent, resetsAt: isoDate(dict["resetsAt"] as? String))
        }

        let rateLimited = windowLabels.contains { entry in
            (usage[entry.key] as? [String: Any])?["status"] as? String == "rate-limited"
        }

        return ProviderUsage(id: id, name: name, accentHex: accent, order: order,
                             windows: windows,
                             note: rateLimited ? "Rate limited" : nil,
                             error: windows.isEmpty ? "No data" : nil)
    }

    static func failure(_ message: String) -> ProviderUsage {
        .failure(id: id, name: name, accentHex: accent, order: order, message: message)
    }
}
