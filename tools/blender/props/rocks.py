"""Rocks, boulder and cliff masses: convex-hull facets, moss on up-facing tops."""
from __future__ import annotations

import math
import random

from mathutils import Matrix, Vector

from .common import Kit, bm_hull, grad_z, trs
from .registry import BOTH, NONE, box, cyl, prop

ROCK_SHADE = (0.74, 0.72, 0.86)


def rock_points(r: random.Random, n: int, size: tuple[float, float, float], rough: float,
                flat_bottom: float = 0.3) -> list[Vector]:
    """Fibonacci-sphere points on an ellipsoid with random radial jitter, bottom clamped flat."""
    pts = []
    golden = math.pi * (3 - math.sqrt(5))
    for i in range(n):
        y = 1 - 2 * (i + 0.5) / n
        rad = math.sqrt(1 - y * y)
        a = golden * i + r.uniform(-0.25, 0.25)
        d = Vector((math.cos(a) * rad, math.sin(a) * rad, y))
        k = 1.0 + r.uniform(-rough, rough)
        p = Vector((d.x * size[0] / 2 * k, d.y * size[1] / 2 * k, d.z * size[2] / 2 * k))
        p.z = max(p.z, -size[2] / 2 * (1 - flat_bottom))
        pts.append(p)
    return pts


def _rock(kit: Kit, size: tuple[float, float, float], n: int, rough: float, moss: float,
          embed: float = 0.12, m: Matrix | None = None, shade_h: float | None = None,
          dark: bool = False) -> None:
    r = kit.r
    pts = rock_points(r, n, size, rough)
    zmin = min(p.z for p in pts)
    base = Matrix.Translation((0, 0, -zmin - size[2] * embed))
    mm = (m if m is not None else Matrix.Identity(4)) @ base
    h = shade_h if shade_h is not None else size[2]
    top_z = h * (1 - moss) if moss > 0 else 1e9
    body = "Rock_Dark" if dark else "Rock"

    def matfn(c: Vector, nrm: Vector) -> str:
        return "Moss" if (nrm.z > 0.72 and c.z > top_z) else body
    kit.add(bm_hull(pts), matfn, mm, grad_z(-0.2, h, ROCK_SHADE))


@prop("rock_a", "rock", ["roadside", "field", "forest", "slope", "water_edge"], BOTH, cyl(0.3))
def rock_a(kit: Kit) -> None:
    """Small rounded stone ~0.6 m."""
    _rock(kit, (0.7, 0.6, 0.5), 30, 0.18, 0.0)


@prop("rock_b", "rock", ["roadside", "field", "forest", "slope", "water_edge"], BOTH, box())
def rock_b(kit: Kit) -> None:
    """Flat slab ~1.2 m."""
    _rock(kit, (1.3, 0.9, 0.45), 36, 0.2, 0.4)


@prop("rock_c", "rock", ["roadside", "forest", "slope", "water_edge"], BOTH, cyl(0.5))
def rock_c(kit: Kit) -> None:
    """Tall angular stone ~1.5 m."""
    _rock(kit, (1.05, 0.9, 1.5), 32, 0.22, 0.25, m=trs((0, 0, 0), (6, -4, 20)))


@prop("rock_d", "rock", ["roadside", "field", "forest", "slope", "water_edge"], BOTH, box())
def rock_d(kit: Kit) -> None:
    """Cluster of three stones ~1.3 m."""
    _rock(kit, (0.9, 0.75, 0.7), 20, 0.22, 0.35, m=trs((-0.2, 0.05, 0), (0, 0, 15)), shade_h=0.7)
    _rock(kit, (0.6, 0.5, 0.45), 16, 0.22, 0.0, m=trs((0.45, -0.2, 0), (0, 0, 60)), shade_h=0.7)
    _rock(kit, (0.4, 0.35, 0.3), 14, 0.2, 0.0, m=trs((0.3, 0.38, 0), (0, 0, 20)), shade_h=0.7)


@prop("rock_e", "rock", ["roadside", "forest", "slope", "field"], BOTH, cyl(0.85))
def rock_e(kit: Kit) -> None:
    """Wide mossy stone ~2 m."""
    _rock(kit, (2.1, 1.6, 1.15), 44, 0.2, 0.45)


@prop("boulder", "rock", ["roadside", "forest", "slope", "field", "water_edge"], BOTH, cyl(1.5))
def boulder(kit: Kit) -> None:
    _rock(kit, (3.8, 3.1, 2.9), 60, 0.18, 0.3, embed=0.1)
    _rock(kit, (1.2, 1.0, 0.8), 16, 0.2, 0.2, m=trs((1.9, -0.9, 0), (0, 0, 30)), shade_h=2.9)


def strata_points(r: random.Random, size: tuple[float, float, float], rings: int, per_ring: int) -> list[Vector]:
    """Stacked jittered rings: near-vertical walls with ledges, flat-ish top (reads as cliff)."""
    pts = []
    for k in range(rings):
        f = k / (rings - 1)
        z = size[2] * f
        shrink = 1.0 - 0.5 * f ** 1.6
        for i in range(per_ring):
            a = 2 * math.pi * (i + r.uniform(-0.3, 0.3)) / per_ring
            j = r.uniform(0.82, 1.08)
            pts.append(Vector((math.cos(a) * size[0] / 2 * shrink * j,
                               math.sin(a) * size[1] / 2 * shrink * j,
                               z + r.uniform(-0.06, 0.06) * size[2])))
    return pts


def _cliff(kit: Kit, chunks: list[tuple[tuple[float, float, float], tuple[float, float, float], float]]) -> None:
    """Chunks are strata columns (loc = base centre, size, yaw). Base sits 1.5 m below ground."""
    h = max(loc[2] + s[2] for loc, s, _ in chunks)
    shade = grad_z(-1.5, h, ROCK_SHADE)
    for i, (loc, size, yaw) in enumerate(chunks):
        pts = strata_points(kit.r, size, 4, 6)
        body = "Rock_Dark" if i % 3 == 2 else "Rock"
        top_z = loc[2] + size[2] * 0.7

        def matfn(c: Vector, nrm: Vector, body=body, top_z=top_z) -> str:
            return "Moss" if (nrm.z > 0.8 and c.z > top_z) else body
        kit.add(bm_hull(pts), matfn,
                trs(loc, (kit.r.uniform(-4, 4), kit.r.uniform(-4, 4), yaw)), shade)


@prop("cliff_a", "rock", ["slope"], BOTH, box())
def cliff_a(kit: Kit) -> None:
    """Tall rocky mass ~12 x 8 m, ~10 m above ground; 1.5 m base below ground for embedding."""
    _cliff(kit, [
        ((0.0, 0.0, -1.5), (8.0, 7.0, 11.5), 0),
        ((-3.8, 0.6, -1.5), (6.5, 6.0, 8.5), 14),
        ((3.8, -0.3, -1.5), (6.2, 6.0, 9.5), -12),
        ((-5.2, -1.2, -1.5), (4.2, 4.4, 5.2), 40),
        ((5.2, -1.0, -1.5), (4.0, 4.2, 5.8), -30),
        ((0.6, -2.4, -1.5), (5.0, 3.6, 4.6), 20),
    ])


@prop("cliff_b", "rock", ["slope"], BOTH, box())
def cliff_b(kit: Kit) -> None:
    """Long lower rock band ~15 x 7 m, ~7 m above ground; 1.5 m base below ground."""
    _cliff(kit, [
        ((-4.2, 0.0, -1.5), (7.0, 6.2, 8.0), 5),
        ((1.2, 0.3, -1.5), (7.2, 6.4, 9.0), -8),
        ((5.8, -0.2, -1.5), (6.0, 5.6, 6.8), 18),
        ((-7.2, -0.8, -1.5), (4.0, 4.2, 4.6), 50),
        ((-1.6, -2.4, -1.5), (5.4, 3.4, 4.2), 12),
        ((4.2, -2.3, -1.5), (4.6, 3.2, 3.6), -15),
    ])
