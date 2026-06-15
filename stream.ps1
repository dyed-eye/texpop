# stream.ps1 -- Persistent "stream mode" companion for texpop.
#
# Part of texpop (https://github.com/dyed-eye/texpop).
#
# Unlike show.ps1 (fire-and-forget: one detection, one render, one Edge popup
# that closes on Esc), stream.ps1 is a LONG-LIVED process:
#
#   1. Resolve the focused chat ONCE (delegated to show.ps1 -ResolveOnly so the
#      whole detection cascade is reused, not duplicated). Pin that session.
#   2. Stand up a loopback HTTP server on 127.0.0.1:<ephemeral> guarded by a
#      random path token. It serves the stream page + vendored assets, and a
#      /latest endpoint that re-parses the pinned transcript on demand.
#   3. Launch an Edge --app window docked as a companion panel beside the
#      terminal. The page polls /latest ~every 800ms and re-renders when the
#      pinned chat's last answer changes.
#   4. Pressing the stream hotkey again launches a SECOND stream.ps1 which finds
#      this live server (via the lock file), tells it to re-pin to the
#      now-focused chat, repositions + focuses the existing window, and exits.
#
# Why loopback + a random token (not file://): a file:// page cannot fetch()
# local files (Chromium CORS), so live updates need an HTTP origin. The server
# binds ONLY to 127.0.0.1 -- it is never on the network. The token + OS ACLs
# gate same-host access; content is your own transcript, already on disk.
#
# Proxy note: the Edge instance is launched with --no-proxy-server because it
# only ever talks to 127.0.0.1; loopback bypass is also implicit in Chromium,
# but the flag makes it unconditional. The server's own loopback client
# (re-pin / liveness) sets HttpWebRequest.Proxy = $null for the same reason.
#
# ASCII-only, PowerShell 5.1 compatible, logging only via Log (the process runs
# -WindowStyle Hidden so console output is invisible).

[CmdletBinding()]
param(
    [string]$ProjectsRoot,
    # Test override: pin directly to this jsonl and skip detection.
    [string]$SessionPath,
    # Adapter name to pair with -SessionPath (default claude-code).
    [string]$AdapterName = 'claude-code',
    # Test: stand up the server but do not launch Edge / position a window.
    [switch]$NoLaunch,
    # Seconds of polling silence after which the server assumes the window
    # was closed and shuts down. The page polls ~every 800ms.
    [int]$IdleTimeoutSec = 12
)

$ErrorActionPreference = 'Stop'

$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$template    = Join-Path $scriptDir 'stream-template.html'
$showPs1     = Join-Path $scriptDir 'show.ps1'
$logPath     = Join-Path $env:TEMP 'texpop-stream.log'
# Lock holds the live port + token; keep it in %LOCALAPPDATA% (always per-user)
# rather than %TEMP% (which can be a shared C:\Windows\Temp on multi-user boxes)
# so other local accounts can't read the token and hit /repin.
$texpopLocal = Join-Path $env:LOCALAPPDATA 'texpop'
try { if (-not (Test-Path $texpopLocal)) { New-Item -ItemType Directory -Force -Path $texpopLocal | Out-Null } } catch { }
$script:lockPath   = Join-Path $texpopLocal 'texpop-stream.lock'
$script:vendorDir  = Join-Path $scriptDir 'vendor'
$script:assetsDir  = Join-Path $scriptDir 'assets'

if (-not $ProjectsRoot) {
    $ProjectsRoot = Join-Path $env:USERPROFILE '.claude\projects'
}

# ---------- Logging ----------
function Log {
    param([string]$msg)
    $stamp = (Get-Date).ToString('HH:mm:ss.fff')
    try {
        [System.IO.File]::AppendAllText($logPath, "[$stamp] $msg`r`n",
            [System.Text.UTF8Encoding]::new($false))
    } catch { }
}
# Keep the log from growing without bound across many long-lived runs.
try {
    if ((Test-Path -LiteralPath $logPath) -and ((Get-Item -LiteralPath $logPath).Length -gt 1048576)) {
        Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
    }
} catch { }
Log "=== texpop stream.ps1 run (pid $PID) ==="

function Fail($msg) {
    Log "FAIL: $msg"
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show("texpop stream: $msg`n`nSee log: $logPath", 'texpop', 'OK', 'Error') | Out-Null
    } catch { }
    exit 1
}

# ---------- Native: window find / position / monitor work area ----------
if (-not ('TexpopStream.Native' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace TexpopStream {
public static class Native {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)]
    public struct MONITORINFO {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
    }

    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder s, int max);
    [DllImport("user32.dll")]
    public static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int X, int Y, int cx, int cy, uint flags);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")]
    public static extern IntPtr MonitorFromPoint(POINT pt, uint flags);
    [DllImport("user32.dll")]
    public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO mi);

    private static readonly IntPtr DPI_PER_MON_V2 = new IntPtr(-4);

    public static IntPtr[] FindMsedgeWindowsByTitle(string substr) {
        var list = new System.Collections.Generic.List<IntPtr>();
        EnumWindows((h, l) => {
            if (!IsWindowVisible(h)) return true;
            int len = GetWindowTextLength(h);
            if (len <= 0) return true;
            var sb = new StringBuilder(len + 1);
            GetWindowText(h, sb, sb.Capacity);
            if (sb.ToString().IndexOf(substr, StringComparison.OrdinalIgnoreCase) < 0) return true;
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            try {
                var p = System.Diagnostics.Process.GetProcessById((int)pid);
                if (string.Equals(p.ProcessName, "msedge", StringComparison.OrdinalIgnoreCase)) list.Add(h);
            } catch { }
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }

    public static int CloseMsedgeWindowsByTitle(string substr) {
        var t = FindMsedgeWindowsByTitle(substr);
        foreach (var h in t) SendMessage(h, 0x0010, IntPtr.Zero, IntPtr.Zero); // WM_CLOSE
        return t.Length;
    }

    public static RECT GetWorkArea(int cx, int cy) {
        try { SetThreadDpiAwarenessContext(DPI_PER_MON_V2); } catch { }
        POINT pt; pt.X = cx; pt.Y = cy;
        IntPtr mon = MonitorFromPoint(pt, 2); // MONITOR_DEFAULTTONEAREST
        MONITORINFO mi = new MONITORINFO();
        mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
        RECT r = new RECT();
        if (GetMonitorInfo(mon, ref mi)) { r = mi.rcWork; }
        return r;
    }
}}
'@ -ErrorAction Stop
}

# ---------- Loopback client (proxy-bypassed) ----------
function Send-LoopbackGet {
    param([string]$url)
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        # Loopback only: never route through the system proxy.
        $req.Proxy = $null
        $req.Timeout = 2500
        $req.Method = 'GET'
        $resp = $req.GetResponse()
        $resp.Close()
        return $true
    } catch {
        Log "Loopback GET failed ($url): $_"
        return $false
    }
}

# ---------- Lock file ----------
function Read-Lock {
    if (-not (Test-Path -LiteralPath $script:lockPath -PathType Leaf)) { return $null }
    try {
        return (Get-Content -LiteralPath $script:lockPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
    } catch { return $null }
}

function Test-ServerAlive {
    param($lock)
    if ($null -eq $lock) { return $false }
    if ($null -eq $lock.pid) { return $false }
    $p = Get-Process -Id ([int]$lock.pid) -ErrorAction SilentlyContinue
    if ($null -eq $p) { return $false }
    if (-not $lock.port -or -not $lock.token) { return $false }
    # Confirm the process is actually our server by hitting /latest with the
    # recorded token (guards against PID reuse and stale locks).
    $u = "http://127.0.0.1:$($lock.port)/$($lock.token)/latest"
    return (Send-LoopbackGet $u)
}

function Write-Lock {
    param([int]$port, [string]$token, [string]$session)
    try {
        $obj = @{ port = $port; token = $token; pid = $PID; session = $session }
        [System.IO.File]::WriteAllText($script:lockPath, (ConvertTo-Json $obj -Compress),
            [System.Text.UTF8Encoding]::new($false))
    } catch { Log "Write-Lock failed: $_" }
}

# ---------- Detection (delegated to show.ps1 -ResolveOnly) ----------
function Resolve-FocusedChat {
    if (-not (Test-Path -LiteralPath $showPs1 -PathType Leaf)) {
        Log "Resolve: show.ps1 not found at $showPs1"
        return $null
    }
    $psExe = $null
    try { $psExe = (Get-Process -Id $PID).Path } catch { }
    if (-not $psExe) { $psExe = 'powershell.exe' }
    $raw = $null
    try {
        $raw = & $psExe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden `
            -File $showPs1 -ResolveOnly -ProjectsRoot $ProjectsRoot 2>$null
    } catch {
        Log "Resolve: show.ps1 -ResolveOnly threw: $_"
        return $null
    }
    # Take the last line that looks like a JSON object.
    $jsonLine = $null
    foreach ($ln in @($raw)) {
        $t = ([string]$ln).Trim()
        if ($t.StartsWith('{') -and $t.EndsWith('}')) { $jsonLine = $t }
    }
    if (-not $jsonLine) { Log "Resolve: no JSON line from show.ps1 -ResolveOnly"; return $null }
    $obj = $null
    try { $obj = $jsonLine | ConvertFrom-Json -ErrorAction Stop } catch { Log "Resolve: JSON parse failed: $_"; return $null }
    if ($obj.error)   { Log "Resolve: detection error: $($obj.error)"; return $null }
    if ($obj.aborted) { Log "Resolve: detection aborted (ambiguous focus)"; return $null }
    if (-not $obj.session) { Log "Resolve: no session in result"; return $null }
    Log "Resolve: session=$($obj.session) adapter=$($obj.adapter)"
    return $obj
}

# ---------- Companion geometry ----------
function Compute-CompanionGeom {
    # Returns a hashtable of physical + DIP rects for a right-docked panel on
    # the terminal's monitor, or $null when the rect is unusable.
    param($rect, [int]$dpi)
    if ($null -eq $rect) { return $null }
    $scale = 1.0
    if ($dpi -gt 0) { $scale = $dpi / 96.0 }
    $cx = [int]([Math]::Round((([double]$rect.left) + ([double]$rect.right)) / 2.0))
    $cy = [int]([Math]::Round((([double]$rect.top) + ([double]$rect.bottom)) / 2.0))
    $work = $null
    try { $work = [TexpopStream.Native]::GetWorkArea($cx, $cy) } catch { Log "GetWorkArea threw: $_"; return $null }
    $wl = [int]$work.Left; $wt = [int]$work.Top; $wr = [int]$work.Right; $wb = [int]$work.Bottom
    $workW = $wr - $wl
    $workH = $wb - $wt
    if ($workW -le 0 -or $workH -le 0) { return $null }

    $panelW = [int]([Math]::Round(0.40 * $workW))
    $minW = [int]([Math]::Round(420 * $scale))
    $maxW = [int]([Math]::Round(760 * $scale))
    if ($panelW -lt $minW) { $panelW = $minW }
    if ($panelW -gt $maxW) { $panelW = $maxW }
    if ($panelW -gt $workW) { $panelW = $workW }

    $px = $wr - $panelW
    $py = $wt
    $pw = $panelW
    $ph = $workH

    return @{
        Xphys = $px; Yphys = $py; Wphys = $pw; Hphys = $ph
        Xdip  = [int]([Math]::Round($px / $scale))
        Ydip  = [int]([Math]::Round($py / $scale))
        Wdip  = [int]([Math]::Round($pw / $scale))
        Hdip  = [int]([Math]::Round($ph / $scale))
    }
}

function Try-PositionStreamWindow {
    # ONE non-blocking attempt to find + dock + focus the stream window.
    # Returns the HWND on success, [IntPtr]::Zero if the window isn't up yet.
    # The window only acquires its 'TeXpop Stream' title once the page loads,
    # which requires the server to already be answering requests -- so this is
    # driven from the serve loop, NOT blocked on before it.
    param($geom)
    $wins = [TexpopStream.Native]::FindMsedgeWindowsByTitle('TeXpop Stream')
    if (-not $wins -or $wins.Count -eq 0) { return [IntPtr]::Zero }
    $h = $wins[0]
    [TexpopStream.Native]::ShowWindow($h, 5) | Out-Null  # SW_SHOW
    if ($null -ne $geom) {
        # SWP_NOZORDER = 0x0004
        [TexpopStream.Native]::SetWindowPos($h, [IntPtr]::Zero, $geom.Xphys, $geom.Yphys, $geom.Wphys, $geom.Hphys, 0x0004) | Out-Null
        Log "Positioned stream window: $($geom.Xphys),$($geom.Yphys) size $($geom.Wphys)x$($geom.Hphys)"
    }
    # Briefly topmost to lift z-order, then back to normal (focusable).
    # HWND_TOPMOST = -1, HWND_NOTOPMOST = -2, SWP_NOMOVE|SWP_NOSIZE = 0x0003
    [TexpopStream.Native]::SetWindowPos($h, [IntPtr]-1, 0, 0, 0, 0, 0x0003) | Out-Null
    Start-Sleep -Milliseconds 25
    [TexpopStream.Native]::SetWindowPos($h, [IntPtr]-2, 0, 0, 0, 0, 0x0003) | Out-Null
    [TexpopStream.Native]::BringWindowToTop($h) | Out-Null
    [TexpopStream.Native]::SetForegroundWindow($h) | Out-Null
    return $h
}

function Position-StreamWindow {
    # Blocking poll wrapper, used ONLY by the re-pin path (where the window
    # already exists, so it returns on the first attempt). The fresh-launch path
    # positions opportunistically from inside the serve loop instead.
    param($geom, [int]$maxAttempts = 60)
    for ($i = 0; $i -lt $maxAttempts; $i++) {
        $h = Try-PositionStreamWindow $geom
        if ($h -ne [IntPtr]::Zero) { return $h }
        Start-Sleep -Milliseconds 200
    }
    Log "Stream window never appeared after $maxAttempts attempts"
    return [IntPtr]::Zero
}

# ---------- Edge ----------
function Find-Edge {
    $cands = @(
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe"
    )
    foreach ($p in $cands) { if (Test-Path $p) { return $p } }
    return $null
}

function Launch-Edge {
    param([string]$url, $geom)
    $edge = Find-Edge
    if (-not $edge) {
        Fail "Microsoft Edge not found. Install Edge or symlink msedge.exe into Program Files\Microsoft\Edge\Application."
    }
    $userDataDir = Join-Path $env:LOCALAPPDATA 'texpop\edge-stream-profile-v1'
    if (-not (Test-Path $userDataDir)) {
        New-Item -ItemType Directory -Force -Path $userDataDir | Out-Null
    }
    $edgeArgs = @(
        "--app=$url",
        "--user-data-dir=$userDataDir",
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-features=Translate',
        # This window only ever talks to 127.0.0.1; ignore the system proxy
        # entirely so a MITM/loopback-intercepting proxy can't touch it.
        '--no-proxy-server',
        # Keep the renderer + timers alive while the window sits in the
        # background (the whole point: it updates while you work in the
        # terminal). Without these, Chromium throttles setTimeout/polling.
        '--disable-renderer-backgrounding',
        '--disable-background-timer-throttling',
        '--disable-backgrounding-occluded-windows'
    )
    if ($null -ne $geom) {
        $edgeArgs += "--window-size=$($geom.Wdip),$($geom.Hdip)"
        $edgeArgs += "--window-position=$($geom.Xdip),$($geom.Ydip)"
    }
    Start-Process -FilePath $edge -ArgumentList $edgeArgs | Out-Null
    Log "Launched Edge stream window -> $url"
}

# ---------- Adapters (for re-parsing the pinned transcript) ----------
$script:Adapters = @()
$script:ClaudeProjectsRoot = $ProjectsRoot
# NOTE: adapters are dot-sourced INLINE at script scope in the fresh-server path
# below -- deliberately NOT wrapped in a function. Dot-sourcing inside a function
# defines the adapter helper functions (Resolve-ClaudeForkLeaf,
# Get-ClaudeActiveModalContent, Read-ClaudeJsonlTail, ...) in that function's
# local scope, where they vanish on return; the stored GetLastAssistantTurn
# scriptblock would then throw "not recognized" at serve time. show.ps1
# dot-sources at script scope for exactly this reason.

# ---------- Pin state ----------
$script:pinnedBase        = $null
$script:pinnedAdapterName = $null
$script:pinnedTurnBlock   = $null
$script:cacheLeafPath     = $null
$script:cacheMtime        = $null
$script:cacheExchanges    = @()     # [{prompt; answer}] -- one navigable page each
$script:cacheCount        = 0

function Set-Pin {
    param([string]$path, [string]$adapterName)
    $fi = $null
    try { $fi = Get-Item -LiteralPath $path -ErrorAction Stop } catch { Log "Set-Pin: cannot open $path"; return $false }
    $ad = $script:Adapters | Where-Object { $_.Name -eq $adapterName } | Select-Object -First 1
    if ($null -eq $ad) { $ad = $script:Adapters | Where-Object { $_.Name -eq 'claude-code' } | Select-Object -First 1 }
    if ($null -eq $ad) { Log "Set-Pin: no adapter available"; return $false }
    $script:pinnedBase        = $fi
    $script:pinnedAdapterName = $ad.Name
    # IMPORTANT: only GetLastAssistantTurn may be invoked against adapters in
    # this process. Match / FindFocusedSession reference [LatexPopup.Native],
    # which is defined in show.ps1, NOT here (stream.ps1 compiles
    # [TexpopStream.Native] instead). Detection is delegated to show.ps1
    # -ResolveOnly precisely so those blocks never run in stream.ps1's process.
    $script:pinnedTurnBlock   = $ad.GetLastAssistantTurn
    $script:cacheLeafPath     = $null
    $script:cacheMtime        = $null
    $script:cacheExchanges    = @()
    $script:cacheCount        = 0
    Log "Pinned: $($fi.FullName) (adapter=$($ad.Name))"
    return $true
}

# Parse the tail of a claude jsonl into an ORDERED list of conversation
# messages: real user prompts and assistant answers, each as markdown. Skips
# tool_result user lines and pure tool_use assistant turns (no text). Assistant
# turns spanning multiple lines (same requestId) are merged. Returns an array of
# hashtables @{ role='user'|'assistant'; markdown='...' }.
function Get-ClaudeMessages {
    param([System.IO.FileInfo]$file)
    $out = [System.Collections.Generic.List[object]]::new()
    $lines = $null
    try { $lines = Read-ClaudeJsonlTail -file $file } catch { return @() }
    if (-not $lines -or $lines.Count -eq 0) { return @() }
    $curReq = $null
    foreach ($line in $lines) {
        if (-not $line) { continue }
        if ($line.Length -lt 40) { continue }
        $isUser = $line.Contains('"type":"user"') -and $line.Contains('"role":"user"')
        $isAsst = $line.Contains('"type":"assistant"') -and $line.Contains('"role":"assistant"')
        if (-not $isUser -and -not $isAsst) { continue }
        $obj = $null
        try { $obj = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if (-not $obj.message) { continue }
        $role = $obj.message.role

        if ($role -eq 'user') {
            $content = $obj.message.content
            $txt = $null
            if ($content -is [string]) {
                $txt = $content
            } elseif ($content) {
                $sb = [System.Text.StringBuilder]::new()
                foreach ($c in @($content)) {
                    if ($c.type -eq 'text' -and $c.text) { [void]$sb.Append($c.text) }
                }
                if ($sb.Length -gt 0) { $txt = $sb.ToString() }
            }
            # Only real prompts (tool_result-only user lines yield no text).
            if ($txt -and $txt.Trim()) {
                $curReq = $null  # a user message ends any assistant turn grouping
                [void]$out.Add(@{ role = 'user'; markdown = $txt })
            }
        } elseif ($role -eq 'assistant') {
            $req = $null
            $m = [regex]::Match($line, '"requestId":"([^"]+)"')
            if ($m.Success) { $req = $m.Groups[1].Value }
            $sb = [System.Text.StringBuilder]::new()
            if ($obj.message.content) {
                foreach ($c in @($obj.message.content)) {
                    if ($c.type -eq 'text' -and $c.text) { [void]$sb.Append($c.text) }
                }
            }
            $txt = $sb.ToString()
            if (-not $txt) { continue }  # pure tool_use turn -- nothing to show
            if ($req -and $req -eq $curReq -and $out.Count -gt 0 -and $out[$out.Count - 1].role -eq 'assistant') {
                $out[$out.Count - 1].markdown += $txt
            } else {
                $curReq = $req
                [void]$out.Add(@{ role = 'assistant'; markdown = $txt })
            }
        }
    }
    # Emit the hashtables as individual pipeline items (NO leading comma): the
    # caller collects them with @(...). A leading-comma "return ,$arr" would make
    # the caller's @() wrap the whole array as a SINGLE element, collapsing every
    # message into one and string-joining them.
    return $out.ToArray()
}

function Get-CurrentState {
    # Re-resolve the fork leaf (claude branches create a new jsonl), check mtime,
    # and re-parse only when the file actually changed. Populates the message
    # list + the latest-message view used by /msg and /latest. The latest view
    # is messages[count-1] so position indices and live-follow stay consistent;
    # GetLastAssistantTurn is the fallback if the message parse yields nothing.
    $leaf = $script:pinnedBase
    if ($null -eq $leaf) { return }
    if ($script:pinnedAdapterName -eq 'claude-code') {
        try {
            $dir = Split-Path -Parent $script:pinnedBase.FullName
            $resolved = Resolve-ClaudeForkLeaf -baseJsonl $script:pinnedBase -projectDir $dir
            if ($resolved) { $leaf = $resolved }
        } catch { Log "fork-leaf resolve threw: $_" }
    }
    try { $leaf = Get-Item -LiteralPath $leaf.FullName -ErrorAction Stop } catch { return }
    $mtime = $leaf.LastWriteTimeUtc
    if ($script:cacheLeafPath -eq $leaf.FullName -and $script:cacheMtime -eq $mtime) { return }

    $msgs = @()
    if ($script:pinnedAdapterName -eq 'claude-code') {
        try { $msgs = @(Get-ClaudeMessages -file $leaf) } catch { Log "messages parse threw: $_"; $msgs = @() }
    }
    if (-not $msgs -or $msgs.Count -eq 0) {
        # Non-claude adapter, or parse failure: fall back to the proven last-turn
        # extractor (modal/aside aware) as a single-item list.
        $rich = ''
        try { $rich = & $script:pinnedTurnBlock $leaf } catch { Log "latest parse threw: $_" }
        if ($rich) { $msgs = @(@{ role = 'assistant'; markdown = $rich }) }
    }

    # Group messages into exchanges: each user prompt plus the assistant turns
    # that follow it (until the next prompt) is one navigable page, so a question
    # and its answer render together.
    $exs = [System.Collections.Generic.List[object]]::new()
    $cur = $null
    foreach ($m in $msgs) {
        if ($m.role -eq 'user') {
            if ($null -ne $cur) { [void]$exs.Add($cur) }
            $cur = @{ prompt = [string]$m.markdown; answer = '' }
        } else {
            if ($null -eq $cur) { $cur = @{ prompt = ''; answer = '' } }
            if ($cur.answer) { $cur.answer = $cur.answer + "`n`n" }
            $cur.answer = $cur.answer + [string]$m.markdown
        }
    }
    if ($null -ne $cur) { [void]$exs.Add($cur) }

    $script:cacheLeafPath  = $leaf.FullName
    $script:cacheMtime     = $mtime
    $script:cacheExchanges = $exs.ToArray()
    $script:cacheCount     = $script:cacheExchanges.Count
}

# ---------- HTTP serving ----------
function Get-ContentType {
    param([string]$path)
    switch ([System.IO.Path]::GetExtension($path).ToLower()) {
        '.css'   { return 'text/css; charset=utf-8' }
        '.js'    { return 'application/javascript; charset=utf-8' }
        '.woff2' { return 'font/woff2' }
        '.woff'  { return 'font/woff' }
        '.ttf'   { return 'font/ttf' }
        '.svg'   { return 'image/svg+xml' }
        '.ico'   { return 'image/x-icon' }
        '.png'   { return 'image/png' }
        '.jpg'   { return 'image/jpeg' }
        '.json'  { return 'application/json; charset=utf-8' }
        '.html'  { return 'text/html; charset=utf-8' }
        default  { return 'application/octet-stream' }
    }
}

function Write-Http {
    param($ns, [int]$status, [string]$ctype, [byte[]]$body, [string]$statusText = 'OK')
    if ($null -eq $body) { $body = New-Object byte[] 0 }
    $head = "HTTP/1.1 $status $statusText`r`n" +
            "Content-Type: $ctype`r`n" +
            "Content-Length: $($body.Length)`r`n" +
            "Cache-Control: no-store`r`n" +
            "Connection: close`r`n`r`n"
    $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
    try {
        $ns.Write($hb, 0, $hb.Length)
        if ($body.Length -gt 0) { $ns.Write($body, 0, $body.Length) }
        $ns.Flush()
    } catch { }
}

function Bytes { param([string]$s) return [System.Text.Encoding]::UTF8.GetBytes($s) }

function Close-Client {
    # Graceful HTTP/1.1 "Connection: close" teardown: half-close the send side
    # (FIN), drain any trailing bytes the client already sent, then close. A
    # bare Close() can RST and truncate the response if the peer still has
    # unread data queued -- rare on loopback, but this is the correct sequence.
    param($client)
    try { $client.Client.Shutdown([System.Net.Sockets.SocketShutdown]::Send) } catch { }
    try {
        $ns = $client.GetStream()
        $client.ReceiveTimeout = 150
        $drain = New-Object byte[] 2048
        $drained = 0
        while ($ns.DataAvailable -and $drained -lt 65536) {
            $dn = $ns.Read($drain, 0, $drain.Length)
            if ($dn -le 0) { break }
            $drained += $dn
        }
    } catch { }
    try { $client.Close() } catch { }
}

function Serve-File {
    param($ns, [string]$path)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Log "404 (missing file): $path"
        Write-Http $ns 404 'text/plain; charset=utf-8' (Bytes 'not found') 'Not Found'; return
    }
    $bytes = $null
    try { $bytes = [System.IO.File]::ReadAllBytes($path) } catch {
        Write-Http $ns 500 'text/plain; charset=utf-8' (Bytes 'read error') 'Internal Server Error'; return
    }
    Write-Http $ns 200 (Get-ContentType $path) $bytes
}

function Serve-Static {
    param($ns, [string]$baseDir, [string]$rel)
    $rel = $rel -replace '/', '\'
    if ($rel.Contains('..')) { Write-Http $ns 400 'text/plain; charset=utf-8' (Bytes 'bad path') 'Bad Request'; return }
    $full = Join-Path $baseDir $rel
    $fullR = $null; $baseR = $null
    try {
        $fullR = [System.IO.Path]::GetFullPath($full)
        # Trailing separator defeats the prefix-collision bug: without it,
        # "<dir>\vendor" would also match a sibling "<dir>\vendorX\evil".
        $baseR = [System.IO.Path]::GetFullPath($baseDir).TrimEnd('\', '/') + '\'
    } catch { Write-Http $ns 400 'text/plain; charset=utf-8' (Bytes 'bad path') 'Bad Request'; return }
    if (-not $fullR.StartsWith($baseR, [System.StringComparison]::OrdinalIgnoreCase)) {
        Log "404 (path escape): rel='$rel'"
        Write-Http $ns 404 'text/plain; charset=utf-8' (Bytes 'not found') 'Not Found'; return
    }
    Serve-File $ns $fullR
}

function Parse-Query {
    param([string]$query)
    $h = @{}
    if (-not $query) { return $h }
    foreach ($pair in ($query -split '&')) {
        if (-not $pair) { continue }
        $kv = $pair -split '=', 2
        $key = $kv[0]
        $val = ''
        if ($kv.Count -gt 1) { try { $val = [uri]::UnescapeDataString($kv[1]) } catch { $val = $kv[1] } }
        if ($key) { $h[$key] = $val }
    }
    return $h
}

function Handle-Repin {
    param($ns, [string]$query)
    $q = Parse-Query $query
    $newPath = $q['path']
    $newAdapter = $q['adapter']
    if (-not $newAdapter) { $newAdapter = 'claude-code' }
    if ($newPath -and (Test-Path -LiteralPath $newPath -PathType Leaf)) {
        # Constrain the re-pin target to the projects root. Without this, a
        # token-bearing local process could re-point the server at an arbitrary
        # transcript-shaped file and read it back via /latest.
        $inScope = $false
        try {
            $projR = [System.IO.Path]::GetFullPath($ProjectsRoot).TrimEnd('\', '/') + '\'
            $npR   = [System.IO.Path]::GetFullPath($newPath)
            if ($npR.StartsWith($projR, [System.StringComparison]::OrdinalIgnoreCase)) { $inScope = $true }
        } catch { }
        if (-not $inScope) {
            Log "Repin refused (outside projects root): $newPath"
            Write-Http $ns 403 'text/plain; charset=utf-8' (Bytes 'forbidden') 'Forbidden'
            return
        }
        if (Set-Pin $newPath $newAdapter) {
            Write-Lock $script:port $script:token $newPath
            Write-Http $ns 200 'text/plain; charset=utf-8' (Bytes 'ok')
            return
        }
    }
    Log "Repin failed for path='$newPath'"
    Write-Http $ns 404 'text/plain; charset=utf-8' (Bytes 'repin failed') 'Not Found'
}

function Handle-Request {
    param($client)
    $client.ReceiveTimeout = 3000
    $client.SendTimeout = 5000
    $ns = $client.GetStream()
    $reqBuf = [System.Text.StringBuilder]::new(1024)
    $tmp = New-Object byte[] 8192
    try {
        # Read until the header terminator. Cap generously (32 * 8KB = 256KB) so
        # a long /repin ?path= query with URL-escaped separators is never
        # truncated mid-request-line; normal GETs hit the terminator in one read.
        # StringBuilder (not string +=) so a slow dribbling client can't make the
        # accumulation O(n^2).
        for ($k = 0; $k -lt 32; $k++) {
            $n = $ns.Read($tmp, 0, $tmp.Length)
            if ($n -le 0) { break }
            [void]$reqBuf.Append([System.Text.Encoding]::ASCII.GetString($tmp, 0, $n))
            if ($reqBuf.ToString().Contains("`r`n`r`n")) { break }
        }
    } catch { }
    $reqText = $reqBuf.ToString()
    if (-not $reqText) { return }

    $firstLine = ($reqText -split "`r`n", 2)[0]
    $sp = $firstLine.Split(' ')
    if ($sp.Count -lt 2) { Write-Http $ns 400 'text/plain; charset=utf-8' (Bytes 'bad request') 'Bad Request'; return }
    $rawPath = $sp[1]
    $pathOnly = $rawPath
    $query = ''
    $qi = $rawPath.IndexOf('?')
    if ($qi -ge 0) { $pathOnly = $rawPath.Substring(0, $qi); $query = $rawPath.Substring($qi + 1) }

    # Token gate: every path must begin with /<token>.
    $prefix = "/$($script:token)"
    if (-not $pathOnly.StartsWith($prefix)) {
        Log "REQ rejected (token mismatch): $pathOnly"
        Write-Http $ns 404 'text/plain; charset=utf-8' (Bytes 'not found') 'Not Found'; return
    }
    $sub = $pathOnly.Substring($prefix.Length)

    if ($sub -eq '' -or $sub -eq '/') {
        Write-Http $ns 200 'text/html; charset=utf-8' (Bytes $script:servedHtml); return
    }
    if ($sub -eq '/latest') {
        Get-CurrentState
        $cnt = $script:cacheCount
        $p = ''; $a = ''
        if ($cnt -gt 0) {
            $p = [string]$script:cacheExchanges[$cnt - 1].prompt
            $a = [string]$script:cacheExchanges[$cnt - 1].answer
        }
        $payload = ConvertTo-Json @{ count = $cnt; prompt = $p; answer = $a } -Compress
        Write-Http $ns 200 'application/json; charset=utf-8' (Bytes $payload); return
    }
    if ($sub -eq '/msg') {
        Get-CurrentState
        $qm = Parse-Query $query
        $idx = -1
        try { $idx = [int]$qm['i'] } catch { $idx = -1 }
        if ($idx -lt 0 -or $idx -ge $script:cacheCount) {
            Write-Http $ns 404 'text/plain; charset=utf-8' (Bytes 'no such page') 'Not Found'; return
        }
        $ex = $script:cacheExchanges[$idx]
        $payload = ConvertTo-Json @{ index = $idx; count = $script:cacheCount; prompt = [string]$ex.prompt; answer = [string]$ex.answer } -Compress
        Write-Http $ns 200 'application/json; charset=utf-8' (Bytes $payload); return
    }
    if ($sub -eq '/repin') { Handle-Repin $ns $query; return }
    if ($sub -eq '/favicon.ico') {
        if ($script:iconFile) { Serve-File $ns $script:iconFile }
        else { Write-Http $ns 404 'text/plain; charset=utf-8' (Bytes 'no icon') 'Not Found' }
        return
    }
    if ($sub.StartsWith('/vendor/')) { Serve-Static $ns $script:vendorDir $sub.Substring('/vendor/'.Length); return }
    if ($sub.StartsWith('/assets/')) { Serve-Static $ns $script:assetsDir $sub.Substring('/assets/'.Length); return }

    Write-Http $ns 404 'text/plain; charset=utf-8' (Bytes 'not found') 'Not Found'
}

# ==================== Main ====================

# ---- Re-pin path: a live server already owns the stream window. ----
$existing = Read-Lock
if ((-not $SessionPath) -and (Test-ServerAlive $existing)) {
    Log "Existing live server found (pid $($existing.pid), port $($existing.port)) -- re-pinning"
    $resolved = Resolve-FocusedChat
    if ($resolved -and $resolved.session) {
        $repinUrl = "http://127.0.0.1:$($existing.port)/$($existing.token)/repin?path=" +
            [uri]::EscapeDataString([string]$resolved.session) +
            "&adapter=" + [uri]::EscapeDataString([string]$resolved.adapter)
        $ok = Send-LoopbackGet $repinUrl
        Log "Re-pin sent (ok=$ok)"
        $geom = Compute-CompanionGeom $resolved.rect $resolved.dpi
        Position-StreamWindow $geom | Out-Null
    } else {
        Log "Re-pin: detection produced no session; focusing existing window only"
        Position-StreamWindow $null | Out-Null
    }
    exit 0
}

# ---- Fresh server path. ----
# Dot-source adapters at SCRIPT scope (see note by $script:Adapters above) so
# their helper functions persist for the GetLastAssistantTurn scriptblock when
# it runs in the serve loop.
$adapterDir = Join-Path $scriptDir 'adapters'
foreach ($adapterFile in @('claude-code.ps1', 'codex.ps1')) {
    $af = Join-Path $adapterDir $adapterFile
    if (-not (Test-Path -LiteralPath $af -PathType Leaf)) { continue }
    try { . $af; Log "Loaded adapter: $adapterFile" } catch { Log "Adapter load failed ($adapterFile): $_" }
}
Log "Adapters registered: $($script:Adapters.Count)"
if ($script:Adapters.Count -eq 0) { Fail "No chat adapters loaded; cannot parse transcripts." }

# Resolve the session to pin (detection, or the test override).
$rect = $null
$dpi = 96
$themeCss = ''
if ($SessionPath) {
    Log "Test mode: pinning -SessionPath directly ($SessionPath)"
    if (-not (Test-Path -LiteralPath $SessionPath -PathType Leaf)) { Fail "SessionPath not found: $SessionPath" }
    if (-not (Set-Pin $SessionPath $AdapterName)) { Fail "Could not pin session $SessionPath" }
} else {
    $resolved = Resolve-FocusedChat
    if (-not $resolved -or -not $resolved.session) {
        Log "No focused chat resolved; nothing to stream. Exiting."
        exit 0
    }
    if (-not (Set-Pin ([string]$resolved.session) ([string]$resolved.adapter))) { Fail "Could not pin resolved session." }
    $rect = $resolved.rect
    $dpi = if ($resolved.dpi) { [int]$resolved.dpi } else { 96 }
    if ($resolved.themeCss) { $themeCss = [string]$resolved.themeCss }
}

# Resolve favicon (user override wins over bundled default).
$script:iconFile = $null
foreach ($n in @('icon-override.svg','icon-override.png','icon-override.jpg','icon-override.ico','icon-default.ico','icon-default.png','icon-default.svg')) {
    $p = Join-Path $script:assetsDir $n
    if (Test-Path -LiteralPath $p -PathType Leaf) { $script:iconFile = $p; break }
}

# Random 128-bit path token (crypto RNG) -- gates same-host access to /latest.
$tokenBytes = New-Object byte[] 16
$rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
try { $rng.GetBytes($tokenBytes) } finally { $rng.Dispose() }
$script:token = -join ($tokenBytes | ForEach-Object { '{0:x2}' -f $_ })

# Build the served page once (placeholders -> token base + theme).
if (-not (Test-Path -LiteralPath $template -PathType Leaf)) { Fail "stream-template.html not found at $template" }
$tpl = Get-Content -LiteralPath $template -Raw -Encoding UTF8
# Defense-in-depth: themeCss is built from show.ps1's hex-validated palette, but
# never let a stray "</style" close the <style> block early.
if ($themeCss -match '(?i)</style') { $themeCss = '' }
$tpl = $tpl.Replace('THEME_CSS_PLACEHOLDER', $themeCss)
# Substitute the DISTINCT placeholder __STREAM_BASE__ (not bare STREAM_BASE):
# the page's JS uses a variable literally named STREAM_BASE, and replacing that
# token would rewrite the variable declaration into "const /<token> = ..." (a
# syntax error that kills the whole inline script).
$tpl = $tpl.Replace('__STREAM_BASE__', "/$($script:token)")
$script:servedHtml = $tpl

# Close any orphaned stream window from a previously-dead server so the
# position step below binds to OUR new window, not a stale one.
try {
    $closed = [TexpopStream.Native]::CloseMsedgeWindowsByTitle('TeXpop Stream')
    if ($closed -gt 0) { Log "Closed $closed orphaned stream window(s)"; Start-Sleep -Milliseconds 200 }
} catch { Log "Orphan close threw: $_" }

# Start the loopback listener on an OS-assigned ephemeral port, bound strictly
# to 127.0.0.1 (never reachable off-host).
$listener = $null
try {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
} catch { Fail "Could not start loopback listener: $_" }
$script:port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
Write-Lock $script:port $script:token $script:pinnedBase.FullName
Log "Loopback server listening on 127.0.0.1:$($script:port) (token len $($script:token.Length))"

$url = "http://127.0.0.1:$($script:port)/$($script:token)/"

$geom = $null
if (-not $NoLaunch) {
    $geom = Compute-CompanionGeom $rect $dpi
    Launch-Edge $url $geom
    # Do NOT block on positioning here: the serve loop must start answering
    # immediately so Edge can load the page. The window only gets its
    # 'TeXpop Stream' title after that load, so positioning is done
    # opportunistically inside the loop below once the title appears.
} else {
    Log "NoLaunch: server is up at $url (no Edge launched)"
}

# ---- Serve loop: parse-on-request + opportunistic positioning + idle shutdown ----
$idleSec = $IdleTimeoutSec
$startupGraceSec = 45
if ($NoLaunch) { $idleSec = 3600; $startupGraceSec = 3600 }  # test: stay up
$startTime = Get-Date
$lastReq = Get-Date
$gotFirst = $false
$positioned = $false
$positionDeadline = (Get-Date).AddSeconds(25)
$running = $true
while ($running) {
    $pending = $false
    try { $pending = $listener.Server.Poll(500000, [System.Net.Sockets.SelectMode]::SelectRead) } catch { Log "Listener Poll threw -- shutting down: $_"; $running = $false; $pending = $false }
    if ($pending) {
        $client = $null
        try { $client = $listener.AcceptTcpClient() } catch { $client = $null }
        if ($client) {
            try { Handle-Request $client } catch { Log "Handle-Request threw: $_" }
            Close-Client $client
            $lastReq = Get-Date
            $gotFirst = $true
        }
    } else {
        $now = Get-Date
        if ($gotFirst) {
            if (($now - $lastReq).TotalSeconds -gt $idleSec) {
                Log "Idle for >$idleSec s (window closed) -- shutting down"
                $running = $false
            }
        } else {
            if (($now - $startTime).TotalSeconds -gt $startupGraceSec) {
                Log "No client connected within ${startupGraceSec}s -- shutting down"
                $running = $false
            }
        }
    }
    # Dock + focus the window once it has loaded the page (title now present).
    # One cheap attempt per loop iteration until it sticks or the deadline passes.
    if ((-not $NoLaunch) -and (-not $positioned) -and ((Get-Date) -lt $positionDeadline)) {
        $ph = Try-PositionStreamWindow $geom
        if ($ph -ne [IntPtr]::Zero) { $positioned = $true; Log "Stream window positioned + focused" }
    }
}

# ---- Cleanup. ----
try { [TexpopStream.Native]::CloseMsedgeWindowsByTitle('TeXpop Stream') | Out-Null } catch { }
try { $listener.Stop() } catch { }
try { if (Test-Path -LiteralPath $script:lockPath) { Remove-Item -LiteralPath $script:lockPath -Force -ErrorAction SilentlyContinue } } catch { }
Log "=== stream.ps1 exit (pid $PID) ==="
