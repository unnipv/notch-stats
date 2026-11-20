# Claude Login Stability & Troubleshooting (macOS)

This note explains how Claude Code stores OAuth credentials on macOS, how NotchStats reads them without interfering, and how to stop recurring Claude Code CLI logouts caused by third-party tools sharing the same single-use refresh token.

---

## How NotchStats reads Claude & Gemini credentials

NotchStats is **strictly read-only** with respect to Claude Code and Antigravity/Gemini credentials, and **background polling performs zero Keychain secret reads**:

1. Environment variable (`CLAUDE_CODE_OAUTH_TOKEN` for Claude; `JETSKI_OAUTH_TOKEN` for Gemini).
2. Plain CLI file (`$CLAUDE_CONFIG_DIR/.credentials.json`, default `~/.claude/.credentials.json`; `$GEMINI_CLI_HOME/.gemini/oauth_creds.json`, default `~/.gemini/oauth_creds.json`) — always free and unprompted.
3. App-private `0600` snapshot under `~/Library/Application Support/NotchStats/credentials/<provider>.json` — created **only** when you deliberately click **Capture Claude login…** or **Capture Gemini login…** in the menu bar. Contains only `accessToken`, `expiresAt`, and `capturedAt` (never refresh tokens) and is treated as stale once expired or older than the provider's token lifetime (8h Claude, 1h Gemini). Delete it anytime with **Forget Claude login** / **Forget Gemini login**.
4. In-memory session cache populated **at most once at launch** (or after wake / manual `⌘R`) **only** when **Allow Keychain Access** is enabled and no live file/snapshot exists. Failed or refused reads are remembered for the rest of the session (no retry storm).

Key guarantees:
- **Zero background prompts:** Every non-interactive Keychain probe and secret read sets **all three** macOS suppression guards: `kSecUseAuthenticationUI = kSecUseAuthenticationUIFail`, `LAContext.interactionNotAllowed = true` (`kSecUseAuthenticationContext`), and `SecKeychainSetUserInteractionAllowed(false)` (via `KeychainGuard`). On macOS's legacy `login.keychain-db`, neither `LAContext` nor `UIFail` alone suppresses legacy ACL dialogs (`AclValidationContext(action:24)`); `SecKeychainSetUserInteractionAllowed(false)` makes `securityd` reject missing ACL grants silently with zero dialog. With **Allow Keychain Access** off, only an attributes-only probe (`kSecReturnAttributes`, never `kSecReturnData`) runs for both Claude and Gemini.
- **Never mutates other tools' credentials:** NotchStats never calls `SecItemAdd` / `SecItemUpdate` / `SecItemDelete`, never spawns `/usr/bin/security`, never refreshes OAuth tokens, and never writes to `~/.claude/` or `~/.gemini/` (including `.credentials.lock` or `.oauth_refresh.lock`).
- **Resilient to normal OAuth rotation:**
  - If an expired `~/.claude/.credentials.json` or `~/.gemini/oauth_creds.json` sits next to a fresher captured snapshot (or cached Keychain login), NotchStats uses the fresher token rather than flashing expired.
  - If an API call returns HTTP `401` because the CLI rotated the token mid-poll, NotchStats re-reads non-keychain sources once before surfacing "rejected".
  - If Claude Code explicitly clears a dead login (`accessToken: ""`, `expiresAt: 0`), NotchStats reports **"Not signed in to Claude"** instead of "Keychain access denied" or "Claude credentials unreadable".

### Ad-hoc signing vs. stable signing vs. capture-once

- **Ad-hoc signing (`codesign -s -`) re-prompts after every rebuild:** macOS pins a Keychain "Always Allow" ACL grant to the app's per-build CDHash when the binary is ad-hoc signed, so rebuilding the app immediately invalidates the grant.
- **A stable signing identity makes the grant stick across rebuilds:** run `./scripts/make-signing-cert.sh` once to create and trust a self-signed `"NotchStats Dev"` code-signing certificate in your login Keychain (one password prompt during setup). `./build.sh` auto-detects any `"NotchStats*"` code-signing identity (or honours `NOTCHSTATS_SIGN_IDENTITY`) and falls back to ad-hoc if none exists.
- **Capture-once removes the prompt even with ad-hoc signing:** clicking **Capture Claude login…** or **Capture Gemini login…** reads the Keychain once into NotchStats's own `0600` snapshot file under `~/Library/Application Support/NotchStats/credentials/`. Every subsequent background poll reads that file instead of the Keychain, so ad-hoc builds never prompt during polling either.

---

## Why Claude Code CLI logs itself out every ~8 hours on macOS

Claude Code's OAuth `accessToken` expires after ~8 hours, and its `refreshToken` is **single-use** (rotating it invalidates the previous refresh token immediately).

On macOS, Claude Code stores its login only in the login Keychain (`Claude Code-credentials`) and coordinates concurrent `claude` processes using `~/.claude/.oauth_refresh.lock` plus a `Claude Code-write-check` probe.

If **another tool** on your Mac borrows and refreshes that same Keychain item — in particular **Hermes (`hermes-agent`)** when `auth.adopt_external_logins: true` (the default) is active in `~/.hermes/config.yaml` — the two tools clash on every 8-hour expiry:

1. Hermes's background inventory/usage check sees the expired Claude Code token and refreshes it under its own lock (`~/.claude/.credentials.lock`), which Claude Code does not check.
2. Hermes posts an un-scoped form-encoded refresh request, writes a scopeless `~/.claude/.credentials.json`, and mirrors the result into the Keychain.
3. On the next `claude` startup, Claude Code marks the grant dead, deletes `~/.claude/.credentials.json`, clears `claudeAiOauth` in the Keychain, and prompts `Not logged in · Please run /login`.

### Fix (Hermes users)

Disable external login borrowing in Hermes so Claude Code remains the sole owner of its OAuth refresh token:

```sh
# 1. Preview the change (dry-run by default):
./scripts/fix-hermes-claude-auth.sh

# 2. Back up ~/.hermes/config.yaml and set `adopt_external_logins: false`:
./scripts/fix-hermes-claude-auth.sh --apply

# 3. Restart the Hermes gateway so the updated config takes effect.
# 4. If Hermes itself needs Anthropic models, give it its own separate login:
hermes auth add anthropic

# 5. Re-authenticate Claude Code once if currently signed out:
claude
```

### Alternative: long-lived token via `claude setup-token`

If you run headless/background `claude -p` jobs (especially while the macOS Keychain may be locked during sleep) or want NotchStats to read Claude usage with **Allow Keychain Access** left off:

1. Run `claude setup-token` to mint a long-lived OAuth token.
2. Export it as `CLAUDE_CODE_OAUTH_TOKEN` in your shell / launch environment.

Both Claude Code and NotchStats honour `CLAUDE_CODE_OAUTH_TOKEN` first without touching the macOS Keychain.

---

## Monitoring stability (without reading secrets)

To verify that `Claude Code-credentials` is no longer being rotated unexpectedly by another process, run the read-only observer script:

```sh
# Single snapshot
./scripts/watch-claude-auth.sh --once

# Continuous 60-second log (leave running in a terminal or tmux pane)
./scripts/watch-claude-auth.sh --interval 60 --log /tmp/claude-auth-watch.log
```

The script only reads Keychain item attributes (`mdat`, never `-w` or `-g`), file mtimes (`.credentials.json`, `.credentials.lock`, `.oauth_refresh.lock`), and process IDs. It never reads or prints token values.
