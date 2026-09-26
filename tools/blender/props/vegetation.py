"""Vegetation: sakura, maple, cedar, pine, bamboo, bushes, ground cover, persimmon, deadwood."""
from __future__ import annotations

import math
import random

from mathutils import Vector

from .common import (Kit, bm_cyl, bm_ico, bm_poly, bm_tube, canopy_shade, displace_radial,
                     grad_z, jitter, lerp_col, mul_col, trs)
from .registry import AUTUMN, BOTH, NONE, SPRING, cyl, prop

BARK_SHADE = (0.72, 0.68, 0.80)


def dir_of(az_deg: float, el_deg: float) -> Vector:
    az, el = math.radians(az_deg), math.radians(el_deg)
    return Vector((math.cos(el) * math.cos(az), math.cos(el) * math.sin(az), math.sin(el)))


def branch_pts(r: random.Random, start: Vector, direction: Vector, length: float, segs: int,
               wobble: float = 0.18, lift: float = 0.0) -> list[Vector]:
    pts = [start.copy()]
    d = direction.normalized()
    p = start.copy()
    step = length / segs
    for _ in range(segs):
        d = (d + Vector((r.uniform(-wobble, wobble), r.uniform(-wobble, wobble),
                         lift + r.uniform(-wobble, wobble) * 0.5))).normalized()
        p = p + d * step
        pts.append(p.copy())
    return pts


def taper(n: int, r0: float, r1: float, flare: float = 0.0) -> list[float]:
    out = [r0 + (r1 - r0) * (i / (n - 1)) for i in range(n)]
    if flare > 0:
        out[0] *= 1.0 + flare
    return out


def bark_color(h: float):
    return grad_z(0.0, h, BARK_SHADE)


class Canopy:
    """Collects cluster blobs, then emits them with one shared canopy gradient."""

    def __init__(self) -> None:
        self.items: list[tuple] = []

    def add(self, mat: str, center, radius: float, scale=(1.2, 1.2, 0.85), **kw) -> None:
        self.items.append((mat, Vector(center), radius, scale, kw))

    def emit(self, kit: Kit, cool=(0.80, 0.78, 0.93), tint_jitter: float = 0.05) -> None:
        z0 = min(c.z - rad * s[2] for _, c, rad, s, _ in self.items)
        z1 = max(c.z + rad * s[2] for _, c, rad, s, _ in self.items)
        shade = canopy_shade(z0, z1, cool)
        for mat, c, rad, s, kw in self.items:
            t = 1.0 - kit.r.uniform(0.0, tint_jitter)
            kit.blob(mat, c, rad, s, color=mul_col(shade, (t, t, t)), **kw)


# ----------------------------------------------------------------------------------------
# Sakura
# ----------------------------------------------------------------------------------------
PINKS = ("Blossom", "Blossom_Pale", "Blossom", "Blossom_Pale", "Blossom_Deep")


def _sakura(kit: Kit, trunk_h: float, lean: Vector, branches: list[tuple[float, float, float]],
            sub: bool, top: list[tuple[float, float, float, float]], blob_r: float,
            droop: float = 0.0, trunk_r: float = 0.22) -> None:
    r = kit.r
    canopy = Canopy()
    trunk = branch_pts(r, Vector((0, 0, 0)), Vector((0, 0, 1)) + lean, trunk_h, 4, wobble=0.08)
    kit.tube("Bark_Sakura", trunk, taper(len(trunk), trunk_r, trunk_r * 0.7, flare=0.45), 6,
             color=bark_color(trunk_h + 2))
    fork = trunk[-1]
    tips: list[tuple[Vector, float]] = []
    for i, (az, el, ln) in enumerate(branches):
        pts = branch_pts(r, fork - Vector((0, 0, 0.15)), dir_of(az, el), ln, 3, wobble=0.16)
        kit.tube("Bark_Sakura", pts, taper(len(pts), trunk_r * 0.62, trunk_r * 0.22), 5,
                 color=bark_color(trunk_h + 3))
        tips.append((pts[-1], 1.0))
        if sub:
            mid = pts[2]
            sd = dir_of(az + r.choice((-1, 1)) * r.uniform(35, 55), el + 15)
            spts = branch_pts(r, mid, sd, ln * 0.5, 2, wobble=0.15)
            kit.tube("Bark_Sakura", spts, taper(len(spts), trunk_r * 0.3, trunk_r * 0.12), 5,
                     color=bark_color(trunk_h + 3))
            tips.append((spts[-1], 0.8))
    for i, (tip, sc) in enumerate(tips):
        mat = PINKS[i % len(PINKS)]
        rad = blob_r * sc * r.uniform(0.9, 1.1)
        c = tip + Vector((0, 0, rad * 0.25 - droop * rad))
        canopy.add(mat, c, rad, (1.25, 1.25, 0.82 + droop * 0.6))
        if droop > 0:
            # weeping curtain: a hanging, elongated cluster below the tip
            canopy.add(PINKS[(i + 1) % len(PINKS)], tip + Vector((r.uniform(-.2, .2), r.uniform(-.2, .2), -rad * 1.35)),
                       rad * 0.7, (0.85, 0.85, 1.65))
    for i, (x, y, z, rad) in enumerate(top):
        canopy.add(PINKS[(i + 1) % len(PINKS)], (x, y, z), rad, (1.25, 1.2, 0.8))
    # small faceted accent puffs around the rim break up the silhouette
    for i, (tip, sc) in enumerate(tips[::2]):
        out = Vector((tip.x, tip.y, 0)).normalized()
        canopy.add(PINKS[(i + 3) % len(PINKS)], tip + out * blob_r * 0.8 + Vector((0, 0, -blob_r * 0.3)),
                   blob_r * 0.42, (1.1, 1.1, 0.9), subdiv=1, jit=0.02)
    canopy.emit(kit, cool=(0.94, 0.82, 0.88))


@prop("sakura_a", "tree", ["roadside", "forest", "village", "slope"], SPRING, cyl(0.26))
def sakura_a(kit: Kit) -> None:
    """Classic wide umbrella cherry."""
    _sakura(kit, 1.8, Vector((0.05, 0.02, 0)),
            [(10, 38, 2.5), (100, 44, 2.3), (195, 36, 2.6), (280, 48, 2.2)],
            sub=True, top=[(0.1, 0.0, 4.3, 1.35), (-0.6, 0.5, 3.6, 1.0)], blob_r=1.05)


@prop("sakura_b", "tree", ["roadside", "forest", "village", "slope"], SPRING, cyl(0.24))
def sakura_b(kit: Kit) -> None:
    """Tall upright oval cherry."""
    _sakura(kit, 2.6, Vector((-0.04, 0.03, 0)),
            [(30, 62, 2.6), (150, 66, 2.9), (260, 60, 2.4)],
            sub=True, top=[(0.0, 0.1, 6.0, 1.25), (0.3, -0.2, 5.0, 1.1), (-0.4, 0.3, 4.2, 1.0)],
            blob_r=0.95, trunk_r=0.2)


@prop("sakura_c", "tree", ["roadside", "village", "water_edge"], SPRING, cyl(0.28))
def sakura_c(kit: Kit) -> None:
    """Weeping (shidare) cherry: leaning trunk, hanging curtains of blossom."""
    _sakura(kit, 2.2, Vector((0.22, 0.0, 0)),
            [(0, 25, 2.4), (90, 30, 2.0), (170, 22, 2.2), (250, 28, 2.1), (330, 34, 1.8)],
            sub=False, top=[(0.5, 0.0, 4.0, 1.15)], blob_r=0.9, droop=0.35, trunk_r=0.25)


# ----------------------------------------------------------------------------------------
# Maple
# ----------------------------------------------------------------------------------------
def _maple(kit: Kit, mats: tuple[str, str, str]) -> None:
    """Momiji: short trunk, spreading limbs, broad domed crown built from overlapping
    slightly flattened leaf masses (reads as a rounded umbrella, not a savanna tree)."""
    r = kit.r
    canopy = Canopy()
    trunk = branch_pts(r, Vector((0, 0, 0)), Vector((0.05, 0, 1)), 1.4, 3, wobble=0.07)
    kit.tube("Bark_Maple", trunk, taper(len(trunk), 0.19, 0.14, flare=0.4), 6, color=bark_color(5))
    fork = trunk[-1]
    n = 5
    az0 = r.uniform(0, 360)
    tips: list[Vector] = []
    for i in range(n):
        az = az0 + i * 360 / n + r.uniform(-15, 15)
        pts = branch_pts(r, fork - Vector((0, 0, 0.1)), dir_of(az, r.uniform(32, 45)), r.uniform(2.0, 2.4), 3,
                         wobble=0.12, lift=0.1)
        kit.tube("Bark_Maple", pts, taper(len(pts), 0.1, 0.035), 5, color=bark_color(5))
        tip = pts[-1]
        tips.append(tip)
        canopy.add(mats[i % 3], tip + Vector((0, 0, 0.25)), r.uniform(1.0, 1.12), (1.3, 1.25, 0.72),
                   lump=0.28, jit=0.06)
        mid = pts[2]
        canopy.add(mats[(i + 1) % 3], Vector((mid.x * 0.75, mid.y * 0.75, tip.z + 1.0)), r.uniform(0.9, 1.0),
                   (1.3, 1.25, 0.75), lump=0.28, jit=0.06)
    canopy.add(mats[0], (0.1, 0.0, fork.z + 3.2), 1.15, (1.35, 1.3, 0.8), lump=0.26, jit=0.06)
    for i, tip in enumerate(tips):  # ragged accent puffs overlapping each outer mass
        out = Vector((tip.x, tip.y, 0)).normalized()
        side = Vector((-out.y, out.x, 0)) * (0.5 if i % 2 else -0.5)
        canopy.add(mats[(i + 2) % 3], tip + out * 1.05 + side + Vector((0, 0, -0.1 + 0.3 * (i % 2))),
                   0.45, (1.2, 1.2, 0.8), subdiv=1, jit=0.03)
    canopy.emit(kit, cool=(0.8, 0.74, 0.9))


@prop("maple_red", "tree", ["roadside", "forest", "village", "slope", "water_edge"], AUTUMN, cyl(0.22))
def maple_red(kit: Kit) -> None:
    _maple(kit, ("Leaves_Maple_Red", "Leaves_Maple_Scarlet", "Leaves_Maple_Red"))


@prop("maple_orange", "tree", ["roadside", "forest", "village", "slope", "water_edge"], AUTUMN, cyl(0.22))
def maple_orange(kit: Kit) -> None:
    _maple(kit, ("Leaves_Maple_Orange", "Leaves_Maple_Scarlet", "Leaves_Maple_Amber"))


@prop("maple_yellow", "tree", ["roadside", "forest", "village", "slope", "water_edge"], AUTUMN, cyl(0.22))
def maple_yellow(kit: Kit) -> None:
    _maple(kit, ("Leaves_Maple_Amber", "Leaves_Maple_Gold", "Leaves_Maple_Orange"))


# ----------------------------------------------------------------------------------------
# Cedar (sugi): tall straight trunk, stacked jagged cone tiers
# ----------------------------------------------------------------------------------------
def _cedar(kit: Kit, height: float, tiers: int, base_r: float, lean: Vector, trunk_r: float) -> None:
    """Sugi: straight trunk, dense column of teardrop lumps tapering to a spire."""
    r = kit.r
    top = Vector((0, 0, height)) + lean * height
    trunk = [Vector((0, 0, 0)), Vector((0, 0, height * 0.3)) + lean * height * 0.3,
             Vector((0, 0, height * 0.7)) + lean * height * 0.7, top]
    kit.tube("Bark_Cedar", trunk, [trunk_r * 1.5, trunk_r, trunk_r * 0.6, 0.0], 6,
             color=bark_color(height * 0.4))
    z0 = height * 0.2
    shade = canopy_shade(z0 - 0.5, height, (0.74, 0.76, 0.92))
    for t in range(tiers):
        f = t / (tiers - 1)
        z = z0 + (height - z0 - 2.0) * (f ** 0.95)
        rad = base_r * (1.0 - 0.72 * f) * r.uniform(0.92, 1.06)
        c = Vector((0, 0, z)) + lean * z
        mat = "Needle_Cedar" if t % 2 == 0 else "Needle_Cedar_Top"
        kit.blob(mat, c + Vector((0, 0, rad * 0.6)), rad, (1.0, 1.0, 1.25), lump=0.26, jit=0.05,
                 pinch=0.35, color=shade)
        if f < 0.6:  # side lumps make the lower column irregular
            a = r.uniform(0, 2 * math.pi)
            off = Vector((math.cos(a), math.sin(a), 0)) * rad * 0.55
            kit.blob("Needle_Cedar_Top" if t % 2 == 0 else "Needle_Cedar", c + off + Vector((0, 0, rad * 0.3)),
                     rad * 0.7, (1.0, 1.0, 1.1), subdiv=1, lump=0.2, jit=0.04, pinch=0.3, color=shade)
    kit.cyl("Needle_Cedar_Top", base_r * 0.3, 2.2, top - Vector((0, 0, 2.0)), seg=6, r_top=0.0,
            color=shade)


@prop("cedar_a", "tree", ["forest", "slope", "roadside"], BOTH, cyl(0.3))
def cedar_a(kit: Kit) -> None:
    _cedar(kit, 12.5, 7, 1.9, Vector((0.0, 0.0, 0)), 0.3)


@prop("cedar_b", "tree", ["forest", "slope", "roadside"], BOTH, cyl(0.26))
def cedar_b(kit: Kit) -> None:
    _cedar(kit, 14.5, 8, 1.55, Vector((0.03, -0.015, 0)), 0.26)


# ----------------------------------------------------------------------------------------
# Japanese black pine (kuromatsu): twisted trunk, flat cloud pads
# ----------------------------------------------------------------------------------------
def _pine(kit: Kit, height: float, lean_az: float, lean: float, pads: list[tuple[float, float, float, float]]) -> None:
    r = kit.r
    ld = dir_of(lean_az, 0)
    trunk = [Vector((0, 0, 0))]
    n = 6
    for i in range(1, n + 1):
        f = i / n
        sway = math.sin(f * math.pi * 1.6) * 0.5
        off = ld * (lean * height * f * f + sway) + dir_of(lean_az + 90, 0) * math.sin(f * 5.0) * 0.25
        trunk.append(Vector((off.x, off.y, height * f)))
    kit.tube("Bark_Pine", trunk, taper(len(trunk), 0.26, 0.09, flare=0.35), 6,
             color=bark_color(height), twist=0.3)
    shade_z0 = height * 0.35
    shade = canopy_shade(shade_z0, height + 1.2, (0.72, 0.76, 0.92))
    for i, (tf, az, reach, size) in enumerate(pads):
        idx = min(len(trunk) - 1, max(1, round(tf * n)))
        base = trunk[idx]
        d = dir_of(az, r.uniform(8, 22))
        pts = branch_pts(r, base, d, reach, 2, wobble=0.12)
        if reach > 0.1:
            kit.tube("Bark_Pine", pts, [0.1, 0.07, 0.045], 5, color=bark_color(height))
        tip = pts[-1]
        kit.blob("Needle_Pine", tip + Vector((0, 0, 0.18)), size, (1.45, 1.25, 0.42),
                 lump=0.18, jit=0.05, color=shade, r=(r.uniform(-6, 6), r.uniform(-6, 6), r.uniform(0, 360)))
        if size > 0.8:
            kit.blob("Needle_Pine", tip + Vector((r.uniform(-.3, .3), r.uniform(-.3, .3), 0.42)), size * 0.62,
                     (1.35, 1.2, 0.45), lump=0.16, jit=0.04, color=shade)


@prop("pine_a", "tree", ["roadside", "village", "slope", "water_edge"], BOTH, cyl(0.25))
def pine_a(kit: Kit) -> None:
    _pine(kit, 6.2, 20, 0.22, [(1.0, 10, 0.2, 1.3), (0.8, 200, 1.6, 1.05), (0.65, 60, 1.9, 1.0),
                               (0.5, 290, 2.2, 0.95), (0.9, 130, 1.3, 0.9), (0.4, 170, 2.0, 0.8),
                               (0.7, 330, 1.2, 0.75)])


@prop("pine_b", "tree", ["roadside", "village", "slope", "water_edge"], BOTH, cyl(0.25))
def pine_b(kit: Kit) -> None:
    """Windswept cliff pine: strong lean, long reaching lower branch."""
    _pine(kit, 5.0, 230, 0.55, [(1.0, 230, 0.6, 1.1), (0.7, 250, 2.4, 1.05), (0.55, 30, 1.4, 0.8),
                                (0.85, 130, 1.5, 0.8), (0.35, 210, 3.0, 0.95)])


# ----------------------------------------------------------------------------------------
# Persimmon (kaki): sparse autumn crown with orange fruit
# ----------------------------------------------------------------------------------------
@prop("persimmon_tree", "tree", ["village", "field", "roadside"], AUTUMN, cyl(0.2))
def persimmon_tree(kit: Kit) -> None:
    r = kit.r
    canopy = Canopy()
    trunk = branch_pts(r, Vector((0, 0, 0)), Vector((0.1, 0, 1)), 1.6, 3, wobble=0.12)
    kit.tube("Bark", trunk, taper(len(trunk), 0.18, 0.13, flare=0.4), 6, color=bark_color(5))
    fork = trunk[-1]
    fruit_spots: list[Vector] = []
    for i in range(6):
        az = i * 60 + r.uniform(-20, 20)
        pts = branch_pts(r, fork, dir_of(az, r.uniform(30, 55)), r.uniform(1.8, 2.4), 3, wobble=0.25)
        kit.tube("Bark", pts, taper(len(pts), 0.09, 0.03), 5, color=bark_color(5))
        fruit_spots += [pts[2], pts[3]]
        if i % 2 == 0:
            canopy.add("Leaves_Persimmon" if i % 4 == 0 else "Leaves_Maple_Orange",
                       pts[3] + Vector((0, 0, 0.1)), r.uniform(0.6, 0.75), (1.3, 1.3, 0.7), lump=0.3, jit=0.08)
    canopy.add("Leaves_Persimmon", fork + Vector((0.2, 0.1, 2.0)), 0.8, (1.4, 1.3, 0.7), lump=0.3, jit=0.08)
    canopy.emit(kit, cool=(0.8, 0.74, 0.88))
    for i, p in enumerate(fruit_spots):
        for k in range(2 if i % 3 else 1):
            off = Vector((r.uniform(-0.3, 0.3), r.uniform(-0.3, 0.3), r.uniform(-0.35, -0.1)))
            bm = bm_ico(1, 0.1)
            kit.add(bm, "Fruit_Persimmon", trs(p + off, (0, 0, r.uniform(0, 90)), (1, 1, 0.85)),
                    grad_z(p.z - 0.5, p.z, (0.85, 0.78, 0.85)))


# ----------------------------------------------------------------------------------------
# Bamboo clump
# ----------------------------------------------------------------------------------------
@prop("bamboo_clump", "tree", ["forest", "roadside", "village", "slope"], BOTH, cyl(0.7))
def bamboo_clump(kit: Kit) -> None:
    r = kit.r
    n = 10
    shade = canopy_shade(3.0, 9.0, (0.74, 0.8, 0.9))
    for i in range(n):
        a = i * 2.4
        d = r.uniform(0.1, 0.7)
        base = Vector((math.cos(a) * d, math.sin(a) * d, 0))
        h = r.uniform(6.0, 8.8)
        out = Vector((math.cos(a), math.sin(a), 0)) * r.uniform(0.6, 1.6)
        pts = []
        segs = 6
        for s in range(segs + 1):
            f = s / segs
            pts.append(base + out * (f ** 2.2) + Vector((0, 0, h * f)))
        rad = r.uniform(0.05, 0.07)
        kit.tube("Foliage_Bamboo", pts, [rad * 1.1] + [rad] * (segs - 1) + [rad * 0.5], 4,
                 color=grad_z(0, h, (0.78, 0.82, 0.8)))
        for s in (1, 2):  # node rings
            kit.cyl("Foliage_Bamboo", rad * 1.4, 0.07, pts[s] - Vector((0, 0, 0.035)), seg=4,
                    cap_bot=False, cap_top=False, color=(0.82, 0.85, 0.78), phase=math.pi / 4)
        for s in range(4, segs + 1):  # drooping leaf sprays near the top
            p = pts[s]
            for k in range(3):
                ang = r.uniform(0, 2 * math.pi)
                dirv = Vector((math.cos(ang), math.sin(ang), 0))
                sp = p + dirv * r.uniform(0.3, 0.5) + Vector((0, 0, -0.15))
                _spray(kit, sp, ang, r.uniform(0.55, 0.8), shade)


def _spray(kit: Kit, center: Vector, yaw: float, size: float, color) -> None:
    """Elongated drooping octahedron leaf spray (8 tris)."""
    r = kit.r
    L, W, H = size, size * 0.45, size * 0.22
    verts = [(L, 0, -0.25 * L), (-L * 0.6, 0, 0.1 * L), (0, W, 0), (0, -W, 0), (0, 0, H), (0, 0, -H)]
    verts = [(x + r.uniform(-.05, .05), y + r.uniform(-.05, .05), z) for x, y, z in verts]
    faces = [(0, 2, 4), (2, 1, 4), (1, 3, 4), (3, 0, 4), (2, 0, 5), (1, 2, 5), (3, 1, 5), (0, 3, 5)]
    kit.poly("Leaves_Bamboo", verts, faces, trs(center, (0, 0, math.degrees(yaw))), color, recalc=True)


# ----------------------------------------------------------------------------------------
# Bushes
# ----------------------------------------------------------------------------------------
def _bush(kit: Kit, mats: tuple[str, ...], blobs: list[tuple[float, float, float, float]],
          flat: float = 0.8, cool=(0.76, 0.78, 0.92)) -> None:
    canopy = Canopy()
    for i, (x, y, z, rad) in enumerate(blobs):
        canopy.add(mats[i % len(mats)], (x, y, z), rad, (1.15, 1.1, flat), lump=0.24, jit=0.04)
    canopy.emit(kit, cool=cool)


@prop("bush_a", "vegetation", ["roadside", "forest", "village", "field", "slope"], BOTH, NONE, 1500)
def bush_a(kit: Kit) -> None:
    _bush(kit, ("Leaves", "Leaves_Spring"),
          [(0, 0, 0.45, 0.62), (0.55, 0.15, 0.35, 0.46), (-0.5, -0.1, 0.32, 0.5), (0.1, -0.45, 0.3, 0.42)])


@prop("bush_b", "vegetation", ["roadside", "village", "field"], BOTH, NONE, 1500)
def bush_b(kit: Kit) -> None:
    """Clipped round tamamono shrub pair."""
    _bush(kit, ("Leaves_Dark", "Leaves"),
          [(0, 0, 0.62, 0.72), (0.75, 0.2, 0.36, 0.44), (0.25, 0.4, 0.95, 0.4)], flat=0.78)


@prop("azalea", "vegetation", ["roadside", "village"], SPRING, NONE, 1500)
def azalea(kit: Kit) -> None:
    """Mounded tsutsuji: green base, magenta/pink bloom caps."""
    r = kit.r
    base = Canopy()
    for x, y, z, rad in [(0, 0, 0.35, 0.62), (0.7, 0.1, 0.3, 0.5), (-0.65, 0.05, 0.3, 0.52)]:
        base.add("Leaves", (x, y, z), rad, (1.2, 1.1, 0.72), lump=0.2)
    base.emit(kit)
    caps = Canopy()
    for i, (x, y, z, rad) in enumerate([(0.05, 0.02, 0.56, 0.56), (0.72, 0.08, 0.47, 0.44),
                                        (-0.64, 0.1, 0.46, 0.46), (0.3, -0.3, 0.42, 0.36)]):
        caps.add("Blossom_Azalea" if i % 2 == 0 else "Blossom_Rose", (x, y, z), rad, (1.2, 1.1, 0.62),
                 lump=0.2)
    caps.emit(kit, cool=(0.86, 0.8, 0.92))
    for k in range(10):
        a = r.uniform(0, 2 * math.pi)
        d = r.uniform(0.3, 1.1)
        p = Vector((math.cos(a) * d * 1.1, math.sin(a) * d * 0.6, 0.25 + r.uniform(0, 0.15)))
        bm = bm_ico(1, 0.09)
        kit.add(bm, "Blossom_Azalea", trs(p, (0, 0, r.uniform(0, 90))), None)


# ----------------------------------------------------------------------------------------
# Ground cover (massive instancing)
# ----------------------------------------------------------------------------------------
def _blade(kit: Kit, mat: str, base: Vector, tip: Vector, w: float, color) -> None:
    """3-tri pyramid blade (no bottom), visible from every side."""
    d = (tip - base)
    side = d.cross(Vector((0, 0, 1)))
    if side.length < 1e-4:
        side = Vector((1, 0, 0))
    side.normalize()
    back = side.cross(d).normalized()
    a = base + side * w
    b = base - side * w
    c = base + back * w * 0.9
    kit.poly(mat, [a, b, c, tip], [(0, 3, 1), (1, 3, 2), (2, 3, 0)], None, color, recalc=True)


@prop("grass_tuft", "ground_cover", ["roadside", "field", "forest", "slope", "water_edge"], BOTH, NONE, 24)
def grass_tuft(kit: Kit) -> None:
    """8 three-sided blades fanning out (24 tris)."""
    r = kit.r
    col = grad_z(0.0, 0.42, (0.66, 0.72, 0.84))
    for i in range(8):
        a = i * 2 * math.pi / 8 + r.uniform(-0.3, 0.3)
        d = r.uniform(0.02, 0.08)
        base = Vector((math.cos(a) * d, math.sin(a) * d, -0.02))
        h = r.uniform(0.26, 0.42) * (1.0 if i % 2 else 0.8)
        lean = r.uniform(0.1, 0.2)
        tip = base + Vector((math.cos(a) * lean, math.sin(a) * lean, h))
        _blade(kit, "Grass", base, tip, 0.045, col)


@prop("flowers_patch", "ground_cover", ["roadside", "field", "slope"], BOTH, NONE, 40)
def flowers_patch(kit: Kit) -> None:
    """Leafy clump with 6 tiny low-pyramid blooms (white/yellow/pink/violet); 39 tris.
    Bloom colour comes from vertex colours on the white Blossom_Flower material."""
    r = kit.r
    leaf = grad_z(0.0, 0.22, (0.66, 0.72, 0.84))
    for i in range(5):
        a = i * 2 * math.pi / 5 + 0.3
        base = Vector((math.cos(a) * 0.04, math.sin(a) * 0.04, -0.02))
        tip = base + Vector((math.cos(a) * 0.16, math.sin(a) * 0.16, r.uniform(0.16, 0.22)))
        _blade(kit, "Grass", base, tip, 0.04, leaf)
    colors = [(1.0, 1.0, 1.0), (0.99, 0.86, 0.4), (0.98, 0.7, 0.8), (1.0, 1.0, 1.0), (0.78, 0.7, 0.98),
              (0.99, 0.86, 0.4)]
    for i in range(6):
        a = i * 2 * math.pi / 6 + 0.9
        d = 0.06 + 0.07 * (i % 2)
        top = Vector((math.cos(a) * d, math.sin(a) * d, 0.12 + 0.05 * ((i * 5) % 3) / 2))
        rad = 0.045
        verts = [(top.x + math.cos(k * math.pi / 2 + a) * rad, top.y + math.sin(k * math.pi / 2 + a) * rad, top.z)
                 for k in range(4)] + [(top.x, top.y, top.z + 0.02)]
        kit.poly("Blossom_Flower", verts, [(0, 1, 4), (1, 2, 4), (2, 3, 4), (3, 0, 4)], None, (*colors[i], 1.0))


@prop("fern", "vegetation", ["forest", "slope", "water_edge", "roadside"], BOTH, NONE, 400)
def fern(kit: Kit) -> None:
    r = kit.r
    col = grad_z(0.0, 0.6, (0.7, 0.76, 0.86))
    for i in range(7):
        a = i * 2 * math.pi / 7 + r.uniform(-0.2, 0.2)
        d = Vector((math.cos(a), math.sin(a), 0))
        side = Vector((-d.y, d.x, 0))
        ln = r.uniform(0.75, 0.95)
        verts = []
        segs = 5
        for s in range(segs + 1):
            f = s / segs
            p = d * (ln * f) + Vector((0, 0, 0.55 * math.sin(f * math.pi * 0.85) + 0.02))
            w = 0.16 * math.sin(math.pi * min(1.0, f * 1.05 + 0.05)) + 0.01
            verts += [p + side * w - Vector((0, 0, 0.05 * f)), p + Vector((0, 0, 0.03)), p - side * w - Vector((0, 0, 0.05 * f))]
        faces = []
        for s in range(segs):
            o, q = s * 3, (s + 1) * 3
            faces += [(o, o + 1, q + 1, q), (o + 1, o + 2, q + 2, q + 1)]
        kit.poly("Leaves_Fern", verts, faces, None, col)
        kit.poly("Leaves_Fern", verts, [tuple(reversed(f)) for f in faces], None, col)


@prop("reeds", "vegetation", ["water_edge", "field"], BOTH, NONE, 400)
def reeds(kit: Kit) -> None:
    r = kit.r
    col = grad_z(0.0, 1.7, (0.7, 0.74, 0.8))
    for i in range(16):
        a = r.uniform(0, 2 * math.pi)
        d = r.uniform(0.0, 0.35)
        base = Vector((math.cos(a) * d, math.sin(a) * d, -0.03))
        h = r.uniform(1.0, 1.75)
        lean = r.uniform(0.1, 0.4)
        tip = base + Vector((math.cos(a) * lean, math.sin(a) * lean, h))
        _blade(kit, "Grass_Reed", base, tip, 0.035, col)
    for i in range(4):
        a = i * 1.7
        base = Vector((math.cos(a) * 0.15, math.sin(a) * 0.15, 0))
        top = base + Vector((math.cos(a) * 0.12, math.sin(a) * 0.12, 1.55 + 0.1 * i))
        _blade(kit, "Grass_Reed", base, top, 0.015, col)
        dirv = (top - base).normalized()
        head0 = top - dirv * 0.32
        kit.add(bm_tube([head0, head0 + dirv * 0.05, top - dirv * 0.03, top], [0.02, 0.045, 0.04, 0.0], 5),
                "Grass_Cattail", None, (0.95, 0.95, 0.95))


# ----------------------------------------------------------------------------------------
# Deadwood
# ----------------------------------------------------------------------------------------
@prop("stump", "vegetation", ["forest", "roadside", "slope"], BOTH, cyl(0.38), 300)
def stump(kit: Kit) -> None:
    r = kit.r
    seg = 9
    h = 0.55
    bm = bm_cyl(0.4, 0.32, h, seg, cap_bot=False, cap_top=False)
    jitter(bm, r, 0.03)
    kit.add(bm, "Bark", None, grad_z(0, h, BARK_SHADE))
    top = [(math.cos(2 * math.pi * i / seg) * 0.32, math.sin(2 * math.pi * i / seg) * 0.32, h + r.uniform(-0.04, 0.03))
           for i in range(seg)]
    kit.poly("Wood_Cut", top, [tuple(range(seg))], None, None)
    kit.cyl("Bark", 0.12, 0.02, (0.02, -0.03, h - 0.005), seg=6, color=(0.8, 0.75, 0.8))
    for i in range(4):
        a = i * math.pi / 2 + 0.5
        d = Vector((math.cos(a), math.sin(a), 0))
        kit.poly("Bark", [d * 0.3 + Vector((0, 0, 0.3)), d * 0.62 + Vector((0, 0, -0.02)),
                          d * 0.28 + d.cross(Vector((0, 0, 1))) * 0.14, d * 0.28 - d.cross(Vector((0, 0, 1))) * 0.14],
                 [(0, 2, 1), (0, 1, 3), (0, 3, 2)], None, grad_z(0, 0.3, BARK_SHADE), recalc=True)
    kit.blob("Moss", (0.15, 0.1, h - 0.02), 0.18, (1.2, 1.0, 0.35), subdiv=1, lump=0.2)


@prop("log", "vegetation", ["forest", "roadside", "slope", "water_edge"], BOTH, {"type": "box"}, 300)
def log(kit: Kit) -> None:
    r = kit.r
    seg = 8
    ln = 3.2
    rad = 0.24
    bm = bm_cyl(rad, rad * 0.88, ln, seg, cap_bot=False, cap_top=False, phase=0.2)
    jitter(bm, r, 0.02)
    m = trs((-ln / 2, 0, rad * 0.92), (0, 90, 0))
    kit.add(bm, "Bark", m, lambda co, n: lerp_col(BARK_SHADE, (1, 1, 1, 1), n.z * 0.5 + 0.5))
    for x, rr, sgn in ((-ln / 2, rad, -1), (ln / 2, rad * 0.88, 1)):
        ring = [(x, math.cos(2 * math.pi * i / seg + 0.2) * rr, rad * 0.92 + math.sin(2 * math.pi * i / seg + 0.2) * rr)
                for i in range(seg)]
        f = tuple(range(seg)) if sgn > 0 else tuple(reversed(range(seg)))
        kit.poly("Wood_Cut", ring, [f], None, None)
    kit.blob("Moss", (0.3, 0.02, rad * 1.8), 0.3, (2.2, 0.9, 0.35), lump=0.2)
    # broken-off branch stub
    kit.cyl_between("Bark", (0.6, 0.0, rad * 1.5), (0.85, -0.25, rad * 2.3), 0.06, seg=5, r_top=0.035)


# ----------------------------------------------------------------------------------------
# Extra tree variants (P2)
# ----------------------------------------------------------------------------------------
@prop("sakura_young", "tree", ["roadside", "village", "field"], SPRING, cyl(0.12))
def sakura_young(kit: Kit) -> None:
    """Young roadside cherry (~3.6 m) for planted avenues."""
    _sakura(kit, 1.4, Vector((0.0, 0.03, 0)), [(20, 55, 1.4), (140, 58, 1.3), (260, 52, 1.4)],
            sub=False, top=[(0.0, 0.0, 3.1, 0.8)], blob_r=0.68, trunk_r=0.1)


@prop("maple_green", "tree", ["roadside", "forest", "village", "slope", "water_edge"], SPRING, cyl(0.22))
def maple_green(kit: Kit) -> None:
    """Fresh spring-green maple (same form as the autumn maples) for the Hanami map."""
    _maple(kit, ("Leaves_Spring", "Leaves_Fresh", "Leaves"))


@prop("ginkgo", "tree", ["village", "roadside", "forest"], AUTUMN, cyl(0.24))
def ginkgo(kit: Kit) -> None:
    """Golden ginkgo (icho): straight trunk, tall conical-oval crown of stacked lumps."""
    r = kit.r
    h = 9.0
    trunk = branch_pts(r, Vector((0, 0, 0)), Vector((0, 0, 1)), h * 0.85, 4, wobble=0.03)
    kit.tube("Bark", trunk, taper(len(trunk), 0.24, 0.07, flare=0.35), 6, color=bark_color(h))
    canopy = Canopy()
    tiers = [(2.4, 1.55), (3.6, 1.7), (4.9, 1.5), (6.1, 1.2), (7.2, 0.9), (8.2, 0.6)]
    for i, (z, rad) in enumerate(tiers):
        canopy.add("Leaves_Ginkgo" if i % 2 == 0 else "Leaves_Maple_Gold", (0, 0, z), rad, (1.15, 1.15, 0.85),
                   lump=0.24, jit=0.05)
        if rad > 1.0:
            a = r.uniform(0, 2 * math.pi)
            for k in range(2):
                aa = a + k * math.pi
                canopy.add("Leaves_Maple_Amber" if k else "Leaves_Ginkgo",
                           (math.cos(aa) * rad * 0.9, math.sin(aa) * rad * 0.9, z - 0.3), rad * 0.45,
                           (1.1, 1.1, 0.85), subdiv=1, jit=0.03)
    canopy.emit(kit, cool=(0.82, 0.76, 0.88))
