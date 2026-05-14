from __future__ import annotations

import re
import shutil

from . import FocusedWindow
from .common import run_text


def resolve() -> FocusedWindow | None:
    if not shutil.which("gdbus"):
        return None
    script = (
        "(() => {"
        "let w = global.display.focus_window;"
        "if (!w) return '';"
        "let r = w.get_frame_rect();"
        "return [w.get_pid(), r.x, r.y, r.width, r.height].join(',');"
        "})()"
    )
    text = run_text(
        [
            "gdbus",
            "call",
            "--session",
            "--dest",
            "org.gnome.Shell",
            "--object-path",
            "/org/gnome/Shell",
            "--method",
            "org.gnome.Shell.Eval",
            script,
        ]
    )
    values = _parse_eval_result(text)
    if not values:
        return None
    pid, x, y, width, height = values
    return FocusedWindow(pid, x, y, width, height, "gnome")


def _parse_eval_result(text: str | None) -> tuple[int, int, int, int, int] | None:
    if not text:
        return None
    match = re.search(r"^\(true,\s*'([^']*)'\)$", text)
    if not match:
        return None
    parts = match.group(1).split(",")
    if len(parts) != 5:
        return None
    try:
        pid, x, y, width, height = [int(part) for part in parts]
    except ValueError:
        return None
    if pid <= 0:
        return None
    return pid, x, y, width, height
