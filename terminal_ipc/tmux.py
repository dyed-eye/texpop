from __future__ import annotations

import shutil

from .common import parse_pid, run_text


def active_pid(env: dict[str, str]) -> int | None:
    if not env.get("TMUX") or not shutil.which("tmux"):
        return None
    return parse_pid(run_text(["tmux", "display-message", "-p", "#{pane_pid}"], env))
