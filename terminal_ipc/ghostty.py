from __future__ import annotations

import shutil
from typing import Any, Iterable

from focus import FocusedWindow
from focus.common import run_json
from proc import ProcessInfo

SHELL_NAMES = {"zsh", "bash", "fish", "sh"}


def active_pid(focused: FocusedWindow, processes: Iterable[ProcessInfo]) -> int | None:
    if focused.source != "hyprland" or "ghostty" not in focused.class_name.lower():
        return None
    if not focused.address or not shutil.which("hyprctl"):
        return None

    active_index = _active_window_index(focused)
    if active_index is None:
        return None

    shells = [
        info
        for info in processes
        if info.ppid == focused.pid and info.tty_nr and info.name in SHELL_NAMES
    ]
    shells.sort(key=lambda info: info.start)
    if active_index >= len(shells):
        return None
    return shells[active_index].pid


def _active_window_index(focused: FocusedWindow) -> int | None:
    clients = run_json(["hyprctl", "-j", "clients"])
    if not isinstance(clients, list):
        return None
    ghostty_clients = [
        client
        for client in clients
        if isinstance(client, dict)
        and client.get("pid") == focused.pid
        and "ghostty" in str(client.get("class") or "").lower()
    ]
    ghostty_clients.sort(key=lambda client: _parse_stable_id(client.get("stableId")))
    for index, client in enumerate(ghostty_clients):
        if client.get("address") == focused.address:
            return index
    return None


def _parse_stable_id(value: Any) -> int:
    if isinstance(value, int):
        return value
    if not value:
        return 0
    text = str(value)
    try:
        return int(text, 16)
    except ValueError:
        try:
            return int(text)
        except ValueError:
            return 0
