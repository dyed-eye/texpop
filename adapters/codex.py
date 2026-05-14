from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Iterable

from proc import ProcessInfo, cli_name, session_fds

from . import ChatSourceAdapter
from .common import mtime_or_zero, newest_file, read_jsonl_tail, text_parts


class CodexAdapter(ChatSourceAdapter):
    name = "codex"
    aliases = ("local",)
    description = "Codex CLI (~/.codex/sessions/.../rollout-*.jsonl)"

    def find_focused_session(self, processes: Iterable[ProcessInfo]) -> Path | None:
        candidates: list[Path] = []
        for info in processes:
            if cli_name(info) != "codex":
                continue
            candidates.extend(session_fds(info.pid, ".codex", "rollout-"))
        unique = list(dict.fromkeys(candidates))
        return max(unique, key=mtime_or_zero) if unique else None

    def newest_session(self) -> Path | None:
        return newest_file(sessions_root(), "rollout-*.jsonl")

    def get_last_assistant_turn(self, session_path: Path) -> str:
        for line in reversed(read_jsonl_tail(session_path)):
            if "assistant" not in line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else obj
            if payload.get("role") != "assistant":
                continue
            text = text_parts(payload.get("content"), {"input_text", "output_text", "text"})
            if text.strip():
                return text
        return ""


def sessions_root() -> Path:
    explicit = os.environ.get("TEXPOP_LOCAL_SESSIONS")
    if explicit:
        return Path(explicit).expanduser()
    home = os.environ.get("TEXPOP_LOCAL_HOME")
    if home:
        return Path(home).expanduser() / "sessions"
    return Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")).expanduser() / "sessions"
