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
        XCTAssertEqual(ClaudeProvider.parse(Data(json.utf8)).error, "Rate limited")
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
}
