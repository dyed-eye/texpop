from __future__ import annotations

import json
import subprocess
from typing import Any


def run_json(cmd: list[str]) -> Any:
    try:
        proc = subprocess.run(cmd, text=True, capture_output=True, check=True)
        return json.loads(proc.stdout)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError):
        return None


def run_text(cmd: list[str]) -> str | None:
    try:
        proc = subprocess.run(cmd, text=True, capture_output=True, check=True)
    except (OSError, subprocess.CalledProcessError):
        return None
    return proc.stdout.strip()
