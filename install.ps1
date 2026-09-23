# Claude Code Statusline - installer (Windows)
# Shows model, thinking mode, context usage (%, bar, free), rate limits, running
# subagents, cost, lines and runtime below the input line of every Claude Code session.
#
# Needs nothing extra: uses Node.js or Python if present, otherwise the pure
# PowerShell variant (available on every Windows).
#
# Install:    irm https://raw.githubusercontent.com/HashfoxGmbH/claude-code-statusline/main/install.ps1 | iex
#   or:       powershell -ExecutionPolicy Bypass -File install.ps1
# Uninstall:  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/HashfoxGmbH/claude-code-statusline/main/install.ps1))) -Uninstall
#   or:       powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
param([switch]$Uninstall)
$ErrorActionPreference = 'Stop'
if ($env:CLAUDE_STATUSLINE_UNINSTALL -eq '1') { $Uninstall = $true }

$claudeDir = Join-Path $env:USERPROFILE '.claude'
New-Item -ItemType Directory -Force $claudeDir | Out-Null
# Forward slashes: on Windows Claude Code runs the command via Git Bash or
# PowerShell; a path with / works in both.
$claudeDirFwd = $claudeDir -replace '\\', '/'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Test-StatuslineRuntime([string]$exe, [string[]]$argList) {
    # Does the command exist AND actually run? The Microsoft Store placeholder
    # python.exe (WindowsApps) exists on many machines but only opens the Store.
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { return $false }
    try {
        $null = & $exe @argList 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}
# No double quotes inside these arguments: Windows PowerShell 5.1 strips them.
$node = Test-StatuslineRuntime 'node' @('-e', 'process.exit(parseInt(process.versions.node) >= 12 ? 0 : 1)')
$python = Test-StatuslineRuntime 'python' @('-c', 'import sys; sys.exit(0 if sys.version_info >= (3, 6) else 1)')

$mergeJs = @'
// Merge settings.json. Mode, command and settings path come in via environment
// variables because Windows PowerShell 5.1 strips double quotes from arguments
// passed to node.
// Exit codes: 0 = ok, 1 = error, 3 = uninstall: no statusline of ours registered.
const fs = require('fs'), os = require('os'), path = require('path');
const p = process.env.CLAUDE_STATUSLINE_SETTINGS || path.join(os.homedir(), '.claude', 'settings.json');
const bak = p + '.bak';
const mode = process.env.CLAUDE_STATUSLINE_MODE;
const cmd = process.env.CLAUDE_STATUSLINE_CMD;
const load = (f) => {
  let raw = fs.readFileSync(f, 'utf8');
  if (raw.charCodeAt(0) === 0xFEFF) raw = raw.slice(1);
  return raw.trim() ? JSON.parse(raw) : {};
};
const ours = (s) => !!(s && s.statusLine && typeof s.statusLine === 'object'
  && /[\\/]\.claude[\\/]statusline\.(js|py|ps1)\b/.test(String(s.statusLine.command)));
const save = (s) => fs.writeFileSync(p, JSON.stringify(s, null, 2) + '\n');
let s = {};
if (fs.existsSync(p)) {
  try {
    s = load(p);
    if (!s || typeof s !== 'object' || Array.isArray(s)) throw new Error('not a JSON object');
  } catch (e) { console.error('settings.json is not valid JSON: ' + e.message); process.exit(1); }
}
if (mode === 'uninstall') {
  if (!ours(s)) process.exit(3);
  // Restore a statusLine the user had before installing, taken from the backup
  let prev = null;
  try { const b = load(bak); if (b && b.statusLine && !ours(b)) prev = b.statusLine; } catch (e) { /* no backup */ }
  if (prev) s.statusLine = prev; else delete s.statusLine;
  save(s);
  console.log(prev ? 'Restored your previous statusLine from settings.json.bak.' : 'Removed statusLine from settings.json.');
} else {
  // Back up only a state WITHOUT this statusline: re-running the installer must not
  // overwrite the original backup with already-modified settings.
  if (fs.existsSync(p) && !ours(s)) fs.copyFileSync(p, bak);
  s.statusLine = { type: 'command', command: cmd, padding: 0 };
  save(s);
}
'@
$mergePy = @'
# Merge settings.json. Mode, command and settings path come in via environment variables.
# Exit codes: 0 = ok, 1 = error, 3 = uninstall: no statusline of ours registered.
import json, os, re, shutil, sys
p = os.environ.get('CLAUDE_STATUSLINE_SETTINGS') or os.path.expanduser('~/.claude/settings.json')
bak = p + '.bak'
mode = os.environ.get('CLAUDE_STATUSLINE_MODE')
cmd = os.environ.get('CLAUDE_STATUSLINE_CMD')

def load(f):
    with open(f, encoding='utf-8-sig') as fh:
        raw = fh.read()
    return json.loads(raw) if raw.strip() else {}

def ours(s):
    sl = s.get('statusLine') if isinstance(s, dict) else None
    return isinstance(sl, dict) and re.search(r'[\\/]\.claude[\\/]statusline\.(js|py|ps1)\b', str(sl.get('command'))) is not None

def save(s):
    with open(p, 'w', encoding='utf-8') as f:
        json.dump(s, f, indent=2, ensure_ascii=False)
        f.write('\n')

s = {}
if os.path.exists(p):
    try:
        s = load(p)
        if not isinstance(s, dict):
            raise ValueError('not a JSON object')
    except Exception as e:
        print('settings.json is not valid JSON: %s' % e, file=sys.stderr)
        sys.exit(1)
if mode == 'uninstall':
    if not ours(s):
        sys.exit(3)
    # Restore a statusLine the user had before installing, taken from the backup
    prev = None
    try:
        b = load(bak)
        if isinstance(b, dict) and b.get('statusLine') and not ours(b):
            prev = b['statusLine']
    except Exception:
        pass
    if prev:
        s['statusLine'] = prev
    else:
        s.pop('statusLine', None)
    save(s)
    print('Restored your previous statusLine from settings.json.bak.' if prev else 'Removed statusLine from settings.json.')
else:
    # Back up only a state WITHOUT this statusline: re-running the installer must not
    # overwrite the original backup with already-modified settings.
    if os.path.exists(p) and not ours(s):
        shutil.copy(p, bak)
    s['statusLine'] = {'type': 'command', 'command': cmd, 'padding': 0}
    save(s)
'@

function Test-StatuslineOurs($s) {
    return [bool]($s -and $s.statusLine -and ("$($s.statusLine.command)" -match '[\\/]\.claude[\\/]statusline\.(js|py|ps1)\b'))
}

function Read-StatuslineSettings([string]$path) {
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if (-not $raw -or -not $raw.Trim()) { return New-Object PSObject }
    $obj = $raw | ConvertFrom-Json
    if ($obj -isnot [System.Management.Automation.PSCustomObject]) { throw 'not a JSON object' }
    return $obj
}

function Invoke-StatuslineMergePs([string]$mode, [string]$cmd) {
    # Same logic as the Node/Python merge scripts, for machines without either.
    $settingsPath = Join-Path $claudeDir 'settings.json'
    $bakPath = "$settingsPath.bak"
    $settings = New-Object PSObject
    if (Test-Path -LiteralPath $settingsPath) {
        try { $settings = Read-StatuslineSettings $settingsPath }
        catch { Write-Host "settings.json is not valid JSON: $($_.Exception.Message)"; return 1 }
    }
    if ($mode -eq 'uninstall') {
        if (-not (Test-StatuslineOurs $settings)) { return 3 }
        $prev = $null
        try {
            $b = Read-StatuslineSettings $bakPath
            if ($b.statusLine -and -not (Test-StatuslineOurs $b)) { $prev = $b.statusLine }
        } catch { }
        if ($prev) { $settings | Add-Member NoteProperty statusLine $prev -Force }
        else { $settings.PSObject.Properties.Remove('statusLine') }
        if ($prev) { Write-Host 'Restored your previous statusLine from settings.json.bak.' }
        else { Write-Host 'Removed statusLine from settings.json.' }
    } else {
        # Back up only a state WITHOUT this statusline (see merge scripts).
        if ((Test-Path -LiteralPath $settingsPath) -and -not (Test-StatuslineOurs $settings)) {
            Copy-Item -LiteralPath $settingsPath $bakPath -Force
        }
        $statusLine = New-Object PSObject
        $statusLine | Add-Member NoteProperty type 'command'
        $statusLine | Add-Member NoteProperty command $cmd
        $statusLine | Add-Member NoteProperty padding 0
        $settings | Add-Member NoteProperty statusLine $statusLine -Force
    }
    [System.IO.File]::WriteAllText($settingsPath, (($settings | ConvertTo-Json -Depth 100) + "`n"), $utf8NoBom)
    return 0
}

function Invoke-StatuslineMerge([string]$mode, [string]$cmd) {
    if (-not ($node -or $python)) { return (Invoke-StatuslineMergePs $mode $cmd) }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('claude-statusline-merge-' + [guid]::NewGuid().ToString('N'))
    $mergeFile = $null
    $env:CLAUDE_STATUSLINE_MODE = $mode
    $env:CLAUDE_STATUSLINE_CMD = $cmd
    $env:CLAUDE_STATUSLINE_SETTINGS = Join-Path $claudeDir 'settings.json'
    try {
        if ($node) {
            $mergeFile = "$tmp.js"
            [System.IO.File]::WriteAllText($mergeFile, $mergeJs, $utf8NoBom)
            & node $mergeFile | Write-Host
        } else {
            $mergeFile = "$tmp.py"
            [System.IO.File]::WriteAllText($mergeFile, $mergePy, $utf8NoBom)
            & python $mergeFile | Write-Host
        }
        return $LASTEXITCODE
    } finally {
        Remove-Item Env:CLAUDE_STATUSLINE_MODE, Env:CLAUDE_STATUSLINE_CMD, Env:CLAUDE_STATUSLINE_SETTINGS -ErrorAction SilentlyContinue
        if ($mergeFile) { Remove-Item -LiteralPath $mergeFile -ErrorAction SilentlyContinue }
    }
}

if ($Uninstall) {
    $rc = Invoke-StatuslineMerge 'uninstall' ''
    if ($rc -eq 3) {
        Write-Host 'This statusline is not registered in settings.json - nothing to do.'
        return
    }
    if ($rc -ne 0) { throw 'Could not update settings.json.' }
    foreach ($ext in 'js', 'py', 'ps1') {
        Remove-Item -LiteralPath (Join-Path $claudeDir "statusline.$ext") -ErrorAction SilentlyContinue
    }
    Write-Host 'Statusline uninstalled. Restart running Claude Code sessions to apply.'
    return
}

$statuslineJs = @'
#!/usr/bin/env node
/**
 * Claude Code statusline (Node variant): model + thinking mode, context usage,
 * free tokens, rate limits, running subagents, cost, folder + git branch.
 *
 * The primary source is the stdin field `context_window` (Claude Code v2.1.x+):
 *   - resume-safe (live session state, not guessed from the transcript),
 *   - limit-correct (200k vs. 1M exactly),
 *   - subagent-free (main session context only).
 *
 * Fallback for older versions: the last assistant message of the main chain
 * from the transcript (isSidechain entries are skipped).
 *
 * Behaviorally identical to statusline.py and statusline.ps1.
 */
'use strict';
const fs = require('fs');
const path = require('path');

const RESET = '\x1b[0m';
const DIM = '\x1b[2m';
const GREEN = '\x1b[32m';
const YELLOW = '\x1b[33m';
const RED = '\x1b[31m';
const CYAN = '\x1b[36m';

function fixed(x, digits, unit = 1) {
  // x/unit with `digits` decimals, halves rounded up. Round to an integer first
  // (floor(v + 0.5)), then build the string by hand: Python and .NET formatting
  // round halves to even, so this is what keeps all three variants identical.
  const v = Math.max(0, Math.floor((x * 10 ** digits + unit / 2) / unit));
  const s = String(v).padStart(digits + 1, '0');
  return digits ? s.slice(0, -digits) + '.' + s.slice(-digits) : s;
}

function fmtTokens(n) {
  // Thresholds after rounding: 999950 is "1.0M", not "1000.0k"
  if (n >= 999_950) return fixed(n, 1, 1_000_000) + 'M';
  if (n >= 999.5) return fixed(n, 1, 1000) + 'k';
  return fixed(n, 0);
}

function fmtLimit(n) {
  if (n >= 999_500) return fixed(n, 0, 1_000_000) + 'M';
  if (n >= 999.5) return fixed(n, 0, 1000) + 'k';
  return fixed(n, 0);
}

function readTail(file, maxBytes) {
  // Read only the end of the file - transcripts grow to many MB and the
  // statusline runs every few hundred ms.
  const fd = fs.openSync(file, 'r');
  try {
    const size = fs.fstatSync(fd).size;
    const start = Math.max(0, size - maxBytes);
    const buf = Buffer.alloc(size - start);
    const n = fs.readSync(fd, buf, 0, buf.length, start);
    return buf.toString('utf8', 0, n);
  } finally {
    fs.closeSync(fd);
  }
}

function fromTranscript(data) {
  let used = 0;
  const tpath = data.transcript_path;
  if (tpath && fs.existsSync(tpath)) {
    try {
      const lines = readTail(tpath, 512 * 1024).split('\n');
      for (const line of lines) {
        if (!line.includes('"usage"')) continue;
        let obj;
        try { obj = JSON.parse(line); } catch { continue; }
        if (obj.type !== 'assistant' || obj.isSidechain) continue;
        const u = obj.message && obj.message.usage;
        if (!u) continue;
        used = (u.input_tokens || 0)
          + (u.cache_read_input_tokens || 0)
          + (u.cache_creation_input_tokens || 0);
      }
    } catch { /* the statusline must never crash */ }
  }
  return used;
}

function detectLimit(data, used) {
  // Detect a 1M session when Claude Code sends no context_window (older
  // versions / resume edge cases). Otherwise a resumed 1M session would
  // wrongly show /200k.
  if (used > 200_000) return 1_000_000;
  if (data.exceeds_200k_tokens) return 1_000_000;
  const model = data.model || {};
  const modelStr = `${model.id || ''} ${model.display_name || ''}`;
  if (/\[1m\]/i.test(modelStr)) return 1_000_000;
  try {
    const settingsPath = path.join(require('os').homedir(), '.claude', 'settings.json');
    const rawSettings = fs.readFileSync(settingsPath, 'utf8');
    const settings = JSON.parse(rawSettings.charCodeAt(0) === 0xFEFF ? rawSettings.slice(1) : rawSettings);
    if (typeof settings.model === 'string' && /\[1m\]/i.test(settings.model)) {
      return 1_000_000;
    }
  } catch { /* settings unreadable -> conservatively 200k */ }
  return 200_000;
}

function gitBranch(cwd) {
  // Read .git/HEAD directly instead of spawning git (the statusline runs often)
  try {
    let dir = cwd;
    for (let i = 0; i < 12 && dir; i++) {
      const gitPath = path.join(dir, '.git');
      if (fs.existsSync(gitPath)) {
        let headFile = path.join(gitPath, 'HEAD');
        const stat = fs.statSync(gitPath);
        if (stat.isFile()) { // worktree: .git is a file "gitdir: <path>"
          const gitdir = fs.readFileSync(gitPath, 'utf8').replace(/^gitdir:\s*/, '').trim();
          headFile = path.join(path.isAbsolute(gitdir) ? gitdir : path.join(dir, gitdir), 'HEAD');
        }
        const head = fs.readFileSync(headFile, 'utf8').trim();
        const m = head.match(/^ref: refs\/heads\/(.+)$/);
        return m ? m[1] : head.slice(0, 7);
      }
      const parent = path.dirname(dir);
      if (parent === dir) break;
      dir = parent;
    }
  } catch { /* not a git repo */ }
  return null;
}

function lastMessageWaiting(text) {
  // Last message entry of a subagent transcript: assistant with tool_use =
  // waiting for a tool (e.g. a long build), user with tool_result = the model
  // is working on the next step. Either way nothing is written to the
  // transcript until it finishes, but the agent is still running.
  // Returns null if `text` holds no complete message entry.
  const lines = text.split('\n');
  for (let i = lines.length - 1; i >= 0; i--) {
    if (!lines[i].includes('"type"')) continue;
    let obj;
    try { obj = JSON.parse(lines[i]); } catch { continue; }
    if (!obj || (obj.type !== 'assistant' && obj.type !== 'user')) continue;
    const content = obj.message && obj.message.content;
    if (!Array.isArray(content)) return false;
    const want = obj.type === 'assistant' ? 'tool_use' : 'tool_result';
    return content.some((c) => c && c.type === want);
  }
  return null;
}

function waitingOnTool(file) {
  // The last entry can be large (e.g. a tool_result holding a whole file), so
  // read a bigger tail if the first 64 KB hold no complete message entry.
  for (const bytes of [64 * 1024, 2 * 1024 * 1024]) {
    const state = lastMessageWaiting(readTail(file, bytes));
    if (state !== null) return state;
    if (fs.statSync(file).size <= bytes) break;
  }
  return false;
}

function activeAgents(data) {
  // Running subagents: agent-*.jsonl under <session>/subagents/. Active means
  // written within the last 45s (running agents append constantly), or at
  // most 10 min old and currently waiting on a tool or the next model reply
  // (10 min = the maximum Bash timeout). Resume-safe, because the path is
  // derived directly from transcript_path.
  try {
    const tpath = data.transcript_path;
    if (!tpath) return 0;
    const dir = path.join(tpath.replace(/\.jsonl$/i, ''), 'subagents');
    if (!fs.existsSync(dir)) return 0;
    const now = Date.now();
    let count = 0;
    for (const f of fs.readdirSync(dir)) {
      if (!f.startsWith('agent-') || !f.endsWith('.jsonl')) continue;
      const file = path.join(dir, f);
      const age = now - fs.statSync(file).mtimeMs;
      if (age < 45_000) count++;
      else if (age < 600_000) {
        try { if (waitingOnTool(file)) count++; } catch { /* file gone */ }
      }
    }
    return count;
  } catch {
    return 0;
  }
}

function fmtReset(sec) {
  // Time until a limit resets: 2d4h / 1h05m / 12m
  const min = Math.max(0, Math.floor(sec / 60));
  if (min >= 1440) return Math.floor(min / 1440) + 'd' + Math.floor((min % 1440) / 60) + 'h';
  if (min >= 60) return Math.floor(min / 60) + 'h' + String(min % 60).padStart(2, '0') + 'm';
  return min + 'm';
}

function rateLimits(data) {
  // Rate limits (Pro/Max, or a gateway spend limit): "5h 23% . 7d 41%".
  // From 70 % on with the time until reset. Missing windows are skipped.
  const rl = data.rate_limits;
  if (!rl || typeof rl !== 'object') return '';
  const now = Date.now() / 1000;
  const bits = [];
  for (const [key, label] of [['five_hour', '5h'], ['seven_day', '7d'], ['spend_limit', 'spend']]) {
    const w = rl[key];
    if (!w || typeof w.used_percentage !== 'number' || !Number.isFinite(w.used_percentage)) continue;
    const pct = Math.max(0, w.used_percentage);
    const col = pct >= 90 ? RED : pct >= 70 ? YELLOW : GREEN;
    let bit = `${DIM}${label}${RESET} ${col}${fixed(pct, 0)}%${RESET}`;
    if (pct >= 70 && typeof w.resets_at === 'number' && w.resets_at > now) {
      bit += ` ${DIM}(${fmtReset(w.resets_at - now)})${RESET}`;
    }
    bits.push(bit);
  }
  return bits.join(` ${DIM}\u00B7${RESET} `);
}

function fmtDuration(ms) {
  const min = Math.floor(ms / 60_000);
  if (min < 60) return min + 'm';
  return Math.floor(min / 60) + 'h' + String(min % 60).padStart(2, '0') + 'm';
}

function bar(pct, width) {
  // floor(x+0.5): rounds exactly like the Python and PowerShell variants
  const filled = Math.max(0, Math.min(width, Math.floor((pct / 100) * width + 0.5)));
  return '\u25B0'.repeat(filled) + DIM + '\u25B1'.repeat(width - filled);
}

function main() {
  let data = {};
  try {
    // Strip a BOM - some shells (Windows PowerShell 5.1) pipe one along
    const raw = fs.readFileSync(0, 'utf8');
    data = JSON.parse(raw.charCodeAt(0) === 0xFEFF ? raw.slice(1) : raw);
    if (!data || typeof data !== 'object' || Array.isArray(data)) throw new Error('not a JSON object');
  } catch {
    process.stdout.write('Claude\n');
    return;
  }

  try {
    render(data);
  } catch {
    // Contract: never crash; worst case, show just the name
    process.stdout.write('Claude\n');
  }
}

function modeSuffix(data) {
  // Thinking mode: effort.level (absent for models without an effort
  // parameter), thinking.enabled (only "off" is shown), fast_mode.
  let out = '';
  const effort = data.effort;
  if (effort && typeof effort.level === 'string' && effort.level) {
    out += ` ${DIM}\u00B7${RESET} ${effort.level}`;
  }
  const thinking = data.thinking;
  if (thinking && thinking.enabled === false) out += ` ${DIM}\u00B7 thinking off${RESET}`;
  if (data.fast_mode === true) out += ` ${YELLOW}\u26A1${RESET}`;
  return out;
}

function render(data) {
  const model = data.model || {};
  let name = model.display_name || model.id || 'Claude';
  try { name += modeSuffix(data); } catch (e) { /* name only */ }

  let used, limit, pct;
  const cw = data.context_window || {};
  if (cw.context_window_size) {
    limit = cw.context_window_size;
    used = cw.total_input_tokens;
    if (used == null) {
      const cu = cw.current_usage || {};
      used = (cu.input_tokens || 0)
        + (cu.cache_read_input_tokens || 0)
        + (cu.cache_creation_input_tokens || 0);
    }
    pct = cw.used_percentage != null ? cw.used_percentage : (limit ? used / limit * 100 : 0);
  } else {
    used = fromTranscript(data);
    limit = detectLimit(data, used);
    pct = limit ? used / limit * 100 : 0;
  }
  if (!Number.isFinite(pct)) pct = 0;
  pct = Math.max(0, pct);
  const free = Math.max(0, limit - used);

  const col = pct >= 90 ? RED : pct >= 70 ? YELLOW : GREEN;
  const sep = ` ${DIM}\u2502${RESET} `;

  let ctxSeg = `${col}${fmtTokens(used)}${RESET}${DIM}/${fmtLimit(limit)}${RESET} ${DIM}\u00B7${RESET} free ${GREEN}${fmtTokens(free)}${RESET}`;
  if (pct >= 85) ctxSeg += ` ${RED}compact soon${RESET}`;

  const parts = [
    `${name}`,
    `${col}${bar(pct, 10)}${RESET} ${col}${fixed(pct, 0)}%${RESET}`,
    ctxSeg,
  ];

  const limits = rateLimits(data);
  if (limits) parts.push(limits);

  const agents = activeAgents(data);
  if (agents > 0) {
    parts.push(`${CYAN}Agents: ${agents}${RESET}`);
  }

  const cost = data.cost || {};
  const costBits = [];
  if (cost.total_cost_usd > 0) costBits.push('$' + fixed(cost.total_cost_usd, 2));
  if (cost.total_lines_added || cost.total_lines_removed) {
    costBits.push(`${GREEN}+${cost.total_lines_added || 0}${RESET}${DIM}/${RESET}${RED}-${cost.total_lines_removed || 0}${RESET}${DIM} lines${RESET}`);
  }
  if (cost.total_duration_ms > 60_000) costBits.push(fmtDuration(cost.total_duration_ms) + ' runtime');
  if (costBits.length) parts.push(`${DIM}${costBits.join(' \u00B7 ')}${RESET}`);

  const cwd = (data.workspace && data.workspace.current_dir) || data.cwd;
  if (cwd) {
    let loc = path.basename(cwd);
    const branch = gitBranch(cwd);
    if (branch) loc += ` ${CYAN}(${branch})${RESET}`;
    parts.push(loc);
  }

  process.stdout.write(parts.join(sep) + '\n');
}

main();
'@

$statuslinePy = @'
#!/usr/bin/env python3
"""Claude Code statusline (Python variant): model + thinking mode, context
usage, free tokens, rate limits, running subagents, cost, folder + git branch.

The primary source is the stdin field `context_window` sent by Claude Code
(v2.1.x+). It is:
  - resume-safe (the value comes from the live session state, not the transcript),
  - limit-correct (context_window_size knows 200k vs. 1M exactly),
  - subagent-free (only the main session context is counted).

Fallback (older Claude Code versions without context_window): the last
assistant message of the main chain from the transcript, subagents
(isSidechain == true) skipped.

Behaviorally identical to statusline.js and statusline.ps1.
"""
import sys, json, os, math

RESET, DIM = "\033[0m", "\033[2m"
GREEN, YELLOW, RED, CYAN = "\033[32m", "\033[33m", "\033[31m", "\033[36m"


def fixed(x, digits, unit=1):
    """x/unit with `digits` decimals, halves rounded up.

    Round to an integer first (floor(v + 0.5)), then build the string by hand:
    Python and .NET format rounding sends halves to the even number
    (0.5 -> "0", 1.25 -> "1.2"), JS toFixed does not. This keeps all three
    variants identical."""
    v = max(0, int(math.floor((x * 10 ** digits + unit / 2) / unit)))
    s = str(v).zfill(digits + 1)
    return s[:-digits] + "." + s[-digits:] if digits else s


def fmt_tokens(n):
    # Thresholds after rounding: 999950 is "1.0M", not "1000.0k"
    if n >= 999_950:
        return fixed(n, 1, 1_000_000) + "M"
    if n >= 999.5:
        return fixed(n, 1, 1000) + "k"
    return fixed(n, 0)


def fmt_limit(n):
    if n >= 999_500:
        return fixed(n, 0, 1_000_000) + "M"
    if n >= 999.5:
        return fixed(n, 0, 1000) + "k"
    return fixed(n, 0)


TAIL_BYTES = 512 * 1024  # transcripts grow to many MB; read only the end


def from_transcript(data):
    """Fallback: derive used tokens from the end of the transcript."""
    used = 0
    tpath = data.get("transcript_path")
    if tpath and os.path.exists(tpath):
        try:
            text = read_tail(tpath, TAIL_BYTES)
            for line in text.split("\n"):
                if '"usage"' not in line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                if obj.get("type") != "assistant" or obj.get("isSidechain"):
                    continue
                u = obj.get("message", {}).get("usage")
                if not u:
                    continue
                used = ((u.get("input_tokens") or 0)
                        + (u.get("cache_read_input_tokens") or 0)
                        + (u.get("cache_creation_input_tokens") or 0))
        except Exception:
            pass
    return used


def detect_limit(data, used):
    """Detect a 1M session when context_window is missing (older versions /
    resume edge cases). Otherwise a resumed 1M session would show /200k."""
    if used > 200_000:
        return 1_000_000
    if data.get("exceeds_200k_tokens"):
        return 1_000_000
    model = data.get("model") or {}
    model_str = f"{model.get('id', '')} {model.get('display_name', '')}"
    if "[1m]" in model_str.lower():
        return 1_000_000
    try:
        settings_path = os.path.expanduser("~/.claude/settings.json")
        with open(settings_path, encoding="utf-8-sig") as f:
            settings = json.load(f)
        if "[1m]" in str(settings.get("model", "")).lower():
            return 1_000_000
    except Exception:
        pass
    return 200_000


def git_branch(cwd):
    """Read `.git/HEAD` directly instead of spawning git (the statusline runs often)."""
    try:
        d = cwd
        for _ in range(12):
            git_path = os.path.join(d, ".git")
            if os.path.exists(git_path):
                head_file = os.path.join(git_path, "HEAD")
                if os.path.isfile(git_path):  # worktree: .git is a file
                    with open(git_path, encoding="utf-8") as f:
                        gitdir = f.read().split("gitdir:")[-1].strip()
                    if not os.path.isabs(gitdir):
                        gitdir = os.path.join(d, gitdir)
                    head_file = os.path.join(gitdir, "HEAD")
                with open(head_file, encoding="utf-8") as f:
                    head = f.read().strip()
                if head.startswith("ref: refs/heads/"):
                    return head[len("ref: refs/heads/"):]
                return head[:7]
            parent = os.path.dirname(d)
            if parent == d:
                break
            d = parent
    except Exception:
        pass
    return None


def read_tail(path, max_bytes):
    with open(path, "rb") as f:
        f.seek(0, os.SEEK_END)
        size = f.tell()
        f.seek(max(0, size - max_bytes))
        return f.read().decode("utf-8", errors="replace")


def last_message_waiting(text):
    """Last message entry of a subagent transcript: assistant with tool_use =
    waiting for a tool (e.g. a long build), user with tool_result = the model
    is working on the next step. Either way nothing is written to the
    transcript until it finishes, but the agent is still running.
    Returns None if `text` holds no complete message entry."""
    for line in reversed(text.split("\n")):
        if '"type"' not in line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if not isinstance(obj, dict) or obj.get("type") not in ("assistant", "user"):
            continue
        content = (obj.get("message") or {}).get("content")
        if not isinstance(content, list):
            return False
        want = "tool_use" if obj["type"] == "assistant" else "tool_result"
        return any(isinstance(c, dict) and c.get("type") == want for c in content)
    return None


def waiting_on_tool(path):
    """The last entry can be large (e.g. a tool_result holding a whole file),
    so read a bigger tail if the first 64 KB hold no complete message entry."""
    for size in (64 * 1024, 2 * 1024 * 1024):
        state = last_message_waiting(read_tail(path, size))
        if state is not None:
            return state
        if os.path.getsize(path) <= size:
            break
    return False


def active_agents(data):
    """Running subagents: agent-*.jsonl under <session>/subagents/. Active
    means written within the last 45s (running agents append constantly), or
    at most 10 min old and currently waiting on a tool or the next model reply
    (10 min = the maximum Bash timeout). Resume-safe, because the path is
    derived directly from transcript_path."""
    import time
    try:
        tpath = data.get("transcript_path")
        if not tpath:
            return 0
        base = tpath[:-6] if tpath.lower().endswith(".jsonl") else tpath
        subdir = os.path.join(base, "subagents")
        if not os.path.isdir(subdir):
            return 0
        now = time.time()
        count = 0
        for f in os.listdir(subdir):
            if not (f.startswith("agent-") and f.endswith(".jsonl")):
                continue
            path = os.path.join(subdir, f)
            age = now - os.path.getmtime(path)
            if age < 45:
                count += 1
            elif age < 600:
                try:
                    if waiting_on_tool(path):
                        count += 1
                except Exception:
                    pass
        return count
    except Exception:
        return 0


def fmt_reset(sec):
    """Time until a limit resets: 2d4h / 1h05m / 12m"""
    minutes = max(0, int(sec // 60))
    if minutes >= 1440:
        return f"{minutes // 1440}d{(minutes % 1440) // 60}h"
    if minutes >= 60:
        return f"{minutes // 60}h{minutes % 60:02d}m"
    return f"{minutes}m"


def is_num(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool) and x == x and abs(x) != float("inf")


def rate_limits(data):
    """Rate limits (Pro/Max, or a gateway spend limit): "5h 23% . 7d 41%".
    From 70 % on with the time until reset. Missing windows are skipped."""
    import time
    rl = data.get("rate_limits")
    if not isinstance(rl, dict):
        return ""
    now = time.time()
    bits = []
    for key, label in (("five_hour", "5h"), ("seven_day", "7d"), ("spend_limit", "spend")):
        w = rl.get(key)
        if not isinstance(w, dict) or not is_num(w.get("used_percentage")):
            continue
        pct = max(0, w["used_percentage"])
        col = RED if pct >= 90 else YELLOW if pct >= 70 else GREEN
        bit = f"{DIM}{label}{RESET} {col}{fixed(pct, 0)}%{RESET}"
        reset = w.get("resets_at")
        if pct >= 70 and is_num(reset) and reset > now:
            bit += f" {DIM}({fmt_reset(reset - now)}){RESET}"
        bits.append(bit)
    return f" {DIM}\u00b7{RESET} ".join(bits)


def fmt_duration(ms):
    minutes = int(ms // 60_000)
    if minutes < 60:
        return f"{minutes}m"
    return f"{minutes // 60}h{minutes % 60:02d}m"


def bar(pct, width=10):
    # floor(x+0.5) instead of round(): rounds exactly like the JS variant
    # (Python rounds halves to even, JS does not)
    filled = max(0, min(width, int(pct / 100 * width + 0.5)))
    return "\u25b0" * filled + DIM + "\u25b1" * (width - filled)


def main():
    try:
        # otherwise Windows Python uses cp1252 and crashes on the bar characters
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    try:
        # Read bytes and decode as UTF-8 ourselves: otherwise Windows Python
        # uses cp1252 for stdin and garbles non-ASCII paths (folder name, git).
        # utf-8-sig also strips a BOM that some shells pipe along.
        data = json.loads(sys.stdin.buffer.read().decode("utf-8-sig"))
        if not isinstance(data, dict):
            raise ValueError("not a JSON object")
    except Exception:
        print("Claude")
        return

    try:
        render(data)
    except Exception:
        # Contract: never crash; worst case, show just the name
        print("Claude")


def mode_suffix(data):
    # Thinking mode: effort.level (absent for models without an effort
    # parameter), thinking.enabled (only "off" is shown), fast_mode.
    out = ""
    effort = data.get("effort")
    if isinstance(effort, dict) and isinstance(effort.get("level"), str) and effort["level"]:
        out += f" {DIM}\u00b7{RESET} {effort['level']}"
    thinking = data.get("thinking")
    if isinstance(thinking, dict) and thinking.get("enabled") is False:
        out += f" {DIM}\u00b7 thinking off{RESET}"
    if data.get("fast_mode") is True:
        out += f" {YELLOW}\u26a1{RESET}"
    return out


def render(data):
    model = data.get("model") or {}
    name = model.get("display_name") or model.get("id") or "Claude"
    try:
        name += mode_suffix(data)
    except Exception:
        pass

    cw = data.get("context_window") or {}
    size = cw.get("context_window_size")
    if size:
        used = cw.get("total_input_tokens")
        if used is None:
            cu = cw.get("current_usage") or {}
            used = ((cu.get("input_tokens") or 0)
                    + (cu.get("cache_read_input_tokens") or 0)
                    + (cu.get("cache_creation_input_tokens") or 0))
        limit = size
        pct = cw.get("used_percentage")
        if pct is None:
            pct = (used / limit * 100) if limit else 0
    else:
        used = from_transcript(data)
        limit = detect_limit(data, used)
        pct = (used / limit * 100) if limit else 0
    if not isinstance(pct, (int, float)) or pct != pct:  # NaN guard
        pct = 0
    pct = max(0, pct)
    free = max(0, limit - used)

    col = RED if pct >= 90 else YELLOW if pct >= 70 else GREEN
    sep = f" {DIM}\u2502{RESET} "

    ctx_seg = (f"{col}{fmt_tokens(used)}{RESET}{DIM}/{fmt_limit(limit)}{RESET} "
               f"{DIM}\u00b7{RESET} free {GREEN}{fmt_tokens(free)}{RESET}")
    if pct >= 85:
        ctx_seg += f" {RED}compact soon{RESET}"

    parts = [
        name,
        f"{col}{bar(pct)}{RESET} {col}{fixed(pct, 0)}%{RESET}",
        ctx_seg,
    ]

    limits = rate_limits(data)
    if limits:
        parts.append(limits)

    agents = active_agents(data)
    if agents > 0:
        parts.append(f"{CYAN}Agents: {agents}{RESET}")

    cost = data.get("cost") or {}
    cost_bits = []
    if (cost.get("total_cost_usd") or 0) > 0:
        cost_bits.append("$" + fixed(cost["total_cost_usd"], 2))
    added = cost.get("total_lines_added") or 0
    removed = cost.get("total_lines_removed") or 0
    if added or removed:
        cost_bits.append(f"{GREEN}+{added}{RESET}{DIM}/{RESET}{RED}-{removed}{RESET}{DIM} lines{RESET}")
    if (cost.get("total_duration_ms") or 0) > 60_000:
        cost_bits.append(fmt_duration(cost["total_duration_ms"]) + " runtime")
    if cost_bits:
        # join outside the f-string: a backslash in the expression needs Python 3.12+
        joined = " \u00b7 ".join(cost_bits)
        parts.append(f"{DIM}{joined}{RESET}")

    cwd = (data.get("workspace") or {}).get("current_dir") or data.get("cwd")
    if cwd:
        loc = os.path.basename(cwd)
        branch = git_branch(cwd)
        if branch:
            loc += f" {CYAN}({branch}){RESET}"
        parts.append(loc)

    print(sep.join(parts))


if __name__ == "__main__":
    main()
'@

$statuslinePs = @'
# Claude Code statusline (PowerShell) - zero-dependency variant for Windows.
# Behaviorally identical to statusline.js (Node) and statusline.py (Python):
# model + thinking mode, context bar/%, used/limit, free, rate limits, running
# subagents, cost, lines, runtime, folder + git branch. Contract: never crash.
$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

$E = [char]27
$RESET = "$E[0m"; $DIM = "$E[2m"; $GREEN = "$E[32m"
$YELLOW = "$E[33m"; $RED = "$E[31m"; $CYAN = "$E[36m"

function Format-Fixed([double]$x, [int]$digits, [double]$unit = 1) {
    # x/unit with $digits decimals, halves rounded up. Round to an integer
    # first (floor(v + 0.5)), then build the string by hand: .NET formats round
    # halves to even ('F') or after 15 digits ('0'); this keeps all three
    # variants identical.
    $v = [math]::Floor(($x * [math]::Pow(10, $digits) + $unit / 2) / $unit)
    if ($v -lt 0) { $v = 0 }
    $s = $v.ToString('F0', $inv).PadLeft($digits + 1, '0')
    if ($digits -gt 0) { return $s.Substring(0, $s.Length - $digits) + '.' + $s.Substring($s.Length - $digits) }
    return $s
}

function Format-Tokens([double]$n) {
    # Thresholds after rounding: 999950 is "1.0M", not "1000.0k"
    if ($n -ge 999950) { return (Format-Fixed $n 1 1000000) + 'M' }
    if ($n -ge 999.5) { return (Format-Fixed $n 1 1000) + 'k' }
    return Format-Fixed $n 0
}

function Format-Limit([double]$n) {
    if ($n -ge 999500) { return (Format-Fixed $n 0 1000000) + 'M' }
    if ($n -ge 999.5) { return (Format-Fixed $n 0 1000) + 'k' }
    return Format-Fixed $n 0
}

function Format-Duration([double]$ms) {
    $min = [math]::Floor($ms / 60000)
    if ($min -lt 60) { return "${min}m" }
    return ('{0}h{1:00}m' -f [math]::Floor($min / 60), ($min % 60))
}

function Get-Bar([double]$pct, [int]$width) {
    # floor(x+0.5): rounds exactly like the JS and Python variants
    $filled = [int][math]::Floor($pct / 100 * $width + 0.5)
    if ($filled -lt 0) { $filled = 0 }
    if ($filled -gt $width) { $filled = $width }
    return (([string][char]0x25B0) * $filled) + $DIM + (([string][char]0x25B1) * ($width - $filled))
}

function Read-Tail([string]$path, [int]$maxBytes) {
    $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try {
        if ($fs.Length -gt $maxBytes) { $null = $fs.Seek(-$maxBytes, 'End') }
        $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        return $reader.ReadToEnd()
    } finally { $fs.Close() }
}

function Test-Number($x) {
    if (-not ($x -is [int] -or $x -is [long] -or $x -is [double] -or $x -is [decimal])) { return $false }
    return -not ([double]::IsNaN([double]$x) -or [double]::IsInfinity([double]$x))
}

function Get-TranscriptUsed($data) {
    # Fallback: derive used tokens from the end of the transcript (last 512 KB).
    $used = 0
    $tpath = $data.transcript_path
    if (-not $tpath -or -not (Test-Path -LiteralPath $tpath)) { return 0 }
    try {
        $text = Read-Tail $tpath 524288
        foreach ($line in $text -split "`n") {
            if ($line -notmatch '"usage"') { continue }
            try { $obj = $line | ConvertFrom-Json } catch { continue }
            if ($obj.type -ne 'assistant' -or $obj.isSidechain) { continue }
            $u = $obj.message.usage
            if (-not $u) { continue }
            $used = [double]($u.input_tokens + $u.cache_read_input_tokens + $u.cache_creation_input_tokens)
        }
    } catch { }
    return $used
}

function Get-Limit($data, [double]$used) {
    # Detect a 1M session when context_window is missing (older versions /
    # resume edge cases) - otherwise a resumed 1M session would show /200k.
    if ($used -gt 200000) { return 1000000 }
    if ($data.exceeds_200k_tokens) { return 1000000 }
    $modelStr = "$($data.model.id) $($data.model.display_name)"
    if ($modelStr -match '\[1m\]') { return 1000000 }
    try {
        $settings = Get-Content -LiteralPath (Join-Path $env:USERPROFILE '.claude\settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ("$($settings.model)" -match '\[1m\]') { return 1000000 }
    } catch { }
    return 200000
}

function Get-GitBranch([string]$cwd) {
    # Read .git/HEAD directly instead of spawning git (the statusline runs often)
    try {
        $dir = $cwd
        for ($i = 0; $i -lt 12 -and $dir; $i++) {
            $gitPath = Join-Path $dir '.git'
            if (Test-Path -LiteralPath $gitPath) {
                $headFile = Join-Path $gitPath 'HEAD'
                if (Test-Path -LiteralPath $gitPath -PathType Leaf) {
                    $gitdir = ((Get-Content -LiteralPath $gitPath -Raw) -replace '^gitdir:\s*', '').Trim()
                    if (-not [System.IO.Path]::IsPathRooted($gitdir)) { $gitdir = Join-Path $dir $gitdir }
                    $headFile = Join-Path $gitdir 'HEAD'
                }
                $head = (Get-Content -LiteralPath $headFile -Raw).Trim()
                if ($head -match '^ref: refs/heads/(.+)$') { return $Matches[1] }
                return $head.Substring(0, [math]::Min(7, $head.Length))
            }
            $parent = Split-Path $dir -Parent
            if ($parent -eq $dir -or -not $parent) { break }
            $dir = $parent
        }
    } catch { }
    return $null
}

function Get-LastMessageWaiting([string]$text) {
    # Last message entry of a subagent transcript: assistant with tool_use =
    # waiting for a tool (e.g. a long build), user with tool_result = the model
    # is working on the next step. Either way nothing is written to the
    # transcript until it finishes, but the agent is still running.
    # Returns $null if $text holds no complete message entry.
    $lines = $text -split "`n"
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -notmatch '"type"') { continue }
        try { $obj = $lines[$i] | ConvertFrom-Json } catch { continue }
        if ($obj.type -ne 'assistant' -and $obj.type -ne 'user') { continue }
        $content = $obj.message.content
        if ($null -eq $content -or $content -is [string]) { return $false }
        $want = if ($obj.type -eq 'assistant') { 'tool_use' } else { 'tool_result' }
        foreach ($c in @($content)) { if ($c.type -eq $want) { return $true } }
        return $false
    }
    return $null
}

function Test-WaitingOnTool([string]$path) {
    # The last entry can be large (e.g. a tool_result holding a whole file), so
    # read a bigger tail if the first 64 KB hold no complete message entry.
    foreach ($bytes in 65536, 2097152) {
        $state = Get-LastMessageWaiting (Read-Tail $path $bytes)
        if ($null -ne $state) { return $state }
        if ((New-Object System.IO.FileInfo($path)).Length -le $bytes) { break }
    }
    return $false
}

function Get-ActiveAgents($data) {
    # Running subagents: agent-*.jsonl under <session>/subagents/. Active means
    # written within the last 45s (running agents append constantly), or at
    # most 10 min old and currently waiting on a tool or the next model reply
    # (10 min = the maximum Bash timeout).
    try {
        $tpath = $data.transcript_path
        if (-not $tpath) { return 0 }
        $dir = Join-Path ($tpath -replace '\.jsonl$', '') 'subagents'
        if (-not (Test-Path -LiteralPath $dir)) { return 0 }
        $now = [DateTime]::UtcNow
        $count = 0
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'agent-*.jsonl')) {
            if (-not $f.Name.EndsWith('.jsonl')) { continue }
            $age = ($now - $f.LastWriteTimeUtc).TotalSeconds
            if ($age -lt 45) { $count++ }
            elseif ($age -lt 600) {
                try { if (Test-WaitingOnTool $f.FullName) { $count++ } } catch { }
            }
        }
        return $count
    } catch { return 0 }
}

function Format-Reset([double]$sec) {
    # Time until a limit resets: 2d4h / 1h05m / 12m
    $min = [math]::Floor($sec / 60)
    if ($min -lt 0) { $min = 0 }
    if ($min -ge 1440) { return ('{0}d{1}h' -f [math]::Floor($min / 1440), [math]::Floor(($min % 1440) / 60)) }
    if ($min -ge 60) { return ('{0}h{1:00}m' -f [math]::Floor($min / 60), ($min % 60)) }
    return "${min}m"
}

function Get-RateLimits($data) {
    # Rate limits (Pro/Max, or a gateway spend limit): "5h 23% . 7d 41%".
    # From 70 % on with the time until reset. Missing windows are skipped.
    $rl = $data.rate_limits
    if ($rl -isnot [System.Management.Automation.PSCustomObject]) { return '' }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000
    $bits = @()
    foreach ($pair in @(@('five_hour', '5h'), @('seven_day', '7d'), @('spend_limit', 'spend'))) {
        $w = $rl.($pair[0])
        if ($w -isnot [System.Management.Automation.PSCustomObject] -or -not (Test-Number $w.used_percentage)) { continue }
        $pct = [double]$w.used_percentage
        if ($pct -lt 0) { $pct = 0 }
        $col = if ($pct -ge 90) { $RED } elseif ($pct -ge 70) { $YELLOW } else { $GREEN }
        $bit = "$DIM$($pair[1])$RESET $col$(Format-Fixed $pct 0)%$RESET"
        if ($pct -ge 70 -and (Test-Number $w.resets_at) -and [double]$w.resets_at -gt $now) {
            $bit += " $DIM($(Format-Reset ([double]$w.resets_at - $now)))$RESET"
        }
        $bits += $bit
    }
    return ($bits -join " $DIM$([char]0xB7)$RESET ")
}

try {
    # UTF-8 without BOM: [Text.Encoding]::UTF8 carries a BOM preamble that
    # Windows PowerShell 5.1 can emit in front of the statusline.
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
    # stdin is UTF-8; without this Windows reads it with the OEM code page and
    # garbles non-ASCII paths (folder name, git lookup).
    try { [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
    $raw = [Console]::In.ReadToEnd()
    $raw = $raw.TrimStart([char]0xFEFF)
    $data = $raw | ConvertFrom-Json
    if ($data -isnot [System.Management.Automation.PSCustomObject]) { throw 'not a JSON object' }

    $name = if ($data.model.display_name) { $data.model.display_name }
            elseif ($data.model.id) { $data.model.id } else { 'Claude' }
    # Thinking mode: effort.level (absent for models without an effort
    # parameter), thinking.enabled (only "off" is shown), fast_mode.
    try {
        if ($data.effort -and $data.effort.level -is [string] -and $data.effort.level) {
            $name = "$name $DIM$([char]0xB7)$RESET $($data.effort.level)"
        }
        if ($data.thinking -and $data.thinking.enabled -is [bool] -and -not $data.thinking.enabled) {
            $name += " $DIM$([char]0xB7) thinking off$RESET"
        }
        if ($data.fast_mode -is [bool] -and $data.fast_mode) { $name += " $YELLOW$([char]0x26A1)$RESET" }
    } catch { }

    $cw = $data.context_window
    if ($cw -and $cw.context_window_size) {
        $limit = [double]$cw.context_window_size
        if ($null -ne $cw.total_input_tokens) {
            $used = [double]$cw.total_input_tokens
        } else {
            $cu = $cw.current_usage
            $used = [double]($cu.input_tokens + $cu.cache_read_input_tokens + $cu.cache_creation_input_tokens)
        }
        $pct = if ($null -ne $cw.used_percentage) { [double]$cw.used_percentage }
               elseif ($limit) { $used / $limit * 100 } else { 0 }
    } else {
        $used = Get-TranscriptUsed $data
        $limit = Get-Limit $data $used
        $pct = if ($limit) { $used / $limit * 100 } else { 0 }
    }
    # No [math]::Max(0, $x): PS picks the Int32 overload there and ROUNDS
    if ([double]::IsNaN($pct) -or [double]::IsInfinity($pct) -or $pct -lt 0) { $pct = 0 }
    $free = $limit - $used
    if ($free -lt 0) { $free = 0 }

    $col = if ($pct -ge 90) { $RED } elseif ($pct -ge 70) { $YELLOW } else { $GREEN }
    $sep = " $DIM$([char]0x2502)$RESET "

    $ctxSeg = "$col$(Format-Tokens $used)$RESET$DIM/$(Format-Limit $limit)$RESET $DIM$([char]0xB7)$RESET free $GREEN$(Format-Tokens $free)$RESET"
    if ($pct -ge 85) { $ctxSeg += " ${RED}compact soon$RESET" }

    $pctText = Format-Fixed $pct 0
    $parts = @(
        $name,
        "$col$(Get-Bar $pct 10)$RESET $col$pctText%$RESET",
        $ctxSeg
    )

    $limits = Get-RateLimits $data
    if ($limits) { $parts += $limits }

    $agents = Get-ActiveAgents $data
    if ($agents -gt 0) { $parts += "${CYAN}Agents: $agents$RESET" }

    $cost = $data.cost
    $costBits = @()
    if ($cost.total_cost_usd -gt 0) { $costBits += ('$' + (Format-Fixed $cost.total_cost_usd 2)) }
    if ($cost.total_lines_added -or $cost.total_lines_removed) {
        $costBits += "$GREEN+$([int]$cost.total_lines_added)$RESET$DIM/$RESET$RED-$([int]$cost.total_lines_removed)$RESET$DIM lines$RESET"
    }
    if ($cost.total_duration_ms -gt 60000) { $costBits += "$(Format-Duration $cost.total_duration_ms) runtime" }
    if ($costBits.Count) { $parts += "$DIM$($costBits -join (' ' + [char]0xB7 + ' '))$RESET" }

    $cwd = if ($data.workspace.current_dir) { $data.workspace.current_dir } else { $data.cwd }
    if ($cwd) {
        $loc = Split-Path $cwd -Leaf
        $branch = Get-GitBranch $cwd
        if ($branch) { $loc += " $CYAN($branch)$RESET" }
        $parts += $loc
    }

    Write-Output ($parts -join $sep)
} catch {
    # Contract: never crash; worst case, show just the name
    Write-Output 'Claude'
}
'@

if ($node) {
    $scriptPath = Join-Path $claudeDir 'statusline.js'
    [System.IO.File]::WriteAllText($scriptPath, $statuslineJs, $utf8NoBom)
    $cmd = 'node "' + $claudeDirFwd + '/statusline.js"'
    $runtime = 'Node.js'
} elseif ($python) {
    $scriptPath = Join-Path $claudeDir 'statusline.py'
    [System.IO.File]::WriteAllText($scriptPath, $statuslinePy, $utf8NoBom)
    $cmd = 'python "' + $claudeDirFwd + '/statusline.py"'
    $runtime = 'Python'
} else {
    # Zero-dependency fallback: PowerShell exists on every Windows.
    # All scripts are ASCII-only, so no BOM is needed.
    $scriptPath = Join-Path $claudeDir 'statusline.ps1'
    [System.IO.File]::WriteAllText($scriptPath, $statuslinePs, $utf8NoBom)
    $cmd = 'powershell -NoProfile -ExecutionPolicy Bypass -File "' + $claudeDirFwd + '/statusline.ps1"'
    $runtime = 'PowerShell'
}

$settingsPath = Join-Path $claudeDir 'settings.json'
if ((Invoke-StatuslineMerge 'install' $cmd) -ne 0) { throw 'Could not update settings.json.' }

# Smoke test
$samplePath = Join-Path ([System.IO.Path]::GetTempPath()) 'claude-statusline-sample.json'
[System.IO.File]::WriteAllText($samplePath, '{"model":{"display_name":"Test"},"context_window":{"context_window_size":200000,"total_input_tokens":50000}}', $utf8NoBom)
# The statusline writes UTF-8 (that is what Claude Code reads). PowerShell decodes
# native output with [Console]::OutputEncoding - the OEM code page by default, which
# garbles the bar characters here. Switch to UTF-8 for the test and its output and
# restore it afterwards, since "irm | iex" runs inside the user's own shell.
$prevOutputEncoding = $null
try { $prevOutputEncoding = [Console]::OutputEncoding; [Console]::OutputEncoding = $utf8NoBom } catch { }
try {
    if ($node) { $out = Get-Content -LiteralPath $samplePath -Raw | & node $scriptPath }
    elseif ($python) { $out = Get-Content -LiteralPath $samplePath -Raw | & python $scriptPath }
    else { $out = Get-Content -LiteralPath $samplePath -Raw | & powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath }
} finally {
    Remove-Item -LiteralPath $samplePath -ErrorAction SilentlyContinue
}
try {
    if (-not $out) { throw 'Smoke test failed: no output.' }
    Write-Host ''
    Write-Host "Statusline installed ($runtime): $scriptPath"
    Write-Host "settings.json updated: $settingsPath (backup: settings.json.bak)"
    Write-Host "Test output:  $out"
    Write-Host 'Done. New Claude Code sessions show the statusline; running sessions after a restart.'
} finally {
    if ($prevOutputEncoding) { try { [Console]::OutputEncoding = $prevOutputEncoding } catch { } }
}