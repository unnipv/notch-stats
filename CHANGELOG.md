# Changelog

## 0.3.0

- **Usage tap for Claude and Gemini — no login, no Keychain (opt-in).**
  - Claude Code and `agy` already pass their real limit state to a status-line
    command on stdin on every render (`rate_limits` for Claude,
    `quota` buckets for `agy`). **Enable usage tap** in the menu bar installs
    a tiny helper (`~/Library/Application Support/NotchStats/bin/notchstats-tap.sh`)
    as the status line of both CLIs; it saves that JSON to
    `~/Library/Application Support/NotchStats/tap/<claude|gemini>.json`
    (`0600`) and NotchStats reads it. No credentials, no token rotation, no
    network request.
  - Priority per poll: a tap capture under 10 minutes old wins, then live
    credentials, then an older capture (shown dimmed as "Last reading") when
    there is no usable login at all.
  - Install asks first and names both files it edits
    (`~/.claude/settings.json`, honouring `CLAUDE_CONFIG_DIR`, and
    `~/.gemini/antigravity-cli/settings.json`). Each is backed up to
    `<file>.notchstats-<unixtime>.bak` before any change, every other key is
    kept, an existing custom status line is chained so it keeps rendering,
    and agy's own status line stays visible (`stack_with_default`). A
    settings file that isn't valid JSON is refused, never overwritten.
  - **Disable usage tap** restores the exact previous `statusLine` (or
    removes the key if there was none), unless you changed it by hand since.
  - Unused `agy` partner buckets (`3p-*`, `remaining_fraction: 1` with a
    1970 reset time) are skipped, and a placeholder reset on any other window
    keeps its percentage with no countdown, so a row never says "resets 56
    years ago". The tap carries no plan tier: the row shows the model in use
    (`model.display_name`) instead, or Gemini's plan if one was fetched earlier.
  - Settings edits re-check the file just before replacing it and re-apply
    once if the CLI wrote it meanwhile; the replace keeps the file's extended
    attributes and ACLs. A settings file NotchStats created is deleted on
    disable if nothing else was added to it.

- **Gemini row follows `agy`'s login across storage layouts.**
  - `agy` does not keep its login in one place across builds: some `1.5.14`
    installations write a plain `0600`
    `~/.gemini/antigravity-cli/antigravity-oauth-token`, while others — the
    build on this Mac among them — keep the `svce=gemini, acct=antigravity`
    Keychain item, refreshed on each `agy` run. NotchStats only knew the
    Keychain item and the stale `~/.gemini/oauth_creds.json` (June-2025
    token), so the Gemini row could report **"token expired"** immediately
    after a fresh `agy` login.
  - Both plain files are now read on every poll with the freshest token
    winning (any unexpired token beats an expired one; otherwise the latest
    `expiry` wins), so a re-login via `agy` is picked up on the next tick.
    Still zero Keychain secret reads and strictly read-only.

- **Zero keychain password prompts during background polling.**
  - Background polling (`AppStore` refresh → provider `fetch()`) now performs
    **zero** Keychain secret reads (`kSecReturnData`). Plain CLI files
    (`~/.claude/.credentials.json`, `~/.gemini/oauth_creds.json`) remain first
    and unprompted; Keychain-only setups now use an explicit, user-initiated
    **Capture Claude login…** / **Capture Gemini login…** menu action that reads
    the Keychain once and writes a private `0600` snapshot under
    `~/Library/Application Support/NotchStats/credentials/<provider>.json`
    containing only `accessToken`, `expiresAt`, and `capturedAt`.
  - Snapshots expire automatically when past `expiresAt` or older than the
    provider's token lifetime (8h for Claude, 1h for Gemini) and can be deleted
    at any time with **Forget Claude login** / **Forget Gemini login** without
    touching `~/.claude/`, `~/.gemini/`, or any Keychain item.
  - Restored `kSecUseAuthenticationUI = kSecUseAuthenticationUIFail` alongside
    `LAContext.interactionNotAllowed = true` **and** wrapped every Keychain
    call in `SecKeychainSetUserInteractionAllowed(false)` (`KeychainGuard`,
    only toggled to `true` during an explicit menu-bar Capture click and
    immediately restored): on macOS 27, neither `LAContext` nor `UIFail` alone
    suppresses legacy `login.keychain-db` ACL password dialogs
    (`AclValidationContext(action:24)`); `SecKeychainSetUserInteractionAllowed(false)`
    makes `securityd` reject missing ACL grants silently (`errSecAuthFailed`)
    with zero dialogs.
  - Gated Gemini (`AntigravityCredentials`) behind the same
    `allowKeychainAccess` opt-in as Claude: with the opt-in off, only an
    attributes-only probe runs and the row shows *"Gemini login found, not
    shared"* instead of reading secret bytes.
  - When **Allow Keychain Access (read once at launch)** is on, NotchStats
    attempts at most **one** non-interactive read at launch (or wake / manual
    `⌘R`) and caches both successes and refusals for the session (no retry
    storm).
  - Added `scripts/make-signing-cert.sh` to create a persistent self-signed
    code-signing certificate (`NotchStats Dev`) in the login Keychain, and
    updated `build.sh` to sign with `NOTCHSTATS_SIGN_IDENTITY` or auto-detect
    any `"NotchStats*"` identity before falling back to ad-hoc signing so
    "Always Allow" grants survive rebuilds.
- **Antigravity / Gemini limits.**
  - Added a read-only **Gemini** (`antigravity`) provider that reads your local
    Antigravity (`agy`) / Gemini login without ever modifying, refreshing, or
    prompting for Keychain passwords (`JETSKI_OAUTH_TOKEN`, then
    `~/.gemini/oauth_creds.json`, then an app-private `0600` captured snapshot,
    then — only if opted in and once at launch — `agy`'s macOS Keychain item
    `gemini` / `antigravity` via `UIFail` + `LAContext`).
  - Calls `daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` once per
    launch (cached for plan tier and project) and
    `/v1internal:retrieveUserQuota` once per existing ~60s poll tick — showing
    real `remainingFraction` and `resetTime` buckets (`Gemini` or `Pro`/`Flash`
    plus `Partner` when 3P Claude/GPT buckets are present) and plan tier (e.g.
    `Google AI Pro`), without inventing limits Google does not expose.
  - Omitted cleanly when Antigravity / Gemini is not installed or signed in.
  - Occupies the second slot on the left notch ear right under Codex.
- **Codex now shows its 5-hour window only.**
  - Dropped Codex's Weekly (`7d`) window from both the collapsed/peek notch bar
    and the expanded panel; the vacated left-ear slot now belongs to Gemini.
  - Replaced the Codex-specific two-window left ear with the shared `EarStack`
    so a single-window provider centres cleanly with no gap, stray ring, or
    panel-height change, and never duplicates its plan label inside a window
    header.
- **Claude login hardening & diagnostics.**
  - Replaced deprecated `kSecUseAuthenticationUIFail` with `LAContext`
    (`interactionNotAllowed = true` via `kSecUseAuthenticationContext`) on all
    background Keychain probes and reads, removing the macOS deprecation
    warnings while keeping background reads strictly non-interactive.
  - When `~/.claude/.credentials.json` holds an expired OAuth token and
    **Allow Keychain Access** is on, NotchStats now checks the Keychain for a
    fresher login before reporting "Claude token expired".
  - An explicitly cleared credential blob (`accessToken: ""`, `expiresAt: 0`,
    written by Claude Code after `invalid_grant`) now reports **"Not signed in
    to Claude"** instead of "Keychain access denied" or "Claude credentials
    unreadable".
  - An HTTP `401` from `/api/oauth/usage` now invalidates the cached token,
    re-reads live sources, and retries once when a newly rotated token is
    present, avoiding a false "Claude token rejected" flash during normal OAuth
    refresh.
  - HTTP 200 responses with a `rate_limit_error` JSON body now map to
    `.rateLimited` (with backoff and dimmed last-reading preservation), matching
    HTTP `429`.
  - Honour `CLAUDE_CONFIG_DIR` when locating `.credentials.json`.
  - Added read-only Keychain/lock diagnostic script
    (`scripts/watch-claude-auth.sh`), Hermes external-login opt-out helper
    (`scripts/fix-hermes-claude-auth.sh`), and
    `docs/claude-login-troubleshooting.md`.
- **NotchStats no longer asks for your keychain password.** The Claude lookup
  used `security find-generic-password -w`, which requests the secret and makes
  macOS prompt for the login password (the grant did not survive a rebuild).
  That subprocess is gone: the credential now comes from
  `CLAUDE_CODE_OAUTH_TOKEN`, then `~/.claude/.credentials.json`, then — only if
  you turn on the new **Allow Keychain Access** menu item (off by default; macOS
  asks for your password once) — the keychain. A Claude login the app isn't
  allowed to read shows "Claude login found, not readable" with a menu hint
  rather than "Not signed in", and a missing or half-written credentials file
  keeps the last good token for two minutes. One process spawn per refresh is
  gone too.
- **The Claude login no longer "disappears".** A failed keychain read used to be
  cached as "no credentials" for five minutes; failures are now remembered for
  10 seconds, an expired token is never served from cache, and wake-from-sleep
  re-reads the credential. Failures are told apart — not signed in, keychain
  denied or not responding, token expired, token rejected, endpoint unreachable,
  rate limited — each with its own caption and recovery hint. Credentials stay
  strictly read-only.
- **More resilient providers.** Transient failures keep the last reading
  (dimmed, marked "Last reading"), network failures and rate limits back off
  per provider, a half-written `~/.codex/auth.json` is retried, and a busy
  OpenCode database never drops a row. A `security` lookup that hangs is killed
  instead of leaking a thread and a process.
- **Lighter.** Idle CPU dropped from 0.6–0.8% to 0.1–0.2% (same method, same
  machine): Anthropic spend is accumulated incrementally, OpenCode sessions are
  re-read only when the database changes, unchanged Codex transcripts cost one
  `stat`, the session poll slows down when idle, and provider requests are
  staggered instead of fired together.
- **New look.** Glass panel, rows that lead with the remaining share, a
  dedicated figure for dollar spend, designed empty and error states, a
  collapsed bar with matching rings on both ears, Reduce Motion support and
  VoiceOver labels. The looping symbol pulse and refresh spinner are gone.

- **Anthropic API spend.** When OpenCode holds a pay-as-you-go Anthropic API
  key, NotchStats adds an **Anthropic API** row with month-to-date and today's
  spend, summed from the `cost` OpenCode records on each Anthropic assistant
  message. Anthropic exposes no credit-balance endpoint for API keys, so the row
  reports spend rather than a made-up remaining balance. OAuth logins are left
  out: they belong to a Claude subscription and aren't billed per use.
- Providers without a quota window get a dollar gauge instead of an empty ring,
  and the expanded panel grows to fit the extra row.
- **Claude in the notch bar.** The 5-hour and weekly windows now also drive a
  compact live indicator, stacked under OpenCode Go on the right ear, so Codex,
  Claude and OpenCode Go are all visible without expanding the panel.

## 0.2.1

- Read the Claude credential with `security` **first**, the way Claude Code
  does. Reading through the Security framework alone makes macOS demand your
  login keychain password; the CLI lookup doesn't. The credential is cached for
  a few minutes so it isn't re-read on every refresh.

## 0.2.0

- **Anthropic / Claude support.** Reads the credential Claude Code already
  wrote (keychain via the Security framework, falling back to the same
  `/usr/bin/security` lookup Claude Code uses, then
  `~/.claude/.credentials.json`) and reports the 5-hour and weekly windows.
- Honest API-key handling: Anthropic reports that usage limits do not apply to
  API organisations, so that is what the row says instead of a fabricated
  number.
- Each provider is now time-boxed. A blocked keychain prompt or a stalled
  connection can no longer stall the other providers — previously one hang left
  the whole panel stuck on "Connecting…".
- Expanded panel is taller to fit four providers.

## 0.1.0

Initial release.

- Notch-native overlay pinned to the physical camera housing, with click-through
  everywhere else.
- Usage is expressed as **remaining** budget (ring + percentage), so an empty
  ring reads as "almost out" rather than a full ring labelled 100%.
- External displays get no island by default; enable **Show on External
  Displays** in the menu bar for a floating pill on non-notched screens.
- Collapsed, peek (hover) and expanded (click) states.
- Usage providers: Codex / ChatGPT (5h + weekly), OpenCode Go (rolling, weekly,
  monthly) and OpenRouter credit.
- Live session tracking for OpenCode v2 and Codex, with state inference
  (thinking, running a tool, responding, compacting, done) and click-to-focus.
- Read-only credential access: expired tokens surface an actionable caption
  instead of failing silently.
- Distribution: curl installer, Homebrew cask, bun/npm wrapper, universal
  ad-hoc-signed builds via GitHub Actions.
