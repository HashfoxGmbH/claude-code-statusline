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

function Test-WaitingOnTool([string]$path) {
    # Last message entry of a subagent transcript: assistant with tool_use =
    # waiting for a tool (e.g. a long build), user with tool_result = the model
    # is working on the next step. Either way nothing is written to the
    # transcript until it finishes, but the agent is still running.
    $lines = (Read-Tail $path 65536) -split "`n"
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
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
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
