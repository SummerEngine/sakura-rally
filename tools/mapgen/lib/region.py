"""Regions of the world: a map spec authored in its own coordinates (maps/hanami.py,
maps/momiji.py) placed into world coordinates by a Frame (translation + turn about +Y)."""
from __future__ import annotations

import copy
import math
from dataclasses import dataclass


@dataclass(frozen=True)
class Frame:
    """Region-local -> world: turn by `yaw` (radians, Godot convention: a local -Z forward
    turns to (-sin yaw, -cos yaw)), then move by (cx, cz)."""
    cx: float = 0.0
    cz: float = 0.0
    yaw: float = 0.0

    def xz(self, x, z):
        c, s = math.cos(self.yaw), math.sin(self.yaw)
        return self.cx + c * x + s * z, self.cz - s * x + c * z

    def local(self, x, z):
        """World -> region-local (inverse of xz); works on numpy arrays."""
        c, s = math.cos(self.yaw), math.sin(self.yaw)
        dx, dz = x - self.cx, z - self.cz
        return c * dx - s * dz, s * dx + c * dz

    @property
    def identity(self) -> bool:
        return self.cx == 0.0 and self.cz == 0.0 and self.yaw == 0.0


def _p2(frame: Frame, p):
    x, z = frame.xz(p[0], p[1])
    return (round(x, 4), round(z, 4))


def _poly(frame: Frame, poly):
    return [_p2(frame, p) for p in poly]


def place(spec: dict, frame: Frame) -> dict:
    """A deep copy of a region spec with every absolute coordinate in world space. Road-relative
    items (road_at / from_cp / lap_frac) need nothing: they follow the placed road."""
    s = copy.deepcopy(spec)
    if frame.identity:
        return s
    deg = math.degrees(frame.yaw)
    road = s["road"]
    road["points"] = [(*_p2(frame, p[:2]), *p[2:]) for p in road["points"]]
    if s.get("lake"):
        s["lake"]["poly"] = _poly(frame, s["lake"]["poly"])
    if s.get("river"):
        r = s["river"]
        r["points"] = [(*_p2(frame, p[:2]), p[2]) for p in r["points"]]
        r["pins"] = _poly(frame, r.get("pins", []))
        for f in r.get("falls", []):
            f["at"] = _p2(frame, f["at"])
        for st in r.get("steep", []):
            st["pos"] = _p2(frame, st["pos"])
    t = s["terrain"]
    for h in t.get("hills", []):
        h["pos"] = _p2(frame, h["pos"])
    for ter in t.get("terraces", []):
        ter["poly"] = _poly(frame, ter["poly"])
    for pad in t.get("pads", []):
        if "pos" in pad:
            pad["pos"] = _p2(frame, pad["pos"])
    for f in s.get("features", []):
        if "pos" in f:
            f["pos"] = _p2(frame, f["pos"])
        if f.get("kind") == "row":
            f["from"] = _p2(frame, f["from"])
            f["to"] = _p2(frame, f["to"])
        if isinstance(f.get("face"), (int, float)) and not isinstance(f.get("face"), bool):
            f["face"] = f["face"] + deg
    for r in s.get("scatter", []):
        for reg in r.get("regions", []):
            if "circle" in reg:
                cx, cz, rad = reg["circle"]
                reg["circle"] = (*_p2(frame, (cx, cz)), rad)
            if "poly" in reg:
                reg["poly"] = _poly(frame, reg["poly"])
        if "exclude" in r:
            r["exclude"] = [(*_p2(frame, (cx, cz)), rad) for cx, cz, rad in r["exclude"]]
        if "exclude_poly" in r:
            r["exclude_poly"] = [_poly(frame, p) for p in r["exclude_poly"]]
    return s
