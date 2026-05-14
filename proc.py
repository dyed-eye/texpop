from __future__ import annotations

import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


@dataclass(frozen=True)
class ProcessInfo:
    pid: int
    ppid: int
    name: str
    exe: str
    cmdline: str
    cwd: str | None
    tty_nr: int
    start: int


def process_info(pid: int) -> ProcessInfo | None:
    stat = _stat(pid)
    if not stat:
        return None
    return ProcessInfo(
        pid=pid,
        ppid=stat["ppid"],
        name=stat["comm"],
        exe=_readlink(f"/proc/{pid}/exe") or "",
        cmdline=cmdline(pid),
        cwd=cwd(pid),
        tty_nr=stat["tty_nr"],
        start=stat["start"],
    )


def process_table() -> list[ProcessInfo]:
    out: list[ProcessInfo] = []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        info = process_info(int(entry.name))
        if info:
            out.append(info)
    return out


def process_tree(root_pid: int) -> list[ProcessInfo]:
    seen: set[int] = set()
    stack = [root_pid]
    out: list[ProcessInfo] = []
    while stack:
        pid = stack.pop()
        if pid in seen:
            continue
        seen.add(pid)
        info = process_info(pid)
        if info:
            out.append(info)
        stack.extend(children(pid))
    return out


def children(pid: int) -> list[int]:
    path = Path(f"/proc/{pid}/task/{pid}/children")
    try:
        raw = path.read_text().strip()
    except OSError:
        return []
    if not raw:
        return []
    return [int(item) for item in raw.split() if item.isdigit()]


def find_cli_processes(processes: Iterable[ProcessInfo]) -> list[ProcessInfo]:
    matches: list[ProcessInfo] = []
    for info in processes:
        if cli_name(info):
            matches.append(info)
    return matches


def cli_name(info: ProcessInfo) -> str | None:
    name = Path(info.exe).name or info.name
    cmd = info.cmdline
    if name == "claude" or _word("claude", cmd):
        return "claude"
    if name == "codex" or _word("codex", cmd):
        return "codex"
    return None


def session_fds(pid: int, required_part: str, name_prefix: str | None = None) -> list[Path]:
    fd_dir = Path(f"/proc/{pid}/fd")
    sessions: list[Path] = []
    try:
        fds = list(fd_dir.iterdir())
    except OSError:
        return sessions
    for fd in fds:
        try:
            target = fd.readlink()
        except OSError:
            continue
        if target.suffix != ".jsonl" or required_part not in target.parts:
            continue
        if name_prefix and not target.name.startswith(name_prefix):
            continue
        if "subagents" in target.parts or ".backups" in target.parts:
            continue
        if target.exists():
            sessions.append(target)
    return sessions


def environ(pid: int) -> dict[str, str]:
    try:
        raw = Path(f"/proc/{pid}/environ").read_bytes()
    except OSError:
        return {}
    env: dict[str, str] = {}
    for part in raw.split(b"\0"):
        if b"=" not in part:
            continue
        key, value = part.split(b"=", 1)
        env[key.decode("utf-8", "replace")] = value.decode("utf-8", "replace")
    return env


def cmdline(pid: int) -> str:
    try:
        raw = Path(f"/proc/{pid}/cmdline").read_bytes()
    except OSError:
        return ""
    return raw.replace(b"\0", b" ").decode("utf-8", "replace").strip()


def cwd(pid: int) -> str | None:
    return _readlink(f"/proc/{pid}/cwd")


def _stat(pid: int) -> dict[str, int | str] | None:
    try:
        stat = Path(f"/proc/{pid}/stat").read_text()
    except OSError:
        return None
    end = stat.rfind(")")
    if end == -1:
        return None
    fields = stat[end + 2 :].split()
    try:
        return {
            "comm": stat[stat.find("(") + 1 : end],
            "ppid": int(fields[1]),
            "tty_nr": int(fields[4]),
            "start": int(fields[19]),
        }
    except (IndexError, ValueError):
        return None


def _readlink(path: str) -> str | None:
    try:
        return os.readlink(path)
    except OSError:
        return None


def _word(word: str, value: str) -> bool:
    return bool(re.search(rf"(^|[\s/]){re.escape(word)}($|[\s/])", value))
