# NotchStats

**Your AI usage limits and live coding sessions, living in the MacBook notch.**

NotchStats is a tiny native macOS overlay that turns the notch into a
Dynamic-Island-style surface. It shows how much of your ChatGPT/Codex and
OpenCode Go allowance you have burned, your OpenRouter credit, and what your
coding agents are doing right now — without you switching windows.

```
        ◖ 87%   ───────notch───────   12% ◗
```

Hover the notch for a quick read. Click it for the full panel.

## Features

All figures show **what's left**, not what's been used: a nearly-empty ring means
you're almost out.

- **Codex / ChatGPT limits** — the 5-hour and weekly windows, with reset timers.
- **OpenCode Go limits** — the rolling (5h), weekly and monthly allowances from
  the official quota endpoint.
- **OpenRouter credit** — remaining balance and spend, straight from the API.
- **Live sessions** — OpenCode and Codex conversations with their current state
  (thinking, running a tool, responding, compacting, done) and how long ago they
  last moved. Click a row to jump to your terminal.
- **Notch-native** — a borderless, non-activating panel that hugs the physical
  camera housing, floats above the menu bar on every Space, and lets clicks pass
  through everywhere else.
- **Local-first** — no account, no telemetry, no proxy. It reads credentials your
  tools already wrote and calls only the providers' own endpoints.

## Requirements

- macOS 14 (Sonoma) or later. Built and tested on macOS 27.
- A MacBook with a notch (falls back to a menu-bar pill elsewhere).
- OpenCode v2 for OpenCode Go usage and live OpenCode sessions.
- Codex for Codex limits and Codex sessions.

## Install

**curl**

```sh
curl -fsSL https://raw.githubusercontent.com/notch-stats/notch-stats/main/scripts/install.sh | bash
```

**Homebrew**

```sh
brew tap notch-stats/notch-stats
brew install --cask notch-stats
```

**bun / npm**

```sh
bunx notch-stats
```

**From source**

```sh
git clone https://github.com/notch-stats/notch-stats
cd notch-stats
./build.sh
open build/NotchStats.app
```

Builds are unsigned, so the installer strips the Gatekeeper quarantine flag for
you. If you download it by hand and macOS complains, run
`xattr -dr com.apple.quarantine /Applications/NotchStats.app`.

## How it works

NotchStats reads data your tools already keep and calls the providers' own
endpoints. Nothing is uploaded anywhere.

| Widget | Source |
| --- | --- |
| Codex / ChatGPT limits | `~/.codex/auth.json` → `chatgpt.com/backend-api/wham/usage` |
| OpenCode Go limits | `opencode.db` credential → `opencode.ai/zen/go/v1/usage` |
| OpenRouter credit | `opencode.db` credential → `openrouter.ai/api/v1/credits` |
| OpenCode sessions | read-only `~/.local/share/opencode/opencode.db` (`session_v2`, `session_message`) |
| Codex sessions | tail of the newest `~/.codex/sessions/**/rollout-*.jsonl` |

Credentials are **read-only**. NotchStats never refreshes or rewrites your
tokens — your CLIs own them. If a token has expired you'll see a caption telling
you how to refresh it.

## Performance

Designed to be invisible. Measured on a MacBook Air M2 with a notched built-in
display plus a 1440p external monitor (two island windows):

- **~0.5% CPU idle, ~21 MB physical footprint.**
- Sessions refresh every 2.5s with a handful of indexed SQLite reads; usage
  refreshes every ~60s with jitter.
- Countdowns are computed from `Date` rather than ticked, and nothing animates
  on a loop — a repeating animation would keep the window's display link active
  and stop the app ever idling.
- No cost engine, no chart library, no updater, no background subprocesses.

## Development

```sh
swift build          # compile
swift test           # unit tests
./build.sh           # assemble build/NotchStats.app (universal, ad-hoc signed)
./scripts/make-icns.sh
```

Test hooks (development only):

```sh
NOTCHSTATS_STATE=collapsed|peek|expanded
NOTCHSTATS_PAGE=activity
NOTCHSTATS_DEBUG_BG=1     # tint the island so its bounds are visible in screenshots
NOTCHSTATS_DUMP=1         # print notch geometry to stderr
scripts/cpu.sh <pid> 10   # true CPU usage over a window
```

## Releasing

Push a tag; CI builds a universal bundle and attaches `NotchStats.zip` to the
GitHub release.

```sh
git tag v0.1.0 && git push origin v0.1.0
```

## License

MIT
