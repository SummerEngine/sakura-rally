"""Garage: the Sakura Rally service workshop by the Hanami start straight (runtime GarageSet).

Built at runtime by scripts/game/garage_set.gd at MapWorld.garage, not scattered by mapgen:
  garage_workshop  open-front timber workshop (front = +Y, the road side): tin gable roof with a
                   kanban sign, three open bays, workbench and tool wall, roll cab, tyre rack,
                   drums, jack, hanging lamps (markers Lamp_0..2 for the warm OmniLights) and red
                   chochin under the front eave (markers Lantern_0..3).
  garage_nobori    tall pink service banner 桜 / 整備 on a weighted pole (flag side +X).
  garage_tyres     outdoor pile of worn tyres and an oil drum.
GarageSet mirrors the workshop's walls, posts and furniture as colliders (WORKSHOP_* constants).
"""
from __future__ import annotations

import math

import bmesh
from mathutils import Matrix, Vector

from .common import Kit, facing, grad_z, lerp_col, trs, underside
from .registry import BOTH, NONE, cyl, prop

FONT = "/System/Library/Fonts/Supplemental/Arial Black.ttf"
FONT_JP = "/Library/Fonts/Arial Unicode.ttf"
SOFT = underside()
WOOD = grad_z(0.0, 4.0, (0.8, 0.76, 0.88))
METAL = grad_z(0.0, 2.5, (0.82, 0.82, 0.92))
RUBBER = lambda co, n: lerp_col((0.78, 0.78, 0.9), (1, 1, 1), n.z * 0.5 + 0.5)  # noqa: E731

# Workshop footprint (Blender metres; GarageSet uses the same numbers in Godot axes).
W, D, H = 14.0, 8.0, 4.0       # width (X), depth (Y), wall height at the eave
SLAB = 0.08
POSTS_X = (-W / 2, -W / 6, W / 6, W / 2)


def _tyre_bm(seg: int = 10) -> bmesh.types.BMesh:
    """Tyre lying flat, centre at the origin (0.66 m across, 0.22 m tall)."""
    prof = [(0.2, -0.09), (0.29, -0.11), (0.335, -0.05), (0.335, 0.05), (0.29, 0.11), (0.2, 0.09)]
    bm = bmesh.new()
    rings = []
    for k in range(seg):
        a = 2 * math.pi * k / seg
        rings.append([bm.verts.new((math.cos(a) * r, math.sin(a) * r, z)) for r, z in prof])
    n = len(prof)
    for k in range(seg):
        ra, rb = rings[k], rings[(k + 1) % seg]
        for j in range(n):
            bm.faces.new((ra[j], ra[(j + 1) % n], rb[(j + 1) % n], rb[j]))
    return bm


def tyre_lying(kit: Kit, c: Vector, yaw: float = 0.0) -> None:
    kit.add(_tyre_bm(), "Rubber", trs(c + Vector((0, 0, 0.11)), (0, 0, yaw)), RUBBER)


def tyre_standing(kit: Kit, c: Vector, yaw: float = 0.0, lean: float = 0.0) -> None:
    """Tyre on its tread, axle along X (turned by yaw), bottom at c."""
    kit.add(_tyre_bm(), "Rubber", trs(c + Vector((0, 0, 0.335)), (lean, 90, yaw)), RUBBER)


def drum(kit: Kit, c: Vector, mat: str) -> None:
    """200 l oil drum with rolled rims and a bung on the lid."""
    kit.cyl(mat, 0.29, 0.88, c, seg=10, color=grad_z(c.z, c.z + 0.9, (0.8, 0.78, 0.9)))
    for z in (0.02, 0.3, 0.58, 0.86):
        kit.cyl(mat, 0.305, 0.03, c + Vector((0, 0, z)), seg=10, cap_bot=False, cap_top=False)
    kit.cyl("Metal_Dark", 0.04, 0.03, c + Vector((0.14, 0.05, 0.88)), seg=6)


def lantern(kit: Kit, c: Vector, mat: str = "Lantern_Red") -> None:
    """Hanging chochin centred at c, with black caps and a cord up to the eave."""
    prof_z = [-0.26, -0.21, -0.07, 0.1, 0.22, 0.26]
    prof_r = [0.12, 0.17, 0.2, 0.195, 0.16, 0.12]
    kit.tube(mat, [c + Vector((0, 0, z)) for z in prof_z], prof_r, 8, cap_start=True, cap_end=True)
    kit.cyl("Ink", 0.125, 0.05, c + Vector((0, 0, 0.25)), seg=8)
    kit.cyl("Ink", 0.125, 0.05, c + Vector((0, 0, -0.3)), seg=8)
    kit.cyl("Rope", 0.01, 0.3, c + Vector((0, 0, 0.3)), seg=3)


def _jp_char(kit: Kit, mat: str, ch: str, size: float, m: Matrix) -> None:
    kit.text(mat, ch, size, 0.02, m, FONT_JP, resolution=1)


@prop("garage_workshop", "building", ["village", "roadside"], BOTH, NONE, 16000)
def garage_workshop(kit: Kit) -> None:
    """Open-front service workshop, 14 x 8 m, three bays facing +Y."""
    r = kit.r
    y0, y1 = -D / 2, D / 2
    # concrete slab with a lip at the front and oil stains
    kit.box("Concrete", (W + 0.5, D + 0.4, SLAB), (0, 0.1, 0), color=grad_z(0, SLAB, (0.86, 0.85, 0.92)))
    for x, y, s in ((-4.4, 1.4, 1.1), (0.3, 0.9, 0.8), (4.7, 1.8, 1.0), (-1.8, -1.6, 0.6)):
        kit.cyl("Metal_Dark", s, 0.004, (x, y, SLAB), seg=9, scale=(1.0, 0.6, 1.0), r=(0, 0, r.uniform(0, 90)))
    # back wall: dark timber skirt, plaster above, posts and a top beam (thin, so the inside shows)
    kit.box("Plaster", (W, 0.2, H), (0, y0 + 0.1, SLAB), color=grad_z(0, H, (0.88, 0.85, 0.92)))
    kit.box("Wood_Dark", (W + 0.04, 0.24, 1.1), (0, y0 + 0.1, SLAB))
    for x in (-W / 2, -W / 4, 0.0, W / 4, W / 2):
        kit.box("Wood_Dark", (0.2, 0.26, H), (x, y0 + 0.1, SLAB))
    kit.box("Wood_Dark", (W + 0.1, 0.28, 0.24), (0, y0 + 0.1, SLAB + H - 0.24))
    # side walls: weathered planks with battens, a window on the right, a door on the left
    for sx in (-1, 1):
        x = sx * (W / 2 - 0.08)
        kit.box("Wood_Weathered", (0.16, D, H), (x, 0, SLAB), color=WOOD)
        for k in range(9):
            y = y0 + 0.4 + k * (D - 0.8) / 8
            kit.box("Wood_Dark", (0.2, 0.06, H - 0.1), (x, y, SLAB))
        kit.box("Wood_Dark", (0.24, D + 0.1, 0.22), (x, 0, SLAB + H - 0.22))
    kit.cbox("Wood_Dark", (0.22, 1.9, 1.2), (W / 2 - 0.08, -0.6, 2.1))
    kit.cbox("Glass", (0.26, 1.7, 1.0), (W / 2 - 0.08, -0.6, 2.1))
    kit.cbox("Wood_Dark", (0.28, 0.06, 1.0), (W / 2 - 0.08, -0.6, 2.1))
    kit.cbox("Wood_Dark", (0.22, 1.1, 2.1), (-W / 2 + 0.08, -1.8, SLAB + 1.05))
    kit.cbox("Wood", (0.24, 0.95, 2.0), (-W / 2 + 0.08, -1.8, SLAB + 1.0))
    # front: posts at the bay edges, header beam, a painted fascia band
    for x in POSTS_X:
        kit.box("Wood_Dark", (0.28, 0.28, H), (x, y1 - 0.14, SLAB), color=WOOD)
        kit.box("Stone", (0.4, 0.4, 0.14), (x, y1 - 0.14, 0.0))
    kit.box("Wood_Dark", (W + 0.2, 0.34, 0.36), (0, y1 - 0.14, SLAB + H - 0.36))
    kit.box("Vermilion", (W + 0.22, 0.06, 0.12), (0, y1 + 0.05, SLAB + H - 0.3))
    # tin gable roof (ridge along X), corrugation ribs, gable ends closed
    zr = gable_tin(kit, SLAB + H)
    # kanban sign board standing on the front slope
    zc = SLAB + H + 0.95
    yb = y1 - 0.55
    kit.cbox("Wood_Dark", (7.4, 0.16, 1.5), (0, yb, zc))
    kit.cbox("Paper_White", (7.1, 0.2, 1.24), (0, yb, zc))
    for x in (-3.0, 3.0):
        kit.box_between("Wood_Dark", (x, yb - 0.1, zc - 0.7), (x, yb - 1.2, SLAB + H - 0.1), 0.1, 0.1, (1, 0, 0))
    yt = yb + 0.11
    # seen from the road the board's -X end is on the viewer's left: flower, then さくら整備
    kit.flower("Vermilion", facing((-2.75, yt, zc + 0.03), "front"), 0.5, "Gold")
    x = -1.95
    for ch in ("さ", "く", "ら", "整", "備"):
        _jp_char(kit, "Ink", ch, 0.78, facing((x, yt, zc + 0.12), "front"))
        x += 0.9 if ch not in ("ら",) else 1.1
    kit.text("Vermilion", "SAKURA RALLY WORKS", 0.2, 0.02, facing((-0.55, yt, zc - 0.44), "front"), FONT,
             resolution=1)
    # hanging lamps inside (markers for the OmniLights)
    for i, lx in enumerate((-W / 3, 0.0, W / 3)):
        z = SLAB + H - 0.9
        kit.cyl("Rope", 0.012, zr - 0.6 - z, (lx, 0.2, z + 0.12), seg=3)
        kit.cyl("Metal_Dark", 0.36, 0.2, (lx, 0.2, z), seg=10, r_top=0.08, cap_bot=False, color=SOFT)
        kit.cyl("Light_Panel", 0.3, 0.02, (lx, 0.2, z + 0.02), seg=10)
        kit.empty(f"Lamp_{i}", (lx, 0.2, z - 0.25))
    # chochin under the front eave, one per post
    for i, px in enumerate(POSTS_X):
        c = Vector((px * 0.97, y1 + 0.55, SLAB + H - 0.95))
        lantern(kit, c, "Lantern_Red" if i % 3 == 0 else "Lantern_Paper")
        kit.empty(f"Lantern_{i}", tuple(c))
    _interior(kit)


def gable_tin(kit: Kit, z_eave: float) -> float:
    """Red tin gable roof over the workshop; returns the ridge height."""
    pitch, over_x, over_y, thick = 1.5, 0.45, 1.35, 0.14
    s = pitch / (D / 2)
    hx, hy = W / 2 + over_x, D / 2 + over_y
    zr = z_eave + pitch
    ze = z_eave - over_y * s
    for sy in (-1, 1):
        pts = []
        for x in (-hx, hx):
            pts += [(x, 0, zr + thick * 0.5), (x, sy * hy, ze), (x, 0, zr - thick), (x, sy * hy, ze - thick)]
        kit.hull("Roof_Tin", pts, None, SOFT)
        for i in range(15):
            x = -hx + 0.3 + i * (2 * hx - 0.6) / 14
            kit.box_between("Roof_Tin", (x, sy * hy, ze + 0.02), (x, 0, zr + thick * 0.5 + 0.02), 0.06, 0.05)
    kit.cbox("Roof_Ridge", (2 * hx + 0.1, 0.3, 0.2), (0, 0, zr + thick * 0.5 + 0.04), color=SOFT)
    for sx in (-1, 1):
        x = sx * (W / 2 - 0.08)
        pts = [(x + dx, y, z) for dx in (-0.08, 0.08)
               for y, z in ((-D / 2, z_eave - 0.01), (D / 2, z_eave - 0.01), (0, zr - thick))]
        kit.hull("Wood_Weathered", pts, None, WOOD)
    return zr


def _interior(kit: Kit) -> None:
    r = kit.r
    yb = -D / 2 + 0.2  # inside face of the back wall
    # tool wall: pegboard with wrenches, hammers and a hose coil, over the workbench (left bay)
    kit.cbox("Wood_Pale", (4.2, 0.04, 1.5), (-4.4, yb + 0.03, 2.2))
    for k in range(9):
        x = -6.1 + k * 0.28
        L = 0.24 + k * 0.03
        kit.cbox("Metal", (0.05, 0.03, L), (x, yb + 0.07, 2.55 - L / 2), color=METAL)
        kit.cbox("Metal", (0.1, 0.03, 0.06), (x, yb + 0.07, 2.58))
    for k in range(3):
        x = -3.5 + k * 0.35
        kit.cbox("Wood", (0.04, 0.03, 0.34), (x, yb + 0.07, 2.2))
        kit.cbox("Metal_Dark", (0.16, 0.05, 0.06), (x, yb + 0.08, 2.39))
    kit.cyl("Red", 0.26, 0.06, (-2.6, yb + 0.08, 1.95), (90, 0, 0), seg=10)
    kit.cyl("Red_Dark", 0.14, 0.07, (-2.6, yb + 0.08, 1.95), (90, 0, 0), seg=8)
    # workbench with a vise and drawers
    kit.box("Wood", (4.2, 0.85, 0.08), (-4.4, yb + 0.45, 0.92))
    for x in (-6.4, -2.4):
        for y in (yb + 0.1, yb + 0.8):
            kit.box("Metal_Dark", (0.06, 0.06, 0.84), (x, y, SLAB))
    kit.box("Metal_Dark", (4.0, 0.7, 0.04), (-4.4, yb + 0.45, 0.3))
    kit.cbox("Red_Dark", (0.9, 0.75, 0.5), (-5.8, yb + 0.45, 0.66))
    for z in (0.52, 0.72):
        kit.cbox("Metal", (0.6, 0.78, 0.02), (-5.8, yb + 0.45, z))
    kit.box("Metal_Dark", (0.24, 0.3, 0.16), (-3.0, yb + 0.72, 1.0))
    kit.box("Metal_Dark", (0.08, 0.3, 0.12), (-3.0, yb + 0.9, 1.02))
    kit.box("Blue", (0.4, 0.26, 0.22), (-4.6, yb + 0.35, 1.0))  # toolbox on the bench
    # roll cab (red tool chest) and a floor jack in the middle bay
    kit.box("Red", (1.0, 0.55, 1.05), (-1.3, yb + 0.35, SLAB + 0.08))
    for k in range(5):
        kit.cbox("Metal", (0.9, 0.58, 0.02), (-1.3, yb + 0.35, SLAB + 0.3 + k * 0.17))
    for x in (-1.72, -0.88):
        kit.cyl("Rubber", 0.05, 0.08, (x, yb + 0.35, SLAB), seg=6)
    kit.box("Red", (0.4, 1.0, 0.16), (0.8, 0.6, SLAB))
    kit.box_between("Metal_Dark", (0.8, 1.05, SLAB + 0.12), (0.8, 2.1, SLAB + 0.75), 0.05, 0.05)
    # compressor tank
    kit.cyl("Blue_Pale", 0.28, 1.0, (0.9, yb + 0.5, SLAB + 0.35), (0, 90, 0), seg=10)
    kit.box("Metal_Dark", (0.4, 0.3, 0.3), (0.9, yb + 0.5, SLAB + 0.68))
    # tyre rack against the back wall, right bay: two shelves of standing tyres
    rx0, rx1 = 3.0, 6.2
    for x in (rx0, (rx0 + rx1) / 2, rx1):
        for y in (yb + 0.05, yb + 0.7):
            kit.box("Galvanized", (0.07, 0.07, 2.2), (x, y, SLAB), color=METAL)
    for z in (0.3, 1.25):
        for y in (yb + 0.05, yb + 0.7):
            kit.box_between("Galvanized", (rx0, y, SLAB + z), (rx1, y, SLAB + z), 0.06, 0.06)
    for row, z in enumerate((0.34, 1.29)):
        for k in range(6):
            tyre_standing(kit, Vector((rx0 + 0.3 + k * 0.52, yb + 0.38, SLAB + z)), yaw=r.uniform(-6, 6),
                          lean=r.uniform(-4, 4))
    # tyre stacks and drums at the right front corner
    for (cx, cy), n in (((5.9, 1.9), 4), ((5.1, 2.6), 3)):
        for i in range(n):
            tyre_lying(kit, Vector((cx + 0.02 * (i % 2), cy, SLAB + i * 0.22)), yaw=i * 13)
    for (dx, dy), mat in (((6.1, 0.4), "Blue"), ((5.5, -0.2), "Red"), ((6.2, -0.8), "Yellow_Sign")):
        drum(kit, Vector((dx, dy, SLAB)), mat)
    # a hanging banner and a chequered flag on the back wall
    kit.cbox("White", (4.3, 0.03, 0.82), (1.2, yb + 0.04, 3.2))
    kit.cbox("Banner_Pink", (4.1, 0.05, 0.64), (1.2, yb + 0.05, 3.2))
    kit.text("Banner_Ink", "SAKURA RALLY", 0.34, 0.02, facing((1.45, yb + 0.09, 3.2), "front"), FONT, resolution=1)
    kit.flower("White", facing((-0.5, yb + 0.085, 3.2), "front"), 0.24, "Banner_Rose")
    for i in range(4):
        for j in range(3):
            mat = "Ink" if (i + j) % 2 == 0 else "White"
            kit.cbox(mat, (0.22, 0.03, 0.22), (4.05 + i * 0.22, yb + 0.05, 2.95 + j * 0.22))
    # calendar / poster
    kit.cbox("Paper_White", (0.5, 0.03, 0.7), (-0.2, yb + 0.04, 2.1))
    kit.cbox("Blossom_Rose", (0.42, 0.04, 0.3), (-0.2, yb + 0.05, 2.25))


@prop("garage_nobori", "rally", ["roadside"], BOTH, cyl(0.06), 2000)
def garage_nobori(kit: Kit) -> None:
    """Tall service banner: weighted base, pole, pink cloth with 桜 and 整備 (reads from +Y and -Y)."""
    h = 4.4
    kit.cyl("Rubber", 0.28, 0.14, (0, 0, 0), seg=8)
    kit.cyl("Galvanized", 0.028, h, (0, 0, 0.14), seg=5, color=METAL)
    kit.cyl("Galvanized", 0.02, 0.72, (0.0, 0, h - 0.05), (0, 90, 0), seg=4)
    x0, x1, z0, z1 = 0.05, 0.72, 1.1, h - 0.06
    for f in ((0, 1, 2, 3), (3, 2, 1, 0)):
        kit.poly("Banner_Pink", [(x0, 0, z0), (x1, 0, z0), (x1, 0, z1), (x0, 0, z1)], [f], None, SOFT)
    for side, y in (("front", 0.012), ("back", -0.012)):
        m = 1 if side == "front" else -1
        kit.poly("White", [(x0, y, z1 - 0.1), (x1, y, z1 - 0.1), (x1, y, z1), (x0, y, z1)],
                 [(0, 1, 2, 3) if m < 0 else (3, 2, 1, 0)])
        kit.poly("Vermilion", [(x0, y, z0), (x1, y, z0), (x1, y, z0 + 0.14), (x0, y, z0 + 0.14)],
                 [(0, 1, 2, 3) if m < 0 else (3, 2, 1, 0)])
        xc = (x0 + x1) / 2
        _jp_char(kit, "Vermilion", "桜", 0.56, facing((xc, y * 1.5, z1 - 0.52), side))
        _jp_char(kit, "Banner_Ink", "整", 0.46, facing((xc, y * 1.5, z1 - 1.22), side))
        _jp_char(kit, "Banner_Ink", "備", 0.46, facing((xc, y * 1.5, z1 - 1.76), side))
        kit.flower("White", facing((xc, y * 1.6, z0 + 0.5), side), 0.16, "Banner_Rose")


@prop("garage_tyres", "rally", ["roadside"], BOTH, cyl(0.7), 2400)
def garage_tyres(kit: Kit) -> None:
    """Pile of worn tyres (two stacks, one leaning) and an oil drum, ~1.8 m across."""
    for i in range(4):
        tyre_lying(kit, Vector((-0.35 + 0.02 * (i % 2), 0.1, i * 0.22)), yaw=i * 17)
    for i in range(2):
        tyre_lying(kit, Vector((0.38, -0.25, i * 0.22)), yaw=i * 23)
    tyre_standing(kit, Vector((0.4, 0.45, 0.0)), yaw=20.0, lean=-14.0)
    drum(kit, Vector((0.95, 0.05, 0.0)), "Blue")
