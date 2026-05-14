from __future__ import annotations

import shutil

from . import FocusedWindow
from .common import run_json


def resolve() -> FocusedWindow | None:
    if not shutil.which("hyprctl"):
        return None
    data = run_json(["hyprctl", "-j", "activewindow"])
    if not isinstance(data, dict) or not data.get("mapped"):
        return None
    pid = data.get("pid")
    at = data.get("at") or [0, 0]
    size = data.get("size") or [900, 700]
    if not isinstance(pid, int):
        return None
    try:
        return FocusedWindow(
            pid,
            int(at[0]),
            int(at[1]),
            int(size[0]),
            int(size[1]),
            "hyprland",
            str(data.get("class") or ""),
            str(data.get("title") or ""),
            str(data.get("address") or ""),
        )
    except (TypeError, ValueError, IndexError):
        return None
