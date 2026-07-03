# Claude Code Statusline - Installer (Windows)
# Zeigt Modell, Context-Verbrauch (%, Balken, free), laufende Subagenten,
# Kosten, Zeilen und Laufzeit unter der Eingabezeile jeder Claude-Code-Session.
#
# Laeuft ohne Zusatzinstallation: nutzt Node.js oder Python falls vorhanden,
# sonst die reine PowerShell-Variante (auf jedem Windows verfuegbar).
#
# Nutzung:  powershell -ExecutionPolicy Bypass -File install.ps1
#   oder:   irm <RAW-URL>/install.ps1 | iex
$ErrorActionPreference = 'Stop'

$claudeDir = Join-Path $env:USERPROFILE '.claude'
New-Item -ItemType Directory -Force $claudeDir | Out-Null
# Forward-Slashes: Claude Code fuehrt den Befehl unter Windows via Git Bash
# oder PowerShell aus; mit / funktioniert der Pfad in beiden.
$claudeDirFwd = $claudeDir -replace '\\', '/'

$node = Get-Command node -ErrorAction SilentlyContinue
$python = Get-Command python -ErrorAction SilentlyContinue

$statuslineJs = @'
#!/usr/bin/env node
/**
 * Claude Code Statusline (Windows): Modell + Context-Verbrauch + freie Tokens.
 *
 * Primaerquelle ist das stdin-Feld `context_window` (Claude Code v2.1.x+):
 *   - resume-fest (Live-Session-State, nicht Transcript-Raten),
 *   - limit-korrekt (200k vs. 1M exakt),
 *   - subagenten-frei (nur Haupt-Session-Context).
 *
 * Fallback fuer aeltere Versionen: letzte Assistant-Nachricht der Hauptkette
 * aus dem Transcript (isSidechain wird uebersprungen).
 *
 * Gegenstueck zu ~/.claude/statusline.py in WSL Ubuntu.
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

function fmtTokens(n) {
  if (n >= 1_000_000) return (n / 1_000_000).toFixed(1) + 'M';
  if (n >= 1000) return (n / 1000).toFixed(1) + 'k';
  return String(Math.round(n));
}

function fmtLimit(n) {
  if (n >= 1_000_000) return Math.round(n / 1_000_000) + 'M';
  if (n >= 1000) return Math.round(n / 1000) + 'k';
  return String(Math.round(n));
}

function readTail(file, maxBytes) {
  // Nur das Dateiende lesen — Transcripts werden viele MB gross,
  // die Statusline laeuft alle paar hundert ms.
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
    } catch { /* Statusline darf nie crashen */ }
  }
  return used;
}

function detectLimit(data, used) {
  // 1M-Session erkennen, wenn Claude Code kein context_window liefert
  // (aeltere Versionen / Resume-Edge-Cases). Sonst wuerde eine resumte
  // 1M-Session faelschlich als /200k angezeigt.
  if (used > 200_000) return 1_000_000;
  if (data.exceeds_200k_tokens) return 1_000_000;
  const model = data.model || {};
  const modelStr = `${model.id || ''} ${model.display_name || ''}`;
  if (/\[1m\]/i.test(modelStr)) return 1_000_000;
  try {
    const settingsPath = path.join(require('os').homedir(), '.claude', 'settings.json');
    const settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
    if (typeof settings.model === 'string' && /\[1m\]/i.test(settings.model)) {
      return 1_000_000;
    }
  } catch { /* Settings nicht lesbar -> konservativ 200k */ }
  return 200_000;
}

function gitBranch(cwd) {
  // .git/HEAD direkt lesen statt git zu spawnen (Statusline laeuft oft)
  try {
    let dir = cwd;
    for (let i = 0; i < 12 && dir; i++) {
      const gitPath = path.join(dir, '.git');
      if (fs.existsSync(gitPath)) {
        let headFile = path.join(gitPath, 'HEAD');
        const stat = fs.statSync(gitPath);
        if (stat.isFile()) { // Worktree: .git ist Datei "gitdir: <pfad>"
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
  } catch { /* kein Git-Repo */ }
  return null;
}

function activeAgents(data) {
  // Laufende Subagenten: agent-*.jsonl unter <session>/subagents/, das in den
  // letzten 45s beschrieben wurde. Laufende Agenten appenden staendig an ihr
  // Transcript; fertige Dateien veralten sofort. Resume-fest, da der Pfad
  // direkt aus transcript_path abgeleitet wird.
  try {
    const tpath = data.transcript_path;
    if (!tpath) return 0;
    const dir = path.join(tpath.replace(/\.jsonl$/i, ''), 'subagents');
    if (!fs.existsSync(dir)) return 0;
    const now = Date.now();
    let count = 0;
    for (const f of fs.readdirSync(dir)) {
      if (!f.startsWith('agent-') || !f.endsWith('.jsonl')) continue;
      const mtime = fs.statSync(path.join(dir, f)).mtimeMs;
      if (now - mtime < 45_000) count++;
    }
    return count;
  } catch {
    return 0;
  }
}

function fmtDuration(ms) {
  const min = Math.floor(ms / 60_000);
  if (min < 60) return min + 'm';
  return Math.floor(min / 60) + 'h' + String(min % 60).padStart(2, '0') + 'm';
}

function bar(pct, width) {
  // floor(x+0.5) statt Math.round: identisches Runden wie die Python-Variante
  const filled = Math.max(0, Math.min(width, Math.floor((pct / 100) * width + 0.5)));
  return '▰'.repeat(filled) + DIM + '▱'.repeat(width - filled);
}

function main() {
  let data = {};
  try {
    // BOM strippen — manche Shells (Windows PowerShell 5.1) pipen mit
    const raw = fs.readFileSync(0, 'utf8');
    data = JSON.parse(raw.charCodeAt(0) === 0xFEFF ? raw.slice(1) : raw);
  } catch {
    process.stdout.write('Claude\n');
    return;
  }

  try {
    render(data);
  } catch {
    // Kontrakt: niemals crashen, schlimmstenfalls nur der Name
    process.stdout.write('Claude\n');
  }
}

function render(data) {
  const model = data.model || {};
  const name = model.display_name || model.id || 'Claude';

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
  const sep = ` ${DIM}│${RESET} `;

  let ctxSeg = `${col}${fmtTokens(used)}${RESET}${DIM}/${fmtLimit(limit)}${RESET} ${DIM}·${RESET} free ${GREEN}${fmtTokens(free)}${RESET}`;
  if (pct >= 85) ctxSeg += ` ${RED}Compact bald!${RESET}`;

  const parts = [
    `${name}`,
    `${col}${bar(pct, 10)}${RESET} ${col}${pct.toFixed(0)}%${RESET}`,
    ctxSeg,
  ];

  const agents = activeAgents(data);
  if (agents > 0) {
    parts.push(`${CYAN}Agents: ${agents}${RESET}`);
  }

  const cost = data.cost || {};
  const costBits = [];
  if (cost.total_cost_usd > 0) costBits.push('$' + cost.total_cost_usd.toFixed(2));
  if (cost.total_lines_added || cost.total_lines_removed) {
    costBits.push(`${GREEN}+${cost.total_lines_added || 0}${RESET}${DIM}/${RESET}${RED}-${cost.total_lines_removed || 0}${RESET}${DIM} lines${RESET}`);
  }
  if (cost.total_duration_ms > 60_000) costBits.push(fmtDuration(cost.total_duration_ms) + ' runtime');
  if (costBits.length) parts.push(`${DIM}${costBits.join(' · ')}${RESET}`);

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
"""Claude Code statusline: Modell + Context-Verbrauch + freie Tokens.

Primaerquelle ist das von Claude Code gelieferte stdin-Feld `context_window`
(ab v2.1.x). Das ist:
  - resume-fest (Wert kommt aus dem Live-Session-State, nicht aus dem Transcript),
  - limit-korrekt (context_window_size kennt 200k vs. 1M exakt),
  - subagenten-frei (nur der Haupt-Session-Context wird gezaehlt).

Fallback (aeltere Claude-Code-Versionen ohne context_window): letzte
Assistant-Nachricht der Hauptkette aus dem Transcript, Subagenten
(isSidechain == true) uebersprungen.

Gegenstueck zu %USERPROFILE%\\.claude\\statusline.js auf der Windows-Seite.
"""
import sys, json, os

RESET, DIM = "\033[0m", "\033[2m"
GREEN, YELLOW, RED, CYAN = "\033[32m", "\033[33m", "\033[31m", "\033[36m"


def fmt_tokens(n):
    if n >= 1_000_000:
        return f"{n/1_000_000:.1f}M"
    if n >= 1000:
        return f"{n/1000:.1f}k"
    return str(int(n))


def fmt_limit(n):
    if n >= 1_000_000:
        return f"{n/1_000_000:.0f}M"
    if n >= 1000:
        return f"{n/1000:.0f}k"
    return str(int(n))


TAIL_BYTES = 512 * 1024  # Transcripts werden viele MB gross; nur Ende lesen


def from_transcript(data):
    """Fallback: used_tokens aus dem Transcript-Ende ableiten."""
    used = 0
    tpath = data.get("transcript_path")
    if tpath and os.path.exists(tpath):
        try:
            with open(tpath, "rb") as f:
                f.seek(0, os.SEEK_END)
                size = f.tell()
                f.seek(max(0, size - TAIL_BYTES))
                text = f.read().decode("utf-8", errors="replace")
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
                used = (u.get("input_tokens", 0)
                        + u.get("cache_read_input_tokens", 0)
                        + u.get("cache_creation_input_tokens", 0))
        except Exception:
            pass
    return used


def detect_limit(data, used):
    """1M-Session erkennen, wenn context_window fehlt (aeltere Versionen /
    Resume-Edge-Cases). Sonst wuerde eine resumte 1M-Session als /200k
    angezeigt werden."""
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
        with open(settings_path) as f:
            settings = json.load(f)
        if "[1m]" in str(settings.get("model", "")).lower():
            return 1_000_000
    except Exception:
        pass
    return 200_000


def git_branch(cwd):
    """`.git/HEAD` direkt lesen statt git zu spawnen (Statusline laeuft oft)."""
    try:
        d = cwd
        for _ in range(12):
            git_path = os.path.join(d, ".git")
            if os.path.exists(git_path):
                head_file = os.path.join(git_path, "HEAD")
                if os.path.isfile(git_path):  # Worktree: .git ist Datei
                    gitdir = open(git_path).read().split("gitdir:")[-1].strip()
                    if not os.path.isabs(gitdir):
                        gitdir = os.path.join(d, gitdir)
                    head_file = os.path.join(gitdir, "HEAD")
                head = open(head_file).read().strip()
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


def active_agents(data):
    """Laufende Subagenten: agent-*.jsonl unter <session>/subagents/, das in
    den letzten 45s beschrieben wurde. Laufende Agenten appenden staendig an
    ihr Transcript; fertige Dateien veralten sofort. Resume-fest, da der Pfad
    direkt aus transcript_path abgeleitet wird."""
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
            if now - os.path.getmtime(os.path.join(subdir, f)) < 45:
                count += 1
        return count
    except Exception:
        return 0


def fmt_duration(ms):
    minutes = int(ms // 60_000)
    if minutes < 60:
        return f"{minutes}m"
    return f"{minutes // 60}h{minutes % 60:02d}m"


def bar(pct, width=10):
    # floor(x+0.5) statt round(): identisches Runden wie die JS-Variante
    # (Python rundet halbe Werte zur geraden Zahl, JS nicht)
    filled = max(0, min(width, int(pct / 100 * width + 0.5)))
    return "▰" * filled + DIM + "▱" * (width - filled)


def main():
    try:
        # BOM strippen — manche Shells pipen mit
        data = json.loads(sys.stdin.read().lstrip("﻿"))
    except Exception:
        print("Claude")
        return

    try:
        render(data)
    except Exception:
        # Kontrakt: niemals crashen, schlimmstenfalls nur der Name
        print("Claude")


def render(data):
    model = data.get("model") or {}
    name = model.get("display_name") or model.get("id") or "Claude"

    cw = data.get("context_window") or {}
    size = cw.get("context_window_size")
    if size:
        used = cw.get("total_input_tokens")
        if used is None:
            cu = cw.get("current_usage") or {}
            used = (cu.get("input_tokens", 0)
                    + cu.get("cache_read_input_tokens", 0)
                    + cu.get("cache_creation_input_tokens", 0))
        limit = size
        pct = cw.get("used_percentage")
        if pct is None:
            pct = (used / limit * 100) if limit else 0
    else:
        used = from_transcript(data)
        limit = detect_limit(data, used)
        pct = (used / limit * 100) if limit else 0
    if not isinstance(pct, (int, float)) or pct != pct:  # NaN-Schutz
        pct = 0
    pct = max(0, pct)
    free = max(0, limit - used)

    col = RED if pct >= 90 else YELLOW if pct >= 70 else GREEN
    sep = f" {DIM}│{RESET} "

    ctx_seg = (f"{col}{fmt_tokens(used)}{RESET}{DIM}/{fmt_limit(limit)}{RESET} "
               f"{DIM}·{RESET} free {GREEN}{fmt_tokens(free)}{RESET}")
    if pct >= 85:
        ctx_seg += f" {RED}Compact bald!{RESET}"

    parts = [
        name,
        f"{col}{bar(pct)}{RESET} {col}{pct:.0f}%{RESET}",
        ctx_seg,
    ]

    agents = active_agents(data)
    if agents > 0:
        parts.append(f"{CYAN}Agents: {agents}{RESET}")

    cost = data.get("cost") or {}
    cost_bits = []
    if (cost.get("total_cost_usd") or 0) > 0:
        cost_bits.append(f"${cost['total_cost_usd']:.2f}")
    added = cost.get("total_lines_added") or 0
    removed = cost.get("total_lines_removed") or 0
    if added or removed:
        cost_bits.append(f"{GREEN}+{added}{RESET}{DIM}/{RESET}{RED}-{removed}{RESET}{DIM} lines{RESET}")
    if (cost.get("total_duration_ms") or 0) > 60_000:
        cost_bits.append(fmt_duration(cost["total_duration_ms"]) + " runtime")
    if cost_bits:
        parts.append(f"{DIM}{' · '.join(cost_bits)}{RESET}")

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
# Claude Code Statusline (PowerShell) — Zero-Dependency-Variante fuer Windows.
# Funktions-Gegenstueck zu statusline.js (Node) und statusline.py (Python):
# Modell, Context-Balken/%, used/limit, free, laufende Subagenten, Kosten,
# Zeilen, Laufzeit, Ordner + Git-Branch. Kontrakt: niemals crashen.
$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

$E = [char]27
$RESET = "$E[0m"; $DIM = "$E[2m"; $GREEN = "$E[32m"
$YELLOW = "$E[33m"; $RED = "$E[31m"; $CYAN = "$E[36m"

function Format-Tokens([double]$n) {
    if ($n -ge 1000000) { return [string]::Format($inv, '{0:0.0}M', $n / 1000000) }
    if ($n -ge 1000) { return [string]::Format($inv, '{0:0.0}k', $n / 1000) }
    return [string][math]::Round($n)
}

function Format-Limit([double]$n) {
    if ($n -ge 1000000) { return [string]::Format($inv, '{0:0}M', $n / 1000000) }
    if ($n -ge 1000) { return [string]::Format($inv, '{0:0}k', $n / 1000) }
    return [string][math]::Round($n)
}

function Format-Duration([double]$ms) {
    $min = [math]::Floor($ms / 60000)
    if ($min -lt 60) { return "${min}m" }
    return ('{0}h{1:00}m' -f [math]::Floor($min / 60), ($min % 60))
}

function Get-Bar([double]$pct, [int]$width) {
    # floor(x+0.5): identisches Runden wie JS-/Python-Variante
    $filled = [math]::Max(0, [math]::Min($width, [math]::Floor($pct / 100 * $width + 0.5)))
    return ('▰' * $filled) + $DIM + ('▱' * ($width - $filled))
}

function Get-TranscriptUsed($data) {
    # Fallback: used_tokens aus dem Transcript-Ende (letzte 512 KB) ableiten.
    $used = 0
    $tpath = $data.transcript_path
    if (-not $tpath -or -not (Test-Path $tpath)) { return 0 }
    try {
        $fs = [System.IO.File]::Open($tpath, 'Open', 'Read', 'ReadWrite')
        try {
            $tail = 524288
            if ($fs.Length -gt $tail) { $null = $fs.Seek(-$tail, 'End') }
            $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
            $text = $reader.ReadToEnd()
        } finally { $fs.Close() }
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
    # 1M-Session erkennen, wenn context_window fehlt (aeltere Versionen /
    # Resume-Edge-Cases) — sonst wuerde eine resumte 1M-Session /200k zeigen.
    if ($used -gt 200000) { return 1000000 }
    if ($data.exceeds_200k_tokens) { return 1000000 }
    $modelStr = "$($data.model.id) $($data.model.display_name)"
    if ($modelStr -match '\[1m\]') { return 1000000 }
    try {
        $settings = Get-Content (Join-Path $env:USERPROFILE '.claude\settings.json') -Raw | ConvertFrom-Json
        if ("$($settings.model)" -match '\[1m\]') { return 1000000 }
    } catch { }
    return 200000
}

function Get-GitBranch([string]$cwd) {
    # .git/HEAD direkt lesen statt git zu spawnen (Statusline laeuft oft)
    try {
        $dir = $cwd
        for ($i = 0; $i -lt 12 -and $dir; $i++) {
            $gitPath = Join-Path $dir '.git'
            if (Test-Path $gitPath) {
                $headFile = Join-Path $gitPath 'HEAD'
                if (Test-Path $gitPath -PathType Leaf) {
                    $gitdir = ((Get-Content $gitPath -Raw) -replace '^gitdir:\s*', '').Trim()
                    if (-not [System.IO.Path]::IsPathRooted($gitdir)) { $gitdir = Join-Path $dir $gitdir }
                    $headFile = Join-Path $gitdir 'HEAD'
                }
                $head = (Get-Content $headFile -Raw).Trim()
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

function Get-ActiveAgents($data) {
    # Laufende Subagenten: agent-*.jsonl unter <session>/subagents/ mit
    # mtime < 45s. Laufende Agenten appenden staendig an ihr Transcript.
    try {
        $tpath = $data.transcript_path
        if (-not $tpath) { return 0 }
        $dir = Join-Path ($tpath -replace '\.jsonl$', '') 'subagents'
        if (-not (Test-Path $dir)) { return 0 }
        $cutoff = (Get-Date).AddSeconds(-45)
        return @(Get-ChildItem $dir -Filter 'agent-*.jsonl' | Where-Object { $_.LastWriteTime -gt $cutoff }).Count
    } catch { return 0 }
}

try {
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    $raw = [Console]::In.ReadToEnd()
    $raw = $raw.TrimStart([char]0xFEFF)
    $data = $raw | ConvertFrom-Json

    $name = if ($data.model.display_name) { $data.model.display_name }
            elseif ($data.model.id) { $data.model.id } else { 'Claude' }

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
    if ([double]::IsNaN($pct) -or [double]::IsInfinity($pct)) { $pct = 0 }
    $pct = [math]::Max(0, $pct)
    $free = [math]::Max(0, $limit - $used)

    $col = if ($pct -ge 90) { $RED } elseif ($pct -ge 70) { $YELLOW } else { $GREEN }
    $sep = " $DIM│$RESET "

    $ctxSeg = "$col$(Format-Tokens $used)$RESET$DIM/$(Format-Limit $limit)$RESET $DIM·$RESET free $GREEN$(Format-Tokens $free)$RESET"
    if ($pct -ge 85) { $ctxSeg += " ${RED}Compact bald!$RESET" }

    $pctText = [string]::Format($inv, '{0:0}', $pct)
    $parts = @(
        $name,
        "$col$(Get-Bar $pct 10)$RESET $col$pctText%$RESET",
        $ctxSeg
    )

    $agents = Get-ActiveAgents $data
    if ($agents -gt 0) { $parts += "${CYAN}Agents: $agents$RESET" }

    $cost = $data.cost
    $costBits = @()
    if ($cost.total_cost_usd -gt 0) { $costBits += [string]::Format($inv, '${0:0.00}', $cost.total_cost_usd) }
    if ($cost.total_lines_added -or $cost.total_lines_removed) {
        $costBits += "$GREEN+$([int]$cost.total_lines_added)$RESET$DIM/$RESET$RED-$([int]$cost.total_lines_removed)$RESET$DIM lines$RESET"
    }
    if ($cost.total_duration_ms -gt 60000) { $costBits += "$(Format-Duration $cost.total_duration_ms) runtime" }
    if ($costBits.Count) { $parts += "$DIM$($costBits -join ' · ')$RESET" }

    $cwd = if ($data.workspace.current_dir) { $data.workspace.current_dir } else { $data.cwd }
    if ($cwd) {
        $loc = Split-Path $cwd -Leaf
        $branch = Get-GitBranch $cwd
        if ($branch) { $loc += " $CYAN($branch)$RESET" }
        $parts += $loc
    }

    Write-Output ($parts -join $sep)
} catch {
    # Kontrakt: niemals crashen, schlimmstenfalls nur der Name
    Write-Output 'Claude'
}
'@

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$utf8Bom = New-Object System.Text.UTF8Encoding($true)

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
    # Zero-Dependency-Fallback: PowerShell ist auf jedem Windows vorhanden.
    # BOM noetig, damit Windows PowerShell 5.1 die UTF-8-Zeichen korrekt liest.
    $scriptPath = Join-Path $claudeDir 'statusline.ps1'
    [System.IO.File]::WriteAllText($scriptPath, $statuslinePs, $utf8Bom)
    $cmd = 'powershell -NoProfile -ExecutionPolicy Bypass -File "' + $claudeDirFwd + '/statusline.ps1"'
    $runtime = 'PowerShell'
}

# settings.json mergen (bestehende Einstellungen bleiben erhalten, Backup als .bak)
$settingsPath = Join-Path $claudeDir 'settings.json'
$mergeJs = @'
const fs = require('fs'), os = require('os'), path = require('path');
const p = path.join(os.homedir(), '.claude', 'settings.json');
const cmd = process.argv[2];
let s = {};
if (fs.existsSync(p)) {
  try {
    const raw = fs.readFileSync(p, 'utf8');
    s = JSON.parse(raw.charCodeAt(0) === 0xFEFF ? raw.slice(1) : raw);
    fs.copyFileSync(p, p + '.bak');
  }
  catch (e) { console.error('settings.json ist kein gueltiges JSON: ' + e.message); process.exit(1); }
}
s.statusLine = { type: 'command', command: cmd, padding: 0 };
fs.writeFileSync(p, JSON.stringify(s, null, 2) + '\n');
'@
$mergePy = @'
import json, os, shutil, sys
p = os.path.expanduser('~/.claude/settings.json')
s = {}
if os.path.exists(p):
    try:
        with open(p, encoding='utf-8-sig') as f:
            s = json.load(f)
        shutil.copy(p, p + '.bak')
    except Exception as e:
        print('settings.json ist kein gueltiges JSON: %s' % e, file=sys.stderr)
        sys.exit(1)
s['statusLine'] = {'type': 'command', 'command': sys.argv[1], 'padding': 0}
with open(p, 'w', encoding='utf-8') as f:
    json.dump(s, f, indent=2)
    f.write('\n')
'@

if ($node -or $python) {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("claude-statusline-merge-" + [guid]::NewGuid().ToString('N'))
    $mergeFile = $null
    try {
        if ($node) {
            $mergeFile = "$tmp.js"
            [System.IO.File]::WriteAllText($mergeFile, $mergeJs, $utf8NoBom)
            & node $mergeFile $cmd
        } else {
            $mergeFile = "$tmp.py"
            [System.IO.File]::WriteAllText($mergeFile, $mergePy, $utf8NoBom)
            & python $mergeFile $cmd
        }
        if ($LASTEXITCODE -ne 0) { throw 'settings.json konnte nicht aktualisiert werden.' }
    } finally {
        if ($mergeFile) { Remove-Item $mergeFile -ErrorAction SilentlyContinue }
    }
} else {
    # Merge in purem PowerShell (kein Node/Python vorhanden)
    $settings = New-Object PSObject
    if (Test-Path $settingsPath) {
        try {
            $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
            Copy-Item $settingsPath "$settingsPath.bak" -Force
        } catch {
            Write-Error "settings.json ist kein gueltiges JSON: $($_.Exception.Message)"
            exit 1
        }
    }
    $statusLine = New-Object PSObject
    $statusLine | Add-Member NoteProperty type 'command'
    $statusLine | Add-Member NoteProperty command $cmd
    $statusLine | Add-Member NoteProperty padding 0
    $settings | Add-Member NoteProperty statusLine $statusLine -Force
    [System.IO.File]::WriteAllText($settingsPath, (($settings | ConvertTo-Json -Depth 100) + "`n"), $utf8NoBom)
}

# Smoke-Test
$samplePath = Join-Path ([System.IO.Path]::GetTempPath()) 'claude-statusline-sample.json'
[System.IO.File]::WriteAllText($samplePath, '{"model":{"display_name":"Test"},"context_window":{"context_window_size":200000,"total_input_tokens":50000}}', $utf8NoBom)
try {
    if ($node) { $out = Get-Content $samplePath -Raw | & node $scriptPath }
    elseif ($python) { $out = Get-Content $samplePath -Raw | & python $scriptPath }
    else { $out = cmd /c "type `"$samplePath`" | powershell -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" }
} finally {
    Remove-Item $samplePath -ErrorAction SilentlyContinue
}
if (-not $out) { throw 'Smoke-Test fehlgeschlagen: keine Ausgabe.' }

Write-Host ''
Write-Host "Statusline installiert ($runtime): $scriptPath"
Write-Host "settings.json aktualisiert: $settingsPath (Backup: settings.json.bak)"
Write-Host "Testausgabe:  $out"
Write-Host 'Fertig. Neue Claude-Code-Sessions zeigen die Statusline an; laufende nach Neustart der Session.'