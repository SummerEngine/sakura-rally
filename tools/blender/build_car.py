"""Sakura Rally - procedural low-poly rally car.

Builds the player car from code (no hand edits), exports
`assets/models/car/rally_car.glb` and saves `assets/models/car/rally_car.blend`.

Usage (from the project root):
    Blender --background --factory-startup --python tools/blender/build_car.py
    Blender --background --factory-startup --python tools/blender/build_car.py -- --render

`--render` additionally renders toon-style previews to `docs/renders/car_*.png`
(after the GLB/.blend are written, so previews never affect the exported asset).

Conventions (docs/CONTRACTS.md): Blender Z up, car front = +Y, right = +X,
origin at axle midpoint on the ground. Wheel objects have their origin at the wheel
centre with identity rotation; left wheels are geometrically mirrored so the rim
faces outward on both sides.
"""

import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from car_kit import (  # noqa: E402  (Blender runs this file as a script)
    DO_RENDER, FONT_BANNER, FONT_NUMBER, PREVIEW_VIEWS, ROOT, WHEELS, Y_AXLE_F, Y_AXLE_R,
    Curve, Greenhouse, Projector, add_box, add_cylinder, annulus_mesh, bevel_sharp_edges,
    build_caliper, build_materials, build_wheel, circle, export, fan_mesh, finalize, join_objects,
    loft, mirror_loop, prism, recess_glass, render_views, report, rot_x, rot_y, rounded_rect,
    sakura_outline, setup_render_scene, smoothstep, strip_mesh, text_mesh, toonify_materials,
)

# --------------------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------------------

GLB_PATH = os.path.join(ROOT, "assets", "models", "car", "rally_car.glb")
BLEND_PATH = os.path.join(ROOT, "assets", "models", "car", "rally_car.blend")

# --------------------------------------------------------------------------------------
# Body geometry
# --------------------------------------------------------------------------------------


Y_FRONT = 2.08          # front bumper face
Y_REAR = -2.06          # tailgate / rear bumper face
ARCH_R = 0.43           # wheel arch opening radius
ARCH_ZC = 0.30          # arch circle centre height
Z_SILL = 0.31
Z_FLOOR = 0.27
WELL_X = 0.60           # inner wall of the wheel wells

# --------------------------------------------------------------------------------------
# Materials
# --------------------------------------------------------------------------------------

# name: (hex, roughness, metallic, emission hex or None, emission strength)
MAT_SPECS = [
    ("Paint", "#f6f1e8", 0.35, 0.0, None, 0.0),
    ("Paint2", "#e8517c", 0.35, 0.0, None, 0.0),
    ("Trim", "#2c2a33", 0.7, 0.0, None, 0.0),
    ("Chrome", "#c9ccd6", 0.25, 0.8, None, 0.0),
    ("Glass", "#3b4760", 0.08, 0.0, None, 0.0),
    ("Rubber", "#35323b", 0.9, 0.0, None, 0.0),
    ("Rim", "#f2c552", 0.35, 0.3, None, 0.0),
    ("HeadLight", "#fff4dc", 0.2, 0.0, "#fff1d0", 2.0),
    ("TailLight", "#e0303a", 0.3, 0.0, "#ff2a36", 2.0),
    ("Decal_White", "#fbf8f2", 0.4, 0.0, None, 0.0),
    ("Number", "#2a2235", 0.5, 0.0, None, 0.0),
    ("Accent", "#f2873e", 0.45, 0.0, None, 0.0),  # tow hooks, brake calipers
]


def arch_z(y: float, r: float) -> float:
    """Height of an arch circle of radius r over either axle (or -1 outside)."""
    best = -1.0
    for yw in (Y_AXLE_F, Y_AXLE_R):
        d = y - yw
        if abs(d) < r:
            best = max(best, ARCH_ZC + math.sqrt(r * r - d * d))
    return best


# --------------------------------------------------------------------------------------
# Body shell (lofted lower body)
# --------------------------------------------------------------------------------------

ZTOP = Curve([(-2.06, 0.915), (-2.035, 0.955), (-2.0, 0.975), (-1.9, 0.98), (-1.3, 0.975),
              (0.62, 0.945), (1.0, 0.925), (1.27, 0.905), (1.72, 0.868), (1.93, 0.843),
              (2.02, 0.815), (2.06, 0.77), (2.08, 0.71)])
CROWN = Curve([(-2.06, 0.03), (-1.8, 0.03), (0.5, 0.03), (1.5, 0.035), (2.08, 0.02)])
WB = Curve([(-2.06, 0.80), (0.0, 0.81), (2.08, 0.80)])
KPLAN = Curve([(-2.06, 0.905), (-2.045, 0.94), (-2.02, 0.97), (-1.96, 0.995), (-1.85, 1.0),
               (1.85, 1.0), (1.97, 0.995), (2.035, 0.97), (2.065, 0.935), (2.08, 0.905)])
FLARE_WHEEL = 0.10
FLARE_DOOR = 0.03
DOOR_Y = (Y_AXLE_R + ARCH_R, Y_AXLE_F - ARCH_R)   # between the arches


def flare(y: float) -> float:
    if y >= Y_AXLE_F or y <= Y_AXLE_R:
        return FLARE_WHEEL
    t = max(smoothstep(0.78, 0.55, Y_AXLE_F - y), smoothstep(0.78, 0.55, y - Y_AXLE_R))
    return FLARE_DOOR + (FLARE_WHEEL - FLARE_DOOR) * t


def body_stations():
    ys = [2.08, 2.074, 2.06, 2.035, 2.0, 1.95, 1.88, 1.80]
    n = 14
    ys += [Y_AXLE_F + ARCH_R * math.cos(math.pi * k / n) for k in range(n + 1)]
    ys += [0.72, 0.62, 0.49, 0.30, 0.10, -0.10, -0.30, -0.50, -0.63, -0.73]
    ys += [Y_AXLE_R + ARCH_R * math.cos(math.pi * k / n) for k in range(n + 1)]
    ys += [-1.80, -1.87, -1.93, -1.98, -2.02, -2.045, -2.06]
    return ys


def section(y: float):
    """Right-half profile P0..P11 as (x, z)."""
    ztp = ZTOP(y)
    cr = CROWN(y)
    w = WB(y)
    f = flare(y)
    k = KPLAN(y)
    zsh = ztp - cr - 0.012
    zfl = max(0.60, arch_z(y, ARCH_R + 0.065))
    zfl = min(zfl, zsh - 0.065)
    zu = min(zfl + 0.035, zsh - 0.025)
    zlow = max(Z_SILL, arch_z(y, ARCH_R))
    zlow = min(zlow, zfl - 0.045)
    return [
        (0.0, ztp),
        (k * 0.5 * w, ztp - 0.25 * cr),
        (k * 0.86 * w, ztp - 0.74 * cr),
        (k * w, zsh),
        (k * (w + 0.012), zu),
        (k * (w + f), zfl),
        (k * (w + f + 0.004), zfl - 0.62 * (zfl - zlow)),
        (k * (w + f - 0.012), zlow + 0.022),
        (k * (w + f - 0.035), zlow),
        (WELL_X, zlow),
        (WELL_X, Z_FLOOR),
        (0.0, Z_FLOOR),
    ]


def body_top_z(x: float, y: float) -> float:
    """Approximate height of the body's top surface (for seating the greenhouse)."""
    w = WB(y) * KPLAN(y)
    t = min(1.0, abs(x) / w)
    return ZTOP(y) - CROWN(y) * t * t


def build_shell():
    ys = body_stations()
    rings = []
    for y in ys:
        prof = section(y)
        right = [Vector((x, y, z)) for (x, z) in prof]
        left = [Vector((-x, y, z)) for (x, z) in reversed(prof[1:-1])]
        rings.append(right + left)

    def seg_of(j):
        return j if j <= 10 else 21 - j

    def mat_fn(a, j):
        s = seg_of(j)
        ymid = 0.5 * (ys[a] + ys[a + 1])
        if s >= 7:
            return "Trim"
        if s == 6 and DOOR_Y[0] < ymid < DOOR_Y[1]:
            return "Trim"
        return "Paint"

    bm = bmesh.new()
    loft(bm, rings, closed=True, cap_start=True, cap_end=True, mat_fn=mat_fn, cap_mat="Paint")
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return bm


# --------------------------------------------------------------------------------------
# Greenhouse (cabin) - vertical loft of plan-view rings
# --------------------------------------------------------------------------------------


GH_RING0 = [(0.0, 0.90), (0.40, 0.882), (0.68, 0.82), (0.765, 0.74), (0.775, 0.25), (0.775, -0.45),
            (0.775, -1.15), (0.765, -1.62), (0.67, -1.83), (0.40, -1.895), (0.0, -1.91)]
GH_RING1 = [(0.0, 0.14), (0.36, 0.128), (0.56, 0.095), (0.625, 0.03), (0.635, -0.20),
            (0.635, -0.58), (0.635, -1.04), (0.625, -1.28), (0.56, -1.355), (0.36, -1.39), (0.0, -1.40)]
GH_Z1 = 1.345
GH_Z2 = 1.385
GH_SINK = 0.035
ROOF_YC = -0.70


def roof_ring(pts):
    return [Vector((p.x * 0.84, ROOF_YC + (p.y - ROOF_YC) * 0.93, GH_Z2)) for p in pts]


def gh_rings():
    r0 = [Vector((x, y, body_top_z(x, y) - GH_SINK)) for (x, y) in mirror_loop(GH_RING0)]
    r1 = [Vector((x, y, GH_Z1)) for (x, y) in mirror_loop(GH_RING1)]
    return r0, r1


WINDOWS = [
    # (t_start, t_end, inset_start, inset_end) along the greenhouse loop (metres of pillar)
    (17.0, 23.0, 0.045, 0.045),     # windscreen
    (3.0, 5.0, 0.04, 0.025),        # right door glass
    (5.0, 7.0, 0.025, 0.05),        # right rear quarter glass
    (7.0, 13.0, 0.05, 0.05),        # rear hatch glass
    (13.0, 15.0, 0.05, 0.025),      # left rear quarter glass
    (15.0, 17.0, 0.025, 0.04),      # left door glass
]
GH_ROWS = [0.0, 0.13, 0.77, 0.925, 1.0]      # v along the pillar (ring0 -> ring1)
GLASS_BANDS = (1, 2)                          # row bands that are glass inside a window
BANNER_BAND = 2                               # on the windscreen this band is the sun strip
GLASS_INSET = 0.013
GLASS_DEPTH = 0.009


def build_greenhouse():
    r0, r1 = gh_rings()

    def mat_fn(a, w):
        if a >= len(GH_ROWS) - 1:
            return "Paint2"
        if w >= 0 and a in GLASS_BANDS:
            return "Paint2" if (w == 0 and a == BANNER_BAND) else "Glass"
        return "Paint"

    gh = Greenhouse(r0, r1, WINDOWS, GH_ROWS, roof_ring, scale1=0.8)
    return gh.build(mat_fn, "Paint2", Vector((0.0, -0.6, 1.0)))


# --------------------------------------------------------------------------------------
# Body detail parts
# --------------------------------------------------------------------------------------


def build_light_pod(bm):
    z = 0.60
    add_box(bm, (0.98, 0.07, 0.11), (0.0, 2.085, z), "Trim")
    for x in (-0.395, -0.135, 0.135, 0.395):
        m = Matrix.Translation((x, 2.115, z)) @ rot_x(-math.pi / 2).to_4x4()
        add_cylinder(bm, 0.074, 0.075, 16, "Trim", m)
        m = Matrix.Translation((x, 2.157, z)) @ rot_x(-math.pi / 2).to_4x4()
        add_cylinder(bm, 0.069, 0.012, 16, "Chrome", m)
        m = Matrix.Translation((x, 2.164, z)) @ rot_x(-math.pi / 2).to_4x4()
        add_cylinder(bm, 0.057, 0.006, 16, "HeadLight", m, radius2=0.052)


def build_splitter(bm):
    poly = [(-0.84, 1.96), (0.84, 1.96), (0.84, 2.07), (0.76, 2.135), (-0.76, 2.135), (-0.84, 2.07)]
    prism(bm, poly, 0.028, lambda u, v, w: Vector((u, v, 0.285 + w)), "Trim")


def build_rear_bumper(bm):
    poly = [(-0.86, -1.98), (-0.86, -2.07), (-0.80, -2.105), (0.80, -2.105), (0.86, -2.07), (0.86, -1.98)]
    prism(bm, list(reversed(poly)), 0.13, lambda u, v, w: Vector((u, v, 0.345 + w)), "Trim")


def build_mirrors(bm):
    for s in (1, -1):
        # stalk
        add_box(bm, (0.12, 0.05, 0.022), (s * 0.82, 0.675, 1.0), "Trim", rot=rot_y(-s * 0.22))
        # aerodynamic housing: loft of rounded sections along X
        rings = []
        for x, sc, dy in ((0.855, 0.70, 0.0), (0.885, 1.0, 0.0), (0.955, 1.0, -0.005), (0.975, 0.78, -0.01)):
            sec = rounded_rect(0.09 * sc, 0.085 * sc, 0.025 * sc, 2)
            rings.append([Vector((s * x, 0.665 + dy + u * 0.8, 1.035 + v)) for (u, v) in sec])
        if s < 0:
            rings = [list(reversed(r)) for r in rings]
        loft(bm, rings, closed=True, cap_start=True, cap_end=True, mat_fn=lambda a, j: "Paint2",
             cap_mat="Paint2")
        # mirror glass on the rear face
        glass = rounded_rect(0.075, 0.06, 0.015, 2)
        prism(bm, glass, 0.006, lambda u, v, w, s=s: Vector((s * 0.92 + u, 0.628 + w, 1.035 + v)), "Chrome")


def build_roof_scoop(bm):
    z0 = GH_Z2 - 0.02
    prof = [(-0.02, z0), (-0.02, z0 + 0.075), (-0.06, z0 + 0.082), (-0.40, z0 + 0.02), (-0.40, z0)]
    # extrude profile (y, z) along X
    prism(bm, prof, 0.30, lambda u, v, w: Vector((w, u, v)), "Paint2")
    add_box(bm, (0.25, 0.012, 0.052), (0.0, -0.018, z0 + 0.045), "Trim")


def build_wing(bm):
    foil = [(0.17, 0.0), (0.158, 0.017), (0.11, 0.029), (0.02, 0.033), (-0.08, 0.025),
            (-0.17, 0.007), (-0.17, -0.002), (-0.08, 0.006), (0.02, 0.0), (0.11, -0.007),
            (0.158, -0.008)]
    aoa = math.radians(-9.0)
    ca, sa = math.cos(aoa), math.sin(aoa)
    yc, zc = -1.935, 1.25

    def foil3d(u, v, w):
        y = u * ca - v * sa
        z = u * sa + v * ca
        return Vector((w, yc + y, zc + z))

    prism(bm, list(reversed(foil)), 1.46, foil3d, "Paint")
    plate = [(0.18, -0.045), (0.18, 0.035), (0.12, 0.065), (-0.17, 0.085), (-0.205, 0.055), (-0.205, -0.06)]
    for s in (1, -1):
        prism(bm, plate, 0.014, lambda u, v, w, s=s: Vector((s * 0.737 + w, yc + u, zc + v)), "Paint2")
    for s in (1, -1):
        post = [(0.045, -0.29), (0.05, 0.0), (-0.05, 0.0), (-0.06, -0.29)]
        prism(bm, post, 0.018, lambda u, v, w, s=s: Vector((s * 0.46 + w, yc - 0.01 + u, zc + v)), "Trim")


def build_mudflaps(bm):
    for s in (1, -1):
        for y, top, bot, fw in ((Y_AXLE_F - ARCH_R - 0.035, 0.40, 0.12, 0.23),
                                (Y_AXLE_R - ARCH_R - 0.03, 0.44, 0.08, 0.25)):
            xo = 0.885
            poly = [(xo - fw, bot), (xo, bot + 0.01), (xo - 0.005, top), (xo - fw, top)]
            prism(bm, poly, 0.014, lambda u, v, w, s=s, y=y: Vector((s * u, y + w, v)), "Paint2")


def build_tow_hooks(bm):
    def hook(center, facing, xs):
        segs = 10
        ro, ri, th = 0.052, 0.032, 0.018
        # annulus loop in the (facing, z) plane, half buried in the bumper
        ring_o, ring_i = [], []
        for k in range(segs + 1):
            a = -math.pi / 2 + math.pi * k / segs
            d_o = Vector((0.0, facing * math.cos(a) * ro, math.sin(a) * ro))
            d_i = Vector((0.0, facing * math.cos(a) * ri, math.sin(a) * ri))
            ring_o.append(d_o)
            ring_i.append(d_i)
        pts = ring_o + list(reversed(ring_i))
        # buried legs so the loop reads as bolted on
        pts = [Vector((0, -facing * 0.04, -ro))] + pts + [Vector((0, -facing * 0.04, -ri))]
        poly = [(p.y, p.z) for p in pts]
        prism(bm, poly, th, lambda u, v, w: Vector((xs + w, center.y + u, center.z + v)), "Accent")

    hook(Vector((0.0, 2.125, 0.33)), 1.0, 0.52)
    hook(Vector((0.0, -2.10, 0.47)), -1.0, -0.52)


def build_exhaust(bm):
    m = Matrix.Translation((0.52, -2.06, 0.315)) @ rot_x(math.pi / 2).to_4x4()
    add_cylinder(bm, 0.05, 0.16, 12, "Chrome", m)
    m = Matrix.Translation((0.52, -2.141, 0.315)) @ rot_x(math.pi / 2).to_4x4()
    add_cylinder(bm, 0.037, 0.004, 12, "Trim", m)


def build_antenna(bm):
    base = Vector((-0.34, -1.22, GH_Z2 - 0.004))
    m = Matrix.Translation(base + Vector((0, 0, 0.012))) @ rot_x(0.0).to_4x4()
    add_cylinder(bm, 0.018, 0.024, 8, "Trim", m, radius2=0.012)
    tilt = rot_x(math.radians(-24)).to_4x4()
    m = Matrix.Translation(base + Vector((0, 0, 0.02))) @ tilt @ Matrix.Translation((0, 0, 0.09))
    add_cylinder(bm, 0.0045, 0.18, 6, "Trim", m, radius2=0.0025)


def build_well_liners(bm):
    """Dark arch liners so you never see daylight through the wheel wells."""
    for yw in (Y_AXLE_F, Y_AXLE_R):
        for s in (1, -1):
            pts = [(yw + (ARCH_R + 0.005) * math.cos(math.pi * k / 12),
                    ARCH_ZC + (ARCH_R + 0.005) * math.sin(math.pi * k / 12)) for k in range(13)]
            prism(bm, pts, 0.01, lambda u, v, w, s=s: Vector((s * (WELL_X + 0.006 + w), u, v)), "Trim")


# --------------------------------------------------------------------------------------
# Livery / decals
# --------------------------------------------------------------------------------------


# Side swoosh: low along the door flare, crossing the (shallow) door ledge mid-door, then
# rising over the rear arch on the vertical panel above the flare.
STRIPE = [(0.84, 0.47, 0.02), (0.55, 0.475, 0.06), (0.20, 0.50, 0.095), (-0.15, 0.60, 0.11),
          (-0.45, 0.72, 0.11), (-0.75, 0.79, 0.09), (-1.00, 0.85, 0.06), (-1.25, 0.888, 0.032),
          (-1.50, 0.90, 0.0)]
PIN = [(0.74, 0.545, 0.0), (0.45, 0.55, 0.012), (0.10, 0.58, 0.014), (-0.20, 0.675, 0.014),
       (-0.50, 0.79, 0.012), (-0.72, 0.848, 0.009), (-0.92, 0.89, 0.0)]
ROUNDEL = (0.13, 0.76, 0.135)      # y, z, radius on each door


def side_to3d(sign):
    return lambda u, v: Vector((sign * 1.4, u, v))


def build_side_decals(bm, proj):
    for s in (1, -1):
        d = Vector((-s, 0, 0))
        to3d = side_to3d(s)
        vs, fs = strip_mesh(STRIPE, samples=90, across=4)
        proj.decal(bm, vs, fs, to3d, d, 0.005, "Paint2", "stripe")
        vs, fs = strip_mesh(PIN, samples=60, across=2)
        proj.decal(bm, vs, fs, to3d, d, 0.005, "Paint2", "pinstripe")
        # door roundel + number
        y, z, r = ROUNDEL
        vs, fs = annulus_mesh(r + 0.014, r, 32)
        proj.decal(bm, vs, fs, lambda u, v, s=s: Vector((s * 1.4, y + u, z + v)), d, 0.004,
                   "Number", "roundel border")
        vs, fs = fan_mesh(circle(r, 32), rings=3)
        proj.decal(bm, vs, fs, lambda u, v, s=s: Vector((s * 1.4, y + u, z + v)), d, 0.004,
                   "Decal_White", "roundel")
        tv, tf = text_mesh("07", 0.17, FONT_NUMBER)
        proj.decal(bm, tv, tf, lambda u, v, s=s: Vector((s * 1.4, y + s * u, z + v)), d, 0.0055,
                   "Number", "door number")
        # door shut lines and handle
        for yl in (0.72, -0.47):
            line = [(yl, 0.90, 0.006), (yl + 0.004, 0.66, 0.006), (yl + 0.006, 0.44, 0.006)]
            vs, fs = strip_mesh(line, samples=16, across=2)
            proj.decal(bm, vs, fs, to3d, d, 0.0045, "Trim", "door line")
        vs, fs = fan_mesh(rounded_rect(0.10, 0.024, 0.01, 2), rings=1)
        proj.decal(bm, vs, fs, lambda u, v, s=s: Vector((s * 1.4, -0.34 + u, 0.85 + v)), d, 0.004,
                   "Trim", "handle")
    # fuel filler (right rear quarter)
    vs, fs = fan_mesh(circle(0.042, 16), rings=2)
    proj.decal(bm, vs, fs, lambda u, v: Vector((1.4, -1.62 + u, 0.88 + v)), Vector((-1, 0, 0)),
               0.004, "Chrome", "fuel cap")


def top_to3d(u, v):
    return Vector((u, v, 3.0))


def build_top_decals(bm, proj):
    down = Vector((0, 0, -1))
    # bonnet sakura
    for (x, y, r, rot) in ((0.25, 1.62, 0.19, 0.25), (-0.03, 1.36, 0.075, -0.4)):
        vs, fs = fan_mesh(sakura_outline(r, 10, rot), rings=3)
        proj.decal(bm, vs, fs, lambda u, v, x=x, y=y: Vector((x + u, y + v, 3.0)), down, 0.003,
                   "Paint2", "sakura")
        vs, fs = fan_mesh(circle(r * 0.22, 12), rings=1)
        proj.decal(bm, vs, fs, lambda u, v, x=x, y=y: Vector((x + u, y + v, 3.0)), down, 0.0045,
                   "Decal_White", "sakura centre")
    # bonnet vents: dark recess with painted louvres
    for s in (1, -1):
        cx, cy = s * 0.36, 1.12
        vs, fs = fan_mesh(rounded_rect(0.22, 0.16, 0.025, 2), rings=2)
        proj.decal(bm, vs, fs, lambda u, v: Vector((cx + u, cy + v, 3.0)), down, 0.003, "Trim", "vent")
        for k in range(4):
            ly = cy - 0.057 + k * 0.038
            vs, fs = strip_mesh([(cx - 0.092, ly, 0.014), (cx, ly, 0.014), (cx + 0.092, ly, 0.014)],
                                samples=6, across=2)
            proj.decal(bm, vs, fs, top_to3d, down, 0.006, "Paint", "louvre")


def build_front_decals(bm, proj):
    back = Vector((0, -1, 0))

    def front3d(u, v):
        return Vector((u, 3.0, v))

    # grille on the nose behind the light pod
    vs, fs = fan_mesh(rounded_rect(1.02, 0.15, 0.03, 2), rings=2)
    proj.decal(bm, vs, fs, lambda u, v: Vector((u, 3.0, 0.61 + v)), back, 0.003, "Trim", "grille")
    # headlights (slanted "eyes")
    for s in (1, -1):
        eye = [(0.54, 0.56), (0.75, 0.56), (0.765, 0.65), (0.615, 0.662), (0.535, 0.625)]
        cx = sum(p[0] for p in eye) / len(eye)
        cz = sum(p[1] for p in eye) / len(eye)
        outline = [(s * (p[0] - cx), p[1] - cz) for p in eye]
        if s < 0:
            outline.reverse()
        rim = [(u * 1.14, v * 1.40) for (u, v) in outline]
        vs, fs = fan_mesh(rim, rings=2)
        proj.decal(bm, vs, fs, lambda u, v, s=s: Vector((s * cx + u, 3.0, cz + v)), back, 0.003,
                   "Trim", "headlight surround")
        vs, fs = fan_mesh(outline, rings=2)
        proj.decal(bm, vs, fs, lambda u, v, s=s: Vector((s * cx + u, 3.0, cz + v)), back, 0.005,
                   "HeadLight", "headlight")
    # lower intake
    mouth = [(-0.44, 0.47), (-0.52, 0.41), (-0.48, 0.355), (0.48, 0.355), (0.52, 0.41), (0.44, 0.47)]
    mouth = [(u, v - 0.43) for (u, v) in reversed(mouth)]
    vs, fs = fan_mesh(list(reversed(mouth)), rings=2)
    proj.decal(bm, vs, fs, lambda u, v: Vector((u, 3.0, 0.43 + v)), back, 0.003, "Trim", "intake")
    # centre badge: small sakura on the nose lip above the light pod
    vs, fs = fan_mesh(sakura_outline(0.03, 8, 0.0), rings=2)
    proj.decal(bm, vs, fs, lambda u, v: Vector((u, 3.0, 0.505 + v)), back, 0.004, "Paint2", "badge")
    del front3d


def build_rear_decals(bm, proj):
    fwd = Vector((0, 1, 0))
    for s in (1, -1):
        vs, fs = fan_mesh(rounded_rect(0.28, 0.155, 0.035, 2), rings=2)
        proj.decal(bm, vs, fs, lambda u, v, s=s: Vector((s * 0.63 + u, -3.0, 0.79 + v)), fwd, 0.003,
                   "Trim", "taillight surround")
        vs, fs = fan_mesh(rounded_rect(0.25, 0.125, 0.025, 2), rings=2)
        proj.decal(bm, vs, fs, lambda u, v, s=s: Vector((s * 0.63 + u, -3.0, 0.79 + v)), fwd, 0.005,
                   "TailLight", "taillight")
        vs, fs = fan_mesh(rounded_rect(0.06, 0.07, 0.012, 2), rings=1)
        proj.decal(bm, vs, fs, lambda u, v, s=s: Vector((s * 0.545 + u, -3.0, 0.79 + v)), fwd, 0.007,
                   "HeadLight", "reverse light")
    vs, fs = fan_mesh(rounded_rect(0.72, 0.07, 0.02, 2), rings=1)
    proj.decal(bm, vs, fs, lambda u, v: Vector((u, -3.0, 0.79 + v)), fwd, 0.004, "Trim", "garnish")
    tv, tf = text_mesh("SAKURA", 0.10, FONT_BANNER, offset=0.0)
    proj.decal(bm, tv, tf, lambda u, v: Vector((u, -3.0, 0.63 + v)), fwd, 0.004, "Paint2", "rear text")


def build_roof_decals(bm, proj_gh):
    down = Vector((0, 0, -1))
    vs, fs = fan_mesh(circle(0.20, 32), rings=3)
    proj_gh.decal(bm, vs, fs, lambda u, v: Vector((u, -0.70 + v, 3.0)), down, 0.004, "Decal_White", "roof roundel")
    vs, fs = annulus_mesh(0.215, 0.20, 32)
    proj_gh.decal(bm, vs, fs, lambda u, v: Vector((u, -0.70 + v, 3.0)), down, 0.004, "Number", "roof roundel border")
    tv, tf = text_mesh("07", 0.25, FONT_NUMBER)
    # upright for the chase camera behind the car
    proj_gh.decal(bm, tv, tf, lambda u, v: Vector((u, -0.70 + v, 3.0)), down, 0.0055, "Number", "roof number")


def build_banner(bm, proj_gh):
    """White lettering on the pink sun strip across the top of the windscreen."""
    r0, r1 = gh_rings()
    v = 0.5 * (GH_ROWS[BANNER_BAND] + GH_ROWS[BANNER_BAND + 1])
    bottom = r0[0].lerp(r1[0], GH_ROWS[BANNER_BAND])
    top = r0[0].lerp(r1[0], GH_ROWS[BANNER_BAND + 1])
    centre = r0[0].lerp(r1[0], v)
    up = (top - bottom).normalized()
    right = Vector((-1.0, 0.0, 0.0))            # viewer's right when facing the car
    nrm = right.cross(up).normalized()
    if nrm.y < 0.0:
        nrm = -nrm
    tv, tf = text_mesh("SAKURA RALLY", 0.075, FONT_BANNER)
    proj_gh.decal(bm, tv, tf, lambda u, w: centre + right * u + up * w + nrm * 0.05, -nrm, 0.004,
                  "Decal_White", "banner text")


def build_mudflap_decals(bm, bm_parts):
    proj = Projector(bm_parts)
    fwd = Vector((0, 1, 0))
    for s in (1, -1):
        y = Y_AXLE_R - ARCH_R - 0.03
        vs, fs = fan_mesh(sakura_outline(0.06, 8, 0.0), rings=2)
        proj.decal(bm, vs, fs, lambda u, v, s=s, y=y: Vector((s * 0.765 + u, y - 0.3, 0.21 + v)), fwd,
                   0.003, "Decal_White", "mudflap sakura")


# --------------------------------------------------------------------------------------
# Assembly
# --------------------------------------------------------------------------------------


def build_car():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    build_materials(MAT_SPECS)

    # --- shell: build, bevel, keep a copy for decal projection
    bm_shell = build_shell()
    shell = finalize(bm_shell, "Body", bevel_angle=26.0, bevel_width=0.011, bevel_segments=2,
                     bevel_skip_mats=("Trim",))
    bm_shell_final = bmesh.new()
    bm_shell_final.from_mesh(shell.data)

    bm_gh = build_greenhouse()
    bevel_sharp_edges(bm_gh, 24.0, 0.012, 2)
    recess_glass(bm_gh, GLASS_INSET, GLASS_DEPTH)
    gh = finalize(bm_gh, "Body_Cabin", recalc=False)
    bm_gh_final = bmesh.new()
    bm_gh_final.from_mesh(gh.data)

    # --- hard parts
    bm_parts = bmesh.new()
    build_light_pod(bm_parts)
    build_splitter(bm_parts)
    build_rear_bumper(bm_parts)
    build_mirrors(bm_parts)
    build_roof_scoop(bm_parts)
    build_wing(bm_parts)
    build_mudflaps(bm_parts)
    build_tow_hooks(bm_parts)
    build_exhaust(bm_parts)
    build_antenna(bm_parts)
    build_well_liners(bm_parts)
    bm_parts_copy = bm_parts.copy()
    parts = finalize(bm_parts, "Body_Parts", bevel_angle=50.0, bevel_width=0.004, bevel_segments=1)

    # --- livery
    proj_shell = Projector(bm_shell_final)
    bm_decal = bmesh.new()
    build_side_decals(bm_decal, proj_shell)
    build_top_decals(bm_decal, proj_shell)
    build_front_decals(bm_decal, proj_shell)
    build_rear_decals(bm_decal, proj_shell)
    build_roof_decals(bm_decal, Projector(bm_gh_final))
    build_banner(bm_decal, Projector(bm_gh_final))
    bmesh.ops.recalc_face_normals(bm_parts_copy, faces=bm_parts_copy.faces)
    build_mudflap_decals(bm_decal, bm_parts_copy)
    decals = finalize(bm_decal, "Body_Livery", recalc=False)

    # --- join everything static into one Body mesh
    body = join_objects(shell, (gh, parts, decals), "Body")

    # --- wheels and calipers
    objs = [body]
    for key, c in WHEELS.items():
        side = 1 if c.x > 0 else -1
        objs.append(build_wheel("Wheel_" + key, c, side))
    for key, c in WHEELS.items():
        side = 1 if c.x > 0 else -1
        objs.append(build_caliper("Caliper_" + key, c, side))

    for bmx in (bm_shell_final, bm_gh_final, bm_parts_copy):
        bmx.free()
    return objs


def main():
    objs = build_car()
    report(objs)
    export(objs, GLB_PATH, BLEND_PATH)
    print(f"[car] exported {GLB_PATH}")
    if DO_RENDER:
        setup_render_scene()
        toonify_materials()
        render_views("car", PREVIEW_VIEWS)


main()
