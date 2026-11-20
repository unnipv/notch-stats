import Foundation

/// Per-provider retry pacing after network-shaped failures.
///
/// The app already refreshes once a minute; this only matters when something is
/// wrong. The first failure retries on the next tick, then the wait doubles
/// from two minutes up to ten, so an outage or a rate limit never turns into a
/// request storm. Any success (or a non-network failure) clears it.
struct Backoff: Equatable {
    private(set) var failures = 0
    private(set) var retryAt: Date?

    static let maxDelay: TimeInterval = 600

    static func delay(afterFailures count: Int) -> TimeInterval {
        count <= 1 ? 0 : min(maxDelay, 30 * pow(2, Double(min(count, 10))))
    }

    func allows(now: Date = Date()) -> Bool {
        guard let retryAt else { return true }
        return now >= retryAt
    }

    mutating func record(_ usage: ProviderUsage?, now: Date = Date()) {
        guard let issue = usage?.issue, issue.backsOff else {
            self = Backoff()
            return
        }
        failures += 1
        retryAt = now.addingTimeInterval(Self.delay(afterFailures: failures))
    }
}
