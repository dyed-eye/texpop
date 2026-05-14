# adapters\codex.ps1 -- ChatSourceAdapter for OpenAI Codex CLI (experimental).
#
# Part of texpop (https://github.com/dyed-eye/texpop).
#
# Codex CLI repo: https://github.com/openai/codex
#
# Transcript layout (research notes -- VERIFY against a real install before
# trusting this adapter):
#   $env:CODEX_HOME              (default: $env:USERPROFILE\.codex)
#     \sessions\YYYY\MM\DD\rollout-YYYY-MM-DDThh-mm-ss-<sessionId>.jsonl
#
# Each line is a JSON object with three top-level wrapper fields:
#   type:      'session_start' | 'response_item' | 'event_msg' | 'turn_context' | ...
#   timestamp: ISO 8601 string
#   payload:   the actual event body
#
# Assistant text appears under 'response_item' lines whose payload looks like:
#   { "type":"message", "role":"assistant",
#     "content":[ { "type":"input_text" | "output_text", "text":"..." } ] }
#
# (The published documentation also references 'output_text'; we accept both
# 'input_text' and 'output_text' to be safe.)
#
# Sources used to build this adapter (cite for future maintainers):
#   https://developers.openai.com/codex/cli/features
#   https://developers.openai.com/codex/config-reference
#   https://developers.openai.com/codex/config-advanced
#   https://inventivehq.com/knowledge-base/openai/where-configuration-files-are-stored
#   https://inventivehq.com/knowledge-base/openai/how-to-resume-sessions
#   https://github.com/openai/codex/pull/14434          (RolloutLine schema PR)
#   https://github.com/openai/codex/discussions/3827    (Session/Rollout files)
#   https://betelgeuse.work/codex-resume/               (Rollout JSONL anatomy)
#
# TODO: verify against real Codex CLI transcript -- payload field names and
# nested 'content' shape are based on docs + a third-party blog post, not on a
# parsed real file. If Codex changes the schema, update the parser.
#
# Dot-sourced from show.ps1; depends on:
#   - $script:Adapters : array, this file appends to it
#   - Log              : function defined in show.ps1

# ---------- Helpers (Codex-specific) ----------

function Get-CodexSessionsRoot {
    if ($env:CODEX_HOME) {
        return (Join-Path $env:CODEX_HOME 'sessions')
    }
    return (Join-Path $env:USERPROFILE '.codex\sessions')
}

function Find-CodexNewestRollout {
    param([string]$sessionsRoot)
    if (-not (Test-Path $sessionsRoot)) { return $null }
    Get-ChildItem -Path $sessionsRoot -Filter 'rollout-*.jsonl' -File -Recurse `
        -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

# ---------- Adapter scriptblocks ----------

$codexMatch = {
    param($candidates)
    foreach ($c in $candidates) {
        $name = if ($c.Name) { $c.Name.ToLower() } else { '' }
        $cmd  = if ($c.CommandLine) { $c.CommandLine } else { '' }
        if ($name -eq 'codex.exe') { return $true }
        # node-hosted codex CLI variant; match 'codex' as a whole word so we
        # don't grab unrelated 'node.exe' processes that just happen to have
        # 'codex' substring inside a path.
        if (($name -eq 'node.exe') -and ($cmd -match '(?i)\bcodex\b')) { return $true }
    }
    return $false
}

$codexFindFocused = {
    # $wtOtherTabs is accepted for adapter-contract symmetry but unused: the
    # Codex rollout layout isn't keyed by chat title, so other-window tab
    # names don't help disambiguate.
    param($candidates, $foregroundTitle, $wtTabName, $wtOtherTabs)

    $sessionsRoot = Get-CodexSessionsRoot
    Log "Codex sessions root: $sessionsRoot"
    if (-not (Test-Path $sessionsRoot)) {
        Log "Codex adapter: sessions root does not exist; skipping"
        return $null
    }

    # Filter candidates down to Codex-specific ones. We don't currently use
    # CWD to scope Codex transcripts (the date-based rollout layout is not
    # keyed by working directory). The earlier diagnostic loop that read CWDs
    # via PEB and discarded them was removed -- it cost one cross-process read
    # per candidate per hotkey press for no benefit.
    $codexCandidates = @()
    foreach ($c in $candidates) {
        $name = if ($c.Name) { $c.Name.ToLower() } else { '' }
        $cmd  = if ($c.CommandLine) { $c.CommandLine } else { '' }
        $isCodex = ($name -eq 'codex.exe') -or
                   (($name -eq 'node.exe') -and ($cmd -match '(?i)\bcodex\b'))
        if ($isCodex) { $codexCandidates += $c }
    }
    Log "Codex candidates: $($codexCandidates.Count)"

    # TODO: if Codex starts emitting a 'session_id' or window title we can map
    # back to a rollout file, use $foregroundTitle / $wtTabName here. For now
    # the most recently modified rollout is the closest proxy for 'focused'.
    $newest = Find-CodexNewestRollout -sessionsRoot $sessionsRoot
    if ($newest) {
        Log "Codex adapter chose newest rollout: $($newest.FullName)"
    } else {
        Log "Codex adapter: no rollout-*.jsonl files under $sessionsRoot"
    }
    return $newest
}

$codexGetLastAssistantTurn = {
    param([System.IO.FileInfo]$file)

    # Codex rollout files tend to be small. Above ~2 MB switch to a tail read
    # so the popup latency stays bounded if a long-running session grows.
    $maxFull = 2 * 1024 * 1024
    $text = $null
    try {
        if ($file.Length -le $maxFull) {
            $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
        } else {
            $stream = [System.IO.File]::Open($file.FullName, 'Open', 'Read', 'ReadWrite')
            try {
                $stream.Seek(-$maxFull, [System.IO.SeekOrigin]::End) | Out-Null
                $buf = [byte[]]::new($maxFull)
                [void]$stream.Read($buf, 0, $maxFull)
                $text = [System.Text.Encoding]::UTF8.GetString($buf)
            } finally { $stream.Dispose() }
            # Drop the partial first line introduced by the seek.
            $nl = $text.IndexOf("`n")
            if ($nl -gt 0) { $text = $text.Substring($nl + 1) }
        }
    } catch {
        Log "Parser[codex]: read failed: $_"
        return ''
    }
    $lines = $text.Split([char]"`n")
    Log "Parser[codex]: file=$($file.Name) size=$($file.Length) lines=$($lines.Count)"

    # Walk backward, find the last 'response_item' line whose payload is an
    # assistant message, and concatenate all 'text' fields from its content[].
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i]
        if (-not $line) { continue }
        if (-not $line.Contains('"role":"assistant"')) { continue }
        try {
            $obj = $line | ConvertFrom-Json -ErrorAction Stop
        } catch { continue }

        # Two shapes are plausible:
        #   1. wrapped: { type:"response_item", payload:{ type:"message", role:"assistant", content:[...] } }
        #   2. flat:    { type:"message", role:"assistant", content:[...] }
        $payload = $null
        if ($obj.payload) {
            $payload = $obj.payload
        } else {
            $payload = $obj
        }
        if (-not $payload) { continue }
        if ($payload.role -ne 'assistant') { continue }
        if (-not $payload.content) { continue }

        $sb = [System.Text.StringBuilder]::new()
        foreach ($c in @($payload.content)) {
            if (-not $c) { continue }
            $ctype = $c.type
            # Accept any of the text-bearing variants the docs reference.
            if ($ctype -eq 'input_text' -or $ctype -eq 'output_text' -or $ctype -eq 'text') {
                if ($c.text) { [void]$sb.Append($c.text) }
            }
        }
        $result = $sb.ToString()
        if (-not [string]::IsNullOrWhiteSpace($result)) {
            Log "Parser[codex]: matched assistant turn at line $i (length $($result.Length))"
            return $result
        }
    }

    Log "Parser[codex]: no assistant turn found"
    return ''
}

$script:Adapters += @(
    @{
        Name                 = 'codex'
        Description          = 'OpenAI Codex CLI (~/.codex/sessions/.../rollout-*.jsonl) -- experimental'
        Match                = $codexMatch
        FindFocusedSession   = $codexFindFocused
        GetLastAssistantTurn = $codexGetLastAssistantTurn
    }
)
