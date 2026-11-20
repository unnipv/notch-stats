# Investigation Notes: Claude Code Logouts & NotchStats Status

**Date:** 2026-11-20  
**Host:** macOS 27.0.1 (arm64), Claude Code `2.1.329`, NotchStats PID `17537` (running continuously since `2026-11-18 17:19:00 +0530` from `/Users/cosmopense/Projects/dynamic-stats/build/NotchStats.app`, built `2026-11-06 16:35:38 +0530`)  
**Safety note:** Zero tokens or credential payloads were read, printed, copied, or modified during this investigation. Only non-secret metadata (`cdat`/`mdat`, file existence/mtimes, macOS unified logs, session JSONL error metadata, and source code) was inspected.

---

## Executive Verdict

**NotchStats is NOT the culprit** for the Claude Code CLI logging itself out every ~8 hours.

1. **CLI logouts (Symptom 1) — Culprit identified with millisecond-level proof: Hermes (`hermes-agent` gateway) with `auth.adopt_external_logins: true`.**
   - `~/.hermes/config.yaml` line 1860 sets `adopt_external_logins: true` (even though Hermes's active model provider is `opencode-go` / `nous`, not Anthropic).
   - Every ~8 hours when Claude Code's OAuth `accessToken` reaches expiry, Hermes's background inventory/account-usage refresh (`hermes_cli/inventory.py` → `agent/account_usage.py:_fetch_anthropic_account_usage` → `agent/anthropic_credentials.py:resolve_anthropic_token`) reads `Claude Code-credentials` from the macOS login Keychain, acquires **`~/.claude/.credentials.lock`** (Hermes's own lock path — Claude Code uses `.oauth_refresh.lock`), POSTs Claude Code's single-use refresh token to `https://platform.claude.com/v1/oauth/token` as form-encoded data **without Claude Code's `scope` list**, creates a scopeless `~/.claude/.credentials.json`, and mirrors the update into the Keychain via `security -i`.
   - On the very next `claude` invocation (observed **7m 39s** later on 2026-11-19 and **12m 54s** later on 2026-11-20), `claude.exe` rejects/clears the rotated grant (two `SecKeychainItemModifyContent` calls ~90ms apart, deletes `~/.claude/.credentials.json`, zeroes `accessToken`/`refreshToken` via `tengu_oauth_refresh_token_marked_dead_invalid_grant`), and emits `Not logged in · Please run /login` 5ms into `api-request` — even while the access token Hermes minted is still returning HTTP 200 on `/api/oauth/usage`.
2. **NotchStats showing unreadable / expired / rejected while CLI is signed in (Symptom 2) — Independent app-side causes, now hardened.**
   - On this Mac, `~/.claude/.credentials.json` normally does not exist and `defaults read dev.notchstats.app` does not exist (`allowKeychainAccess` defaults to `false`), so NotchStats legitimately cannot read the Keychain secret unless opted in or `CLAUDE_CODE_OAUTH_TOKEN` is set.
   - Code audit also uncovered four concrete app-side hardening gaps fixed on this branch:
     1. Deprecated `kSecUseAuthenticationUIFail` replaced with `LAContext` (`interactionNotAllowed = true` via `kSecUseAuthenticationContext`).
     2. An expired `~/.claude/.credentials.json` previously short-circuited before checking Keychain (even with opt-in on), causing a false "Claude token expired" when a fresher login lived in Keychain.
     3. An explicitly cleared credential blob (`{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}`, written by Claude Code on `invalid_grant`) previously parsed as `nil` and surfaced as `"Keychain access denied"` or `"Claude credentials unreadable"` instead of `"Not signed in to Claude"`.
     4. An HTTP 401 right after normal OAuth rotation immediately surfaced `"Claude token rejected"` for a full poll cycle instead of invalidating and retrying once with the newly rotated token; and a 200-with-`rate_limit_error` body omitted `issue: .rateLimited` (breaking backoff and stale-reading preservation).

---

## Unified Evidence Timeline

All timestamps shown in **UTC** and local **IST (`+0530`)** where observed.

| Time (UTC) | Time (IST `+0530`) | Source | Event |
| --- | --- | --- | --- |
| `2026-10-16 04:29` | — | `git log` (`86e7841`) | NotchStats `v0.2.1` shipped `/usr/bin/security` lookup. |
| `2026-10-27 18:20:48Z` | `23:50:48` | `~/.claude/projects` + Keychain | `/login` run; `Claude Code-credentials` created (`cdat = 2026-10-27 18:26:52Z`). |
| `2026-11-05 11:20:09Z` | `16:50:09` | `~/.claude/projects` | `authentication_failed: Not logged in · Please run /login` (Hermes logs begin `2026-11-05 00:53`). |
| `2026-11-06 11:05:38Z` | `16:35:38` | `stat` on live build | Live `NotchStats.app` built from PR #1 branch (no `security` subprocess, file-first, opt-in Keychain). |
| `2026-11-07` – `2026-11-17` | — | `~/.claude/projects` & `history.jsonl` | Repeated logouts continue **after** `security` subprocess was removed: Nov 7 (`18:39Z`), Nov 9 (`16:11Z`), Nov 11 (`19:48Z`), Nov 12 (`01:46Z` → `/login 01:47Z`), Nov 13 (`19:04Z` → `/login 19:13Z`), Nov 15 (`13:46Z` → `/login 13:58Z`), Nov 16 (`09:20Z` → `/login 11:40Z` → **`20:39Z`**, 8h 59m later → `/login 20:50Z`), Nov 17 (`/login 14:50Z`). |
| `2026-11-18 11:49:00Z` | `17:19:00` | `ps -o lstart` | NotchStats PID `17537` starts; runs continuously for 48+ hours with `allowKeychainAccess = false`. |
| `2026-11-19 02:23:24Z` | `07:53:24` | `~/.claude/projects` | Last successful `claude` session (`a725b3ca`) finishes. No `claude` runs for the next 8h 16m. |
| `2026-11-19 10:30:42Z` – `10:31:12Z` | `16:00:42` – `16:01:12` | Unified log (`NotchStats[17537]`) | NotchStats calls `SecItemCopyMatching_ios` (probe only — `~/.claude/.credentials.json` does not exist). |
| **`2026-11-19 10:31:48Z` – `10:31:49.200Z`** | **`16:01:48` – `16:01:49.200`** | **Unified log (`python3.14[2647]` = Hermes + `security[42628..42642]`)** | **INCIDENT 1 TRIGGER:** Zero `claude` processes running. Hermes (`python3.14:2647`) runs `security` reads, refreshes expired Claude Code OAuth token, **creates `~/.claude/.credentials.json`**, and runs `security[42641] SecKeychainItemModifyContent` committing `login.keychain-db`, then queries `<dn:GqQQdg>` (`api.anthropic.com`). |
| `2026-11-19 10:31:55Z` – `10:39:10Z` | `16:01:55` – `16:09:10` | Unified log (`NotchStats[17537]`) | **6 seconds after Hermes wrote `.credentials.json`**, NotchStats stops calling `SecItemCopyMatching` and receives **HTTP 200** from `/api/oauth/usage` using `~/.claude/.credentials.json`. |
| **`2026-11-19 10:39:28Z` – `10:39:29.549Z`** | **`16:09:28` – `16:09:29.549`** | **Unified log + `29004851.jsonl`** | **INCIDENT 1 LOGOUT (7m 39s after Hermes):** `claude.exe` runs `security[44206]` (`16:09:29.271`) and `security[44209]` (`16:09:29.367`) `SecKeychainItemModifyContent`, deletes `~/.claude/.credentials.json`, clears `claudeAiOauth`, and fails with `authentication_failed: Not logged in · Please run /login`. |
| `2026-11-19 10:40:19Z` – `10:41:32Z` | `16:10:19` – `16:11:32` | Unified log (`NotchStats[17537]`) | NotchStats sees `.credentials.json` gone → resumes `SecItemCopyMatching_ios`; `16:10:20` still gets **HTTP 200** via 120s `lastGood` grace (proving the access token itself was still valid for `/api/oauth/usage`!); at `16:11:32` grace expires and NotchStats stops calling Anthropic. |
| `2026-11-19 11:05:07Z` | `16:35:07` | `c5574e38.jsonl` + unified log | Owner runs `/login` (`security[62542..62625]`). |
| `2026-11-20 01:35:13Z` | `07:05:13` | `~/.claude/.last-update-result.json` | Claude Code auto-updates `2.1.327` → `2.1.329`. |
| `2026-11-20 02:38:19Z` – `02:38:46Z` | `08:08:19` – `08:08:46` | `a4ecbe35.jsonl` + unified log | Owner runs `/login` (`security[74972] SecKeychainItemModifyContent`). 8-hour access token expires ~`10:38Z` (`16:08 IST`). |
| `2026-11-20 09:44:26Z` | `15:14:26` | `3e6b020d.jsonl` | Last successful `claude` session finishes. No `claude` runs for the next 1h 13m. |
| `2026-11-20 10:43:54Z` | `16:13:54` | Unified log (`NotchStats[17537]`) | NotchStats calls `SecItemCopyMatching_ios` (probe only — no `.credentials.json`). |
| **`2026-11-20 10:45:03Z` – `10:45:04.537Z`** | **`16:15:03` – `16:15:04.537`** | **Unified log (`python3.14[73150]` = Hermes + `security[3422..3448]`) + `stat`** | **INCIDENT 2 TRIGGER (IDENTICAL TO INCIDENT 1):** Zero `claude` processes running (8h 07m after `08:08` `/login`). Hermes (`python3.14:73150`) runs account-usage sweep, touches **`~/.claude/.credentials.lock` (`mtime = 2026-11-20 16:15:04 +0530`)**, POSTs single-use refresh token to `platform.claude.com/v1/oauth/token`, **creates `~/.claude/.credentials.json`**, and runs `security[3447] SecKeychainItemModifyContent` (`16:15:04.523`) committing `login.keychain-db`. |
| `2026-11-20 10:45:14Z` – `10:57:22Z` | `16:15:14` – `16:27:22` | Unified log (`NotchStats[17537]`) | **10 seconds after Hermes wrote `.credentials.json`**, NotchStats stops calling `SecItemCopyMatching` and gets **11 consecutive HTTP 200s** from `/api/oauth/usage`. |
| **`2026-11-20 10:57:58Z` – `10:58:02.549Z`** | **`16:27:58` – `16:28:02.549`** | **Unified log + `dd635504.jsonl`** | **INCIDENT 2 LOGOUT (12m 58s after Hermes):** `claude.exe[9540]` starts (`16:27:58.895`), reads Keychain, calls Anthropic, then executes `security[9842]` (`16:28:02.280`) and `security[9845]` (`16:28:02.368`) `SecKeychainItemModifyContent`, deletes `~/.claude/.credentials.json`, clears `claudeAiOauth`, and emits synthetic `authentication_failed: Not logged in · Please run /login` 5ms after `api-request` (`16:28:02.549`). |
| `2026-11-20 10:58:34Z` – `10:59:49Z` | `16:28:34` – `16:29:49` | Unified log (`NotchStats[17537]`) | NotchStats sees `.credentials.json` deleted → resumes `SecItemCopyMatching_ios`; `16:28:35` still gets **HTTP 200** from `/api/oauth/usage` via `lastGood` grace; at `16:29:49` grace expires and NotchStats returns to probe-only. |
| `2026-11-20 11:34:42Z` – `11:35:14Z` | `17:04:42` – `17:05:14` | `d4ecc1d8.jsonl` + Keychain | Owner runs `/login`; Keychain updated (`security[14267]`, `mdat = 2026-11-20 11:35:14Z`). |
| `2026-11-20 12:20:24Z` | `17:50:24` | `git log` (`5c79ae7`) | PR #1 merged to `main`. |

---

## Hypotheses Tested

### H1: Refresh-token rotation race (concurrent `claude` sessions OR external borrower) — **CONFIRMED (External borrower: Hermes)**
- **Concurrent `claude`-vs-`claude` overlap did NOT precede either observed logout:** On Nov 19 (`16:09:29`) no `claude` session had run for 8+ hours; on Nov 20 (`16:28:02`) no `claude` session had run for 1h 13m.
- **Hermes (`hermes-agent`) IS the external rotator:**
  - `~/.hermes/config.yaml:1860` has `adopt_external_logins: true`.
  - `~/.hermes/hermes-agent/agent/anthropic_credentials.py` borrows `Claude Code-credentials` from Keychain (`line 302`) and refreshes expired tokens (`_refresh_oauth_token`, `line 473`) on background inventory/account-usage sweeps (`hermes_cli/inventory.py:341` → `agent/account_usage.py:509`).
  - **Two distinct defects compound here:**
    1. **Different lock files:** Hermes locks `~/.claude/.credentials.lock` (`hermes_cli/auth.py:717`: `auth_path.with_suffix(".lock")`), whereas Claude Code 2.1.329 locks `~/.claude/.oauth_refresh.lock` and `~/.claude/.storage-write.lock`. There is zero cross-tool mutual exclusion.
    2. **Protocol/payload mismatch on refresh:** Hermes calls `refresh_anthropic_oauth_pure(refresh_token, use_json=False)` (`agent/anthropic_credentials.py:458–470`), sending `application/x-www-form-urlencoded` with **no `scope` parameter**, and writes a scopeless `~/.claude/.credentials.json` (`line 556`) before mirroring into Keychain (`line 582`). Claude Code's own `uae()` sends JSON with its full scope list (`user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload user:plugins ...`) and parses `refresh_token_expires_in` + `scope`. In both documented incidents (Nov 19 `16:01:49` → `16:09:29`; Nov 20 `16:15:04` → `16:28:02`), the very next `claude` startup after Hermes rotated the token triggered `claude.exe`'s dead-token clear (`cSs()`, deleting `.credentials.json` and zeroing Keychain `claudeAiOauth`).
- **Secondary H1 factor:** Concurrent `claude -p` (`sdk-cli`) runs do occur on this Mac (e.g. Nov 16 `18:07Z`, Nov 19 `12:50Z`), though Claude Code `2.1.329` already ships `.oauth_refresh.lock`, `Claude Code-write-check`, and CAS adoption (`tengu_oauth_refresh_save_adopted_newer_write`) for `claude`-vs-`claude` contention.

### H2: NotchStats perturbs Claude Code's Keychain writes — **RULED OUT**
- The live running binary (`/Users/cosmopense/Projects/dynamic-stats/build/NotchStats.app`, PID `17537`, built `2026-11-06`) already contains PR #1's code (confirmed via `strings`: `"Allow Keychain Access"`, `"Claude login found, not readable"`, zero `/usr/bin/security` references).
- `defaults read dev.notchstats.app` does not exist (`allowKeychainAccess` is `false`).
- Across the full 48h unified log (`2026-11-18`–`2026-11-20`):
  - **0** `/usr/bin/security` spawns from NotchStats.
  - **0** Keychain secret reads (`kSecReturnData`) or writes/deletes from NotchStats.
  - **0** `securityd` / `secd` ACL denials or interaction-not-allowed errors for NotchStats.
  - **0** HTTP 401/403/429/5xx responses from NotchStats.
  - During both Incident 1 (`16:01:55`–`16:09:10`) and Incident 2 (`16:15:14`–`16:27:22`), NotchStats was not even touching Keychain at all (it was reading the `.credentials.json` Hermes had just created).
- Logouts continued steadily across Nov 7–20 long after the Nov 6 build removed `/usr/bin/security`.

### H3: Caveman plugin / proxy — **RULED OUT**
- Active hooks in `~/.claude/settings.json` are `caveman-activate.js`, `caveman-mode-tracker.js`, and `caveman-statusline.sh`. Full audit confirmed they only read/write `~/.claude/.caveman-active` (4-byte mode flag) and transcript stats; zero Keychain, `security`, OAuth, or `.credentials.*` access.
- `~/.claude/plugins/marketplaces/caveman/packages/cli/tests/credentials.runtime.mjs` is an unexecuted unit test for caveman's own cloud CLI (`CAVEMAN_HOME`, `CAVE_TOKEN`, `gateway.caveman.cloud`). No `caveman-proxy` process or LaunchAgent is running.

### H4: Stale `~/.claude/.credentials.lock` blocks Claude Code refresh — **RULED OUT as blocker (actually smoking gun for Hermes)**
- Inspection of `/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe` confirms Claude Code `2.1.329` does **not** use `.credentials.lock` — it uses `.oauth_refresh.lock` and `.storage-write.lock`.
- `~/.claude/.credentials.lock` is created exclusively by Hermes (`hermes_cli/auth.py:717`), and its `2026-11-20 16:15:04 +0530` mtime matches Hermes's `16:15:04.523` Keychain write to the exact second.

### H5: App-side state-machine / display bugs in NotchStats — **CONFIRMED (independent of CLI logouts; fixed)**
- Confirmed four real app-side bugs/gaps in `ClaudeCredentials.swift` and `ClaudeProvider.swift`:
  1. Deprecated `kSecUseAuthenticationUIFail` (compiler warnings) → replaced with `LAContext` (`interactionNotAllowed = true` via `kSecUseAuthenticationContext`).
  2. Expired `~/.claude/.credentials.json` shadowed a live Keychain token when `allowKeychainAccess` was enabled → now falls through to Keychain and prefers any live (or fresher) token.
  3. Explicitly cleared JSON (`{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}`, written by Claude Code on `invalid_grant`) mapped to `keychainDenied` / `fileUnreadable` instead of `notSignedIn`, and could be masked by `lastGood` → now parsed as `.cleared` and mapped accurately to `.notSignedIn`.
  4. HTTP 401 during an in-flight OAuth rotation immediately flashed `"Claude token rejected"` instead of re-reading and retrying once with the newly rotated token; and HTTP 200 with `"type": "rate_limit_error"` lacked `issue: .rateLimited` → both fixed.

---

## Relevant Claude Code Changelog Quotes (`~/.claude/cache/changelog.md`)

From Claude Code **2.1.329** (installed `2026-11-20 07:05 IST`):
> - Fixed repeated sign-outs on macOS when Claude Code could read the Keychain but not save to it. That session now stops at expiry and says why, and other sessions stay signed in
> - Changed macOS login renewal to test the Keychain with a `Claude Code-write-check` item
> - Improved `/tui` and other in-place restarts to wait briefly for a login refresh, so they are less likely to sign you out
> - [VSCode] Fixed being signed out of Claude Code in every window and terminal when the sign-in server took 10 to 30 seconds to answer the extension's token refresh

Earlier relevant entries in `~/.claude/cache/changelog.md`:
> - Fixed a request that kept failing with a 401 refreshing your login on every retry and causing 401s in your other sessions
> - Fixed `/usage` hiding limit bars for setup tokens and `CLAUDE_CODE_OAUTH_TOKEN`: it keeps the session and weekly bars and says why the rest are missing

---

## A/B Isolation & Verification Harness

Because Claude Code's OAuth `accessToken` has an ~8-hour TTL, waiting out a full live A/B cycle is not practical inside a single session. However, the macOS unified logs already provided a **natural two-day A/B**: on both `2026-11-19` and `2026-11-20`, logouts occurred within 8–13 minutes of Hermes rotating `Claude Code-credentials` while zero `claude` processes were running and while NotchStats was completely passive.

To let the owner verify 0 logouts over the next 24 hours after disabling Hermes external login adoption, this branch ships:
- `scripts/fix-hermes-claude-auth.sh` — dry-run by default; with `--apply`, backs up `~/.hermes/config.yaml` and sets `adopt_external_logins: false` (never touches `~/.claude/` or tokens).
- `scripts/watch-claude-auth.sh` — read-only 60-second observer logging Keychain `mdat` (attributes-only, never `-w`/`-g`), `.credentials.json`, `.credentials.lock`, `.oauth_refresh.lock`, and active `claude`/`hermes`/`NotchStats` PIDs.

---

## Residual Risk

1. **Owner action required on Hermes:** Until `auth.adopt_external_logins: false` is applied in `~/.hermes/config.yaml` and the Hermes gateway is restarted, Hermes will continue rotating Claude Code's OAuth token every ~8 hours. (Also check after future Hermes upgrades that `adopt_external_logins: false` remains set.)
2. **Live NotchStats binary not replaced:** Per task rules, `/Users/cosmopense/Projects/dynamic-stats/build/NotchStats.app` was left untouched. The owner will need to rebuild/relaunch from this branch (or after merge) to pick up the app-side hardening.
3. **Keychain locked during sleep/clamshell:** If a background `claude -p` session runs while macOS's login Keychain is locked, Claude Code `2.1.329` now refuses to burn the refresh token (using `Claude Code-write-check`) and stops at expiry instead of logging out other sessions, but that individual background run will still need an unlocked Keychain or `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`).
4. **Long-lived `CLAUDE_CODE_OAUTH_TOKEN` trade-off:** Using `claude setup-token` + `CLAUDE_CODE_OAUTH_TOKEN` completely eliminates Keychain contention for both Claude Code and NotchStats, at the cost of manual rotation when the setup token expires.
