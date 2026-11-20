import LocalAuthentication
import Security
import XCTest
@testable import NotchStats

/// Resolution order, zero-keychain-on-poll guarantee, 0600 snapshot lifecycle,
/// and prompt-suppression audits — with every source replaced by a stub or
/// temp directory: nothing here touches the real keychain or home directory.
final class CredentialResolutionTests: XCTestCase {
    private typealias C = ClaudeCredentials

    private let fileJSON = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-file","expiresAt":4102444800000}}"#
    private let keychainJSON = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-keychain","expiresAt":4102444800000}}"#

    /// Counts what a resolution consulted.
    private final class Calls {
        var file = 0, snapshot = 0, probe = 0
    }

    private func cred(_ token: String, expiresAt: Date? = Date(timeIntervalSince1970: 4_102_444_800)) -> C.Credential {
        C.Credential(token: token, kind: .init(token: token), expiresAt: expiresAt)
    }

    private func inputs(env: [String: String] = [:],
                        file: C.FileRead = .absent,
                        snapshot: CredentialSnapshotStore.ReadResult = .absent,
                        allowed: Bool = false,
                        sessionKeychain: C.KeychainSessionState = .unattempted,
                        probe: C.KeychainProbe = .absent,
                        calls: Calls = Calls()) -> C.Inputs {
        C.Inputs(environment: env,
                 readFile: { calls.file += 1; return file },
                 readSnapshot: { calls.snapshot += 1; return snapshot },
                 keychainAllowed: allowed,
                 sessionKeychain: sessionKeychain,
                 probeKeychain: { calls.probe += 1; return probe })
    }

    private func token(_ resolution: C.Resolution) -> String? {
        if case let .found(credential, _) = resolution { return credential.token }
        return nil
    }

    override func tearDown() {
        super.tearDown()
        C.resetKeychainSession()
    }

    // MARK: - Order

    func testEnvironmentWinsOverFileSnapshotAndKeychain() {
        let calls = Calls()
        let snap = CredentialSnapshot(accessToken: "sk-ant-oat01-snap", expiresAt: 4_102_444_800, capturedAt: 1_800_000_000)
        let resolution = C.resolve(inputs(env: ["CLAUDE_CODE_OAUTH_TOKEN": " sk-ant-oat01-env \n"],
                                          file: .data(Data(fileJSON.utf8)),
                                          snapshot: .valid(snap),
                                          allowed: true,
                                          sessionKeychain: .credential(cred("sk-ant-oat01-keychain")),
                                          calls: calls),
                                   lastGood: nil)
        XCTAssertEqual(token(resolution), "sk-ant-oat01-env")
        XCTAssertEqual(calls.file + calls.snapshot + calls.probe, 0, "nothing else is consulted")
    }

    func testFileWinsOverSnapshotAndKeychain() {
        let calls = Calls()
        let snap = CredentialSnapshot(accessToken: "sk-ant-oat01-snap", expiresAt: 4_102_444_800, capturedAt: 1_800_000_000)
        let resolution = C.resolve(inputs(file: .data(Data(fileJSON.utf8)),
                                          snapshot: .valid(snap),
                                          allowed: true,
                                          sessionKeychain: .credential(cred("sk-ant-oat01-keychain")),
                                          calls: calls),
                                   lastGood: nil)
        XCTAssertEqual(token(resolution), "sk-ant-oat01-file")
        XCTAssertEqual(calls.snapshot, 0)
        XCTAssertEqual(calls.probe, 0)
    }

    func testSnapshotWinsOverKeychainAndExpiredFile() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiredFile = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-old","expiresAt":1799999000000}}"#
        let snap = CredentialSnapshot(accessToken: "sk-ant-oat01-snap",
                                      expiresAt: now.addingTimeInterval(3600).timeIntervalSince1970,
                                      capturedAt: now.timeIntervalSince1970)
        let calls = Calls()
        let resolution = C.resolve(inputs(file: .data(Data(expiredFile.utf8)),
                                          snapshot: .valid(snap),
                                          allowed: false,
                                          probe: .present,
                                          calls: calls),
                                   lastGood: nil, now: now)
        XCTAssertEqual(token(resolution), "sk-ant-oat01-snap")
        if case let .found(_, source) = resolution { XCTAssertEqual(source, .snapshot) }
        XCTAssertEqual(calls.probe, 0, "valid snapshot must not even probe the keychain")
    }

    func testStaleSnapshotFallsThroughToUnsharedState() {
        let resolution = C.resolve(inputs(snapshot: .stale, allowed: false, probe: .present), lastGood: nil)
        XCTAssertEqual(resolution, .missing(.keychainNotAllowed))
    }

    func testSessionKeychainCacheSuppliesTokenWithoutProbing() {
        let calls = Calls()
        let resolution = C.resolve(inputs(allowed: true,
                                          sessionKeychain: .credential(cred("sk-ant-oat01-keychain")),
                                          calls: calls),
                                   lastGood: nil)
        XCTAssertEqual(token(resolution), "sk-ant-oat01-keychain")
        if case let .found(_, source) = resolution { XCTAssertEqual(source, .keychain) }
        XCTAssertEqual(calls.probe, 0)
    }

    func testBlankEnvironmentTokenIsIgnored() {
        let resolution = C.resolve(inputs(env: ["CLAUDE_CODE_OAUTH_TOKEN": "  "],
                                          file: .data(Data(fileJSON.utf8))), lastGood: nil)
        XCTAssertEqual(token(resolution), "sk-ant-oat01-file")
    }

    // MARK: - Opt-in off & zero-retry-storm guarantees

    func testKeychainItemWithoutShareIsNotAllowedNeverNotSignedIn() {
        let resolution = C.resolve(inputs(allowed: false, probe: .present), lastGood: nil)
        XCTAssertEqual(resolution, .missing(.keychainNotAllowed))
        XCTAssertNotEqual(resolution, .missing(.notSignedIn))
    }

    func testLockedKeychainIsNotReportedAsSignedOut() {
        XCTAssertEqual(C.resolve(inputs(probe: .unknown), lastGood: nil), .missing(.keychainDenied))
    }

    func testNothingAnywhereIsNotSignedIn() {
        XCTAssertEqual(C.resolve(inputs(), lastGood: nil), .missing(.notSignedIn))
        XCTAssertEqual(C.resolve(inputs(allowed: true, sessionKeychain: .absent), lastGood: nil), .missing(.notSignedIn))
    }

    func testRefusedSessionKeychainIsDeniedNotSignedOutAndDoesNotProbe() {
        let calls = Calls()
        let resolution = C.resolve(inputs(allowed: true, sessionKeychain: .refused, probe: .present, calls: calls),
                                   lastGood: nil)
        XCTAssertEqual(resolution, .missing(.keychainDenied))
        XCTAssertEqual(calls.probe, 0, "remembered refused read must not even probe again")
    }

    func testWarmFromKeychainRunsAtMostOnceAndRemembersRefusal() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchstats-warm-claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        C.resetKeychainSession()
        let reads = Locked(0)

        // Opt-in off -> zero keychain reads.
        await C.warmFromKeychainIfAllowed(
            keychainAllowed: false,
            environment: [:],
            readFile: { .absent },
            snapshotDirectory: dir,
            readSecret: { reads.withLock { $0 += 1 }; return .refused })
        XCTAssertEqual(reads.withLock { $0 }, 0)
        XCTAssertEqual(C.currentSessionState, .unattempted)

        // Opt-in on -> reads once, remembers .refused; subsequent warm calls do nothing.
        await C.warmFromKeychainIfAllowed(
            keychainAllowed: true,
            environment: [:],
            readFile: { .absent },
            snapshotDirectory: dir,
            readSecret: { reads.withLock { $0 += 1 }; return .refused })
        await C.warmFromKeychainIfAllowed(
            keychainAllowed: true,
            environment: [:],
            readFile: { .absent },
            snapshotDirectory: dir,
            readSecret: { reads.withLock { $0 += 1 }; return .refused })
        XCTAssertEqual(reads.withLock { $0 }, 1, "denied launch read must be remembered for the session")
        XCTAssertEqual(C.currentSessionState, .refused)

        // invalidate() (e.g. 401 on a background poll) must NOT reset the session cache.
        C.invalidate()
        await C.warmFromKeychainIfAllowed(
            keychainAllowed: true,
            environment: [:],
            readFile: { .absent },
            snapshotDirectory: dir,
            readSecret: { reads.withLock { $0 += 1 }; return .refused })
        XCTAssertEqual(reads.withLock { $0 }, 1)

        // resetKeychainSession() (wake-from-sleep / manual refresh) allows one retry.
        C.resetKeychainSession()
        await C.warmFromKeychainIfAllowed(
            keychainAllowed: true,
            environment: [:],
            readFile: { .absent },
            snapshotDirectory: dir,
            readSecret: { reads.withLock { $0 += 1 }; return .found(Data(self.keychainJSON.utf8)) })
        XCTAssertEqual(reads.withLock { $0 }, 2)
        if case let .credential(c) = C.currentSessionState {
            XCTAssertEqual(c.token, "sk-ant-oat01-keychain")
        } else {
            XCTFail("expected cached keychain credential, got \(C.currentSessionState)")
        }
    }

    func testWarmSkipsKeychainWhenValidSnapshotAlreadyExists() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchstats-warm-snap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try CredentialSnapshotStore.write(provider: .claude,
                                          accessToken: "sk-ant-oat01-snap",
                                          expiresAt: now.addingTimeInterval(3600),
                                          capturedAt: now,
                                          directory: dir)

        C.resetKeychainSession()
        let reads = Locked(0)
        await C.warmFromKeychainIfAllowed(
            keychainAllowed: true,
            environment: [:],
            readFile: { .absent },
            snapshotDirectory: dir,
            readSecret: { reads.withLock { $0 += 1 }; return .found(Data(self.keychainJSON.utf8)) },
            now: now)
        XCTAssertEqual(reads.withLock { $0 }, 0, "valid snapshot must skip the launch keychain read")
    }

    // MARK: - Capture-once 0600 snapshot lifecycle

    func testCaptureWrites0600SnapshotWithOnlyRequiredFieldsAndForgetDeletesIt() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchstats-capture-claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let richBlob = """
        {
          "claudeAiOauth": {
            "accessToken": "sk-ant-oat01-captured",
            "refreshToken": "sk-ant-ort01-must-not-be-saved",
            "expiresAt": 1800014400000
          }
        }
        """

        let result = await C.captureFromKeychain(
            snapshotDirectory: dir,
            readSecret: { .found(Data(richBlob.utf8)) },
            now: now)

        guard case let .captured(captured) = result else {
            return XCTFail("expected .captured, got \(result)")
        }
        XCTAssertEqual(captured.token, "sk-ant-oat01-captured")

        let fileURL = CredentialSnapshotStore.fileURL(for: .claude, directory: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        // Verify 0700 directory and 0600 file permissions.
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        let dirMode = (dirAttrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(dirMode, 0o700, "credentials directory must be 0700")

        let fileAttrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileMode = (fileAttrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(fileMode, 0o600, "snapshot file must be 0600")

        // Snapshot must NOT contain refreshToken or extra fields.
        let rawText = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(rawText.contains("refreshToken"), "refresh tokens must never be copied into snapshots")
        XCTAssertFalse(rawText.contains("must-not-be-saved"))

        // Fresh read returns .valid.
        if case let .valid(snap) = CredentialSnapshotStore.read(provider: .claude, directory: dir, now: now.addingTimeInterval(60)) {
            XCTAssertEqual(snap.accessToken, "sk-ant-oat01-captured")
            XCTAssertEqual(snap.expiresAt ?? 0, 1_800_014_400, accuracy: 1)
        } else {
            XCTFail("expected valid snapshot")
        }

        // Past expiry returns .stale.
        XCTAssertEqual(
            CredentialSnapshotStore.read(provider: .claude, directory: dir, now: Date(timeIntervalSince1970: 1_800_014_401)),
            .stale)

        // Older than 8h lifetime returns .stale even if expiresAt were far in the future.
        try CredentialSnapshotStore.write(provider: .claude,
                                          accessToken: "sk-ant-oat01-long",
                                          expiresAt: now.addingTimeInterval(86_400),
                                          capturedAt: now,
                                          directory: dir)
        XCTAssertEqual(
            CredentialSnapshotStore.read(provider: .claude,
                                         directory: dir,
                                         now: now.addingTimeInterval(CredentialSnapshotStore.Provider.claude.maxLifetime + 1)),
            .stale, "snapshot older than provider token lifetime must be treated as stale")

        // Forget deletes the snapshot and resets the session cache.
        C.forgetSnapshot(snapshotDirectory: dir)
        XCTAssertFalse(CredentialSnapshotStore.exists(provider: .claude, directory: dir))
        XCTAssertEqual(C.currentSessionState, .unattempted)
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

    func testNotSharedCaptionPointsAtCaptureInMenu() {
        let usage = ClaudeProvider.failure(.keychainNotAllowed)
        XCTAssertEqual(usage.error, "Claude login not shared — Capture in menu")
        XCTAssertTrue(usage.hint?.contains("Capture Claude login") ?? false)
        XCTAssertNotEqual(usage.error, ClaudeProvider.failure(.notSignedIn).error)
    }

    func testOptInKeyIsSharedByMenuAndResolver() {
        // The menu item and both resolvers share one UserDefaults key.
        XCTAssertEqual(C.keychainOptInKey, "allowKeychainAccess")
    }

    // MARK: - Expired file vs fresh keychain, and explicitly cleared logins

    func testExpiredFileFallsBackToFreshKeychainWhenCached() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiredFile = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-old","expiresAt":1799999000000}}"#
        let freshCred = C.Credential(token: "sk-ant-oat01-fresh", kind: .oauth,
                                     expiresAt: Date(timeIntervalSince1970: 1_800_010_000))
        let resolution = C.resolve(
            inputs(file: .data(Data(expiredFile.utf8)), allowed: true,
                   sessionKeychain: .credential(freshCred)),
            lastGood: nil, now: now)
        XCTAssertEqual(token(resolution), "sk-ant-oat01-fresh")
        if case let .found(_, source) = resolution { XCTAssertEqual(source, .keychain) }
    }

    func testExpiredFileStillReturnsExpiredWhenKeychainHasNothingFresher() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiredFile = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-old","expiresAt":1799999000000}}"#
        let resolution = C.resolve(
            inputs(file: .data(Data(expiredFile.utf8)), allowed: true, sessionKeychain: .absent),
            lastGood: nil, now: now)
        XCTAssertEqual(token(resolution), "sk-ant-oat01-old")
        if case let .found(cred, source) = resolution {
            XCTAssertTrue(cred.isExpired(now: now))
            XCTAssertEqual(source, .file)
        }
    }

    func testClearedKeychainCredentialIsNotSignedInNotKeychainDenied() {
        let now = Date()
        let resolution = C.resolve(
            inputs(allowed: true, sessionKeychain: .cleared),
            lastGood: lastGood(now: now), now: now)
        XCTAssertEqual(resolution, .missing(.notSignedIn),
                       "an explicitly cleared keychain item must report notSignedIn, not keychainDenied or stale lastGood")
    }

    func testClearedFileCredentialIsNotUnreadableAndDoesNotServeLastGood() {
        let now = Date()
        let cleared = #"{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}"#
        let resolution = C.resolve(
            inputs(file: .data(Data(cleared.utf8)), allowed: true, sessionKeychain: .absent),
            lastGood: lastGood(now: now), now: now)
        XCTAssertEqual(resolution, .missing(.notSignedIn))
    }

    func testClearedFileFallsThroughToLiveKeychainWhenCached() {
        let cleared = #"{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}"#
        let resolution = C.resolve(
            inputs(file: .data(Data(cleared.utf8)), allowed: true,
                   sessionKeychain: .credential(cred("sk-ant-oat01-keychain"))),
            lastGood: nil)
        XCTAssertEqual(token(resolution), "sk-ant-oat01-keychain")
        if case let .found(_, source) = resolution { XCTAssertEqual(source, .keychain) }
    }

    // MARK: - Prompt-suppression query invariants & static security audit

    func testProbeQueryIsAttributesOnlyAndSetsBothUIFailAndLAContext() {
        let query = C.Keychain.probeQuery(service: "Claude Code-credentials")
        XCTAssertEqual(query[kSecReturnAttributes as String] as? Bool, true)
        XCTAssertNil(query[kSecReturnData as String], "probe must never request secret bytes")
        XCTAssertEqual(query[kSecUseAuthenticationUI as String] as? String,
                       kSecUseAuthenticationUIFail as String,
                       "probe must set kSecUseAuthenticationUIFail to suppress legacy ACL prompts")
        let context = query[kSecUseAuthenticationContext as String] as? LAContext
        XCTAssertEqual(context?.interactionNotAllowed, true,
                       "probe must also attach an LAContext with interactionNotAllowed = true")
    }

    func testNonInteractiveSecretQuerySetsBothUIFailAndLAContext() {
        let failQuery = C.Keychain.secretQuery(service: "Claude Code-credentials", interaction: .fail)
        XCTAssertEqual(failQuery[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(failQuery[kSecUseAuthenticationUI as String] as? String,
                       kSecUseAuthenticationUIFail as String,
                       "non-interactive secret queries MUST set kSecUseAuthenticationUIFail (LAContext alone does not suppress legacy ACL dialogs)")
        let context = failQuery[kSecUseAuthenticationContext as String] as? LAContext
        XCTAssertEqual(context?.interactionNotAllowed, true,
                       "non-interactive secret queries MUST also attach LAContext with interactionNotAllowed = true")

        // Default interaction must be .fail.
        let defaultQuery = C.Keychain.secretQuery(service: "Claude Code-credentials")
        XCTAssertEqual(defaultQuery[kSecUseAuthenticationUI as String] as? String,
                       kSecUseAuthenticationUIFail as String)

        let allowQuery = C.Keychain.secretQuery(service: "Claude Code-credentials", interaction: .allow)
        XCTAssertNil(allowQuery[kSecUseAuthenticationUI as String])
        XCTAssertNil(allowQuery[kSecUseAuthenticationContext as String],
                     "only the explicit menu-bar Capture path may allow macOS to prompt")
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
        let sourceURL = repoRoot().appendingPathComponent("Sources/NotchStats/Providers/ClaudeCredentials.swift")
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

    /// Static audit across every Swift source file in the app:
    /// 1. Only ClaudeCredentials.swift and AntigravityCredentials.swift may call
    ///    `SecItemCopyMatching` or reference `kSecReturnData`.
    /// 2. Every file with a secret-reading query must set BOTH
    ///    `kSecUseAuthenticationUIFail` and `interactionNotAllowed = true`.
    /// 3. `CredentialSnapshotStore.swift` never touches `.claude`, `.gemini`,
    ///    any Keychain API, or subprocesses.
    func testStaticKeychainAndSnapshotSecurityAudit() throws {
        let sourcesRoot = repoRoot().appendingPathComponent("Sources/NotchStats")
        let enumerator = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)
        var keychainFiles: [String] = []

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            let codeOnly = source
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            let name = url.lastPathComponent

            if codeOnly.contains("SecItemCopyMatching") || codeOnly.contains("kSecReturnData") {
                keychainFiles.append(name)
                XCTAssertTrue(codeOnly.contains("kSecUseAuthenticationUIFail"),
                              "\(name) calls SecItemCopyMatching/kSecReturnData without kSecUseAuthenticationUIFail")
                XCTAssertTrue(codeOnly.contains("kSecUseAuthenticationUI"),
                              "\(name) calls SecItemCopyMatching/kSecReturnData without kSecUseAuthenticationUI")
                XCTAssertTrue(codeOnly.contains("interactionNotAllowed = true"),
                              "\(name) calls SecItemCopyMatching/kSecReturnData without LAContext.interactionNotAllowed = true")
                XCTAssertTrue(codeOnly.contains("kSecUseAuthenticationContext"),
                              "\(name) calls SecItemCopyMatching/kSecReturnData without kSecUseAuthenticationContext")
                XCTAssertTrue(codeOnly.contains("KeychainGuard.withInteraction"),
                              "\(name) calls SecItemCopyMatching without KeychainGuard.withInteraction (SecKeychainSetUserInteractionAllowed)")
            }

            if name == "KeychainGuard.swift" {
                XCTAssertTrue(codeOnly.contains("SecKeychainSetUserInteractionAllowed(false)"),
                              "KeychainGuard.swift must disable legacy Keychain UI via SecKeychainSetUserInteractionAllowed(false)")
            }

            if name == "CredentialSnapshotStore.swift" {
                for forbidden in ["SecItem", "\".claude\"", "\".gemini\"", ".credentials.json", "oauth_creds.json",
                                  "/usr/bin/security", "Process(", "NSTask"] {
                    XCTAssertFalse(codeOnly.contains(forbidden),
                                   "CredentialSnapshotStore.swift must only touch app-private snapshots (found \(forbidden))")
                }
            }

            if name.hasSuffix("Provider.swift") || name == "AppStore.swift" {
                XCTAssertFalse(source.contains("SecItemCopyMatching"),
                               "\(name) must never call SecItemCopyMatching directly")
                XCTAssertFalse(source.contains("kSecReturnData"),
                               "\(name) must never reference kSecReturnData")
                XCTAssertFalse(source.contains("interaction: .allow"),
                               "\(name) must never invoke interactive keychain queries directly")
            }

            if name == "ClaudeCredentials.swift" || name == "AntigravityCredentials.swift" {
                // `interaction: .allow` may only appear inside `captureFromKeychain`.
                let allowLines = source
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .enumerated()
                    .filter { $0.element.contains("interaction: .allow") && !$0.element.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                XCTAssertEqual(allowLines.count, 1,
                               "\(name) may only have one interactive .allow call site (inside captureFromKeychain); found \(allowLines.count)")
                if let only = allowLines.first {
                    XCTAssertTrue(only.element.contains("readSecret(interaction: .allow)"),
                                  "\(name) interactive call site must be the explicit captureFromKeychain default")
                }
            }
        }

        XCTAssertEqual(Set(keychainFiles), Set(["ClaudeCredentials.swift", "AntigravityCredentials.swift"]),
                       "unexpected file touches SecItemCopyMatching/kSecReturnData: \(keychainFiles)")
    }

    func testKeychainGuardAlwaysRestoresLegacyInteractionDisabled() {
        KeychainGuard.disableBackgroundInteraction()
        XCTAssertFalse(KeychainGuard.isLegacyInteractionAllowed)

        let insideAllow: Bool = KeychainGuard.withInteraction(allowed: true) {
            var state = DarwinBoolean(false)
            _ = SecKeychainGetUserInteractionAllowed(&state)
            return state.boolValue
        }
        XCTAssertTrue(insideAllow, "explicit interactive capture must be allowed inside the guarded block")
        XCTAssertFalse(KeychainGuard.isLegacyInteractionAllowed,
                       "legacy keychain interaction MUST be restored to false immediately after capture")

        let insideFail: Bool = KeychainGuard.withInteraction(allowed: false) {
            var state = DarwinBoolean(true)
            _ = SecKeychainGetUserInteractionAllowed(&state)
            return state.boolValue
        }
        XCTAssertFalse(insideFail)
        XCTAssertFalse(KeychainGuard.isLegacyInteractionAllowed)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // NotchStatsTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }
}
