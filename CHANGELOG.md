# Changelog

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
