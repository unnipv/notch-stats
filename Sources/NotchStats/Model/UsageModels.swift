import Foundation

/// A single usage window (e.g. 5-hour, weekly, monthly).
struct UsageWindow: Identifiable, Sendable {
    let id: String
    let label: String
    /// Normalised fraction in `0...1`.
    let percent: Double
    let resetsAt: Date?
}

/// Everything we know about one provider at a point in time.
struct ProviderUsage: Identifiable, Sendable {
    let id: String
    let name: String
    let accentHex: String
    let order: Int
    let windows: [UsageWindow]
    let note: String?
    let error: String?

    var headline: UsageWindow? { windows.first }

    static func failure(id: String, name: String, accentHex: String, order: Int, message: String) -> ProviderUsage {
        ProviderUsage(id: id, name: name, accentHex: accentHex, order: order,
                      windows: [], note: nil, error: message)
    }
}

enum Format {
    static func percent(_ v: Double) -> String {
        "\(Int((v * 100).rounded()))%"
    }

    /// Compact relative countdown: "2h 14m", "3d 4h", "12m", "now".
    static func countdown(to date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "now" }
        let total = Int(seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

/// Tolerant numeric coercion for JSON values that may arrive as Int/Double/String.
func asDouble(_ value: Any?) -> Double? {
    switch value {
    case let d as Double: return d
    case let i as Int: return Double(i)
    case let n as NSNumber: return n.doubleValue
    case let s as String: return Double(s)
    default: return nil
    }
}

/// Parse an ISO-8601 string with or without fractional seconds.
func isoDate(_ string: String?) -> Date? {
    guard let string else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: string) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: string)
}
