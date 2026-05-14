from __future__ import annotations

import json
import subprocess
from typing import Any


def parse_pid(value: object) -> int | None:
    try:
        pid = int(str(value).strip())
    except (TypeError, ValueError):
        return None
    return pid if pid > 0 else None


def run_text(cmd: list[str], env: dict[str, str]) -> str | None:
    try:
        proc = subprocess.run(cmd, text=True, capture_output=True, check=True, env=env)
    except (OSError, subprocess.CalledProcessError):
        return None
    return proc.stdout.strip()


def run_json(cmd: list[str], env: dict[str, str]) -> Any:
    text = run_text(cmd, env)
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None
