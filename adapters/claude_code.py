from __future__ import annotations

import json
import os
import re
from pathlib import Path
from typing import Iterable

from proc import ProcessInfo, cli_name, session_fds

from . import ChatSourceAdapter
from .common import mtime_or_zero, newest_file, read_jsonl_tail, text_parts


class ClaudeCodeAdapter(ChatSourceAdapter):
    name = "claude"
    aliases = ("claude-code",)
    description = "Claude Code CLI (~/.claude/projects/*.jsonl)"

    def find_focused_session(self, processes: Iterable[ProcessInfo]) -> Path | None:
        candidates: list[Path] = []
        for info in processes:
            if cli_name(info) != "claude":
                continue
            candidates.extend(session_fds(info.pid, ".claude"))
            project_dir = project_dir_for_cwd(info.cwd)
            if project_dir:
                newest = newest_session(project_dir)
                if newest:
                    candidates.append(newest)
        unique = list(dict.fromkeys(candidates))
        return max(unique, key=mtime_or_zero) if unique else None

    def newest_session(self) -> Path | None:
        return newest_session()

    def get_last_assistant_turn(self, session_path: Path) -> str:
        modal = active_plan_mode_content(session_path)
        if modal:
            return modal
        return last_assistant_turn(session_path)


def projects_root() -> Path:
    return Path(os.environ.get("CLAUDE_PROJECTS_ROOT", Path.home() / ".claude" / "projects")).expanduser()


def project_dir_for_cwd(cwd: str | None) -> Path | None:
    if not cwd:
        return None
    # Claude Code encodes project dir names by replacing EVERY non-alphanumeric
    # codepoint with '-', not just ':' '\' '/' '.'. Underscores, spaces, and
    # non-ASCII letters (Cyrillic etc.) all collapse to one '-' per codepoint.
    encoded = re.sub(r"[^A-Za-z0-9]", "-", cwd)
    candidates = [encoded]
    if encoded:
        candidates.append(encoded[0].lower() + encoded[1:])
    for candidate in candidates:
        path = projects_root() / candidate
        if path.exists():
            return path
    return None


def newest_session(root: Path | None = None) -> Path | None:
    return newest_file(root or projects_root(), "*.jsonl", {"subagents", ".backups"})


def active_plan_mode_content(path: Path) -> str | None:
    lines = read_jsonl_tail(path, 1_500_000)
    plan_idx = -1
    tool_id: str | None = None
    for index in range(len(lines) - 1, -1, -1):
        line = lines[index]
        if "ExitPlanMode" not in line or "tool_use" not in line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        for item in ((obj.get("message") or {}).get("content") or []):
            if item.get("type") == "tool_use" and item.get("name") == "ExitPlanMode" and item.get("id"):
                tool_id = item["id"]
                break
        if tool_id:
            plan_idx = index
            break
    if plan_idx < 0 or not tool_id:
        return None
    for line in lines[plan_idx + 1 :]:
        if tool_id in line and "tool_use_id" in line:
            return None
    try:
        obj = json.loads(lines[plan_idx])
    except json.JSONDecodeError:
        return None
    for item in ((obj.get("message") or {}).get("content") or []):
        if item.get("type") == "tool_use" and item.get("name") == "ExitPlanMode":
            plan = (item.get("input") or {}).get("plan")
            if plan:
                return "## Plan mode active\n\n> Awaiting your approval\n\n" + str(plan)
    return None


def last_assistant_turn(path: Path) -> str:
    lines = read_jsonl_tail(path, 500_000)
    last_req: str | None = None
    last_req_index = -1
    for index in range(len(lines) - 1, -1, -1):
        line = lines[index]
        if "assistant" not in line or "text" not in line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if obj.get("type") == "assistant" and obj.get("requestId"):
            last_req = obj["requestId"]
            last_req_index = index
            break
    if not last_req:
        return ""
    parts: list[str] = []
    for line in lines:
        if last_req not in line or "assistant" not in line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if obj.get("requestId") != last_req:
            continue
        msg = obj.get("message") or {}
        if msg.get("role") == "assistant":
            parts.append(text_parts(msg.get("content"), {"text"}))
    turn = "".join(parts)
    user_text = _preceding_user_text(lines, last_req_index)
    if user_text:
        match = re.match(r"^/(btw|aside)\b", user_text.lstrip())
        if match:
            command = match.group(1).lower()
            label = "By the way" if command == "btw" else "Side question"
            return f"## /{command}\n\n> {label} response\n\n{turn}"
    return turn


def _preceding_user_text(lines: list[str], start: int) -> str | None:
    if start < 0:
        return None
    for line in reversed(lines[:start]):
        if "user" not in line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        msg = obj.get("message") or {}
        if msg.get("role") != "user":
            continue
        text = text_parts(msg.get("content"), {"text"})
        if text:
            return text
    return None
