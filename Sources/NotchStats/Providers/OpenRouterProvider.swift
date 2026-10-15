import Foundation

/// OpenRouter credit balance from `GET https://openrouter.ai/api/v1/credits`.
struct OpenRouterProvider: UsageProvider {
    static let id = "openrouter"
    static let name = "OpenRouter"
    static let accent = "#7E8BF5"
    static let order = 2

    func fetch() async -> ProviderUsage {
        guard let credential = OpenCodeDB.credentialJSON(integrationIDs: ["openrouter"]),
              let key = (credential["key"] as? String) ?? (credential["access"] as? String) else {
            return Self.failure("No OpenRouter key")
        }

        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/credits")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { return Self.failure("Key rejected") }
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
