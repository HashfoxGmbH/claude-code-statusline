# Changelog

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
