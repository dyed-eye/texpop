#!/usr/bin/env python3
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
from pathlib import Path

TITLE = "TeXpop"
APP_ID = "texpop"


def die(message):
    print(f"texpop: {message}", file=sys.stderr)
    raise SystemExit(1)


def read_jsonl_tail(path, max_bytes=2 * 1024 * 1024):
    size = path.stat().st_size
    with path.open("rb") as f:
        if size > max_bytes:
            f.seek(-max_bytes, os.SEEK_END)
            f.readline()
        data = f.read()
    return data.decode("utf-8", "replace").splitlines()


def local_sessions_root():
    explicit = os.environ.get("TEXPOP_LOCAL_SESSIONS")
    if explicit:
        return Path(explicit).expanduser()
    home = os.environ.get("TEXPOP_LOCAL_HOME")
    if home:
        return Path(home).expanduser() / "sessions"
    return Path.home() / ".codex" / "sessions"


def newest_file(root, pattern):
    if not root.exists():
        return None
    files = [p for p in root.rglob(pattern) if p.is_file()]
    if not files:
        return None
    return max(files, key=lambda p: p.stat().st_mtime)


def newest_local_session():
    return newest_file(local_sessions_root(), "rollout-*.jsonl")


def claude_projects_root():
    return Path(os.environ.get("CLAUDE_PROJECTS_ROOT", Path.home() / ".claude" / "projects")).expanduser()


def newest_claude_session(root=None):
    root = root or claude_projects_root()
    files = []
    if root.exists():
        for p in root.rglob("*.jsonl"):
            if "subagents" not in p.parts and ".backups" not in p.parts:
                files.append(p)
    if not files:
        return None
    return max(files, key=lambda p: p.stat().st_mtime)


def claude_project_dir_for_cwd(cwd):
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


def proc_stat(pid):
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


def proc_table():
    out = {}
    for entry in Path("/proc").iterdir():
        if entry.name.isdigit():
            stat = proc_stat(int(entry.name))
            if stat:
                out[stat["pid"]] = stat
    return out


def proc_cmdline(pid):
    try:
        raw = Path(f"/proc/{pid}/cmdline").read_bytes()
    except OSError:
        return ""
    return raw.replace(b"\0", b" ").decode("utf-8", "replace").strip()


def proc_cwd(pid):
    try:
        return os.readlink(f"/proc/{pid}/cwd")
    except OSError:
        return None


def descendants(root_pid, table):
    children = {}
    for stat in table.values():
        children.setdefault(stat["ppid"], []).append(stat["pid"])
    stack = list(children.get(root_pid, []))
    out = []
    while stack:
        pid = stack.pop()
        out.append(pid)
        stack.extend(children.get(pid, []))
    return out


def hyprland_clients():
    if not shutil.which("hyprctl"):
        return []
    data = run_json(["hyprctl", "-j", "clients"])
    return data if isinstance(data, list) else []


def active_hyprland_window():
    if not shutil.which("hyprctl"):
        return None
    data = run_json(["hyprctl", "-j", "activewindow"])
    return data if isinstance(data, dict) and data.get("mapped") else None


def session_fds_for_pid(pid, home_part, name_prefix=None):
    fd_dir = Path(f"/proc/{pid}/fd")
    sessions = []
    try:
        fds = list(fd_dir.iterdir())
    except OSError:
        return sessions
    for fd in fds:
        try:
            target = Path(os.readlink(fd))
        except OSError:
            continue
        if target.suffix != ".jsonl" or home_part not in target.parts:
            continue
        if name_prefix and not target.name.startswith(name_prefix):
            continue
        if "subagents" in target.parts or ".backups" in target.parts:
            continue
        if target.exists():
            sessions.append(target)
    return sessions


def is_claude_process(pid, stat):
    if stat["comm"] == "claude":
        return True
    cmdline = proc_cmdline(pid)
    return bool(re.search(r"(^|[\s/])claude($|[\s/])", cmdline))


def is_codex_process(pid, stat):
    if stat["comm"] == "codex":
        return True
    cmdline = proc_cmdline(pid)
    return bool(re.search(r"(^|[\s/])codex($|[\s/])", cmdline))


def focused_roots():
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


def focused_claude_session():
    roots, table = focused_roots()
    candidates = []
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
    return max(set(candidates), key=lambda p: p.stat().st_mtime)


def focused_ghostty_shell(active, table):
    if "ghostty" not in active.get("class", "").lower():
        return None
    ghostty_pid = active.get("pid")
    clients = [
        c
        for c in hyprland_clients()
        if c.get("pid") == ghostty_pid and "ghostty" in c.get("class", "").lower()
    ]
    clients.sort(key=lambda c: int(c.get("stableId") or 0))
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


def focused_local_session():
    roots, table = focused_roots()
    candidates = []
    for root_pid in roots:
        for pid in [root_pid] + descendants(root_pid, table):
            stat = table.get(pid)
            if stat and is_codex_process(pid, stat):
                candidates.extend(session_fds_for_pid(pid, ".codex", "rollout-"))
    if not candidates:
        return None
    return max(set(candidates), key=lambda p: p.stat().st_mtime)


def text_parts(content, text_types):
    out = []
    for item in content or []:
        if isinstance(item, dict) and item.get("type") in text_types and item.get("text"):
            out.append(item["text"])
    return "".join(out)


def parse_local(path):
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


def parse_claude(path):
    lines = read_jsonl_tail(path, 500_000)
    last_req = None
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
    parts = []
    for line in lines:
        if last_req not in line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        msg = obj.get("message") or {}
        if msg.get("role") == "assistant":
            parts.append(text_parts(msg.get("content"), {"text"}))
    return "".join(parts)


def choose_session(source, explicit):
    if explicit:
        path = Path(explicit).expanduser()
        if not path.exists():
            die(f"session not found: {path}")
        if source != "auto":
            return path, source
        return path, "claude" if ".claude" in path.parts else "local"
    if source == "local":
        path = focused_local_session() or newest_local_session()
        return path, "local"
    if source == "claude":
        path = focused_claude_session() or newest_claude_session()
        return path, "claude"
    local = focused_local_session() or newest_local_session()
    claude = focused_claude_session() or newest_claude_session()
    candidates = [(p, kind) for p, kind in ((local, "local"), (claude, "claude")) if p]
    if not candidates:
        return None, source
    return max(candidates, key=lambda item: item[0].stat().st_mtime)


def file_uri(path):
    return path.resolve().as_uri()


def icon_uri(root):
    assets = root / "assets"
    for name in (
        "icon-override.svg",
        "icon-override.png",
        "icon-override.jpg",
        "icon-default.png",
        "icon-default.svg",
        "icon-default.ico",
    ):
        candidate = assets / name
        if candidate.exists():
            return file_uri(candidate)
    return ""


def write_html(root, message, session):
    template = root / "template.html"
    vendor = root / "vendor"
    if not template.exists():
        die(f"template.html not found at {template}")
    if not vendor.exists():
        die("vendor/ missing; run setup-linux.sh first")
    html = template.read_text(encoding="utf-8")
    html = html.replace("ASSETS_BASE/icon.svg", icon_uri(root))
    html = html.replace("VENDOR_BASE", file_uri(vendor).rstrip("/"))
    html = html.replace("ASSETS_BASE", file_uri(root / "assets").rstrip("/"))
    if "MESSAGE_PLACEHOLDER" not in html:
        die("MESSAGE_PLACEHOLDER missing from template.html")
    escaped = re.sub(r"</script", "<\\/script", message, flags=re.IGNORECASE)
    html = html.replace("MESSAGE_PLACEHOLDER", escaped)
    source = session.name.replace("--", "- -")
    html = f"<!-- source: {source} | {time.ctime(session.stat().st_mtime)} -->\n" + html
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".html", prefix="texpop-", delete=False) as f:
        f.write(html)
        out = Path(f.name)
    os.chmod(out, 0o600)
    atexit.register(lambda path=out: path.unlink(missing_ok=True))
    return out


def run_json(cmd):
    try:
        proc = subprocess.run(cmd, text=True, capture_output=True, check=True)
        return json.loads(proc.stdout)
    except (subprocess.CalledProcessError, json.JSONDecodeError, OSError):
        return None


def active_hyprland_rect():
    data = active_hyprland_window()
    if not data:
        return None
    at = data.get("at") or [0, 0]
    size = data.get("size") or [900, 700]
    return int(at[0]), int(at[1]), int(size[0]), int(size[1])


def texpop_window_addresses():
    return {
        item.get("address")
        for item in hyprland_clients()
        if item.get("title") == TITLE and item.get("class") == APP_ID and valid_hyprland_address(item.get("address"))
    }


def close_texpop_windows():
    for address in texpop_window_addresses():
        subprocess.run(["hyprctl", "dispatch", "closewindow", f"address:{address}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def find_hyprland_window(pid, before=None):
    before = before or set()
    for item in hyprland_clients():
        if item.get("pid") == pid and item.get("title") == TITLE:
            address = item.get("address")
            if address not in before:
                return address
    return None


def valid_hyprland_address(address):
    return isinstance(address, str) and re.fullmatch(r"0x[0-9a-fA-F]+", address)


def dispatch_hyprland_placement(address, rect):
    if not valid_hyprland_address(address):
        return False
    x, y, w, h = rect
    selector = f"address:{address}"
    subprocess.run(["hyprctl", "dispatch", "setfloating", selector], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["hyprctl", "dispatch", "resizewindowpixel", f"exact {w} {h},{selector}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["hyprctl", "dispatch", "movewindowpixel", f"exact {x} {y},{selector}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["hyprctl", "dispatch", "focuswindow", selector], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return True


def place_hyprland(pid, rect, mode, before=None):
    if mode != "floating":
        return
    if not rect or not shutil.which("hyprctl"):
        return
    for _ in range(50):
        address = find_hyprland_window(pid, before)
        if address and dispatch_hyprland_placement(address, rect):
            return
        time.sleep(0.1)


def show_with_qt(html_path, rect, hyprland_mode, before_windows=None):
    try:
        from PyQt6.QtCore import QTimer, QUrl
        from PyQt6.QtGui import QKeySequence, QShortcut
        from PyQt6.QtWidgets import QApplication, QMainWindow
        from PyQt6.QtWebEngineWidgets import QWebEngineView
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
        attempts = {"count": 0}

        def poll_hyprland():
            if hyprland_mode != "floating" or not rect or not shutil.which("hyprctl"):
                return
            attempts["count"] += 1
            address = find_hyprland_window(os.getpid(), before_windows)
            if address and dispatch_hyprland_placement(address, rect):
                return
            if attempts["count"] < 50:
                QTimer.singleShot(100, poll_hyprland)

        QTimer.singleShot(250, poll_hyprland)
    try:
        exit_code = app.exec()
    except RuntimeError as exc:
        print(f"texpop: Qt popup failed: {exc}", file=sys.stderr)
        return False
    return exit_code == 0


def browser_candidates():
    for binary in ("google-chrome-stable", "google-chrome", "chromium", "chromium-browser", "microsoft-edge", "brave-browser"):
        path = shutil.which(binary)
        if path:
            yield "chromium", path
    firefox = shutil.which("firefox")
    if firefox:
        yield "firefox", firefox


def show_with_browser(html_path, rect, hyprland_mode, before_windows=None):
    uri = file_uri(html_path)
    for kind, binary in browser_candidates():
        if kind == "chromium":
            profile = Path(tempfile.mkdtemp(prefix="texpop-browser-profile-"))
            os.chmod(profile, 0o700)
            if profile.stat().st_uid != os.getuid():
                continue
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
        elif kind == "firefox":
            proc = subprocess.Popen([binary, "--new-window", uri], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            proc.wait()
            return True
    return False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", choices=("auto", "local", "claude"), default="auto")
    parser.add_argument("--session")
    parser.add_argument("--print-message", action="store_true")
    parser.add_argument("--browser", action="store_true")
    parser.add_argument("--hyprland-mode", choices=("floating", "tiled", "none"), default=os.environ.get("TEXPOP_HYPRLAND_MODE", "floating"))
    args = parser.parse_args()
    if args.hyprland_mode not in ("floating", "tiled", "none"):
        die(f"invalid hyprland mode: {args.hyprland_mode}")

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
