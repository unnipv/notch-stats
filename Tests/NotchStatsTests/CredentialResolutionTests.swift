import LocalAuthentication
import Security
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

    // MARK: - Expired file vs fresh keychain, and explicitly cleared logins

    func testExpiredFileFallsBackToFreshKeychainWhenOptedIn() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiredFile = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-old","expiresAt":1799999000000}}"#
        let freshKeychain = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-fresh","expiresAt":1800010000000}}"#
        let resolution = C.resolve(
            inputs(file: .data(Data(expiredFile.utf8)), allowed: true,
                   secret: .found(Data(freshKeychain.utf8))),
            lastGood: nil, now: now)
        XCTAssertEqual(token(resolution), "sk-ant-oat01-fresh")
        if case let .found(_, source) = resolution { XCTAssertEqual(source, .keychain) }
    }

    func testExpiredFileStillReturnsExpiredWhenKeychainHasNothingFresher() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiredFile = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-old","expiresAt":1799999000000}}"#
        let resolution = C.resolve(
            inputs(file: .data(Data(expiredFile.utf8)), allowed: true, secret: .absent),
            lastGood: nil, now: now)
        XCTAssertEqual(token(resolution), "sk-ant-oat01-old")
        if case let .found(cred, source) = resolution {
            XCTAssertTrue(cred.isExpired(now: now))
            XCTAssertEqual(source, .file)
        }
    }

    func testClearedKeychainCredentialIsNotSignedInNotKeychainDenied() {
        let now = Date()
        // Exact shape Claude Code writes on dead-token clear (invalid_grant).
        let cleared = #"{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0,"scopes":["user:inference"]}}"#
        let resolution = C.resolve(
            inputs(allowed: true, secret: .found(Data(cleared.utf8))),
            lastGood: lastGood(now: now), now: now)
        XCTAssertEqual(resolution, .missing(.notSignedIn),
                       "an explicitly cleared keychain item must report notSignedIn, not keychainDenied or stale lastGood")
    }

    func testClearedFileCredentialIsNotUnreadableAndDoesNotServeLastGood() {
        let now = Date()
        let cleared = #"{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}"#
        let resolution = C.resolve(
            inputs(file: .data(Data(cleared.utf8)), allowed: true, secret: .absent),
            lastGood: lastGood(now: now), now: now)
        XCTAssertEqual(resolution, .missing(.notSignedIn))
    }

    func testClearedFileFallsThroughToLiveKeychainWhenOptedIn() {
        let cleared = #"{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}"#
        let resolution = C.resolve(
            inputs(file: .data(Data(cleared.utf8)), allowed: true,
                   secret: .found(Data(keychainJSON.utf8))),
            lastGood: nil)
        XCTAssertEqual(token(resolution), "sk-ant-oat01-keychain")
        if case let .found(_, source) = resolution { XCTAssertEqual(source, .keychain) }
    }

    // MARK: - Non-interactive queries & read-only guarantees

    func testProbeQueryIsAttributesOnlyAndNonInteractive() {
        let query = C.Keychain.probeQuery(service: "Claude Code-credentials")
        XCTAssertEqual(query[kSecReturnAttributes as String] as? Bool, true)
        XCTAssertNil(query[kSecReturnData as String], "probe must never request secret bytes")
        let context = query[kSecUseAuthenticationContext as String] as? LAContext
        XCTAssertEqual(context?.interactionNotAllowed, true,
                       "probe must attach an LAContext with interactionNotAllowed = true")
    }

    func testBackgroundSecretQueryForbidsUIInteraction() {
        let failQuery = C.Keychain.secretQuery(service: "Claude Code-credentials", interaction: .fail)
        let context = failQuery[kSecUseAuthenticationContext as String] as? LAContext
        XCTAssertEqual(context?.interactionNotAllowed, true,
                       "background secret reads must never prompt")

        let allowQuery = C.Keychain.secretQuery(service: "Claude Code-credentials", interaction: .allow)
        XCTAssertNil(allowQuery[kSecUseAuthenticationContext as String],
                     "only the explicit user opt-in path may allow macOS to prompt")
    }

    func testCredentialsFilePathHonoursClaudeConfigDir() {
        let custom = C.Keychain.credentialsFilePath(
            environment: ["CLAUDE_CONFIG_DIR": "/tmp/custom-claude"],
            homeDirectory: "/Users/example")
        XCTAssertEqual(custom, "/tmp/custom-claude/.credentials.json")

        let fallback = C.Keychain.credentialsFilePath(
            environment: ["CLAUDE_CONFIG_DIR": "   "],
            homeDirectory: "/Users/example")
        XCTAssertEqual(fallback, "/Users/example/.claude/.credentials.json")
    }

    func testLiveFileReadIsStrictlyReadOnlyAndCreatesNoLockFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchstats-claude-ro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let credFile = dir.appendingPathComponent(".credentials.json")
        try Data(fileJSON.utf8).write(to: credFile)
        let before = try FileManager.default.attributesOfItem(atPath: credFile.path)[.modificationDate] as? Date

        let read = C.Keychain.liveFileRead(environment: ["CLAUDE_CONFIG_DIR": dir.path])
        XCTAssertEqual(read, .data(Data(fileJSON.utf8)))

        let after = try FileManager.default.attributesOfItem(atPath: credFile.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after, "reading credentials must not modify the file")

        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(entries, [".credentials.json"],
                       "reading credentials must never create lock or sidecar files")
    }

    func testClaudeCredentialsSourceContainsNoMutatingOrSubprocessAPIs() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // NotchStatsTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Sources/NotchStats/Providers/ClaudeCredentials.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let forbidden = [
            "SecItemAdd", "SecItemUpdate", "SecItemDelete",
            "SecKeychainItemModify", "SecKeychainItemDelete",
            "/usr/bin/security", "Process(", "NSTask",
            "write(to:", "createFile(", "removeItem("
        ]
        for symbol in forbidden {
            XCTAssertFalse(source.contains(symbol),
                           "ClaudeCredentials.swift must stay strictly read-only (found \(symbol))")
        }
    }
}
