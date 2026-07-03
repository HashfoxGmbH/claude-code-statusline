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
