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
    static let order = 1

    private static let windowLabels: [(key: String, label: String)] = [
        ("rolling", "5h"),
        ("weekly", "Weekly"),
        ("monthly", "Monthly")
    ]

    func fetch() async -> ProviderUsage {
        guard let credential = OpenCodeDB.credentialJSON(integrationIDs: ["opencode-go", "opencode"]),
              let token = (credential["access"] as? String) ?? (credential["key"] as? String) else {
            return Self.failure("No OpenCode credential")
        }

        var request = URLRequest(url: URL(string: "https://opencode.ai/zen/go/v1/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { return Self.failure("Token expired — open OpenCode to refresh") }
            guard status == 200 else { return Self.failure("HTTP \(status)") }
            return Self.parse(data)
        } catch {
            return Self.failure(error.localizedDescription)
        }
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
