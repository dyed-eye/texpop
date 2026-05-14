from __future__ import annotations

import atexit
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from collections.abc import Iterator
from pathlib import Path
from typing import Any

TITLE = "TeXpop"
APP_ID = "texpop"


def file_uri(path: Path) -> str:
    return path.resolve().as_uri()


def icon_uri(root: Path) -> str:
    assets = root / "assets"
    for name in (
        "icon-override.svg",
        "icon-override.png",
        "icon-override.jpg",
        "icon-override.ico",
        "icon-default.ico",
        "icon-default.png",
        "icon-default.svg",
    ):
        candidate = assets / name
        if candidate.exists():
            return file_uri(candidate)
    return file_uri(assets / "icon-default.ico")


def write_html(root: Path, message: str) -> Path:
    template = root / "template.html"
    vendor = root / "vendor"
    if not template.exists():
        raise RuntimeError(f"template.html not found at {template}")
    if not vendor.exists():
        raise RuntimeError("vendor/ missing; run setup-linux.sh first")
    html = template.read_text(encoding="utf-8")
    html = html.replace("ASSETS_BASE/icon.svg", icon_uri(root))
    html = html.replace("VENDOR_BASE", file_uri(vendor).rstrip("/"))
    html = html.replace("ASSETS_BASE", file_uri(root / "assets").rstrip("/"))
    if "MESSAGE_PLACEHOLDER" not in html:
        raise RuntimeError("MESSAGE_PLACEHOLDER missing from template.html")
    html = html.replace("MESSAGE_PLACEHOLDER", json.dumps(message).replace("</", "<\\/"))
    fd, path_str = tempfile.mkstemp(suffix=".html", prefix="texpop-")
    out = Path(path_str)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(html)
    atexit.register(lambda path=out: path.unlink(missing_ok=True))
    return out


def show(html_path: Path, rect: tuple[int, int, int, int] | None, force_browser: bool = False) -> bool:
    close_texpop_windows()
    before_windows = texpop_window_addresses()
    if not force_browser and show_with_qt(html_path, rect, before_windows):
        return True
    return show_with_browser(html_path, rect, before_windows)


def run_json(cmd: list[str]) -> Any:
    try:
        proc = subprocess.run(cmd, text=True, capture_output=True, check=True)
        return json.loads(proc.stdout)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError):
        return None


def hyprland_clients() -> list[dict[str, Any]]:
    if not shutil.which("hyprctl"):
        return []
    data = run_json(["hyprctl", "-j", "clients"])
    return data if isinstance(data, list) else []


def valid_hyprland_address(address: Any) -> bool:
    return isinstance(address, str) and bool(re.fullmatch(r"0x[0-9a-fA-F]+", address))


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


def place_hyprland(address: str, rect: tuple[int, int, int, int]) -> bool:
    if not valid_hyprland_address(address):
        return False
    x, y, width, height = rect
    selector = f"address:{address}"
    for args in (
        ["hyprctl", "dispatch", "setfloating", selector],
        ["hyprctl", "dispatch", "resizewindowpixel", f"exact {width} {height},{selector}"],
        ["hyprctl", "dispatch", "movewindowpixel", f"exact {x} {y},{selector}"],
        ["hyprctl", "dispatch", "focuswindow", selector],
    ):
        subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return True


def poll_place_hyprland(pid: int, rect: tuple[int, int, int, int] | None, before: set[str] | None) -> bool:
    if not rect or not shutil.which("hyprctl"):
        return False
    for _ in range(50):
        address = find_hyprland_window(pid, before)
        if address and place_hyprland(address, rect):
            return True
        time.sleep(0.1)
    return False


def show_with_qt(html_path: Path, rect: tuple[int, int, int, int] | None, before_windows: set[str] | None) -> bool:
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
    if rect:
        win.setGeometry(*rect)
    else:
        win.resize(900, 700)
    QShortcut(QKeySequence("Escape"), win).activated.connect(win.close)
    win.show()
    win.raise_()
    win.activateWindow()

    if rect and shutil.which("hyprctl"):
        attempts = 0

        def poll() -> None:
            nonlocal attempts
            attempts += 1
            address = find_hyprland_window(os.getpid(), before_windows)
            if address and place_hyprland(address, rect):
                return
            if attempts < 50:
                QTimer.singleShot(100, poll)

        QTimer.singleShot(250, poll)

    try:
        return app.exec() == 0
    except RuntimeError as exc:
        print(f"texpop: Qt popup failed: {exc}", file=sys.stderr)
        return False


def browser_candidates() -> Iterator[tuple[str, str]]:
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


def profile_dir_root() -> Path:
    xdg = os.environ.get("XDG_RUNTIME_DIR")
    if xdg:
        candidate = Path(xdg)
        if candidate.is_dir():
            return candidate
    return Path(tempfile.gettempdir())


def show_with_browser(html_path: Path, rect: tuple[int, int, int, int] | None, before_windows: set[str] | None) -> bool:
    uri = file_uri(html_path)
    for kind, binary in browser_candidates():
        if kind == "chromium":
            profile = Path(tempfile.mkdtemp(prefix="texpop-browser-profile-", dir=profile_dir_root()))
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
            if rect:
                x, y, width, height = rect
                args.extend([f"--window-size={width},{height}", f"--window-position={x},{y}"])
            proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            poll_place_hyprland(proc.pid, rect, before_windows)
            proc.wait()
            return True
        if kind == "firefox":
            proc = subprocess.Popen([binary, "--new-window", uri], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            proc.wait()
            return True
    return False
