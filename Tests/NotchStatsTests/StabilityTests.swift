import XCTest
import SQLite3
@testable import NotchStats

final class StabilityTests: XCTestCase {

    // MARK: - Credentials

    private func credential(expiresIn seconds: TimeInterval?) -> ClaudeCredentials.Credential {
        ClaudeCredentials.Credential(token: "sk-ant-oat01-x", kind: .oauth,
                                     expiresAt: seconds.map { Date().addingTimeInterval($0) })
    }

    func testCredentialExpiryOnlyAppliesToOAuth() {
        let key = ClaudeCredentials.Credential(token: "sk-ant-api03-x", kind: .apiKey,
                                               expiresAt: Date().addingTimeInterval(-10))
        XCTAssertFalse(key.isExpired())
        XCTAssertTrue(credential(expiresIn: -1).isExpired())
        XCTAssertFalse(credential(expiresIn: nil).isExpired())
    }

    func testBlobWithoutScopesStillYieldsAToken() {
        // The keychain item seen in the wild: only the three token fields.
        let json = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-a","refreshToken":"r","expiresAt":1797000000000}}"#
        XCTAssertEqual(ClaudeCredentials.credential(from: Data(json.utf8))?.token, "sk-ant-oat01-a")
    }

    // MARK: - Claude: every failure is its own state

    func testEachClaudeFailureHasItsOwnCaptionAndHint() {
        let states: [ProviderUsage] = [
            ClaudeProvider.failure(.notSignedIn),
            ClaudeProvider.failure(.keychainNotAllowed),
            ClaudeProvider.failure(.keychainDenied),
            ClaudeProvider.failure(.fileUnreadable),
            ClaudeProvider.expired(),
            ClaudeProvider.response(status: 401, data: Data(), kind: .oauth),
            ClaudeProvider.response(status: 403, data: Data(), kind: .oauth),
            ClaudeProvider.response(status: 429, data: Data(), kind: .oauth),
            ClaudeProvider.response(status: 503, data: Data(), kind: .oauth),
            ClaudeProvider.transportFailure(URLError(.notConnectedToInternet))
        ]
        let captions = states.compactMap(\.error)
        XCTAssertEqual(captions.count, Set(captions).count, "captions must be distinct: \(captions)")
        XCTAssertTrue(states.allSatisfy { $0.hint?.isEmpty == false && $0.issue != nil })
    }

    func testExpiredTokenSaysSo() {
        let usage = ClaudeProvider.expired()
        XCTAssertEqual(usage.error, "Claude token expired")
        XCTAssertEqual(usage.hint, "Open Claude Code to renew it")
        XCTAssertEqual(usage.issue, .tokenExpired)
    }

    func testRejectedTokenIsDistinctFromExpired() {
        let usage = ClaudeProvider.response(status: 401, data: Data(), kind: .oauth)
        XCTAssertEqual(usage.issue, .rejected)
        XCTAssertNotEqual(usage.error, ClaudeProvider.expired().error)
    }

    func testSuccessAndOrganisationErrorStillMap() {
        let ok = ClaudeProvider.response(status: 200, data: Data(#"{"five_hour":{"utilization":10}}"#.utf8),
                                         kind: .oauth)
        XCTAssertNil(ok.error)
        let org = ClaudeProvider.response(
            status: 400,
            data: Data(#"{"error":{"message":"not applicable to API organizations"}}"#.utf8),
            kind: .apiKey)
        XCTAssertEqual(org.error, "API key login — usage limits don't apply")
    }

    func testNetworkAndRateLimitFailuresBackOffButAuthFailuresDoNot() {
        XCTAssertTrue(ProviderIssue.unreachable.backsOff)
        XCTAssertTrue(ProviderIssue.rateLimited.backsOff)
        for issue in [ProviderIssue.notSignedIn, .tokenExpired, .rejected, .keychainDenied, .busy] {
            XCTAssertFalse(issue.backsOff)
        }
    }

    // MARK: - Keeping the last good reading

    private func reading() -> ProviderUsage {
        ProviderUsage(id: "claude", name: "Claude", accentHex: "#D97757", order: 1,
                      windows: [UsageWindow(id: "5h", label: "5h", percent: 0.2, resetsAt: nil)],
                      note: nil, error: nil)
    }

    func testTransientFailureKeepsThePreviousReadingMarkedStale() {
        let merged = ProviderUsage.merge(ClaudeProvider.transportFailure(URLError(.timedOut)),
                                         previous: reading())
        XCTAssertEqual(merged?.windows.count, 1)
        XCTAssertEqual(merged?.isStale, true)
        XCTAssertNil(merged?.error)
        XCTAssertEqual(merged?.hint, "Can't reach Anthropic")
    }

    func testPermanentFailureReplacesThePreviousReading() {
        let merged = ProviderUsage.merge(ClaudeProvider.expired(), previous: reading())
        XCTAssertEqual(merged?.issue, .tokenExpired)
        XCTAssertTrue(merged?.windows.isEmpty ?? false)
    }

    func testTransientFailureWithNothingToKeepIsShown() {
        let merged = ProviderUsage.merge(ClaudeProvider.transportFailure(URLError(.timedOut)), previous: nil)
        XCTAssertEqual(merged?.issue, .unreachable)
    }

    func testBusyDatabaseWithNothingToKeepProducesNoRow() {
        let busy = ProviderUsage.failure(id: "x", name: "X", accentHex: "#fff", order: 9,
                                         message: "busy", issue: .busy)
        XCTAssertNil(ProviderUsage.merge(busy, previous: nil))
    }

    func testSuccessReplacesAStaleReading() {
        var stale = reading(); stale.isStale = true
        XCTAssertEqual(ProviderUsage.merge(reading(), previous: stale)?.isStale, false)
    }

    // MARK: - Backoff

    func testBackoffGrowsAndIsCapped() {
        XCTAssertEqual(Backoff.delay(afterFailures: 1), 0)
        XCTAssertEqual(Backoff.delay(afterFailures: 2), 120)
        XCTAssertEqual(Backoff.delay(afterFailures: 3), 240)
        XCTAssertEqual(Backoff.delay(afterFailures: 4), 480)
        XCTAssertEqual(Backoff.delay(afterFailures: 5), 600)
        XCTAssertEqual(Backoff.delay(afterFailures: 500), 600)
    }

    func testBackoffGatesAttemptsAndResetsOnSuccess() {
        var backoff = Backoff()
        let now = Date()
        let down = ClaudeProvider.transportFailure(URLError(.notConnectedToInternet))
        backoff.record(down, now: now)
        XCTAssertTrue(backoff.allows(now: now), "first failure retries on the next tick")
        backoff.record(down, now: now)
        XCTAssertFalse(backoff.allows(now: now.addingTimeInterval(60)))
        XCTAssertTrue(backoff.allows(now: now.addingTimeInterval(121)))
        backoff.record(reading(), now: now)
        XCTAssertEqual(backoff, Backoff())
    }

    func testAuthFailureDoesNotBackOff() {
        var backoff = Backoff()
        backoff.record(ClaudeProvider.expired())
        backoff.record(ClaudeProvider.expired())
        XCTAssertTrue(backoff.allows())
    }

    // MARK: - Codex auth file

    private func tempFile(_ contents: String?) -> String {
        let path = NSTemporaryDirectory() + "notchstats-auth-\(UUID().uuidString).json"
        if let contents { try? contents.write(toFile: path, atomically: true, encoding: .utf8) }
        return path
    }

    func testCodexAuthStates() {
        let good = tempFile(#"{"tokens":{"access_token":"abc"}}"#)
        let half = tempFile(#"{"tokens":{"access_tok"#)
        let shape = tempFile(#"{"other":1}"#)
        let gone = tempFile(nil)
        defer { [good, half, shape].forEach { try? FileManager.default.removeItem(atPath: $0) } }

        XCTAssertEqual(CodexProvider.readToken(path: good), .token("abc"))
        XCTAssertEqual(CodexProvider.readToken(path: half), .unreadable)
        XCTAssertEqual(CodexProvider.readToken(path: shape), .unreadable)
        XCTAssertEqual(CodexProvider.readToken(path: gone), .missing)
    }

    func testCodexHalfWrittenFileIsNotCalledSignedOut() {
        XCTAssertEqual(CodexProvider.failure(.unreadable).issue, .busy)
        XCTAssertEqual(CodexProvider.failure(.missing).issue, .notSignedIn)
        XCTAssertEqual(CodexProvider.response(status: 401, data: Data()).issue, .rejected)
        XCTAssertEqual(CodexProvider.response(status: 503, data: Data()).issue, .unreachable)
    }

    func testOpenCodeGoMapsHTTPFailures() {
        XCTAssertEqual(OpenCodeGoProvider.response(status: 401, data: Data()).issue, .rejected)
        XCTAssertEqual(OpenCodeGoProvider.response(status: 429, data: Data()).issue, .rateLimited)
    }
}

// MARK: - Regression: "the Claude login keeps disappearing"

/// A transient keychain failure must never look like a missing login, and a
/// genuinely absent login must still say so.
final class LoginDisappearingRegressionTests: XCTestCase {

    private func lastReading() -> ProviderUsage {
        ProviderUsage(id: "claude", name: "Claude", accentHex: "#D97757", order: 1,
                      windows: [UsageWindow(id: "5h", label: "5h", percent: 0.14, resetsAt: nil)],
                      note: "Max", error: nil)
    }

    /// Resolution → provider result → what the panel shows next to the previous
    /// good reading, i.e. the whole path the user actually sees.
    private func shown(_ failure: ClaudeCredentials.Failure) -> ProviderUsage? {
        ProviderUsage.merge(ClaudeProvider.failure(failure), previous: lastReading())
    }

    func testUnreadableLoginKeepsTheLastReadingDimmed() {
        for failure in [ClaudeCredentials.Failure.keychainNotAllowed, .keychainDenied, .fileUnreadable] {
            let usage = shown(failure)
            XCTAssertEqual(usage?.isStale, true, "\(failure) must show the last reading, dimmed")
            XCTAssertEqual(usage?.windows.count, 1)
            XCTAssertNil(usage?.error, "\(failure) must not become an error row")
            XCTAssertNotEqual(usage?.issue, .notSignedIn)
        }
    }

    func testUnreadableLoginWithNoHistoryNamesTheProblemNotTheLogin() {
        for failure in [ClaudeCredentials.Failure.keychainNotAllowed, .keychainDenied, .fileUnreadable] {
            let usage = ProviderUsage.merge(ClaudeProvider.failure(failure), previous: nil)
            XCTAssertNotEqual(usage?.issue, .notSignedIn)
            XCTAssertFalse(usage?.error?.lowercased().contains("not signed in") ?? true)
            XCTAssertNotNil(usage?.hint)
        }
    }

    func testARealAbsenceStillSaysNotSignedIn() {
        // Every source answered "nothing here": a real absence replaces the
        // old reading instead of dimming it.
        let usage = shown(.notSignedIn)
        XCTAssertEqual(usage?.issue, .notSignedIn)
        XCTAssertEqual(usage?.error, "Not signed in to Claude")
        XCTAssertEqual(usage?.hint, "Run `claude` to sign in")
        XCTAssertTrue(usage?.windows.isEmpty ?? false)
        XCTAssertEqual(usage?.isStale, false)
    }
}
