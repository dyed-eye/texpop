# adapters\claude-code.ps1 -- ChatSourceAdapter for Anthropic Claude Code CLI.
#
# Part of texpop (https://github.com/dyed-eye/texpop).
#
# Transcript layout:
#   $env:USERPROFILE\.claude\projects\<encoded-cwd>\*.jsonl
# where <encoded-cwd> is the working directory with ':' '\' '.' all replaced by '-'.
#
# Each line is a JSON object. Assistant text lines look roughly like:
#   {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"..."}]},"requestId":"..."}
# Project sessions are also tagged by an 'aiTitle' line which mirrors the WT tab title.
#
# Dot-sourced from show.ps1; depends on:
#   - $script:Adapters       : array, this file appends to it
#   - Log                    : function defined in show.ps1
#   - $script:ClaudeProjectsRoot : root path (set by show.ps1 from -ProjectsRoot)

# ---------- Helpers (Claude-specific) ----------

function Resolve-ClaudeProjectDirForCwd {
    param([string]$cwd, [string]$projectsRoot)
    if (-not $cwd) { return $null }
    $encoded = $cwd.Replace(':', '-').Replace('\', '-').Replace('.', '-')
    $candidates = @(
        $encoded,
        ($encoded.Substring(0,1).ToLower() + $encoded.Substring(1))
    )
    foreach ($c in $candidates) {
        $p = Join-Path $projectsRoot $c
        if (Test-Path $p) {
            Log "  CWD '$cwd' -> project dir '$c'"
            return $p
        }
    }
    Log "  CWD '$cwd' -> NO project dir match (tried: $($candidates -join ', '))"
    return $null
}

function Find-ClaudeNewestJsonl {
    param([string]$projectDir)
    Get-ChildItem -Path $projectDir -Filter '*.jsonl' -File `
        -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

# Read last ~60KB of a jsonl, find the most recent {"type":"ai-title","aiTitle":"..."} line.
function Get-ClaudeAiTitle {
    param([System.IO.FileInfo]$file)
    try {
        $size      = $file.Length
        $chunkSize = [int][Math]::Min(60000, $size)
        $stream = [System.IO.File]::Open($file.FullName, 'Open', 'Read', 'ReadWrite')
        try {
            if ($size -gt $chunkSize) {
                $stream.Seek(-$chunkSize, [System.IO.SeekOrigin]::End) | Out-Null
            }
            $buf = [byte[]]::new([int][Math]::Min($size, $chunkSize))
            $br  = $stream.Read($buf, 0, $buf.Length)
            $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $br)
        } finally { $stream.Dispose() }

        $matches = [regex]::Matches($text, '"aiTitle":"((?:[^"\\]|\\.)*)"')
        if ($matches.Count -eq 0 -and $size -gt $chunkSize) {
            # Try the head of the file too (small chats)
            $stream2 = [System.IO.File]::Open($file.FullName, 'Open', 'Read', 'ReadWrite')
            try {
                $buf2 = [byte[]]::new([int][Math]::Min(60000, $size))
                $br2  = $stream2.Read($buf2, 0, $buf2.Length)
                $head = [System.Text.Encoding]::UTF8.GetString($buf2, 0, $br2)
                $matches = [regex]::Matches($head, '"aiTitle":"((?:[^"\\]|\\.)*)"')
            } finally { $stream2.Dispose() }
        }
        if ($matches.Count -eq 0) { return $null }
        return $matches[$matches.Count - 1].Groups[1].Value
    } catch { return $null }
}

# Read the entire jsonl into a string array of lines, capped at ~maxBytes from
# the tail. Returns @() on error. Used by the modal-detection helpers below.
function Read-ClaudeJsonlTail {
    param([System.IO.FileInfo]$file, [int]$maxBytes = 1500000)
    try {
        $size      = $file.Length
        $chunkSize = [int][Math]::Min($maxBytes, $size)
        $stream = [System.IO.File]::Open($file.FullName, 'Open', 'Read', 'ReadWrite')
        try {
            if ($size -gt $chunkSize) {
                $stream.Seek(-$chunkSize, [System.IO.SeekOrigin]::End) | Out-Null
            }
            $buf = [byte[]]::new($chunkSize)
            [void]$stream.Read($buf, 0, $chunkSize)
            $text = [System.Text.Encoding]::UTF8.GetString($buf)
        } finally { $stream.Dispose() }
        $lines = $text.Split([char]"`n")
        if ($size -gt $chunkSize -and $lines.Count -gt 0) {
            # Drop the partial first line.
            $lines = $lines | Select-Object -Skip 1
        }
        return ,$lines
    } catch {
        return ,@()
    }
}

# Get the timestamp (DateTime?) of the latest assistant *text* turn in $lines.
# Returns $null if not found.
function Get-LatestAssistantTextTime {
    param([string[]]$lines)
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i]
        if (-not $line) { continue }
        if ($line.Length -lt 80) { continue }
        if (-not $line.Contains('"role":"assistant"')) { continue }
        if (-not $line.Contains('"type":"text"')) { continue }
        $m = [regex]::Match($line, '"timestamp":"([^"]+)"')
        if ($m.Success) {
            try { return [DateTime]::Parse($m.Groups[1].Value).ToUniversalTime() } catch { }
        }
    }
    return $null
}

# Return the most recent ExitPlanMode tool_use line (raw JSON string) that has
# NOT been resolved by a following tool_result. Returns $null if none active.
function Get-ActivePlanModeLine {
    param([string[]]$lines)
    # Find latest tool_use for ExitPlanMode.
    $planIdx     = -1
    $planToolId  = $null
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i]
        if (-not $line) { continue }
        if (-not $line.Contains('"name":"ExitPlanMode"')) { continue }
        if (-not $line.Contains('"type":"tool_use"')) { continue }
        $m = [regex]::Match($line, '"type":"tool_use","id":"([^"]+)","name":"ExitPlanMode"')
        if ($m.Success) {
            $planIdx    = $i
            $planToolId = $m.Groups[1].Value
            break
        }
    }
    if ($planIdx -lt 0) { return $null }

    # Look forward for a tool_result referencing $planToolId. Any such match
    # means the plan was resolved (approved/rejected) -- not active.
    for ($j = $planIdx + 1; $j -lt $lines.Count; $j++) {
        $line = $lines[$j]
        if (-not $line) { continue }
        if ($line.Contains("`"tool_use_id`":`"$planToolId`"")) {
            return $null
        }
    }
    return $lines[$planIdx]
}

# Extract the markdown plan body from a tool_use ExitPlanMode line.
function Get-PlanModeMarkdown {
    param([string]$line)
    if (-not $line) { return $null }
    try {
        $obj = $line | ConvertFrom-Json -ErrorAction Stop
    } catch { return $null }
    if (-not $obj.message -or -not $obj.message.content) { return $null }
    foreach ($c in @($obj.message.content)) {
        if ($c.type -eq 'tool_use' -and $c.name -eq 'ExitPlanMode' -and $c.input -and $c.input.plan) {
            return [string]$c.input.plan
        }
    }
    return $null
}

# Find the most recent aside_question subagent jsonl whose mtime is newer than
# the latest assistant text turn in the parent transcript. Returns the
# [FileInfo] or $null.
function Find-ActiveAsideSubagent {
    param([System.IO.FileInfo]$parentFile, [DateTime]$lastAssistantUtc)
    $sessionDir = [System.IO.Path]::Combine(
        $parentFile.DirectoryName,
        [System.IO.Path]::GetFileNameWithoutExtension($parentFile.Name))
    $subDir = Join-Path $sessionDir 'subagents'
    if (-not (Test-Path $subDir)) { return $null }
    $candidates = Get-ChildItem -Path $subDir -Filter 'agent-aside_question-*.jsonl' -File `
        -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    if (-not $candidates) { return $null }
    $newest = $candidates | Select-Object -First 1
    # The subagent file must be newer than the parent's last assistant text
    # turn -- else the assistant has already moved past the aside.
    $newestUtc = $newest.LastWriteTimeUtc
    if ($newestUtc -le $lastAssistantUtc) { return $null }
    return $newest
}

# Pull the last assistant text-only turn out of a sidechain subagent jsonl.
function Get-AsideMarkdown {
    param([System.IO.FileInfo]$file)
    $lines = Read-ClaudeJsonlTail -file $file -maxBytes 800000
    if (-not $lines) { return $null }
    # Walk backward, collect text from the latest end_turn assistant message.
    $sb = [System.Text.StringBuilder]::new()
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i]
        if (-not $line) { continue }
        if ($line.Length -lt 80) { continue }
        if (-not $line.Contains('"role":"assistant"')) { continue }
        if (-not $line.Contains('"type":"text"')) { continue }
        try {
            $obj = $line | ConvertFrom-Json -ErrorAction Stop
        } catch { continue }
        if (-not $obj.message -or -not $obj.message.content) { continue }
        foreach ($c in @($obj.message.content)) {
            if ($c.type -eq 'text' -and $c.text) {
                [void]$sb.Insert(0, $c.text)
            }
        }
        if ($sb.Length -gt 0) { break }
    }
    if ($sb.Length -eq 0) { return $null }
    return $sb.ToString()
}

# Return @{ kind = 'plan' | 'btw'; markdown = '...' } or $null.
# Modal detection: if the most-recent significant event in the transcript is an
# unresolved plan-mode preview OR an /aside (~= /btw) subagent answer that
# postdates the last assistant text turn, render that instead.
function Get-ClaudeActiveModalContent {
    param([System.IO.FileInfo]$file)

    $lines = Read-ClaudeJsonlTail -file $file
    if (-not $lines -or $lines.Count -eq 0) { return $null }

    $lastAssistantUtc = Get-LatestAssistantTextTime -lines $lines
    if (-not $lastAssistantUtc) { $lastAssistantUtc = [DateTime]::MinValue }

    # 1. Plan mode -- only consider it active when no tool_result has resolved
    #    it yet. This is the strongest "modal" signal.
    $planLine = Get-ActivePlanModeLine -lines $lines
    if ($planLine) {
        $planMd = Get-PlanModeMarkdown -line $planLine
        if ($planMd) {
            $header  = "## Plan mode active`r`n`r`n> Awaiting your approval`r`n`r`n"
            return @{ kind = 'plan'; markdown = $header + $planMd }
        }
    }

    # 2. /aside (a.k.a. /btw) -- the aside subagent jsonl mtime postdates the
    #    main transcript's last assistant text turn.
    $aside = Find-ActiveAsideSubagent -parentFile $file -lastAssistantUtc $lastAssistantUtc
    if ($aside) {
        $asideMd = Get-AsideMarkdown -file $aside
        if ($asideMd) {
            $header  = "## /aside`r`n`r`n> Side question response`r`n`r`n"
            return @{ kind = 'btw'; markdown = $header + $asideMd }
        }
    }

    return $null
}

function Normalize-ClaudeTitle {
    param([string]$t)
    if (-not $t) { return '' }
    # Strip leading decoration chars (e.g. "* ", emoji, whitespace) and lowercase.
    return (($t -replace '^[\W_]+', '').Trim().ToLower())
}

function Find-ClaudeSessionByTitle {
    param([string]$targetTitle, $projectDirs)
    $norm = Normalize-ClaudeTitle $targetTitle
    if (-not $norm) { return $null }
    Log "Title-match target: '$targetTitle' (normalized='$norm')"
    foreach ($pd in $projectDirs) {
        $jsonls = Get-ChildItem -Path $pd -Filter '*.jsonl' -File `
            -ErrorAction SilentlyContinue
        foreach ($j in $jsonls) {
            $title = Get-ClaudeAiTitle $j
            if (-not $title) { continue }
            $jNorm = Normalize-ClaudeTitle $title
            Log "  '$($j.Name)' aiTitle='$title' (norm='$jNorm')"
            if ($jNorm -eq $norm) {
                Log "  MATCH"
                return $j
            }
        }
    }
    Log "Title-match: no aiTitle matched"
    return $null
}

# ---------- Adapter scriptblocks ----------

$claudeMatch = {
    param($candidates)
    foreach ($c in $candidates) {
        $name = if ($c.Name) { $c.Name.ToLower() } else { '' }
        $cmd  = if ($c.CommandLine) { $c.CommandLine } else { '' }
        if ($name -eq 'claude.exe') { return $true }
        if (($name -eq 'node.exe') -and ($cmd -match 'claude')) { return $true }
    }
    return $false
}

$claudeFindFocused = {
    param($candidates, $foregroundTitle, $wtTabName)

    $projectsRoot = $script:ClaudeProjectsRoot

    # Filter candidates down to Claude-specific ones (the Match block already
    # confirmed at least one exists, but the candidate list is shared across
    # adapters so we re-filter here).
    $claudeCandidates = @()
    foreach ($c in $candidates) {
        $name = if ($c.Name) { $c.Name.ToLower() } else { '' }
        $cmd  = if ($c.CommandLine) { $c.CommandLine } else { '' }
        $isClaude = ($name -eq 'claude.exe') -or
                    (($name -eq 'node.exe') -and ($cmd -match 'claude'))
        if ($isClaude) { $claudeCandidates += $c }
    }
    if (-not $claudeCandidates) { return $null }

    # Collect unique project dirs from candidate CWDs.
    $projectDirs = @()
    foreach ($c in $claudeCandidates) {
        $cwd = $null
        try { $cwd = [LatexPopup.Native]::GetProcessCwd([int]$c.ProcessId) } catch { Log "  PEB read pid=$($c.ProcessId) threw: $_" }
        Log "  pid=$($c.ProcessId)  CWD='$cwd'"
        if (-not $cwd) { continue }
        $pd = Resolve-ClaudeProjectDirForCwd -cwd $cwd -projectsRoot $projectsRoot
        if (-not $pd) { continue }
        if ($projectDirs -notcontains $pd) { $projectDirs += $pd }
    }
    Log "Candidate project dirs: $($projectDirs.Count)"

    # PRIMARY signal: match the WT/window title against ai-title in candidate jsonls.
    $titleSources = @()
    if ($foregroundTitle) { $titleSources += $foregroundTitle }
    if ($wtTabName -and ($wtTabName -ne $foregroundTitle)) { $titleSources += $wtTabName }
    foreach ($t in $titleSources) {
        $match = Find-ClaudeSessionByTitle -targetTitle $t -projectDirs $projectDirs
        if ($match) { return $match }
    }

    # Fallback: newest jsonl across candidate project dirs (heuristic).
    $best = $null
    foreach ($pd in $projectDirs) {
        $j = Find-ClaudeNewestJsonl $pd
        if (-not $j) { continue }
        Log "  fallback newest in $($pd | Split-Path -Leaf): $($j.Name) (mtime $($j.LastWriteTime))"
        if (-not $best -or $j.LastWriteTime -gt $best.LastWriteTime) { $best = $j }
    }
    if ($best) { Log "Tree-walk fallback chose: $($best.FullName)" }
    return $best
}

$claudeGetLastAssistantTurn = {
    param([System.IO.FileInfo]$file)

    # Modal-first: plan-mode preview or /aside answer takes precedence over
    # the previous full assistant turn. Falls through if neither is active.
    try {
        $modal = Get-ClaudeActiveModalContent -file $file
    } catch {
        Log "Parser[claude]: modal detect threw: $_"
        $modal = $null
    }
    if ($modal -and $modal.markdown) {
        Log "Parser[claude]: modal active kind=$($modal.kind)  len=$($modal.markdown.Length)"
        return $modal.markdown
    }

    $size      = $file.Length
    $chunkSize = [int][Math]::Min(500000, $size)
    $stream = [System.IO.File]::Open($file.FullName, 'Open', 'Read', 'ReadWrite')
    try {
        $stream.Seek(-$chunkSize, [System.IO.SeekOrigin]::End) | Out-Null
        $buf = [byte[]]::new($chunkSize)
        [void]$stream.Read($buf, 0, $chunkSize)
        $text = [System.Text.Encoding]::UTF8.GetString($buf)
    } finally {
        $stream.Dispose()
    }

    $lines = $text.Split([char]"`n")
    if ($size -gt $chunkSize -and $lines.Count -gt 0) {
        $lines = $lines | Select-Object -Skip 1
    }
    Log "Parser[claude]: file=$($file.Name) size=$size  chunkSize=$chunkSize  lines=$($lines.Count)"

    $lastReqId = $null
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i]
        if ($line.Length -lt 80) { continue }
        if (-not $line.Contains('"role":"assistant"')) { continue }
        if (-not $line.Contains('"type":"text"')) { continue }
        $m = [regex]::Match($line, '"requestId":"([^"]+)"')
        if ($m.Success) {
            $lastReqId = $m.Groups[1].Value
            break
        }
    }
    if (-not $lastReqId) { Log "Parser[claude]: no last-assistant requestId found"; return '' }
    Log "Parser[claude]: last requestId=$lastReqId"

    $sb = [System.Text.StringBuilder]::new()
    foreach ($line in $lines) {
        if ($line.Length -lt 80) { continue }
        if (-not $line.Contains($lastReqId)) { continue }
        if (-not $line.Contains('"type":"text"')) { continue }
        if (-not $line.Contains('"role":"assistant"')) { continue }
        try {
            $obj = $line | ConvertFrom-Json -ErrorAction Stop
            if ($obj.message -and $obj.message.content) {
                foreach ($c in @($obj.message.content)) {
                    if ($c.type -eq 'text' -and $c.text) {
                        [void]$sb.Append($c.text)
                    }
                }
            }
        } catch { }
    }
    return $sb.ToString()
}

$script:Adapters += @(
    @{
        Name                 = 'claude-code'
        Description          = 'Anthropic Claude Code CLI (~/.claude/projects/*.jsonl)'
        Match                = $claudeMatch
        FindFocusedSession   = $claudeFindFocused
        GetLastAssistantTurn = $claudeGetLastAssistantTurn
    }
)
