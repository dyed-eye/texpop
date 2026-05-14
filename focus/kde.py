from __future__ import annotations

import re
import shutil

from . import FocusedWindow
from .common import run_text


def resolve() -> FocusedWindow | None:
    if not shutil.which("qdbus"):
        return None
    support = run_text(["qdbus", "org.kde.KWin", "/KWin", "supportInformation"])
    return _parse_support_window(support)


def _parse_support_window(text: str | None) -> FocusedWindow | None:
    if not text:
        return None
    active = re.search(r"Active window:.*?pid:\s*(\d+).*?geometry:\s*(-?\d+),(-?\d+)\s+(\d+)x(\d+)", text, re.S | re.I)
    if not active:
        return None
    try:
        pid, x, y, width, height = [int(value) for value in active.groups()]
    except ValueError:
        return None
    return FocusedWindow(pid, x, y, width, height, "kde")
