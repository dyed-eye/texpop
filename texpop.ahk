; texpop.ahk -- AutoHotkey v2 hotkeys for show.ps1
;
; Part of texpop (https://github.com/dyed-eye/texpop).
;
; Hotkeys (active ONLY when a terminal window has focus):
;   Ctrl + Alt + V           ->  render the focused chat's last message (one-shot)
;   Ctrl + Alt + S           ->  stream mode: persistent companion window that
;                                live-updates as new answers arrive in the chat.
;                                Press again (in any chat) to re-pin it there.
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

ShowPs1   := A_ScriptDir "\show.ps1"
StreamPs1 := A_ScriptDir "\stream.ps1"

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
^!s::TriggerStream
^+!v::TriggerDiagnose
#HotIf

TriggerPopup(*) {
    global ShowPs1
    if !FileExist(ShowPs1) {
        MsgBox "show.ps1 not found at:`n" ShowPs1, "texpop", "Iconx"
        return
    }
    ToolTip "Loading last message..."
    ; Fallback timer: clears the tooltip if the popup never appears (failure
    ; case). When the popup IS detected, ActivateLatexPopup clears it
    ; immediately, so the timer fires harmlessly on already-cleared state.
    ; 6000 ms is long enough for Edge cold-boot on slower machines.
    SetTimer ClearTip, -6000

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
    ; Poll every 120 ms until the popup window appears, up to ~6 s -- matches
    ; the fallback ClearTip timer so the tooltip and the activation give up
    ; at the same moment on a failed launch.
    SetTimer ActivateLatexPopup.Bind(0), -200
}

ActivateLatexPopup(attempt) {
    static MAX_ATTEMPTS := 50  ; ~6 s total (50 * 120ms)
    title := "TeXpop"
    if WinExist(title) {
        ; Window is up -- kill the "Loading..." tooltip immediately, so the
        ; user doesn't see it linger after the popup has appeared (and doesn't
        ; see it vanish before the popup appears on slow cold-boot).
        ToolTip
        try {
            WinActivate(title)
            WinSetAlwaysOnTop(true, title)
            Sleep(40)
            WinSetAlwaysOnTop(false, title)
            WinActivate(title)
        }
        return
    }
    if (attempt < MAX_ATTEMPTS) {
        SetTimer ActivateLatexPopup.Bind(attempt + 1), -120
    }
}

TriggerStream(*) {
    global StreamPs1
    if !FileExist(StreamPs1) {
        MsgBox "stream.ps1 not found at:`n" StreamPs1, "texpop", "Iconx"
        return
    }
    ToolTip "Stream mode..."
    SetTimer ClearTip, -4000

    ; stream.ps1 is long-lived and positions + focuses its own window (both on
    ; fresh launch and on re-pin), so -- unlike TriggerPopup -- AHK does not
    ; poll for the window afterwards. Grant the right to set foreground once so
    ; the PowerShell child's SetForegroundWindow call is honoured.
    DllCall("AllowSetForegroundWindow", "uint", 0xFFFFFFFF)

    cmd := 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' StreamPs1 '"'
    try {
        Run cmd, , "Hide"
    } catch Any as err {
        ToolTip
        MsgBox "Run failed:`n" err.Message, "texpop", "Iconx"
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
