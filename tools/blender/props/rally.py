"""Rally dressing: arches, gates, flags, barriers, boards, tent, marshal post."""
from __future__ import annotations

import math

import bmesh
from mathutils import Matrix, Vector

from .common import Kit, facing, grad_z, lerp_col, trs, underside
from .registry import BOTH, NONE, box, cyl, prop

FONT = "/System/Library/Fonts/Supplemental/Arial Black.ttf"
FONT_JP = "/Library/Fonts/Arial Unicode.ttf"
SOFT = underside()
METAL = grad_z(0.0, 6.0, (0.82, 0.82, 0.92))


def two_posts(offset: float, radius: float, height: float) -> dict:
    """Collision: two cylinders at x = ±offset (Godot coords), gap between them stays open."""
    return {"type": "cylinder", "radius": radius, "height": height,
            "offsets": [[-offset, 0.0, 0.0], [offset, 0.0, 0.0]]}


# ----------------------------------------------------------------------------------------
# Truss
# ----------------------------------------------------------------------------------------
def truss(kit: Kit, a: Vector, b: Vector, w: float, mat: str = "Galvanized", bay: float = 0.55,
          chord: float = 0.045, faces: tuple[int, ...] = (0, 1, 2, 3)) -> None:
    """Square box truss from a to b (w = chord spacing): 4 chords + zigzag lacing on `faces`."""
    d = b - a
    fwd = d.normalized()
    up = Vector((0, 0, 1)) if abs(fwd.z) < 0.9 else Vector((0, 1, 0))
    side = fwd.cross(up).normalized()
    up = side.cross(fwd).normalized()
    h = w / 2
    corners = [side * h + up * h, -side * h + up * h, -side * h - up * h, side * h - up * h]
    for c in corners:
        kit.box_between(mat, a + c, b + c, chord * 2, chord * 2, up, METAL)
    n = max(1, round(d.length / bay))
    for f in faces:
        c0, c1 = corners[f], corners[(f + 1) % 4]
        for i in range(n):
            p0 = a + d * (i / n)
            p1 = a + d * ((i + 1) / n)
            s, e = (c0, c1) if i % 2 == 0 else (c1, c0)
            kit.cyl_between(mat, p0 + s, p1 + e, chord * 0.6, seg=3, color=METAL, caps=False)


def _arch_frame(kit: Kit, span: float, H: float, tw: float) -> float:
    """Two truss towers + top truss beam; returns x of tower centres."""
    xt = span / 2 + tw / 2
    for sx in (-1, 1):
        x = sx * xt
        kit.box("Concrete", (tw + 0.5, tw + 0.5, 0.35), (x, 0, 0), color=grad_z(0, 0.35, (0.85, 0.83, 0.9)))
        truss(kit, Vector((x, 0, 0.35)), Vector((x, 0, H)), tw)
        kit.cbox("Galvanized", (tw + 0.12, tw + 0.12, 0.12), (x, 0, H + 0.06), color=METAL)
    truss(kit, Vector((-xt - tw / 2, 0, H - tw / 2 - 0.05)), Vector((xt + tw / 2, 0, H - tw / 2 - 0.05)), tw,
          faces=(0, 1, 2, 3))
    return xt


def _banner(kit: Kit, w: float, h: float, zc: float, mat: str, trim: str) -> None:
    kit.cbox(trim, (w + 0.12, 0.05, h + 0.12), (0, 0, zc))
    kit.cbox(mat, (w, 0.08, h), (0, 0, zc))


def _banner_text(kit: Kit, body: str, size: float, zc: float, mat: str, depth: float = 0.03,
                 font: str = FONT, x: float = 0.0, spacing: float = 1.0) -> float:
    w = 0.0
    for side, y in (("front", 0.04 + depth / 2), ("back", -0.04 - depth / 2)):
        w, _ = kit.text(mat, body, size, depth, facing((x, y, zc), side), font, resolution=1, spacing=spacing)
    return w


@prop("start_arch", "rally", ["roadside"], BOTH, two_posts(5.05, 0.5, 6.4), 3000)
def start_arch(kit: Kit) -> None:
    """Start arch spanning a 9 m road (clear width 9.5 m, clear height 5.2 m)."""
    span, H, tw = 9.6, 6.2, 0.55
    xt = _arch_frame(kit, span, H, tw)
    zc = H - tw - 0.7
    _banner(kit, span, 1.05, zc, "Banner_Pink", "White")
    tw_ = _banner_text(kit, "SAKURA RALLY", 0.62, zc - 0.02, "Banner_Ink")
    for side, y in (("front", 0.045), ("back", -0.045)):
        for sx in (-1, 1):
            xf = sx * (tw_ / 2 + 0.75)
            kit.flower("White", facing((xf, y * 1.1, zc), side), 0.42, "Banner_Rose")
            kit.flower("Banner_Rose", facing((xf + sx * 0.95, y * 1.1, zc + 0.12), side), 0.26)
    # hanging lantern-coloured pennant string under the beam
    for i in range(12):
        x = -span / 2 + 0.45 + i * (span - 0.9) / 11
        z = zc - 0.62 - 0.18 * (1 - (x / (span / 2)) ** 2)
        mat = ("Banner_Pink", "White", "Vermilion")[i % 3]
        kit.poly(mat, [(x - 0.17, 0, z + 0.05), (x + 0.17, 0, z + 0.05), (x, 0, z - 0.3)], [(0, 1, 2)])
        kit.poly(mat, [(x - 0.17, 0, z + 0.05), (x + 0.17, 0, z + 0.05), (x, 0, z - 0.3)], [(2, 1, 0)])
    kit.tube("Rope", [Vector((x, 0, zc - 0.57 - 0.18 * (1 - (x / (span / 2)) ** 2))) for x in
                      [-span / 2 + i * span / 8 for i in range(9)]], [0.012] * 9, 3, cap_end=False)
    # tower sleeves with sponsor-like panels
    for sx in (-1, 1):
        x = sx * xt
        for side in (1, -1):
            kit.cbox("Banner_Pink" if sx < 0 else "White", (tw + 0.04, 0.04, 2.0), (x, side * (tw / 2 + 0.03), 2.1))
            kit.flower("Banner_Rose" if sx > 0 else "White",
                       facing((x, side * (tw / 2 + 0.055), 2.5), "front" if side > 0 else "back"), 0.2)


@prop("finish_arch", "rally", ["roadside"], BOTH, two_posts(5.05, 0.5, 6.4), 3000)
def finish_arch(kit: Kit) -> None:
    """Finish arch: same frame, chequered band + FINISH banner."""
    span, H, tw = 9.6, 6.2, 0.55
    xt = _arch_frame(kit, span, H, tw)
    bh = 1.5
    zc = H - tw - 0.95
    _banner(kit, span, bh, zc, "White", "Ink")
    n = 32
    cw = span / n
    for row, z in enumerate((zc + bh / 2 - cw / 2, zc - bh / 2 + cw / 2)):
        for i in range(n):
            if (i + row) % 2 == 0:
                kit.cbox("Ink", (cw, 0.1, cw), (-span / 2 + cw * (i + 0.5), 0, z))
    _banner_text(kit, "FINISH", 0.66, zc - 0.03, "Red_Dark", spacing=1.1)
    for side, y in (("front", 0.05), ("back", -0.05)):
        for sx in (-1, 1):
            kit.flower("Banner_Rose", facing((sx * 2.75, y * 1.05, zc), side), 0.34, "White")
            kit.flower("Banner_Pink", facing((sx * 3.6, y * 1.05, zc + 0.08), side), 0.22)
    for sx in (-1, 1):
        x = sx * xt
        for side in (1, -1):
            for k in range(6):
                if k % 2 == (0 if sx > 0 else 1):
                    kit.cbox("Ink", (tw + 0.04, 0.04, 0.3), (x, side * (tw / 2 + 0.03), 1.3 + k * 0.3))
                else:
                    kit.cbox("White", (tw + 0.04, 0.04, 0.3), (x, side * (tw / 2 + 0.03), 1.3 + k * 0.3))


def _nobori(kit: Kit, x: float, mat: str, accent: str, h: float = 4.6) -> None:
    """Tall feather-style flag on a pole with a weighted base."""
    kit.cyl("Rubber", 0.3, 0.15, (x, 0, 0), seg=8)
    kit.cyl("Galvanized", 0.03, h, (x, 0, 0.15), seg=5, color=METAL)
    # feather flag: curved leading edge, attached along the pole
    top = h + 0.1
    pts = [(0.03, 0.9), (0.03, top - 0.1), (0.35, top), (0.62, top - 0.35), (0.72, top - 1.2),
           (0.7, 1.6), (0.62, 0.9)]
    verts = [(x + px, 0.0, pz) for px, pz in pts]
    f = tuple(range(len(verts)))
    kit.poly(mat, verts, [f], None, SOFT)
    kit.poly(mat, verts, [tuple(reversed(f))], None, SOFT)
    stripe = [(x + 0.08, 0.004, 1.2), (x + 0.2, 0.004, 1.2), (x + 0.2, 0.004, top - 0.3), (x + 0.08, 0.004, top - 0.18)]
    kit.poly(accent, stripe, [(0, 1, 2, 3)])
    kit.poly(accent, [(p[0], -p[1], p[2]) for p in stripe], [(3, 2, 1, 0)])
    kit.flower(accent, trs((x + 0.45, 0.006, top - 1.2), (90, 0, 180)), 0.16)
    kit.flower(accent, trs((x + 0.45, -0.006, top - 1.2), (-90, 0, 0)), 0.16)


@prop("checkpoint_gate", "rally", ["roadside"], BOTH, two_posts(5.2, 0.3, 4.7), 1500)
def checkpoint_gate(kit: Kit) -> None:
    """Two tall feather flags 10.4 m apart, each with a small CP board at eye height."""
    for sx in (-1, 1):
        x = sx * 5.2
        _nobori(kit, x, "Banner_Pink", "White")
        kit.cbox("Vermilion", (0.5, 0.05, 0.36), (x - sx * 0.02, 0.07, 1.1))
        kit.cbox("White", (0.42, 0.06, 0.28), (x - sx * 0.02, 0.07, 1.1))
        for side, y in (("front", 0.115), ("back", 0.025)):
            kit.text("Banner_Ink", "CP", 0.2, 0.01, facing((x - sx * 0.02, y, 1.1), side), FONT, resolution=1)


def _flag_pole(kit: Kit, mat: str) -> None:
    """Tall pole with a triangular pennant rippling to +X."""
    kit.cyl("Concrete", 0.2, 0.12, (0, 0, 0), seg=8)
    kit.cyl("White", 0.035, 5.0, (0, 0, 0.12), seg=6, r_top=0.025)
    kit.cyl("Gold", 0.06, 0.08, (0, 0, 5.12), seg=6)
    L, H = 1.9, 0.9
    top = 4.95
    n = 5
    verts = []
    for i in range(n + 1):
        f = i / n
        x = 0.04 + L * f
        y = 0.12 * math.sin(f * math.pi * 1.5)
        half = H / 2 * (1 - f)
        zc = top - H / 2 - 0.08 * f
        verts += [(x, y, zc + half), (x, y, zc - half)]
    faces = []
    for i in range(n):
        o = i * 2
        faces.append((o, o + 1, o + 3, o + 2))
    shade = lambda co, nn: lerp_col((0.84, 0.82, 0.92), (1, 1, 1), abs(nn.y))
    kit.poly(mat, verts, faces, None, shade)
    kit.poly(mat, verts, [tuple(reversed(f)) for f in faces], None, shade)


@prop("flag_pole", "rally", ["roadside", "spectator_zone"], BOTH, cyl(0.1), 300)
def flag_pole(kit: Kit) -> None:
    _flag_pole(kit, "Vermilion")


@prop("flag_pole_pink", "rally", ["roadside", "spectator_zone"], BOTH, cyl(0.1), 300)
def flag_pole_pink(kit: Kit) -> None:
    _flag_pole(kit, "Banner_Pink")


@prop("flag_pole_blue", "rally", ["roadside", "spectator_zone"], BOTH, cyl(0.1), 300)
def flag_pole_blue(kit: Kit) -> None:
    _flag_pole(kit, "Cloth_Blue")


def _tyre(kit: Kit, c: Vector, band: str | None = None, yaw: float = 0.0) -> None:
    """Lying tyre (torus-like lathe of a rounded profile), outward-facing normals by construction."""
    seg = 10
    # (radius, z) profile, counter-clockwise around the tyre cross-section seen from outside
    prof = [(0.2, -0.09), (0.29, -0.11), (0.335, -0.05), (0.335, 0.05), (0.29, 0.11), (0.2, 0.09)]
    bm = bmesh.new()
    rings = []
    for k in range(seg):
        a = 2 * math.pi * k / seg + math.radians(yaw)
        rings.append([bm.verts.new((math.cos(a) * r, math.sin(a) * r, z)) for r, z in prof])
    n = len(prof)
    for k in range(seg):
        ra, rb = rings[k], rings[(k + 1) % seg]
        for j in range(n):
            bm.faces.new((ra[j], ra[(j + 1) % n], rb[(j + 1) % n], rb[j]))
    kit.add(bm, "Rubber" if band is None else (lambda cc, nn: band if nn.z > 0.3 else "Rubber"),
            Matrix.Translation(c + Vector((0, 0, 0.12))),
            lambda co, nn: lerp_col((0.8, 0.8, 0.9), (1, 1, 1), nn.z * 0.5 + 0.5))


@prop("tire_stack", "rally", ["roadside"], BOTH, cyl(0.36), 800)
def tire_stack(kit: Kit) -> None:
    """Barrier stack of 4 tyres, top one painted white, strapped."""
    for i in range(4):
        _tyre(kit, Vector((0.01 * (i % 2), 0.01 * (i % 3), i * 0.24)), "White" if i == 3 else None, yaw=i * 11)
    for a in (0, 180):
        kit.cbox("Vermilion", (0.05, 0.05, 0.96), (0.335 * math.cos(math.radians(a)), 0.335 * math.sin(math.radians(a)), 0.48))


@prop("hay_bale_round", "rally", ["roadside", "field"], BOTH, box(), 400)
def hay_bale_round(kit: Kit) -> None:
    """Round hay bale on its side (1.4 m diameter), with rolled face rings."""
    R, W = 0.7, 1.2
    seg = 12
    kit.cyl("Hay", R, W, (-W / 2, 0, R), (0, 90, 0), seg=seg, cap_bot=False, cap_top=False,
            color=lambda co, nn: lerp_col((0.8, 0.76, 0.84), (1, 1, 1), nn.z * 0.5 + 0.5))
    for sx in (-1, 1):
        for rr, mat, off in ((R, "Straw", 0.0), (R * 0.62, "Hay", 0.012), (R * 0.28, "Straw", 0.024)):
            ring = [(sx * (W / 2 + off), math.cos(2 * math.pi * k / seg) * rr, R + math.sin(2 * math.pi * k / seg) * rr)
                    for k in range(seg)]
            f = tuple(range(seg)) if sx > 0 else tuple(reversed(range(seg)))
            kit.poly(mat, ring, [f])
    for x in (-0.3, 0.3):  # net wrap bands
        kit.cyl("Hay_Wrap", R + 0.01, 0.06, (x, 0, R), (0, 90, 0), seg=seg, cap_bot=False, cap_top=False)


@prop("hay_bale_square", "rally", ["roadside", "field"], BOTH, box(), 300)
def hay_bale_square(kit: Kit) -> None:
    """Large square bale (1.6 x 0.9 x 0.8 m) with twine."""
    r = kit.r
    sh = lambda co, nn: lerp_col((0.8, 0.76, 0.84), (1, 1, 1), nn.z * 0.5 + 0.5)
    kit.box("Hay", (1.6, 0.9, 0.8), (0, 0, 0), color=sh)
    kit.box("Straw", (1.62, 0.84, 0.05), (0, 0, 0.78), color=sh)
    for x in (-0.45, 0.0, 0.45):
        kit.box("Rope", (0.03, 0.92, 0.82), (x + r.uniform(-0.03, 0.03), 0, -0.01))
    for sx in (-1, 1):  # loose straw tufts at the ends
        kit.cyl("Straw", 0.09, 0.14, (sx * 0.8, 0.2, 0.55), (0, sx * 90, 0), seg=4, r_top=0.0)
        kit.cyl("Straw", 0.07, 0.12, (sx * 0.8, -0.25, 0.3), (0, sx * 90, 0), seg=4, r_top=0.0)


@prop("traffic_cone", "rally", ["roadside"], BOTH, cyl(0.2), 200)
def traffic_cone(kit: Kit) -> None:
    kit.box("Orange", (0.4, 0.4, 0.04), (0, 0, 0))
    h = 0.7
    for i, (z0, z1, mat) in enumerate(((0.04, 0.3, "Orange"), (0.3, 0.42, "White"), (0.42, 0.52, "Orange"),
                                       (0.52, 0.6, "White"), (0.6, h, "Orange"))):
        r0 = 0.15 * (1 - (z0 - 0.04) / (h - 0.04)) + 0.03
        r1 = 0.15 * (1 - (z1 - 0.04) / (h - 0.04)) + 0.03
        kit.cyl(mat, r0, z1 - z0, (0, 0, z0), seg=8, r_top=r1, cap_bot=(i == 0), cap_top=(i == 4))


@prop("tape_post", "rally", ["roadside", "spectator_zone"], BOTH, two_posts(1.5, 0.06, 1.1), 300)
def tape_post(kit: Kit) -> None:
    """Two stakes 3 m apart with sagging red/white barrier tape (origin mid-span)."""
    for x in (-1.5, 1.5):
        kit.cyl("Wood_Pale", 0.04, 1.05, (x, 0, 0), seg=5)
        kit.cyl("Wood_Pale", 0.04, 0.08, (x, 0, 1.05), seg=5, r_top=0.0)
    for zt in (1.0, 0.55):
        n = 12
        for i in range(n):
            x0 = -1.5 + 3.0 * i / n
            x1 = -1.5 + 3.0 * (i + 1) / n
            z0 = zt - 0.1 * (1 - (x0 / 1.5) ** 2)
            z1 = zt - 0.1 * (1 - (x1 / 1.5) ** 2)
            mat = "Tape_Red" if i % 2 == 0 else "Tape_White"
            q = [(x0, 0.0, z0 + 0.04), (x1, 0.0, z1 + 0.04), (x1, 0.0, z1 - 0.04), (x0, 0.0, z0 - 0.04)]
            kit.poly(mat, q, [(3, 2, 1, 0)])
            kit.poly(mat, q, [(0, 1, 2, 3)])


@prop("tent", "rally", ["spectator_zone", "roadside"], BOTH, box(), 800)
def tent(kit: Kit) -> None:
    """3 x 3 m pop-up canopy: pink/white peaked roof, valance, table with cooler."""
    S, H = 3.0, 2.1
    for sx in (-1, 1):
        for sy in (-1, 1):
            kit.cyl("Galvanized", 0.03, H, (sx * S / 2, sy * S / 2, 0), seg=5)
            kit.box("Metal_Dark", (0.14, 0.14, 0.02), (sx * S / 2, sy * S / 2, 0))
    peak = H + 0.7
    for k in range(4):
        a0 = math.pi / 4 + k * math.pi / 2
        a1 = a0 + math.pi / 2
        c0 = (math.cos(a0) * S / math.sqrt(2) * 1.02, math.sin(a0) * S / math.sqrt(2) * 1.02, H)
        c1 = (math.cos(a1) * S / math.sqrt(2) * 1.02, math.sin(a1) * S / math.sqrt(2) * 1.02, H)
        mat = "Banner_Pink" if k % 2 == 0 else "White"
        kit.poly(mat, [c0, c1, (0, 0, peak)], [(0, 1, 2)], None, SOFT)
        kit.poly(mat, [c0, c1, (0, 0, peak)], [(2, 1, 0)], None, (0.8, 0.78, 0.9, 1))
        # valance (drop skirt)
        v = [c0, c1, (c1[0], c1[1], H - 0.25), (c0[0], c0[1], H - 0.25)]
        kit.poly(mat, v, [(3, 2, 1, 0)])
        kit.poly(mat, v, [(0, 1, 2, 3)])
    kit.flower("White", trs((0, S / 2 * 1.02 + 0.005, H - 0.125), (90, 0, 180)), 0.12)
    kit.box("White", (1.8, 0.7, 0.04), (0, -0.6, 0.72))
    for sx in (-1, 1):
        kit.box_between("Metal_Dark", (sx * 0.8, -0.9, 0), (sx * 0.8, -0.3, 0.72), 0.03, 0.03, (1, 0, 0))
        kit.box_between("Metal_Dark", (sx * 0.8, -0.3, 0), (sx * 0.8, -0.9, 0.72), 0.03, 0.03, (1, 0, 0))
    kit.box("Cloth_Blue", (0.5, 0.34, 0.32), (0.5, -0.6, 0.76))
    kit.box("White", (0.52, 0.36, 0.06), (0.5, -0.6, 1.06))
    kit.cyl("Cloth_Green", 0.04, 0.22, (-0.4, -0.55, 0.76), seg=6)
    kit.cyl("Red", 0.04, 0.22, (-0.25, -0.62, 0.76), seg=6)


@prop("marshal_post", "rally", ["roadside"], BOTH, box(), 800)
def marshal_post(kit: Kit) -> None:
    """Marshal station: numbered orange board, folding chair, extinguisher, yellow flag."""
    for x in (-0.45, 0.45):
        kit.cyl("Galvanized", 0.03, 1.8, (x, 0, 0), seg=5)
    kit.cbox("Orange", (1.1, 0.05, 0.7), (0, 0.03, 1.45))
    kit.cyl("White", 0.26, 0.02, (0, 0.06, 1.45), (-90, 0, 0), seg=12)
    kit.text("Ink", "7", 0.34, 0.012, facing((0, 0.075, 1.45), "front"), FONT, resolution=1)
    kit.text("Ink", "7", 0.34, 0.012, facing((0, -0.005, 1.45), "back"), FONT, resolution=1)
    # folding chair
    cx = 0.8
    kit.box("Cloth_Navy", (0.45, 0.42, 0.04), (cx, 0.5, 0.42))
    kit.cbox("Cloth_Navy", (0.45, 0.04, 0.4), (cx, 0.3, 0.68), (-10, 0, 0))
    for sx in (-1, 1):
        kit.box_between("Metal_Dark", (cx + sx * 0.2, 0.3, 0), (cx + sx * 0.2, 0.7, 0.42), 0.025, 0.025, (1, 0, 0))
        kit.box_between("Metal_Dark", (cx + sx * 0.2, 0.7, 0), (cx + sx * 0.2, 0.28, 0.9), 0.025, 0.025, (1, 0, 0))
    # extinguisher
    kit.cyl("Red", 0.08, 0.5, (-0.8, 0.35, 0), seg=8)
    kit.cyl("Metal_Dark", 0.035, 0.08, (-0.8, 0.35, 0.5), seg=6)
    kit.box_between("Ink", (-0.8, 0.35, 0.55), (-0.72, 0.42, 0.3), 0.02, 0.02, (0, 0, 1))
    # flag leaning on the board
    kit.cyl_between("Wood_Pale", (-0.62, 0.15, 0), (-0.5, 0.2, 1.3), 0.015, seg=4)
    kit.poly("Cloth_Yellow", [(-0.5, 0.2, 1.3), (-0.52, 0.19, 1.05), (-0.1, 0.3, 1.1), (-0.1, 0.3, 1.33)],
             [(0, 1, 2, 3)])
    kit.poly("Cloth_Yellow", [(-0.5, 0.2, 1.3), (-0.52, 0.19, 1.05), (-0.1, 0.3, 1.1), (-0.1, 0.3, 1.33)],
             [(3, 2, 1, 0)])


@prop("banner_fence", "rally", ["roadside", "spectator_zone"], BOTH,
      {"type": "box", "size": [3.0, 1.2, 0.1], "center": [0, 0.6, 0]}, 1500)
def banner_fence(kit: Kit) -> None:
    """3 m crowd fence with fabric banner: pink band, blossom motifs, SAKURA RALLY lettering."""
    for x in (-1.5, 0.0, 1.5):
        kit.cyl("Galvanized", 0.03, 1.2, (x, 0, 0), seg=5, color=METAL)
        kit.box("Metal_Dark", (0.12, 0.5, 0.04), (x, 0, 0))
    kit.cyl("Galvanized", 0.025, 3.0, (-1.5, 0, 1.18), (0, 90, 0), seg=5, color=METAL)
    kit.cbox("Banner_Pink", (3.0, 0.02, 0.8), (0, 0.04, 0.72))
    kit.cbox("White", (3.0, 0.025, 0.08), (0, 0.04, 1.06))
    kit.cbox("White", (3.0, 0.025, 0.08), (0, 0.04, 0.38))
    kit.text("Banner_Ink", "SAKURA RALLY", 0.26, 0.012, facing((0.25, 0.058, 0.72), "front"), FONT, resolution=1)
    kit.flower("White", facing((-1.15, 0.056, 0.72), "front"), 0.2, "Banner_Rose")
    kit.flower("Banner_Rose", facing((1.28, 0.056, 0.8), "front"), 0.14)
    kit.flower("White", facing((1.1, 0.056, 0.58), "front"), 0.1)


def _distance_board(kit: Kit, text: str) -> None:
    for x in (-0.5, 0.5):
        kit.cyl("Galvanized", 0.035, 1.7, (x, -0.04, 0), seg=5)
    kit.cbox("Red", (1.24, 0.05, 0.84), (0, 0, 1.25))
    kit.cbox("White", (1.12, 0.06, 0.72), (0, 0, 1.25))
    kit.text("Ink", text, 0.42, 0.012, facing((0, 0.036, 1.25), "front"), FONT, resolution=1)
    kit.cbox("Ink", (1.12, 0.062, 0.05), (0, 0, 1.0))


@prop("distance_board_100", "rally", ["roadside"], BOTH,
      {"type": "box", "size": [1.3, 1.7, 0.12], "center": [0, 0.85, 0]}, 400)
def distance_board_100(kit: Kit) -> None:
    _distance_board(kit, "100")


@prop("distance_board_50", "rally", ["roadside"], BOTH,
      {"type": "box", "size": [1.3, 1.7, 0.12], "center": [0, 0.85, 0]}, 400)
def distance_board_50(kit: Kit) -> None:
    _distance_board(kit, "50")
