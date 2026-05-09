# show.ps1 -- Render the focused Claude Code session's last assistant message.
#
# Part of texpop (https://github.com/dyed-eye/texpop).
#
# Detection cascade:
#   1. If foreground window is Windows Terminal, use UIAutomation to query
#      the SELECTED TabItem's name; try to extract a path from it.
#   2. Walk foreground process tree, find claude / node-claude descendants,
#      read each one's CWD via PEB (NtQueryInformationProcess + ReadProcessMemory).
#   3. Map a CWD to ~/.claude/projects/<encoded>/ and pick newest .jsonl in it.
#   4. Fallback: newest .jsonl globally (excluding subagents/.backups).
#
# Parsing speed:
#   - Read only the last ~500KB of the picked .jsonl (backward).
#   - Find the LAST line with assistant text; capture its requestId.
#   - Concatenate text from all lines sharing that requestId.
#
# Debugging:
#   - Always writes %TEMP%\texpop-debug.log
#   - Run with -Diagnose to skip Edge launch and open the log in Notepad.
#
# Usage: powershell -WindowStyle Hidden -File show.ps1

[CmdletBinding()]
param(
    [string]$ProjectsRoot,
    [int]$Width  = 720,
    [int]$Height = 540,
    [switch]$KeepOpenOnError,
    [switch]$Diagnose
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$template  = Join-Path $scriptDir 'template.html'
$vendor    = Join-Path $scriptDir 'vendor'
$outHtml   = Join-Path $env:TEMP 'texpop.html'
$logPath   = Join-Path $env:TEMP 'texpop-debug.log'

if (-not $ProjectsRoot) {
    $ProjectsRoot = Join-Path $env:USERPROFILE '.claude\projects'
}

# ---------- Logging ----------
$logBuf = [System.Text.StringBuilder]::new()
function Log {
    param([string]$msg)
    $stamp = (Get-Date).ToString('HH:mm:ss.fff')
    [void]$logBuf.AppendLine("[$stamp] $msg")
}
function Flush-Log {
    try {
        [System.IO.File]::WriteAllText($logPath, $logBuf.ToString(),
            [System.Text.UTF8Encoding]::new($false))
    } catch { }
}

Log "=== texpop show.ps1 run ==="
Log "ProjectsRoot=$ProjectsRoot  Diagnose=$Diagnose"

# Captured inside Find-FocusedSessionFile; reused at Edge-launch time to size/position
# the popup so it overlaps the terminal window exactly.
$script:fgRectAtStart = $null

function Fail($msg) {
    Log "FAIL: $msg"
    Flush-Log
    Write-Host "texpop: $msg" -ForegroundColor Red
    if ($KeepOpenOnError) { Read-Host 'Press Enter' }
    exit 1
}

if (-not (Test-Path $template))     { Fail "template.html not found at $template" }
if (-not (Test-Path $vendor))       { Fail "vendor/ missing -- run setup.ps1 first" }
if (-not (Test-Path $ProjectsRoot)) { Fail "Projects root not found: $ProjectsRoot" }

# ---------- P/Invoke: foreground PID + PEB CWD reader (x64) ----------

if (-not ('LatexPopup.Native' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace LatexPopup {
public static class Native {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT pvAttr, int cb);
    [DllImport("user32.dll")]
    public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr dpiContext);
    [DllImport("Shcore.dll")]
    public static extern int GetDpiForMonitor(IntPtr hmonitor, int dpiType, out uint dpiX, out uint dpiY);
    [DllImport("user32.dll")]
    public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);

    // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4
    private static readonly IntPtr DPI_PER_MON_V2 = new IntPtr(-4);

    public static RECT GetForegroundRect() {
        IntPtr prev = IntPtr.Zero;
        try { prev = SetThreadDpiAwarenessContext(DPI_PER_MON_V2); } catch { }

        var r = new RECT();
        IntPtr h = GetForegroundWindow();
        if (h == IntPtr.Zero) return r;
        // DWMWA_EXTENDED_FRAME_BOUNDS = 9 -- excludes drop shadow on Win10+
        int hr = DwmGetWindowAttribute(h, 9, out r, Marshal.SizeOf(typeof(RECT)));
        if (hr != 0) GetWindowRect(h, out r);
        return r;
    }

    public static uint GetForegroundDpi() {
        IntPtr h = GetForegroundWindow();
        if (h == IntPtr.Zero) return 96;
        // MONITOR_DEFAULTTONEAREST = 2
        IntPtr mon = MonitorFromWindow(h, 2);
        uint dx, dy;
        // MDT_EFFECTIVE_DPI = 0
        if (GetDpiForMonitor(mon, 0, out dx, out dy) == 0) return dx;
        return 96;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_BASIC_INFORMATION {
        public IntPtr ExitStatus;
        public IntPtr PebBaseAddress;
        public IntPtr AffinityMask;
        public IntPtr BasePriority;
        public IntPtr UniqueProcessId;
        public IntPtr InheritedFromUniqueProcessId;
    }

    [DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(
        IntPtr hProcess, int infoClass,
        ref PROCESS_BASIC_INFORMATION info, int infoLen, out int retLen);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(int access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ReadProcessMemory(IntPtr h, IntPtr addr,
        byte[] buf, int size, out int bytesRead);
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr h);

    public static int GetForegroundPid() {
        IntPtr h = GetForegroundWindow();
        if (h == IntPtr.Zero) return 0;
        uint pid;
        GetWindowThreadProcessId(h, out pid);
        return (int)pid;
    }

    public static IntPtr GetForegroundHwnd() {
        return GetForegroundWindow();
    }

    public static string GetForegroundTitle() {
        IntPtr h = GetForegroundWindow();
        if (h == IntPtr.Zero) return "";
        var sb = new StringBuilder(512);
        GetWindowText(h, sb, sb.Capacity);
        return sb.ToString();
    }

    public static string GetProcessCwd(int pid) {
        const int PROCESS_QUERY_INFORMATION = 0x0400;
        const int PROCESS_VM_READ           = 0x0010;
        IntPtr hProc = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, pid);
        if (hProc == IntPtr.Zero) return null;
        try {
            var pbi = new PROCESS_BASIC_INFORMATION();
            int ret;
            int status = NtQueryInformationProcess(hProc, 0, ref pbi,
                Marshal.SizeOf(pbi), out ret);
            if (status != 0 || pbi.PebBaseAddress == IntPtr.Zero) return null;

            byte[] ptrBuf = new byte[8];
            int br;
            // PEB.ProcessParameters at offset 0x20 (x64)
            if (!ReadProcessMemory(hProc, IntPtr.Add(pbi.PebBaseAddress, 0x20),
                                   ptrBuf, 8, out br)) return null;
            IntPtr pp = (IntPtr)BitConverter.ToInt64(ptrBuf, 0);
            if (pp == IntPtr.Zero) return null;

            // ProcessParameters.CurrentDirectory.DosPath UNICODE_STRING at +0x38 (x64)
            byte[] usBuf = new byte[16];
            if (!ReadProcessMemory(hProc, IntPtr.Add(pp, 0x38), usBuf, 16, out br))
                return null;
            ushort len = BitConverter.ToUInt16(usBuf, 0);
            IntPtr buf = (IntPtr)BitConverter.ToInt64(usBuf, 8);
            if (len == 0 || buf == IntPtr.Zero) return null;

            byte[] strBytes = new byte[len];
            if (!ReadProcessMemory(hProc, buf, strBytes, len, out br))
                return null;

            string s = Encoding.Unicode.GetString(strBytes, 0, br);
            return s.TrimEnd('\\').TrimEnd();
        } finally {
            CloseHandle(hProc);
        }
    }
}}
'@ -ErrorAction Stop
}

# ---------- UIAutomation: WT selected tab name ----------

function Get-WtSelectedTabInfo {
    param([IntPtr]$wtHwnd)
    try {
        Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
        Add-Type -AssemblyName UIAutomationTypes  -ErrorAction Stop
    } catch {
        Log "UIA assemblies failed to load: $_"
        return $null
    }

    try {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($wtHwnd)
    } catch {
        Log "UIA FromHandle threw: $_"
        return $null
    }
    if (-not $root) { Log "UIA root null"; return $null }

    $ctype = [System.Windows.Automation.AutomationElement]::ControlTypeProperty
    $tabT  = [System.Windows.Automation.ControlType]::TabItem
    $sel   = [System.Windows.Automation.SelectionItemPattern]::IsSelectedProperty
    $tree  = [System.Windows.Automation.TreeScope]::Descendants

    $sCond = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new($ctype, $tabT),
        [System.Windows.Automation.PropertyCondition]::new($sel, $true)
    )
    $tab = $null
    try { $tab = $root.FindFirst($tree, $sCond) } catch { Log "UIA selected-tab find threw: $_" }

    if (-not $tab) {
        Log "UIA no selected TabItem; trying any TabItem"
        try {
            $tab = $root.FindFirst($tree,
                [System.Windows.Automation.PropertyCondition]::new($ctype, $tabT))
        } catch { Log "UIA any-tab find threw: $_" }
    }
    if (-not $tab) { return $null }

    $name = $tab.Current.Name
    Log "UIA selected-tab name: '$name'"
    return $name
}

# ---------- Find focused session file ----------

function Resolve-ProjectDirForCwd {
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

function Find-NewestJsonl {
    param([string]$projectDir)
    Get-ChildItem -Path $projectDir -Filter '*.jsonl' -File `
        -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

# Read last ~60KB of a jsonl, find the most recent {"type":"ai-title","aiTitle":"..."} line.
function Get-AiTitle {
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

function Normalize-Title {
    param([string]$t)
    if (-not $t) { return '' }
    # Strip leading decoration chars (e.g. "* ", emoji, whitespace) and lowercase.
    return (($t -replace '^[\W_]+', '').Trim().ToLower())
}

function Find-SessionByTitle {
    param([string]$targetTitle, $projectDirs)
    $norm = Normalize-Title $targetTitle
    if (-not $norm) { return $null }
    Log "Title-match target: '$targetTitle' (normalized='$norm')"
    foreach ($pd in $projectDirs) {
        $jsonls = Get-ChildItem -Path $pd -Filter '*.jsonl' -File `
            -ErrorAction SilentlyContinue
        foreach ($j in $jsonls) {
            $title = Get-AiTitle $j
            if (-not $title) { continue }
            $jNorm = Normalize-Title $title
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

function Find-FocusedSessionFile {
    param([string]$projectsRoot)

    $fgPid   = [LatexPopup.Native]::GetForegroundPid()
    $fgHwnd  = [LatexPopup.Native]::GetForegroundHwnd()
    $fgTitle = [LatexPopup.Native]::GetForegroundTitle()
    $script:fgRectAtStart = [LatexPopup.Native]::GetForegroundRect()
    $fgDpi = 96
    try { $fgDpi = [LatexPopup.Native]::GetForegroundDpi() } catch { }
    $script:fgDpiAtStart = $fgDpi
    $scale = [Math]::Round($fgDpi / 96.0, 2)
    Log "Foreground: HWND=0x$([Convert]::ToString([int64]$fgHwnd, 16))  PID=$fgPid  Title='$fgTitle'"
    Log "Foreground rect (physical px): L=$($script:fgRectAtStart.Left) T=$($script:fgRectAtStart.Top) R=$($script:fgRectAtStart.Right) B=$($script:fgRectAtStart.Bottom)"
    Log "Foreground monitor DPI=$fgDpi (scale=${scale}x)"
    if ($fgPid -le 0) { Log "Foreground PID 0 -- skipping focus detection"; return $null }

    # Get foreground process info
    $fgProc = $null
    try { $fgProc = Get-Process -Id $fgPid -ErrorAction Stop } catch { }
    $fgName = if ($fgProc) { $fgProc.ProcessName } else { "<unknown>" }
    Log "Foreground process: $fgName.exe (pid $fgPid)"

    # If WT, capture the selected tab's UIA name for use in title matching below.
    $wtTabName = $null
    if ($fgName -ieq 'WindowsTerminal') {
        $wtTabName = Get-WtSelectedTabInfo -wtHwnd $fgHwnd
    }

    # ---------- Walk process tree, collect candidate claude processes ----------
    $procs = $null
    try {
        $procs = Get-CimInstance Win32_Process `
            -Property ProcessId, ParentProcessId, Name, CommandLine `
            -ErrorAction Stop
    } catch {
        Log "Win32_Process query failed: $_"
        return $null
    }

    $childMap = @{}
    foreach ($p in $procs) {
        $ppid = [int]$p.ParentProcessId
        if (-not $childMap.ContainsKey($ppid)) { $childMap[$ppid] = @() }
        $childMap[$ppid] += $p
    }

    $queue = [System.Collections.Generic.Queue[int]]::new()
    $queue.Enqueue($fgPid)
    $candidates = @()
    $visited = @{}
    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue()
        if ($visited.ContainsKey($cur)) { continue }
        $visited[$cur] = $true
        $kids = $childMap[$cur]
        if (-not $kids) { continue }
        foreach ($k in $kids) {
            $name = if ($k.Name) { $k.Name.ToLower() } else { '' }
            $cmd  = if ($k.CommandLine) { $k.CommandLine } else { '' }
            $isClaude = ($name -eq 'claude.exe') -or
                        (($name -eq 'node.exe') -and ($cmd -match 'claude'))
            if ($isClaude) { $candidates += $k }
            $queue.Enqueue([int]$k.ProcessId)
        }
    }

    Log "Tree walk: $($candidates.Count) claude candidate(s) under PID $fgPid"
    foreach ($c in $candidates) {
        $cmdShort = if ($c.CommandLine) { ($c.CommandLine -replace '\s+', ' ').Substring(0, [Math]::Min(140, $c.CommandLine.Length)) } else { '<no cmd>' }
        Log "  candidate pid=$($c.ProcessId)  $($c.Name)  cmd='$cmdShort'"
    }

    if (-not $candidates) {
        Log "No claude descendants of foreground"
        return $null
    }

    # Collect unique project dirs from candidate CWDs.
    $projectDirs = @()
    foreach ($c in $candidates) {
        $cwd = $null
        try { $cwd = [LatexPopup.Native]::GetProcessCwd([int]$c.ProcessId) } catch { Log "  PEB read pid=$($c.ProcessId) threw: $_" }
        Log "  pid=$($c.ProcessId)  CWD='$cwd'"
        if (-not $cwd) { continue }
        $pd = Resolve-ProjectDirForCwd -cwd $cwd -projectsRoot $projectsRoot
        if (-not $pd) { continue }
        if ($projectDirs -notcontains $pd) { $projectDirs += $pd }
    }
    Log "Candidate project dirs: $($projectDirs.Count)"

    # PRIMARY signal: match the WT/window title against ai-title in candidate jsonls.
    $titleSources = @()
    if ($fgTitle)   { $titleSources += $fgTitle }
    if ($wtTabName -and ($wtTabName -ne $fgTitle)) { $titleSources += $wtTabName }
    foreach ($t in $titleSources) {
        $match = Find-SessionByTitle -targetTitle $t -projectDirs $projectDirs
        if ($match) { return $match }
    }

    # Fallback: newest jsonl across candidate project dirs (heuristic).
    $best = $null
    foreach ($pd in $projectDirs) {
        $j = Find-NewestJsonl $pd
        if (-not $j) { continue }
        Log "  fallback newest in $($pd | Split-Path -Leaf): $($j.Name) (mtime $($j.LastWriteTime))"
        if (-not $best -or $j.LastWriteTime -gt $best.LastWriteTime) { $best = $j }
    }
    if ($best) { Log "Tree-walk fallback chose: $($best.FullName)" }
    return $best
}

# ---------- Backward parser ----------

function Get-LastAssistantTurn {
    param([System.IO.FileInfo]$file)

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
    Log "Parser: file=$($file.Name) size=$size  chunkSize=$chunkSize  lines=$($lines.Count)"

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
    if (-not $lastReqId) { Log "Parser: no last-assistant requestId found"; return '' }
    Log "Parser: last requestId=$lastReqId"

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

# ---------- Main ----------

$session = Find-FocusedSessionFile -projectsRoot $ProjectsRoot

if (-not $session) {
    Log "FOCUSED detection failed -- using GLOBAL newest fallback"
    $session = Get-ChildItem -Path $ProjectsRoot -Filter *.jsonl -Recurse -File `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notmatch '\\subagents\\' -and
            $_.FullName -notmatch '\\\.backups\\'
        } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($session) { Log "Global newest: $($session.FullName)" }
}

if (-not $session) { Fail 'No session transcripts found.' }
Log "PICKED: $($session.FullName)  (mtime $($session.LastWriteTime))"

$message = Get-LastAssistantTurn -file $session
if ([string]::IsNullOrWhiteSpace($message)) {
    Fail "No assistant text in $($session.Name)"
}
Log "Message length: $($message.Length) chars"

if ($Diagnose) {
    Log "Diagnose mode -- not launching Edge"
    Flush-Log
    Start-Process notepad.exe -ArgumentList $logPath | Out-Null
    return
}

# ---------- Render template, launch Edge ----------

$tpl = Get-Content -Path $template -Raw -Encoding UTF8
$vendorUri = ([uri]$vendor).AbsoluteUri.TrimEnd('/')
$assetsDir = Join-Path $scriptDir 'assets'
$assetsUri = ([uri]$assetsDir).AbsoluteUri.TrimEnd('/')

# Resolve favicon: user override (svg/png/jpg/ico) wins over bundled default.
$iconCandidates = @(
    'icon-override.svg',
    'icon-override.png',
    'icon-override.jpg',
    'icon-override.ico',
    'icon-default.svg'
)
$resolvedIcon = $null
foreach ($name in $iconCandidates) {
    $path = Join-Path $assetsDir $name
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $resolvedIcon = ([uri]$path).AbsoluteUri
        Log "Icon resolved: $name -> $resolvedIcon"
        break
    }
}
if (-not $resolvedIcon) {
    Log "Icon: no candidate found in $assetsDir (template href will dangle)"
    $resolvedIcon = "$assetsUri/icon-default.svg"
}

$tpl = $tpl.Replace('ASSETS_BASE/icon.svg', $resolvedIcon)
$tpl = $tpl.Replace('VENDOR_BASE', $vendorUri)
$tpl = $tpl.Replace('ASSETS_BASE', $assetsUri)
$safeMsg = $message -replace '</script', '<\/script'
$tpl = $tpl.Replace('MESSAGE_PLACEHOLDER', $safeMsg)
$srcInfo = "<!-- source: $($session.FullName) | $($session.LastWriteTime) -->`r`n"
$tpl = $srcInfo + $tpl
[System.IO.File]::WriteAllText($outHtml, $tpl, [System.Text.UTF8Encoding]::new($false))

$edge = $null
$edgeCandidates = @(
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe"
)
foreach ($p in $edgeCandidates) {
    if (Test-Path $p) { $edge = $p; break }
}

$fileUri     = ([uri]$outHtml).AbsoluteUri
# v2 profile dir -- bumping forces a fresh favicon cache after icon change.
$userDataDir = Join-Path $env:LOCALAPPDATA 'texpop\edge-profile-v2'
if (-not (Test-Path $userDataDir)) {
    New-Item -ItemType Directory -Force -Path $userDataDir | Out-Null
}

# Compute window size + position from the captured foreground rect.
# DwmGetWindowAttribute (in PMv2 mode) returns PHYSICAL pixels; Edge's command-line
# --window-size/--window-position expect DIPs (logical pixels). Divide by scale.
$winX = $null; $winY = $null; $winW = $Width; $winH = $Height
if ($script:fgRectAtStart) {
    $r = $script:fgRectAtStart
    $rwPhys = $r.Right  - $r.Left
    $rhPhys = $r.Bottom - $r.Top
    $dpi = if ($script:fgDpiAtStart) { [double]$script:fgDpiAtStart } else { 96.0 }
    $scale = $dpi / 96.0
    if ($rwPhys -gt 200 -and $rhPhys -gt 150 -and $scale -gt 0) {
        $rwDip = [int]([Math]::Round($rwPhys / $scale))
        $rhDip = [int]([Math]::Round($rhPhys / $scale))
        $winW = [int][Math]::Min(3840, [Math]::Max(480, $rwDip))
        $winH = [int][Math]::Min(2160, [Math]::Max(360, $rhDip))
        $winX = [int]([Math]::Round($r.Left / $scale))
        $winY = [int]([Math]::Round($r.Top  / $scale))
        Log ("Rect physical: {0}x{1} at ({2},{3}); scale={4}x; DIP: {5}x{6} at ({7},{8})" -f `
            $rwPhys, $rhPhys, $r.Left, $r.Top, $scale, $winW, $winH, $winX, $winY)
    }
}

if ($edge) {
    $edgeArgs = @(
        "--app=$fileUri",
        "--window-size=$winW,$winH",
        "--user-data-dir=$userDataDir",
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-features=Translate'
    )
    if ($null -ne $winX -and $null -ne $winY) {
        $edgeArgs += "--window-position=$winX,$winY"
    }
    Start-Process -FilePath $edge -ArgumentList $edgeArgs | Out-Null
    Log "Launched Edge"

    try {
        Add-Type -Namespace LatexPopupSwp -Name Win -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr FindWindow(string lpClassName, string lpWindowName);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetWindowPos(System.IntPtr hWnd, System.IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetForegroundWindow(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool BringWindowToTop(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@ -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 350
        for ($i = 0; $i -lt 15; $i++) {
            $h = [LatexPopupSwp.Win]::FindWindow($null, 'LaTeX preview')
            if ($h -ne [IntPtr]::Zero) {
                # SW_SHOW = 5 -- ensure visible & not minimized
                [LatexPopupSwp.Win]::ShowWindow($h, 5) | Out-Null
                # Briefly topmost to lift z-order, then back to normal so it
                # behaves like a regular window (focusable, not pinned).
                # HWND_TOPMOST = -1, HWND_NOTOPMOST = -2, SWP_NOMOVE|SWP_NOSIZE = 0x0003
                [LatexPopupSwp.Win]::SetWindowPos($h, [IntPtr]-1, 0, 0, 0, 0, 0x0003) | Out-Null
                Start-Sleep -Milliseconds 25
                [LatexPopupSwp.Win]::SetWindowPos($h, [IntPtr]-2, 0, 0, 0, 0, 0x0003) | Out-Null
                [LatexPopupSwp.Win]::BringWindowToTop($h) | Out-Null
                [LatexPopupSwp.Win]::SetForegroundWindow($h) | Out-Null
                Log "Brought Edge popup to foreground (HWND=0x$([Convert]::ToString([int64]$h, 16)))"
                break
            }
            Start-Sleep -Milliseconds 130
        }
    } catch { Log "Foreground promotion threw: $_" }
} else {
    Log "Edge not found; opening with default browser"
    Start-Process $outHtml | Out-Null
}

Flush-Log
