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


    func fetch() async -> ProviderUsage {
        guard let token = Self.accessToken() else {
            return Self.failure("No credentials — run `codex login`")
        }

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("NotchStats", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { return Self.failure("Auth expired — run `codex login`") }
            guard status == 200 else { return Self.failure("HTTP \(status)") }
            return Self.parse(data)
        } catch {
            return Self.failure(error.localizedDescription)
        }
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

    static func accessToken() -> String? {
        let path = NSHomeDirectory() + "/.codex/auth.json"
        guard let data = FileManager.default.contents(atPath: path),
              let any = try? JSONSerialization.jsonObject(with: data),
              let object = any as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String else { return nil }
        return token
    }
}
