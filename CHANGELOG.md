# Changelog

## 1.2.0

### Changed
- **npm package renamed to `@hashfox/claude-code-statusline`** (was `@hashox/…`, a typo).
- Context warning is now `compact soon` (was the German `Compact bald!`); all installer
  messages and code comments are in English.

### Added
- **Rate limits:** `5h 23% · 7d 41%` for claude.ai Pro/Max (plus `spend` behind a gateway
  spend limit), colored like the context bar and with a reset countdown from 70 % on.
- **Uninstall** in every installer: `install.ps1 -Uninstall`, `install.sh --uninstall`,
  `npx @hashfox/claude-code-statusline --uninstall`. Removes the entry (or restores the
  statusline you had before) and deletes the scripts; other settings stay untouched.
- `build.ps1` runs on Windows, macOS and Linux (`pwsh ./build.ps1`).

### Fixed
- **Your own `~/.claude/statusline.*` was overwritten:** these are common names for
  hand-written statuslines. The installers overwrote such a file without a backup (and
  skipped the settings backup, since the entry looked like ours); uninstall then deleted it.
  Scripts are now recognized by their content: a foreign file is set aside as
  `statusline.<ext>.bak` and put back on uninstall, together with your previous statusLine.
- **`irm | iex` changed the caller's shell:** `install.ps1` left `$ErrorActionPreference =
  'Stop'` plus its variables and functions in the user's session, failed under
  `Set-StrictMode` (PowerShell-only path) and under `$PSNativeCommandUseErrorActionPreference`.
  It now runs in its own scope. The console encoding is restored even if the smoke test fails.
- Installers read `settings.json` before writing any file, so an invalid `settings.json`
  no longer leaves a stray script behind.
- The three settings-merge implementations now agree on edge cases (case-insensitive path
  match, restoring an empty `statusLine` object).
- `package.json` sets `publishConfig.access = public`, required for the first publish of a
  scoped package.
- **Backup lost on re-install:** every run overwrote `settings.json.bak`, so after a second
  run it no longer contained your original settings. The backup is now only written while
  this statusline is not yet registered.
- **Windows Store Python placeholder:** `install.ps1` took the `python.exe` stub for a real
  Python and failed its smoke test instead of falling back. Installers now verify that
  Node (≥ 12) / Python (≥ 3.6) actually run — also covers the macOS `python3` stub.
- **Spaces in the Windows user name:** Windows PowerShell 5.1 strips double quotes from
  arguments to native programs, so the script path could end up unquoted in
  `settings.json`. The merge now receives it via an environment variable.
- `install.ps1` no longer closes the PowerShell window on an error when run via `irm | iex`.
- `install.ps1` printed the smoke-test output garbled (`Ôöé Ôû░Ôû░…`) because PowerShell decoded
  the script's UTF-8 output with the console's OEM code page. The console is switched to
  UTF-8 for the test and restored afterwards. The statusline itself was not affected.
- **Subagents waiting on a long tool call** (> 45 s, e.g. a build) disappeared from the
  counter. They now stay counted for up to 10 minutes while a tool call is pending.
  This also works when the last transcript entry is larger than 64 KB (e.g. a
  `tool_result` holding a whole file).
- PowerShell variant: the console output encoding is set to UTF-8 *without* BOM, so
  Windows PowerShell 5.1 cannot emit a BOM in front of the statusline.

## 1.1.0

### Added
- Thinking mode next to the model name: reasoning effort (`low` / `medium` / `high` /
  `xhigh` / `max`), `thinking off` when extended thinking is disabled, and `⚡` when fast
  mode is on. Read from the live stdin fields `effort.level`, `thinking.enabled` and
  `fast_mode`; hidden when Claude Code doesn't send them. Implemented identically in the
  Node, Python and PowerShell variants.

### Fixed
- **Python ≤ 3.11:** the Python variant crashed with a `SyntaxError` (backslash inside an
  f-string expression), so on those systems — the default runtime of `install.sh` —
  nothing but an error was shown and the installer's smoke test failed.
- **Umlauts / non-ASCII paths on Windows:** the Python and PowerShell variants decoded stdin
  with the system code page (cp1252 / OEM), garbling folder names like `Übung` and breaking
  the git-branch lookup for them. stdin is now always read as UTF-8.
- **Folder names with `[` `]` (PowerShell):** paths were treated as wildcards, so the git
  branch and running subagents were not found. All path cmdlets now use `-LiteralPath`.
- **Inconsistent rounding between variants:** Python and .NET round halves to even, JS
  doesn't — e.g. `0.5 %` showed `0%` vs `1%`, `1250` tokens `1.2k` vs `1.3k`, `$0.125` as
  `$0.12` vs `$0.13`, and PowerShell showed `103%` at 102.4999…%. All three now round
  identically (verified byte-for-byte on 130+ inputs).
- `999,950` tokens displayed as `1000.0k` instead of `1.0M`.
- Invalid stdin (`null`, `[]`, empty) rendered a half-empty line in PowerShell and JS; all
  variants now fall back to `Claude`.
- `null` token fields in `current_usage` crashed the Python variant down to `Claude`.
- `settings.json` with a UTF-8 BOM was ignored by the 1M-context fallback detection (Node).
- `install.sh` wrote an unquoted script path into `settings.json`, breaking the statusline
  when `$HOME` contains spaces.

## 1.0.0

- Initial release: resume-safe statusline with Node / Python / PowerShell variants.
