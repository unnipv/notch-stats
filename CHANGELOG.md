# Changelog

## Unreleased

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
