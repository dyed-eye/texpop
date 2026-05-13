; texpop.ahk -- AutoHotkey v2 hotkeys for show.ps1
;
; Part of texpop (https://github.com/dyed-eye/texpop).
;
; Hotkeys (active ONLY when a terminal window has focus):
;   Ctrl + Alt + V           ->  render the focused chat's last message
;   Ctrl + Alt + Shift + V   ->  diagnostic-only run; opens debug log in Notepad
;
; Setup:
;   1. Install AutoHotkey v2 (e.g. `winget install AutoHotkey.AutoHotkey`,
;      or download from https://www.autohotkey.com/). This installs
;      AutoHotkey64.exe somewhere under your user profile.
;   2. Double-click this .ahk file to run it
;   3. (Optional) Add a shortcut in shell:startup to auto-load on login.

#Requires AutoHotkey v2.0
#SingleInstance Force

ShowPs1 := A_ScriptDir "\show.ps1"

; List of process exe names that count as "terminals" for hotkey activation.
; Add more here if you use a different terminal (e.g. "wezterm-gui.exe").
TerminalExes := [
    "WindowsTerminal.exe",
    "conhost.exe",
    "powershell.exe",
    "pwsh.exe",
    "cmd.exe",
    "wezterm-gui.exe",
    "alacritty.exe",
    "Hyper.exe"
]

IsTerminalActive() {
    global TerminalExes
    for exe in TerminalExes {
        if WinActive("ahk_exe " exe)
            return true
    }
    return false
}

#HotIf IsTerminalActive()
^!v::TriggerPopup
^+!v::TriggerDiagnose
#HotIf

AmbiguousFlag := A_Temp "\texpop-ambiguous.flag"

TriggerPopup(*) {
    global ShowPs1, AmbiguousFlag
    if !FileExist(ShowPs1) {
        MsgBox "show.ps1 not found at:`n" ShowPs1, "texpop", "Iconx"
        return
    }
    ; Clear any stale ambiguous flag from a previous run.
    if FileExist(AmbiguousFlag) {
        try FileDelete AmbiguousFlag
    }
    ToolTip "Loading last message..."
    SetTimer ClearTip, -2200

    ; Grant any descendant process the right to set foreground (one-shot).
    DllCall("AllowSetForegroundWindow", "uint", 0xFFFFFFFF)

    cmd := 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' ShowPs1 '"'
    try {
        Run cmd, , "Hide"
    } catch Any as err {
        ToolTip
        MsgBox "Run failed:`n" err.Message, "texpop", "Iconx"
        return
    }

    ; Use AHK's hardened foreground-activation (uses AttachThreadInput under the hood).
    ; Poll every 120 ms until the popup window appears, up to ~3 s.
    SetTimer ActivateLatexPopup.Bind(0), -200
}

ActivateLatexPopup(attempt) {
    global AmbiguousFlag
    static MAX_ATTEMPTS := 25  ; ~3 s total
    title := "TeXpop"
    if WinExist(title) {
        try {
            WinActivate(title)
            WinSetAlwaysOnTop(true, title)
            Sleep(40)
            WinSetAlwaysOnTop(false, title)
            WinActivate(title)
        }
        return
    }
    ; show.ps1 sets this when it refuses to guess between multiple Claude
    ; tabs. Replace the 'Loading...' tooltip with a rename hint and stop
    ; polling -- no popup window is coming.
    if FileExist(AmbiguousFlag) {
        try FileDelete AmbiguousFlag
        ToolTip "/rename the chat"
        SetTimer ClearTip, -2500
        return
    }
    if (attempt < MAX_ATTEMPTS) {
        SetTimer ActivateLatexPopup.Bind(attempt + 1), -120
    }
}

TriggerDiagnose(*) {
    global ShowPs1
    if !FileExist(ShowPs1) {
        MsgBox "show.ps1 not found at:`n" ShowPs1, "texpop", "Iconx"
        return
    }
    ToolTip "Diagnosing... (Notepad will open)"
    SetTimer ClearTip, -2500

    cmd := 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' ShowPs1 '" -Diagnose'
    try {
        Run cmd, , "Hide"
    } catch Any as err {
        ToolTip
        MsgBox "Run failed:`n" err.Message, "texpop", "Iconx"
    }
}

ClearTip(*) {
    ToolTip
}
