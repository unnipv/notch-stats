import Foundation

/// A single usage window (e.g. 5-hour, weekly, monthly).
struct UsageWindow: Identifiable, Sendable, Equatable {
    let id: String
    let label: String
    /// Normalised fraction of the allowance *used*, in `0...1`.
    let percent: Double
    let resetsAt: Date?

    /// Fraction still available. We surface this to the user: a nearly-empty
    /// ring reads as "almost out", whereas a full ring reading "100%" reads as
    /// "plenty" even when the budget is exhausted.
    var remaining: Double { max(0, min(1, 1 - percent)) }
}

/// Why a provider has no reading. Each case has its own caption and recovery
/// hint, so "your login is gone" is never conflated with "the keychain was
/// momentarily unreadable" or "you're offline".
enum ProviderIssue: Equatable, Sendable {
    /// No credential exists anywhere we look.
    case notSignedIn
    /// The keychain refused or didn't answer.
    case keychainDenied
    /// The token's own `expiresAt` is in the past.
    case tokenExpired
    /// The server answered 401 / 403 for a token that looked valid.
    case rejected
    /// No answer from the network or the request timed out.
    case unreachable
    case rateLimited
    /// A local database was busy; the next read will usually succeed.
    case busy

    /// Worth retrying with growing delays rather than on every tick.
    var backsOff: Bool {
        switch self {
        case .unreachable, .rateLimited: return true
        default: return false
        }
    }

    /// Keep showing the previous reading (marked stale) instead of an error.
    var isTransient: Bool {
        switch self {
        case .unreachable, .rateLimited, .busy, .keychainDenied: return true
        default: return false
        }
    }
}

/// Everything we know about one provider at a point in time.
struct ProviderUsage: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let accentHex: String
    let order: Int
    let windows: [UsageWindow]
    let note: String?
    let error: String?
    /// What the user can do about `error`.
    var hint: String? = nil
    var issue: ProviderIssue? = nil
    /// The reading is from an earlier refresh because the latest one failed.
    var isStale = false

    var headline: UsageWindow? { windows.first }

    static func failure(id: String, name: String, accentHex: String, order: Int, message: String,
                        hint: String? = nil, issue: ProviderIssue? = nil) -> ProviderUsage {
        ProviderUsage(id: id, name: name, accentHex: accentHex, order: order,
                      windows: [], note: nil, error: message, hint: hint, issue: issue)
    }

    /// Folds a fresh result into the previous one. A transient failure keeps
    /// the last good reading (flagged stale); a busy database with nothing to
    /// fall back on produces no row at all.
    static func merge(_ new: ProviderUsage, previous: ProviderUsage?) -> ProviderUsage? {
        guard let issue = new.issue, issue.isTransient else { return new }
        if let previous, previous.error == nil, !previous.windows.isEmpty || previous.note != nil {
            var kept = previous
            kept.isStale = true
            kept.hint = new.error
            return kept
        }
        return issue == .busy ? nil : new
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
    /// Compact "time ago": "now", "42s", "7m", "3h", "2d".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 5 { return "now" }
        if seconds < 60 { return "\(Int(seconds))s" }
        let minutes = Int(seconds) / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
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
