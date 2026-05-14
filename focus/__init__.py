from __future__ import annotations

import os
import shutil
from dataclasses import dataclass
from typing import Callable


@dataclass(frozen=True)
class FocusedWindow:
    pid: int
    x: int
    y: int
    width: int
    height: int
    source: str
    class_name: str = ""
    title: str = ""
    address: str = ""

    @property
    def rect(self) -> tuple[int, int, int, int]:
        return self.x, self.y, self.width, self.height


Resolver = Callable[[], FocusedWindow | None]


def resolve() -> FocusedWindow | None:
    resolvers: list[tuple[bool, str, Resolver]] = [
        (bool(os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")), "hyprland", _hyprland),
        (bool(os.environ.get("SWAYSOCK")), "sway", _sway),
        (bool(os.environ.get("DISPLAY")) and not os.environ.get("WAYLAND_DISPLAY"), "x11", _x11),
        (_desktop_is("gnome") or bool(os.environ.get("GNOME_SETUP_DISPLAY")), "gnome", _gnome),
        (bool(os.environ.get("KDE_FULL_SESSION")) or _desktop_is("kde"), "kde", _kde),
    ]
    for enabled, _name, resolver in resolvers:
        if not enabled:
            continue
        focused = resolver()
        if focused:
            return focused
    for binary, resolver in (
        ("hyprctl", _hyprland),
        ("swaymsg", _sway),
        ("xdotool", _x11),
        ("qdbus", _kde),
        ("gdbus", _gnome),
    ):
        if shutil.which(binary):
            focused = resolver()
            if focused:
                return focused
    return None


def _desktop_is(name: str) -> bool:
    desktop = os.environ.get("XDG_CURRENT_DESKTOP", "")
    return name.lower() in desktop.lower()


def _hyprland() -> FocusedWindow | None:
    from .hyprland import resolve as resolve_hyprland

    return resolve_hyprland()


def _sway() -> FocusedWindow | None:
    from .sway import resolve as resolve_sway

    return resolve_sway()


def _x11() -> FocusedWindow | None:
    from .x11 import resolve as resolve_x11

    return resolve_x11()


def _gnome() -> FocusedWindow | None:
    from .gnome import resolve as resolve_gnome

    return resolve_gnome()


def _kde() -> FocusedWindow | None:
    from .kde import resolve as resolve_kde

    return resolve_kde()
