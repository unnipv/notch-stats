import XCTest
@testable import NotchStats

final class ClaudeTests: XCTestCase {

    // MARK: - Usage parsing

    func testParsesFiveHourAndWeeklyWindows() {
        let json = """
        {
          "subscriptionType": "max",
          "five_hour":  { "utilization": 14.5, "resets_at": "2026-10-16T09:30:00.000Z" },
          "seven_day":  { "utilization": 46.0, "resets_at": "2026-10-21T00:00:00.000Z" }
        }
        """
        let usage = ClaudeProvider.parse(Data(json.utf8))

        XCTAssertNil(usage.error)
        XCTAssertEqual(usage.id, "claude")
        XCTAssertEqual(usage.note, "Max")
        XCTAssertEqual(usage.windows.map(\.label), ["5h", "Weekly"])
        // utilization is a percentage, so 14.5 -> 14.5% used -> 85.5% left.
        XCTAssertEqual(usage.windows[0].percent, 0.145, accuracy: 0.0001)
        XCTAssertEqual(usage.windows[0].remaining, 0.855, accuracy: 0.0001)
        XCTAssertEqual(usage.windows[1].percent, 0.46, accuracy: 0.0001)
        XCTAssertNotNil(usage.windows[0].resetsAt, "fractional-second ISO-8601 should parse")
    }

    func testFractionalUtilizationIsNotTreatedAsNormalised() {
        // A 0.5% reading must be 0.5%, not 50%.
        let json = #"{ "five_hour": { "utilization": 0.5 } }"#
        let usage = ClaudeProvider.parse(Data(json.utf8))
        XCTAssertEqual(usage.windows.first?.percent ?? -1, 0.005, accuracy: 0.0001)
    }

    func testEpochResetTimestampsAreAccepted() {
        let json = #"{ "five_hour": { "utilization": 10, "resets_at": 1792083607 } }"#
        let usage = ClaudeProvider.parse(Data(json.utf8))
        XCTAssertNotNil(usage.windows.first?.resetsAt)
    }

    func testUsedPercentFallback() {
        let json = #"{ "five_hour": { "used_percent": 25 } }"#
        let usage = ClaudeProvider.parse(Data(json.utf8))
        XCTAssertEqual(usage.windows.first?.percent ?? -1, 0.25, accuracy: 0.0001)
    }

    func testRateLimitErrorBodyIsSurfaced() {
        let json = #"{ "error": { "type": "rate_limit_error", "message": "slow down" } }"#
        let usage = ClaudeProvider.parse(Data(json.utf8))
        XCTAssertEqual(usage.error, "Rate limited")
        XCTAssertEqual(usage.issue, .rateLimited)
        XCTAssertEqual(usage.hint, "Retrying shortly")
        XCTAssertTrue(usage.issue?.backsOff ?? false)
        XCTAssertTrue(usage.issue?.isTransient ?? false)
    }

    func testEmptyBodyIsNoData() {
        XCTAssertEqual(ClaudeProvider.parse(Data("{}".utf8)).error, "No data")
    }

    func testGarbageIsParseError() {
        XCTAssertEqual(ClaudeProvider.parse(Data("nope".utf8)).error, "Parse error")
    }

    // MARK: - Credential discovery

    func testParsesKeychainShapedCredentials() {
        let json = """
        { "claudeAiOauth": { "accessToken": "sk-ant-oat01-abc",
                             "refreshToken": "sk-ant-ort01-xyz",
                             "expiresAt": 1797000000000 } }
        """
        let credential = ClaudeCredentials.credential(from: Data(json.utf8))
        XCTAssertEqual(credential?.token, "sk-ant-oat01-abc")
        XCTAssertNotNil(credential?.expiresAt)
    }

    func testParsesFlatCredentialsFile() {
        let json = #"{ "accessToken": "flat-token" }"#
        XCTAssertEqual(ClaudeCredentials.credential(from: Data(json.utf8))?.token, "flat-token")
    }

    func testExpiryMillisecondsAreConvertedToSeconds() {
        let json = #"{ "accessToken": "t", "expiresAt": 1797000000000 }"#
        let date = ClaudeCredentials.credential(from: Data(json.utf8))?.expiresAt
        // 1.797e12 ms -> 1.797e9 s -> 2026-12-07
        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, 1_797_000_000, accuracy: 1)
    }

    func testMissingTokenYieldsNil() {
        XCTAssertNil(ClaudeCredentials.credential(from: Data(#"{ "claudeAiOauth": {} }"#.utf8)))
        XCTAssertNil(ClaudeCredentials.credential(from: Data("garbage".utf8)))
    }

    func testBareAPIKeyIsAccepted() {
        let credential = ClaudeCredentials.credential(from: Data("sk-ant-api03-abc123\n".utf8))
        XCTAssertEqual(credential?.token, "sk-ant-api03-abc123")
        XCTAssertEqual(credential?.kind, .apiKey)
    }

    func testKindIsInferredFromPrefix() {
        XCTAssertEqual(ClaudeCredentials.credential(
            from: Data(#"{ "accessToken": "sk-ant-oat01-xyz" }"#.utf8))?.kind, .oauth)
        XCTAssertEqual(ClaudeCredentials.credential(
            from: Data(#"{ "accessToken": "sk-ant-api03-xyz" }"#.utf8))?.kind, .apiKey)
    }

    func testAPIOrganisationErrorIsRecognised() {
        let json = """
        { "type": "error",
          "error": { "type": "invalid_request_error",
                     "message": "Usage limits are not applicable to API organizations" } }
        """
        XCTAssertTrue(ClaudeProvider.isAPIOrganisationError(Data(json.utf8)))
        XCTAssertFalse(ClaudeProvider.isAPIOrganisationError(Data(#"{ "error": {} }"#.utf8)))
        XCTAssertFalse(ClaudeProvider.isAPIOrganisationError(Data("nope".utf8)))
    }

    // MARK: - 401 retry-once on OAuth token rotation

    private let validUsageJSON = Data(#"{"five_hour":{"utilization":20.0},"seven_day":{"utilization":35.0}}"#.utf8)

    func test401RetriesOnceWhenTokenRotatedAndSucceeds() async {
        let oldCred = ClaudeCredentials.Credential(token: "sk-ant-oat01-old", kind: .oauth,
                                                   expiresAt: Date().addingTimeInterval(3600))
        let newCred = ClaudeCredentials.Credential(token: "sk-ant-oat01-new", kind: .oauth,
                                                   expiresAt: Date().addingTimeInterval(28800))
        let calls = Locked<(resolves: [Bool], authHeaders: [String])>(([], []))
        let provider = ClaudeProvider(
            resolve: { force in
                calls.withLock { $0.resolves.append(force) }
                return .found(force ? newCred : oldCred, force ? .file : .lastKnown)
            },
            transport: { request in
                let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
                calls.withLock { $0.authHeaders.append(auth) }
                if auth == "Bearer sk-ant-oat01-old" { return (Data(), 401) }
                return (self.validUsageJSON, 200)
            })

        let usage = await provider.fetch()
        XCTAssertNil(usage?.error, "rotated token retry should succeed without flashing Rejected")
        XCTAssertEqual(usage?.windows.count, 2)
        let recorded = calls.withLock { $0 }
        XCTAssertEqual(recorded.resolves, [false, true])
        XCTAssertEqual(recorded.authHeaders, ["Bearer sk-ant-oat01-old", "Bearer sk-ant-oat01-new"])
    }

    func test401DoesNotRetryWhenTokenIsUnchanged() async {
        let sameCred = ClaudeCredentials.Credential(token: "sk-ant-oat01-same", kind: .oauth,
                                                    expiresAt: Date().addingTimeInterval(3600))
        let requestCount = Locked(0)
        let provider = ClaudeProvider(
            resolve: { _ in .found(sameCred, .file) },
            transport: { _ in
                requestCount.withLock { $0 += 1 }
                return (Data(), 401)
            })

        let usage = await provider.fetch()
        XCTAssertEqual(usage?.issue, .rejected)
        XCTAssertEqual(requestCount.withLock { $0 }, 1, "must not resend the exact same rejected token")
    }

    func test401RetriesAtMostOnceEvenIfNewTokenAlsoReturns401() async {
        let first = ClaudeCredentials.Credential(token: "sk-ant-oat01-first", kind: .oauth,
                                                 expiresAt: Date().addingTimeInterval(3600))
        let second = ClaudeCredentials.Credential(token: "sk-ant-oat01-second", kind: .oauth,
                                                  expiresAt: Date().addingTimeInterval(3600))
        let requestCount = Locked(0)
        let provider = ClaudeProvider(
            resolve: { force in .found(force ? second : first, .file) },
            transport: { _ in
                requestCount.withLock { $0 += 1 }
                return (Data(), 401)
            })

        let usage = await provider.fetch()
        XCTAssertEqual(usage?.issue, .rejected)
        XCTAssertEqual(requestCount.withLock { $0 }, 2, "retry must be bounded to a single attempt")
    }

    func test401WhenFileMidRewriteSurfacesTransientUnreadableInsteadOfRejected() async {
        let cached = ClaudeCredentials.Credential(token: "sk-ant-oat01-cached", kind: .oauth,
                                                  expiresAt: Date().addingTimeInterval(3600))
        let provider = ClaudeProvider(
            resolve: { force in force ? .missing(.fileUnreadable) : .found(cached, .lastKnown) },
            transport: { _ in (Data(), 401) })

        let usage = await provider.fetch()
        XCTAssertEqual(usage?.issue, .unreadable,
                       "mid-write credential file after 401 should stay transient so last reading stays dimmed")
        XCTAssertTrue(usage?.issue?.isTransient ?? false)
    }

    func test401WhenReResolveSeesExpiredTokenReportsExpired() async {
        let cached = ClaudeCredentials.Credential(token: "sk-ant-oat01-cached", kind: .oauth,
                                                  expiresAt: Date().addingTimeInterval(3600))
        let expired = ClaudeCredentials.Credential(token: "sk-ant-oat01-expired", kind: .oauth,
                                                   expiresAt: Date().addingTimeInterval(-60))
        let provider = ClaudeProvider(
            resolve: { force in .found(force ? expired : cached, .file) },
            transport: { _ in (Data(), 401) })

        let usage = await provider.fetch()
        XCTAssertEqual(usage?.issue, .tokenExpired)
    }
}
