"""Japanese countryside: shrines, houses, fences, roadside furniture, farm props, kei truck."""
from __future__ import annotations

import math

from mathutils import Vector

from .arch import gable_roof, hip_roof, irimoya_roof, panel, shoji, steps, timber_walls
from .common import (Kit, bm_ico, chamfer_box_points, grad_z, lerp_col, trs,
                     underside)
from .registry import AUTUMN, BOTH, NONE, box, cyl, prop

SOFT = underside()
STONE_SHADE = grad_z(0.0, 2.0, (0.8, 0.78, 0.9))


# ----------------------------------------------------------------------------------------
# Torii
# ----------------------------------------------------------------------------------------
def _torii(kit: Kit, H: float, span: float, pr: float) -> None:
    lean = math.degrees(math.atan2(H * 0.03, H))
    for sx in (-1, 1):
        x = sx * span / 2
        kit.cyl("Vermilion", pr, H * 0.9, (x, 0, 0), (0, sx * lean, 0), seg=8, r_top=pr * 0.86,
                color=grad_z(0, H, (0.86, 0.84, 0.92)))
        kit.cyl("Ink", pr * 1.28, H * 0.075, (x, 0, 0), seg=8, r_top=pr * 1.18)
        kit.cyl("Stone", pr * 1.6, 0.06, (x, 0, -0.02), seg=8, r_top=pr * 1.45)
    # nuki (tie beam) passes through pillars
    kit.cbox("Vermilion", (span + pr * 5.5, pr * 1.1, pr * 1.2), (0, 0, H * 0.7), color=SOFT)
    # shimaki (lower lintel)
    kit.cbox("Vermilion", (span + pr * 4.6, pr * 1.4, pr * 1.1), (0, 0, H * 0.885), color=SOFT)
    # gakuzuka strut + plaque
    kit.cbox("Vermilion", (pr * 0.9, pr * 0.9, H * 0.16), (0, 0, H * 0.79))
    kit.cbox("Ink", (pr * 2.6, pr * 0.5, H * 0.13), (0, pr * 0.3, H * 0.795))
    kit.cbox("Gold", (pr * 2.1, pr * 0.52, H * 0.095), (0, pr * 0.32, H * 0.795))
    # kasagi (black top lintel) with upswept ends
    half = span / 2 + pr * 3.6
    xs = [half * (i / 8 * 2 - 1) for i in range(9)]
    th = pr * 1.25
    dd = pr * 1.7
    prof = [(-dd / 2, 0), (dd / 2, 0), (dd / 2 * 1.08, th), (-dd / 2 * 1.08, th)]
    z0 = H * 0.92
    kit.extrude_x("Ink", prof, xs, lambda x: z0 + pr * 1.3 * (abs(x) / half) ** 3.5, SOFT)
    kit.extrude_x("Vermilion", [(-dd * 0.45, -pr * 0.55), (dd * 0.45, -pr * 0.55), (dd * 0.45, 0.01),
                                (-dd * 0.45, 0.01)], xs, lambda x: z0 + pr * 1.3 * (abs(x) / half) ** 3.5, SOFT)


@prop("torii_small", "village", ["roadside", "forest", "village", "slope"], BOTH,
      {"type": "box", "size": [2.1, 2.6, 0.3], "center": [0, 1.3, 0]})
def torii_small(kit: Kit) -> None:
    """Small roadside/approach torii, 2.6 m, 1.6 m between pillars."""
    _torii(kit, 2.6, 1.6, 0.085)


@prop("torii_large", "village", ["roadside", "village", "slope"], BOTH,
      {"type": "box", "size": [5.2, 6.2, 0.6], "center": [0, 3.1, 0]})
def torii_large(kit: Kit) -> None:
    """Large shrine torii, 6.2 m tall, 4.4 m between pillars (a car passes under)."""
    _torii(kit, 6.2, 4.4, 0.21)


# ----------------------------------------------------------------------------------------
# Stone lantern, jizo, hokora
# ----------------------------------------------------------------------------------------
@prop("stone_lantern", "village", ["roadside", "village"], BOTH, cyl(0.35))
def stone_lantern(kit: Kit) -> None:
    """Kasuga-doro, ~2.1 m."""
    sh = STONE_SHADE
    kit.cyl("Stone", 0.42, 0.1, (0, 0, 0), seg=6, color=sh)
    kit.cyl("Stone", 0.34, 0.14, (0, 0, 0.1), seg=6, r_top=0.26, color=sh)
    kit.cyl("Stone", 0.12, 0.72, (0, 0, 0.24), seg=8, color=sh)
    kit.cyl("Stone", 0.15, 0.06, (0, 0, 0.56), seg=8, color=sh)
    kit.cyl("Stone", 0.18, 0.16, (0, 0, 0.96), seg=6, r_top=0.34, color=sh)
    # firebox: stone corner posts around a glowing paper core
    kit.cyl("Lantern_Paper", 0.2, 0.34, (0, 0, 1.12), seg=6, phase=math.pi / 6)
    for k in range(6):
        a = k * math.pi / 3
        kit.cbox("Stone", (0.08, 0.08, 0.34), (math.cos(a) * 0.23, math.sin(a) * 0.23, 1.29), (0, 0, math.degrees(a)),
                 color=sh)
    kit.cyl("Stone", 0.26, 0.05, (0, 0, 1.46), seg=6, color=sh)
    # kasa (roof) with curled corner tips, moss on top
    kit.cyl(lambda c, n: "Moss" if n.z > 0.5 and c.z > 1.62 else "Stone", 0.52, 0.26, (0, 0, 1.5), seg=6,
            r_top=0.1, color=sh)
    for k in range(6):
        a = k * math.pi / 3
        kit.cyl("Stone", 0.05, 0.1, (math.cos(a) * 0.5, math.sin(a) * 0.5, 1.5), seg=4, r_top=0.0, color=sh)
    kit.cyl("Stone", 0.08, 0.1, (0, 0, 1.76), seg=6, color=sh)
    kit.add(bm_ico(1, 0.1), "Stone", trs((0, 0, 1.92), (0, 0, 0), (1, 1, 1.3)), sh)
    kit.cyl("Stone", 0.02, 0.1, (0, 0, 1.99), seg=4, r_top=0.0, color=sh)


@prop("jizo", "village", ["roadside", "village", "forest"], BOTH, cyl(0.25), 600)
def jizo(kit: Kit) -> None:
    """Small stone jizo with red bib and cap, on a plinth (~0.95 m)."""
    sh = STONE_SHADE
    kit.cyl("Stone_Dark", 0.26, 0.18, (0, 0, 0), seg=8, color=sh)
    kit.cyl("Stone", 0.2, 0.06, (0, 0, 0.18), seg=8, color=sh)
    body = [Vector((0, 0, z)) for z in (0.24, 0.3, 0.45, 0.6, 0.7, 0.74)]
    kit.tube("Stone", body, [0.15, 0.17, 0.17, 0.15, 0.11, 0.0], 8, cap_start=True, color=sh)
    kit.add(bm_ico(2, 0.13), "Stone", trs((0, 0.0, 0.84), (0, 0, 0), (1, 0.95, 1.05)), sh)
    kit.add(bm_ico(1, 0.05), "Stone", trs((0, 0.16, 0.48)), sh)  # hands together
    # bib: flared apron hugging the chest
    bib = [(-0.1, 0.1, 0.7), (0.1, 0.1, 0.7), (0.15, 0.13, 0.56), (0.0, 0.18, 0.5), (-0.15, 0.13, 0.56)]
    kit.hull("Cloth_Red", bib + [(x, y + 0.03, z) for x, y, z in bib], None, SOFT)
    # knit cap
    kit.cyl("Cloth_Red", 0.135, 0.12, (0, -0.005, 0.89), seg=8, r_top=0.06)
    kit.add(bm_ico(1, 0.035), "Cloth_Red", trs((0, 0, 1.02)))


@prop("hokora", "village", ["roadside", "forest", "village"], BOTH, box(), 1200)
def hokora(kit: Kit) -> None:
    """Tiny roadside shrine on a stone plinth (~1.5 m)."""
    kit.box("Stone", (0.9, 0.8, 0.28), (0, 0, 0), color=STONE_SHADE)
    kit.box("Stone", (0.72, 0.64, 0.3), (0, 0, 0.28), color=STONE_SHADE)
    kit.box("Wood", (0.56, 0.48, 0.5), (0, 0, 0.58))
    kit.box("Wood_Dark", (0.62, 0.54, 0.05), (0, 0, 0.58))
    # lattice doors
    panel(kit, "Wood_Dark", "front", 0.56, 0.48, 0, 0.83, 0.42, 0.4, 0.03)
    panel(kit, "Gold", "front", 0.56, 0.48, 0, 0.83, 0.3, 0.3, 0.035)
    panel(kit, "Wood_Dark", "front", 0.56, 0.48, 0, 0.83, 0.03, 0.4, 0.05)
    gable_roof(kit, "Roof_Copper", 0.56, 0.48, 1.08, 0.24, 0.12, 0.2, 0.05, "Wood", "Roof_Ridge",
               ridge=(0.08, 0.06))
    # chigi (crossed finials) at gable ends
    for sx in (-1, 1):
        for sy in (-1, 1):
            kit.box_between("Wood_Dark", (sx * 0.38, 0, 1.3), (sx * 0.4, sy * 0.13, 1.47), 0.03, 0.025)
    # offerings: tiny sake cup + red cloth
    kit.cyl("White", 0.03, 0.05, (0.2, 0.34, 0.58), seg=6)
    kit.box("Cloth_Red", (0.3, 0.06, 0.12), (0, 0.27, 0.52))


# ----------------------------------------------------------------------------------------
# Shrine hall
# ----------------------------------------------------------------------------------------
@prop("shrine", "building", ["village", "forest", "slope"], BOTH, box())
def shrine(kit: Kit) -> None:
    """Small shinto haiden: stone base, vermilion frame, white walls, green copper irimoya roof."""
    W, D = 5.6, 4.6
    kit.box("Stone", (W + 1.6, D + 1.6, 0.35), (0, 0, 0), color=STONE_SHADE)
    kit.box("Wood_Dark", (W + 0.9, D + 0.9, 0.12), (0, 0, 0.85))  # engawa deck
    for sx in (-1, 1):
        for sy in (-1, 1):
            kit.box("Wood_Dark", (0.14, 0.14, 0.5), (sx * (W / 2 + 0.35), sy * (D / 2 + 0.35), 0.35))
    kit.box("Stone", (W - 0.2, D - 0.2, 0.5), (0, 0, 0.35), color=STONE_SHADE)
    z0 = 0.97
    H = 2.8
    kit.box("Plaster", (W, D, H), (0, 0, z0))
    # vermilion frame: pillars, head beam, sill
    for i in range(5):
        x = -W / 2 + W * i / 4
        for y in (-D / 2, D / 2):
            kit.cyl("Vermilion", 0.13, H, (x, y, z0), seg=8)
    for j in (1, 2):
        for x in (-W / 2, W / 2):
            kit.cyl("Vermilion", 0.13, H, (x, -D / 2 + D * j / 3, z0), seg=8)
    kit.box("Vermilion", (W + 0.12, D + 0.12, 0.22), (0, 0, z0 + H - 0.5))
    kit.box("Vermilion", (W + 0.08, D + 0.08, 0.14), (0, 0, z0))
    kit.box("Wood_Dark", (W + 0.3, D + 0.3, 0.28), (0, 0, z0 + H - 0.08))  # bracket band
    # front: three bays of lattice doors
    for off in (-1.4, 0.0, 1.4):
        panel(kit, "Wood_Dark", "front", W, D, off, z0 + 1.05, 1.2, 2.0, 0.06)
        panel(kit, "Gold" if off == 0 else "Shoji", "front", W, D, off, z0 + 1.15, 0.95, 1.6, 0.08)
        panel(kit, "Wood_Dark", "front", W, D, off, z0 + 1.15, 0.05, 1.6, 0.1)
    for side in ("left", "right"):
        shoji(kit, side, W, D, 0.0, z0 + 1.5, 1.4, 1.0)
    irimoya_roof(kit, "Roof_Copper", "Vermilion", W + 0.6, D + 0.6, z0 + H + 0.1, 2.0, 1.1, 0.32,
                 upper=0.5)
    # front steps + small entry roof posts
    steps(kit, "Wood", 3, 1.8, 0.32, 0.32, D / 2 + 0.45, 0, 0.0)
    # saisen-bako (offering box)
    kit.box("Wood_Dark", (0.9, 0.5, 0.55), (0, D / 2 + 0.2, 0.97))
    kit.box("Wood", (0.95, 0.55, 0.06), (0, D / 2 + 0.2, 1.5))
    # shimenawa rope with shide paper
    y = D / 2 + 0.28
    pts = [Vector((x, y, z0 + H - 0.62 - 0.22 * (1 - (x / 1.9) ** 2))) for x in (-1.9, -1.2, -0.5, 0.2, 0.9, 1.6, 1.9)]
    kit.tube("Rope", pts, [0.11, 0.14, 0.16, 0.16, 0.15, 0.13, 0.1], 6, cap_start=True)
    for x in (-1.1, 0.0, 1.1):
        z = z0 + H - 0.62 - 0.22 * (1 - (x / 1.9) ** 2) - 0.12
        for k in range(3):
            kit.cbox("Paper_White", (0.1, 0.02, 0.12), (x + (0.03 if k % 2 else -0.03), y + 0.05, z - 0.12 * k - 0.06))
    # bell + rope
    kit.add(bm_ico(1, 0.16), "Gold", trs((0.0, D / 2 + 0.36, z0 + H - 0.95), (0, 0, 0), (1, 1, 1.1)))
    kit.tube("Cloth_Red", [Vector((0.02, D / 2 + 0.38, z0 + H - 1.1)), Vector((0.06, D / 2 + 0.4, z0 + 0.6)),
                           Vector((0.1, D / 2 + 0.42, z0 + 0.25))], [0.05, 0.05, 0.03], 5)
    # stone guardian lantern pair bases
    for sx in (-1, 1):
        kit.cyl("Stone", 0.14, 0.9, (sx * (W / 2 + 0.55), D / 2 + 0.55, 0.35), seg=6, color=STONE_SHADE)
        kit.cyl("Lantern_Paper", 0.13, 0.2, (sx * (W / 2 + 0.55), D / 2 + 0.55, 1.25), seg=6)
        kit.cyl("Stone", 0.26, 0.16, (sx * (W / 2 + 0.55), D / 2 + 0.55, 1.45), seg=6, r_top=0.05, color=STONE_SHADE)


# ----------------------------------------------------------------------------------------
# Houses
# ----------------------------------------------------------------------------------------
@prop("farmhouse_a", "building", ["village", "field", "roadside"], BOTH, box())
def farmhouse_a(kit: Kit) -> None:
    """Tiled-roof farmhouse with side wing, engawa veranda and genkan porch."""
    W, D, H = 8.4, 6.0, 3.3
    kit.box("Stone_Dark", (W + 0.3, D + 0.3, 0.35), (0, 0, 0))
    timber_walls(kit, W, D, H, 0.35, 0.95)
    # veranda (engawa) along the front-left with sliding glass/shoji
    kit.box("Wood", (5.0, 1.0, 0.12), (-1.6, D / 2 + 0.5, 0.45))
    for x in (-4.0, -2.4, -0.8, 0.8):
        kit.box("Wood_Dark", (0.12, 0.12, 2.35), (x, D / 2 + 0.95, 0.55))
    for i, off in enumerate((-3.35, -2.0, -0.65)):
        shoji(kit, "front", W, D, off, 1.55, 1.2, 1.8, paper="Glass" if i == 1 else "Shoji")
    hip_roof(kit, "Roof_Tile", 5.6, 1.2, 2.95, 0.35, 0.25, 0.14, 2.6, None, -1.6, D / 2 + 0.55)
    # genkan: entry porch with gable
    panel(kit, "Wood_Dark", "front", W, D, 2.4, 1.4, 1.5, 2.1, 0.08)
    panel(kit, "Glass", "front", W, D, 2.4, 1.4, 1.3, 1.9, 0.1)
    panel(kit, "Wood_Dark", "front", W, D, 2.4, 1.4, 0.06, 1.9, 0.12)
    gable_roof(kit, "Roof_Tile", 1.9, 1.4, 2.75, 0.5, 0.2, 0.25, 0.12, None, "Roof_Ridge", 2.4, D / 2 + 0.55)
    kit.box("Stone", (1.8, 0.8, 0.22), (2.4, D / 2 + 0.4, 0.0))
    # windows on the sides / back
    shoji(kit, "right", W, D, 0.8, 1.9, 1.4, 1.0)
    shoji(kit, "left", W, D, -1.0, 1.9, 1.2, 1.0)
    shoji(kit, "back", W, D, 1.5, 1.9, 1.6, 1.0)
    shoji(kit, "back", W, D, -2.2, 2.0, 0.8, 0.8, paper="Glass")
    irimoya_roof(kit, "Roof_Tile", "Wood_Dark", W, D, 0.35 + H + 0.25, 2.3, 0.85, 0.3, upper=0.48)
    # side wing (lower, gable roof) at the back-right
    wx, wy = 3.4, -3.8
    kit.box("Stone_Dark", (3.6, 3.2, 0.35), (wx, wy, 0))
    timber_walls(kit, 3.4, 3.0, 2.6, 0.35, 0.8, cx=wx, cy=wy)
    shoji(kit, "right", 3.4, 3.0, 0.0, 1.8, 1.2, 0.9, cx=wx, cy=wy)
    gable_roof(kit, "Roof_Tile", 3.0, 3.4, 2.95, 1.2, 0.35, 0.45, 0.14, "Plaster", "Roof_Ridge", wx, wy)
    # chimney pipe
    kit.cyl("Metal_Dark", 0.1, 1.4, (-3.2, -1.8, 4.8), seg=6)


@prop("farmhouse_b", "building", ["village", "field", "forest"], BOTH, box())
def farmhouse_b(kit: Kit) -> None:
    """Thatched kominka: dark timber, tall kabuto thatch roof, veranda."""
    W, D, H = 9.0, 6.4, 2.9
    kit.box("Stone", (W + 0.4, D + 0.4, 0.4), (0, 0, 0), color=STONE_SHADE)
    timber_walls(kit, W, D, H, 0.4, 1.2, wall="Plaster", lower="Wood_Dark", bay=1.5)
    kit.box("Wood_Dark", (W - 1.0, 1.1, 0.14), (0.5, D / 2 + 0.55, 0.52))
    for x in (-3.9, -1.9, 0.1, 2.1, 4.1):
        kit.box("Wood_Dark", (0.14, 0.14, 2.6), (x, D / 2 + 1.0, 0.6))
    for off, paper in ((-3.0, "Shoji"), (-1.5, "Shoji"), (0.0, "Shoji"), (1.5, "Shoji")):
        shoji(kit, "front", W, D, off, 1.65, 1.3, 1.9, paper=paper)
    # doma entrance (dark opening with wood door frame)
    panel(kit, "Wood_Dark", "front", W, D, 3.4, 1.55, 1.7, 2.3, 0.08)
    panel(kit, "Wood", "front", W, D, 3.4, 1.5, 1.5, 2.1, 0.1)
    panel(kit, "Wood_Dark", "front", W, D, 3.4, 1.5, 0.06, 2.1, 0.12)
    hip_roof(kit, "Roof_Tile", W, 1.4, 3.15, 0.35, 0.3, 0.12, W / 2 - 0.4, None, 0.0, D / 2 + 0.7)
    shoji(kit, "left", W, D, 0.0, 1.9, 1.6, 1.0)
    shoji(kit, "right", W, D, -0.8, 1.9, 1.2, 1.0)
    shoji(kit, "back", W, D, 0.0, 1.9, 2.0, 1.0)
    # thick thatch kabuto roof
    ztop = irimoya_roof(kit, "Thatch", "Wood_Dark", W, D, 0.4 + H + 0.35, 4.6, 1.2, 0.75,
                        ridge_mat="Thatch_Dark", upper=0.42)
    # ridge crosses (grass-bundle ridge caps)
    for x in (-2.2, -1.1, 0.0, 1.1, 2.2):
        kit.box_between("Wood_Dark", (x, -0.45, ztop + 0.05), (x, 0.45, ztop + 0.05), 0.12, 0.1)


@prop("kura", "building", ["village", "field"], BOTH, box())
def kura(kit: Kit) -> None:
    """White storehouse: stone base, grey-tile lower band with lattice, heavy tile gable roof."""
    W, D, H = 4.2, 3.4, 4.8
    kit.box("Stone", (W + 0.5, D + 0.5, 0.5), (0, 0, 0), color=STONE_SHADE)
    kit.box("Plaster", (W, D, H), (0, 0, 0.5))
    kit.box("Roof_Tile", (W + 0.08, D + 0.08, 1.3), (0, 0, 0.5))
    # namako-kabe lattice (diagonal white strips) on the band
    for side, L in (("front", W), ("back", W), ("left", D), ("right", D)):
        n = int(L / 0.7)
        for i in range(n):
            off = -L / 2 + (i + 0.5) * L / n
            for rz in (45, -45):
                if side in ("front", "back"):
                    y = D / 2 + 0.05 if side == "front" else -D / 2 - 0.05
                    kit.cbox("Plaster", (0.62, 0.04, 0.06), (off, y, 1.15), (0, rz, 0))
                else:
                    x = W / 2 + 0.05 if side == "right" else -W / 2 - 0.05
                    kit.cbox("Plaster", (0.04, 0.62, 0.06), (x, off, 1.15), (rz, 0, 0))
    kit.box("Plaster", (W + 0.16, D + 0.16, 0.12), (0, 0, 1.78))
    kit.box("Plaster", (W + 0.18, D + 0.18, 0.16), (0, 0, 0.5 + H - 0.28))
    # heavy door
    panel(kit, "Plaster", "front", W, D, 0.0, 1.55, 1.5, 2.1, 0.22)
    panel(kit, "Wood_Dark", "front", W, D, 0.0, 1.45, 1.0, 1.8, 0.26)
    panel(kit, "Metal_Dark", "front", W, D, 0.0, 1.45, 0.06, 1.8, 0.3)
    # upper window with black shutters
    for side in ("front", "left"):
        panel(kit, "Plaster", side, W, D, 0.0 if side == "front" else 0.3, 4.05, 0.9, 0.8, 0.18)
        panel(kit, "Ink", side, W, D, 0.0 if side == "front" else 0.3, 4.05, 0.6, 0.55, 0.22)
    gable_roof(kit, "Roof_Tile", W, D, 0.5 + H, 1.6, 0.35, 0.55, 0.22, "Plaster", "Roof_Ridge")
    # onigawara at ridge ends + family crest on gables
    for sx in (-1, 1):
        kit.cbox("Roof_Ridge", (0.14, 0.42, 0.5), (sx * (W / 2 + 0.38), 0, 0.5 + H + 1.6 + 0.28))
        kit.cyl("Ink", 0.3, 0.06, (sx * (W / 2 + 0.01), 0, 0.5 + H + 0.62), (0, sx * 90, 0), seg=10)
        kit.cyl("Plaster", 0.2, 0.08, (sx * (W / 2 + 0.01), 0, 0.5 + H + 0.62), (0, sx * 90, 0), seg=10)


@prop("shed", "building", ["village", "field", "forest"], BOTH, box(), 1500)
def shed(kit: Kit) -> None:
    """Weathered plank shed with lean-to tin roof and firewood stack."""
    W, D = 3.2, 2.4
    kit.box("Stone_Dark", (W + 0.1, D + 0.1, 0.12), (0, 0, 0))
    # back wall tall, front low; planks as vertical strips on sides
    kit.hull("Wood_Weathered", [(x, y, z) for x in (-W / 2, W / 2) for y, z in
                                ((-D / 2, 0.1), (-D / 2, 2.6), (D / 2, 0.1), (D / 2, 2.1))])
    for i in range(9):
        x = -W / 2 + 0.2 + i * (W - 0.4) / 8
        kit.box("Wood_Dark", (0.04, 0.05, 1.95), (x, D / 2 + 0.02, 0.12))
    panel(kit, "Wood_Dark", "front", W, D, -0.6, 1.0, 1.0, 1.8, 0.06)
    panel(kit, "Wood", "front", W, D, -0.6, 1.0, 0.85, 1.7, 0.08)
    # lean-to roof
    pts = []
    for x in (-W / 2 - 0.3, W / 2 + 0.3):
        pts += [(x, -D / 2 - 0.35, 2.72), (x, D / 2 + 0.55, 2.08), (x, -D / 2 - 0.35, 2.64), (x, D / 2 + 0.55, 2.0)]
    kit.hull("Roof_Tin", pts, None, SOFT)
    for i in range(7):  # corrugation ribs
        x = -W / 2 - 0.2 + i * (W + 0.4) / 6
        kit.box_between("Roof_Tin", (x, -D / 2 - 0.35, 2.74), (x, D / 2 + 0.55, 2.1), 0.05, 0.04)
    # firewood stack against the right wall
    r = kit.r
    for row in range(3):
        for k in range(5 - row):
            y = -0.8 + k * 0.32 + row * 0.16
            z = 0.14 + row * 0.26
            kit.cyl("Wood_Cut", 0.13, 0.9, (W / 2 + 0.05, y, z + 0.13), (0, 90, r.uniform(-8, 8)), seg=6,
                    color=lambda co, n: (1, 1, 1, 1) if abs(n.x) > 0.8 else (0.62, 0.5, 0.5, 1))


# ----------------------------------------------------------------------------------------
# Fences and walls (2 m segments along X, origin at segment centre)
# ----------------------------------------------------------------------------------------
@prop("fence_wood", "village", ["roadside", "village", "field"], BOTH,
      {"type": "box", "size": [2.0, 1.1, 0.12], "center": [0, 0.55, 0]}, 300)
def fence_wood(kit: Kit) -> None:
    r = kit.r
    for x in (-0.95, 0.95):
        kit.box("Wood", (0.11, 0.11, 1.12), (x, 0, 0), (0, 0, r.uniform(-4, 4)), grad_z(0, 1.1, (0.8, 0.76, 0.86)))
        kit.cyl("Wood", 0.08, 0.06, (x, 0, 1.12), seg=4, r_top=0.0, phase=math.pi / 4)
    for z, tilt in ((0.42, 0.8), (0.86, -0.6)):
        kit.cbox("Wood_Pale", (2.06, 0.05, 0.12), (0, 0.07, z), (tilt, 0, 0))


@prop("fence_bamboo", "village", ["roadside", "village"], BOTH,
      {"type": "box", "size": [2.0, 1.25, 0.14], "center": [0, 0.62, 0]}, 600)
def fence_bamboo(kit: Kit) -> None:
    """Yotsume-style bamboo fence: posts, horizontal splits, dense vertical canes, black ties."""
    for x in (-0.97, 0.97):
        kit.cyl("Wood_Dark", 0.055, 1.25, (x, 0, 0), seg=6)
    for z in (0.3, 0.7, 1.05):
        kit.cyl("Bamboo_Cane", 0.025, 2.02, (-1.01, 0.05, z), (0, 90, 0), seg=4)
    n = 17
    for i in range(n):
        x = -0.85 + i * 1.7 / (n - 1)
        h = 1.16 + 0.03 * ((i * 7) % 3)
        kit.cyl("Bamboo_Cane", 0.022, h, (x, -0.0, 0.0), seg=4, cap_bot=False,
                color=grad_z(0, 1.2, (0.82, 0.8, 0.84)))
    for z in (0.3, 0.7, 1.05):
        for x in (-0.6, 0.0, 0.6):
            kit.cbox("Ink", (0.05, 0.1, 0.05), (x, 0.03, z))


@prop("stone_wall", "village", ["roadside", "village", "slope", "field"], BOTH,
      {"type": "box", "size": [2.0, 1.0, 0.7], "center": [0, 0.5, 0]}, 800)
def stone_wall(kit: Kit) -> None:
    """Dry-stacked ishigaki segment, 2 m x 1 m x 0.7 m, tileable along X."""
    r = kit.r
    rows = [(0.0, 0.36, 4), (0.33, 0.33, 5), (0.63, 0.3, 4)]
    for ri, (z, h, n) in enumerate(rows):
        w = 2.0 / n
        if ri % 2:
            cuts = [-1.0] + [-1.0 + w / 2 + w * k for k in range(n)] + [1.0]
        else:
            cuts = [-1.0 + w * k for k in range(n + 1)]
        for x0, x1 in zip(cuts, cuts[1:]):
            size = ((x1 - x0) * 0.96, 0.7 - 0.05 * ri, h * 0.96)
            pts = chamfer_box_points(Vector(((x0 + x1) / 2, 0, z)), size, 0.2, r, 0.025)
            for p in pts:  # keep the segment ends flush so walls tile along X
                p.x = max(-1.0, min(1.0, p.x))
            top = ri == len(rows) - 1
            kit.hull(lambda c, nrm, top=top: "Moss" if top and nrm.z > 0.8 and (c.x + 1.0) % 0.9 < 0.4 else "Stone",
                     pts, None, grad_z(0, 1.0, (0.78, 0.76, 0.88)))
    kit.box("Stone_Dark", (2.0, 0.34, 0.82), (0, 0.0, 0.0))  # dark core fills gaps between stones


# ----------------------------------------------------------------------------------------
# Roadside furniture
# ----------------------------------------------------------------------------------------
@prop("telephone_pole", "roadside", ["roadside", "village", "field"], BOTH, cyl(0.16), 800)
def telephone_pole(kit: Kit) -> None:
    """8 m concrete utility pole: crossarm + 3 insulators, transformer, yellow guard, number plate.
    Empties WireA/WireB/WireC mark the insulator tips (wire attachment points)."""
    kit.cyl("Concrete", 0.15, 8.0, (0, 0, 0), seg=8, r_top=0.1, color=grad_z(0, 8, (0.84, 0.82, 0.9)))
    for i in range(4):  # yellow/black guard sleeve
        kit.cyl("Yellow_Sign" if i % 2 == 0 else "Ink", 0.165, 0.45, (0, 0, i * 0.45), seg=8, cap_bot=False,
                cap_top=(i == 3))
    kit.cbox("Blue", (0.18, 0.02, 0.5), (0, 0.155, 2.6))
    kit.cbox("White", (0.13, 0.025, 0.4), (0, 0.158, 2.6))
    kit.cbox("Metal_Dark", (1.9, 0.1, 0.1), (0, 0.0, 7.45))
    kit.box_between("Metal_Dark", (-0.7, 0, 7.42), (0, 0, 6.95), 0.04, 0.04, (0, 1, 0))
    kit.box_between("Metal_Dark", (0.7, 0, 7.42), (0, 0, 6.95), 0.04, 0.04, (0, 1, 0))
    for name, x in (("WireA", -0.8), ("WireB", 0.0), ("WireC", 0.8)):
        z = 7.5 if name != "WireB" else 8.0
        kit.cyl("White", 0.06, 0.16, (x, 0, z), seg=6, r_top=0.045)
        kit.cyl("White", 0.07, 0.04, (x, 0, z + 0.05), seg=6)
        kit.empty(name, (x, 0, z + 0.17))
    # transformer can + step bolts
    kit.cyl("Galvanized", 0.26, 0.75, (0, -0.4, 5.6), seg=8)
    kit.cyl("Metal_Dark", 0.27, 0.06, (0, -0.4, 6.35), seg=8)
    kit.cbox("Metal_Dark", (0.08, 0.3, 0.08), (0, -0.18, 6.1))
    for i in range(6):
        a = math.pi / 2 if i % 2 else -math.pi / 2
        z = 3.0 + i * 0.45
        kit.cyl("Metal_Dark", 0.015, 0.22, (0.1 * math.cos(a), 0.1 * math.sin(a), z), (90, 0, math.degrees(a) + 90),
                seg=4)


@prop("vending_machine", "roadside", ["roadside", "village"], BOTH, box(), 800)
def vending_machine(kit: Kit) -> None:
    """Japanese drink vending machine: glowing display with rows of cans."""
    W, D, H = 1.0, 0.72, 1.83
    kit.box("Offwhite", (W, D, H), (0, 0, 0.04))
    kit.box("Metal_Dark", (W - 0.04, D - 0.04, 0.05), (0, 0, 0.0))
    kit.cbox("Red", (W + 0.02, D + 0.02, 0.2), (0, 0, H - 0.06))
    panel(kit, "Red", "front", W, D, 0.0, 1.1, W - 0.04, 1.44, 0.03)
    panel(kit, "Light_Panel", "front", W, D, 0.0, 1.35, W - 0.14, 0.86, 0.05)
    cans = ["Blue", "Red", "Cloth_Green", "Orange", "White", "Cloth_Yellow", "Metal_Dark", "Cloth_Pink",
            "Teal", "Cloth_Khaki", "Blue_Pale", "Red"]
    for row in range(3):
        for k in range(6):
            x = -0.34 + k * 0.136
            z = 1.0 + row * 0.27
            kit.cyl(cans[(row * 5 + k) % len(cans)], 0.04, 0.13, (x, D / 2 + 0.06, z), seg=6)
            kit.cbox("Blue_Pale", (0.08, 0.02, 0.025), (x, D / 2 + 0.06, z - 0.03))
    panel(kit, "Metal_Dark", "front", W, D, 0.0, 0.22, 0.7, 0.2, 0.06)  # pickup slot
    panel(kit, "Metal_Dark", "front", W, D, 0.34, 0.62, 0.16, 0.26, 0.05)  # coin panel
    panel(kit, "Light_Panel", "front", W, D, 0.34, 0.7, 0.1, 0.05, 0.06)
    panel(kit, "Blue", "front", W, D, -0.14, 0.62, 0.5, 0.18, 0.04)
    panel(kit, "Red", "right", W, D, 0.0, 1.0, D - 0.08, 1.5, 0.02)


@prop("bus_stop", "roadside", ["roadside", "village"], BOTH, box(), 1500)
def bus_stop(kit: Kit) -> None:
    """Rural bus shelter (wood, tin roof, bench) with the round bus-stop sign."""
    W, D = 2.6, 1.3
    kit.box("Concrete", (W + 0.2, D + 0.2, 0.1), (0, 0, 0))
    for x in (-W / 2 + 0.07, W / 2 - 0.07):
        for y in (-D / 2 + 0.07, D / 2 - 0.07):
            kit.box("Wood_Dark", (0.1, 0.1, 2.3), (x, y, 0.1))
    kit.box("Wood_Weathered", (W, 0.06, 1.9), (0, -D / 2 + 0.05, 0.3))
    for side in (-1, 1):
        kit.box("Wood_Weathered", (0.06, D * 0.7, 1.9), (side * (W / 2 - 0.05), -D * 0.12, 0.3))
    for i in range(6):
        kit.box("Wood_Dark", (0.03, 0.02, 1.9), (-W / 2 + 0.3 + i * (W - 0.6) / 5, -D / 2 + 0.09, 0.3))
    kit.box("Wood", (W - 0.3, 0.38, 0.06), (0, -D / 2 + 0.3, 0.45))
    for x in (-0.9, 0.9):
        kit.box("Wood_Dark", (0.06, 0.3, 0.35), (x, -D / 2 + 0.3, 0.1))
    pts = []
    for x in (-W / 2 - 0.2, W / 2 + 0.2):
        pts += [(x, -D / 2 - 0.2, 2.5), (x, D / 2 + 0.4, 2.3), (x, -D / 2 - 0.2, 2.42), (x, D / 2 + 0.4, 2.22)]
    kit.hull("Roof_Tin", pts, None, SOFT)
    # timetable board
    kit.cbox("White", (0.5, 0.03, 0.4), (0.7, -D / 2 + 0.1, 1.5))
    kit.cbox("Blue", (0.5, 0.035, 0.08), (0.7, -D / 2 + 0.1, 1.68))
    # sign pole
    sx = W / 2 + 0.55
    kit.cyl("Concrete", 0.22, 0.14, (sx, D / 2, 0), seg=8)
    kit.cyl("Galvanized", 0.035, 2.2, (sx, D / 2, 0.14), seg=6)
    kit.cyl("Blue", 0.3, 0.04, (sx, D / 2 + 0.02, 2.2), (90, 0, 0), seg=12)
    kit.cyl("White", 0.24, 0.06, (sx, D / 2 + 0.03, 2.2), (90, 0, 0), seg=12)
    kit.cbox("Red", (0.3, 0.07, 0.06), (sx, D / 2 + 0.03, 2.2))
    kit.cbox("White", (0.22, 0.03, 0.5), (sx, D / 2 + 0.02, 1.55))


def _curve_sign(kit: Kit, left: bool) -> None:
    kit.cyl("Galvanized", 0.035, 2.35, (0, 0, 0), seg=6)
    z = 2.15
    s = 0.62
    kit.cbox("Ink", (s + 0.03, 0.03, s + 0.03), (0, 0.04, z), (0, 45, 0))
    kit.cbox("Yellow_Sign", (s - 0.03, 0.04, s - 0.03), (0, 0.05, z), (0, 45, 0))
    # curved arrow: stem up, bend to the side, arrow head. Seen from the front (+Y), the
    # viewer's left is world +X.
    sgn = 1 if left else -1
    pts = [Vector((0.08 * -sgn, 0.08, z - 0.3)), Vector((0.08 * -sgn, 0.08, z - 0.02)),
           Vector((0.0, 0.08, z + 0.12)), Vector((0.1 * sgn, 0.08, z + 0.16))]
    for a, b in zip(pts, pts[1:]):
        kit.box_between("Ink", a, b, 0.075, 0.03, (0, 1, 0))
    tip = pts[-1] + Vector((0.13 * sgn, 0, 0))
    base = pts[-1]
    kit.poly("Ink", [base + Vector((0, 0.0, 0.1)), tip, base + Vector((0, 0.0, -0.1)),
                     base + Vector((0, 0.03, 0.1)), tip + Vector((0, 0.03, 0)), base + Vector((0, 0.03, -0.1))],
             [(0, 1, 2), (5, 4, 3), (0, 3, 4, 1), (1, 4, 5, 2), (2, 5, 3, 0)], None, None, recalc=True)
    kit.cbox("Galvanized", (0.08, 0.06, 0.2), (0, 0.02, z))


@prop("sign_curve_left", "roadside", ["roadside"], BOTH, cyl(0.05), 300)
def sign_curve_left(kit: Kit) -> None:
    _curve_sign(kit, True)


@prop("sign_curve_right", "roadside", ["roadside"], BOTH, cyl(0.05), 300)
def sign_curve_right(kit: Kit) -> None:
    _curve_sign(kit, False)


@prop("road_mirror", "roadside", ["roadside"], BOTH, cyl(0.06), 400)
def road_mirror(kit: Kit) -> None:
    """Orange convex traffic mirror on a pole, facing +Y."""
    kit.cyl("Orange", 0.045, 2.9, (0, 0, 0), seg=6)
    kit.cbox("Orange", (0.08, 0.3, 0.06), (0, 0.1, 2.72))
    c = Vector((0, 0.28, 2.7))
    kit.cyl("Orange", 0.4, 0.1, c, (-80, 0, 0), seg=14)
    kit.cyl("Glass_Mirror", 0.34, 0.05, c + Vector((0, 0.1, 0.0)), (-80, 0, 0), seg=14, r_top=0.25)
    kit.cyl("Orange", 0.43, 0.18, c + Vector((0, 0.04, 0.34)), (-80, 0, 0), seg=10, r_top=0.4,
            scale=(1.0, 0.35, 1.0))


@prop("guardrail", "roadside", ["roadside", "slope"], BOTH,
      {"type": "box", "size": [4.0, 0.8, 0.3], "center": [0, 0.4, 0]}, 300)
def guardrail(kit: Kit) -> None:
    """4 m white W-beam guardrail segment (tiles along X; rail faces +Y/road)."""
    for x in (-1.0, 1.0):
        kit.cyl("Galvanized", 0.07, 0.8, (x, -0.1, 0), seg=6)
        kit.cyl("Galvanized", 0.075, 0.03, (x, -0.1, 0.8), seg=6)
        kit.cbox("Galvanized", (0.12, 0.14, 0.3), (x, -0.02, 0.62))
    prof = [(0.05, 0.47), (0.12, 0.52), (0.12, 0.58), (0.06, 0.62), (0.12, 0.66), (0.12, 0.72),
            (0.05, 0.77), (0.02, 0.77), (0.09, 0.72), (0.09, 0.66), (0.03, 0.62), (0.09, 0.58),
            (0.09, 0.52), (0.02, 0.47)]
    prof = [(y, z) for y, z in reversed(prof)]
    kit.extrude_x("White", prof, [-2.0, 2.0], None, lambda co, n: lerp_col((0.8, 0.8, 0.9), (1, 1, 1), n.y * 0.6 + 0.6))


# ----------------------------------------------------------------------------------------
# Festival / farm
# ----------------------------------------------------------------------------------------
def _carp(kit: Kit, mat: str, root: Vector, length: float, rad: float, droop: float, phase: float) -> None:
    pts = []
    radii = []
    n = 7
    for i in range(n):
        f = i / (n - 1)
        pts.append(root + Vector((length * f, 0.12 * math.sin(f * 5 + phase), -droop * f * f)))
        radii.append(rad * (0.85 + 0.35 * math.sin(min(1.0, f * 1.6) * math.pi * 0.9)) * (1 - 0.72 * f))
    kit.tube(mat, pts, radii, 6, cap_start=False, cap_end=True,
             color=lambda co, nn: lerp_col((0.8, 0.78, 0.9), (1, 1, 1), nn.z * 0.5 + 0.7))
    kit.cyl("Ink", rad * 0.8, 0.02, root + Vector((0.02, 0, 0)), (0, 90, 0), seg=6)
    kit.cyl("Gold", rad * 0.9, 0.06, root, (0, 90, 0), seg=6, cap_bot=False, cap_top=False)
    tail = pts[-1]
    for sz in (1, -1):
        fin = [tail + Vector((-0.1, 0, 0)), tail + Vector((rad * 1.6, 0, sz * rad * 1.3)),
               tail + Vector((rad * 1.0, 0, 0))]
        kit.poly(mat, fin, [(0, 1, 2)])
        kit.poly(mat, fin, [(2, 1, 0)])
    for sy in (1, -1):
        e = root + Vector((rad * 0.8, sy * rad * 0.82, rad * 0.25))
        kit.cyl("White", rad * 0.3, 0.02, e, (sy * -90, 0, 0), seg=6)
        kit.cyl("Ink", rad * 0.15, 0.03, e, (sy * -90, 0, 0), seg=5)
    for i in range(3):  # scale band accents
        f = 0.3 + i * 0.18
        p = root + Vector((length * f, 0.12 * math.sin(f * 5 + phase), -droop * f * f))
        rr = rad * (0.85 + 0.35 * math.sin(min(1.0, f * 1.6) * math.pi * 0.9)) * (1 - 0.72 * f) * 1.03
        kit.cyl("White" if mat != "Cloth_White" else "Cloth_Red", rr, 0.05, p, (0, 90, 0), seg=6, cap_bot=False,
                cap_top=False)


@prop("koinobori", "village", ["village", "field", "roadside"], ["spring"], cyl(0.08), 1500)
def koinobori(kit: Kit) -> None:
    """Carp-streamer pole: 8 m, spinning wheel top, five-colour streamer, three carp."""
    kit.cyl("Bamboo_Cane", 0.08, 8.2, (0, 0, 0), seg=6, r_top=0.05)
    kit.add(bm_ico(1, 0.1), "Gold", trs((0, 0, 8.3)))
    for k in range(4):
        a = k * 45
        kit.box_between("Gold", (0, 0, 8.05), (0.3 * math.cos(math.radians(a)), 0.3 * math.sin(math.radians(a)), 8.05),
                        0.03, 0.03)
        kit.box_between("Gold", (0, 0, 8.05), (-0.3 * math.cos(math.radians(a)), -0.3 * math.sin(math.radians(a)), 8.05),
                        0.03, 0.03)
    for i, m in enumerate(("Cloth_Blue", "Cloth_Yellow", "Cloth_Red", "Cloth_White", "Cloth_Green")):
        pts = [Vector((0.1, 0.02 * i, 7.9 - i * 0.05)), Vector((1.2, 0.02 * i + 0.05, 7.8 - i * 0.07)),
               Vector((2.4, 0.02 * i, 7.5 - i * 0.1))]
        for a, b in zip(pts, pts[1:]):
            kit.box_between(m, a, b, 0.02, 0.1, (0, 1, 0))
    kit.cyl("Rope", 0.012, 7.0, (0.07, 0, 0.6), seg=3)
    _carp(kit, "Cloth_Black", Vector((0.1, 0, 7.1)), 3.0, 0.38, 0.6, 0.0)
    _carp(kit, "Cloth_Red", Vector((0.1, 0, 6.1)), 2.4, 0.3, 0.55, 1.3)
    _carp(kit, "Cloth_Blue", Vector((0.1, 0, 5.2)), 1.8, 0.24, 0.45, 2.6)


@prop("lantern_string", "village", ["village", "roadside", "spectator_zone"], BOTH, NONE, 1200)
def lantern_string(kit: Kit) -> None:
    """5 m festival string of paper chochin between two poles (origin mid-span)."""
    for x in (-2.5, 2.5):
        kit.cyl("Wood", 0.06, 3.3, (x, 0, 0), seg=6, r_top=0.05)
        kit.cyl("Wood_Dark", 0.07, 0.3, (x, 0, 0), seg=6)
    sag = 0.4
    top = 3.2
    pts = [Vector((x, 0, top - sag * (1 - (x / 2.5) ** 2))) for x in [-2.5 + i * 0.5 for i in range(11)]]
    kit.tube("Rope", pts, [0.012] * len(pts), 3, cap_end=False)
    for i in range(7):
        x = -2.1 + i * 0.7
        zr = top - sag * (1 - (x / 2.5) ** 2)
        c = Vector((x, 0, zr - 0.34))
        mat = "Lantern_Red" if i % 2 == 0 else "Lantern_Paper"
        prof_z = [-0.2, -0.16, -0.05, 0.08, 0.17, 0.2]
        prof_r = [0.09, 0.13, 0.155, 0.15, 0.12, 0.09]
        kit.tube(mat, [c + Vector((0, 0, z)) for z in prof_z], prof_r, 7, cap_start=True, cap_end=True)
        kit.cyl("Ink", 0.095, 0.04, c + Vector((0, 0, 0.19)), seg=7)
        kit.cyl("Ink", 0.095, 0.04, c + Vector((0, 0, -0.23)), seg=7)
        kit.cyl("Rope", 0.008, 0.1, c + Vector((0, 0, 0.23)), seg=3)


@prop("hazagi", "village", ["field"], AUTUMN,
      {"type": "box", "size": [4.6, 2.1, 0.5], "center": [0, 1.05, 0]}, 1200)
def hazagi(kit: Kit) -> None:
    """Rice-drying rack: poles, three bamboo bars, hanging straw sheaves."""
    r = kit.r
    for x in (-2.2, 0.0, 2.2):
        kit.cyl("Wood_Weathered", 0.06, 2.2, (x, 0, 0), (0, r.uniform(-3, 3), 0), seg=5)
        for sy in (-1, 1):
            kit.cyl_between("Wood_Weathered", (x, sy * 0.6, 0), (x, 0, 1.6), 0.04, seg=4)
    bars = (0.75, 1.3, 1.85)
    for z in bars:
        kit.cyl("Bamboo_Cane", 0.03, 4.7, (-2.35, 0, z), (0, 90, 0), seg=4)
    for z in bars:
        x = -2.05
        while x < 2.1:
            if abs(x) > 0.08 and abs(abs(x) - 2.2) > 0.08:
                w = r.uniform(0.14, 0.18)
                h = r.uniform(0.42, 0.5)
                sp = r.uniform(0.1, 0.14)
                pts = [(x - w / 2, 0, z + 0.04), (x + w / 2, 0, z + 0.04),
                       (x - w / 2 - 0.02, -sp, z - h), (x + w / 2 + 0.02, -sp, z - h),
                       (x - w / 2 - 0.02, sp, z - h), (x + w / 2 + 0.02, sp, z - h)]
                kit.hull("Straw", pts, None, grad_z(z - 0.5, z, (0.82, 0.76, 0.8)))
            x += 0.19


@prop("scarecrow", "village", ["field"], BOTH, cyl(0.1), 600)
def scarecrow(kit: Kit) -> None:
    """Kakashi: straw hat, sack face, blue happi coat on a cross."""
    kit.cyl("Wood_Weathered", 0.04, 1.7, (0, 0, 0), seg=5)
    kit.cyl("Wood_Weathered", 0.035, 1.5, (-0.75, 0, 1.3), (0, 90, 0), seg=5)
    kit.hull("Cloth_Blue", [(x, y, z) for x in (-0.25, 0.25) for y in (-0.12, 0.12) for z in (0.8, 1.42)] +
             [(-0.3, 0, 0.75), (0.3, 0, 0.75)], None, SOFT)
    for sx in (-1, 1):
        kit.hull("Cloth_Blue", [(sx * x, y, z) for x in (0.2, 0.62) for y in (-0.1, 0.1) for z in (1.22, 1.42)] +
                 [(sx * 0.62, 0, 1.12)], None, SOFT)
        kit.cyl("Straw", 0.08, 0.2, (sx * 0.62, 0, 1.3), (0, sx * 90, 0), seg=5, r_top=0.0)
    kit.cbox("Red", (0.52, 0.26, 0.07), (0, 0, 1.0))
    kit.add(bm_ico(2, 0.17), "Canvas", trs((0, 0, 1.58)))
    for sx in (-1, 1):
        kit.cyl("Ink", 0.025, 0.02, (sx * 0.06, 0.16, 1.62), (-90, 0, 0), seg=5)
    kit.cbox("Ink", (0.1, 0.02, 0.015), (0, 0.165, 1.53))
    kit.cyl("Straw", 0.42, 0.24, (0, 0, 1.64), seg=10, r_top=0.03)
    kit.cyl("Straw", 0.1, 0.25, (0, 0, 0.55), seg=5, r_top=0.0, color=(0.9, 0.85, 0.85))


@prop("kei_truck", "vehicle", ["village", "field", "roadside"], BOTH, box(), 1800)
def kei_truck(kit: Kit) -> None:
    """Parked white kei pickup (3.4 x 1.48 m): cab-over, drop-side bed, yellow kei plates."""
    W = 1.46
    body = grad_z(0.2, 1.8, (0.84, 0.84, 0.94))
    # chassis + bed
    kit.box("Metal_Dark", (1.2, 3.2, 0.2), (0, 0, 0.28))
    kit.box("White", (W, 1.95, 0.08), (0, -0.72, 0.62), color=body)
    for sx in (-1, 1):
        kit.box("White", (0.04, 1.95, 0.3), (sx * (W / 2 - 0.02), -0.72, 0.7), color=body)
    kit.box("White", (W, 0.04, 0.3), (0, -1.68, 0.7), color=body)
    kit.box("White", (W, 0.04, 0.3), (0, 0.24, 0.7), color=body)
    # headboard guard frame
    for sx in (-0.6, 0.0, 0.6):
        kit.box("Metal_Dark", (0.04, 0.04, 0.55), (sx, 0.26, 1.0))
    kit.box("Metal_Dark", (W - 0.04, 0.05, 0.05), (0, 0.26, 1.52))
    # cab (slanted front)
    y0, y1 = 0.3, 1.7
    cab = [(x, y, z) for x in (-W / 2, W / 2) for (y, z) in
           ((y0, 0.45), (y0, 1.78), (y1 - 0.25, 1.76), (y1, 1.1), (y1, 0.45))]
    kit.hull("White", cab, None, body)
    # windows
    kit.poly("Glass", [(-W / 2 + 0.06, y1 - 0.02, 1.16), (W / 2 - 0.06, y1 - 0.02, 1.16),
                       (W / 2 - 0.06, y1 - 0.27, 1.72), (-W / 2 + 0.06, y1 - 0.27, 1.72)],
             [(0, 1, 2, 3)], trs((0, 0.012, 0.004)))
    for sx in (-1, 1):
        x = sx * (W / 2 + 0.005)
        f = [(x, y0 + 0.5, 1.12), (x, y1 - 0.12, 1.12), (x, y1 - 0.3, 1.66), (x, y0 + 0.5, 1.66)]
        kit.poly("Glass", f, [(0, 1, 2, 3)] if sx > 0 else [(3, 2, 1, 0)])
        kit.poly("Glass", [(x, y0 + 0.08, 1.12), (x, y0 + 0.42, 1.12), (x, y0 + 0.42, 1.66), (x, y0 + 0.08, 1.66)],
                 [(0, 1, 2, 3)] if sx > 0 else [(3, 2, 1, 0)])
        kit.box("Metal_Dark", (0.02, 0.4, 0.03), (x, y0 + 0.7, 0.98))  # door line/handle strip
        kit.cbox("Metal_Dark", (0.14, 0.04, 0.1), (sx * (W / 2 + 0.1), y1 - 0.15, 1.3))  # mirror
        kit.cbox("Metal_Dark", (0.03, 0.03, 0.14), (sx * (W / 2 + 0.03), y1 - 0.15, 1.22))
    # front: bumper, grille, lights, plate
    kit.cbox("Metal_Dark", (W + 0.02, 0.12, 0.16), (0, y1 + 0.03, 0.42))
    kit.cbox("Metal_Dark", (0.8, 0.03, 0.14), (0, y1 + 0.005, 0.72))
    for sx in (-1, 1):
        kit.cbox("HeadLight", (0.22, 0.04, 0.14), (sx * 0.5, y1 + 0.005, 0.72))
        kit.cbox("Orange", (0.08, 0.04, 0.08), (sx * 0.66, y1 + 0.005, 0.56))
    kit.cbox("Yellow_Sign", (0.33, 0.03, 0.17), (0, y1 + 0.1, 0.44))
    # rear lights + plate
    for sx in (-1, 1):
        kit.cbox("TailLight", (0.12, 0.04, 0.16), (sx * 0.58, -1.72, 0.55))
    kit.cbox("Yellow_Sign", (0.33, 0.03, 0.17), (0, -1.72, 0.45))
    # wheels
    for y in (1.08, -0.95):
        for sx in (-1, 1):
            xc = sx * (W / 2 - 0.1)
            kit.cyl("Rubber", 0.28, 0.17, (xc - 0.085, y, 0.28), (0, 90, 0), seg=10)
            kit.cyl("Galvanized", 0.15, 0.02, (xc + 0.085 if sx > 0 else xc - 0.105, y, 0.28), (0, 90, 0), seg=8)
    # arches (dark wheel wells)
    for y in (1.08, -0.95):
        for sx in (-1, 1):
            kit.cbox("Metal_Dark", (0.02, 0.7, 0.2), (sx * (W / 2 + 0.005), y, 0.62))
    # cargo: two crates
    kit.box("Wood_Pale", (0.5, 0.4, 0.34), (-0.3, -1.1, 0.66))
    kit.box("Orange", (0.46, 0.34, 0.28), (0.35, -0.6, 0.66))
    kit.cyl("Cloth_Green", 0.12, 0.3, (0.35, -0.6, 0.94), seg=6)


@prop("bench", "village", ["roadside", "village", "spectator_zone"], BOTH, box(), 300)
def bench(kit: Kit) -> None:
    """Wooden slat bench, 1.8 m."""
    for x in (-0.75, 0.75):
        kit.box("Metal_Dark", (0.06, 0.45, 0.42), (x, 0, 0))
        kit.box("Metal_Dark", (0.06, 0.06, 0.45), (x, -0.2, 0.42), (-12, 0, 0))
    for k in range(3):
        kit.box("Wood", (1.8, 0.13, 0.04), (0, -0.16 + k * 0.155, 0.42))
    for k in range(2):
        kit.box("Wood", (1.8, 0.04, 0.12), (0, -0.25 - 0.02 * k, 0.58 + k * 0.17), (-12, 0, 0))


# ----------------------------------------------------------------------------------------
# P2 extras
# ----------------------------------------------------------------------------------------
@prop("bridge_rail", "village", ["water_edge", "roadside"], BOTH,
      {"type": "box", "size": [4.0, 1.0, 0.2], "center": [0, 0.5, 0]}, 400)
def bridge_rail(kit: Kit) -> None:
    """4 m wooden bridge railing (vermilion-capped posts, top rail, mid rail), tiles along X."""
    for x in (-1.9, 0.0, 1.9):
        kit.box("Wood", (0.16, 0.16, 0.98), (x, 0, 0), color=grad_z(0, 1.0, (0.82, 0.78, 0.88)))
        kit.cyl("Vermilion", 0.1, 0.1, (x, 0, 0.98), seg=6)
        kit.add(bm_ico(1, 0.075), "Gold", trs((x, 0, 1.12), (0, 0, 0), (1, 1, 1.3)))
    kit.extrude_x("Wood", [(-0.06, 0.8), (0.06, 0.8), (0.07, 0.9), (0.0, 0.94), (-0.07, 0.9)],
                  [-2.0, 2.0], None, SOFT)
    kit.cbox("Wood_Dark", (4.0, 0.06, 0.08), (0, 0, 0.45))
    for x0 in (-1.9, 0.0):
        for k in range(1, 4):
            kit.box("Wood_Dark", (0.04, 0.04, 0.35), (x0 + k * 0.475, 0, 0.45))


@prop("water_well", "village", ["village", "field"], BOTH, cyl(0.62), 800)
def water_well(kit: Kit) -> None:
    """Stone well with a small tiled roof, pulley and wooden bucket."""
    kit.cyl(lambda c, n: "Moss" if n.z > 0.8 else "Stone", 0.62, 0.72, (0, 0, 0), seg=10, r_top=0.6,
            color=STONE_SHADE)
    kit.cyl("Water", 0.47, 0.02, (0, 0, 0.5), seg=10)
    kit.cyl("Stone_Dark", 0.5, 0.18, (0, 0, 0.4), seg=10, cap_top=False)
    kit.cbox("Wood", (1.34, 0.07, 0.06), (0, 0, 0.75))
    for sx in (-1, 1):
        kit.box("Wood_Dark", (0.1, 0.1, 1.7), (sx * 0.62, 0, 0.3))
    kit.cbox("Wood_Dark", (1.4, 0.1, 0.1), (0, 0, 1.95))
    kit.cyl("Wood", 0.1, 0.08, (-0.04, 0, 1.78), (0, 90, 0), seg=8)
    kit.cyl("Rope", 0.01, 0.9, (0.0, 0.1, 0.88), seg=3)
    gable_roof(kit, "Roof_Tile", 1.3, 0.9, 2.0, 0.42, 0.18, 0.2, 0.08, None, "Roof_Ridge", ridge=(0.12, 0.1))
    kit.cyl("Wood_Pale", 0.13, 0.22, (0.3, 0.7, 0.72), seg=8, r_top=0.15)
    kit.cyl("Metal_Dark", 0.14, 0.03, (0.3, 0.7, 0.82), seg=8, cap_bot=False, cap_top=False)


@prop("shrine_bell", "village", ["village", "forest"], BOTH, box(), 800)
def shrine_bell(kit: Kit) -> None:
    """Shoro: small open bell tower with bronze temple bell and striker log."""
    kit.box("Stone", (2.4, 2.4, 0.4), (0, 0, 0), color=STONE_SHADE)
    for sx in (-1, 1):
        for sy in (-1, 1):
            kit.cyl("Vermilion", 0.1, 2.9, (sx * 0.9, sy * 0.9, 0.4), seg=8)
    kit.box("Vermilion", (2.0, 2.0, 0.16), (0, 0, 3.0))
    kit.box("Wood_Dark", (2.1, 2.1, 0.14), (0, 0, 3.16))
    hip_roof(kit, "Roof_Tile", 2.0, 2.0, 3.3, 1.05, 0.55, 0.14, 0.12)
    kit.cbox("Wood_Dark", (0.12, 1.9, 0.12), (0, 0, 2.9))
    kit.cyl("Roof_Copper", 0.32, 0.9, (0, 0, 1.9), seg=10, r_top=0.26)
    kit.cyl("Roof_Copper", 0.2, 0.12, (0, 0, 2.8), seg=8, r_top=0.08)
    kit.cyl("Roof_Copper", 0.34, 0.08, (0, 0, 1.86), seg=10)
    for z in (2.1, 2.45):
        kit.cyl("Gold", 0.315 - (z - 1.9) * 0.07, 0.03, (0, 0, z), seg=10, cap_bot=False, cap_top=False)
    kit.cyl("Wood_Pale", 0.07, 1.2, (-0.6, 0.55, 2.2), (0, 90, 0), seg=6)
    for x in (-0.4, 0.4):
        kit.cyl("Rope", 0.012, 0.65, (x, 0.55, 2.26), seg=3)


@prop("rice_paddy_marker", "village", ["field", "roadside"], BOTH, cyl(0.05), 200)
def rice_paddy_marker(kit: Kit) -> None:
    """Paddy boundary stake with a hanging straw sheaf and a red plot tag."""
    kit.cyl("Wood_Weathered", 0.04, 1.3, (0, 0, 0), seg=5)
    kit.cyl("Wood_Weathered", 0.04, 0.08, (0, 0, 1.3), seg=5, r_top=0.0)
    kit.cbox("White", (0.12, 0.02, 0.28), (0, 0.05, 1.0))
    kit.cbox("Red", (0.12, 0.022, 0.06), (0, 0.05, 1.1))
    kit.hull("Straw", [(-0.1, 0.0, 0.8), (0.1, 0.0, 0.8), (-0.14, -0.1, 0.35), (0.14, -0.1, 0.35),
                       (-0.14, 0.1, 0.35), (0.14, 0.1, 0.35)], None, grad_z(0.3, 0.8, (0.82, 0.76, 0.8)))
    kit.cyl("Rope", 0.06, 0.04, (0, 0, 0.74), seg=6)
