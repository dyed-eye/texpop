#!/usr/bin/env python3
"""show-linux.py - Render the focused AI CLI session's last assistant turn.

Linux counterpart of show.ps1. Hyprland + Ghostty is the tested combination;
other compositors fall back to whichever Chromium-family browser is on PATH.
"""
from __future__ import annotations

import argparse
import atexit
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from collections.abc import Iterable, Iterator
from pathlib import Path
from typing import Any, NoReturn

# TITLE and APP_ID are part of a cross-layer protocol: they must match
# template.html's <title> AND show.ps1's "TeXpop" substring filter. Renaming
# in one place silently breaks popup-close-before-relaunch behaviour.
TITLE = "TeXpop"
APP_ID = "texpop"

_VALID_HYPRLAND_MODES = ("floating", "tiled", "none")


def die(message: str) -> NoReturn:
    print(f"texpop: {message}", file=sys.stderr)
    raise SystemExit(1)


def _debug(message: str) -> None:
    if os.environ.get("TEXPOP_DEBUG"):
        print(f"texpop[debug]: {message}", file=sys.stderr)


def _mtime_or_zero(path: Path) -> float:
    """stat() guarded against TOCTOU: a session file deleted between
    enumeration and the max() sort key would otherwise raise FileNotFoundError."""
    try:
        return path.stat().st_mtime
    except OSError:
        return 0.0


def read_jsonl_tail(path: Path, max_bytes: int = 2 * 1024 * 1024) -> list[str]:
    size = path.stat().st_size
    with path.open("rb") as f:
        if size > max_bytes:
            f.seek(-max_bytes, os.SEEK_END)
            f.readline()
        data = f.read()
    return data.decode("utf-8", "replace").splitlines()


def local_sessions_root() -> Path:
    explicit = os.environ.get("TEXPOP_LOCAL_SESSIONS")
    if explicit:
        return Path(explicit).expanduser()
    home = os.environ.get("TEXPOP_LOCAL_HOME")
    if home:
        return Path(home).expanduser() / "sessions"
    return Path.home() / ".codex" / "sessions"


def newest_file(root: Path, pattern: str) -> Path | None:
    if not root.exists():
        return None
    files = [p for p in root.rglob(pattern) if p.is_file()]
    if not files:
        return None
    return max(files, key=_mtime_or_zero)


def newest_local_session() -> Path | None:
    return newest_file(local_sessions_root(), "rollout-*.jsonl")


def claude_projects_root() -> Path:
    return Path(os.environ.get("CLAUDE_PROJECTS_ROOT", Path.home() / ".claude" / "projects")).expanduser()


def newest_claude_session(root: Path | None = None) -> Path | None:
    if root is None:
        root = claude_projects_root()
    files: list[Path] = []
    if root.exists():
        for p in root.rglob("*.jsonl"):
            if "subagents" not in p.parts and ".backups" not in p.parts:
                files.append(p)
    if not files:
        return None
    return max(files, key=_mtime_or_zero)


def claude_project_dir_for_cwd(cwd: str | None) -> Path | None:
    """Map a CWD to the Claude project directory name Claude Code uses.

    Claude encodes the full CWD as the project dir name by replacing path
    separators and dots with '-'. The replace of ':' and '\\' is a no-op on
    Linux CWDs but kept so the encoding rule matches Windows' show.ps1
    (adapters/claude-code.ps1:Resolve-ClaudeProjectDirForCwd) byte-for-byte.
    """
    if not cwd:
        return None
    root = claude_projects_root()
    encoded = cwd.replace(":", "-").replace("\\", "-").replace("/", "-").replace(".", "-")
    candidates = [encoded]
    if encoded:
        candidates.append(encoded[0].lower() + encoded[1:])
    for candidate in candidates:
        path = root / candidate
        if path.exists():
            return path
    return None


def proc_stat(pid: int) -> dict[str, Any] | None:
    try:
        stat = Path(f"/proc/{pid}/stat").read_text()
    except OSError:
        return None
    end = stat.rfind(")")
    if end == -1:
        return None
    fields = stat[end + 2 :].split()
    try:
        return {
            "pid": pid,
            "comm": stat[stat.find("(") + 1 : end],
            "ppid": int(fields[1]),
            "tty_nr": int(fields[4]),
            "start": int(fields[19]),
        }
    except (IndexError, ValueError):
        return None


def proc_table() -> dict[int, dict[str, Any]]:
    out: dict[int, dict[str, Any]] = {}
    for entry in Path("/proc").iterdir():
        if entry.name.isdigit():
            stat = proc_stat(int(entry.name))
            if stat:
                out[stat["pid"]] = stat
    return out


def proc_cmdline(pid: int) -> str:
    try:
        raw = Path(f"/proc/{pid}/cmdline").read_bytes()
    except OSError:
        return ""
    return raw.replace(b"\0", b" ").decode("utf-8", "replace").strip()


def proc_cwd(pid: int) -> str | None:
    try:
        return os.readlink(f"/proc/{pid}/cwd")
    except OSError:
        return None


def descendants(root_pid: int, table: dict[int, dict[str, Any]]) -> list[int]:
    children: dict[int, list[int]] = {}
    for stat in table.values():
        children.setdefault(stat["ppid"], []).append(stat["pid"])
    stack = list(children.get(root_pid, []))
    out: list[int] = []
    while stack:
        pid = stack.pop()
        out.append(pid)
        stack.extend(children.get(pid, []))
    return out


def hyprland_clients() -> list[dict[str, Any]]:
    if not shutil.which("hyprctl"):
        return []
    data = run_json(["hyprctl", "-j", "clients"])
    return data if isinstance(data, list) else []


def active_hyprland_window() -> dict[str, Any] | None:
    if not shutil.which("hyprctl"):
        return None
    data = run_json(["hyprctl", "-j", "activewindow"])
    return data if isinstance(data, dict) and data.get("mapped") else None


def session_fds_for_pid(pid: int, required_dir_part: str, name_prefix: str | None = None) -> list[Path]:
    """List jsonl files referenced by /proc/<pid>/fd whose path contains the
    named directory component. required_dir_part must be an exact single path
    component (e.g. '.claude', '.codex') - substring or multi-component values
    will not match."""
    fd_dir = Path(f"/proc/{pid}/fd")
    sessions: list[Path] = []
    try:
        fds = list(fd_dir.iterdir())
    except OSError:
        return sessions
    for fd in fds:
        try:
            target = fd.readlink()
        except OSError:
            continue
        if target.suffix != ".jsonl" or required_dir_part not in target.parts:
            continue
        if name_prefix and not target.name.startswith(name_prefix):
            continue
        if "subagents" in target.parts or ".backups" in target.parts:
            continue
        if target.exists():
            sessions.append(target)
    return sessions


def is_claude_process(pid: int, stat: dict[str, Any]) -> bool:
    if stat["comm"] == "claude":
        return True
    cmdline = proc_cmdline(pid)
    return bool(re.search(r"(^|[\s/])claude($|[\s/])", cmdline))


def is_codex_process(pid: int, stat: dict[str, Any]) -> bool:
    if stat["comm"] == "codex":
        return True
    cmdline = proc_cmdline(pid)
    return bool(re.search(r"(^|[\s/])codex($|[\s/])", cmdline))


def focused_roots() -> tuple[list[int], dict[int, dict[str, Any]]]:
    active = active_hyprland_window()
    if not active:
        return [], {}
    table = proc_table()
    shell = focused_ghostty_shell(active, table)
    if shell:
        return [shell], table
    active_pid = active.get("pid")
    if isinstance(active_pid, int):
        return [active_pid], table
    return [], table


def focused_claude_session() -> Path | None:
    roots, table = focused_roots()
    candidates: list[Path] = []
    for root_pid in roots:
        for pid in [root_pid] + descendants(root_pid, table):
            stat = table.get(pid)
            if not stat or not is_claude_process(pid, stat):
                continue
            candidates.extend(session_fds_for_pid(pid, ".claude"))
            cwd = proc_cwd(pid)
            project_dir = claude_project_dir_for_cwd(cwd)
            if project_dir:
                newest = newest_claude_session(project_dir)
                if newest:
                    candidates.append(newest)
    if not candidates:
        return None
    # dict.fromkeys deduplicates while preserving insertion order; semantically
    # cleaner than set() here since we're only using the keys.
    return max(dict.fromkeys(candidates), key=_mtime_or_zero)


def _parse_stable_id(value: object) -> int:
    """Hyprland stableId is decimal-as-string on older versions and hex (no
    '0x' prefix) on newer ones. The value is only used as a monotone sort
    key, so int(str, 16) handles both representations - decimal '123' parses
    as 0x123, which still produces stable relative ordering."""
    if isinstance(value, int):
        return value
    if not value:
        return 0
    try:
        return int(str(value), 16)
    except (TypeError, ValueError):
        return 0


def focused_ghostty_shell(active: dict[str, Any], table: dict[int, dict[str, Any]]) -> int | None:
    """Map the active Ghostty window's stableId-sorted index onto the
    start-time-sorted index of its child shells. Assumption: window order
    by stableId mirrors shell creation order. A shell restart or PID reuse
    while windows remain open can silently return the wrong PID; that's an
    accepted limitation until Ghostty exposes per-window PID directly."""
    if "ghostty" not in active.get("class", "").lower():
        return None
    ghostty_pid = active.get("pid")
    clients = [
        c
        for c in hyprland_clients()
        if c.get("pid") == ghostty_pid and "ghostty" in c.get("class", "").lower()
    ]
    clients.sort(key=lambda c: _parse_stable_id(c.get("stableId")))
    active_address = active.get("address")
    active_index = next((i for i, c in enumerate(clients) if c.get("address") == active_address), None)
    if active_index is None:
        return None
    shells = [
        stat
        for stat in table.values()
        if stat["ppid"] == ghostty_pid and stat["tty_nr"] and stat["comm"] in {"zsh", "bash", "fish", "sh"}
    ]
    shells.sort(key=lambda stat: stat["start"])
    if active_index >= len(shells):
        return None
    return shells[active_index]["pid"]


def focused_local_session() -> Path | None:
    roots, table = focused_roots()
    candidates: list[Path] = []
    for root_pid in roots:
        for pid in [root_pid] + descendants(root_pid, table):
            stat = table.get(pid)
            if stat and is_codex_process(pid, stat):
                candidates.extend(session_fds_for_pid(pid, ".codex", "rollout-"))
    if not candidates:
        return None
    return max(dict.fromkeys(candidates), key=_mtime_or_zero)


def text_parts(content: Iterable[Any] | None, text_types: set[str]) -> str:
    out: list[str] = []
    for item in content or []:
        if isinstance(item, dict) and item.get("type") in text_types and item.get("text"):
            out.append(item["text"])
    return "".join(out)


def parse_local(path: Path) -> str:
    for line in reversed(read_jsonl_tail(path)):
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        payload = obj.get("payload") if isinstance(obj, dict) else None
        msg = payload if isinstance(payload, dict) else obj
        if msg.get("role") != "assistant":
            continue
        text = text_parts(msg.get("content"), {"input_text", "output_text", "text"})
        if text.strip():
            return text
    return ""


def parse_claude(path: Path) -> str:
    lines = read_jsonl_tail(path, 500_000)
    last_req: str | None = None
    for line in reversed(lines):
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if obj.get("type") == "assistant" and obj.get("requestId"):
            last_req = obj["requestId"]
            break
    if not last_req:
        return ""
    parts: list[str] = []
    for line in lines:
        # Substring pre-filter is a fast path; the authoritative requestId
        # check happens after json.loads so a user message that quotes an
        # earlier requestId cannot contribute to the assembled output.
        if last_req not in line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if obj.get("requestId") != last_req:
            continue
        msg = obj.get("message") or {}
        if msg.get("role") == "assistant":
            parts.append(text_parts(msg.get("content"), {"text"}))
    return "".join(parts)


def choose_session(source: str, explicit: str | None) -> tuple[Path | None, str]:
    if explicit:
        path = Path(explicit).expanduser()
        if not path.exists():
            die(f"session not found: {path}")
        if source != "auto":
            return path, source
        return path, "claude" if ".claude" in path.parts else "local"
    if source == "local":
        return focused_local_session() or newest_local_session(), "local"
    if source == "claude":
        return focused_claude_session() or newest_claude_session(), "claude"
    local = focused_local_session() or newest_local_session()
    claude = focused_claude_session() or newest_claude_session()
    candidates: list[tuple[Path, str]] = [
        (p, kind) for p, kind in ((local, "local"), (claude, "claude")) if p
    ]
    if not candidates:
        return None, source
    return max(candidates, key=lambda item: _mtime_or_zero(item[0]))


def file_uri(path: Path) -> str:
    return path.resolve().as_uri()


def icon_uri(root: Path) -> str:
    """Resolve favicon URI, mirroring show.ps1's cascade exactly.

    Returns a file:// URI for the first existing candidate. Falls through to
    the default-ico path even when nothing exists, so the rendered HTML never
    emits href="" (which produces an invalid request and a console error).
    Keep this list in sync with show.ps1's $iconCandidates array.
    """
    assets = root / "assets"
    candidates = (
        "icon-override.svg",
        "icon-override.png",
        "icon-override.jpg",
        "icon-override.ico",
        "icon-default.ico",
        "icon-default.png",
        "icon-default.svg",
    )
    for name in candidates:
        candidate = assets / name
        if candidate.exists():
            return file_uri(candidate)
    return file_uri(assets / "icon-default.ico")


def write_html(root: Path, message: str, session: Path) -> Path:
    template = root / "template.html"
    vendor = root / "vendor"
    if not template.exists():
        die(f"template.html not found at {template}")
    if not vendor.exists():
        die("vendor/ missing; run setup-linux.sh first")
    html = template.read_text(encoding="utf-8")
    # Replacement order is load-bearing: ASSETS_BASE/icon.svg must run BEFORE
    # the bare ASSETS_BASE prefix or the icon URI gets sliced. Same constraint
    # is mirrored in show.ps1; keep them in sync.
    html = html.replace("ASSETS_BASE/icon.svg", icon_uri(root))
    html = html.replace("VENDOR_BASE", file_uri(vendor).rstrip("/"))
    html = html.replace("ASSETS_BASE", file_uri(root / "assets").rstrip("/"))
    if "MESSAGE_PLACEHOLDER" not in html:
        die("MESSAGE_PLACEHOLDER missing from template.html")
    # JSON data island. template.html now parses via JSON.parse, so any
    # special characters in the message - including raw </script substrings -
    # arrive as ordinary string contents instead of being interpreted by the
    # HTML parser. The extra '</' -> '<\/' replacement is defence-in-depth:
    # JSON treats '\/' as identical to '/' on decode, so the message
    # round-trips unchanged.
    encoded = json.dumps(message).replace("</", "<\\/")
    html = html.replace("MESSAGE_PLACEHOLDER", encoded)
    # Atomic create with 0o600 perms via tempfile.mkstemp - no race window
    # between file creation (umask-bound) and a post-hoc chmod.
    fd, path_str = tempfile.mkstemp(suffix=".html", prefix="texpop-")
    out = Path(path_str)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(html)
    atexit.register(lambda path=out: path.unlink(missing_ok=True))
    return out


def run_json(cmd: list[str]) -> Any:
    try:
        proc = subprocess.run(cmd, text=True, capture_output=True, check=True)
        return json.loads(proc.stdout)
    except (subprocess.CalledProcessError, json.JSONDecodeError, OSError) as exc:
        _debug(f"run_json({cmd[0]!r}) failed: {type(exc).__name__}: {exc}")
        return None


def active_hyprland_rect() -> tuple[int, int, int, int] | None:
    data = active_hyprland_window()
    if not data:
        return None
    at = data.get("at") or [0, 0]
    size = data.get("size") or [900, 700]
    return int(at[0]), int(at[1]), int(size[0]), int(size[1])


def texpop_window_addresses() -> set[str]:
    return {
        item.get("address")
        for item in hyprland_clients()
        if item.get("title") == TITLE and item.get("class") == APP_ID and valid_hyprland_address(item.get("address"))
    }


def close_texpop_windows() -> None:
    for address in texpop_window_addresses():
        subprocess.run(
            ["hyprctl", "dispatch", "closewindow", f"address:{address}"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


def find_hyprland_window(pid: int, before: set[str] | None = None) -> str | None:
    before_set = before or set()
    for item in hyprland_clients():
        if item.get("pid") == pid and item.get("title") == TITLE:
            address = item.get("address")
            if isinstance(address, str) and address not in before_set:
                return address
    return None


def valid_hyprland_address(address: Any) -> bool:
    return isinstance(address, str) and bool(re.fullmatch(r"0x[0-9a-fA-F]+", address))


def dispatch_hyprland_placement(address: str, rect: tuple[int, int, int, int]) -> bool:
    if not valid_hyprland_address(address):
        return False
    x, y, w, h = rect
    selector = f"address:{address}"
    for args in (
        ["hyprctl", "dispatch", "setfloating", selector],
        ["hyprctl", "dispatch", "resizewindowpixel", f"exact {w} {h},{selector}"],
        ["hyprctl", "dispatch", "movewindowpixel", f"exact {x} {y},{selector}"],
        ["hyprctl", "dispatch", "focuswindow", selector],
    ):
        subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return True


def _place_when_visible(
    pid: int,
    rect: tuple[int, int, int, int] | None,
    mode: str,
    before: set[str] | None,
    on_attempt: Any = None,
) -> bool:
    """Poll Hyprland up to 50 times (~5s) for a window owned by pid, then
    position it. Returns True once placement dispatches, False otherwise.

    on_attempt is a hook used by the Qt event-loop variant (show_with_qt) to
    schedule the next poll via QTimer instead of time.sleep(); pass None for
    the blocking variant."""
    if mode != "floating" or not rect or not shutil.which("hyprctl"):
        return False
    for _ in range(50):
        address = find_hyprland_window(pid, before)
        if address and dispatch_hyprland_placement(address, rect):
            return True
        if on_attempt is None:
            time.sleep(0.1)
        else:
            on_attempt()
            return False
    return False


def place_hyprland(pid: int, rect: tuple[int, int, int, int] | None, mode: str, before: set[str] | None = None) -> bool:
    """Blocking placement helper for Chromium backend. Returns True on success."""
    return _place_when_visible(pid, rect, mode, before, on_attempt=None)


def show_with_qt(
    html_path: Path,
    rect: tuple[int, int, int, int] | None,
    hyprland_mode: str,
    before_windows: set[str] | None = None,
) -> bool:
    try:
        from PyQt6.QtCore import QTimer, QUrl
        from PyQt6.QtGui import QKeySequence, QShortcut
        from PyQt6.QtWebEngineWidgets import QWebEngineView
        from PyQt6.QtWidgets import QApplication, QMainWindow
    except ImportError:
        return False

    app = QApplication(sys.argv[:1])
    app.setApplicationName(TITLE)
    app.setDesktopFileName(APP_ID)
    win = QMainWindow()
    win.setWindowTitle(TITLE)
    view = QWebEngineView()
    view.load(QUrl.fromLocalFile(str(html_path)))
    win.setCentralWidget(view)
    if rect and hyprland_mode == "floating":
        win.setGeometry(*rect)
    else:
        win.resize(900, 700)
    QShortcut(QKeySequence("Escape"), win).activated.connect(win.close)
    win.show()
    win.raise_()
    win.activateWindow()

    if os.environ.get("XDG_CURRENT_DESKTOP", "").lower() == "hyprland":
        # Qt's event loop forbids blocking sleeps in show_with_qt's thread, so
        # we re-implement the polling shape from place_hyprland using QTimer.
        # Keep the cadence (50 attempts at 100ms) in sync with _place_when_visible.
        attempts = 0

        def poll_hyprland() -> None:
            nonlocal attempts
            if hyprland_mode != "floating" or not rect or not shutil.which("hyprctl"):
                return
            attempts += 1
            address = find_hyprland_window(os.getpid(), before_windows)
            if address and dispatch_hyprland_placement(address, rect):
                return
            if attempts < 50:
                QTimer.singleShot(100, poll_hyprland)

        QTimer.singleShot(250, poll_hyprland)

    try:
        exit_code = app.exec()
    except RuntimeError as exc:
        print(f"texpop: Qt popup failed: {exc}", file=sys.stderr)
        return False
    return exit_code == 0


def browser_candidates() -> Iterator[tuple[str, str]]:
    # All Chromium-family binaries below accept the same --app and
    # --user-data-dir flags, so we group them under one "chromium" kind.
    for binary in (
        "google-chrome-stable",
        "google-chrome",
        "chromium",
        "chromium-browser",
        "microsoft-edge",
        "brave-browser",
    ):
        path = shutil.which(binary)
        if path:
            yield "chromium", path
    firefox = shutil.which("firefox")
    if firefox:
        yield "firefox", firefox


def _profile_dir_root() -> Path:
    """Prefer $XDG_RUNTIME_DIR (per-user, 0o700 by spec) over system /tmp so
    profile paths aren't enumerable by other users."""
    xdg = os.environ.get("XDG_RUNTIME_DIR")
    if xdg:
        candidate = Path(xdg)
        if candidate.is_dir():
            return candidate
    return Path(tempfile.gettempdir())


def show_with_browser(
    html_path: Path,
    rect: tuple[int, int, int, int] | None,
    hyprland_mode: str,
    before_windows: set[str] | None = None,
) -> bool:
    uri = file_uri(html_path)
    for kind, binary in browser_candidates():
        if kind == "chromium":
            profile = Path(tempfile.mkdtemp(prefix="texpop-browser-profile-", dir=_profile_dir_root()))
            # mkdtemp creates with 0o700 on POSIX; no chmod / uid check needed.
            atexit.register(shutil.rmtree, profile, ignore_errors=True)
            args = [
                binary,
                f"--app={uri}",
                f"--user-data-dir={profile}",
                "--ozone-platform=x11",
                "--disable-gpu",
                "--disable-software-rasterizer",
                "--no-first-run",
                "--no-default-browser-check",
                "--disable-features=Translate",
            ]
            if rect and hyprland_mode == "floating":
                x, y, w, h = rect
                args.extend([f"--window-size={w},{h}", f"--window-position={x},{y}"])
            proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if os.environ.get("XDG_CURRENT_DESKTOP", "").lower() == "hyprland":
                place_hyprland(proc.pid, rect, hyprland_mode, before_windows)
            proc.wait()
            return True
        if kind == "firefox":
            proc = subprocess.Popen([binary, "--new-window", uri], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            proc.wait()
            return True
    return False


def _resolved_hyprland_mode_default() -> str:
    env = os.environ.get("TEXPOP_HYPRLAND_MODE")
    if env is None:
        return "floating"
    if env not in _VALID_HYPRLAND_MODES:
        die(f"invalid TEXPOP_HYPRLAND_MODE={env!r}; expected one of {_VALID_HYPRLAND_MODES}")
    return env


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", choices=("auto", "local", "claude"), default="auto")
    parser.add_argument("--session")
    parser.add_argument("--print-message", action="store_true")
    parser.add_argument("--browser", action="store_true")
    parser.add_argument(
        "--hyprland-mode",
        choices=_VALID_HYPRLAND_MODES,
        default=_resolved_hyprland_mode_default(),
    )
    args = parser.parse_args()

    root = Path(__file__).resolve().parent
    session, kind = choose_session(args.source, args.session)
    if not session:
        die(f"no {args.source} session found")
    message = parse_claude(session) if kind == "claude" else parse_local(session)
    if not message.strip():
        die(f"no assistant text in {session}")
    if args.print_message:
        print(message)
        return

    if args.hyprland_mode == "tiled" and shutil.which("hyprctl"):
        close_texpop_windows()
    before_windows = texpop_window_addresses() if shutil.which("hyprctl") else set()
    rect = active_hyprland_rect()
    html_path = write_html(root, message, session)
    if not args.browser and show_with_qt(html_path, rect, args.hyprland_mode, before_windows):
        return
    if show_with_browser(html_path, rect, args.hyprland_mode, before_windows):
        return
    die("no supported popup backend found")


if __name__ == "__main__":
    main()
