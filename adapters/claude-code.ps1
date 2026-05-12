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
    # Encoding rule (verified by sampling existing project dirs): replace
    # ':', '\', '.', and '_' with '-'. Case of the drive letter sometimes
    # round-trips lowercased (e.g. 'c--emae-sandbox-wardrobe-app'), so try
    # both variants.
    $encoded = $cwd.Replace(':', '-').Replace('\', '-').Replace('.', '-').Replace('_', '-')
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
            # Tail read missed it; try the head too. The aiTitle line is
            # usually written near the start of long transcripts.
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

# Return @{ kind = 'plan'; markdown = '...' } or $null.
# Modal detection: if the most-recent significant event in the transcript is an
# unresolved plan-mode preview, render that instead. /aside detection is
# text-marker-based and lives in the GetLastAssistantTurn scriptblock.
function Get-ClaudeActiveModalContent {
    param([System.IO.FileInfo]$file)

    $lines = Read-ClaudeJsonlTail -file $file
    if (-not $lines -or $lines.Count -eq 0) { return $null }

    # Plan mode -- only consider it active when no tool_result has resolved
    # it yet. This is the strongest "modal" signal.
    $planLine = Get-ActivePlanModeLine -lines $lines
    if ($planLine) {
        $planMd = Get-PlanModeMarkdown -line $planLine
        if ($planMd) {
            $header  = "## Plan mode active`r`n`r`n> Awaiting your approval`r`n`r`n"
            return @{ kind = 'plan'; markdown = $header + $planMd }
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

# Secondary match: compare the normalized foreground title against each
# candidate's CWD basename. Catches the case where the WT tab name was
# auto-set by Claude Code (e.g. spinner-stripped 'filament' against a cwd
# basename of 'huygens_filament'). Returns the newest jsonl in the
# best-scoring candidate's project dir.
function Find-ClaudeSessionByCwdBasename {
    param([string]$targetTitle, $candidatePairs)
    $norm = Normalize-ClaudeTitle $targetTitle
    if (-not $norm) { return $null }
    $titleKey = ($norm -replace '[^a-z0-9]+', '')
    if (-not $titleKey) { return $null }
    Log "CWD-basename match: title-key='$titleKey'"

    $bestPair  = $null
    $bestScore = 0
    foreach ($p in $candidatePairs) {
        $leaf = Split-Path $p.Cwd -Leaf
        if (-not $leaf) { continue }
        $leafKey = ($leaf.ToLower() -replace '[^a-z0-9]+', '')
        if (-not $leafKey) { continue }
        $score = 0
        if ($leafKey -eq $titleKey)              { $score = 100 }
        elseif ($leafKey.StartsWith($titleKey))  { $score = 80  }
        elseif ($leafKey.EndsWith($titleKey))    { $score = 75  }
        elseif ($leafKey.Contains($titleKey))    { $score = 60  }
        elseif ($titleKey.Contains($leafKey))    { $score = 50  }
        Log "  leaf='$leaf' (key='$leafKey') score=$score"
        if ($score -gt $bestScore) {
            $bestScore = $score
            $bestPair  = $p
        }
    }
    if ($bestScore -lt 50 -or $null -eq $bestPair) {
        Log "CWD-basename match: no candidate scored"
        return $null
    }
    Log "CWD-basename pick: $($bestPair.Cwd) (score $bestScore)"
    $j = Find-ClaudeNewestJsonl $bestPair.Path
    if ($j) { Log "  -> $($j.Name)" }
    return $j
}

# ---------- Adapter scriptblocks ----------

$claudeMatch = {
    param($candidates)
    foreach ($c in $candidates) {
        $name = if ($c.Name) { $c.Name.ToLower() } else { '' }
        $cmd  = if ($c.CommandLine) { $c.CommandLine } else { '' }
        if ($name -eq 'claude.exe') { return $true }
        # Word-boundary match so paths like C:\Users\claude\... or scripts
        # named preclaude.js don't false-positive. Mirror the codex adapter.
        if (($name -eq 'node.exe') -and ($cmd -match '(?i)\bclaude\b')) { return $true }
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
                    (($name -eq 'node.exe') -and ($cmd -match '(?i)\bclaude\b'))
        if ($isClaude) { $claudeCandidates += $c }
    }
    if (-not $claudeCandidates) { return $null }

    # Collect unique (project-dir, cwd) pairs from candidate CWDs. We keep
    # the cwd around so the CWD-basename fallback (below) can compare the
    # WT tab name against directory leaves.
    $candidatePairs = [System.Collections.Generic.List[object]]::new()
    $seenPaths      = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($c in $claudeCandidates) {
        $cwd = $null
        try { $cwd = [LatexPopup.Native]::GetProcessCwd([int]$c.ProcessId) } catch { Log "  PEB read pid=$($c.ProcessId) threw: $_" }
        Log "  pid=$($c.ProcessId)  CWD='$cwd'"
        if (-not $cwd) { continue }
        $pd = Resolve-ClaudeProjectDirForCwd -cwd $cwd -projectsRoot $projectsRoot
        if (-not $pd) { continue }
        if ($seenPaths.Add($pd)) {
            [void]$candidatePairs.Add([pscustomobject]@{ Path = $pd; Cwd = $cwd })
        }
    }
    Log "Candidate project dirs: $($candidatePairs.Count)"

    $projectDirs = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $candidatePairs) { [void]$projectDirs.Add($p.Path) }

    # Title sources: foreground window title, then WT selected-tab name.
    $titleSources = @()
    if ($foregroundTitle) { $titleSources += $foregroundTitle }
    if ($wtTabName -and ($wtTabName -ne $foregroundTitle)) { $titleSources += $wtTabName }

    # PRIMARY signal: match each title against ai-title in candidate jsonls.
    foreach ($t in $titleSources) {
        $match = Find-ClaudeSessionByTitle -targetTitle $t -projectDirs $projectDirs
        if ($match) { return $match }
    }

    # SECONDARY signal: WT auto-set title vs CWD basename. Handles tab names
    # like '* filament' (spinner + project leaf) that the aiTitle path
    # cannot match because aiTitles are AI-generated descriptions, not
    # project names.
    foreach ($t in $titleSources) {
        $match = Find-ClaudeSessionByCwdBasename -targetTitle $t -candidatePairs $candidatePairs
        if ($match) { return $match }
    }

    # Newest-mtime fallback is only safe when the title is informative OR
    # there is exactly one candidate. With multiple candidates and a
    # generic foreground title ('Claude Code' default), the newest-mtime
    # pick tracks whichever session is actively streaming rather than
    # which tab is focused -- silently showing the wrong conversation is
    # worse than no popup.
    $allUninformative = $true
    foreach ($t in $titleSources) {
        $n = Normalize-ClaudeTitle $t
        if ($n -and ($n -ne 'claude code') -and ($n -ne 'claude')) {
            $allUninformative = $false
            break
        }
    }
    if ($allUninformative -and $candidatePairs.Count -gt 1) {
        Log "Foreground title uninformative; $($candidatePairs.Count) candidates -- refusing newest-mtime fallback"
        # Signal to show.ps1 that we deliberately refused so the global
        # newest-mtime fallback at the orchestrator level also stays gated.
        $script:FocusAmbiguous = $true
        return $null
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

    # Modal-first: plan-mode preview takes precedence over the latest assistant
    # turn. /aside is detected by text marker after the turn is extracted.
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
    if ($size -le 0) {
        Log "Parser[claude]: file=$($file.Name) is empty -- nothing to render"
        return ''
    }
    $chunkSize = [int][Math]::Min(500000, $size)
    # Minimum length for a candidate JSONL line. The shortest valid assistant
    # text line includes type/role/requestId envelope + text content; values
    # below this are partial / control / noise lines.
    $MIN_LINE_LEN = 80
    $stream = [System.IO.File]::Open($file.FullName, 'Open', 'Read', 'ReadWrite')
    try {
        if ($size -gt $chunkSize) {
            $stream.Seek(-$chunkSize, [System.IO.SeekOrigin]::End) | Out-Null
        }
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
        if ($line.Length -lt $MIN_LINE_LEN) { continue }
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
        if ($line.Length -lt $MIN_LINE_LEN) { continue }
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

    $turn = $sb.ToString()
    if (-not $turn) { return '' }

    # /btw and /aside detection -- look at the user message that PRECEDED this
    # assistant turn. /btw is a built-in Claude Code slash command; /aside is
    # a user-installed one. Neither gives the assistant response a recognizable
    # text prefix, so the only reliable signal is the user message that
    # triggered it.
    #
    # Scan backwards from the line that introduced the last requestId; the
    # first user message we hit is the prompt we're responding to.
    $lastUserText = $null
    $reachedReq   = $false
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i]
        if (-not $reachedReq) {
            if ($line.Contains($lastReqId)) { $reachedReq = $true }
            continue
        }
        if (-not $line.Contains('"type":"user"')) { continue }
        if (-not $line.Contains('"role":"user"')) { continue }
        try {
            $obj = $line | ConvertFrom-Json -ErrorAction Stop
            if ($obj.type -ne 'user' -or -not $obj.message) { continue }
            if ($obj.message.role -ne 'user') { continue }
            $content = $obj.message.content
            if ($content -is [string]) {
                $lastUserText = $content
            } elseif ($content) {
                foreach ($c in @($content)) {
                    if ($c.type -eq 'text' -and $c.text) {
                        $lastUserText = $c.text
                        break
                    }
                }
            }
            if ($lastUserText) { break }
        } catch { }
    }

    if ($lastUserText) {
        $trimmed = $lastUserText.TrimStart()
        if ($trimmed -match '^/(btw|aside)\b') {
            $cmd = $matches[1].ToLower()
            Log "Parser[claude]: /$cmd slash-command detected from user message"
            $tag    = if ($cmd -eq 'btw') { 'By the way' } else { 'Side question' }
            $header = "## /$cmd`r`n`r`n> $tag response`r`n`r`n"
            return $header + $turn
        }
    }

    return $turn
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
