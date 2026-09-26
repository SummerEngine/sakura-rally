"""Sakura Rally - Hayate 疾風, the second car: a low-poly 1980s rear-drive hatchback coupe.

Builds the car from code (no hand edits) and exports `assets/models/car/hayate.glb`.
Shares materials, helpers, wheels, calipers, export and preview renders with the Sakura
(`car_kit.py`); only the body, cabin, parts and livery are Hayate's own.

Usage (from the project root):
    Blender --background --factory-startup --python tools/blender/build_car_hayate.py
    Blender --background --factory-startup --python tools/blender/build_car_hayate.py -- --render

`--render` additionally renders toon-style previews to `docs/renders/car_hayate_*.png`,
including `car_hayate_front34_open.png` with the pop-up headlights raised.

Contract (docs/CONTRACTS.md, "Episode 2 / Car catalogue"): same chassis geometry and node /
material names as the Sakura. `PopUp_L` / `PopUp_R` are children of `Body` with identity rest
rotation and their origin on the hinge at the rear edge of each pod; they open by rotating
about their local +X by POPUP_OPEN_DEG (the front edge lifts).

Livery layout: `Paint` is the upper body, `Paint2` the lower-panel two-tone below the side
crease (plus bumpers, the windscreen sun strip and the hood gale streaks), `Number` the door and roof
number panels.
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
    Curve, Greenhouse, Projector, add_box, add_cylinder, bevel_sharp_edges, build_caliper,
    build_materials, build_wheel, circle, export, fan_mesh, finalize, join_objects, loft,
    mirror_loop, prism, recess_glass, render_views, report, rot_x, rounded_rect, setup_render_scene,
    smoothstep, strip_mesh, text_mesh, toonify_materials,
)

GLB_PATH = os.path.join(ROOT, "assets", "models", "car", "hayate.glb")
FONT_KANJI = "/System/Library/Fonts/ヒラギノ角ゴシック W8.ttc"

# --------------------------------------------------------------------------------------
# Body geometry (Blender axes: front +Y, right +X, up +Z)
# --------------------------------------------------------------------------------------

Y_FRONT = 2.01          # nose face
Y_REAR = -2.02          # tail panel
ARCH_R = 0.41           # wheel arch opening radius
ARCH_ZC = 0.31          # arch circle centre height
Z_SILL = 0.29
Z_FLOOR = 0.25
Z_CREASE = 0.60         # side character line; Paint2 two-tone below it
WELL_X = 0.60
FLARE_WHEEL = 0.07      # arch flare over the tyres

# --------------------------------------------------------------------------------------
# Materials
# --------------------------------------------------------------------------------------

# name: (hex, roughness, metallic, emission hex or None, emission strength)
MAT_SPECS = [
    ("Paint", "#f4f0e8", 0.35, 0.0, None, 0.0),
    ("Paint2", "#e44a30", 0.35, 0.0, None, 0.0),
    ("Trim", "#2c2a33", 0.7, 0.0, None, 0.0),
    ("Chrome", "#c9ccd6", 0.25, 0.8, None, 0.0),
    ("Glass", "#3b4760", 0.08, 0.0, None, 0.0),
    ("Rubber", "#35323b", 0.9, 0.0, None, 0.0),
    ("Rim", "#d9d4c8", 0.35, 0.3, None, 0.0),
    ("HeadLight", "#fff4dc", 0.2, 0.0, "#fff1d0", 2.0),
    ("TailLight", "#e0303a", 0.3, 0.0, "#ff2a36", 2.0),
    ("Decal_White", "#fbf8f2", 0.4, 0.0, None, 0.0),
    ("Number", "#2a2235", 0.5, 0.0, None, 0.0),
    ("Accent", "#f2c552", 0.45, 0.0, None, 0.0),  # tow hooks, brake calipers, indicators
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

# centre-line top: low nose rolling into a long flat hood, belt rising gently to a ducktail
ZTOP = Curve([(-2.02, 0.80), (-2.01, 0.855), (-1.985, 0.895), (-1.93, 0.915), (-1.85, 0.91),
              (-1.75, 0.90), (-1.2, 0.885), (-0.4, 0.87), (0.55, 0.85), (1.0, 0.83), (1.27, 0.815),
              (1.55, 0.795), (1.75, 0.775), (1.88, 0.745), (1.95, 0.715), (1.985, 0.675),
              (2.005, 0.62), (2.01, 0.575)])
CROWN = Curve([(-2.02, 0.02), (0.0, 0.02), (2.01, 0.018)])
WB = Curve([(-2.02, 0.835), (-1.0, 0.845), (0.0, 0.845), (1.3, 0.84), (2.01, 0.825)])
KPLAN = Curve([(-2.02, 0.90), (-2.01, 0.945), (-1.985, 0.975), (-1.92, 0.995), (-1.83, 1.0),
               (1.81, 1.0), (1.91, 0.99), (1.97, 0.965), (2.0, 0.935), (2.01, 0.905)])


def flare(y: float) -> float:
    d = min(abs(y - Y_AXLE_F), abs(y - Y_AXLE_R))
    return FLARE_WHEEL * smoothstep(0.62, 0.36, d)


def body_stations():
    ys = [2.01, 2.005, 1.995, 1.98, 1.95, 1.91, 1.85, 1.78, 1.72]
    n = 14
    ys += [Y_AXLE_F + ARCH_R * math.cos(math.pi * k / n) for k in range(n + 1)]
    ys += [0.80, 0.70, 0.56, 0.40, 0.20, 0.0, -0.20, -0.42, -0.58, -0.72, -0.82]
    ys += [Y_AXLE_R + ARCH_R * math.cos(math.pi * k / n) for k in range(n + 1)]
    ys += [-1.73, -1.80, -1.86, -1.92, -1.965, -1.995, -2.012, -2.02]
    return ys


def section(y: float):
    """Right-half profile P0..P11 as (x, z): hood/deck top, crisp shoulder, side panel
    widest at the character crease (flared into a lip over the wheels), tucked sill."""
    ztp = ZTOP(y)
    cr = CROWN(y)
    k = KPLAN(y)
    w = WB(y) * k
    f = flare(y) * k
    zsh = ztp - cr - 0.012
    zcr = min(max(Z_CREASE, arch_z(y, ARCH_R + 0.035)), zsh - 0.03)
    z4 = zsh - 0.4 * (zsh - zcr)
    zlow = min(max(Z_SILL, arch_z(y, ARCH_R)), zcr - 0.02)
    z6 = zcr - 0.55 * (zcr - zlow)
    z7 = zlow + min(0.03, 0.3 * (zcr - zlow))
    return [
        (0.0, ztp),
        (0.5 * w, ztp - 0.25 * cr),
        (0.86 * w, ztp - 0.74 * cr),
        (w, zsh),
        (w + 0.010, z4),
        (w + 0.018 + f, zcr),
        (w + 0.012 + f, z6),
        (w - 0.004 + 0.9 * f, z7),
        (w - 0.03 + 0.8 * f, zlow),
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

    def mat_fn(a, j):
        s = j if j <= 10 else 21 - j
        if s >= 7:
            return "Trim"
        if s >= 5:
            return "Paint2"
        return "Paint"

    bm = bmesh.new()
    loft(bm, rings, closed=True, cap_start=True, cap_end=True, mat_fn=mat_fn, cap_mat="Paint")
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return bm


# --------------------------------------------------------------------------------------
# Greenhouse: raked windscreen, thin pillars, fastback hatch
# --------------------------------------------------------------------------------------

GH_RING0 = [(0.0, 0.60), (0.40, 0.585), (0.66, 0.53), (0.78, 0.44), (0.80, 0.08), (0.80, -0.42),
            (0.80, -0.95), (0.785, -1.40), (0.70, -1.65), (0.42, -1.735), (0.0, -1.755)]
GH_RING1 = [(0.0, -0.17), (0.36, -0.182), (0.56, -0.215), (0.625, -0.27), (0.635, -0.40),
            (0.64, -0.60), (0.64, -0.82), (0.63, -0.99), (0.56, -1.055), (0.36, -1.08), (0.0, -1.09)]
GH_Z1 = 1.212
GH_Z2 = 1.24
GH_SINK = 0.03
ROOF_YC = -0.62

WINDOWS = [
    # (t_start, t_end, inset_start, inset_end) along the greenhouse loop (metres of pillar)
    (17.0, 23.0, 0.034, 0.034),     # windscreen (thin A pillars)
    (3.0, 5.0, 0.03, 0.016),        # right door glass
    (5.0, 7.0, 0.016, 0.055),       # right rear quarter glass
    (7.0, 13.0, 0.045, 0.045),      # hatch glass
    (13.0, 15.0, 0.055, 0.016),     # left rear quarter glass
    (15.0, 17.0, 0.016, 0.03),      # left door glass
]
GH_ROWS = [0.0, 0.11, 0.79, 0.925, 1.0]      # v along the pillar (ring0 -> ring1)
GLASS_BANDS = (1, 2)
BANNER_BAND = 2                               # on the windscreen this band is the sun strip
GLASS_INSET = 0.012
GLASS_DEPTH = 0.009


def roof_ring(pts):
    return [Vector((p.x * 0.88, ROOF_YC + (p.y - ROOF_YC) * 0.95, GH_Z2)) for p in pts]


def gh_rings():
    r0 = [Vector((x, y, body_top_z(x, y) - GH_SINK)) for (x, y) in mirror_loop(GH_RING0)]
    r1 = [Vector((x, y, GH_Z1)) for (x, y) in mirror_loop(GH_RING1)]
    return r0, r1


def build_greenhouse():
    r0, r1 = gh_rings()

    def mat_fn(a, w):
        if w >= 0 and a in GLASS_BANDS:
            return "Paint2" if (w == 0 and a == BANNER_BAND) else "Glass"
        return "Paint"

    gh = Greenhouse(r0, r1, WINDOWS, GH_ROWS, roof_ring, scale1=0.8)
    return gh.build(mat_fn, "Paint", Vector((0.0, -0.5, 0.95)))


# --------------------------------------------------------------------------------------
# Pop-up headlights (separate nodes, children of Body)
# --------------------------------------------------------------------------------------

POPUP_X = 0.555         # pod centre |x|
POPUP_HALF_W = 0.165
POPUP_Y = (1.54, 1.83)  # hinge (rear edge) .. front edge of the lid
POPUP_LIFT = 0.007      # lid clearance over the hood
POPUP_LID_STEPS = 4     # lid sections along y, so the lid follows the hood's curve
POPUP_HINGE_DROP = 0.02  # hinge axis below the lid's rear edge
POPUP_OPEN_DEG = 55.0
POPUP_FACE = 0.15       # length of the lamp face (along the face plane)


def popup_hinge(proj, s):
    y0 = POPUP_Y[0]
    loc, _ = proj.hit(Vector((s * POPUP_X, y0, 3.0)), Vector((0, 0, -1)))
    return Vector((s * POPUP_X, y0, loc.z + POPUP_LIFT - POPUP_HINGE_DROP))


def build_popup(name, proj, s):
    """Pod = Paint lid flush with the hood, Trim housing below it and a lamp on the front face.
    The front face points forward-down by POPUP_OPEN_DEG at rest, so it faces straight ahead
    once the pod is raised by that angle about the hinge."""
    a = math.radians(POPUP_OPEN_DEG)
    d = Vector((0.0, -math.sin(a), -math.cos(a)))      # down the lamp face, from its top edge
    down = Vector((0, 0, -1))
    rings = []
    n = POPUP_LID_STEPS
    for xo in (-POPUP_HALF_W, POPUP_HALF_W):
        x = s * POPUP_X + xo
        lid = []
        for k in range(n + 1):
            y = POPUP_Y[0] + (POPUP_Y[1] - POPUP_Y[0]) * k / n
            hit, _ = proj.hit(Vector((x, y, 3.0)), down)
            lid.append(Vector((x, y, hit.z + POPUP_LIFT)))
        top_f = lid[-1]
        bot_f = top_f + d * POPUP_FACE
        bot_r = Vector((x, POPUP_Y[0] + 0.012, bot_f.z - 0.012))
        # lid (follows the hood), then housing: lid lip, lamp face, floor, rear wall
        rings.append(lid + [top_f + d * 0.018, bot_f, bot_r])
    if s < 0:
        rings.reverse()
    bm = bmesh.new()
    mats = ["Paint"] * (n + 1) + ["Trim"] * 3
    loft(bm, rings, closed=True, cap_start=True, cap_end=True, mat_fn=lambda a_, j: mats[j], cap_mat="Trim")
    # lamp: chrome bezel + lens on the face plane
    top_f = Vector((s * POPUP_X, POPUP_Y[1], (rings[0][n].z + rings[1][n].z) * 0.5))
    centre = top_f + d * (0.018 + (POPUP_FACE - 0.018) * 0.5)
    nrm = Vector((0.0, math.cos(a), -math.sin(a)))
    up = -d

    def on_face(u, v, w, c=centre):
        return c + Vector((u, 0, 0)) + up * v + nrm * w

    prism(bm, rounded_rect(0.285, 0.105, 0.03, 2), 0.012, lambda u, v, w: on_face(u, v, w + 0.004), "Chrome")
    prism(bm, rounded_rect(0.255, 0.08, 0.022, 2), 0.01, lambda u, v, w: on_face(u, v, w + 0.009), "HeadLight")
    hinge = popup_hinge(proj, s)
    bmesh.ops.translate(bm, vec=-hinge, verts=bm.verts)
    ob = finalize(bm, name, smooth_angle=30.0, bevel_angle=50.0, bevel_width=0.004, bevel_segments=1)
    ob.location = hinge
    return ob


def build_popup_wells(bm, proj):
    """Dark recess on the hood under each pod, seen only while the lamps are up."""
    down = Vector((0, 0, -1))
    for s in (1, -1):
        cy = 0.5 * (POPUP_Y[0] + POPUP_Y[1])
        vs, fs = fan_mesh(rounded_rect(2 * POPUP_HALF_W - 0.012, POPUP_Y[1] - POPUP_Y[0] - 0.012, 0.012, 2), rings=2)
        proj.decal(bm, vs, fs, lambda u, v, s=s: Vector((s * POPUP_X + u, cy + v, 3.0)), down, 0.002,
                   "Trim", "popup well")


# --------------------------------------------------------------------------------------
# Body detail parts
# --------------------------------------------------------------------------------------


def build_front_bumper(bm):
    # wraparound urethane bumper (plan outline extruded in z), with a black lip under it
    poly = [(-0.87, 1.75), (0.87, 1.75), (0.875, 1.88), (0.84, 1.995), (0.74, 2.05), (-0.74, 2.05),
            (-0.84, 1.995), (-0.875, 1.88)]
    prism(bm, poly, 0.15, lambda u, v, w: Vector((u, v, 0.37 + w)), "Paint2")
    lip = [(-0.80, 1.85), (0.80, 1.85), (0.80, 2.02), (0.72, 2.075), (-0.72, 2.075), (-0.80, 2.02)]
    prism(bm, lip, 0.03, lambda u, v, w: Vector((u, v, 0.28 + w)), "Trim")
    # rubbing strip along the bumper face
    strip = [(-0.86, 1.81), (0.86, 1.81), (0.865, 1.89), (0.835, 2.008), (0.74, 2.063), (-0.74, 2.063),
             (-0.835, 2.008), (-0.865, 1.89)]
    prism(bm, strip, 0.035, lambda u, v, w: Vector((u, v, 0.43 + w)), "Trim")


def build_fog_lamps(bm):
    """Round rally driving lamps set into the bumper: the car's face while the pop-ups sleep."""
    for s in (1, -1):
        x = s * 0.50
        m = Matrix.Translation((x, 2.035, 0.35)) @ rot_x(-math.pi / 2).to_4x4()
        add_cylinder(bm, 0.058, 0.05, 14, "Trim", m)
        m = Matrix.Translation((x, 2.061, 0.35)) @ rot_x(-math.pi / 2).to_4x4()
        add_cylinder(bm, 0.052, 0.006, 14, "Chrome", m)
        m = Matrix.Translation((x, 2.066, 0.35)) @ rot_x(-math.pi / 2).to_4x4()
        add_cylinder(bm, 0.043, 0.006, 14, "HeadLight", m, radius2=0.039)


def build_rear_bumper(bm):
    poly = [(-0.86, -1.79), (-0.87, -1.90), (-0.84, -2.02), (-0.76, -2.07), (0.76, -2.07), (0.84, -2.02),
            (0.87, -1.90), (0.86, -1.79)]
    prism(bm, list(reversed(poly)), 0.16, lambda u, v, w: Vector((u, v, 0.37 + w)), "Paint2")
    strip = [(-0.865, -1.83), (-0.87, -1.90), (-0.845, -2.03), (-0.76, -2.083), (0.76, -2.083),
             (0.845, -2.03), (0.87, -1.90), (0.865, -1.83)]
    prism(bm, list(reversed(strip)), 0.035, lambda u, v, w: Vector((u, v, 0.40 + w)), "Trim")


def build_mirrors(bm):
    for s in (1, -1):
        add_box(bm, (0.07, 0.05, 0.02), (s * 0.835, 0.43, 0.905), "Trim")
        rings = []
        for x, sc in ((0.855, 0.72), (0.88, 1.0), (0.93, 1.0), (0.945, 0.8)):
            sec = rounded_rect(0.085 * sc, 0.065 * sc, 0.02 * sc, 2)
            rings.append([Vector((s * x, 0.415 + u * 0.8, 0.935 + v)) for (u, v) in sec])
        if s < 0:
            rings = [list(reversed(r)) for r in rings]
        loft(bm, rings, closed=True, cap_start=True, cap_end=True, mat_fn=lambda a, j: "Trim", cap_mat="Trim")
        glass = rounded_rect(0.07, 0.048, 0.012, 2)
        prism(bm, glass, 0.006, lambda u, v, w, s=s: Vector((s * 0.905 + u, 0.383 + w, 0.935 + v)), "Chrome")


def build_roof_vent(bm):
    """Low rally roof vent near the windscreen header."""
    z0 = GH_Z2 - 0.012
    prof = [(-0.30, z0), (-0.30, z0 + 0.052), (-0.33, z0 + 0.06), (-0.56, z0 + 0.016), (-0.56, z0)]
    prism(bm, prof, 0.26, lambda u, v, w: Vector((w, u, v)), "Trim")
    add_box(bm, (0.21, 0.01, 0.036), (0.0, -0.296, z0 + 0.03), "Chrome")


def build_hatch_spoiler(bm):
    """Small spoiler off the roof's trailing edge, over the hatch glass, with end plates."""
    foil = [(0.0, 0.0), (-0.02, 0.016), (-0.10, 0.018), (-0.20, 0.008), (-0.205, -0.004), (-0.12, -0.006),
            (-0.02, -0.014)]
    yc, zc = -1.035, GH_Z2 - 0.018
    aoa = math.radians(-8.0)
    ca, sa = math.cos(aoa), math.sin(aoa)

    def foil3d(u, v, x):
        return Vector((x, yc + u * ca - v * sa, zc + u * sa + v * ca))

    prism(bm, foil, 1.12, lambda u, v, w: foil3d(u, v, w), "Paint")
    plate = [(0.005, -0.03), (0.0, 0.03), (-0.19, 0.036), (-0.215, 0.012), (-0.21, -0.03), (-0.12, -0.05)]
    for s in (1, -1):
        prism(bm, plate, 0.012, lambda u, v, w, s=s: foil3d(u, v, s * 0.566 + w), "Paint")


def build_mudflaps(bm):
    for s in (1, -1):
        for y, top, bot, fw in ((Y_AXLE_F - ARCH_R - 0.03, 0.40, 0.12, 0.22),
                                (Y_AXLE_R - ARCH_R - 0.03, 0.44, 0.075, 0.25)):
            xo = 0.89
            poly = [(xo - fw, bot), (xo, bot + 0.01), (xo - 0.005, top), (xo - fw, top)]
            prism(bm, poly, 0.014, lambda u, v, w, s=s, y=y: Vector((s * u, y + w, v)), "Trim")


def build_tow_hooks(bm):
    def hook(center, facing, xs):
        segs = 10
        ro, ri, th = 0.05, 0.031, 0.018
        ring_o, ring_i = [], []
        for k in range(segs + 1):
            a = -math.pi / 2 + math.pi * k / segs
            ring_o.append(Vector((0.0, facing * math.cos(a) * ro, math.sin(a) * ro)))
            ring_i.append(Vector((0.0, facing * math.cos(a) * ri, math.sin(a) * ri)))
        pts = ring_o + list(reversed(ring_i))
        pts = [Vector((0, -facing * 0.04, -ro))] + pts + [Vector((0, -facing * 0.04, -ri))]
        poly = [(p.y, p.z) for p in pts]
        prism(bm, poly, th, lambda u, v, w: Vector((xs + w, center.y + u, center.z + v)), "Accent")

    hook(Vector((0.0, 2.05, 0.30)), 1.0, -0.66)
    hook(Vector((0.0, -2.07, 0.33)), -1.0, 0.64)


def build_exhaust(bm):
    m = Matrix.Translation((-0.50, -2.01, 0.27)) @ rot_x(math.pi / 2).to_4x4()
    add_cylinder(bm, 0.045, 0.18, 12, "Chrome", m)
    m = Matrix.Translation((-0.50, -2.101, 0.27)) @ rot_x(math.pi / 2).to_4x4()
    add_cylinder(bm, 0.033, 0.004, 12, "Trim", m)


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

NUMBER = "08"
NUMBER_PANEL = (0.14, 0.722, 0.31, 0.185)    # door panel centre y, z and size


def gale_streaks(length, spacing, width):
    """The Hayate gale mark: three tapered wind streaks, staggered like a gust (u = along,
    v = across; each streak is widest at its head, u = 0, and runs out toward +u)."""
    meshes = []
    for k, (lead, scale) in enumerate(((0.0, 1.0), (0.22, 0.78), (0.44, 0.56))):
        v = (k - 1) * spacing
        du = lead * length
        ln = length * scale
        keys = [(du, v, width * 0.75), (du + 0.12 * ln, v, width), (du + 0.55 * ln, v - 0.004, width * 0.6),
                (du + ln, v - 0.008, 0.0)]
        meshes.append(strip_mesh(keys, samples=16, across=2))
    return meshes


def build_side_decals(bm, proj):
    for s in (1, -1):
        d = Vector((-s, 0, 0))

        def to3d(u, v, s=s):
            return Vector((s * 1.4, u, v))

        # white pinstripe riding the two-tone crease: fender, door, rear quarter
        zp = Z_CREASE + 0.022
        for y0, y1, w0, w1 in ((1.95, 1.715, 0.0, 0.011), (0.84, -0.84, 0.011, 0.011), (-1.715, -1.97, 0.011, 0.0)):
            vs, fs = strip_mesh([(y0, zp, w0), (0.5 * (y0 + y1), zp, 0.011), (y1, zp, w1)], samples=24, across=2)
            proj.decal(bm, vs, fs, to3d, d, 0.0045, "Decal_White", "pinstripe")
        # door number panel
        y, z, w, h = NUMBER_PANEL
        vs, fs = fan_mesh(rounded_rect(w + 0.024, h + 0.024, 0.045, 3), rings=2)
        proj.decal(bm, vs, fs, lambda u, v, s=s: Vector((s * 1.4, y + u, z + v)), d, 0.004, "Number", "number border")
        vs, fs = fan_mesh(rounded_rect(w, h, 0.035, 3), rings=2)
        proj.decal(bm, vs, fs, lambda u, v, s=s: Vector((s * 1.4, y + u, z + v)), d, 0.005, "Decal_White", "number panel")
        tv, tf = text_mesh(NUMBER, 0.16, FONT_NUMBER)
        proj.decal(bm, tv, tf, lambda u, v, s=s: Vector((s * 1.4, y + s * u, z + v)), d, 0.0065, "Number", "door number")
        # door shut lines and handle
        for yl, zt in ((0.80, 0.83), (-0.42, 0.845)):
            line = [(yl, zt, 0.006), (yl - 0.004, 0.60, 0.006), (yl - 0.006, 0.33, 0.006)]
            vs, fs = strip_mesh(line, samples=16, across=2)
            proj.decal(bm, vs, fs, to3d, d, 0.0045, "Trim", "door line")
        vs, fs = fan_mesh(rounded_rect(0.11, 0.022, 0.01, 2), rings=1)
        proj.decal(bm, vs, fs, lambda u, v, s=s: Vector((s * 1.4, -0.30 + u, 0.785 + v)), d, 0.004, "Trim", "handle")
        # 疾風 on the front fender
        tv, tf = text_mesh("疾風", 0.075, FONT_KANJI)
        proj.decal(bm, tv, tf, lambda u, v, s=s: Vector((s * 1.4, 1.76 + s * u, 0.69 + v)), d, 0.0045,
                   "Number", "fender kanji")
    vs, fs = fan_mesh(circle(0.04, 16), rings=2)
    proj.decal(bm, vs, fs, lambda u, v: Vector((1.4, -1.76 + u, 0.75 + v)), Vector((-1, 0, 0)), 0.004,
               "Chrome", "fuel cap")


def build_top_decals(bm, proj):
    down = Vector((0, 0, -1))
    # gale mark streaming back along the left of the hood
    for vs, fs in gale_streaks(0.70, 0.085, 0.055):
        proj.decal(bm, vs, fs, lambda u, v: Vector((-0.28 + v, 1.64 - u, 3.0)), down, 0.003, "Paint2", "hood gale")
    # cowl vent strip ahead of the windscreen
    for s in (1, -1):
        vs, fs = fan_mesh(rounded_rect(0.30, 0.045, 0.012, 2), rings=1)
        proj.decal(bm, vs, fs, lambda u, v, s=s: Vector((s * 0.24 + u, 0.70 + v, 3.0)), down, 0.003, "Trim", "cowl")


def build_front_decals(bm, proj):
    back = Vector((0, -1, 0))
    # slim slat grille across the nose
    vs, fs = fan_mesh(rounded_rect(0.92, 0.07, 0.02, 2), rings=2)
    proj.decal(bm, vs, fs, lambda u, v: Vector((u, 3.0, 0.485 + v)), back, 0.003, "Trim", "grille")
    for k in (-1, 1):
        vs, fs = strip_mesh([(-0.42, 0.485 + k * 0.012, 0.007), (0.42, 0.485 + k * 0.012, 0.007)], samples=2, across=2)
        proj.decal(bm, vs, fs, lambda u, v: Vector((u, 3.0, v)), back, 0.0045, "Chrome", "grille slat")
    # parking / indicator lamps at the nose corners
    for s in (1, -1):
        vs, fs = fan_mesh(rounded_rect(0.19, 0.075, 0.018, 2), rings=1)
        proj.decal(bm, vs, fs, lambda u, v, s=s: Vector((s * 0.70 + u, 3.0, 0.49 + v)), back, 0.003, "Trim", "lamp surround")
        vs, fs = fan_mesh(rounded_rect(0.09, 0.05, 0.012, 2), rings=1)
        proj.decal(bm, vs, fs, lambda u, v, s=s: Vector((s * 0.655 + u, 3.0, 0.49 + v)), back, 0.005, "HeadLight", "parking lamp")
        vs, fs = fan_mesh(rounded_rect(0.06, 0.05, 0.012, 2), rings=1)
        proj.decal(bm, vs, fs, lambda u, v, s=s: Vector((s * 0.745 + u, 3.0, 0.49 + v)), back, 0.005, "Accent", "indicator")


def build_rear_decals(bm, proj):
    fwd = Vector((0, 1, 0))
    # full-width tail lamp band: red lamps, a black centre garnish with the name
    vs, fs = fan_mesh(rounded_rect(1.54, 0.15, 0.03, 2), rings=2)
    proj.decal(bm, vs, fs, lambda u, v: Vector((u, -3.0, 0.69 + v)), fwd, 0.003, "Trim", "tail band")
    for s in (1, -1):
        vs, fs = fan_mesh(rounded_rect(0.36, 0.115, 0.02, 2), rings=2)
        proj.decal(bm, vs, fs, lambda u, v, s=s: Vector((s * 0.54 + u, -3.0, 0.69 + v)), fwd, 0.005, "TailLight", "taillight")
        vs, fs = fan_mesh(rounded_rect(0.07, 0.115, 0.016, 2), rings=1)
        proj.decal(bm, vs, fs, lambda u, v, s=s: Vector((s * 0.305 + u, -3.0, 0.69 + v)), fwd, 0.005, "HeadLight", "reverse light")
        vs, fs = fan_mesh(rounded_rect(0.06, 0.115, 0.016, 2), rings=1)
        proj.decal(bm, vs, fs, lambda u, v, s=s: Vector((s * 0.755 + u, -3.0, 0.69 + v)), fwd, 0.005, "Accent", "rear indicator")
    tv, tf = text_mesh("HAYATE", 0.085, FONT_BANNER)
    proj.decal(bm, tv, tf, lambda u, v: Vector((u, -3.0, 0.69 + v)), fwd, 0.0055, "Decal_White", "rear text")


def build_roof_decals(bm, proj_gh):
    down = Vector((0, 0, -1))
    c = Vector((0.0, -0.78))
    vs, fs = fan_mesh(rounded_rect(0.40, 0.34, 0.06, 3), rings=2)
    proj_gh.decal(bm, vs, fs, lambda u, v: Vector((c.x + u, c.y + v, 3.0)), down, 0.004, "Number", "roof panel border")
    vs, fs = fan_mesh(rounded_rect(0.37, 0.31, 0.048, 3), rings=2)
    proj_gh.decal(bm, vs, fs, lambda u, v: Vector((c.x + u, c.y + v, 3.0)), down, 0.005, "Decal_White", "roof panel")
    tv, tf = text_mesh(NUMBER, 0.24, FONT_NUMBER)
    proj_gh.decal(bm, tv, tf, lambda u, v: Vector((c.x + u, c.y + v, 3.0)), down, 0.0065, "Number", "roof number")


def build_banner(bm, proj_gh):
    """White lettering on the Paint2 sun strip across the top of the windscreen."""
    r0, r1 = gh_rings()
    v = 0.5 * (GH_ROWS[BANNER_BAND] + GH_ROWS[BANNER_BAND + 1])
    bottom = r0[0].lerp(r1[0], GH_ROWS[BANNER_BAND])
    top = r0[0].lerp(r1[0], GH_ROWS[BANNER_BAND + 1])
    centre = r0[0].lerp(r1[0], v)
    up = (top - bottom).normalized()
    right = Vector((-1.0, 0.0, 0.0))
    nrm = right.cross(up).normalized()
    if nrm.y < 0.0:
        nrm = -nrm
    tv, tf = text_mesh("HAYATE  疾風", 0.07, FONT_KANJI)
    proj_gh.decal(bm, tv, tf, lambda u, w: centre + right * u + up * w + nrm * 0.05, -nrm, 0.004,
                  "Decal_White", "banner text")


def build_mudflap_decals(bm, bm_parts):
    proj = Projector(bm_parts)
    fwd = Vector((0, 1, 0))
    for s in (1, -1):
        y = Y_AXLE_R - ARCH_R - 0.03
        for vs, fs in gale_streaks(0.19, 0.035, 0.02):
            proj.decal(bm, vs, fs, lambda u, v, s=s, y=y: Vector((s * (0.84 - u), y - 0.3, 0.22 + v)), fwd,
                       0.003, "Decal_White", "mudflap gale")


# --------------------------------------------------------------------------------------
# Wheels: ten flat spokes (classic 80s multi-spoke face) on the shared tyre and hub
# --------------------------------------------------------------------------------------


def spokes_ten(bm):
    n_sp = 10
    for i in range(n_sp):
        a = 2 * math.pi * i / n_sp + math.pi / 2
        ca, sa = math.cos(a), math.sin(a)
        ta, tb = Vector((0, -sa, ca)), Vector((0, ca, sa))

        def P(r, w, x):
            return Vector((x, 0, 0)) + tb * r + ta * w

        v_in = [P(0.055, -0.013, 0.074), P(0.055, 0.013, 0.074), P(0.055, 0.013, 0.050), P(0.055, -0.013, 0.050)]
        v_out = [P(0.188, -0.019, 0.094), P(0.188, 0.019, 0.094), P(0.188, 0.019, 0.074), P(0.188, -0.019, 0.074)]
        loft(bm, [v_in, v_out], closed=True, cap_start=True, cap_end=True,
             mat_fn=lambda a_, j_: "Rim", cap_mat="Rim")


# --------------------------------------------------------------------------------------
# Assembly
# --------------------------------------------------------------------------------------


def build_car():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    build_materials(MAT_SPECS)
    if not os.path.exists(FONT_KANJI):
        raise RuntimeError(f"kanji font missing: {FONT_KANJI}")

    bm_shell = build_shell()
    shell = finalize(bm_shell, "Body", bevel_angle=26.0, bevel_width=0.011, bevel_segments=2,
                     bevel_skip_mats=("Trim",))
    bm_shell_final = bmesh.new()
    bm_shell_final.from_mesh(shell.data)
    proj_shell = Projector(bm_shell_final)

    bm_gh = build_greenhouse()
    bevel_sharp_edges(bm_gh, 24.0, 0.012, 2)
    recess_glass(bm_gh, GLASS_INSET, GLASS_DEPTH)
    gh = finalize(bm_gh, "Body_Cabin", recalc=False)
    bm_gh_final = bmesh.new()
    bm_gh_final.from_mesh(gh.data)

    bm_parts = bmesh.new()
    build_front_bumper(bm_parts)
    build_fog_lamps(bm_parts)
    build_rear_bumper(bm_parts)
    build_mirrors(bm_parts)
    build_roof_vent(bm_parts)
    build_hatch_spoiler(bm_parts)
    build_mudflaps(bm_parts)
    build_tow_hooks(bm_parts)
    build_exhaust(bm_parts)
    build_well_liners(bm_parts)
    bm_parts_copy = bm_parts.copy()
    parts = finalize(bm_parts, "Body_Parts", bevel_angle=50.0, bevel_width=0.004, bevel_segments=1)

    bm_decal = bmesh.new()
    build_side_decals(bm_decal, proj_shell)
    build_top_decals(bm_decal, proj_shell)
    build_popup_wells(bm_decal, proj_shell)
    build_front_decals(bm_decal, proj_shell)
    build_rear_decals(bm_decal, proj_shell)
    proj_gh = Projector(bm_gh_final)
    build_roof_decals(bm_decal, proj_gh)
    build_banner(bm_decal, proj_gh)
    bmesh.ops.recalc_face_normals(bm_parts_copy, faces=bm_parts_copy.faces)
    build_mudflap_decals(bm_decal, bm_parts_copy)
    decals = finalize(bm_decal, "Body_Livery", recalc=False)

    popups = [build_popup("PopUp_L", proj_shell, -1), build_popup("PopUp_R", proj_shell, 1)]

    body = join_objects(shell, (gh, parts, decals), "Body")
    for pod in popups:
        pod.parent = body

    objs = [body] + popups
    for key, c in WHEELS.items():
        objs.append(build_wheel("Wheel_" + key, c, 1 if c.x > 0 else -1, spokes=spokes_ten))
    for key, c in WHEELS.items():
        objs.append(build_caliper("Caliper_" + key, c, 1 if c.x > 0 else -1))

    for bmx in (bm_shell_final, bm_gh_final, bm_parts_copy):
        bmx.free()
    return objs


def set_popups(objs, degrees):
    for ob in objs:
        if ob.name.startswith("PopUp_"):
            ob.rotation_euler = (math.radians(degrees), 0.0, 0.0)


def main():
    objs = build_car()
    report(objs, "hayate")
    export(objs, GLB_PATH)
    print(f"[hayate] exported {GLB_PATH}")
    if DO_RENDER:
        setup_render_scene()
        toonify_materials()
        views = {k: PREVIEW_VIEWS[k] for k in ("front34", "rear34", "side", "front", "top", "low")}
        render_views("car_hayate", views, "hayate")
        set_popups(objs, POPUP_OPEN_DEG)
        render_views("car_hayate", {"front34_open": PREVIEW_VIEWS["front34"]}, "hayate")


main()
