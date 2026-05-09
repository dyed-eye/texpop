# Contributing to texpop

Thanks for your interest — PRs are welcome. This is a small, focused tool, so the bar for accepting changes is "does it fit the existing model and stay easy to maintain?" rather than "does it add a feature." Read the scope sections below before writing code so we don't both end up disappointed.

## What's in scope for PRs

These are the changes most likely to land quickly:

- **New terminal exes for the AHK allowlist.** If you use a terminal that isn't already in `texpop.ahk`'s `TerminalExes` array (e.g. `kitty.exe`, a niche TUI host, a fork of WT), a one-line addition is the ideal first PR. Include a short note in the PR describing how you confirmed the hotkey only fires inside that terminal.
- **New `ChatSourceAdapter` implementations under `adapters/`.** If you run a different CLI agent and it writes a transcript somewhere on disk, write an adapter for it. The current `claude-code.ps1` adapter is the canonical example. The experimental `codex.ps1` adapter is known to be incomplete — fixing it is a perfectly good PR.
- **New callout label colours / types in `template.html`.** The CSS variable system handles `warning`, `tip`/`note`/`key-takeaway`, `danger`/`error` today. Adding e.g. `info` or `success` is a small, contained change.
- **Bug fixes.** Always welcome. Please include reproduction steps in the PR description.
- **Documentation improvements.** README typos, missing setup steps, unclear hotkey table rows, broken links, etc.
- **Performance improvements that keep behaviour identical.** Faster `Find-FocusedSession`, cheaper UIA queries, fewer process tree walks — all good. "Identical" means the same transcript file is picked for the same input, the same Markdown is rendered, and the popup lands at the same coordinates.
- **Linux / macOS port work** — but coordinate first via an issue. texpop is Windows-only today (P/Invoke into `user32`, `dwmapi`, `Shcore`, `ntdll`; UIAutomation; Windows Terminal). A cross-platform port is a documented future direction, not a "send a patch and we'll figure it out" item.

## What's out of scope

Not because these are bad ideas, but because they belong in different projects:

- **VS Code mode.** texpop renders into a popup that overlays your terminal. If you want LaTeX rendering inside VS Code's editor, use [`claude-code-katex`](https://marketplace.visualstudio.com/) or `MathRender`. We won't add a VS Code extension surface here.
- **Web app / `claude.ai` mode.** If you want LaTeX in the Claude.ai web UI, use `Claude-LaTeX-Parser` (or a Tampermonkey-style userscript). texpop's whole reason to exist is *terminal users who can't use those tools*.
- **Large feature additions that change the hotkey-popup-overlay model.** Anything that turns texpop into a daemon, a tray app with persistent state, a chat browser, a multi-window thing, an embedded renderer, etc. — file an issue first to discuss. The "press hotkey, see last message, press Esc" loop is the product. Changing it needs agreement.
- **macOS / Linux ports without coordination.** Open an issue so we can plan the directory layout (where do adapters live? how does the hotkey hook work? what replaces P/Invoke?) before you write code we'd have to reject.
- **Heavyweight runtime dependencies.** No Electron. No Node-required-at-runtime. No Python-required-at-runtime. The tool runs on what Windows already has (PowerShell 5.1, AHK v2 from winget, Edge for rendering) plus the vendored `setup.ps1` downloads (KaTeX + markdown-it as static files). A PR that pulls in a runtime sidecar will be closed.

## The three-layer architecture (so you know which file to edit)

texpop has three components that talk through narrow interfaces. Knowing which layer your change belongs in saves a lot of misdirected work:

1. **`texpop.ahk` (AHK v2)** — The hotkey layer. It owns: when the popup *triggers*, which terminal exes count as "active", and the post-launch `WinActivate` dance that brings the popup to the foreground. It does *not* own: any logic about which transcript to render, any rendering, any DPI math. If your change is "the hotkey should also fire in <terminal X>" or "the hotkey should be <different combo>", this is your file. Otherwise it probably isn't.
2. **`show.ps1` + `adapters/*.ps1` (PowerShell)** — The detection-and-extraction layer. It owns: foreground process tree walking, UIAutomation queries against Windows Terminal, picking the right transcript file via the adapter chain, extracting the last assistant message as Markdown, computing the popup's window-size and window-position in DIPs, and launching Edge with the right flags. If your change is "detect a different agent", "fix focused-tab detection", or "the window lands at the wrong coordinates", this is your file.
3. **`template.html` (HTML / CSS / JS)** — The rendering layer. It owns: how Markdown becomes styled HTML, how callouts are detected and re-styled, KaTeX integration, the Tokyo-Night palette, the Esc-to-close behaviour. If your change is purely visual ("make tables nicer", "add a callout colour", "fix code-block overflow"), this is your file.

The interfaces between layers are: AHK -> PowerShell via a single `Run` of `show.ps1`; PowerShell -> HTML via a placeholder substitution into a temp file plus Edge command-line flags. Don't punch new holes through these boundaries (e.g. don't try to pass JSON from PowerShell into the page via a side-channel) — keep changes layer-local where you can.

## Code style

### PowerShell (`.ps1` files)

- **ASCII-only.** Windows PowerShell 5.1 mis-parses non-ASCII bytes when the file has no BOM, and we don't ship BOMs. No em-dashes, no smart quotes, no `→`, no Greek letters in comments. Use `--`, `"`, `->`, `psi` instead. Verify before committing:

  ```powershell
  Select-String -Path *.ps1 -Pattern '[^\x00-\x7F]'
  ```

  Empty output means you're good. Do this for any `.ps1` you've touched, including files under `adapters/`.
- **No hardcoded user paths.** Use `$env:USERPROFILE`, `$env:LOCALAPPDATA`, `$env:TEMP`. Never write `C:\Users\<anything>\...` literally. The whole point of Phase 1 was stripping these out — don't reintroduce them.
- **PowerShell 5.1 compatibility.** `show.ps1` and the adapters need to run on stock Windows 10/11. Avoid PS7-only syntax:
  - No null-conditional operators (`?.`, `?[]`, `??`, `??=`)
  - No `&&` / `||` between commands (use `if ($LASTEXITCODE -eq 0) { ... }` or `try`/`catch`)
  - No ternary `condition ? a : b` (use `if ($cond) { $a } else { $b }`)
  - Prefer `$null -ne $x` over `$x -ne $null` for the "is not null" idiom — it works on both, and the reverse form trips PSScriptAnalyzer.
- **Logging.** Use the existing `Log` function in `show.ps1`. Don't add `Write-Host`, `Write-Verbose`, or `Write-Output` for diagnostics — they break `-WindowStyle Hidden`. Adapter code should `Log` through the script-scope function it inherits.

### AutoHotkey (`texpop.ahk`)

- **AHK v2 syntax.** The file declares `#Requires AutoHotkey v2.0`. Don't paste v1 snippets — `WinActive("ahk_exe ...")` etc. behaves subtly differently across versions.
- **`#HotIf` for context-sensitive hotkeys.** Hotkeys must be active *only* when a terminal is focused. Look at the existing `#HotIf IsTerminalActive()` block before adding new bindings. Global hotkeys are a no-go.
- **`ToolTip` for instant feedback.** The user pressed the hotkey; they want to see *something* within ~50 ms. `ToolTip "Loading..."` followed by `SetTimer ClearTip, -2200` is the established pattern. `TrayTip` is too slow and gets queued by Windows' notification system — don't use it for this.

### HTML / CSS (`template.html`)

- **Tokyo-Night palette is the default theme.** The CSS variables at the top of the `<style>` block (`--bg`, `--fg`, `--muted`, `--accent`, `--code-bg`, `--border`) drive every colour decision. If you're adding a callout colour, follow the existing pattern: pick a Tokyo-Night accent (e.g. `#bb9af7` purple, `#7dcfff` cyan), define the `border-color` / `background` / `.callout-label` colour as a new block under the existing callout types, and document what label words trigger it in a CSS comment.
- **If you deviate from the palette**, leave a comment in the CSS explaining why. "Matches the warning callout in MkDocs Material" is fine. No comment is not.

### Adding a callout colour — concrete example

Say you want an `info` callout (cyan accent). The pattern in `template.html`:

```css
.callout-info {
  border-color: rgba(125, 207, 255, 0.32);
  background: linear-gradient(135deg, rgba(125,207,255,0.09), rgba(125,207,255,0.02));
}
.callout-info .callout-label { color: #7dcfff; }
.callout-info .callout-label::before {
  background: #7dcfff;
  box-shadow: 0 0 0 4px rgba(125,207,255,0.20),
              0 0 12px rgba(125,207,255,0.55);
}
.callout-info .callout-label::after {
  background: linear-gradient(90deg, rgba(125,207,255,0.55), transparent);
}
```

Add the block alongside the existing `.callout-warning` / `.callout-tip` / `.callout-danger` rules, not in some new file. The label-detection JS already auto-applies `callout-<word>` based on the heading word, so `* Info ──── ...` in assistant Markdown will pick up the new style with no JS changes. If you want a *new* label word (e.g. `key-takeaway` was added this way), add it to the existing class lists in CSS so it shares an existing palette, or add a new palette block following the example above.

### JavaScript (inside `template.html`)

- **No external libraries beyond what's vendored.** KaTeX and markdown-it are downloaded by `setup.ps1` into `vendor/` and referenced by `VENDOR_BASE/...` placeholders. Don't add a third library, even if it's "just one CDN script" — `setup.ps1` keeps the install reproducible and offline-capable.
- **Vanilla JS, existing patterns.** The callout transformer is plain DOM walking with regex matchers. No frameworks, no bundlers, no transpilation. If you're tempted to add ES modules or `import` statements, stop — `template.html` is loaded via `file://` in an Edge `--app=` window and module resolution there is a footgun.

## Writing a new adapter (the 30-second tour)

Most non-trivial PRs touch `adapters/`. Here's the contract every adapter file must fulfil so `show.ps1` can dispatch to it:

1. **Live in `adapters/<name>.ps1` AND register the filename in `show.ps1`.** Adapter loading is an explicit allowlist (the `$adapterAllowlist` array near the top of the adapter-loading block in `show.ps1`), not a `*.ps1` glob — this is intentional, so an unrelated `.ps1` dropped into `adapters/` doesn't auto-execute in script scope. Add your filename to the array; load order follows array order. Pick a name that's a reasonable URL-slug for the agent (`claude-code`, `codex`, `aider`, etc.).
2. **Append a hashtable to `$script:Adapters`** with these keys, all required:
   - `Name` — short string, used in log lines (`adapter=claude-code`).
   - `Description` — one-liner for humans.
   - `Match` — scriptblock taking `$candidates` (the tree-walk result, an array of `Win32_Process` objects). Returns `$true` if this adapter recognises one of those processes as its agent. Match cheaply — string-compare on `Name` and `CommandLine`. Don't read files in `Match`.
   - `FindFocusedSession` — scriptblock taking `$candidates`, `$fgTitle`, `$wtTabName`. Returns a `[System.IO.FileInfo]` for the transcript file to render, or `$null`. This is where you do the real work: figure out which transcript belongs to the focused chat and return its path.
   - `GetLastAssistantTurn` — scriptblock taking `[System.IO.FileInfo]`. Returns the last assistant message as Markdown (a string). Strips tool calls, role headers, and anything else that isn't prose.
3. **Log liberally** through the inherited `Log` function. The diagnostic hotkey opens that log; it's how users will tell you what went wrong.
4. **Never throw out of `Match` or `FindFocusedSession`.** `show.ps1` catches exceptions and skips the adapter, but the user only sees "no session" — not the real cause. Wrap your own work in `try`/`catch` and `Log "MyAdapter: <reason>"` instead.

Read `adapters/claude-code.ps1` end-to-end before writing your own. It's the spec.

## Testing your change

There is no automated test suite. Manual verification is the bar.

- **The standard manual test.** Drop your edited files into your local install (or repoint `texpop.ahk` at the sandbox copy), reload AHK, press `Ctrl+Alt+Shift+V` (the diagnostic hotkey). This runs `show.ps1 -Diagnose` and opens `%TEMP%\texpop-debug.log` in Notepad. Verify the log shows what you expect: foreground process detected, adapter matched, session file picked, message extracted, no exceptions.
- **For adapter changes:** test with at least two open chats so the focused-detection logic is actually exercised. Open chat A in one Windows Terminal tab and chat B in another, focus A, hit the hotkey, confirm A renders. Switch to B, hit the hotkey, confirm B renders. If both runs render the same chat, your adapter's `FindFocusedSession` is broken — don't ship it.
- **For window-overlay changes:** test on at least two DPI scaling settings. 100% (a typical 1080p monitor) and >=150% (a typical laptop or 4K display). The popup should land flush over the terminal window in both cases. DPI mistakes show up as "popup is half the size of the terminal" or "popup is shifted up and left" — both regressions of the PMv2 / DIP conversion in `show.ps1`.
- **For new terminal exes:** confirm the hotkey only fires inside that terminal, not in random other apps. Open the terminal, press `Ctrl+Alt+V`, see the popup. Switch to Notepad / a browser / Explorer, press `Ctrl+Alt+V`, see *nothing*. If the hotkey fires outside the terminal, your `TerminalExes` entry is wrong (typo in exe name) or `IsTerminalActive` is being bypassed somehow.

### Iterating quickly without the AHK round-trip

When you're debugging a `show.ps1` or adapter change, you don't need to reload AHK every time. Run `show.ps1` directly from a PowerShell prompt with `-Diagnose`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\path\to\texpop\show.ps1 -Diagnose
```

This skips the Edge launch, runs the full detection pipeline against whichever window was foreground when you pressed Enter (so click into your terminal first, then `alt-tab` back and run the command — the foreground at *invocation* time is what gets inspected). The debug log opens in Notepad. Re-run after each edit. AHK only needs reloading when you change `texpop.ahk` itself.

For `template.html` changes, an even faster loop: trigger the popup once normally, then grab the resulting `%TEMP%\texpop-<guid>.html` (filename includes a per-invocation 8-char id; pick the most recent) and re-open it in your browser. Edit-reload for layout work. The Markdown content is baked in at render time, so reusing that file gives you a real message to test against without re-running the whole pipeline. Stale files prune themselves after 5 minutes.

## Common failure modes during development

A non-exhaustive list of things that will bite you, with the fix:

- **"Hotkey doesn't fire."** Check that AHK is actually running (tray icon present), that you reloaded the script after editing (`Right-click tray -> Reload Script`), and that the foreground window's exe matches one of `TerminalExes`. AHK's `Window Spy` tool (also in the tray menu) shows the active `ahk_exe` value — paste that into the array if needed.
- **"Popup opens but renders 'Loading...' forever."** Almost always a JavaScript error in `template.html`. Open the popup, press `Ctrl+Shift+I` to get DevTools, check the console. Common cause: a regex in the callout transformer threw on unexpected input.
- **"Popup is positioned wrong on a high-DPI monitor."** The DIP / physical pixel conversion in `show.ps1` (the `$scale = $dpi / 96.0` block) is the culprit. Verify `Log` lines show a sensible scale (1.0 at 100%, 1.5 at 150%, 2.0 at 200%) — if you see `scale=1.0` on a 4K laptop, the process isn't PMv2-aware and `SetThreadDpiAwarenessContext` failed silently.
- **"PowerShell parser error after I edited a `.ps1`."** Run the ASCII check (`Select-String -Path *.ps1 -Pattern '[^\x00-\x7F]'`). If it returns lines, your editor inserted a smart quote or em-dash. Replace with ASCII equivalents and re-save.
- **"Adapter doesn't match my agent."** Add a `Log` line at the start of your `Match` block dumping `$candidates | ForEach-Object { $_.Name + ' ' + $_.CommandLine }`, run the diagnostic hotkey, and read the log. The actual exe and command line are almost always different from what you assumed.

## Commit style

- **One logical change per commit.** "Add codex adapter and fix WT tab detection and update README" is three commits, not one. The log should read like a changelog, not a diary.
- **Imperative present tense.** `add codex adapter`, not `added codex adapter` or `adds codex adapter`. This matches `git`'s own conventions and the existing history.
- **Conventional-commits prefixes welcome but not required.** `feat:`, `fix:`, `docs:`, `refactor:`, `chore:` — use them if you like them. Don't use them if they feel like noise. We won't reject a PR over the prefix.
- **Subject line under ~72 characters.** Wrap the body at ~72 too. Standard `git` etiquette.

## Pull request checklist

Before opening the PR, tick these mentally:

- [ ] Branch is rebased on the current `main`
- [ ] Manual test passed (see "Testing your change" above)
- [ ] No Unicode regression in `.ps1` files (run the `Select-String` check)
- [ ] No hardcoded user paths reintroduced (`grep` for `C:\Users\` and `/Users/`)
- [ ] README updated if the change affects user-visible behaviour (hotkey, install, customisation)
- [ ] Commit messages are imperative present tense and one-change-per-commit
- [ ] PR description explains *why* the change is needed, not just what it does

If you can't tick "manual test passed" because you don't have a Windows machine, say so in the PR description and tag the maintainer — we'll either run it locally or close the PR with an explanation.

## Filing a useful bug report

If you're filing an issue rather than a PR, the report that gets fixed fastest looks like this:

1. **Windows version** (`winver` -> screenshot or version string).
2. **Terminal you were using** and its version (Windows Terminal / WezTerm / Alacritty / etc.).
3. **Which CLI agent** (Claude Code, Codex, other) and roughly its version.
4. **What you pressed and what happened.** "Pressed `Ctrl+Alt+V`, popup opened but was empty" is good. "It's broken" is not.
5. **The diagnostic log.** Press `Ctrl+Alt+Shift+V`, copy the contents of `%TEMP%\texpop-debug.log`, and paste into the issue inside a code fence. Redact any path you don't want public — but please leave the `Log` lines intact, they're how we trace the failure.
6. **DPI scaling** of the affected monitor (`Settings -> Display -> Scale`). 100%, 125%, 150%, 200% all behave differently.

A bug report with all six items is usually fixed in one commit. A bug report with two of them turns into a five-message back-and-forth and probably stalls.

## How to propose a new feature

For anything bigger than a one-line `TerminalExes` addition or a colour tweak, **open an issue before writing code.** The issue should cover:

1. **Use case.** What are you trying to do that texpop doesn't do today? Concrete example, not "I think it would be nice if...".
2. **Smallest possible API change.** If the answer is "add a config file with 14 options", the answer is probably "no". If the answer is "add one optional parameter to one function", we're in business.
3. **Platform implications.** Does this assume Windows? Does it require a new vendor download? Does it touch the AHK / PowerShell / HTML boundary in a new way? Spell it out.

We'd genuinely rather say "no, here's why" early than merge a feature we'll regret six months from now and have to deprecate. Saying no isn't personal — it's how the tool stays small enough to keep working.

## Maintainer status

texpop is a personal-scratch project. It exists because the maintainer wanted it; it's published because someone else might too. It is not a company product, has no sponsor, no roadmap, and no SLA. Review timelines are best-effort and should be measured in **weeks, not days** — sometimes longer if life is busy.

If your PR sits for a while, please be patient and don't take silence personally. A polite ping after two or three weeks is fine. Two pings in a week is not.

The project is MIT licensed. You're free to fork it, repackage it, vendor it into your own tool, or rewrite it in Rust. If you do something interesting with it, drop a link in an issue — that's always nice to see.
