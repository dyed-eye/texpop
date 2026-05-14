# show.ps1 -- Render the focused AI CLI session's last assistant message.
#
# Part of texpop (https://github.com/dyed-eye/texpop).
#
# Detection cascade:
#   1. If foreground window is Windows Terminal, use UIAutomation to query
#      the SELECTED TabItem's name; try to extract a path from it.
#   2. Walk foreground process tree, collect candidate CLI processes
#      (claude.exe / node.exe+claude / codex.exe / node.exe+codex / ...).
#   3. Run each registered ChatSourceAdapter's Match block; first match wins.
#      The adapter's FindFocusedSession picks a transcript file, then its
#      GetLastAssistantTurn returns the last assistant message as Markdown.
#   4. Fallback: newest .jsonl globally under ~/.claude/projects (excluding
#      subagents/.backups). Codex-only sessions still need a Claude project
#      dir for this fallback to fire -- in that case the adapter's own
#      FindFocusedSession should have already returned a result.
#
# Adapters live in adapters\<name>.ps1 and are dot-sourced below.
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
# Each invocation writes to a unique filename so Edge can't serve the previous
# render from cache. Stale files (>5 min old) are pruned right here at start.
$invocationId = [guid]::NewGuid().ToString('N').Substring(0, 8)
$outHtml   = Join-Path $env:TEMP "texpop-$invocationId.html"
$logPath   = Join-Path $env:TEMP 'texpop-debug.log'
try {
    Get-ChildItem -Path $env:TEMP -Filter 'texpop-*.html' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddMinutes(-5) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
} catch { }

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

# Captured inside Find-FocusedSession; reused at Edge-launch time to size/position
# the popup so it overlaps the terminal window exactly.
$script:fgRectAtStart = $null

function Fail($msg) {
    Log "FAIL: $msg"
    Flush-Log
    # show.ps1 runs with -WindowStyle Hidden so console output is invisible.
    # Surface failures via MessageBox; users can also open the debug log.
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show("texpop: $msg`n`nSee log: $logPath", 'texpop', 'OK', 'Error') | Out-Null
    } catch { }
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

    public static RECT GetWindowRectPhys(IntPtr h) {
        IntPtr prev = IntPtr.Zero;
        try { prev = SetThreadDpiAwarenessContext(DPI_PER_MON_V2); } catch { }
        var r = new RECT();
        if (h == IntPtr.Zero) return r;
        int hr = DwmGetWindowAttribute(h, 9, out r, Marshal.SizeOf(typeof(RECT)));
        if (hr != 0) GetWindowRect(h, out r);
        return r;
    }

    public static string GetWindowTitle(IntPtr h) {
        if (h == IntPtr.Zero) return "";
        var sb = new StringBuilder(512);
        GetWindowText(h, sb, sb.Capacity);
        return sb.ToString();
    }

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    public delegate bool EnumWindowsCb(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsCb lpEnumFunc, IntPtr lParam);

    public static IntPtr FindFirstVisibleHwndForPids(int[] pids) {
        var pidSet = new System.Collections.Generic.HashSet<uint>();
        foreach (var p in pids) pidSet.Add((uint)p);
        IntPtr matched = IntPtr.Zero;
        EnumWindows((hWnd, lParam) => {
            if (!IsWindowVisible(hWnd)) return true;
            int len = GetWindowTextLength(hWnd);
            if (len <= 0) return true; // skip toolwindows / hidden helpers
            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            if (pidSet.Contains(pid)) {
                matched = hWnd;
                return false; // stop
            }
            return true;
        }, IntPtr.Zero);
        return matched;
    }

    public static IntPtr[] FindAllVisibleHwndsForPids(int[] pids) {
        var pidSet = new System.Collections.Generic.HashSet<uint>();
        foreach (var p in pids) pidSet.Add((uint)p);
        var matched = new System.Collections.Generic.List<IntPtr>();
        EnumWindows((hWnd, lParam) => {
            if (!IsWindowVisible(hWnd)) return true;
            int len = GetWindowTextLength(hWnd);
            if (len <= 0) return true;
            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            if (pidSet.Contains(pid)) matched.Add(hWnd);
            return true;
        }, IntPtr.Zero);
        return matched.ToArray();
    }

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    // Enumerate every top-level window whose class name matches exactly.
    // Used to find ALL Windows Terminal windows by their CASCADIA_HOSTING_WINDOW_CLASS,
    // which is more robust than filtering by PID: WT may run a single process for
    // all windows (modern default) OR a separate process per window (depending on
    // 'windowingBehavior' settings), and windows on other virtual desktops have
    // their own quirks. requireVisible=false lets us pick up cross-desktop /
    // cloaked windows too. Empty-title windows are skipped regardless.
    public static IntPtr[] FindWindowsByClassName(string className, bool requireVisible) {
        var matched = new System.Collections.Generic.List<IntPtr>();
        EnumWindows((hWnd, lParam) => {
            if (requireVisible && !IsWindowVisible(hWnd)) return true;
            int tlen = GetWindowTextLength(hWnd);
            if (tlen <= 0) return true;
            var sb = new StringBuilder(256);
            if (GetClassName(hWnd, sb, sb.Capacity) == 0) return true;
            if (string.Equals(sb.ToString(), className, StringComparison.OrdinalIgnoreCase)) {
                matched.Add(hWnd);
            }
            return true;
        }, IntPtr.Zero);
        return matched.ToArray();
    }

    [DllImport("user32.dll")]
    public static extern int GetWindowTextLength(IntPtr hWnd);

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
            // Clamp to MAX_PATH*2 so a corrupt or adversarial PEB can't trick us
            // into a 64KB cross-process read.
            if (len > 520) return null;

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

# Enumerate ALL TabItem names under a Windows Terminal window. Used to scope
# candidate jsonls to the focused WT window: modern WT runs every window
# under one WindowsTerminal.exe process, so the process-tree walk below
# would otherwise see claude.exe descendants from every window at once.
# Tab titles in other windows are used as a per-jsonl exclusion set.
function Get-WtAllTabNames {
    param([IntPtr]$wtHwnd)
    try {
        Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
        Add-Type -AssemblyName UIAutomationTypes  -ErrorAction Stop
    } catch {
        Log "UIA assemblies failed to load: $_"
        return @()
    }
    try {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($wtHwnd)
    } catch {
        Log "UIA FromHandle threw: $_"
        return @()
    }
    if (-not $root) { return @() }

    $ctype = [System.Windows.Automation.AutomationElement]::ControlTypeProperty
    $tabT  = [System.Windows.Automation.ControlType]::TabItem
    $tree  = [System.Windows.Automation.TreeScope]::Descendants
    $cond  = [System.Windows.Automation.PropertyCondition]::new($ctype, $tabT)

    $tabs = $null
    try { $tabs = $root.FindAll($tree, $cond) } catch { Log "UIA FindAll tabs threw: $_"; return @() }
    if (-not $tabs) { return @() }

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($t in $tabs) {
        try {
            $n = $t.Current.Name
            if ($n) { [void]$names.Add($n) }
        } catch { }
    }
    return ,$names.ToArray()
}

# ---------- Adapter loading ----------

# Each adapter file appends a hashtable to $script:Adapters with keys:
#   Name, Description, Match, FindFocusedSession, GetLastAssistantTurn.
# See adapters\claude-code.ps1 for the canonical example.
$script:Adapters = @()
$script:ClaudeProjectsRoot = $ProjectsRoot

$adapterDir = Join-Path $scriptDir 'adapters'
# Explicit allowlist: an attacker (or a confused git pull) dropping a new .ps1
# into adapters/ should NOT get auto-executed in this script's scope. To add a
# new adapter, edit this list and ship the file.
$adapterAllowlist = @('claude-code.ps1', 'codex.ps1')
if (Test-Path $adapterDir) {
    foreach ($name in $adapterAllowlist) {
        $afPath = Join-Path $adapterDir $name
        if (-not (Test-Path -LiteralPath $afPath -PathType Leaf)) {
            Log "Adapter '$name' not present in $adapterDir -- skipped"
            continue
        }
        try {
            . $afPath
            Log "Loaded adapter file: $name"
        } catch {
            Log "Failed to load adapter '$name': $_"
        }
    }
} else {
    Log "Adapter dir not found: $adapterDir"
}
Log "Adapters registered: $($script:Adapters.Count) -- $((($script:Adapters | ForEach-Object { $_.Name }) -join ', '))"

# ---------- Find focused session file (orchestrator) ----------

function Find-FocusedSession {
    # Returns @{ File = [System.IO.FileInfo]; Adapter = <hashtable> } or $null.

    $fgPid   = [LatexPopup.Native]::GetForegroundPid()
    $fgHwnd  = [LatexPopup.Native]::GetForegroundHwnd()
    $fgTitle = [LatexPopup.Native]::GetForegroundTitle()
    $script:fgRectAtStart = [LatexPopup.Native]::GetForegroundRect()
    $fgDpi = 96
    try { $fgDpi = [LatexPopup.Native]::GetForegroundDpi() } catch { }
    $script:fgDpiAtStart = $fgDpi
    Log "Foreground: HWND=0x$([Convert]::ToString([int64]$fgHwnd, 16))  PID=$fgPid  Title='$fgTitle'"
    Log "Foreground rect (physical px): L=$($script:fgRectAtStart.Left) T=$($script:fgRectAtStart.Top) R=$($script:fgRectAtStart.Right) B=$($script:fgRectAtStart.Bottom)"
    Log ("Foreground monitor DPI={0} (scale={1:F2}x)" -f $fgDpi, ($fgDpi / 96.0))
    if ($fgPid -le 0) { Log "Foreground PID 0 -- skipping focus detection"; return $null }

    # Get foreground process info
    $fgProc = $null
    try { $fgProc = Get-Process -Id $fgPid -ErrorAction Stop } catch { }
    $fgName = if ($fgProc) { $fgProc.ProcessName } else { "<unknown>" }
    Log "Foreground process: $fgName.exe (pid $fgPid)"

    # If foreground is a TeXpop popup, the captured rect is the popup's, not
    # the terminal's. Walk visible windows for the most recent terminal window
    # and reuse its rect, HWND, title, and DPI.
    if ($fgName -ieq 'msedge' -and $fgTitle -like '*TeXpop*') {
        Log "Foreground is the TeXpop popup itself - looking for the actual terminal"
        try {
            $termPids = Get-CimInstance Win32_Process -Filter "Name='WindowsTerminal.exe' OR Name='conhost.exe' OR Name='wezterm-gui.exe' OR Name='alacritty.exe' OR Name='Hyper.exe'" `
                -Property ProcessId, Name -ErrorAction Stop |
                ForEach-Object { [int]$_.ProcessId }
            if ($termPids) {
                $termHwnd = [LatexPopup.Native]::FindFirstVisibleHwndForPids([int[]]$termPids)
                if ($termHwnd -ne [IntPtr]::Zero) {
                    $tRect = [LatexPopup.Native]::GetWindowRectPhys($termHwnd)
                    $tTitle = [LatexPopup.Native]::GetWindowTitle($termHwnd)
                    # Pull the terminal's PID so BFS below walks ITS process tree
                    # instead of the popup's (which has no relevant descendants).
                    $tPid = [uint32]0
                    [void][LatexPopup.Native]::GetWindowThreadProcessId($termHwnd, [ref]$tPid)
                    Log "Re-targeted to terminal HWND=0x$([Convert]::ToString([int64]$termHwnd, 16)) PID=$tPid Title='$tTitle' rect=L=$($tRect.Left) T=$($tRect.Top) R=$($tRect.Right) B=$($tRect.Bottom)"
                    $fgHwnd  = $termHwnd
                    $fgTitle = $tTitle
                    $script:fgRectAtStart = $tRect
                    $fgPid = [int]$tPid
                    # Re-resolve the process name so the WT-UIA branch fires
                    # iff the re-targeted window is actually Windows Terminal.
                    try { $fgProc = Get-Process -Id $fgPid -ErrorAction Stop } catch { $fgProc = $null }
                    $fgName = if ($fgProc) { $fgProc.ProcessName } else { "<unknown>" }
                    Log "Re-targeted process: $fgName.exe (pid $fgPid)"
                } else {
                    Log "No visible terminal window found - keeping popup rect (popup will land on top of itself)"
                }
            }
        } catch { Log "Re-targeting threw: $_" }
    }

    # If WT, capture the selected tab's UIA name for use in title matching below.
    $wtTabName = $null
    # Tab titles in *other* WT windows. Used by Claude adapter as an exclusion
    # set so the process-tree walk doesn't pull in chats from windows that
    # aren't focused. Empty when WT isn't foreground or only one WT window
    # exists.
    $wtOtherTabs = @()
    if ($fgName -ieq 'WindowsTerminal') {
        $wtTabName = Get-WtSelectedTabInfo -wtHwnd $fgHwnd

        # Find every WT window by class name (more robust than by PID --
        # works for both single-process and multi-process WT, and picks up
        # windows on other virtual desktops).
        try {
            $wtHwnds = [LatexPopup.Native]::FindWindowsByClassName('CASCADIA_HOSTING_WINDOW_CLASS', $false)
            Log "WT windows by class CASCADIA_HOSTING_WINDOW_CLASS: count=$($wtHwnds.Count)"
            $otherList = [System.Collections.Generic.List[string]]::new()
            foreach ($h in $wtHwnds) {
                $hTitle = [LatexPopup.Native]::GetWindowTitle($h)
                $hPid   = [uint32]0
                [void][LatexPopup.Native]::GetWindowThreadProcessId($h, [ref]$hPid)
                $isFg = ($h -eq $fgHwnd)
                if ($isFg) {
                    Log "  WT[fg] HWND=0x$([Convert]::ToString([int64]$h, 16)) PID=$hPid title='$hTitle'"
                    continue
                }
                $names = Get-WtAllTabNames -wtHwnd $h
                $sample = ($names | Select-Object -First 4) -join ' | '
                Log "  WT     HWND=0x$([Convert]::ToString([int64]$h, 16)) PID=$hPid title='$hTitle' tabs=$($names.Count) sample='$sample'"
                foreach ($n in $names) {
                    if ($n) { [void]$otherList.Add($n) }
                }
            }
            $wtOtherTabs = $otherList.ToArray()
            Log "WT other-window tab names: count=$($wtOtherTabs.Count)"
        } catch { Log "Enumerate WT windows threw: $_" }
    }

    # ---------- Walk process tree, collect ALL candidate descendants ----------
    # We collect every descendant process and let each adapter's Match block
    # decide which ones it cares about. This lets a single tree contain
    # multiple agents (e.g. WT host with one tab running claude, another
    # running codex) without losing detection coverage.
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

    $candidates = [System.Collections.Generic.List[object]]::new()
    $queue = [System.Collections.Generic.Queue[int]]::new()
    $queue.Enqueue($fgPid)
    $visited = @{}
    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue()
        if ($visited.ContainsKey($cur)) { continue }
        $visited[$cur] = $true
        $kids = $childMap[$cur]
        if (-not $kids) { continue }
        foreach ($k in $kids) {
            [void]$candidates.Add($k)
            $queue.Enqueue([int]$k.ProcessId)
        }
    }

    Log "Tree walk: $($candidates.Count) descendant process(es) under PID $fgPid"
    foreach ($c in $candidates) {
        $cmdShort = if ($c.CommandLine) {
            $collapsed = $c.CommandLine -replace '\s+', ' '
            if ($collapsed.Length -gt 140) { $collapsed.Substring(0, 140) } else { $collapsed }
        } else { '<no cmd>' }
        Log "  candidate pid=$($c.ProcessId)  $($c.Name)  cmd='$cmdShort'"
    }

    if ($candidates.Count -eq 0) {
        Log "No descendant processes of foreground"
        return $null
    }

    # ---------- Dispatch to adapters; first match wins ----------
    foreach ($adapter in $script:Adapters) {
        $matched = $false
        try {
            $matched = & $adapter.Match $candidates
        } catch {
            Log "Adapter '$($adapter.Name)' Match threw: $_"
            continue
        }
        if (-not $matched) {
            Log "Adapter no-match for: $($adapter.Name)"
            continue
        }
        Log "Adapter matched: $($adapter.Name)"
        $file = $null
        try {
            $file = & $adapter.FindFocusedSession $candidates $fgTitle $wtTabName $wtOtherTabs
        } catch {
            Log "Adapter '$($adapter.Name)' FindFocusedSession threw: $_"
            continue
        }
        if ($file) {
            return @{ File = $file; Adapter = $adapter }
        }
        Log "Adapter '$($adapter.Name)' returned no session file"
    }

    Log "No adapter produced a session file"
    return $null
}

# ---------- Main ----------

$pick    = Find-FocusedSession
$session = $null
$pickedAdapter = $null
if ($pick) {
    $session = $pick.File
    $pickedAdapter = $pick.Adapter
}

if (-not $session) {
    Log "FOCUSED detection failed -- using GLOBAL newest fallback (Claude projects only)"
    $session = Get-ChildItem -Path $ProjectsRoot -Filter *.jsonl -Recurse -File `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notmatch '\\subagents\\' -and
            $_.FullName -notmatch '\\\.backups\\'
        } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($session) {
        Log "Global newest: $($session.FullName)"
        # The global fallback only reaches Claude transcripts, so route the
        # parse through the claude-code adapter.
        $pickedAdapter = $script:Adapters | Where-Object { $_.Name -eq 'claude-code' } | Select-Object -First 1
    }
}

if (-not $session) { Fail 'No session transcripts found.' }
if (-not $pickedAdapter) { Fail "Internal: no adapter to parse $($session.Name)" }
Log "PICKED: $($session.FullName)  (mtime $($session.LastWriteTime))  adapter=$($pickedAdapter.Name)"

$message = & $pickedAdapter.GetLastAssistantTurn $session
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
    'icon-default.ico',
    'icon-default.png',
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
    $resolvedIcon = "$assetsUri/icon-default.ico"
}

# Replacement order is load-bearing: ASSETS_BASE/icon.svg must run BEFORE
# the bare ASSETS_BASE prefix or the icon URI gets sliced. Same constraint
# is replicated in show-linux.py:write_html; keep them in sync.
$tpl = $tpl.Replace('ASSETS_BASE/icon.svg', $resolvedIcon)
$tpl = $tpl.Replace('VENDOR_BASE', $vendorUri)
$tpl = $tpl.Replace('ASSETS_BASE', $assetsUri)
# JSON data island: template.html uses <script type='application/json'> for
# the message payload and parses via JSON.parse. We produce a JSON-encoded
# string, then defensively escape any </ as <\/ so that no literal '</script'
# substring inside the message body can terminate the host script element.
# JSON treats '\/' as identical to '/' on decode, so the message round-trips.
$jsonMsg = ConvertTo-Json -InputObject $message -Compress
$jsonMsg = $jsonMsg -replace '</', '<\/'
$tpl = $tpl.Replace('MESSAGE_PLACEHOLDER', $jsonMsg)
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
# Profile dir is versioned; bump the suffix to flush Edge's favicon/state cache
# when the icon or window-state behaviour changes.
$userDataDir = Join-Path $env:LOCALAPPDATA 'texpop\edge-profile-v3'
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
    # Close any existing TeXpop popup BEFORE launching the new one. Edge --app
    # mode with the same URL + user-data-dir would otherwise refocus the
    # existing window without reloading, leaving stale content. Each hotkey
    # press should show the current focused chat, so kill the old popup first.
    if (-not ('LatexPopupCloser.Win' -as [type])) {
        Add-Type -Namespace LatexPopupCloser -Name Win -MemberDefinition @'
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Auto)]
public static extern int GetWindowText(System.IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern int GetWindowTextLength(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsWindowVisible(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr SendMessage(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(System.IntPtr hwnd, out uint pid);

public static System.IntPtr[] FindTeXpopMsedgeWindows(string substr) {
    System.Collections.Generic.List<System.IntPtr> targets = new System.Collections.Generic.List<System.IntPtr>();
    EnumWindows((hWnd, lParam) => {
        if (!IsWindowVisible(hWnd)) return true;
        int len = GetWindowTextLength(hWnd);
        if (len <= 0) return true;
        var sb = new System.Text.StringBuilder(len + 1);
        GetWindowText(hWnd, sb, sb.Capacity);
        if (sb.ToString().IndexOf(substr, System.StringComparison.OrdinalIgnoreCase) < 0) return true;
        uint pid;
        GetWindowThreadProcessId(hWnd, out pid);
        try {
            var p = System.Diagnostics.Process.GetProcessById((int)pid);
            if (string.Equals(p.ProcessName, "msedge", System.StringComparison.OrdinalIgnoreCase)) {
                targets.Add(hWnd);
            }
        } catch { }
        return true;
    }, System.IntPtr.Zero);
    return targets.ToArray();
}

public static int CloseTeXpopMsedgeWindows(string substr) {
    var targets = FindTeXpopMsedgeWindows(substr);
    foreach (var h in targets) {
        // WM_CLOSE = 0x0010
        SendMessage(h, 0x0010, System.IntPtr.Zero, System.IntPtr.Zero);
    }
    return targets.Length;
}
'@ -ErrorAction SilentlyContinue
    }
    # Snapshot existing TeXpop windows BEFORE launch so we can later
    # distinguish the new popup HWND from any leftover HWNDs that may still
    # be enumerable while Edge is mid-close.
    $script:preLaunchHwnds = @()
    try {
        $script:preLaunchHwnds = [LatexPopupCloser.Win]::FindTeXpopMsedgeWindows('TeXpop')
        $closed = [LatexPopupCloser.Win]::CloseTeXpopMsedgeWindows('TeXpop')
        if ($closed -gt 0) {
            Log "Closed $closed existing TeXpop popup window(s) before relaunch (msedge-only)"
            Start-Sleep -Milliseconds 250  # give Edge time to actually close
        }
    } catch { Log "Pre-launch close threw: $_" }

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
        # Note: this Add-Type registers a SECOND inline type alongside
        # LatexPopupCloser.Win above. The two share several P/Invoke
        # declarations (EnumWindows / GetWindowText / IsWindowVisible);
        # they remain separate because each is gated by an `-as [type]`
        # check and the AppDomain caches them across re-runs in the same
        # PowerShell session, so editing the C# here only takes effect
        # after a fresh process. Do NOT re-add `FindWindowContaining`
        # here -- the polling loop below uses the Closer's
        # `FindTeXpopMsedgeWindows` and an exclusion-set instead.
        Add-Type -Namespace LatexPopupSwp -Name Win -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetWindowPos(System.IntPtr hWnd, System.IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetForegroundWindow(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool BringWindowToTop(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)]
public static extern System.IntPtr SendMessage(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr LoadImage(System.IntPtr hInst, string name, uint type, int cx, int cy, uint flags);
'@ -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 350
        # Edge can take several seconds on cold start before it sets the
        # window title from <title>. Poll up to ~12 s.
        $maxAttempts = 60
        $attemptDelay = 200
        # Build a hashset of pre-launch HWNDs to exclude (they may be
        # half-closed but still enumerable for a few hundred ms).
        $excluded = @{}
        foreach ($eh in $script:preLaunchHwnds) { $excluded[$eh.ToInt64()] = $true }

        for ($i = 0; $i -lt $maxAttempts; $i++) {
            # Find a NEW TeXpop msedge HWND that wasn't in the pre-launch snapshot.
            $candidates = [LatexPopupCloser.Win]::FindTeXpopMsedgeWindows('TeXpop')
            $h = [IntPtr]::Zero
            foreach ($cand in $candidates) {
                if (-not $excluded.ContainsKey($cand.ToInt64())) { $h = $cand; break }
            }
            if ($h -ne [IntPtr]::Zero) {
                Log "Found NEW TeXpop popup on attempt $($i+1) (HWND=0x$([Convert]::ToString([int64]$h, 16)); pre-launch had $($script:preLaunchHwnds.Count))"
                # SW_SHOW = 5 -- ensure visible & not minimized
                [LatexPopupSwp.Win]::ShowWindow($h, 5) | Out-Null

                # Force the popup's rect to match the captured terminal rect.
                # Edge's --user-data-dir stores window state per-app and restores
                # it on subsequent launches, overriding --window-size /
                # --window-position. SetWindowPos here is authoritative.
                if ($script:fgRectAtStart) {
                    $r = $script:fgRectAtStart
                    $w = $r.Right  - $r.Left
                    $hh = $r.Bottom - $r.Top
                    if ($w -gt 200 -and $hh -gt 150) {
                        # SWP_NOZORDER = 0x0004 -- don't disturb z-order yet
                        [LatexPopupSwp.Win]::SetWindowPos($h, [IntPtr]::Zero, $r.Left, $r.Top, $w, $hh, 0x0004) | Out-Null
                        Log "Forced popup rect to terminal: $($r.Left),$($r.Top) size $w x $hh"
                    }
                }

                # Briefly topmost to lift z-order, then back to normal so it
                # behaves like a regular window (focusable, not pinned).
                # HWND_TOPMOST = -1, HWND_NOTOPMOST = -2, SWP_NOMOVE|SWP_NOSIZE = 0x0003
                [LatexPopupSwp.Win]::SetWindowPos($h, [IntPtr]-1, 0, 0, 0, 0, 0x0003) | Out-Null
                Start-Sleep -Milliseconds 25
                [LatexPopupSwp.Win]::SetWindowPos($h, [IntPtr]-2, 0, 0, 0, 0, 0x0003) | Out-Null
                [LatexPopupSwp.Win]::BringWindowToTop($h) | Out-Null
                [LatexPopupSwp.Win]::SetForegroundWindow($h) | Out-Null
                Log "Brought Edge popup to foreground (HWND=0x$([Convert]::ToString([int64]$h, 16)))"

                # Force the taskbar icon directly via WM_SETICON. Edge sets its
                # own icon when the favicon loads, possibly slightly after we
                # hit this point; two sends with a small gap is enough to win
                # that race in practice (was 5x600ms = 3s blocking on every
                # hotkey press, which the user perceives as latency).
                try {
                    $icoPath = Join-Path $scriptDir 'assets\icon-default.ico'
                    if (Test-Path $icoPath) {
                        # IMAGE_ICON = 1, LR_LOADFROMFILE = 0x10
                        $hIcon = [LatexPopupSwp.Win]::LoadImage([IntPtr]::Zero, $icoPath, 1, 256, 256, 0x10)
                        for ($k = 0; $k -lt 2; $k++) {
                            # WM_SETICON = 0x0080, ICON_SMALL = 0, ICON_BIG = 1
                            [LatexPopupSwp.Win]::SendMessage($h, 0x0080, [IntPtr]0, $hIcon) | Out-Null
                            [LatexPopupSwp.Win]::SendMessage($h, 0x0080, [IntPtr]1, $hIcon) | Out-Null
                            Start-Sleep -Milliseconds 350
                        }
                        Log "Forced taskbar icon via WM_SETICON x2 (hIcon=0x$([Convert]::ToString([int64]$hIcon, 16)))"
                    } else {
                        Log "icon-default.ico not found for WM_SETICON"
                    }
                } catch { Log "WM_SETICON threw: $_" }

                break
            }
            Start-Sleep -Milliseconds $attemptDelay
        }
        if ($i -ge $maxAttempts) {
            Log "TeXpop popup HWND never appeared after $maxAttempts attempts ($($maxAttempts*$attemptDelay)ms total)"
        }
    } catch { Log "Foreground promotion threw: $_" }
} else {
    # No fallback to default browser: the popup relies on Edge --app for the
    # frameless overlay + isolated profile. A regular browser tab would be
    # confusing (no auto-close on Esc) and lands outside the security
    # boundary the --app profile gives.
    Fail "Microsoft Edge not found in expected locations. Install Edge or symlink msedge.exe into Program Files\Microsoft\Edge\Application."
}

Flush-Log
