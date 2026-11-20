import LocalAuthentication
import Security
import XCTest
@testable import NotchStats

final class AntigravityTests: XCTestCase {
    private typealias C = AntigravityCredentials

    override func tearDown() {
        super.tearDown()
        C.resetKeychainSession()
    }

    // MARK: - Quota parsing (synthetic fixtures matching real daily-cloudcode-pa shape)

    func testParsesUnifiedGeminiAndPartnerPools() {
        let json = """
        {
          "buckets": [
            { "modelId": "claude-opus-5-5-high", "remainingFraction": 1.0, "resetTime": "2026-11-20T18:53:03Z", "tokenType": "WTUS" },
            { "modelId": "claude-sonnet-5-5-medium", "remainingFraction": 0.96, "resetTime": "2026-11-20T18:53:03Z", "tokenType": "WTUS" },
            { "modelId": "gpt-oss-120b-medium", "remainingFraction": 1.0, "resetTime": "2026-11-20T18:53:03Z", "tokenType": "WTUS" },
            { "modelId": "gemini-2.5-pro", "remainingFraction": 0.925, "resetTime": "2026-11-20T18:31:02Z", "tokenType": "WTUS" },
            { "modelId": "gemini-2.5-flash", "remainingFraction": 0.925, "resetTime": "2026-11-20T18:31:02Z", "tokenType": "WTUS" },
            { "modelId": "gemini-3-flash", "remainingFraction": 0.925, "resetTime": "2026-11-20T18:31:02Z", "tokenType": "WTUS" },
            { "modelId": "gemini-4-hydrogen-sonar", "remainingFraction": 0.925, "resetTime": "2026-11-20T18:31:02Z", "tokenType": "WTUS" },
            { "modelId": "tab_flash_lite_preview", "remainingFraction": 1.0, "tokenType": "WTUS" }
          ]
        }
        """
        let usage = AntigravityProvider.parseQuota(Data(json.utf8), note: "Google AI Pro")

        XCTAssertNil(usage.error)
        XCTAssertEqual(usage.id, "antigravity")
        XCTAssertEqual(usage.name, "Gemini")
        XCTAssertEqual(usage.accentHex, "#4285F4")
        XCTAssertEqual(usage.note, "Google AI Pro")
        XCTAssertEqual(usage.windows.map(\.id), ["gemini", "partner"])
        XCTAssertEqual(usage.windows.map(\.label), ["Gemini", "Partner"])
        XCTAssertEqual(usage.windows[0].remaining, 0.925, accuracy: 0.0001)
        XCTAssertEqual(usage.windows[0].percent, 0.075, accuracy: 0.0001)
        XCTAssertNotNil(usage.windows[0].resetsAt)
        // Partner pool takes tightest remaining fraction across Claude/GPT buckets.
        XCTAssertEqual(usage.windows[1].remaining, 0.96, accuracy: 0.0001)
        XCTAssertEqual(usage.windows[1].percent, 0.04, accuracy: 0.0001)
        XCTAssertNotNil(usage.windows[1].resetsAt)
    }

    func testSplitsGeminiProAndFlashWhenQuotasDiffer() {
        let json = """
        {
          "buckets": [
            { "modelId": "gemini-2.5-pro", "remainingFraction": 0.40, "resetTime": "2026-11-20T18:00:00Z" },
            { "modelId": "gemini-2.5-flash", "remainingFraction": 0.90, "resetTime": "2026-11-20T18:30:00Z" },
            { "modelId": "claude-opus-5-5-high", "remainingFraction": 0.80, "resetTime": "2026-11-20T19:00:00Z" }
          ]
        }
        """
        let usage = AntigravityProvider.parseQuota(Data(json.utf8), note: "Free plan")

        XCTAssertNil(usage.error)
        XCTAssertEqual(usage.windows.map(\.id), ["gemini-pro", "gemini-flash", "partner"])
        XCTAssertEqual(usage.windows.map(\.label), ["Pro", "Flash", "Partner"])
        XCTAssertEqual(usage.windows[0].remaining, 0.40, accuracy: 0.0001)
        XCTAssertEqual(usage.windows[1].remaining, 0.90, accuracy: 0.0001)
        XCTAssertEqual(usage.windows[2].remaining, 0.80, accuracy: 0.0001)
    }

    func testGeminiOnlyAccountProducesSingleGeminiWindow() {
        let json = """
        {
          "buckets": [
            { "modelId": "gemini-2.5-flash", "remainingFraction": 0.65, "resetTime": "2026-11-20T18:30:00Z" }
          ]
        }
        """
        let usage = AntigravityProvider.parseQuota(Data(json.utf8))
        XCTAssertNil(usage.error)
        XCTAssertEqual(usage.windows.map(\.label), ["Gemini"])
        XCTAssertEqual(usage.windows[0].remaining, 0.65, accuracy: 0.0001)
    }

    func testZeroRemainingFractionIsExhaustedNotUnknown() {
        let json = """
        {
          "buckets": [
            { "modelId": "gemini-2.5-pro", "remainingFraction": 0, "resetTime": "2026-11-20T18:30:00Z" }
          ]
        }
        """
        let usage = AntigravityProvider.parseQuota(Data(json.utf8))
        XCTAssertNil(usage.error)
        XCTAssertEqual(usage.windows.first?.remaining, 0.0)
        XCTAssertEqual(usage.windows.first?.percent, 1.0)
    }

    func testMissingRemainingFractionIsSkippedNeverTurnedInto100Percent() {
        let json = """
        {
          "buckets": [
            { "modelId": "gemini-2.5-pro", "resetTime": "2026-11-20T18:30:00Z" },
            { "modelId": "gemini-2.5-flash" }
          ]
        }
        """
        let usage = AntigravityProvider.parseQuota(Data(json.utf8))
        XCTAssertTrue(usage.windows.isEmpty)
        XCTAssertEqual(usage.error, "No data")
    }

    func testOutOfRangeRemainingFractionIsClamped() {
        let json = """
        {
          "buckets": [
            { "modelId": "gemini-2.5-pro", "remainingFraction": 1.8 },
            { "modelId": "gemini-2.5-flash", "remainingFraction": -0.5 }
          ]
        }
        """
        let usage = AntigravityProvider.parseQuota(Data(json.utf8))
        XCTAssertEqual(usage.windows.map(\.label), ["Pro", "Flash"])
        XCTAssertEqual(usage.windows[0].remaining, 1.0)
        XCTAssertEqual(usage.windows[1].remaining, 0.0)
    }

    func testFallbackQuotaBucketForUnrecognisedModels() {
        let json = """
        {
          "buckets": [
            { "modelId": "experimental-alpha-1", "remainingFraction": 0.55 }
          ]
        }
        """
        let usage = AntigravityProvider.parseQuota(Data(json.utf8))
        XCTAssertNil(usage.error)
        XCTAssertEqual(usage.windows.map(\.label), ["Quota"])
        XCTAssertEqual(usage.windows[0].remaining, 0.55, accuracy: 0.0001)
    }

    func testInternalModelsOnlyStillFallbackCleanly() {
        let json = """
        {
          "buckets": [
            { "modelId": "tab_flash_lite_preview", "remainingFraction": 0.85 }
          ]
        }
        """
        let usage = AntigravityProvider.parseQuota(Data(json.utf8))
        XCTAssertNil(usage.error)
        XCTAssertEqual(usage.windows.map(\.label), ["Quota"])
        XCTAssertEqual(usage.windows[0].remaining, 0.85, accuracy: 0.0001)
    }

    func testRpcErrorBodyInside200MapsToIssue() {
        let limited = AntigravityProvider.parseQuota(Data(#"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED"}}"#.utf8))
        XCTAssertEqual(limited.issue, .rateLimited)
        XCTAssertTrue(limited.issue?.backsOff ?? false)

        let unauth = AntigravityProvider.parseQuota(Data(#"{"error":{"code":401,"status":"UNAUTHENTICATED"}}"#.utf8))
        XCTAssertEqual(unauth.issue, .rejected)

        let denied = AntigravityProvider.parseQuota(Data(#"{"error":{"code":403,"status":"PERMISSION_DENIED"}}"#.utf8))
        XCTAssertEqual(denied.issue, .rejected)
    }

    func testEmptyAndGarbageQuotaBodiesFailCleanly() {
        XCTAssertEqual(AntigravityProvider.parseQuota(Data("{}".utf8)).error, "No data")
        XCTAssertEqual(AntigravityProvider.parseQuota(Data(#"{"buckets":[]}"#.utf8)).error, "No data")
        XCTAssertEqual(AntigravityProvider.parseQuota(Data("not json".utf8)).error, "Parse error")
    }

    // MARK: - loadCodeAssist account context parsing

    func testParsesPaidTierAndProjectFromLoadCodeAssist() {
        let json = """
        {
          "cloudaicompanionProject": "synthetic-project-id",
          "currentTier": { "id": "free-tier", "name": "Antigravity" },
          "paidTier": { "id": "g1-pro-tier", "name": "Google AI Pro" }
        }
        """
        let ctx = AntigravityProvider.parseAccountContext(Data(json.utf8))
        XCTAssertEqual(ctx?.tierNote, "Google AI Pro")
        XCTAssertEqual(ctx?.projectID, "synthetic-project-id")
    }

    func testParsesFreeTierWhenNoPaidTierPresent() {
        let json = """
        {
          "cloudaicompanionProject": "synthetic-free-proj",
          "currentTier": { "id": "free-tier", "name": "Antigravity" }
        }
        """
        let ctx = AntigravityProvider.parseAccountContext(Data(json.utf8))
        XCTAssertEqual(ctx?.tierNote, "Free plan")
        XCTAssertEqual(ctx?.projectID, "synthetic-free-proj")
    }

    func testParsesUltraTierFallbackById() {
        let json = #"{"paidTier":{"id":"g1-ultra-tier"}}"#
        let ctx = AntigravityProvider.parseAccountContext(Data(json.utf8))
        XCTAssertEqual(ctx?.tierNote, "Google AI Ultra")
        XCTAssertNil(ctx?.projectID)
    }

    func testLoadCodeAssistGarbageReturnsNil() {
        XCTAssertNil(AntigravityProvider.parseAccountContext(Data("nope".utf8)))
    }

    // MARK: - HTTP and failure mapping

    func testEachAntigravityFailureHasDistinctCaptionAndHint() {
        let states: [ProviderUsage] = [
            AntigravityProvider.failure(.notSignedIn),
            AntigravityProvider.failure(.keychainNotAllowed),
            AntigravityProvider.failure(.keychainDenied),
            AntigravityProvider.failure(.fileUnreadable),
            AntigravityProvider.expired(),
            AntigravityProvider.response(status: 401, data: Data()),
            AntigravityProvider.response(status: 403, data: Data()),
            AntigravityProvider.response(status: 429, data: Data()),
            AntigravityProvider.response(status: 503, data: Data()),
            AntigravityProvider.transportFailure(URLError(.notConnectedToInternet))
        ]
        let captions = states.compactMap(\.error)
        XCTAssertEqual(captions.count, Set(captions).count, "captions must be distinct: \(captions)")
        XCTAssertTrue(states.allSatisfy { $0.hint?.isEmpty == false && $0.issue != nil })
    }

    func testNotSharedCaptionReportsLoginFoundNotShared() {
        let usage = AntigravityProvider.failure(.keychainNotAllowed)
        XCTAssertEqual(usage.issue, .keychainNotAllowed)
        XCTAssertTrue(usage.error?.contains("login found, not shared") ?? false)
        XCTAssertTrue(usage.hint?.contains("Capture Gemini login") ?? false)
    }

    func testUnknownHTTPStatusMapsToStatusMessage() {
        let usage = AntigravityProvider.response(status: 418, data: Data())
        XCTAssertEqual(usage.error, "HTTP 418")
        XCTAssertNil(usage.issue)
    }

    // MARK: - Credential parsing & resolution

    private func wrapGoKeyring(_ json: String) -> Data {
        let encoded = Data(json.utf8).base64EncodedString()
        return Data("\(C.goKeyringPrefix)\(encoded)".utf8)
    }

    private func makeInputs(env: [String: String] = [:],
                            file: C.FileRead = .absent,
                            snapshot: CredentialSnapshotStore.ReadResult = .absent,
                            allowed: Bool = false,
                            sessionKeychain: C.KeychainSessionState = .unattempted,
                            probe: C.KeychainProbe = .absent) -> C.Inputs {
        C.Inputs(environment: env,
                 readFile: { file },
                 readSnapshot: { snapshot },
                 keychainAllowed: allowed,
                 sessionKeychain: sessionKeychain,
                 probeKeychain: { probe })
    }

    func testParsesGoKeyringBase64StoredToken() {
        let raw = """
        {
          "auth_method": "consumer",
          "token": {
            "access_token": "synthetic-keyring-token",
            "expiry": "2099-01-01T00:00:00Z",
            "token_type": "Bearer"
          }
        }
        """
        let cred = C.credential(from: wrapGoKeyring(raw))
        XCTAssertEqual(cred?.token, "synthetic-keyring-token")
        XCTAssertNotNil(cred?.expiresAt)
        XCTAssertFalse(cred?.isExpired() ?? true)
    }

    func testParsesOAuthCredsJSONWithMillisecondExpiry() {
        let json = """
        {
          "access_token": "synthetic-file-token",
          "refresh_token": "synthetic-refresh",
          "token_type": "Bearer",
          "expiry_date": 1797000000000
        }
        """
        let cred = C.credential(from: Data(json.utf8))
        XCTAssertEqual(cred?.token, "synthetic-file-token")
        XCTAssertEqual(cred?.expiresAt?.timeIntervalSince1970 ?? 0, 1_797_000_000, accuracy: 1)
    }

    func testParsesClearedAndMalformedCredentials() {
        XCTAssertEqual(C.parseCredential(from: Data(#"{"access_token":""}"#.utf8)), .cleared)
        XCTAssertEqual(C.parseCredential(from: Data(#"{"token":{"access_token":"   "}}"#.utf8)), .cleared)
        XCTAssertEqual(C.parseCredential(from: Data(#"{"other":1}"#.utf8)), .malformed)
        XCTAssertEqual(C.parseCredential(from: Data("not json".utf8)), .malformed)
    }

    func testResolutionOrderAndLiveBeatsExpired() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let liveKC = C.Credential(token: "live-kc", expiresAt: Date(timeIntervalSince1970: 4_102_444_800))
        let expiredKC = C.Credential(token: "old-kc", expiresAt: Date(timeIntervalSince1970: 1_577_836_800))
        let liveFile = Data(#"{"access_token":"live-file","expiry_date":4102444800000}"#.utf8)
        let expiredFile = Data(#"{"access_token":"old-file","expiry_date":1750830000000}"#.utf8)
        let liveSnap = CredentialSnapshot(accessToken: "live-snap",
                                          expiresAt: now.addingTimeInterval(3600).timeIntervalSince1970,
                                          capturedAt: now.timeIntervalSince1970)

        // Env wins over everything.
        let envRes = C.resolve(
            makeInputs(env: ["JETSKI_OAUTH_TOKEN": " env-tok \n"],
                       file: .data(liveFile),
                       snapshot: .valid(liveSnap),
                       allowed: true,
                       sessionKeychain: .credential(liveKC)),
            lastGood: nil, now: now)
        XCTAssertEqual(envRes, .found(C.Credential(token: "env-tok", expiresAt: nil), .environment))

        // Live plain file wins over snapshot and keychain (plain file is free/unprompted).
        let fileWins = C.resolve(
            makeInputs(file: .data(liveFile),
                       snapshot: .valid(liveSnap),
                       allowed: true,
                       sessionKeychain: .credential(liveKC)),
            lastGood: nil, now: now)
        if case let .found(cred, source) = fileWins {
            XCTAssertEqual(cred.token, "live-file")
            XCTAssertEqual(source, .file)
        } else {
            XCTFail("expected live file credential, got \(fileWins)")
        }

        // Valid 0600 snapshot beats expired oauth_creds.json.
        let snapRes = C.resolve(
            makeInputs(file: .data(expiredFile),
                       snapshot: .valid(liveSnap),
                       allowed: false,
                       probe: .present),
            lastGood: nil, now: now)
        if case let .found(cred, source) = snapRes {
            XCTAssertEqual(cred.token, "live-snap")
            XCTAssertEqual(source, .snapshot)
        } else {
            XCTFail("expected live snapshot credential, got \(snapRes)")
        }

        // Cached live keychain wins over expired oauth_creds.json.
        let kcRes = C.resolve(
            makeInputs(file: .data(expiredFile),
                       allowed: true,
                       sessionKeychain: .credential(liveKC)),
            lastGood: nil, now: now)
        if case let .found(cred, source) = kcRes {
            XCTAssertEqual(cred.token, "live-kc")
            XCTAssertEqual(source, .keychain)
        } else {
            XCTFail("expected live keychain credential, got \(kcRes)")
        }

        // With opt-in off, expired oauth_creds.json + present agy keychain item
        // reports keychainNotAllowed ("Gemini login found, not shared").
        let unshared = C.resolve(
            makeInputs(file: .data(expiredFile), allowed: false, probe: .present),
            lastGood: nil, now: now)
        XCTAssertEqual(unshared, .missing(.keychainNotAllowed))

        // Both expired -> picks the fresher expired token so UI reports expiry.
        let bothExpired = C.resolve(
            makeInputs(file: .data(expiredFile),
                       allowed: true,
                       sessionKeychain: .credential(expiredKC)),
            lastGood: nil, now: now)
        if case let .found(cred, source) = bothExpired {
            XCTAssertEqual(cred.token, "old-file")
            XCTAssertEqual(source, .file)
            XCTAssertTrue(cred.isExpired(now: now))
        } else {
            XCTFail("expected fresher expired credential, got \(bothExpired)")
        }
    }

    func testResolutionGraceAndFailureModes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let good = C.LastGood(
            credential: C.Credential(token: "kept", expiresAt: now.addingTimeInterval(3600)),
            source: .file,
            at: now.addingTimeInterval(-30))

        // Transient unreadable file keeps lastGood within grace.
        let kept = C.resolve(
            makeInputs(file: .unreadable, sessionKeychain: .absent),
            lastGood: good, now: now)
        XCTAssertEqual(kept, .found(good.credential, .lastKnown))

        // Explicit cleared blob does not keep lastGood.
        let cleared = C.resolve(
            makeInputs(file: .data(Data(#"{"access_token":""}"#.utf8)), sessionKeychain: .absent),
            lastGood: good, now: now)
        XCTAssertEqual(cleared, .missing(.notSignedIn))

        // Opt-in off + present keychain item reports keychainNotAllowed.
        let notShared = C.resolve(
            makeInputs(allowed: false, sessionKeychain: .unattempted, probe: .present),
            lastGood: nil, now: now)
        XCTAssertEqual(notShared, .missing(.keychainNotAllowed))

        // Refused keychain without grace reports keychainDenied.
        let denied = C.resolve(
            makeInputs(allowed: true, sessionKeychain: .refused),
            lastGood: nil, now: now)
        XCTAssertEqual(denied, .missing(.keychainDenied))

        // Unreadable file without grace reports fileUnreadable.
        let unreadable = C.resolve(
            makeInputs(file: .data(Data("{".utf8)), sessionKeychain: .absent),
            lastGood: nil, now: now)
        XCTAssertEqual(unreadable, .missing(.fileUnreadable))

        // Nothing anywhere reports notSignedIn.
        let missing = C.resolve(
            makeInputs(file: .absent, sessionKeychain: .absent),
            lastGood: nil, now: now)
        XCTAssertEqual(missing, .missing(.notSignedIn))
    }

    func testGeminiWarmRespectsAllowKeychainAccessAndRemembersRefusal() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchstats-warm-gemini-\(UUID().uuidString)")
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

        // Opt-in on -> single non-interactive read; denied read remembered (no retry storm).
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
        XCTAssertEqual(reads.withLock { $0 }, 1)
        XCTAssertEqual(C.currentSessionState, .refused)
    }

    func testGeminiCaptureWrites0600SnapshotAndForgetsCleanly() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchstats-capture-gemini-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let blob = wrapGoKeyring("""
        {
          "auth_method": "consumer",
          "id_token_email": "private@example.com",
          "token": {
            "access_token": "ya29.synthetic-captured",
            "refresh_token": "1//must-not-be-saved",
            "expiry": "2027-01-15T09:00:00Z"
          },
          "writer_id": "writer-secret"
        }
        """)

        let result = await C.captureFromKeychain(
            snapshotDirectory: dir,
            readSecret: { .data(blob) },
            now: now)
        guard case let .captured(cred) = result else {
            return XCTFail("expected .captured, got \(result)")
        }
        XCTAssertEqual(cred.token, "ya29.synthetic-captured")

        let fileURL = CredentialSnapshotStore.fileURL(for: .gemini, directory: dir)
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let rawText = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(rawText.contains("refresh_token"))
        XCTAssertFalse(rawText.contains("must-not-be-saved"))
        XCTAssertFalse(rawText.contains("private@example.com"))
        XCTAssertFalse(rawText.contains("writer-secret"))

        // Older than 1h Gemini token lifetime is treated as stale.
        XCTAssertEqual(
            CredentialSnapshotStore.read(provider: .gemini,
                                         directory: dir,
                                         now: now.addingTimeInterval(3601)),
            .stale)

        C.forgetSnapshot(snapshotDirectory: dir)
        XCTAssertFalse(CredentialSnapshotStore.exists(provider: .gemini, directory: dir))
    }

    func testProbeAndSecretQueriesSetBothUIFailAndLAContext() {
        let probe = C.Store.probeQuery()
        XCTAssertEqual(probe[kSecAttrService as String] as? String, "gemini")
        XCTAssertEqual(probe[kSecAttrAccount as String] as? String, "antigravity")
        XCTAssertEqual(probe[kSecReturnAttributes as String] as? Bool, true)
        XCTAssertNil(probe[kSecReturnData as String], "probe must never request secret bytes")
        XCTAssertEqual(probe[kSecUseAuthenticationUI as String] as? String,
                       kSecUseAuthenticationUIFail as String)
        XCTAssertEqual((probe[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed, true)

        let failQuery = C.Store.secretQuery(interaction: .fail)
        XCTAssertEqual(failQuery[kSecAttrService as String] as? String, "gemini")
        XCTAssertEqual(failQuery[kSecAttrAccount as String] as? String, "antigravity")
        XCTAssertEqual(failQuery[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(failQuery[kSecUseAuthenticationUI as String] as? String,
                       kSecUseAuthenticationUIFail as String,
                       "secret query MUST set kSecUseAuthenticationUIFail to suppress legacy ACL prompts")
        let context = failQuery[kSecUseAuthenticationContext as String] as? LAContext
        XCTAssertEqual(context?.interactionNotAllowed, true,
                       "secret query MUST also attach LAContext with interactionNotAllowed = true")

        let allowQuery = C.Store.secretQuery(interaction: .allow)
        XCTAssertNil(allowQuery[kSecUseAuthenticationUI as String])
        XCTAssertNil(allowQuery[kSecUseAuthenticationContext as String])
    }

    func testCredentialsFilePathHonoursGeminiCliHome() {
        let custom = C.Store.credentialsFilePath(
            environment: ["GEMINI_CLI_HOME": "/tmp/custom-gemini"],
            homeDirectory: "/Users/example")
        XCTAssertEqual(custom, "/tmp/custom-gemini/.gemini/oauth_creds.json")

        let fallback = C.Store.credentialsFilePath(
            environment: ["GEMINI_CLI_HOME": "   "],
            homeDirectory: "/Users/example")
        XCTAssertEqual(fallback, "/Users/example/.gemini/oauth_creds.json")
    }

    func testLiveFileReadIsStrictlyReadOnlyAndCreatesNoLockFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchstats-gemini-ro-\(UUID().uuidString)")
        let geminiDir = dir.appendingPathComponent(".gemini")
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let credFile = geminiDir.appendingPathComponent("oauth_creds.json")
        let body = Data(#"{"access_token":"synthetic-ro-token","expiry_date":4102444800000}"#.utf8)
        try body.write(to: credFile)
        let before = try FileManager.default.attributesOfItem(atPath: credFile.path)[.modificationDate] as? Date

        let read = C.Store.liveFileRead(environment: ["GEMINI_CLI_HOME": dir.path])
        XCTAssertEqual(read, .data(body))

        let after = try FileManager.default.attributesOfItem(atPath: credFile.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after, "reading credentials must not modify the file")

        let entries = try FileManager.default.contentsOfDirectory(atPath: geminiDir.path)
        XCTAssertEqual(entries, ["oauth_creds.json"],
                       "reading credentials must never create lock or sidecar files")
    }

    func testFetchShowsUnsharedRowWhenKeychainItemNotShared() async {
        let requests = Locked(0)
        let provider = AntigravityProvider(
            resolve: { _ in .missing(.keychainNotAllowed) },
            transport: { _ in
                requests.withLock { $0 += 1 }
                return (Data(), 200)
            },
            accountCache: Locked(nil))

        let usage = await provider.fetch()
        XCTAssertEqual(usage?.issue, .keychainNotAllowed)
        XCTAssertEqual(usage?.error, "Gemini login found, not shared")
        XCTAssertEqual(requests.withLock { $0 }, 0)
    }

    func testFetchRetriesOnceWhenLoadCodeAssistReturns401AndTokenRotated() async {
        let oldCred = C.Credential(token: "tok-old", expiresAt: Date().addingTimeInterval(3600))
        let newCred = C.Credential(token: "tok-new", expiresAt: Date().addingTimeInterval(3600))
        let authHeaders = Locked<[String]>([])

        let provider = AntigravityProvider(
            resolve: { force in .found(force ? newCred : oldCred, .snapshot) },
            transport: { request in
                let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
                authHeaders.withLock { $0.append(auth) }
                if auth == "Bearer tok-old" { return (Data(), 401) }
                let path = request.url?.absoluteString ?? ""
                if path.contains("loadCodeAssist") { return (self.loadCodeAssistJSON, 200) }
                return (self.quotaJSON, 200)
            },
            accountCache: Locked(nil))

        let usage = await provider.fetch()
        XCTAssertNil(usage?.error)
        XCTAssertEqual(usage?.note, "Google AI Pro")
        XCTAssertEqual(authHeaders.withLock { $0 }, ["Bearer tok-old", "Bearer tok-new", "Bearer tok-new"])
    }

    // MARK: - Async fetch behaviour (omission, caching, 401 rotation retry)

    private let loadCodeAssistJSON = Data("""
    {
      "cloudaicompanionProject": "proj-123",
      "paidTier": { "id": "g1-pro-tier", "name": "Google AI Pro" }
    }
    """.utf8)

    private let quotaJSON = Data("""
    {
      "buckets": [
        { "modelId": "gemini-2.5-pro", "remainingFraction": 0.90, "resetTime": "2026-11-20T18:30:00Z" },
        { "modelId": "claude-opus-5-5-high", "remainingFraction": 1.0, "resetTime": "2026-11-20T18:50:00Z" }
      ]
    }
    """.utf8)

    func testFetchReturnsNilWhenNotInstalledOrSignedOut() async {
        let requests = Locked(0)
        let provider = AntigravityProvider(
            resolve: { _ in .missing(.notSignedIn) },
            transport: { _ in
                requests.withLock { $0 += 1 }
                return (Data(), 200)
            },
            accountCache: Locked(nil))

        let usage = await provider.fetch()
        XCTAssertNil(usage, "row must be omitted when Antigravity/Gemini is absent")
        XCTAssertEqual(requests.withLock { $0 }, 0)
    }

    func testFetchReportsExpiredWithoutMakingAnyNetworkCall() async {
        let requests = Locked(0)
        let expired = C.Credential(token: "old", expiresAt: Date().addingTimeInterval(-60))
        let provider = AntigravityProvider(
            resolve: { _ in .found(expired, .file) },
            transport: { _ in
                requests.withLock { $0 += 1 }
                return (Data(), 200)
            },
            accountCache: Locked(nil))

        let usage = await provider.fetch()
        XCTAssertEqual(usage?.issue, .tokenExpired)
        XCTAssertEqual(requests.withLock { $0 }, 0, "must never spend a request on an expired token")
    }

    func testFetchCachesLoadCodeAssistAcrossTicksSoSteadyStateIsOneRequest() async {
        let cred = C.Credential(token: "live-tok", expiresAt: Date().addingTimeInterval(3600))
        let urls = Locked<[String]>([])
        let provider = AntigravityProvider(
            resolve: { _ in .found(cred, .snapshot) },
            transport: { request in
                let path = request.url?.absoluteString ?? ""
                urls.withLock { $0.append(path) }
                if path.contains("loadCodeAssist") { return (self.loadCodeAssistJSON, 200) }
                return (self.quotaJSON, 200)
            },
            accountCache: Locked(nil))

        let first = await provider.fetch()
        XCTAssertNil(first?.error)
        XCTAssertEqual(first?.note, "Google AI Pro")
        XCTAssertEqual(first?.windows.count, 2)

        let second = await provider.fetch()
        XCTAssertNil(second?.error)
        XCTAssertEqual(second?.note, "Google AI Pro")

        let recorded = urls.withLock { $0 }
        XCTAssertEqual(recorded.count, 3, "tick 1 = loadCodeAssist + quota; tick 2 = quota only")
        XCTAssertTrue(recorded[0].contains("loadCodeAssist"))
        XCTAssertTrue(recorded[1].contains("retrieveUserQuota"))
        XCTAssertTrue(recorded[2].contains("retrieveUserQuota"))
    }

    func testFetchRetriesOnceOn401WhenTokenRotated() async {
        let oldCred = C.Credential(token: "tok-old", expiresAt: Date().addingTimeInterval(3600))
        let newCred = C.Credential(token: "tok-new", expiresAt: Date().addingTimeInterval(3600))
        let authHeaders = Locked<[String]>([])
        let cache = Locked<AntigravityProvider.AccountContext?>(
            AntigravityProvider.AccountContext(tierNote: "Google AI Pro", projectID: "proj-123"))

        let provider = AntigravityProvider(
            resolve: { force in .found(force ? newCred : oldCred, .snapshot) },
            transport: { request in
                let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
                authHeaders.withLock { $0.append(auth) }
                if auth == "Bearer tok-old" { return (Data(), 401) }
                return (self.quotaJSON, 200)
            },
            accountCache: cache)

        let usage = await provider.fetch()
        XCTAssertNil(usage?.error)
        XCTAssertEqual(usage?.windows.count, 2)
        XCTAssertEqual(authHeaders.withLock { $0 }, ["Bearer tok-old", "Bearer tok-new"])
    }

    func testFetchDoesNotRetry401WhenTokenUnchanged() async {
        let sameCred = C.Credential(token: "tok-same", expiresAt: Date().addingTimeInterval(3600))
        let calls = Locked(0)
        let cache = Locked<AntigravityProvider.AccountContext?>(
            AntigravityProvider.AccountContext(tierNote: "Google AI Pro", projectID: "proj-123"))

        let provider = AntigravityProvider(
            resolve: { _ in .found(sameCred, .snapshot) },
            transport: { _ in
                calls.withLock { $0 += 1 }
                return (Data(), 401)
            },
            accountCache: cache)

        let usage = await provider.fetch()
        XCTAssertEqual(usage?.issue, .rejected)
        XCTAssertEqual(calls.withLock { $0 }, 1)
    }

    func testFetchMapsTransportErrorToUnreachable() async {
        let cred = C.Credential(token: "live-tok", expiresAt: Date().addingTimeInterval(3600))
        let provider = AntigravityProvider(
            resolve: { _ in .found(cred, .snapshot) },
            transport: { _ in throw URLError(.timedOut) },
            accountCache: Locked(nil))

        let usage = await provider.fetch()
        XCTAssertEqual(usage?.issue, .unreachable)
        XCTAssertTrue(usage?.issue?.backsOff ?? false)
        XCTAssertTrue(usage?.issue?.isTransient ?? false)
    }

    // MARK: - Strictly read-only static guarantee

    func testAntigravitySourcesContainNoMutatingOrSubprocessAPIs() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // NotchStatsTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root

        let files = [
            "Sources/NotchStats/Providers/AntigravityCredentials.swift",
            "Sources/NotchStats/Providers/AntigravityProvider.swift"
        ]
        let forbidden = [
            "SecItemAdd", "SecItemUpdate", "SecItemDelete",
            "SecKeychainItemModify", "SecKeychainItemDelete",
            "/usr/bin/security", "Process(", "NSTask",
            "write(to:", "createFile(", "removeItem(",
            "oauth2.googleapis.com/token", "refresh_token"
        ]

        for relative in files {
            let source = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            for symbol in forbidden {
                XCTAssertFalse(source.contains(symbol),
                               "\(relative) must stay strictly read-only and never refresh (found \(symbol))")
            }
        }
    }
}
