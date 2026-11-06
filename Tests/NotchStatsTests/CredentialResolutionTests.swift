import XCTest
@testable import NotchStats

/// Resolution order and the "never prompt" guarantee, with every source
/// replaced by a stub: nothing here reads the real keychain or home directory.
final class CredentialResolutionTests: XCTestCase {
    private typealias C = ClaudeCredentials

    private let fileJSON = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-file","expiresAt":4102444800000}}"#
    private let keychainJSON = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-keychain","expiresAt":4102444800000}}"#

    /// Counts what a resolution consulted.
    private final class Calls {
        var file = 0, probe = 0, secret = 0
    }

    private func inputs(env: [String: String] = [:],
                        file: C.FileRead = .absent,
                        allowed: Bool = false,
                        probe: C.KeychainProbe = .absent,
                        secret: C.KeychainSecret = .absent,
                        calls: Calls = Calls()) -> C.Inputs {
        C.Inputs(environment: env,
                 readFile: { calls.file += 1; return file },
                 keychainAllowed: allowed,
                 probeKeychain: { calls.probe += 1; return probe },
                 readKeychain: { calls.secret += 1; return secret })
    }

    private func token(_ resolution: C.Resolution) -> String? {
        if case let .found(credential, _) = resolution { return credential.token }
        return nil
    }

    // MARK: - Order

    func testEnvironmentWinsOverFileAndKeychain() {
        let calls = Calls()
        let resolution = C.resolve(inputs(env: ["CLAUDE_CODE_OAUTH_TOKEN": " sk-ant-oat01-env \n"],
                                          file: .data(Data(fileJSON.utf8)), allowed: true,
                                          secret: .found(Data(keychainJSON.utf8)), calls: calls),
                                   lastGood: nil)
        XCTAssertEqual(token(resolution), "sk-ant-oat01-env")
        XCTAssertEqual(calls.file + calls.probe + calls.secret, 0, "nothing else is consulted")
    }

    func testFileWinsOverTheKeychain() {
        let calls = Calls()
        let resolution = C.resolve(inputs(file: .data(Data(fileJSON.utf8)), allowed: true,
                                          secret: .found(Data(keychainJSON.utf8)), calls: calls),
                                   lastGood: nil)
        XCTAssertEqual(token(resolution), "sk-ant-oat01-file")
        XCTAssertEqual(calls.secret, 0)
    }

    func testKeychainIsTheFallbackOnlyWhenOptedIn() {
        let resolution = C.resolve(inputs(allowed: true, secret: .found(Data(keychainJSON.utf8))), lastGood: nil)
        XCTAssertEqual(token(resolution), "sk-ant-oat01-keychain")
        if case let .found(_, source) = resolution { XCTAssertEqual(source, .keychain) }
    }

    func testBlankEnvironmentTokenIsIgnored() {
        let resolution = C.resolve(inputs(env: ["CLAUDE_CODE_OAUTH_TOKEN": "  "],
                                          file: .data(Data(fileJSON.utf8))), lastGood: nil)
        XCTAssertEqual(token(resolution), "sk-ant-oat01-file")
    }

    // MARK: - Opt-in off

    func testOptInOffNeverReadsTheKeychainSecret() {
        for probe in [C.KeychainProbe.present, .absent, .unknown] {
            let calls = Calls()
            _ = C.resolve(inputs(allowed: false, probe: probe,
                                 secret: .found(Data(keychainJSON.utf8)), calls: calls), lastGood: nil)
            XCTAssertEqual(calls.secret, 0, "the secret must not be requested with the opt-in off (\(probe))")
        }
    }

    func testKeychainItemWithoutOptInIsNotReadableNeverNotSignedIn() {
        let resolution = C.resolve(inputs(allowed: false, probe: .present), lastGood: nil)
        XCTAssertEqual(resolution, .missing(.keychainNotAllowed))
        XCTAssertNotEqual(resolution, .missing(.notSignedIn))
    }

    func testLockedKeychainIsNotReportedAsSignedOut() {
        XCTAssertEqual(C.resolve(inputs(probe: .unknown), lastGood: nil), .missing(.keychainDenied))
    }

    func testNothingAnywhereIsNotSignedIn() {
        XCTAssertEqual(C.resolve(inputs(), lastGood: nil), .missing(.notSignedIn))
        XCTAssertEqual(C.resolve(inputs(allowed: true, secret: .absent), lastGood: nil), .missing(.notSignedIn))
    }

    func testRefusedReadWithOptInIsDeniedNotSignedOut() {
        XCTAssertEqual(C.resolve(inputs(allowed: true, secret: .refused), lastGood: nil), .missing(.keychainDenied))
    }

    // MARK: - File being rewritten

    private func lastGood(age: TimeInterval = 10, expiresIn: TimeInterval? = 3600, now: Date) -> C.LastGood {
        C.LastGood(credential: C.Credential(token: "sk-ant-oat01-kept", kind: .oauth,
                                            expiresAt: expiresIn.map { now.addingTimeInterval($0) }),
                   source: .file, at: now.addingTimeInterval(-age))
    }

    func testCorruptFileKeepsTheLastGoodCredential() {
        let now = Date()
        for file in [C.FileRead.data(Data(#"{"claudeAiOauth":{"accessTo"#.utf8)), .data(Data("garbage".utf8)),
                     .unreadable, .absent] {
            let resolution = C.resolve(inputs(file: file), lastGood: lastGood(now: now), now: now)
            XCTAssertEqual(token(resolution), "sk-ant-oat01-kept", "\(file) must not wipe the token")
            if case let .found(_, source) = resolution { XCTAssertEqual(source, .lastKnown) }
        }
    }

    func testAGoodFileReplacesTheLastGoodCredential() {
        let now = Date()
        let resolution = C.resolve(inputs(file: .data(Data(fileJSON.utf8))), lastGood: lastGood(now: now), now: now)
        XCTAssertEqual(token(resolution), "sk-ant-oat01-file")
    }

    func testTheGraceEndsSoARealLogoutShowsUp() {
        let now = Date()
        let old = lastGood(age: C.graceLifetime + 1, now: now)
        XCTAssertEqual(C.resolve(inputs(), lastGood: old, now: now), .missing(.notSignedIn))
    }

    func testAnExpiredLastGoodTokenIsNotKept() {
        let now = Date()
        let expired = lastGood(expiresIn: -5, now: now)
        XCTAssertEqual(C.resolve(inputs(file: .unreadable), lastGood: expired, now: now), .missing(.fileUnreadable))
    }

    func testCorruptFileWithNothingToKeepSaysUnreadableNotSignedOut() {
        let resolution = C.resolve(inputs(file: .data(Data("{".utf8))), lastGood: nil)
        XCTAssertEqual(resolution, .missing(.fileUnreadable))
        XCTAssertEqual(C.Failure.fileUnreadable.issue, .unreadable)
    }

    // MARK: - What the user sees

    func testEachFailureMapsToItsOwnIssue() {
        XCTAssertEqual(C.Failure.notSignedIn.issue, .notSignedIn)
        XCTAssertEqual(C.Failure.keychainNotAllowed.issue, .keychainNotAllowed)
        XCTAssertEqual(C.Failure.keychainDenied.issue, .keychainDenied)
    }

    func testNotReadableCaptionPointsAtTheMenu() {
        let usage = ClaudeProvider.failure(.keychainNotAllowed)
        XCTAssertEqual(usage.error, "Claude login found, not readable")
        XCTAssertTrue(usage.hint?.contains("Allow Keychain Access") ?? false)
        XCTAssertNotEqual(usage.error, ClaudeProvider.failure(.notSignedIn).error)
    }

    func testOptInKeyIsSharedByMenuAndResolver() {
        // The menu item and the resolver share one UserDefaults key.
        XCTAssertEqual(C.keychainOptInKey, "allowKeychainAccess")
    }
}
