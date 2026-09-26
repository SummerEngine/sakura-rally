"""Corner warning kit (docs/CONTRACTS.md, "Corners"): big Japanese yellow diamond warning signs
(curve, sharp bend, hairpin, series of bends; left and right) and yellow/black chevron boards, free-standing
or mounted on a guardrail. Placed by tools/mapgen/lib/roadside.py; category `corner_sign` has
its own long view distance at runtime (MapWorld.CATEGORY_VIEW).

Board fronts face Blender +Y (the game's -Z); seen from the front the viewer's right is -X.
Symbols are authored in board coordinates (u to the viewer's right, v up) and mirrored for
the left-hand versions.
"""
from __future__ import annotations

import math

from .common import Kit
from .registry import BOTH, NONE, prop

CATEGORY = "corner_sign"
INK = "Ink"
FACE = "Yellow_Sign"
BACK = "Galvanized"

WARN_SIDE = 2.2      # diamond side (m): 3.1 m across its corners
WARN_CENTRE = 3.05   # board centre height (lib/roadside.py WARN_CENTRE)
WARN_POSTS = 0.55    # posts at x = +-0.55
CHEV_W, CHEV_H, CHEV_BOTTOM = 1.2, 1.5, 0.9   # free-standing chevron board
CHEV_POSTS = 0.4
RAIL_W, RAIL_H, RAIL_BOTTOM = 0.9, 1.1, 0.86  # on a guardrail (the beam's top is at 0.77)


def _posts(offset: float, radius: float, height: float) -> dict:
    """Collision: the posts, set 0.1 m behind the board (SoftCourse spans them; the board is
    above the car)."""
    return {"type": "cylinder", "radius": radius, "height": height,
            "offsets": [[-offset, 0.0, 0.1], [offset, 0.0, 0.1]]}


def _uv(u: float, v: float, zc: float, y: float, mirror: bool) -> tuple[float, float, float]:
    return (u if mirror else -u, y, zc + v)


def _prism(kit: Kit, mat: str, pts2d: list[tuple[float, float]], zc: float, y: float, t: float,
           mirror: bool) -> None:
    """Convex flat shape in board coordinates, extruded from y to y + t."""
    kit.hull(mat, [_uv(u, v, zc, yy, mirror) for u, v in pts2d for yy in (y, y + t)])


def _stroke(kit: Kit, mat: str, pts: list[tuple[float, float]], w: float, zc: float, y: float, t: float,
            mirror: bool) -> None:
    """Thick polyline (round joints) in board coordinates."""
    h = w / 2.0
    for (u0, v0), (u1, v1) in zip(pts, pts[1:]):
        L = math.hypot(u1 - u0, v1 - v0)
        nu, nv = -(v1 - v0) / L * h, (u1 - u0) / L * h
        _prism(kit, mat, [(u0 + nu, v0 + nv), (u0 - nu, v0 - nv), (u1 + nu, v1 + nv), (u1 - nu, v1 - nv)],
               zc, y, t, mirror)
    for u, v in pts[1:-1]:
        _prism(kit, mat, [(u + h * math.cos(a), v + h * math.sin(a)) for a in
                          (k * math.pi / 5 for k in range(10))], zc, y, t, mirror)


def _head(kit: Kit, mat: str, base: tuple[float, float], d: tuple[float, float], length: float, width: float,
          zc: float, y: float, t: float, mirror: bool) -> None:
    """Arrow head: base centre, unit direction d."""
    nu, nv = -d[1] * width / 2, d[0] * width / 2
    tip = (base[0] + d[0] * length, base[1] + d[1] * length)
    _prism(kit, mat, [(base[0] + nu, base[1] + nv), (base[0] - nu, base[1] - nv), tip], zc, y, t, mirror)


def _arc(cu: float, cv: float, r: float, a0: float, a1: float, steps: int) -> list[tuple[float, float]]:
    return [(cu + r * math.cos(math.radians(a0 + (a1 - a0) * k / steps)),
             cv + r * math.sin(math.radians(a0 + (a1 - a0) * k / steps))) for k in range(steps + 1)]


def _unit(u: float, v: float) -> tuple[float, float]:
    L = math.hypot(u, v)
    return (u / L, v / L)


# ----------------------------------------------------------------------------------------
# Warning diamonds
# ----------------------------------------------------------------------------------------
def _diamond(kit: Kit) -> float:
    """Posts, back plate and the yellow face with its black edge and inset line. Returns the
    y of the face's front."""
    top = WARN_CENTRE + WARN_SIDE / math.sqrt(2) - 0.3
    for x in (-WARN_POSTS, WARN_POSTS):
        kit.cyl(BACK, 0.065, top, (x, -0.1, 0), seg=6)
        kit.cyl("Concrete", 0.16, 0.12, (x, -0.1, 0), seg=6)
    for zb in (WARN_CENTRE - 0.55, WARN_CENTRE + 0.55):  # clamp bars behind the board
        kit.cbox(BACK, (2 * WARN_POSTS + 0.2, 0.06, 0.1), (0, -0.07, zb))
    layers = ((BACK, WARN_SIDE, -0.04, 0.03), (INK, WARN_SIDE, -0.01, 0.02), (FACE, WARN_SIDE - 0.1, 0.01, 0.015),
              (INK, WARN_SIDE - 0.26, 0.025, 0.012), (FACE, WARN_SIDE - 0.4, 0.037, 0.012))
    for mat, s, y, t in layers:
        kit.cbox(mat, (s, t, s), (0, y + t / 2, WARN_CENTRE), (0, 45, 0))
    return 0.049


SYMBOL_W = 0.26  # stroke width of the symbols (m)


def _warn_curve(kit: Kit, mirror: bool) -> None:
    """右方屈曲: an arrow going up and bending to the right."""
    y = _diamond(kit)
    pts = [(-0.34, -0.72), (-0.34, -0.12)] + _arc(0.46, -0.12, 0.8, 180.0, 128.0, 6)[1:]
    _stroke(kit, INK, pts, SYMBOL_W, WARN_CENTRE, y, 0.012, mirror)
    a = pts[-1]
    d = _unit(pts[-1][0] - pts[-2][0], pts[-1][1] - pts[-2][1])
    _head(kit, INK, a, d, 0.36, 0.62, WARN_CENTRE, y, 0.012, mirror)


def _warn_sharp(kit: Kit, mirror: bool) -> None:
    """右方屈折: up, then a right angle to the right."""
    y = _diamond(kit)
    pts = [(-0.32, -0.72), (-0.32, 0.2), (0.12, 0.2)]
    _stroke(kit, INK, pts, SYMBOL_W, WARN_CENTRE, y, 0.012, mirror)
    _head(kit, INK, (0.12, 0.2), (1.0, 0.0), 0.4, 0.66, WARN_CENTRE, y, 0.012, mirror)


def _warn_hairpin(kit: Kit, mirror: bool) -> None:
    """Hairpin: up, a U-turn over the top to the right, and back down."""
    y = _diamond(kit)
    pts = [(-0.36, -0.7), (-0.36, 0.1)] + _arc(0.0, 0.1, 0.36, 180.0, 0.0, 10)[1:] + [(0.36, -0.12)]
    _stroke(kit, INK, pts, SYMBOL_W, WARN_CENTRE, y, 0.012, mirror)
    _head(kit, INK, (0.36, -0.12), (0.0, -1.0), 0.4, 0.66, WARN_CENTRE, y, 0.012, mirror)


def _warn_series(kit: Kit, mirror: bool) -> None:
    """右背向屈曲: a series of bends, the first to the right - the arrow jogs right, then left."""
    y = _diamond(kit)

    def smooth(t: float) -> float:
        t = min(max((t - 0.12) / 0.76, 0.0), 1.0)
        return t * t * (3.0 - 2.0 * t)

    pts = [(-0.32 + 0.64 * smooth(k / 14), -0.82 + 1.3 * k / 14) for k in range(15)]
    _stroke(kit, INK, pts, SYMBOL_W, WARN_CENTRE, y, 0.012, mirror)
    _head(kit, INK, pts[-1], (0.0, 1.0), 0.36, 0.62, WARN_CENTRE, y, 0.012, mirror)


WARN_COLLISION = _posts(WARN_POSTS, 0.07, 4.3)


@prop("corner_warn_curve_left", CATEGORY, ["roadside"], BOTH, WARN_COLLISION, 900)
def corner_warn_curve_left(kit: Kit) -> None:
    _warn_curve(kit, mirror=True)


@prop("corner_warn_curve_right", CATEGORY, ["roadside"], BOTH, WARN_COLLISION, 900)
def corner_warn_curve_right(kit: Kit) -> None:
    _warn_curve(kit, mirror=False)


@prop("corner_warn_sharp_left", CATEGORY, ["roadside"], BOTH, WARN_COLLISION, 900)
def corner_warn_sharp_left(kit: Kit) -> None:
    _warn_sharp(kit, mirror=True)


@prop("corner_warn_sharp_right", CATEGORY, ["roadside"], BOTH, WARN_COLLISION, 900)
def corner_warn_sharp_right(kit: Kit) -> None:
    _warn_sharp(kit, mirror=False)


@prop("corner_warn_series_left", CATEGORY, ["roadside"], BOTH, WARN_COLLISION, 900)
def corner_warn_series_left(kit: Kit) -> None:
    _warn_series(kit, mirror=True)


@prop("corner_warn_series_right", CATEGORY, ["roadside"], BOTH, WARN_COLLISION, 900)
def corner_warn_series_right(kit: Kit) -> None:
    _warn_series(kit, mirror=False)


@prop("corner_warn_hairpin_left", CATEGORY, ["roadside"], BOTH, WARN_COLLISION, 900)
def corner_warn_hairpin_left(kit: Kit) -> None:
    _warn_hairpin(kit, mirror=True)


@prop("corner_warn_hairpin_right", CATEGORY, ["roadside"], BOTH, WARN_COLLISION, 900)
def corner_warn_hairpin_right(kit: Kit) -> None:
    _warn_hairpin(kit, mirror=False)


# ----------------------------------------------------------------------------------------
# Chevron boards
# ----------------------------------------------------------------------------------------
def _chevron_board(kit: Kit, w: float, h: float, bottom: float, mirror: bool, y0: float = 0.0) -> None:
    """Portrait yellow board with a black edge and one fat black chevron pointing right (the
    way the road turns), front at y0 + 0.04."""
    zc = bottom + h / 2
    kit.cbox(BACK, (w, 0.03, h), (0, y0 - 0.025, zc))
    kit.cbox(INK, (w, 0.02, h), (0, y0 - 0.0, zc))
    kit.cbox(FACE, (w - 0.1, 0.015, h - 0.1), (0, y0 + 0.017, zc))
    y = y0 + 0.024
    sw = 0.27 * w / 1.2
    pts = [(-0.26 * w, 0.34 * h), (0.2 * w, 0.0), (-0.26 * w, -0.34 * h)]
    _stroke(kit, INK, pts, sw, zc, y, 0.012, mirror)


def _chevron(kit: Kit, mirror: bool) -> None:
    top = CHEV_BOTTOM + CHEV_H - 0.1
    for x in (-CHEV_POSTS, CHEV_POSTS):
        kit.cyl(BACK, 0.05, top, (x, -0.08, 0), seg=6)
    kit.cbox(BACK, (2 * CHEV_POSTS + 0.14, 0.05, 0.08), (0, -0.06, CHEV_BOTTOM + 0.3))
    kit.cbox(BACK, (2 * CHEV_POSTS + 0.14, 0.05, 0.08), (0, -0.06, CHEV_BOTTOM + CHEV_H - 0.3))
    _chevron_board(kit, CHEV_W, CHEV_H, CHEV_BOTTOM, mirror)


def _chevron_rail(kit: Kit, mirror: bool) -> None:
    """On a guardrail: a stub post clamped to the rail post behind the beam, board above it."""
    kit.cyl(BACK, 0.045, RAIL_BOTTOM + RAIL_H - 0.12 - 0.3, (0, -0.16, 0.3), seg=6)
    kit.cbox(BACK, (0.16, 0.12, 0.14), (0, -0.12, 0.62))
    kit.cbox(BACK, (0.3, 0.05, 0.07), (0, -0.1, RAIL_BOTTOM + 0.25))
    kit.cbox(BACK, (0.3, 0.05, 0.07), (0, -0.1, RAIL_BOTTOM + RAIL_H - 0.25))
    _chevron_board(kit, RAIL_W, RAIL_H, RAIL_BOTTOM, mirror, y0=-0.04)


CHEV_COLLISION = _posts(CHEV_POSTS, 0.06, CHEV_BOTTOM + CHEV_H)


@prop("corner_chevron_left", CATEGORY, ["roadside"], BOTH, CHEV_COLLISION, 400)
def corner_chevron_left(kit: Kit) -> None:
    """Free-standing chevron board; the chevron points left as the driver sees it."""
    _chevron(kit, mirror=True)


@prop("corner_chevron_right", CATEGORY, ["roadside"], BOTH, CHEV_COLLISION, 400)
def corner_chevron_right(kit: Kit) -> None:
    _chevron(kit, mirror=False)


@prop("corner_chevron_rail_left", CATEGORY, ["roadside"], BOTH, NONE, 400)
def corner_chevron_rail_left(kit: Kit) -> None:
    """Chevron board mounted on a guardrail post (no collider: the rail is the barrier)."""
    _chevron_rail(kit, mirror=True)


@prop("corner_chevron_rail_right", CATEGORY, ["roadside"], BOTH, NONE, 400)
def corner_chevron_rail_right(kit: Kit) -> None:
    _chevron_rail(kit, mirror=False)
