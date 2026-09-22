<div align="center">

# claude-code-statusline

**A fast, resume-safe statusline for [Claude Code](https://code.claude.com) — model & thinking mode, context usage, free tokens, rate limits, running subagents, cost & git branch. Zero required dependencies on Windows.**

[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS%20%7C%20Linux%20%7C%20WSL-blue)](#installation)
[![Runtime](https://img.shields.io/badge/runtime-Node%20%7C%20Python%20%7C%20PowerShell-8A2BE2)](#how-the-installer-picks-a-runtime)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![npm](https://img.shields.io/npm/v/%40hashfox%2Fclaude-code-statusline?logo=npm&color=CB3837)](https://www.npmjs.com/package/@hashfox/claude-code-statusline)

<img src="assets/demo.svg" alt="Statusline demo below the Claude Code input" width="980">

</div>

---

## Installation — one command

**Windows** (PowerShell):

```powershell
irm https://raw.githubusercontent.com/HashfoxGmbH/claude-code-statusline/main/install.ps1 | iex
```

**Linux / WSL / macOS**:

```bash
curl -fsSL https://raw.githubusercontent.com/HashfoxGmbH/claude-code-statusline/main/install.sh | bash
```

**npm / npx**:

```bash
npx @hashfox/claude-code-statusline
```

Every installer is **idempotent**, merges `~/.claude/settings.json` **losslessly**
and runs a smoke test before finishing. Your settings from before the first install are
saved as `settings.json.bak` — re-running an installer never overwrites that backup.
Installers check that a runtime actually works before using it (e.g. the Microsoft Store
`python.exe` placeholder on Windows is skipped).
New Claude Code sessions show the statusline immediately; running sessions after a restart.

## What you see

```text
Fable 5 · high │ ▰▰▱▱▱▱▱▱▱▱ 25% │ 246.0k/1M · free 754.0k │ 5h 23% · 7d 41% │ Agents: 2 │ $1.23 · +230/-57 lines · 2h21m runtime │ my-project (main)
```

| Segment | Meaning |
|---|---|
| `Fable 5` | Current model |
| `· high` | Reasoning effort (`low` / `medium` / `high` / `xhigh` / `max`) — updates live on `/effort`; hidden when the model has no effort parameter |
| `· thinking off` | Shown only when extended thinking is disabled |
| `⚡` | Fast mode is on (hidden otherwise) |
| `▰▰▱▱▱▱▱▱▱▱ 25%` | Context usage bar — **green** &lt; 70 %, **yellow** ≥ 70 %, **red** ≥ 90 % |
| `246.0k/1M · free 754.0k` | Used / total context and remaining tokens; `compact soon` warning at ≥ 85 % |
| `5h 23% · 7d 41%` | Rate limits: 5-hour and 7-day window (claude.ai Pro/Max), plus `spend` behind a gateway spend limit. Same colors as the context bar; from 70 % on with the time until reset, e.g. `5h 92% (1h12m)`. Hidden when Claude Code sends no rate limits |
| `Agents: 2` | Subagents running **right now**, including ones waiting on a long tool call (hidden when zero) |
| `$1.23 · +230/-57 lines · 2h21m runtime` | Session cost, lines added/removed, wall-clock runtime |
| `my-project (main)` | Working directory and git branch |

## Why this one?

- **Resume-safe.** The primary data source is the `context_window` field Claude Code
  (≥ 2.1) passes on stdin — live session state, not transcript guesswork. After
  `claude --resume` the numbers are correct immediately.
- **1M-context aware.** The fallback (older Claude Code versions) detects 1M sessions
  through four independent signals (`[1m]` model suffix, `exceeds_200k_tokens`,
  settings model, usage &gt; 200k) — no more bogus `/200k` after resuming a 1M session.
- **Thinking mode at a glance.** Effort level, extended thinking and fast mode come straight
  from the live session fields `effort.level`, `thinking.enabled` and `fast_mode`. Older Claude
  Code versions without these fields simply show the model name as before.
- **Live subagent counter.** Running agents continuously append to
  `<session>/subagents/agent-*.jsonl`; files written within the last 45 s count as active.
  An agent that is waiting on a long tool call (e.g. a 5-minute build) writes nothing in the
  meantime — it still counts for up to 10 minutes (the maximum Bash timeout) as long as its
  transcript ends in a pending tool call or tool result.
- **Rate limits.** The 5-hour and 7-day usage of your claude.ai plan (and a gateway spend
  limit, if any) come from the live `rate_limits` field, with a reset countdown once they
  get tight.
- **Never crashes.** Every code path is guarded. Worst case, the statusline shows `Claude`
  — never a stack trace, never a blank line, even on malformed or hostile stdin.
- **Fast.** Reads only the last 512 KB of multi-MB transcripts, reads `.git/HEAD` directly
  instead of spawning `git`, strips the UTF-8 BOM some shells prepend.

## How the installer picks a runtime

| Priority | Windows | Linux / WSL / macOS |
|---|---|---|
| 1 | Node.js (fastest) | python3 |
| 2 | Python | Node.js |
| 3 | **PowerShell — always available, zero extra installs** | — |

All three script variants (`src/statusline.js`, `src/statusline.py`, `src/statusline.ps1`)
are feature-identical, down to the rounding behavior.

## Why not a Claude Code plugin?

Plugins cannot register a statusline — `statusLine` is not a plugin-manifest field and can
only be configured in `settings.json`
([official docs](https://code.claude.com/docs/en/statusline)). That's why this project ships
as an installer that merges your settings safely instead.

## Uninstall

Use the same way you installed:

```powershell
# Windows
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/HashfoxGmbH/claude-code-statusline/main/install.ps1))) -Uninstall
```

```bash
# Linux / WSL / macOS
curl -fsSL https://raw.githubusercontent.com/HashfoxGmbH/claude-code-statusline/main/install.sh | bash -s -- --uninstall

# npm
npx @hashfox/claude-code-statusline --uninstall
```

Uninstalling removes the `statusLine` entry — or restores the statusline you had before, if
`settings.json.bak` contains one — and deletes `~/.claude/statusline.{js,py,ps1}`. All other
settings stay as they are. It only touches `settings.json` if this statusline is the one
registered there.

## Development

```text
src/statusline.js    Node variant
src/statusline.py    Python variant
src/statusline.ps1   PowerShell variant (Windows zero-dependency fallback)
build.ps1            regenerates the self-contained install.ps1 / install.sh from src/
                     (pwsh ./build.ps1 - works on Windows, macOS and Linux)
bin/install.js       npx installer
```

Edit **only** the files in `src/`, then run `build.ps1` so the embedded copies inside the
installers stay in sync. Keep all three variants behaviorally identical.

## License

[MIT](LICENSE)
