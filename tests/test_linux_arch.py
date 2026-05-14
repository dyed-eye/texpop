from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from adapters.claude_code import last_assistant_turn
from adapters.codex import CodexAdapter
from focus import FocusedWindow
from focus.gnome import _parse_eval_result
from proc import ProcessInfo
from terminal_ipc.ghostty import active_pid as ghostty_active_pid
from terminal_ipc.kitty import focused_pid as kitty_focused_pid


class LinuxAdapterTests(unittest.TestCase):
    def test_codex_adapter_reads_last_assistant_message(self) -> None:
        path = _jsonl(
            {
                "payload": {
                    "role": "assistant",
                    "content": [{"type": "output_text", "text": "first"}],
                }
            },
            {
                "payload": {
                    "role": "assistant",
                    "content": [{"type": "text", "text": "second"}],
                }
            },
        )
        self.addCleanup(path.unlink)

        self.assertEqual(CodexAdapter().get_last_assistant_turn(path), "second")

    def test_claude_adapter_joins_last_request_id(self) -> None:
        path = _jsonl(
            {"type": "assistant", "requestId": "old", "message": {"role": "assistant", "content": [{"type": "text", "text": "old"}]}},
            {"type": "assistant", "requestId": "new", "message": {"role": "assistant", "content": [{"type": "text", "text": "one"}]}},
            {"type": "assistant", "requestId": "new", "message": {"role": "assistant", "content": [{"type": "text", "text": " two"}]}},
        )
        self.addCleanup(path.unlink)

        self.assertEqual(last_assistant_turn(path), "one two")


class LinuxFocusTests(unittest.TestCase):
    def test_gnome_eval_result_parser(self) -> None:
        self.assertEqual(_parse_eval_result("(true, '123,1,2,900,700')"), (123, 1, 2, 900, 700))

    def test_kitty_focused_pid_parser(self) -> None:
        self.assertEqual(
            kitty_focused_pid(
                [
                    {
                        "tabs": [
                            {
                                "windows": [
                                    {
                                        "is_focused": True,
                                        "foreground_processes": [{"pid": 456}],
                                    }
                                ]
                            }
                        ]
                    }
                ]
            ),
            456,
        )

    def test_ghostty_maps_focused_window_index_to_shell_start_order(self) -> None:
        focused = _focused_ghostty_window(address="0xbb")
        processes = [
            _proc(pid=20, ppid=10, name="zsh", start=100),
            _proc(pid=21, ppid=10, name="zsh", start=200),
        ]

        def fake_clients(_: list[str]) -> list[dict[str, object]]:
            return [
                {"pid": 10, "class": "com.mitchellh.ghostty", "address": "0xaa", "stableId": "1"},
                {"pid": 10, "class": "com.mitchellh.ghostty", "address": "0xbb", "stableId": "2"},
            ]

        import terminal_ipc.ghostty as ghostty

        original = ghostty.run_json
        original_which = ghostty.shutil.which
        ghostty.run_json = fake_clients
        ghostty.shutil.which = lambda _: "/usr/bin/hyprctl"
        try:
            self.assertEqual(ghostty_active_pid(focused, processes), 21)
        finally:
            ghostty.run_json = original
            ghostty.shutil.which = original_which


def _jsonl(*objects: object) -> Path:
    handle = tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False)
    with handle:
        for obj in objects:
            handle.write(json.dumps(obj) + "\n")
    return Path(handle.name)


def _proc(pid: int, ppid: int, name: str, start: int) -> ProcessInfo:
    return ProcessInfo(pid=pid, ppid=ppid, name=name, exe=name, cmdline=name, cwd="/tmp", tty_nr=1, start=start)


def _focused_ghostty_window(address: str) -> FocusedWindow:
    return FocusedWindow(
        pid=10,
        x=0,
        y=0,
        width=1,
        height=1,
        source="hyprland",
        class_name="com.mitchellh.ghostty",
        address=address,
    )


if __name__ == "__main__":
    unittest.main()
