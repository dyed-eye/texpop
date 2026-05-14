from __future__ import annotations

import shutil

from .common import parse_pid, run_json


def active_pid(env: dict[str, str]) -> int | None:
    if not env.get("WEZTERM_UNIX_SOCKET") or not shutil.which("wezterm"):
        return None
    data = run_json(["wezterm", "cli", "list", "--format", "json"], env)
    if not isinstance(data, list):
        return None
    active = [item for item in data if isinstance(item, dict) and item.get("is_active")]
    for item in active or data:
        pid = item.get("foreground_process_pid") or item.get("pane_pid")
        parsed = parse_pid(pid)
        if parsed:
            return parsed
    return None
