# Claude Login Stability & Troubleshooting (macOS)

This note explains how Claude Code stores OAuth credentials on macOS, how NotchStats reads them without interfering, and how to stop recurring Claude Code CLI logouts caused by third-party tools sharing the same single-use refresh token.

---

## How NotchStats reads Claude credentials

NotchStats is **strictly read-only** with respect to Claude Code credentials:

1. `CLAUDE_CODE_OAUTH_TOKEN` environment variable (if set).
2. `$CLAUDE_CONFIG_DIR/.credentials.json` (defaults to `~/.claude/.credentials.json`).
3. The macOS login Keychain (`Claude Code-credentials` / `Claude Code`), **only** when **Allow Keychain Access** is turned on in the NotchStats menu bar.

Key guarantees:
- **Never prompts in the background:** Every background Keychain probe and secret read attaches a `LocalAuthentication` `LAContext` with `interactionNotAllowed = true` (`kSecUseAuthenticationContext`). With **Allow Keychain Access** off, NotchStats only probes item attributes (`kSecReturnAttributes`), never secret bytes (`kSecReturnData`).
- **Never mutates credentials:** NotchStats never calls `SecItemAdd` / `SecItemUpdate` / `SecItemDelete`, never spawns `/usr/bin/security`, never refreshes OAuth tokens, and never reads or creates `~/.claude/.credentials.lock` or `~/.claude/.oauth_refresh.lock`.
- **Resilient to normal OAuth rotation:**
  - If an expired `~/.claude/.credentials.json` sits next to a fresher Keychain login (and Keychain access is enabled), NotchStats uses the fresher Keychain token rather than flashing "Claude token expired".
  - If an API call returns HTTP `401` because Claude Code rotated the token mid-poll, NotchStats invalidates its cache, re-reads live sources, and retries **once** with the rotated token before surfacing "Claude token rejected".
  - If Claude Code explicitly clears a dead login (`accessToken: ""`, `expiresAt: 0`), NotchStats reports **"Not signed in to Claude"** instead of "Keychain access denied" or "Claude credentials unreadable".

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
