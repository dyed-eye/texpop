from __future__ import annotations

from abc import ABC, abstractmethod
from pathlib import Path
from typing import Iterable

from proc import ProcessInfo, cli_name


class ChatSourceAdapter(ABC):
    name: str
    aliases: tuple[str, ...] = ()
    description: str

    def matches(self, processes: Iterable[ProcessInfo]) -> bool:
        names = {cli_name(info) for info in processes}
        return self.name in names or any(alias in names for alias in self.aliases)

    @abstractmethod
    def find_focused_session(self, processes: Iterable[ProcessInfo]) -> Path | None:
        raise NotImplementedError

    @abstractmethod
    def newest_session(self) -> Path | None:
        raise NotImplementedError

    @abstractmethod
    def get_last_assistant_turn(self, session_path: Path) -> str:
        raise NotImplementedError


def load_adapters() -> list[ChatSourceAdapter]:
    from .claude_code import ClaudeCodeAdapter
    from .codex import CodexAdapter

    return [ClaudeCodeAdapter(), CodexAdapter()]
