# NotchStats Keychain Prompt Fix — Investigation, Design & Verification Notes

**Date:** 2026-11-20  
**Branch:** `fix/keychain-prompts`  
**Host:** macOS 27.0.1 (arm64)  
**Safety note:** Zero token values or credential secrets were printed, logged, or committed. All unit tests and snapshot smoke tests used synthetic fixtures. Neither `~/.claude/`, `~/.gemini/`, `/Users/cosmopense/Projects/dynamic-stats/build/`, nor any other app's Keychain item was modified.

---

## 1. Root-Cause Evidence (`securityd`)

Before this fix, `/Applications/NotchStats.app` triggered **37 keychain password prompts in 30 minutes** (~1 every 50 seconds), alternating between `Claude Code-credentials` and `gemini`:

```text
displaying keychain prompt for /Applications/NotchStats.app(86375); ACL: <AclValidationContext(action:24)
  SUBJECT[<ThresholdAclSubject(1 of 3)[<CodeSignatureAclSubject[legacyHash:0d36d119…]
  [path:/Applications/NotchStats.app][requirement:cdhash H"841952fc24cc2a80a1163a220b95ed4c5d743a11"]>] … >
user approved 'allow' for /Applications/NotchStats.app(86375)
```

Five distinct causes compounded:

1. **Background polling read Keychain secret bytes (`kSecReturnData`) on every 60s tick.** With `allowKeychainAccess = 1`, `AppStore.refresh()` → `fetch()` → `resolveAsync()` queried the login Keychain on every refresh.
2. **Gemini was completely ungated.** `AntigravityCredentials.Store.liveKeychainRead()` called `SecItemCopyMatching` with `kSecReturnData = true` unconditionally, ignoring `allowKeychainAccess`.
3. **Ad-hoc signing invalidated "Always Allow" on every rebuild.** `./build.sh` signed ad-hoc (`codesign -s -`), so macOS pinned ACL grants to a per-build `cdhash` that changed on every build.
4. **Empirical discovery on macOS 27: neither `LAContext.interactionNotAllowed = true` nor `kSecUseAuthenticationUIFail` alone suppresses legacy `login.keychain-db` ACL dialogs.**
   - During intermediate testing of this branch (PID `98977`, `2026-11-20 20:23:58`–`20:24:14 IST`), a query passing **both** `kSecUseAuthenticationUI = kSecUseAuthenticationUIFail` and `LAContext(interactionNotAllowed = true)` to `SecItemCopyMatching` **still** triggered `securityd` `displaying keychain prompt` (`AclValidationContext(action:24)`) on both `Claude Code-credentials` and `gemini`.
   - Apple's own `SecItem.h` documents that the `SecItem` authentication-UI attributes apply to the Data Protection Keychain while legacy file-based keychain items still activate UI.
   - Only **`SecKeychainSetUserInteractionAllowed(false)`** (wrapped via a serialized `KeychainGuard` alongside `kSecUseAuthenticationUIFail` and `LAContext.interactionNotAllowed = true`) makes `securityd`'s legacy CDSA/CSSM ACL evaluator reject missing ACL grants silently (`ObjectAcl REJECTS access using ACL`, returning `errSecAuthFailed` / `-25293`) with **zero** password dialogs.
5. **Failed/denied reads were not cached for the session**, so every subsequent poll retried and re-prompted.

---

## 2. Design Implemented

### Zero Keychain reads during background polling
- `ClaudeCredentials.Inputs` and `AntigravityCredentials.Inputs` no longer carry a secret-reading closure. `resolve()` and `resolveAsync()` (called by `ClaudeProvider.fetch()` and `AntigravityProvider.fetch()`) are architecturally incapable of calling `SecItemCopyMatching` with `kSecReturnData`.
- Resolution order on every poll:
  1. Environment override (`CLAUDE_CODE_OAUTH_TOKEN` / `JETSKI_OAUTH_TOKEN`).
  2. Plain CLI file (`~/.claude/.credentials.json` / `~/.gemini/oauth_creds.json`) — always first, free, and unprompted.
  3. App-private `0600` snapshot (`~/Library/Application Support/NotchStats/credentials/{claude,gemini}.json`).
  4. In-memory session cache (`KeychainSessionState`) — populated at most **once at launch** (only if `allowKeychainAccess` is on and no live file/snapshot exists), or on explicit user action / wake-from-sleep. Refusals (`.refused`) are remembered for the rest of the session (zero retry storms).
  5. Attributes-only probe (`kSecReturnAttributes`, never `kSecReturnData`) when unattempted, so the row distinguishes signed-out from *"Claude login not shared — Capture in menu"* / *"Gemini login found, not shared"*.

### Capture-once `0600` app-private snapshots (`CredentialSnapshotStore.swift`)
- Menu items added in `AppDelegate`:
  - **Capture Claude login…** / **Forget Claude login**
  - **Capture Gemini login…** / **Forget Gemini login**
  - **Allow Keychain Access (read once at launch)** (shared by both Claude and Gemini; off by default).
- Clicking **Capture …** is the **only** path in the entire app that allows macOS to display a Keychain prompt (`interaction: .allow` inside `KeychainGuard.withInteraction(allowed: true)`, which immediately restores `SecKeychainSetUserInteractionAllowed(false)` in `defer`).
- On success, `CredentialSnapshotStore.write` atomically writes a `0600` JSON file (created via `open(..., O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)` + `fchmod(0o600)` + `rename`) inside a `0700` directory at `~/Library/Application Support/NotchStats/credentials/<provider>.json`, storing **only** `accessToken`, `expiresAt`, and `capturedAt` (never refresh tokens, ID tokens, emails, or writer IDs).
- Snapshots are automatically treated as stale/absent once past `expiresAt` or older than the provider's token lifetime (8h Claude, 1h Gemini), surfacing the unshared row state and menu hint.
- **Forget …** deletes only NotchStats's own snapshot file and resets the in-memory session cache.

### Triple-layer non-interactive Keychain suppression (`KeychainGuard.swift`)
- `KeychainGuard.disableBackgroundInteraction()` runs at `applicationDidFinishLaunching`.
- Every `SecItemCopyMatching` query in `ClaudeCredentials.swift` and `AntigravityCredentials.swift` runs inside `KeychainGuard.withInteraction(allowed:)` and sets:
  1. `SecKeychainSetUserInteractionAllowed(false)` (suppresses legacy `login.keychain-db` ACL dialogs in `securityd`),
  2. `kSecUseAuthenticationUI = kSecUseAuthenticationUIFail`,
  3. `kSecUseAuthenticationContext` with `LAContext.interactionNotAllowed = true`.
- Enforced by both runtime unit tests and a static audit test (`testStaticKeychainAndSnapshotSecurityAudit`) across all files under `Sources/NotchStats/`.

### Stable-identity signing (`scripts/make-signing-cert.sh` & `build.sh`)
- `scripts/make-signing-cert.sh` creates and trusts a self-signed `"NotchStats Dev"` code-signing certificate in `~/Library/Keychains/login.keychain-db` using `/usr/bin/openssl` (LibreSSL, macOS PKCS#12 safe) and `security import` + `security add-trusted-cert`. It is idempotent, supports `--dry-run`, prints the exact `security` commands, and explains the single password prompt during certificate trust setup.
- `build.sh` signs with `NOTCHSTATS_SIGN_IDENTITY` when set, else auto-detects any valid code-signing certificate whose CN starts with `"NotchStats"`, else falls back cleanly to ad-hoc signing (`-`) without ever failing a build.

---

## 3. Verification Output

### 3.1 Build & Unit Tests (`swift test` & `./build.sh`)

```text
Test Suite 'NotchStatsTests.xctest' passed at 2026-11-20 20:32:44.967.
	 Executed 163 tests, with 0 failures (0 unexpected) in 0.204 (0.223) seconds
Test Suite 'All tests' passed at 2026-11-20 20:32:44.967.
	 Executed 163 tests, with 0 failures (0 unexpected) in 0.204 (0.224) seconds
==> Built /Users/cosmopense/Projects/dynamic-stats-worktrees/keychain-prompts/build/NotchStats.app
CDHash=d8bc4729cb25228ab4da2248a72490c5defcdd4f
Signature=adhoc
```

### 3.2 Live 4m 45s Worst-Case Run (`allowKeychainAccess = 1`, brand-new untrusted ad-hoc CDHash, no snapshots)

Launched `build/NotchStats.app/Contents/MacOS/NotchStats` (PID `6473`, `CDHash=d8bc4729cb25228ab4da2248a72490c5defcdd4f`, ad-hoc signed, NOT in any Keychain ACL) at `2026-11-20T15:11:46Z` (`20:41:46 IST`) with `defaults read dev.notchstats.app` showing `allowKeychainAccess = 1` and checked at `2026-11-20T15:16:31Z` (`04:45` elapsed):

```text
2026-11-20T15:16:31Z
=== Running NotchStats process ===
  PID ELAPSED  %CPU    RSS ARGS
 6473   04:45   0.0  70512 ./build/NotchStats.app/Contents/MacOS/NotchStats
=== defaults read dev.notchstats.app ===
{
    allowKeychainAccess = 1;
}
=== EXACT VERIFICATION COMMAND ===
$ log show --last 5m --predicate 'process == "securityd"' | grep -c 'displaying keychain prompt for .*NotchStats'
0
=== securityd acleval / prompt lines (last 5m) ===
2026-11-20 20:41:46.353 Df securityd[400:10b1] [com.apple.securityd:acleval] ObjectAcl REJECTS access using ACL: ... desc:Claude Code-credentials ...
2026-11-20 20:41:46.362 Df securityd[400:521c58] [com.apple.securityd:acleval] ObjectAcl REJECTS access using ACL: ... desc:gemini ...
```

Key observations from the 4m 45s run:
- **0** keychain prompts (`log show --last 5m --predicate 'process == "securityd"' | grep -c 'displaying keychain prompt for .*NotchStats'` printed **`0`**).
- Exactly **2** silent ACL rejections at launch (`20:41:46.353` and `20:41:46.362`), and **0** keychain calls across all subsequent ~60s background poll ticks.
- `allowKeychainAccess` was restored to `0` after the run.

### 3.3 `NOTCHSTATS_DUMP=1` Smoke Runs (Opt-in Off, Opt-in On, and Synthetic `0600` Snapshot Flow)

1. **`allowKeychainAccess = 0`, no snapshots** (confirms status item + both Claude & Gemini gated behind opt-in):
   ```text
   [statusItem] created=true
   [provider] id=codex name=Codex windows=1 metrics=0
   [provider] id=claude name=Claude error="Claude login not shared — Capture in menu" issue=Optional(NotchStats.ProviderIssue.keychainNotAllowed)
   [provider] id=antigravity name=Gemini error="Gemini login found, not shared" issue=Optional(NotchStats.ProviderIssue.keychainNotAllowed)
   [provider] id=anthropic-api name=Anthropic API windows=0 metrics=1
   [provider] id=opencode name=OpenCode Go windows=3 metrics=0
   [provider] id=openrouter name=OpenRouter windows=1 metrics=0
   ```
2. **End-to-end `0600` snapshot verification (driven with synthetic tokens — no interactive GUI click in this environment):**
   - Wrote synthetic `0600` snapshots to `~/Library/Application Support/NotchStats/credentials/{claude,gemini}.json` (dir `700`, files `600`, `allowKeychainAccess = 0`), ran `NOTCHSTATS_DUMP=1 ./build/NotchStats.app/Contents/MacOS/NotchStats`:
     ```text
     700 /Users/cosmopense/Library/Application Support/NotchStats/credentials
     600 /Users/cosmopense/Library/Application Support/NotchStats/credentials/claude.json
     600 /Users/cosmopense/Library/Application Support/NotchStats/credentials/gemini.json
     [statusItem] created=true
     [provider] id=claude name=Claude error="Claude token rejected" issue=Optional(NotchStats.ProviderIssue.rejected)
     [provider] id=antigravity name=Gemini error="Gemini login rejected" issue=Optional(NotchStats.ProviderIssue.rejected)
     ```
     Both providers read their `0600` snapshot files without touching the Keychain and sent the synthetic bearer tokens to their respective endpoints (returning HTTP 401 `rejected` as expected for fake tokens). Both synthetic files were deleted immediately afterward.
   - Unit tests `testCaptureWrites0600SnapshotWithOnlyRequiredFieldsAndForgetDeletesIt` and `testGeminiCaptureWrites0600SnapshotAndForgetsCleanly` exercise `captureFromKeychain` → `CredentialSnapshotStore.write` (`0700` dir / `0600` file, stripping refresh tokens / emails) → `read` (valid, expired, past token lifetime) → `forgetSnapshot`.
   - Note: Because this session cannot click a macOS GUI Keychain password dialog directly, the interactive **Capture Claude login…** / **Capture Gemini login…** dialog itself was not clicked in this harness; the `KeychainGuard.withInteraction(allowed: true)` toggle and restoration are verified by `testKeychainGuardAlwaysRestoresLegacyInteractionDisabled`, and `scripts/make-signing-cert.sh`'s OpenSSL + `security import` pipeline was verified against an isolated temporary keychain (`1 identity imported.`) plus `--dry-run`.
