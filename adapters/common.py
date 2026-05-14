from __future__ import annotations

import os
from pathlib import Path
from typing import Any, Iterable


def mtime_or_zero(path: Path) -> float:
    try:
        return path.stat().st_mtime
    except OSError:
        return 0.0


def newest_file(root: Path, pattern: str, excluded_parts: set[str] | None = None) -> Path | None:
    if not root.exists():
        return None
    excluded = excluded_parts or set()
    files = [p for p in root.rglob(pattern) if p.is_file() and not excluded.intersection(p.parts)]
    return max(files, key=mtime_or_zero) if files else None


def read_jsonl_tail(path: Path, max_bytes: int = 2 * 1024 * 1024) -> list[str]:
    try:
        with path.open("rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            if size > max_bytes:
                handle.seek(-max_bytes, os.SEEK_END)
                handle.readline()
            else:
                handle.seek(0)
            data = handle.read(max_bytes)
    except OSError:
        return []
    return data.decode("utf-8", "replace").splitlines()


def text_parts(content: Iterable[Any] | str | None, text_types: set[str]) -> str:
    if isinstance(content, str):
        return content
    out: list[str] = []
    for item in content or []:
        if isinstance(item, dict) and item.get("type") in text_types and item.get("text"):
            out.append(item["text"])
    return "".join(out)
