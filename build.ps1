# Generiert install.ps1 und install.sh aus den Quellen in src/.
# Nach jeder Aenderung an src/statusline.{js,py,ps1} ausfuehren, damit die
# selbst-enthaltenen Installer synchron bleiben.
#
# Die Templates nutzen <HSOPEN>/<HSCLOSE>-Platzhalter statt echter Here-String-
# Delimiter, weil sich Here-Strings in PowerShell nicht verschachteln lassen.
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

$js = (Get-Content "$root\src\statusline.js" -Raw).TrimEnd()
$py = (Get-Content "$root\src\statusline.py" -Raw).TrimEnd()
$ps = (Get-Content "$root\src\statusline.ps1" -Raw).TrimEnd()

# ---------- install.ps1 (Windows) ----------
$ps1Template = @'
# Claude Code Statusline - Installer (Windows)
# Zeigt Modell, Context-Verbrauch (%, Balken, free), laufende Subagenten,
# Kosten, Zeilen und Laufzeit unter der Eingabezeile jeder Claude-Code-Session.
#
# Laeuft ohne Zusatzinstallation: nutzt Node.js oder Python falls vorhanden,
# sonst die reine PowerShell-Variante (auf jedem Windows verfuegbar).
#
# Nutzung:  powershell -ExecutionPolicy Bypass -File install.ps1
#   oder:   irm https://raw.githubusercontent.com/HashfoxGmbH/claude-code-statusline/main/install.ps1 | iex
$ErrorActionPreference = 'Stop'

$claudeDir = Join-Path $env:USERPROFILE '.claude'
New-Item -ItemType Directory -Force $claudeDir | Out-Null
# Forward-Slashes: Claude Code fuehrt den Befehl unter Windows via Git Bash
# oder PowerShell aus; mit / funktioniert der Pfad in beiden.
$claudeDirFwd = $claudeDir -replace '\\', '/'

$node = Get-Command node -ErrorAction SilentlyContinue
$python = Get-Command python -ErrorAction SilentlyContinue

$statuslineJs = <HSOPEN>
__JS__
<HSCLOSE>

$statuslinePy = <HSOPEN>
__PY__
<HSCLOSE>

$statuslinePs = <HSOPEN>
__PS__
<HSCLOSE>

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
$mergeJs = <HSOPEN>
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
<HSCLOSE>
$mergePy = <HSOPEN>
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
<HSCLOSE>

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
'@

# ---------- install.sh (Linux / WSL / macOS) ----------
$shTemplate = @'
#!/usr/bin/env bash
# Claude Code Statusline - Installer (Linux / WSL / macOS)
# Zeigt Modell, Context-Verbrauch (%, Balken, free), laufende Subagenten,
# Kosten, Zeilen und Laufzeit unter der Eingabezeile jeder Claude-Code-Session.
# Nutzung:  bash install.sh
#   oder:   curl -fsSL https://raw.githubusercontent.com/HashfoxGmbH/claude-code-statusline/main/install.sh | bash
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
mkdir -p "$CLAUDE_DIR"

if command -v python3 >/dev/null 2>&1; then
    RUNTIME=python3
elif command -v node >/dev/null 2>&1; then
    RUNTIME=node
else
    echo "Weder python3 noch node gefunden - bitte eines von beiden installieren." >&2
    exit 1
fi

cat > "$CLAUDE_DIR/statusline.py" <<'STATUSLINE_PY_EOF'
__PY__
STATUSLINE_PY_EOF

cat > "$CLAUDE_DIR/statusline.js" <<'STATUSLINE_JS_EOF'
__JS__
STATUSLINE_JS_EOF

if [ "$RUNTIME" = "python3" ]; then
    CMD="python3 $HOME/.claude/statusline.py"
    SCRIPT="$CLAUDE_DIR/statusline.py"
else
    CMD="node $HOME/.claude/statusline.js"
    SCRIPT="$CLAUDE_DIR/statusline.js"
fi

merge_py() {
python3 - "$CMD" <<'MERGE_EOF'
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
MERGE_EOF
}

merge_node() {
node - "$CMD" <<'MERGE_EOF'
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
MERGE_EOF
}

if [ "$RUNTIME" = "python3" ]; then merge_py; else merge_node; fi

OUT=$(echo '{"model":{"display_name":"Test"},"context_window":{"context_window_size":200000,"total_input_tokens":50000}}' | $RUNTIME "$SCRIPT")
[ -n "$OUT" ] || { echo "Smoke-Test fehlgeschlagen: keine Ausgabe." >&2; exit 1; }

echo ""
echo "Statusline installiert ($RUNTIME): $SCRIPT"
echo "settings.json aktualisiert (Backup: settings.json.bak)"
echo "Testausgabe:  $OUT"
echo "Fertig. Neue Claude-Code-Sessions zeigen die Statusline an; laufende nach Neustart der Session."
'@

$ps1 = $ps1Template.Replace('__JS__', $js).Replace('__PY__', $py).Replace('__PS__', $ps).Replace('<HSOPEN>', "@'").Replace('<HSCLOSE>', "'@")
$sh = $shTemplate.Replace('__PY__', $py).Replace('__JS__', $js)

# install.ps1 MIT BOM (PowerShell 5.1 braucht BOM fuer UTF-8-Skripte),
# install.sh OHNE BOM und mit LF-Zeilenenden (bash scheitert sonst).
[System.IO.File]::WriteAllText("$root\install.ps1", $ps1, [System.Text.Encoding]::UTF8)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText("$root\install.sh", (($sh -replace "`r`n", "`n") + "`n"), $utf8NoBom)

Write-Host "Generiert: install.ps1 ($([math]::Round((Get-Item "$root\install.ps1").Length/1kb,1)) KB), install.sh ($([math]::Round((Get-Item "$root\install.sh").Length/1kb,1)) KB)"
