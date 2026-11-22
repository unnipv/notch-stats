import XCTest
@testable import NotchStats

final class UsageTapTests: XCTestCase {

    // MARK: - Fixtures (real payloads, trimmed)

    let claudePayload = Data("""
    {
      "session_id": "abc", "cwd": "/tmp", "version": "2.1.330",
      "model": { "id": "claude-opus-5-5", "display_name": "Opus 5.5" },
      "cost": { "total_cost_usd": 0.16 },
      "context_window": { "total_input_tokens": 45164, "context_window_size": 1000000, "used_percentage": 5 },
      "rate_limits": {
        "five_hour": { "used_percentage": 26, "resets_at": 1795334400 },
        "seven_day":  { "used_percentage": 25, "resets_at": 1795777200 }
      }
    }
    """.utf8)

    let claudePayloadBeforeFirstResponse = Data("""
    {
      "session_id": "abc", "version": "2.1.330",
      "model": { "id": "claude-opus-5-5", "display_name": "Opus 5.5" },
      "context_window": { "context_window_size": 1000000, "used_percentage": 0 }
    }
    """.utf8)

    let geminiPayload = Data("""
    {
      "version": "1.5.14", "product": "antigravity",
      "model": { "id": "Gemini 4 Neon (High)", "display_name": "Gemini 4 Neon (High)", "effort": "high" },
      "agent_state": "initializing", "cycle_mode": "auto",
      "context_window": { "context_window_size": 1048576, "used_percentage": 0 },
      "quota": {
        "gemini-5h":  { "remaining_fraction": 0.85119635, "reset_time": "2026-11-22T08:05:01Z", "reset_in_seconds": 16645 },
        "gemini-weekly": { "remaining_fraction": 0.66828686, "reset_time": "2026-11-28T09:12:12.250Z", "reset_in_seconds": 539076 },
        "gemini-argon-wtu-weekly": { "remaining_fraction": 1, "reset_time": "2026-11-29T03:27:35Z" },
        "3p-5h":     { "remaining_fraction": 1, "reset_time": "1970-01-01T00:00:00Z", "reset_in_seconds": 0 },
        "3p-weekly": { "remaining_fraction": 1, "reset_time": "1970-01-01T00:00:00Z", "reset_in_seconds": 0 }
      }
    }
    """.utf8)

    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageTapTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    // MARK: - Claude parsing

    func testClaudeParse() throws {
        let reading = try XCTUnwrap(UsageTap.parseClaude(claudePayload))
        XCTAssertEqual(reading.note, "Opus 5.5", "note comes from model.display_name")
        let windows = reading.windows
        XCTAssertEqual(windows.map(\.id), ["5h", "7d"])
        XCTAssertEqual(windows.map(\.label), ["5h", "Weekly"])
        XCTAssertEqual(windows[0].remaining, 0.74, accuracy: 1e-9)
        XCTAssertEqual(windows[1].remaining, 0.75, accuracy: 1e-9)
        XCTAssertEqual(windows[0].resetsAt, Date(timeIntervalSince1970: 1_795_334_400))
        XCTAssertEqual(windows[1].resetsAt, Date(timeIntervalSince1970: 1_795_777_200))
    }

    func testClaudeParseWithoutRateLimitsIsNil() {
        XCTAssertNil(UsageTap.parseClaude(claudePayloadBeforeFirstResponse))
        XCTAssertNil(UsageTap.parseClaude(Data(#"{"rate_limits": {}}"#.utf8)))
    }

    func testClaudeParseClampsOutOfRangePercentages() throws {
        let json = #"{"rate_limits":{"five_hour":{"used_percentage":140,"resets_at":1795334400},"#
            + #""seven_day":{"used_percentage":-3}}}"#
        let reading = try XCTUnwrap(UsageTap.parseClaude(Data(json.utf8)))
        XCTAssertNil(reading.note, "no model object → no note")
        let windows = reading.windows
        XCTAssertEqual(windows[0].percent, 1)
        XCTAssertEqual(windows[1].percent, 0)
        XCTAssertNil(windows[1].resetsAt)
    }

    func testClaudePlaceholderResetKeepsWindow() throws {
        let json = #"{"model":{"id":"claude-opus-5-5"},"rate_limits":{"five_hour":{"used_percentage":40,"resets_at":0}}}"#
        let reading = try XCTUnwrap(UsageTap.parseClaude(Data(json.utf8)))
        XCTAssertEqual(reading.note, "claude-opus-5-5", "falls back to model.id")
        XCTAssertEqual(reading.windows.count, 1, "a real percentage survives a placeholder reset")
        XCTAssertEqual(reading.windows[0].percent, 0.4, accuracy: 1e-9)
        XCTAssertNil(reading.windows[0].resetsAt)
    }

    // MARK: - Antigravity parsing

    func testGeminiParse() throws {
        let reading = try XCTUnwrap(UsageTap.parseAntigravity(geminiPayload))
        XCTAssertEqual(reading.note, "Gemini 4 Neon (High)")
        let windows = reading.windows
        // 3p-* (unused, epoch-0 reset) and the argon bucket are skipped.
        XCTAssertEqual(windows.map(\.id), ["gemini", "gemini-wk"])
        XCTAssertEqual(windows.map(\.label), ["Gemini", "Weekly"])
        XCTAssertEqual(windows[0].percent * 100, 14.88, accuracy: 0.005)
        XCTAssertEqual(windows[1].percent * 100, 33.17, accuracy: 0.005)
        XCTAssertEqual(windows[0].resetsAt, isoDate("2026-11-22T08:05:01Z"))
        // Fractional seconds parse too.
        XCTAssertEqual(try XCTUnwrap(windows[1].resetsAt).timeIntervalSince1970,
                       try XCTUnwrap(isoDate("2026-11-28T09:12:12Z")).timeIntervalSince1970 + 0.25,
                       accuracy: 0.001)
    }

    func testGeminiPartnerBucketsAppearOnlyWhenUsed() throws {
        let json = """
        {"quota": {
          "gemini-5h": { "remaining_fraction": 0.5, "reset_time": "2026-11-22T08:05:01Z" },
          "3p-5h":     { "remaining_fraction": 0.9, "reset_time": "2026-11-22T09:00:00Z" },
          "3p-weekly": { "remaining_fraction": 0.4, "reset_time": "1970-01-01T00:00:00Z" },
          "mystery":   { "remaining_fraction": 0.1, "reset_time": "2026-11-22T09:00:00Z" }
        }}
        """
        let reading = try XCTUnwrap(UsageTap.parseAntigravity(Data(json.utf8)))
        XCTAssertNil(reading.note)
        let windows = reading.windows
        XCTAssertEqual(windows.map(\.id), ["gemini", "partner"])
        XCTAssertEqual(windows[1].label, "Partner")
        XCTAssertEqual(windows[1].percent, 0.1, accuracy: 1e-9)
    }

    func testGeminiNeverRendersEpochZeroReset() throws {
        let json = #"{"quota":{"gemini-5h":{"remaining_fraction":0.7,"reset_time":"1970-01-01T00:00:00Z"},"#
            + #""3p-5h":{"remaining_fraction":0.5,"reset_time":"1970-01-01T00:00:00Z"}}}"#
        let windows = try XCTUnwrap(UsageTap.parseAntigravity(Data(json.utf8))).windows
        // The Gemini window keeps its real percentage with no reset; a partner
        // pool with a placeholder reset is still skipped.
        XCTAssertEqual(windows.map(\.id), ["gemini"])
        XCTAssertEqual(windows[0].percent, 0.3, accuracy: 1e-9)
        XCTAssertNil(windows[0].resetsAt)
    }

    // MARK: - Bad input

    func testBadInputIsNilNotThrow() throws {
        for data in [Data(), Data("not json".utf8), Data("[1,2]".utf8), Data("{".utf8)] {
            XCTAssertNil(UsageTap.parseClaude(data))
            XCTAssertNil(UsageTap.parseAntigravity(data))
        }

        XCTAssertNil(UsageTap.read(.claude, directory: temp), "missing file")
        try Data().write(to: UsageTapProviderKind.claude.fileURL(directory: temp))
        XCTAssertNil(UsageTap.read(.claude, directory: temp), "empty file")
        try Data("{\"rate_".utf8).write(to: UsageTapProviderKind.claude.fileURL(directory: temp))
        XCTAssertNil(UsageTap.read(.claude, directory: temp), "truncated file")
    }

    func testReadReturnsCaptureWithMtime() throws {
        let url = UsageTapProviderKind.gemini.fileURL(directory: temp)
        try geminiPayload.write(to: url)
        let stamp = Date(timeIntervalSince1970: 1_795_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)

        let capture = try XCTUnwrap(UsageTap.read(.gemini, directory: temp))
        XCTAssertEqual(capture.data, geminiPayload)
        XCTAssertEqual(capture.modifiedAt.timeIntervalSince1970, stamp.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(capture.windows.count, 2)
    }

    // MARK: - Freshness

    func testFreshnessBoundary() throws {
        let modified = Date(timeIntervalSince1970: 1_795_000_000)
        let capture = UsageTap.Capture(kind: .claude, data: claudePayload, modifiedAt: modified,
                                       reading: try XCTUnwrap(UsageTap.parseClaude(claudePayload)))
        XCTAssertEqual(UsageTap.freshness(capture, now: modified.addingTimeInterval(9 * 60 + 59)), .fresh)
        XCTAssertEqual(UsageTap.freshness(capture, now: modified.addingTimeInterval(10 * 60 + 1)), .stale)
    }

    // MARK: - Provider priority

    private func capture(_ kind: UsageTapProviderKind, age: TimeInterval, now: Date) throws -> UsageTap.Capture {
        let data = kind == .claude ? claudePayload : geminiPayload
        let reading = kind == .claude ? UsageTap.parseClaude(data) : UsageTap.parseAntigravity(data)
        return UsageTap.Capture(kind: kind, data: data, modifiedAt: now.addingTimeInterval(-age),
                                reading: try XCTUnwrap(reading))
    }

    func testClaudeFreshTapSkipsCredentialsAndNetwork() async throws {
        let now = Date()
        let tap = try capture(.claude, age: 30, now: now)
        let calls = Locked(0)
        let provider = ClaudeProvider(
            resolve: { _ in calls.withLock { $0 += 1 }; return .missing(.notSignedIn) },
            transport: { _ in calls.withLock { $0 += 1 }; return (Data(), 500) },
            tap: { tap }, now: { now })

        let usage = try await XCTUnwrapAsync(await provider.fetch())
        XCTAssertNil(usage.error)
        XCTAssertEqual(usage.note, "Opus 5.5", "the model name, never an invented plan tier")
        XCTAssertFalse(usage.isStale)
        XCTAssertEqual(usage.windows.map(\.id), ["5h", "7d"])
        XCTAssertEqual(calls.withLock { $0 }, 0)
    }

    func testClaudeStaleTapOnlyWhenNoCredential() async throws {
        let now = Date()
        let tap = try capture(.claude, age: 3600, now: now)

        let noLogin = ClaudeProvider(resolve: { _ in .missing(.keychainNotAllowed) },
                                     transport: { _ in (Data(), 500) },
                                     tap: { tap }, now: { now })
        let stale = try await XCTUnwrapAsync(await noLogin.fetch())
        XCTAssertNil(stale.error)
        XCTAssertTrue(stale.isStale)
        XCTAssertEqual(stale.windows.count, 2)

        let liveJSON = Data(#"{"five_hour":{"utilization":50},"seven_day":{"utilization":10}}"#.utf8)
        let credential = ClaudeCredentials.Credential(token: "test-oauth-token", kind: .oauth,
                                                      expiresAt: now.addingTimeInterval(3600))
        let loggedIn = ClaudeProvider(resolve: { _ in .found(credential, .file) },
                                      transport: { _ in (liveJSON, 200) },
                                      tap: { tap }, now: { now })
        let live = try await XCTUnwrapAsync(await loggedIn.fetch())
        XCTAssertFalse(live.isStale)
        XCTAssertEqual(live.windows.first?.percent ?? 0, 0.5, accuracy: 1e-9, "live credentials beat a stale tap")
    }

    func testGeminiFreshTapNotesModelAndFallsBackToCachedPlan() async throws {
        let now = Date()
        let tap = try capture(.gemini, age: 5, now: now)
        let cache = Locked<AntigravityProvider.AccountContext?>(.init(tierNote: "Google AI Pro", projectID: "p"))
        let provider = AntigravityProvider(resolve: { _ in .missing(.notSignedIn) },
                                           transport: { _ in (Data(), 500) },
                                           accountCache: cache, tap: { tap }, now: { now })
        let usage = try await XCTUnwrapAsync(await provider.fetch())
        XCTAssertEqual(usage.note, "Gemini 4 Neon (High)",
                       "the model spending the quota beats a plan label from an earlier fetch")
        XCTAssertEqual(usage.windows.map(\.id), ["gemini", "gemini-wk"])

        // Payload without a model: the cached tier note is the only label left.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: geminiPayload) as? [String: Any])
        object.removeValue(forKey: "model")
        let noModel = try XCTUnwrap(UsageTap.parseAntigravity(try JSONSerialization.data(withJSONObject: object)))
        let bare = UsageTap.Capture(kind: .gemini, data: geminiPayload, modifiedAt: now, reading: noModel)
        let uncached = AntigravityProvider(resolve: { _ in .missing(.notSignedIn) },
                                           transport: { _ in (Data(), 500) },
                                           accountCache: cache, tap: { bare }, now: { now })
        let fallback = try await XCTUnwrapAsync(await uncached.fetch())
        XCTAssertEqual(fallback.note, "Google AI Pro", "no model in the payload → cached plan, never a guess")
    }

    func testGeminiStaleTapReplacesMissingRow() async throws {
        let now = Date()
        let tap = try capture(.gemini, age: 7200, now: now)
        let provider = AntigravityProvider(resolve: { _ in .missing(.notSignedIn) },
                                           transport: { _ in (Data(), 500) },
                                           accountCache: Locked(nil), tap: { tap }, now: { now })
        let usage = try await XCTUnwrapAsync(await provider.fetch())
        XCTAssertTrue(usage.isStale)
        XCTAssertEqual(usage.windows.count, 2)
    }

    // MARK: - Installer

    private func makeInstaller() throws -> UsageTapInstaller {
        let claudeDir = temp.appendingPathComponent("home/.claude", isDirectory: true)
        let geminiDir = temp.appendingPathComponent("home/.gemini/antigravity-cli", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        let clock = Locked(1_795_000_000.0)
        return UsageTapInstaller(
            claudeSettingsURL: claudeDir.appendingPathComponent("settings.json"),
            geminiSettingsURL: geminiDir.appendingPathComponent("settings.json"),
            supportDirectory: temp.appendingPathComponent("home/Library/Application Support/NotchStats"),
            now: { Date(timeIntervalSince1970: clock.withLock { $0 += 1; return $0 }) })
    }

    private func object(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(jsonObject(try Data(contentsOf: url)))
    }

    private func backups(of url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(url.lastPathComponent + ".notchstats-") && $0.hasSuffix(".bak") }
    }

    func testInstallIsIdempotentAndUninstallRestores() throws {
        let installer = try makeInstaller()
        let claudeOriginal = #"{"model":"opus","permissions":{"allow":["Bash(ls)"]},"env":{"A":"1"}}"#
        try Data(claudeOriginal.utf8).write(to: installer.claudeSettingsURL)
        // No agy settings file yet: it is created, and uninstall removes only our key.
        XCTAssertEqual(installer.status(), .notInstalled)

        try installer.install()
        XCTAssertEqual(installer.status(), .installed)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installer.scriptURL.path))

        let claude = try object(at: installer.claudeSettingsURL)
        let claudeLine = try XCTUnwrap(claude["statusLine"] as? [String: Any])
        XCTAssertEqual(claudeLine["type"] as? String, "command")
        XCTAssertEqual(claudeLine["command"] as? String, installer.command(for: .claude))
        XCTAssertEqual(claude["model"] as? String, "opus", "other keys preserved")
        XCTAssertNotNil(claude["permissions"])

        let gemini = try object(at: installer.geminiSettingsURL)
        let geminiLine = try XCTUnwrap(gemini["statusLine"] as? [String: Any])
        XCTAssertEqual(geminiLine["command"] as? String, installer.command(for: .gemini))
        XCTAssertEqual(geminiLine["stack_with_default"] as? Bool, true)

        let rawAfterFirst = try String(contentsOf: installer.claudeSettingsURL)
        XCTAssertTrue(rawAfterFirst.hasSuffix("}\n"), "trailing newline")
        XCTAssertTrue(rawAfterFirst.contains("/Library/Application Support/NotchStats/bin/"),
                      "slashes not escaped")
        XCTAssertEqual(try backups(of: installer.claudeSettingsURL).count, 1)

        try installer.install()
        XCTAssertEqual(try String(contentsOf: installer.claudeSettingsURL), rawAfterFirst,
                       "second install is a no-op")
        XCTAssertEqual(try backups(of: installer.claudeSettingsURL).count, 1, "no-op writes no backup")

        try installer.uninstall()
        XCTAssertEqual(installer.status(), .notInstalled)
        let restored = try object(at: installer.claudeSettingsURL)
        let expected = try XCTUnwrap(jsonObject(Data(claudeOriginal.utf8)))
        XCTAssertEqual(try canonical(restored), try canonical(expected))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.geminiSettingsURL.path),
                       "a settings file we created and emptied is removed, not left as {}")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.stateURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.scriptURL.path))
        XCTAssertEqual(try backups(of: installer.claudeSettingsURL).count, 2, "uninstall leaves a backup")
    }

    func testChainsExistingStatusLineAndRestoresIt() throws {
        let installer = try makeInstaller()
        let original = """
        {"statusLine":{"type":"command","command":"echo 'it''s' \\"$PWD\\" | head -c 40","padding":2}}
        """
        try Data(original.utf8).write(to: installer.claudeSettingsURL)
        let agyOriginal = #"{"statusLine":{"command":"~/bin/agy-line.sh"},"theme":"dark"}"#
        try Data(agyOriginal.utf8).write(to: installer.geminiSettingsURL)

        try installer.install()

        let line = try XCTUnwrap(try object(at: installer.claudeSettingsURL)["statusLine"] as? [String: Any])
        let command = try XCTUnwrap(line["command"] as? String)
        let previous = #"echo 'it''s' "$PWD" | head -c 40"#
        XCTAssertEqual(command, installer.command(for: .claude) + " sh -c "
                       + UsageTapInstaller.shellQuote(previous))
        XCTAssertTrue(command.contains(" claude sh -c '"))
        XCTAssertEqual(line["padding"] as? Int, 2, "other status-line options kept")
        XCTAssertEqual(UsageTapInstaller.chainedCommand(in: command, kind: .claude), previous)

        let agyLine = try XCTUnwrap(try object(at: installer.geminiSettingsURL)["statusLine"] as? [String: Any])
        XCTAssertEqual(agyLine["command"] as? String,
                       installer.command(for: .gemini) + " sh -c '~/bin/agy-line.sh'")

        // Re-install doesn't double-wrap.
        try installer.install()
        let again = try XCTUnwrap(try object(at: installer.claudeSettingsURL)["statusLine"] as? [String: Any])
        XCTAssertEqual(again["command"] as? String, command)

        try installer.uninstall()
        XCTAssertEqual(try canonical(try object(at: installer.claudeSettingsURL)),
                       try canonical(try XCTUnwrap(jsonObject(Data(original.utf8)))))
        XCTAssertEqual(try canonical(try object(at: installer.geminiSettingsURL)),
                       try canonical(try XCTUnwrap(jsonObject(Data(agyOriginal.utf8)))))
    }

    func testUninstallWithoutStateUnwrapsChain() throws {
        let installer = try makeInstaller()
        try Data(#"{"statusLine":{"type":"command","command":"my-line --x"}}"#.utf8)
            .write(to: installer.claudeSettingsURL)
        try installer.install()
        try FileManager.default.removeItem(at: installer.stateURL)

        try installer.uninstall()
        let line = try XCTUnwrap(try object(at: installer.claudeSettingsURL)["statusLine"] as? [String: Any])
        XCTAssertEqual(line["command"] as? String, "my-line --x")
    }

    func testUninstallLeavesUserReplacedStatusLineAlone() throws {
        let installer = try makeInstaller()
        try installer.install()
        let mine = #"{"statusLine":{"type":"command","command":"newer-choice"}}"#
        try Data(mine.utf8).write(to: installer.claudeSettingsURL)

        try installer.uninstall()
        XCTAssertEqual(try String(contentsOf: installer.claudeSettingsURL), mine)
    }

    func testIsTapCommandMatchesFirstTokenOnly() throws {
        let installer = try makeInstaller()
        XCTAssertTrue(UsageTapInstaller.isTapCommand(installer.command(for: .claude)))
        XCTAssertTrue(UsageTapInstaller.isTapCommand(installer.command(for: .gemini, chaining: "x")))
        XCTAssertTrue(UsageTapInstaller.isTapCommand("/opt/bin/notchstats-tap.sh claude"))
        XCTAssertFalse(UsageTapInstaller.isTapCommand("echo notchstats-tap.sh"))
        XCTAssertFalse(UsageTapInstaller.isTapCommand("~/bin/wrap.sh '/x/notchstats-tap.sh' claude"))
        XCTAssertFalse(UsageTapInstaller.isTapCommand("/x/my-notchstats-tap.sh.bak claude"))
        XCTAssertFalse(UsageTapInstaller.isTapCommand(nil))
        XCTAssertFalse(UsageTapInstaller.isTapCommand("   "))
    }

    func testCommandMentioningScriptIsChainedNotSkipped() throws {
        let installer = try makeInstaller()
        try Data(#"{"statusLine":{"type":"command","command":"echo notchstats-tap.sh"}}"#.utf8)
            .write(to: installer.claudeSettingsURL)
        try installer.install()
        XCTAssertEqual(UsageTapInstaller.statusLineCommand(try object(at: installer.claudeSettingsURL)),
                       installer.command(for: .claude, chaining: "echo notchstats-tap.sh"))
    }

    func testUninstallIgnoresTamperedSettingsPath() throws {
        let installer = try makeInstaller()
        try Data(#"{"model":"opus"}"#.utf8).write(to: installer.claudeSettingsURL)
        try installer.install()
        let victim = temp.appendingPathComponent("victim.json")
        let victimContent = #"{"statusLine":{"command":"'/x/notchstats-tap.sh' claude"},"keep":1}"#
        try Data(victimContent.utf8).write(to: victim)

        var state = try object(at: installer.stateURL)
        var claude = try XCTUnwrap(state["claude"] as? [String: Any])
        claude["settingsPath"] = victim.path
        state["claude"] = claude
        try JSONSerialization.data(withJSONObject: state).write(to: installer.stateURL)

        try installer.uninstall()
        XCTAssertEqual(try String(contentsOf: victim), victimContent, "file outside the targets untouched")
        XCTAssertEqual(try object(at: installer.claudeSettingsURL) as NSDictionary, ["model": "opus"] as NSDictionary,
                       "real target still restored")
    }

    func testCreatedSettingsFileWithOtherKeysIsKept() throws {
        let installer = try makeInstaller()
        try installer.install()
        XCTAssertEqual(try object(at: installer.stateURL)["claude"].flatMap { ($0 as? [String: Any])?["existed"] }
                       as? Bool, false)
        // The CLI added its own key after we created the file.
        var settings = try object(at: installer.claudeSettingsURL)
        settings["model"] = "opus"
        try JSONSerialization.data(withJSONObject: settings).write(to: installer.claudeSettingsURL)

        try installer.uninstall()
        let restored = try object(at: installer.claudeSettingsURL)
        XCTAssertEqual(restored as NSDictionary, ["model": "opus"] as NSDictionary)
    }

    func testConcurrentEditIsReappliedOnce() throws {
        var installer = try makeInstaller()
        try Data(#"{"model":"opus"}"#.utf8).write(to: installer.claudeSettingsURL)
        let target = installer.claudeSettingsURL
        let calls = Locked(0)
        installer.beforeCommit = { url in
            guard url == target else { return }
            // The CLI writes the file once, mid-edit.
            if calls.withLock({ $0 += 1; return $0 }) == 1 {
                try? Data(#"{"model":"sonnet","theme":"dark"}"#.utf8).write(to: url)
            }
        }
        try installer.install()

        let settings = try object(at: target)
        XCTAssertEqual(settings["model"] as? String, "sonnet", "the concurrent write is not lost")
        XCTAssertEqual(settings["theme"] as? String, "dark")
        XCTAssertEqual(UsageTapInstaller.statusLineCommand(settings), installer.command(for: .claude))
        XCTAssertEqual(calls.withLock { $0 }, 2)
    }

    func testConcurrentEditTwiceThrows() throws {
        var installer = try makeInstaller()
        try Data(#"{"model":"opus"}"#.utf8).write(to: installer.claudeSettingsURL)
        let target = installer.claudeSettingsURL
        let calls = Locked(0)
        installer.beforeCommit = { url in
            guard url == target else { return }
            let n = calls.withLock { $0 += 1; return $0 }
            try? Data("{\"model\":\"edit-\(n)\",\"pad\":\"\(String(repeating: "x", count: n))\"}".utf8).write(to: url)
        }
        XCTAssertThrowsError(try installer.install()) { error in
            XCTAssertEqual(error as? UsageTapError, .concurrentEdit(path: target.path))
            XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains("try again") ?? false)
        }
        XCTAssertEqual(calls.withLock { $0 }, 2, "capped at two attempts")
        XCTAssertEqual(try object(at: target)["model"] as? String, "edit-2", "their write wins")
    }

    func testReplacePreservesExtendedAttributes() throws {
        let installer = try makeInstaller()
        let url = installer.claudeSettingsURL
        try Data(#"{"model":"opus"}"#.utf8).write(to: url)
        let value = Array("kept".utf8)
        XCTAssertEqual(setxattr(url.path, "dev.notchstats.test", value, value.count, 0, 0), 0)

        try installer.install()
        var buffer = [UInt8](repeating: 0, count: 16)
        let read = getxattr(url.path, "dev.notchstats.test", &buffer, buffer.count, 0, 0)
        XCTAssertEqual(read, value.count, "xattr survives the replace")
        XCTAssertEqual(Array(buffer.prefix(max(0, read))), value)
        XCTAssertNotNil(try object(at: url)["statusLine"])
    }

    func testRefusesUnparseableSettings() throws {
        let installer = try makeInstaller()
        let garbage = "{ \"model\": \"opus\", // a comment\n"
        try Data(garbage.utf8).write(to: installer.claudeSettingsURL)

        XCTAssertThrowsError(try installer.install()) { error in
            XCTAssertEqual(error as? UsageTapError,
                           .unparseableSettings(path: installer.claudeSettingsURL.path))
            XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
        }
        XCTAssertEqual(try String(contentsOf: installer.claudeSettingsURL), garbage, "never overwritten")
    }

    func testEmptySettingsFileIsBackedUpAndTreatedAsEmptyObject() throws {
        let installer = try makeInstaller()
        try Data("  \n".utf8).write(to: installer.claudeSettingsURL)
        try installer.install()
        XCTAssertNotNil(try object(at: installer.claudeSettingsURL)["statusLine"])
        XCTAssertEqual(try backups(of: installer.claudeSettingsURL).count, 1)
    }

    func testSkipsCLIThatIsNotInstalled() throws {
        let installer = try makeInstaller()
        try FileManager.default.removeItem(at: installer.geminiSettingsURL.deletingLastPathComponent())
        try installer.install()
        XCTAssertEqual(installer.status(), .installed)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: installer.geminiSettingsURL.deletingLastPathComponent().path),
            "never creates config directories for absent tools")
    }

    func testFollowsSymlinkedSettings() throws {
        let installer = try makeInstaller()
        let real = temp.appendingPathComponent("dotfiles-settings.json")
        try Data(#"{"model":"opus"}"#.utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: installer.claudeSettingsURL, withDestinationURL: real)

        try installer.install()
        let attributes = try FileManager.default.attributesOfItem(atPath: installer.claudeSettingsURL.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertNotNil(try object(at: real)["statusLine"])
    }

    func testLiveInstallerHonoursClaudeConfigDir() {
        let installer = UsageTapInstaller.live(environment: ["CLAUDE_CONFIG_DIR": "/tmp/alt-claude"],
                                               home: "/tmp/fake-home")
        XCTAssertEqual(installer.claudeSettingsURL.path, "/tmp/alt-claude/settings.json")
        XCTAssertEqual(installer.geminiSettingsURL.path, "/tmp/fake-home/.gemini/antigravity-cli/settings.json")
        XCTAssertEqual(installer.scriptURL.path,
                       "/tmp/fake-home/Library/Application Support/NotchStats/bin/notchstats-tap.sh")
    }

    // MARK: - Helper script

    private func writeScript() throws -> URL {
        let url = temp.appendingPathComponent("notchstats-tap.sh")
        try Data(UsageTapInstaller.script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @discardableResult
    private func run(_ arguments: [String], stdin: Data, home: URL? = nil) throws -> (Int32, Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = arguments
        var environment = ["PATH": "/usr/bin:/bin"]
        if let home { environment["HOME"] = home.path }
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(stdin)
        try input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, out)
    }

    func testScriptPassesBashSyntaxCheck() throws {
        let script = try writeScript()
        let (status, _) = try run(["-n", script.path], stdin: Data())
        XCTAssertEqual(status, 0)
        XCTAssertTrue(UsageTapInstaller.script.hasPrefix("#!/bin/bash\n"))
        XCTAssertFalse(UsageTapInstaller.script.contains("jq"))
        XCTAssertFalse(UsageTapInstaller.script.contains("python"))
    }

    func testScriptCapturesAndPassesThroughSamePayload() throws {
        let script = try writeScript()
        let home = temp.appendingPathComponent("scripthome", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let tapDir = UsageTap.defaultDirectory(home: home.path)

        // Chained exactly as the installer writes it, including our quoting.
        let (status, out) = try run([script.path, "claude", "sh", "-c", "cat; exit 3"],
                                    stdin: claudePayload, home: home)
        XCTAssertEqual(status, 3, "passthrough exit status is kept")
        XCTAssertEqual(out, claudePayload, "passthrough sees the same stdin")

        let captured = try Data(contentsOf: UsageTapProviderKind.claude.fileURL(directory: tapDir))
        XCTAssertEqual(captured, claudePayload)
        let mode = try FileManager.default.attributesOfItem(
            atPath: UsageTapProviderKind.claude.fileURL(directory: tapDir).path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tapDir.path)
            .filter { $0.hasPrefix(".") || $0.contains(".new.") }
        XCTAssertEqual(leftovers, [], "temp files removed")
        XCTAssertNotNil(UsageTap.read(.claude, directory: tapDir))

        // Non-JSON input: no capture overwrite, still exits 0 with no passthrough.
        let (plainStatus, plainOut) = try run([script.path, "claude"], stdin: Data("garbage".utf8), home: home)
        XCTAssertEqual(plainStatus, 0)
        XCTAssertEqual(plainOut, Data())
        XCTAssertEqual(try Data(contentsOf: UsageTapProviderKind.claude.fileURL(directory: tapDir)), claudePayload)
    }

    func testInstalledCommandRunsThroughShellWithSpacesInPath() throws {
        let installer = try makeInstaller()
        try Data(#"{"statusLine":{"type":"command","command":"printf 'it'\\''s: '; cat"}}"#.utf8)
            .write(to: installer.claudeSettingsURL)
        try installer.install()
        let command = try XCTUnwrap(UsageTapInstaller.statusLineCommand(
            try object(at: installer.claudeSettingsURL)))
        XCTAssertTrue(installer.scriptURL.path.contains("Application Support"))

        // Claude Code runs the status line through a shell, like this.
        let home = temp.appendingPathComponent("home", isDirectory: true)
        let (status, out) = try runShell(command, stdin: claudePayload, home: home)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(out, Data("it's: ".utf8) + claudePayload)
        XCTAssertNotNil(UsageTap.read(.claude, directory: UsageTap.defaultDirectory(home: home.path)))
    }

    private func runShell(_ command: String, stdin: Data, home: URL) throws -> (Int32, Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": home.path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(stdin)
        try input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, out)
    }

    // MARK: - Helpers

    private func canonical(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

/// `XCTUnwrap` for an already-awaited optional, so the call sites read flat.
private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
