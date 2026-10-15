import Foundation

/// Codex / ChatGPT plan limits from `~/.codex/auth.json` → `chatgpt.com/backend-api/wham/usage`.
struct CodexProvider: UsageProvider {
    static let id = "codex"
    static let name = "Codex"
    static let accent = "#10A37F"
    static let order = 0

    func fetch() async -> ProviderUsage {
        guard let token = Self.accessToken() else {
            return fail("No credentials — run `codex login`")
        }

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        request.setValue("NotchStats", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { return fail("Auth expired — run `codex login`") }
            guard status == 200 else { return fail("HTTP \(status)") }

            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return fail("Parse error")
            }
            let rateLimit = object["rate_limit"] as? [String: Any] ?? [:]

            var windows: [UsageWindow] = []
            if let w = Self.window(id: "5h", label: "5h", rateLimit["primary_window"]) { windows.append(w) }
            if let w = Self.window(id: "7d", label: "Weekly", rateLimit["secondary_window"]) { windows.append(w) }

            let plan = object["plan_type"] as? String
            return ProviderUsage(id: Self.id, name: Self.name, accentHex: Self.accent, order: Self.order,
                                 windows: windows, note: plan.map { "\($0.capitalized) plan" }, error: nil)
        } catch {
            return fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) -> ProviderUsage {
        .failure(id: Self.id, name: Self.name, accentHex: Self.accent, order: Self.order, message: message)
    }

    private static func window(id: String, label: String, _ object: Any?) -> UsageWindow? {
        guard let dict = object as? [String: Any], let used = asDouble(dict["used_percent"]) else { return nil }
        let reset = asDouble(dict["reset_at"]).map { Date(timeIntervalSince1970: $0) }
        return UsageWindow(id: id, label: label, percent: max(0, min(1, used / 100)), resetsAt: reset)
    }

    private static func accessToken() -> String? {
        let path = NSHomeDirectory() + "/.codex/auth.json"
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String else { return nil }
        return token
    }
}
