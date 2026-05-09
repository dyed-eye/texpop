# texpop — Publish Plan

**Project name:** `texpop`
**Tagline:** *Hotkey LaTeX popup for Claude Code (and Codex) — overlays your terminal, picks the focused chat, renders Markdown + KaTeX.*
**License:** MIT
**Target:** Windows 10/11. Cross-platform later (see Task #24).
**Repo description (SEO):** `LaTeX parser and popup renderer for Claude Code & Codex CLI — press a hotkey, see your AI's math beautifully rendered over the terminal. KaTeX, focused-chat detection, DPI-correct, no VS Code required.`

**Workspace layout:**
- **`C:\emae\sandbox\texpop\`** — dev workspace, this becomes the GitHub repo
- **`~/.claude/scripts/texpop/`** — your personal install (untouched; AHK keeps pointing here)

When dev is stable, you can either (a) leave the personal install where it is and just publish the sandbox copy, or (b) repoint AHK at the sandbox copy.

**Commit discipline:** every meaningful change is its own commit. No "refactor everything + add README" mega-commits. The task list (#13–#24) is ordered roughly chronologically; each task yields 1–2 commits.

---

## Phase 1 — Refactor for portability

Strip everything personal. Generic, swappable, ready for any user.

- Replace hardcoded `C:\Users\<user>\...` with `$env:USERPROFILE` / `$HOME` everywhere
- Sweep all comments / log strings for personal identifiers or local-machine references
- Replace `dubstepgun.png` with a clean default favicon (Tokyo-Night `ψ` SVG)
- Document how users swap in their own icon (drop a file into `assets/`)
- Make the AHK terminal allowlist configurable via a top-of-script array (already is)

## Phase 2 — Adapter pattern for AI tools

Make `texpop` agnostic across CLI agents. Extract a `ChatSourceAdapter` interface:

- `ClaudeCodeAdapter` (current): reads `~/.claude/projects/<encoded-cwd>/*.jsonl`, scans for `aiTitle`, joins assistant text by `requestId`
- `CodexAdapter` (stub): research transcript location (`~/.codex/sessions/`?), implement when format known
- Auto-pick adapter from foreground process tree: see `node.exe` running `claude` → Claude; see `node.exe` running `codex` → Codex
- Each adapter exposes the same surface: `findFocusedSession() → {sessionFile, aiTitle?}` and `lastAssistantMessage(file) → markdown`

## Phase 3 — Repo bootstrap

- `git init` in `scripts\texpop\`
- `LICENSE` (MIT, year 2026, copyright the user's GitHub handle)
- `.gitignore` — exclude `vendor/`, `assets/edge-profile*/`, `%TEMP%` artifacts, debug logs
- `setup.ps1` already handles vendor download — README will tell users to run it after clone
- `CONTRIBUTING.md` — short: PRs welcome for new terminals/adapters/styles, scope kept tight
- Tag `v0.1.0` after first stable run

## Phase 4 — README (SEO-heavy, demand-covering)

Order:
1. **H1:** `texpop` + tagline
2. **Hero GIF** (10–15 s loop: hotkey → popup overlay → math + Insight callout → Esc)
3. **3-line hook:** "Press `Ctrl+Alt+V` in any Claude Code terminal session. Last assistant message renders as Markdown + LaTeX in a window that overlays the terminal exactly. Esc closes."
4. **Why it exists** — short paragraph: VS Code extensions don't help if you run Claude Code in Windows Terminal / conhost / WezTerm. This fills that gap.
5. **Comparison table** (vs `claude-code-katex`, MathRender, Claude-LaTeX-Parser, etc.)
6. **Features** — bulleted, with screenshot links
7. **Install** — `winget install AutoHotkey.AutoHotkey` + `git clone` + `setup.ps1`
8. **Use** — hotkey table, customisation
9. **How it picks the focused chat** — paragraph on PEB/UIA/`aiTitle` matching (the "wow" trick)
10. **Customisation** — change hotkey, change icon, add callout types, change window size override
11. **Adapter coverage** — Claude Code today, Codex planned, contribute via `ChatSourceAdapter`
12. **Troubleshooting** — `Ctrl+Alt+Shift+V` for debug log, common failures + fixes
13. **License** + Credits

SEO keywords (sprinkled, not stuffed): *LaTeX parser for Claude Code, math renderer, KaTeX popup, Windows Terminal, focused chat detection, Markdown LaTeX preview, Claude Code tools, AI CLI math rendering, Codex LaTeX*.

GitHub repo topics: `claude-code`, `latex-parser`, `latex-renderer`, `katex`, `math-rendering`, `markdown-renderer`, `windows-terminal`, `autohotkey`, `powershell`, `popup`, `claude-code-tools`, `codex`, `developer-tools`.

## Phase 5 — Assets

- `assets/screenshots/`: math render, callout block, terminal-overlay-screenshot, focused-tab-detection diagram
- `assets/demo.gif` — 10-15 s loop
- `assets/icon.svg` — default `ψ` favicon

## Phase 6 — Verification before push

- Delete `%LOCALAPPDATA%\texpop\edge-profile-v2`, run `setup.ps1`, run hotkey twice — fresh-state test
- Multi-tab WT: open chat A and B, focus A, hotkey, confirm A renders; switch to B, hotkey, confirm B
- DPI test: drag terminal between 100% and 200% monitors, verify overlay
- Run on a clean Windows account or VM if available — catches hardcoded paths

## Phase 7 — Publish

- `gh repo create <user>/texpop --public`
- Push, set description (SEO line above), set topics
- Tag `v0.1.0`, draft a release with the GIF embedded

## Phase 8 — Distribution

- Comment on [`anthropics/claude-code#21433`](https://github.com/anthropics/claude-code/issues/21433) with: *"For terminal-CLI users on Windows, here's a community workaround until native support ships: https://github.com/dyed-eye/texpop"*
- Same comment style on [`#16446`](https://github.com/anthropics/claude-code/issues/16446)
- Post on `r/ClaudeAI`, `r/PhysicsStudents` with screenshot and 1-paragraph pitch
- Anthropic Discord `#community-tools` channel
- Tweet (optional)

---

## Decisions (locked)

| # | Decision | Resolution |
|---|---|---|
| 1 | GitHub repo | `github.com/dyed-eye/texpop` |
| 2 | License | MIT |
| 3 | Codex adapter | Implement best-effort at v0.1.0, README labels it experimental and asks users to PR fixes |
| 4 | Demo media | Static screenshots + 10–15 s GIF (recorded on user's machine) |
| 5 | Default favicon | Ship Tokyo-Night `ψ` SVG; user keeps `dubstepgun.png` as local override |
| 6 | winget submission | Deferred to post-v0.1.0 |
