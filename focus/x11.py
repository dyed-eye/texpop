from __future__ import annotations

import re
import shutil

from . import FocusedWindow
from .common import run_text


def resolve() -> FocusedWindow | None:
    if not shutil.which("xdotool"):
        return None
    window_id = run_text(["xdotool", "getactivewindow"])
    if not window_id:
        return None
    pid_text = run_text(["xdotool", "getwindowpid", window_id])
    geometry = run_text(["xdotool", "getwindowgeometry", "--shell", window_id])
    if not pid_text or not geometry:
        return None
    values = dict(re.findall(r"^([A-Z]+)=(-?\d+)$", geometry, re.MULTILINE))
    try:
        return FocusedWindow(
            int(pid_text),
            int(values.get("X", "0")),
            int(values.get("Y", "0")),
            int(values.get("WIDTH", "900")),
            int(values.get("HEIGHT", "700")),
            "x11",
        )
    except ValueError:
        return None
