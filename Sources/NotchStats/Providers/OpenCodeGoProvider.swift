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
            return fail("No OpenCode credential")
        }

        var request = URLRequest(url: URL(string: "https://opencode.ai/zen/go/v1/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { return fail("Token expired — open OpenCode to refresh") }
            guard status == 200 else { return fail("HTTP \(status)") }

            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let usage = object["usage"] as? [String: Any] else {
                return fail("Parse error")
            }

            let windows: [UsageWindow] = Self.windowLabels.compactMap { entry in
                guard let dict = usage[entry.key] as? [String: Any] else { return nil }
                let percent = max(0, min(1, (asDouble(dict["percent"]) ?? 0) / 100))
                return UsageWindow(id: entry.key, label: entry.label,
                                   percent: percent, resetsAt: isoDate(dict["resetsAt"] as? String))
            }

            return ProviderUsage(id: Self.id, name: Self.name, accentHex: Self.accent, order: Self.order,
                                 windows: windows, note: nil,
                                 error: windows.isEmpty ? "No data" : nil)
        } catch {
            return fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) -> ProviderUsage {
        .failure(id: Self.id, name: Self.name, accentHex: Self.accent, order: Self.order, message: message)
    }
}
