#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import NoReturn

import focus
import popup
import terminal_ipc
from adapters import ChatSourceAdapter, load_adapters
from adapters.common import mtime_or_zero
from proc import ProcessInfo, find_cli_processes, process_tree


def die(message: str) -> NoReturn:
    print(f"texpop: {message}", file=sys.stderr)
    raise SystemExit(1)


def focused_processes() -> tuple[list[ProcessInfo], tuple[int, int, int, int] | None]:
    focused = focus.resolve()
    if not focused:
        return [], None
    window_processes = process_tree(focused.pid)
    active_pid = terminal_ipc.active_pane_pid(focused, window_processes)
    if active_pid and active_pid != focused.pid:
        return process_tree(active_pid), focused.rect
    return window_processes, focused.rect


def pick_adapter(source: str, session: Path | None, processes: list[ProcessInfo]) -> tuple[ChatSourceAdapter, Path]:
    adapters = load_adapters()
    if session:
        adapter = adapter_for_source(adapters, source, session)
        return adapter, session

    if source != "auto":
        adapter = adapter_for_source(adapters, source, None)
        path = adapter.find_focused_session(processes) or adapter.newest_session()
        if not path:
            die(f"no {source} session found")
        return adapter, path

    cli_processes = find_cli_processes(processes)
    for adapter in adapters:
        if not adapter.matches(cli_processes):
            continue
        path = adapter.find_focused_session(cli_processes)
        if path:
            return adapter, path

    candidates: list[tuple[ChatSourceAdapter, Path]] = []
    for adapter in adapters:
        path = adapter.newest_session()
        if path:
            candidates.append((adapter, path))
    if not candidates:
        die("no auto session found")
    return max(candidates, key=lambda item: mtime_or_zero(item[1]))


def adapter_for_source(adapters: list[ChatSourceAdapter], source: str, session: Path | None) -> ChatSourceAdapter:
    if source == "auto" and session:
        if ".claude" in session.parts:
            source = "claude"
        elif ".codex" in session.parts:
            source = "local"
        else:
            source = "local"
    for adapter in adapters:
        names = {adapter.name, *adapter.aliases}
        if source in names:
            return adapter
    die(f"unsupported source: {source}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", choices=("auto", "local", "claude", "codex"), default="auto")
    parser.add_argument("--session")
    parser.add_argument("--print-message", action="store_true")
    parser.add_argument("--browser", action="store_true")
    args = parser.parse_args()

    explicit_session = Path(args.session).expanduser() if args.session else None
    if explicit_session and not explicit_session.exists():
        die(f"session not found: {explicit_session}")

    processes, rect = focused_processes()
    adapter, session = pick_adapter(args.source, explicit_session, processes)
    message = adapter.get_last_assistant_turn(session)
    if not message.strip():
        die(f"no assistant text in {session}")
    if args.print_message:
        print(message)
        return

    root = Path(__file__).resolve().parent
    try:
        html_path = popup.write_html(root, message)
    except RuntimeError as exc:
        die(str(exc))
    if popup.show(html_path, rect, args.browser):
        return
    die("no supported popup backend found")


if __name__ == "__main__":
    main()
