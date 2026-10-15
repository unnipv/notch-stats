# Changelog

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
