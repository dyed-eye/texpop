#!/usr/bin/env python3
import argparse
import json
import os
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
    return Path.home() / (".co" + "dex") / "sessions"


def newest_file(root, pattern):
    if not root.exists():
        return None
    files = [p for p in root.rglob(pattern) if p.is_file()]
    if not files:
        return None
    return max(files, key=lambda p: p.stat().st_mtime)


def newest_local_session():
    return newest_file(local_sessions_root(), "rollout-*.jsonl")


def newest_claude_session():
    root = Path(os.environ.get("CLAUDE_PROJECTS_ROOT", Path.home() / ".claude" / "projects")).expanduser()
    files = []
    if root.exists():
        for p in root.rglob("*.jsonl"):
            s = str(p)
            if "/subagents/" not in s and "/.backups/" not in s:
                files.append(p)
    if not files:
        return None
    return max(files, key=lambda p: p.stat().st_mtime)


def text_parts(content, text_types):
    out = []
    for item in content or []:
        if isinstance(item, dict) and item.get("type") in text_types and item.get("text"):
            out.append(item["text"])
    return "".join(out)


def parse_local(path):
    for line in reversed(read_jsonl_tail(path)):
        if '"role":"assistant"' not in line and '"role": "assistant"' not in line:
            continue
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
        if '"role":"assistant"' not in line or '"type":"text"' not in line:
            continue
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
        if last_req not in line or '"role":"assistant"' not in line or '"type":"text"' not in line:
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
        path = newest_local_session()
        return path, "local"
    if source == "claude":
        path = newest_claude_session()
        return path, "claude"
    local = newest_local_session()
    claude = newest_claude_session()
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
    return file_uri(assets / "icon-default.png")


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
    html = html.replace("MESSAGE_PLACEHOLDER", message.replace("</script", "<\\/script"))
    html = f"<!-- source: {session.name} | {time.ctime(session.stat().st_mtime)} -->\n" + html
    out = Path(tempfile.gettempdir()) / f"texpop-{os.getpid()}-{int(time.time())}.html"
    out.write_text(html, encoding="utf-8")
    return out


def run_json(cmd):
    try:
        proc = subprocess.run(cmd, text=True, capture_output=True, check=True)
        return json.loads(proc.stdout)
    except Exception:
        return None


def active_hyprland_rect():
    if not shutil.which("hyprctl"):
        return None
    data = run_json(["hyprctl", "-j", "activewindow"])
    if not data or not data.get("mapped"):
        return None
    at = data.get("at") or [0, 0]
    size = data.get("size") or [900, 700]
    return int(at[0]), int(at[1]), int(size[0]), int(size[1])


def find_hyprland_window(pid):
    data = run_json(["hyprctl", "-j", "clients"])
    if not isinstance(data, list):
        return None
    for item in data:
        if item.get("pid") == pid and item.get("title") == TITLE:
            return item.get("address")
    for item in data:
        if item.get("title") == TITLE:
            return item.get("address")
    return None


def place_hyprland(pid, rect, mode):
    if mode != "floating":
        return
    if not rect or not shutil.which("hyprctl"):
        return
    x, y, w, h = rect
    for _ in range(50):
        address = find_hyprland_window(pid)
        if address:
            selector = f"address:{address}"
            subprocess.run(["hyprctl", "dispatch", "setfloating", selector], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["hyprctl", "dispatch", "resizewindowpixel", f"exact {w} {h},{selector}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["hyprctl", "dispatch", "movewindowpixel", f"exact {x} {y},{selector}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["hyprctl", "dispatch", "focuswindow", selector], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return
        time.sleep(0.1)


def show_with_qt(html_path, rect, hyprland_mode):
    try:
        from PyQt6.QtCore import QTimer, QUrl
        from PyQt6.QtGui import QKeySequence, QShortcut
        from PyQt6.QtWidgets import QApplication, QMainWindow
        from PyQt6.QtWebEngineWidgets import QWebEngineView
    except Exception:
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
        QTimer.singleShot(250, lambda: place_hyprland(os.getpid(), rect, hyprland_mode))
    return app.exec() == 0


def browser_candidates():
    for binary in ("google-chrome-stable", "google-chrome", "chromium", "chromium-browser", "microsoft-edge", "brave-browser"):
        path = shutil.which(binary)
        if path:
            yield "chromium", path
    firefox = shutil.which("firefox")
    if firefox:
        yield "firefox", firefox


def show_with_browser(html_path, rect, hyprland_mode):
    uri = file_uri(html_path)
    for kind, binary in browser_candidates():
        if kind == "chromium":
            profile = Path(tempfile.gettempdir()) / f"texpop-browser-profile-{os.getpid()}"
            profile.mkdir(exist_ok=True)
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
                place_hyprland(proc.pid, rect, hyprland_mode)
            return True
        subprocess.Popen([binary, "--new-window", uri], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
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

    rect = active_hyprland_rect()
    html_path = write_html(root, message, session)
    if not args.browser and show_with_qt(html_path, rect, args.hyprland_mode):
        return
    if show_with_browser(html_path, rect, args.hyprland_mode):
        return
    die("no supported popup backend found")


if __name__ == "__main__":
    main()
