"""Prop registry: every builder registers itself with metadata used for the manifest."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable

from .common import Kit

PLACEMENTS = ("roadside", "field", "forest", "village", "water_edge", "slope", "spectator_zone")
SPRING = ["spring"]
AUTUMN = ["autumn"]
BOTH = ["spring", "autumn"]


@dataclass
class PropSpec:
    name: str
    build: Callable[[Kit], None]
    category: str
    placement: list[str]
    seasons: list[str]
    # {"type": "none"} | {"type": "cylinder", "radius": r} (height from bounds)
    # | {"type": "box"} (size/center from bounds) | {"type": "box", "size": [...], "center": [...]}
    collision: dict = field(default_factory=lambda: {"type": "none"})
    max_tris: int = 3000


PROPS: dict[str, PropSpec] = {}

BUDGET = {
    "tree": 1500, "vegetation": 1500, "ground_cover": 40, "rock": 300, "building": 3000,
    "village": 3000, "rally": 3000, "spectator": 1300, "corner_sign": 900,
}


def prop(name: str, category: str, placement: list[str], seasons: list[str],
         collision: dict | None = None, max_tris: int | None = None):
    for p in placement:
        assert p in PLACEMENTS, (name, p)

    def deco(fn: Callable[[Kit], None]) -> Callable[[Kit], None]:
        assert name not in PROPS, name
        PROPS[name] = PropSpec(name, fn, category, placement, seasons,
                               collision or {"type": "none"},
                               max_tris if max_tris is not None else BUDGET.get(category, 3000))
        return fn
    return deco


def cyl(radius: float) -> dict:
    return {"type": "cylinder", "radius": radius}


def box() -> dict:
    return {"type": "box"}


NONE = {"type": "none"}
