from __future__ import annotations

import shutil
from typing import Any

from . import FocusedWindow
from .common import run_json


def resolve() -> FocusedWindow | None:
    if not shutil.which("swaymsg"):
        return None
    tree = run_json(["swaymsg", "-t", "get_tree"])
    node = _focused_node(tree)
    if not node:
        return None
    pid = node.get("pid")
    rect = node.get("rect") or {}
    if not isinstance(pid, int):
        return None
    try:
        return FocusedWindow(
            pid,
            int(rect.get("x", 0)),
            int(rect.get("y", 0)),
            int(rect.get("width", 900)),
            int(rect.get("height", 700)),
            "sway",
        )
    except (TypeError, ValueError):
        return None


def _focused_node(node: Any) -> dict[str, Any] | None:
    if not isinstance(node, dict):
        return None
    if node.get("focused"):
        return node
    for child in (node.get("nodes") or []) + (node.get("floating_nodes") or []):
        found = _focused_node(child)
        if found:
            return found
    return None
