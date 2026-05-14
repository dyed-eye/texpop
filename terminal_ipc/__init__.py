from __future__ import annotations

import os
from typing import Iterable

from focus import FocusedWindow
from proc import ProcessInfo, environ, process_table


def active_pane_pid(focused: FocusedWindow, processes: Iterable[ProcessInfo]) -> int | None:
    process_list = list(processes)
    envs = [os.environ.copy()]
    envs.extend(environ(info.pid) for info in process_list)

    from .tmux import active_pid as tmux_pid
    from .wezterm import active_pid as wezterm_pid
    from .kitty import active_pid as kitty_pid
    from .ghostty import active_pid as ghostty_pid

    for resolver in (tmux_pid, wezterm_pid, kitty_pid):
        for env in envs:
            pid = resolver(env)
            if pid:
                return pid

    return ghostty_pid(focused, process_table())
