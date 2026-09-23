# Generates install.ps1 and install.sh from the sources in src/.
# Run after every change to src/statusline.{js,py,ps1} so the self-contained
# installers stay in sync. Works with Windows PowerShell 5.1 and PowerShell 7
# on Windows, macOS and Linux:  pwsh ./build.ps1
#
# The templates use <HSOPEN>/<HSCLOSE> placeholders instead of real here-string
# delimiters because PowerShell here-strings cannot be nested.
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$src = Join-Path $root 'src'

$js = (Get-Content -LiteralPath (Join-Path $src 'statusline.js') -Raw).TrimEnd()
$py = (Get-Content -LiteralPath (Join-Path $src 'statusline.py') -Raw).TrimEnd()
$ps = (Get-Content -LiteralPath (Join-Path $src 'statusline.ps1') -Raw).TrimEnd()

# Shared settings.json merge logic (install / uninstall), used by both installers.
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
'@.TrimEnd()
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
'@.TrimEnd()

# ---------- install.ps1 (Windows) ----------
$ps1Template = @'
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

$mergeJs = <HSOPEN>
__MERGE_JS__
<HSCLOSE>
$mergePy = <HSOPEN>
__MERGE_PY__
<HSCLOSE>

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

$statuslineJs = <HSOPEN>
__JS__
<HSCLOSE>

$statuslinePy = <HSOPEN>
__PY__
<HSCLOSE>

$statuslinePs = <HSOPEN>
__PS__
<HSCLOSE>

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
'@

# ---------- install.sh (Linux / WSL / macOS) ----------
$shTemplate = @'
#!/usr/bin/env bash
# Claude Code Statusline - installer (Linux / WSL / macOS)
# Shows model, thinking mode, context usage (%, bar, free), rate limits, running
# subagents, cost, lines and runtime below the input line of every Claude Code session.
#
# Install:    curl -fsSL https://raw.githubusercontent.com/HashfoxGmbH/claude-code-statusline/main/install.sh | bash
#   or:       bash install.sh
# Uninstall:  curl -fsSL https://raw.githubusercontent.com/HashfoxGmbH/claude-code-statusline/main/install.sh | bash -s -- --uninstall
#   or:       bash install.sh --uninstall
set -euo pipefail

UNINSTALL=0
for arg in "$@"; do
    case "$arg" in
        --uninstall) UNINSTALL=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done
[ "${CLAUDE_STATUSLINE_UNINSTALL:-}" = "1" ] && UNINSTALL=1

CLAUDE_DIR="$HOME/.claude"
mkdir -p "$CLAUDE_DIR"

# Check that the runtime actually runs (e.g. the macOS /usr/bin/python3 stub
# without Command Line Tools exists but fails) and is recent enough.
have_python() {
    command -v python3 >/dev/null 2>&1 \
        && python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 6) else 1)' >/dev/null 2>&1
}
have_node() {
    command -v node >/dev/null 2>&1 \
        && node -e 'process.exit(parseInt(process.versions.node) >= 12 ? 0 : 1)' >/dev/null 2>&1
}

if have_python; then
    RUNTIME=python3
elif have_node; then
    RUNTIME=node
else
    echo "Neither python3 (>= 3.6) nor node (>= 12) found - please install one of them." >&2
    exit 1
fi

CMD=""
merge() {
    # $1 = install | uninstall. Exit codes: 0 = ok, 1 = error, 3 = nothing of ours registered.
    if [ "$RUNTIME" = "python3" ]; then
        CLAUDE_STATUSLINE_MODE="$1" CLAUDE_STATUSLINE_CMD="$CMD" CLAUDE_STATUSLINE_SETTINGS="$CLAUDE_DIR/settings.json" python3 - <<'MERGE_EOF'
__MERGE_PY__
MERGE_EOF
    else
        CLAUDE_STATUSLINE_MODE="$1" CLAUDE_STATUSLINE_CMD="$CMD" CLAUDE_STATUSLINE_SETTINGS="$CLAUDE_DIR/settings.json" node - <<'MERGE_EOF'
__MERGE_JS__
MERGE_EOF
    fi
}

if [ "$UNINSTALL" = "1" ]; then
    rc=0
    merge uninstall || rc=$?
    if [ "$rc" = "3" ]; then
        echo "This statusline is not registered in settings.json - nothing to do."
        exit 0
    fi
    [ "$rc" = "0" ] || { echo "Could not update settings.json." >&2; exit 1; }
    rm -f "$CLAUDE_DIR/statusline.py" "$CLAUDE_DIR/statusline.js" "$CLAUDE_DIR/statusline.ps1"
    echo "Statusline uninstalled. Restart running Claude Code sessions to apply."
    exit 0
fi

cat > "$CLAUDE_DIR/statusline.py" <<'STATUSLINE_PY_EOF'
__PY__
STATUSLINE_PY_EOF

cat > "$CLAUDE_DIR/statusline.js" <<'STATUSLINE_JS_EOF'
__JS__
STATUSLINE_JS_EOF

if [ "$RUNTIME" = "python3" ]; then
    CMD="python3 \"$HOME/.claude/statusline.py\""
    SCRIPT="$CLAUDE_DIR/statusline.py"
else
    CMD="node \"$HOME/.claude/statusline.js\""
    SCRIPT="$CLAUDE_DIR/statusline.js"
fi

merge install

OUT=$(echo '{"model":{"display_name":"Test"},"context_window":{"context_window_size":200000,"total_input_tokens":50000}}' | $RUNTIME "$SCRIPT")
[ -n "$OUT" ] || { echo "Smoke test failed: no output." >&2; exit 1; }

echo ""
echo "Statusline installed ($RUNTIME): $SCRIPT"
echo "settings.json updated (backup: settings.json.bak)"
echo "Test output:  $OUT"
echo "Done. New Claude Code sessions show the statusline; running sessions after a restart."
'@

$ps1 = $ps1Template.Replace('__MERGE_JS__', $mergeJs).Replace('__MERGE_PY__', $mergePy).Replace('__JS__', $js).Replace('__PY__', $py).Replace('__PS__', $ps).Replace('<HSOPEN>', "@'").Replace('<HSCLOSE>', "'@")
$sh = $shTemplate.Replace('__MERGE_JS__', $mergeJs).Replace('__MERGE_PY__', $mergePy).Replace('__PY__', $py).Replace('__JS__', $js)

# Everything ASCII-only and WITHOUT a BOM: install.ps1 then works the same via
# "-File" (PS 5.1/7) AND via "irm | iex" (a BOM would break the first line for
# iex); install.sh needs LF line endings (bash fails on CRLF).
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$ps1Path = Join-Path $root 'install.ps1'
$shPath = Join-Path $root 'install.sh'
[System.IO.File]::WriteAllText($ps1Path, (($ps1 -replace "`r`n", "`n") -replace "`n", "`r`n"), $utf8NoBom)
[System.IO.File]::WriteAllText($shPath, (($sh -replace "`r`n", "`n") + "`n"), $utf8NoBom)

Write-Host "Generated: install.ps1 ($([math]::Round((Get-Item -LiteralPath $ps1Path).Length / 1kb, 1)) KB), install.sh ($([math]::Round((Get-Item -LiteralPath $shPath).Length / 1kb, 1)) KB)"
