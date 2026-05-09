# texpop

*Hotkey LaTeX popup for Claude Code (and Codex, experimentally) — overlays your terminal, picks the focused chat, renders Markdown + KaTeX.*

<!-- Demo GIF will be added in v0.1.0 release -->
![demo](assets/screenshots/demo.gif)

**Press `Ctrl + Alt + V` in any Claude Code terminal session.**
**The last assistant message renders as Markdown + LaTeX in a window that overlays the terminal exactly.**
**`Esc` closes. Press the hotkey again to refresh with the latest reply.**

`texpop` is a **LaTeX parser for Claude Code** and a math renderer for Claude Code that lives outside your editor. If you use Claude Code or the Codex CLI inside Windows Terminal, conhost, WezTerm, or any other Windows console, texpop is the Claude Code popup that finally makes Markdown LaTeX preview work — KaTeX rendering, focused chat detection, DPI-correct overlay, fully offline. No VS Code required, no browser tab juggling, no Tampermonkey scripts that only target the web app.

---

## Table of contents

- [Why this exists](#why-this-exists)
- [Comparison](#comparison)
- [Features](#features)
- [Install](#install)
- [Use](#use)
- [How it picks the focused chat](#how-it-picks-the-focused-chat)
- [Customisation](#customisation)
- [Adapter coverage](#adapter-coverage)
- [Known limitations](#known-limitations)
- [Troubleshooting](#troubleshooting)
- [Status](#status)
- [Credits](#credits)
- [License](#license)

---

## Why this exists

Every existing LaTeX renderer for Claude assumes you live in a specific surface. VS Code extensions like `claude-code-katex` and MathRender only fire when you run Claude Code as a VS Code task — they're useless if you launch `claude` from Windows Terminal, conhost, WezTerm, or any other terminal. Tampermonkey scripts like `Claude-LaTeX-Parser` and `Claude-LaTeX-Math-Renderer` only target `claude.ai` in the browser — they never see the CLI. And **none** of them solve the harder problem: when you have several Claude Code chats open across tabs and panes, *which* one are you looking at right now? texpop is the first Windows Terminal LaTeX renderer built specifically for terminal-CLI users, and the only one that detects the focused chat instead of guessing the newest file.

---

## Comparison

| Tool | Surface | LaTeX render | Markdown + math context | Picks focused chat | Window matches terminal | Custom callouts | Offline |
|---|---|:---:|:---:|:---:|:---:|:---:|:---:|
| **texpop** | Terminal (Windows Terminal, conhost, WezTerm, ...) | ✅ KaTeX | ✅ | ✅ | ✅ | ✅ | ✅ |
| claude-code-katex (VS Code) | VS Code only | ✅ KaTeX | ✅ | ❌ | ❌ | ❌ | ✅ |
| MathRender (VS Code) | VS Code only | ✅ MathJax | partial | ❌ | ❌ | ❌ | ✅ |
| Claude-LaTeX-Parser (Tampermonkey) | claude.ai web only | ✅ | partial | ❌ | ❌ | ❌ | ❌ |
| Claude-LaTeX-Math-Renderer (Tampermonkey) | claude.ai web only | ✅ | partial | ❌ | ❌ | ❌ | ❌ |

If you run Claude Code in a terminal, texpop is the only choice — every other tool requires you to be either in VS Code or in the browser.

---

## Features

- **Hotkey-triggered.** `Ctrl + Alt + V` from any allowlisted terminal, anywhere in your Claude Code session. No menu hunting, no command palette.
- **Focused-chat detection.** PEB CWD reads + UIAutomation tab name + `ai-title` transcript matching pick the chat you're actually looking at, even with five Claude Code tabs open in Windows Terminal.
- **DPI-correct overlay.** The popup window matches the terminal's exact pixel rectangle, with per-monitor DPI v2 awareness — drag your terminal between a 100% and 200% display and it still lines up.
- **KaTeX rendering.** Inline `$...$`, display `$$...$$`, and `\(...\)` / `\[...\]` delimiters all render. Pre-loaded macros for Dirac notation (`\ket`, `\bra`, `\braket`), `\Tr`, blackboard sets (`\R`, `\C`, `\Z`, `\N`), and `\eps`.
- **Full Markdown.** Headings, lists, tables, blockquotes, fenced code blocks — markdown-it 14.x renders the lot, with math interleaved naturally.
- **Custom callout styling.** Patterns like `* Insight ──── body ────` automatically transform into styled callout cards (Insight, Tip, Note, Warning, Danger, Caution, Error, Key-Takeaway).
- **Offline by default.** KaTeX 0.16.x and markdown-it 14.x are vendored locally by `setup.ps1`; once installed, texpop never touches the network.
- **Customisable hotkey.** Edit one line in `texpop.ahk` to rebind to any AutoHotkey v2 combo.
- **Customisable icon.** Drop `assets/icon-override.{svg,png,jpg,ico}` to replace the default Tokyo-Night `ψ` favicon.
- **Customisable window size.** Pass `-Width` / `-Height` to `show.ps1`, or let texpop auto-size to the terminal.
- **Codex CLI adapter (experimental).** A `ChatSourceAdapter` for Codex CLI ships in `adapters/codex.ps1`. Contributions welcome to harden it.
- **Diagnostic mode.** `Ctrl + Alt + Shift + V` runs the detection cascade without launching the popup and opens the debug log in Notepad.
- **MIT licensed.** Personal-scratch project, but yours to fork, ship, and modify. Windows 10/11 supported.

---

## Install

1. **Install AutoHotkey v2.**

   ```powershell
   winget install AutoHotkey.AutoHotkey
   ```

2. **Clone the repo into your Claude scripts directory.**

   ```powershell
   git clone https://github.com/dyed-eye/texpop.git "$env:USERPROFILE\.claude\scripts\texpop"
   ```

3. **Run setup to fetch KaTeX and markdown-it.** This pulls KaTeX 0.16.x, markdown-it 14.x, and the KaTeX font files into `vendor/`. Idempotent — re-run anytime to refresh.

   ```powershell
   powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\scripts\texpop\setup.ps1"
   ```

4. **Double-click `texpop.ahk`.** The green `H` AutoHotkey tray icon appears. The hotkey is now live in any allowlisted terminal.

5. **(Optional) Auto-launch on login.** Drop a shortcut to `texpop.ahk` into `shell:startup` (Win + R, type `shell:startup`, hit Enter, paste the shortcut there).

---

## Use

| Hotkey | Where | What it does |
|---|---|---|
| `Ctrl + Alt + V` | Any allowlisted terminal | Detects the focused Claude Code chat and renders its last assistant message |
| `Ctrl + Alt + Shift + V` | Any allowlisted terminal | Diagnostic mode — runs detection without launching the popup, opens `%TEMP%\texpop-debug.log` in Notepad |
| `Esc` | Inside the popup | Close the popup |

Typical workflow: you're chatting with Claude Code about a physics or math problem. Claude replies with `\ket{\psi}`, a `$$\hat{H}\ket{\psi} = E\ket{\psi}$$` display equation, and a `* Insight ────` callout summarising the result. In the terminal, that's raw text. Press `Ctrl + Alt + V` and the same reply pops up rendered — properly typeset math, styled callout, syntax-highlighted code blocks. Read it, hit `Esc`, you're back in the terminal. Ask the next question, hit `Ctrl + Alt + V` again to refresh. The popup window is sized and positioned to overlap the terminal exactly, so your eyes don't have to relocate.

---

## How it picks the focused chat

This is the part most LaTeX preview tools skip. If you have three Claude Code sessions running in three Windows Terminal tabs, "newest `.jsonl`" is wrong — the active tab might not be the most recently written one. texpop runs a cascade:

1. **Capture the foreground HWND** the moment the hotkey fires.
2. **If the foreground process is `WindowsTerminal.exe`**, query UIAutomation to read the **selected** `TabItem`'s name. That's whatever Windows Terminal currently displays on the active tab.
3. **Walk the foreground process tree** via `Win32_Process`, collecting every descendant — `claude.exe`, `node.exe` running Claude Code, `codex.exe`, `node.exe` running Codex, anything an adapter cares about.
4. **Read each candidate's current working directory** by opening the process with `PROCESS_QUERY_INFORMATION | PROCESS_VM_READ`, calling `NtQueryInformationProcess` to get the PEB base address, then `ReadProcessMemory` to chase `PEB → ProcessParameters → CurrentDirectory.DosPath`. That's the CWD as the process actually sees it.
5. **Map each CWD to its Claude project directory** under `~/.claude/projects/<encoded-path>/` (the same encoding Claude Code uses).
6. **Scan each candidate project's `.jsonl` transcripts** for `{"type":"ai-title","aiTitle":"..."}` events.
7. **Match against the Windows Terminal tab title.** The session whose `aiTitle` matches the WT tab name (or the foreground window title for non-WT terminals) wins — that's the focused chat.
8. **Fall back to "newest `.jsonl` among candidates"** if no `aiTitle` matches, then to "globally newest `.jsonl`" if process tree detection failed entirely.

The heavy lifting lives in `show.ps1` (orchestrator) and `adapters/claude-code.ps1` (the canonical adapter implementation). Run `Ctrl + Alt + Shift + V` to see the whole cascade in `%TEMP%\texpop-debug.log`.

---

## Customisation

### Change the hotkey

Open `texpop.ahk`. Find:

```ahk
#HotIf IsTerminalActive()
^!v::TriggerPopup
^+!v::TriggerDiagnose
#HotIf
```

Replace `^!v` and `^+!v` with any AutoHotkey v2 combo. Quick cheatsheet:

| AHK | Combo |
|---|---|
| `^` | Ctrl |
| `!` | Alt |
| `+` | Shift |
| `#` | Win |
| `^!l` | Ctrl + Alt + L |
| `^+m` | Ctrl + Shift + M |
| `!F1` | Alt + F1 |
| `#l` | Win + L (avoid — locks Windows) |

Save and right-click the tray icon → **Reload Script**.

### Replace the icon

texpop resolves the popup favicon in this order, first match wins:

1. `assets/icon-override.svg`
2. `assets/icon-override.png`
3. `assets/icon-override.jpg`
4. `assets/icon-override.ico`
5. `assets/icon-default.svg` (the bundled Tokyo-Night `ψ`)

Drop your file into `assets/` with the right name and the popup uses it on the next launch. If the favicon doesn't update, delete `%LOCALAPPDATA%\texpop\edge-profile-v2` to nuke Edge's icon cache.

### Add a callout type

texpop's callout transformer fires on patterns like `* Label ──── body ────` at the start of a paragraph or list item. The callout class becomes `callout-<lowercased-label>`. To style a new label `Mytype`, add a CSS rule in `template.html` next to the existing `.callout-warning` / `.callout-tip` / `.callout-danger` blocks:

```css
.callout-mytype {
  border-color: rgba(180, 142, 173, 0.32);
  background: linear-gradient(135deg, rgba(180,142,173,0.10), rgba(180,142,173,0.02));
}
.callout-mytype .callout-label { color: #b48ead; }
.callout-mytype .callout-label::before {
  background: #b48ead;
  box-shadow: 0 0 0 4px rgba(180,142,173,0.20),
              0 0 12px rgba(180,142,173,0.55);
}
.callout-mytype .callout-label::after {
  background: linear-gradient(90deg, rgba(180,142,173,0.55), transparent);
}
```

Then any reply containing `* Mytype ──── ...` renders with your palette. Built-in palettes already cover Insight, Tip, Note, Warning, Caution, Warn, Danger, Error, and Key-Takeaway.

### Add a terminal exe

If your terminal isn't allowlisted, the hotkey won't fire. Add it to the `TerminalExes` array near the top of `texpop.ahk`:

```ahk
TerminalExes := [
    "WindowsTerminal.exe",
    "conhost.exe",
    "powershell.exe",
    "pwsh.exe",
    "cmd.exe",
    "wezterm-gui.exe",
    "alacritty.exe",
    "Hyper.exe",
    "your-terminal.exe"
]
```

Reload the script (tray icon → **Reload Script**).

### Custom window size

texpop auto-sizes the popup to the foreground terminal's pixel rectangle (DPI-corrected). To override, call `show.ps1` directly with explicit dimensions:

```powershell
powershell -ExecutionPolicy Bypass -File show.ps1 -Width 900 -Height 700
```

If the foreground rect is unusable (very small or off-screen), texpop falls back to the `-Width` / `-Height` defaults (720 × 540).

---

## Adapter coverage

texpop is built around a `ChatSourceAdapter` interface — each AI CLI gets its own adapter file in `adapters/`. The orchestrator in `show.ps1` walks the foreground process tree, then asks each registered adapter "is this yours?" The first adapter to match owns the rest of the pipeline: pick the focused session file, parse the transcript, return the last assistant message as Markdown.

| Adapter | File | Status |
|---|---|---|
| Claude Code | `adapters/claude-code.ps1` | Stable, primary target. Reads `~/.claude/projects/<encoded>/*.jsonl`, joins assistant text by `requestId`, matches `aiTitle` against window/tab titles. |
| Codex CLI | `adapters/codex.ps1` | Experimental. Best-effort transcript discovery; format may shift between Codex CLI versions. PRs welcome — verify against your installed Codex version and submit fixes. |

Adding a new adapter is a single PowerShell file that exposes `Name`, `Description`, `Match`, `FindFocusedSession`, `GetLastAssistantTurn` and appends itself to `$script:Adapters`. Use `adapters/claude-code.ps1` as the template.

---

## Known limitations

### `/btw` exchanges may not appear

Claude Code's built-in `/btw` slash command does not always persist its question/answer pair to the session JSONL on disk — at least not synchronously. The exchange shows up live in the terminal but may never reach `~/.claude/projects/<encoded>/<sessionid>.jsonl`, or it lands there with significant delay.

texpop reads from disk. If Claude Code hasn't written the `/btw` exchange to the transcript file by the time you press the hotkey, **there is nothing for texpop (or any external tool) to render** — so the popup falls through to the previous on-disk assistant turn.

The adapter does have detection logic for `/btw` and `/aside`: if the most-recent user message in the transcript starts with `/btw` or `/aside`, the popup prefixes the answer with `## /btw` or `## /aside` so the modal nature is visually explicit. That code is dormant until Claude Code starts persisting these exchanges reliably.

This is upstream behavior, not a texpop bug. Track [`anthropics/claude-code`](https://github.com/anthropics/claude-code) for any change in `/btw` persistence semantics.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Hotkey doesn't fire | Your terminal exe isn't in the allowlist | Add it to `TerminalExes` in `texpop.ahk` and reload |
| Hotkey doesn't fire | The AutoHotkey process was killed | Re-run `texpop.ahk` (or check the `H` tray icon is present) |
| Wrong session opens | UIA tab title or `aiTitle` mismatch | `Ctrl + Alt + Shift + V` to dump the debug log; check the cascade output in `%TEMP%\texpop-debug.log` |
| Popup is wrong size or off-screen | Per-monitor DPI v2 unavailable | texpop requires Windows 10 build 1607+ for full DPI correctness; older builds may fall back to logical pixels |
| `Edge not found` error | Microsoft Edge is missing | Install Edge (`winget install Microsoft.Edge`); texpop falls back to the default browser if Edge isn't found, but loses window-positioning |
| Favicon doesn't update after override | Edge cached the old icon | Delete `%LOCALAPPDATA%\texpop\edge-profile-v2` and re-trigger |
| `vendor/ missing` error | `setup.ps1` was never run | Run `setup.ps1` to fetch KaTeX and markdown-it |
| Popup is empty / unstyled | Vendor files corrupted or partial download | Re-run `setup.ps1 -Force` to refetch everything |
| No math renders | The reply has no math delimiters | Confirm the reply contains `$...$`, `$$...$$`, `\(...\)`, or `\[...\]` |

---

## Status

Personal-scratch project, MIT licensed. No support guarantees, no roadmap commitments, no SLA — texpop scratches my own itch and I'm publishing it because the same itch keeps showing up in `anthropics/claude-code` issues. PRs are welcome for: new terminal exes, new `ChatSourceAdapter` implementations, new callout palettes, bugfixes, and documentation. Out of scope: VS Code integration (use `claude-code-katex` instead), web-mode rendering (use a Tampermonkey script), and large feature additions that drift from "render the focused chat's last reply, fast." If you want something bigger, fork it.

---

## Credits

Built on the shoulders of:

- **[KaTeX](https://katex.org/)** — fast math typesetting for the web (MIT).
- **[markdown-it](https://github.com/markdown-it/markdown-it)** — pluggable Markdown parser (MIT).
- **[AutoHotkey v2](https://www.autohotkey.com/)** — Windows hotkey + window automation (GPLv2).
- **[Anthropic](https://www.anthropic.com/)** — for [Claude Code](https://github.com/anthropics/claude-code), the CLI this tool wraps.
- **[OpenAI](https://openai.com/)** — for the [Codex CLI](https://github.com/openai/codex), the experimental second adapter target.

The default `ψ` favicon uses the Tokyo-Night palette.

---

## License

MIT — see [LICENSE](LICENSE).
