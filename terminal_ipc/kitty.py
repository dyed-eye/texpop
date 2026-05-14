from __future__ import annotations

import shutil
from typing import Any

from .common import parse_pid, run_json


def active_pid(env: dict[str, str]) -> int | None:
    if not env.get("KITTY_LISTEN_ON") or not shutil.which("kitty"):
        return None
    return focused_pid(run_json(["kitty", "@", "ls"], env))


def focused_pid(node: Any) -> int | None:
    if isinstance(node, list):
        for child in node:
            found = focused_pid(child)
            if found:
                return found
        return None
    if not isinstance(node, dict):
        return None
    if node.get("is_focused") or node.get("is_active"):
        for proc in node.get("foreground_processes") or []:
            if isinstance(proc, dict):
                pid = parse_pid(proc.get("pid"))
                if pid:
                    return pid
    for key in ("os_windows", "tabs", "windows"):
        found = focused_pid(node.get(key))
        if found:
            return found
    return None
