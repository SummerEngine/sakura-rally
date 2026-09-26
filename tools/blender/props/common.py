"""Shared geometry + material toolkit for the Sakura Rally prop kit.

Every prop is built into one `Kit`: a single bmesh with per-face material slots and a
per-corner colour layer (multiplies albedo in the toon shader). Primitives are generated in
local space and merged with a transform, so the whole prop ends up as one mesh object with
flat (faceted) shading. Origin = base centre on the ground, metres, front = Blender +Y.
"""
from __future__ import annotations

import math
import random
import zlib
from typing import Callable, Iterable, Sequence

import bmesh
import bpy
from mathutils import Euler, Matrix, Vector, noise

ColorFn = Callable[[Vector, Vector], Sequence[float]]

# ----------------------------------------------------------------------------------------
# Palette + materials. Names follow docs/CONTRACTS.md keyword table (Blossom / Leaves /
# Needle / Grass / Foliage sway; Glass; Light/Lantern/Emit emissive). Names must NOT contain
# a keyword accidentally (e.g. never "Highlight", "Leafless").
# ----------------------------------------------------------------------------------------
MATERIALS: dict[str, tuple[str, float]] = {
    # name: (sRGB hex, emission strength)
    "Blossom": ("#f8c0d1", 0.0),
    "Blossom_Pale": ("#fcd9e3", 0.0),
    "Blossom_Deep": ("#f2a6be", 0.0),
    "Blossom_Rose": ("#e68aa8", 0.0),
    "Blossom_Azalea": ("#e3649a", 0.0),
    "Blossom_Flower": ("#ffffff", 0.0),
    "Leaves": ("#6ea655", 0.0),
    "Leaves_Spring": ("#9ccb6b", 0.0),
    "Leaves_Dark": ("#3f7348", 0.0),
    "Leaves_Maple_Red": ("#d13f35", 0.0),
    "Leaves_Maple_Scarlet": ("#e75b3d", 0.0),
    "Leaves_Maple_Orange": ("#f2873e", 0.0),
    "Leaves_Maple_Amber": ("#f5b04a", 0.0),
    "Leaves_Maple_Gold": ("#f2c552", 0.0),
    "Leaves_Persimmon": ("#d9a54a", 0.0),
    "Leaves_Bamboo": ("#8cc063", 0.0),
    "Leaves_Fern": ("#5f9a4c", 0.0),
    "Foliage_Bamboo": ("#9dbd5c", 0.0),
    "Needle_Cedar": ("#2f5d4a", 0.0),
    "Needle_Cedar_Top": ("#3a6c55", 0.0),
    "Needle_Pine": ("#3f7348", 0.0),
    "Grass": ("#8dc266", 0.0),
    "Grass_Reed": ("#a8b86a", 0.0),
    "Grass_Pale": ("#bad981", 0.0),
    "Bark": ("#6b4d42", 0.0),
    "Bark_Sakura": ("#5a3d3c", 0.0),
    "Bark_Cedar": ("#7a5040", 0.0),
    "Bark_Pine": ("#5e4a44", 0.0),
    "Bark_Maple": ("#6f5a52", 0.0),
    "Wood_Cut": ("#d8b184", 0.0),
    "Fruit_Persimmon": ("#f07a22", 0.0),
    "Grass_Cattail": ("#7a5238", 0.0),
    "Rock": ("#a29d96", 0.0),
    "Rock_Dark": ("#8a847f", 0.0),
    "Moss": ("#88ae5c", 0.0),
    "Earth": ("#b38c64", 0.0),
    "Stone": ("#bab3a6", 0.0),
    "Stone_Dark": ("#948d82", 0.0),
    "Concrete": ("#c9c4ba", 0.0),
    "Wood": ("#a47148", 0.0),
    "Wood_Dark": ("#5b4036", 0.0),
    "Wood_Pale": ("#c89f72", 0.0),
    "Wood_Weathered": ("#8f8274", 0.0),
    "Plaster": ("#f4ede0", 0.0),
    "Roof_Tile": ("#4f5a6d", 0.0),
    "Roof_Tin": ("#b0503f", 0.0),
    "Roof_Ridge": ("#3b4353", 0.0),
    "Bamboo_Cane": ("#cdb872", 0.0),
    "Roof_Copper": ("#5e9c8c", 0.0),
    "Thatch": ("#b89a62", 0.0),
    "Thatch_Dark": ("#8c7248", 0.0),
    "Shoji": ("#fbf3df", 0.0),
    "Vermilion": ("#e44a30", 0.0),
    "Ink": ("#2e2836", 0.0),
    "Gold": ("#f2c552", 0.0),
    "Rope": ("#e8d6a8", 0.0),
    "Paper_White": ("#fbf7ee", 0.0),
    "Lantern_Paper": ("#fff0d2", 1.4),
    "Lantern_Red": ("#e2503c", 1.1),
    "Light_Panel": ("#fff6dd", 1.2),
    "HeadLight": ("#fff7e0", 1.5),
    "TailLight": ("#e0322c", 0.8),
    "Glass": ("#7fa3c4", 0.0),
    "Water": ("#6fa8c8", 0.0),
    "Glass_Mirror": ("#b9d3e8", 0.0),
    "Metal": ("#9aa0a8", 0.0),
    "Metal_Dark": ("#4d505c", 0.0),
    "Galvanized": ("#c2c8cc", 0.0),
    "Rubber": ("#34303a", 0.0),
    "White": ("#f5f2ea", 0.0),
    "Offwhite": ("#e6e1d6", 0.0),
    "Red": ("#d8413a", 0.0),
    "Red_Dark": ("#a8302e", 0.0),
    "Orange": ("#f28a2e", 0.0),
    "Yellow_Sign": ("#f5c431", 0.0),
    "Blue": ("#3f73c0", 0.0),
    "Blue_Pale": ("#8fb8e0", 0.0),
    "Green_Vend": ("#3d9a6a", 0.0),
    "Pink": ("#f08fb0", 0.0),
    "Teal": ("#3aa6a0", 0.0),
    "Purple": ("#7b62b0", 0.0),
    "Straw": ("#e2c47c", 0.0),
    "Hay": ("#dcb964", 0.0),
    "Hay_Wrap": ("#f2efe6", 0.0),
    "Canvas": ("#f3efe4", 0.0),
    "Skin": ("#f6d2b8", 0.0),
    "Skin_Tan": ("#dca47e", 0.0),
    "Hair_Black": ("#2f2a33", 0.0),
    "Hair_Brown": ("#6a4638", 0.0),
    "Hair_Grey": ("#b8b4b6", 0.0),
    "Cloth_Red": ("#d9483e", 0.0),
    "Cloth_Blue": ("#4a78c4", 0.0),
    "Cloth_Navy": ("#34406b", 0.0),
    "Cloth_Yellow": ("#f3c64a", 0.0),
    "Cloth_Green": ("#5ea466", 0.0),
    "Cloth_White": ("#f4f1ea", 0.0),
    "Cloth_Pink": ("#f29bb8", 0.0),
    "Cloth_Denim": ("#56709a", 0.0),
    "Cloth_Khaki": ("#b8a47a", 0.0),
    "Cloth_Grey": ("#8d8c94", 0.0),
    "Cloth_Orange": ("#f28b3a", 0.0),
    "Cloth_Teal": ("#3fa3a0", 0.0),
    "Cloth_Black": ("#35313b", 0.0),
    "Banner_Pink": ("#f6b8cb", 0.0),
    "Banner_Ink": ("#3a2e48", 0.0),
    "Banner_Rose": ("#e68aa8", 0.0),
    "Leaves_Ginkgo": ("#f4c64a", 0.0),
    "Leaves_Fresh": ("#b5d672", 0.0),
    "Tape_Red": ("#e0483c", 0.0),
    "Tape_White": ("#f6f3ec", 0.0),
}


def srgb_to_linear(c: float) -> float:
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def hex_rgb(h: str) -> tuple[float, float, float]:
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4))  # type: ignore[return-value]


def get_material(name: str) -> bpy.types.Material:
    mat = bpy.data.materials.get(name)
    if mat is not None:
        return mat
    if name not in MATERIALS:
        raise KeyError(f"material {name!r} not in palette table")
    hx, emit = MATERIALS[name]
    srgb = hex_rgb(hx)
    lin = tuple(srgb_to_linear(c) for c in srgb)
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*lin, 1.0)
    bsdf.inputs["Roughness"].default_value = 0.85
    bsdf.inputs["Metallic"].default_value = 0.0
    if emit > 0.0:
        bsdf.inputs["Emission Color"].default_value = (*lin, 1.0)
        bsdf.inputs["Emission Strength"].default_value = emit
    mat.diffuse_color = (*lin, 1.0)
    return mat


# ----------------------------------------------------------------------------------------
# Deterministic randomness
# ----------------------------------------------------------------------------------------
def rng(key: str) -> random.Random:
    return random.Random(zlib.crc32(key.encode("utf-8")))


def rot(rx: float = 0.0, ry: float = 0.0, rz: float = 0.0) -> Matrix:
    """Rotation matrix from Euler degrees (XYZ)."""
    return Euler((math.radians(rx), math.radians(ry), math.radians(rz)), "XYZ").to_matrix().to_4x4()


def trs(loc: Sequence[float] = (0, 0, 0), r: Sequence[float] = (0, 0, 0),
        s: Sequence[float] | float = (1, 1, 1)) -> Matrix:
    if isinstance(s, (int, float)):
        s = (s, s, s)
    return Matrix.Translation(Vector(loc)) @ rot(*r) @ Matrix.Diagonal((*s, 1.0))


def facing(center: Sequence[float], side: str = "front") -> Matrix:
    """Matrix for flat decals/text authored in local XY (reading +X, up +Y, face +Z) so they read
    correctly from +Y ("front") or -Y ("back") in Blender (front = game forward)."""
    if side == "front":
        cols = (Vector((-1, 0, 0)), Vector((0, 0, 1)), Vector((0, 1, 0)))
    elif side == "back":
        cols = (Vector((1, 0, 0)), Vector((0, 0, 1)), Vector((0, -1, 0)))
    else:
        raise ValueError(side)
    m = Matrix((cols[0], cols[1], cols[2])).transposed().to_4x4()
    return Matrix.Translation(Vector(center)) @ m


def look_matrix(origin: Vector, direction: Vector) -> Matrix:
    """Matrix whose local +Z points along `direction`, placed at `origin`."""
    d = direction.normalized()
    q = Vector((0, 0, 1)).rotation_difference(d)
    return Matrix.Translation(origin) @ q.to_matrix().to_4x4()


# ----------------------------------------------------------------------------------------
# Colour helpers (vertex colours multiply albedo, so keep them <= 1)
# ----------------------------------------------------------------------------------------
WHITE = (1.0, 1.0, 1.0, 1.0)


def lerp_col(a: Sequence[float], b: Sequence[float], t: float) -> tuple[float, float, float, float]:
    t = max(0.0, min(1.0, t))
    return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, 1.0)


def grad_z(z0: float, z1: float, c0: Sequence[float], c1: Sequence[float] = WHITE) -> ColorFn:
    """Vertical gradient: c0 at z0 (bottom) to c1 at z1 (top)."""
    span = max(1e-4, z1 - z0)
    return lambda co, n: lerp_col(c0, c1, (co.z - z0) / span)


def canopy_shade(z0: float, z1: float, cool: Sequence[float] = (0.80, 0.80, 0.93),
                 tint: Sequence[float] = WHITE) -> ColorFn:
    """Canopy gradient: cooler/darker at the bottom, plus face-normal term (undersides cooler)."""
    span = max(1e-4, z1 - z0)

    def fn(co: Vector, n: Vector) -> tuple[float, float, float, float]:
        t = (co.z - z0) / span * 0.75 + (n.z * 0.5 + 0.5) * 0.25
        c = lerp_col(cool, WHITE, t)
        return (c[0] * tint[0], c[1] * tint[1], c[2] * tint[2], 1.0)
    return fn


def underside(cool: Sequence[float] = (0.8, 0.79, 0.92)) -> ColorFn:
    """Darken/cool only downward-facing faces (eaves, soffits)."""
    return lambda co, n: lerp_col(cool, WHITE, n.z + 1.0)


def mul_col(fn: ColorFn | Sequence[float] | None, tint: Sequence[float]) -> ColorFn:
    def out(co: Vector, n: Vector) -> tuple[float, float, float, float]:
        if fn is None:
            base = WHITE
        elif callable(fn):
            base = fn(co, n)
        else:
            base = fn
        return (base[0] * tint[0], base[1] * tint[1], base[2] * tint[2], 1.0)
    return out


# ----------------------------------------------------------------------------------------
# Primitive bmesh generators (local space)
# ----------------------------------------------------------------------------------------
def bm_box(sx: float, sy: float, sz: float) -> bmesh.types.BMesh:
    """Box centred at origin in XY, base at z=0."""
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    for v in bm.verts:
        v.co = Vector((v.co.x * sx, v.co.y * sy, (v.co.z + 0.5) * sz))
    return bm


def bm_cyl(r_bot: float, r_top: float, h: float, seg: int, cap_bot: bool = True,
           cap_top: bool = True, phase: float = 0.0) -> bmesh.types.BMesh:
    """Cylinder/cone along +Z from z=0 to z=h. r_top=0 makes a pointed cone."""
    bm = bmesh.new()
    bot = []
    top = []
    for i in range(seg):
        a = phase + 2 * math.pi * i / seg
        ca, sa = math.cos(a), math.sin(a)
        bot.append(bm.verts.new((ca * r_bot, sa * r_bot, 0.0)))
        if r_top > 0:
            top.append(bm.verts.new((ca * r_top, sa * r_top, h)))
    if r_top > 0:
        for i in range(seg):
            j = (i + 1) % seg
            bm.faces.new((bot[i], bot[j], top[j], top[i]))
        if cap_top:
            bm.faces.new(top)
    else:
        apex = bm.verts.new((0, 0, h))
        for i in range(seg):
            j = (i + 1) % seg
            bm.faces.new((bot[i], bot[j], apex))
    if cap_bot:
        bm.faces.new(list(reversed(bot)))
    return bm


def bm_ico(subdiv: int, radius: float = 1.0) -> bmesh.types.BMesh:
    """subdiv 1 = icosahedron (20 tris), 2 = 80 tris, 3 = 320 tris."""
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=subdiv, radius=radius)
    return bm


def bm_hull(points: Iterable[Sequence[float]]) -> bmesh.types.BMesh:
    bm = bmesh.new()
    verts = [bm.verts.new(p) for p in points]
    res = bmesh.ops.convex_hull(bm, input=verts)
    # remove interior leftovers
    unused = [v for v in res.get("geom_unused", []) if isinstance(v, bmesh.types.BMVert)]
    interior = [v for v in res.get("geom_interior", []) if isinstance(v, bmesh.types.BMVert)]
    bmesh.ops.delete(bm, geom=list(set(unused + interior)), context="VERTS")
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return bm


def bm_poly(verts: Sequence[Sequence[float]], faces: Sequence[Sequence[int]]) -> bmesh.types.BMesh:
    bm = bmesh.new()
    vs = [bm.verts.new(v) for v in verts]
    for f in faces:
        bm.faces.new([vs[i] for i in f])
    return bm


def bm_tube(points: Sequence[Vector], radii: Sequence[float], sides: int,
            cap_start: bool = False, cap_end: bool = True, twist: float = 0.0) -> bmesh.types.BMesh:
    """Tube swept along a polyline with per-point radius (parallel-transport frames).
    A radius of 0 at the end produces a pointed tip."""
    bm = bmesh.new()
    pts = [Vector(p) for p in points]
    n = len(pts)
    tangents = []
    for i in range(n):
        if i == 0:
            t = pts[1] - pts[0]
        elif i == n - 1:
            t = pts[-1] - pts[-2]
        else:
            t = (pts[i + 1] - pts[i - 1])
        tangents.append(t.normalized())
    ref = Vector((1, 0, 0)) if abs(tangents[0].x) < 0.9 else Vector((0, 1, 0))
    normal = tangents[0].cross(ref).normalized()
    rings: list[list[bmesh.types.BMVert] | bmesh.types.BMVert] = []
    for i in range(n):
        if i > 0:
            q = tangents[i - 1].rotation_difference(tangents[i])
            normal = (q @ normal).normalized()
        binormal = tangents[i].cross(normal).normalized()
        if radii[i] <= 1e-5:
            rings.append(bm.verts.new(pts[i]))
            continue
        ring = []
        for k in range(sides):
            a = 2 * math.pi * k / sides + twist * i
            off = normal * math.cos(a) + binormal * math.sin(a)
            ring.append(bm.verts.new(pts[i] + off * radii[i]))
        rings.append(ring)
    for i in range(n - 1):
        a, b = rings[i], rings[i + 1]
        if isinstance(b, bmesh.types.BMVert):
            for k in range(sides):
                bm.faces.new((a[k], a[(k + 1) % sides], b))
        else:
            for k in range(sides):
                bm.faces.new((a[k], a[(k + 1) % sides], b[(k + 1) % sides], b[k]))
    if cap_start and isinstance(rings[0], list):
        bm.faces.new(list(reversed(rings[0])))
    if cap_end and isinstance(rings[-1], list):
        bm.faces.new(rings[-1])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return bm


def rock_like_points(base: Vector, size: Sequence[float], n: int, r: random.Random | None = None,
                     rough: float = 0.0) -> list[Vector]:
    """Fibonacci points on an ellipsoid whose bottom sits flat at `base` (for hull stones)."""
    pts = []
    golden = math.pi * (3 - math.sqrt(5))
    for i in range(n):
        y = 1 - 2 * (i + 0.5) / n
        rad = math.sqrt(1 - y * y)
        a = golden * i
        k = 1.0 + (r.uniform(-rough, rough) if r else 0.0)
        z = (max(-0.8, y) + 0.8) / 1.8 * size[2]  # flat bottom at 80% of the lower half
        pts.append(base + Vector((math.cos(a) * rad * size[0] / 2 * k, math.sin(a) * rad * size[1] / 2 * k, z)))
    return pts


def chamfer_box_points(center: Vector, size: Sequence[float], bevel: float, r: random.Random,
                       jit: float = 0.0) -> list[Vector]:
    """24 points of a chamfered box (base at center.z) for hull-built cut stones / pillows."""
    hx, hy, hz = size[0] / 2, size[1] / 2, size[2] / 2
    pts = []
    for sx in (-1, 1):
        for sy in (-1, 1):
            for sz in (-1, 1):
                c = Vector((sx * hx, sy * hy, sz * hz + hz))
                for ax in range(3):
                    p = c.copy()
                    p[ax] -= (sx, sy, sz)[ax] * bevel * size[ax]
                    p += Vector((r.uniform(-jit, jit), r.uniform(-jit, jit), r.uniform(-jit, jit)))
                    pts.append(center + p)
    return pts


def displace_radial(bm: bmesh.types.BMesh, amount: float, freq: float, seed_off: Vector) -> None:
    for v in bm.verts:
        d = v.co.length
        if d < 1e-6:
            continue
        k = noise.noise(v.co * freq + seed_off)
        v.co = v.co * (1.0 + amount * k)


def jitter(bm: bmesh.types.BMesh, r: random.Random, amount: float) -> None:
    for v in bm.verts:
        v.co += Vector((r.uniform(-amount, amount), r.uniform(-amount, amount), r.uniform(-amount, amount)))


# ----------------------------------------------------------------------------------------
# Kit: accumulates a prop
# ----------------------------------------------------------------------------------------
class Kit:
    def __init__(self, name: str):
        self.name = name
        self.bm = bmesh.new()
        self.col = self.bm.loops.layers.color.new("Color")
        self.mat_names: list[str] = []
        self.empties: list[tuple[str, Vector]] = []
        self.r = rng(name)

    # -- materials ------------------------------------------------------------------
    def mat(self, name: str) -> int:
        if name not in self.mat_names:
            if name not in MATERIALS:
                raise KeyError(f"material {name!r} not in palette table")
            self.mat_names.append(name)
        return self.mat_names.index(name)

    # -- merge ---------------------------------------------------------------------------
    def add(self, src: bmesh.types.BMesh, mat: str | Callable[[Vector, Vector], str],
            m: Matrix | None = None, color: ColorFn | Sequence[float] | None = None) -> None:
        """Merge `src` transformed by `m`. `mat` may be a callable(center, normal) -> name
        to assign materials per face (e.g. moss on upward faces)."""
        src.normal_update()
        mi_fixed = None if callable(mat) else self.mat(mat)
        m = m if m is not None else Matrix.Identity(4)
        flip = m.to_3x3().determinant() < 0
        nm = m.to_3x3().inverted_safe().transposed()
        vmap = {}
        for v in src.verts:
            vmap[v] = self.bm.verts.new(m @ v.co)
        for f in src.faces:
            vs = [vmap[v] for v in f.verts]
            if flip:
                vs.reverse()
            try:
                nf = self.bm.faces.new(vs)
            except ValueError:
                continue
            n = (nm @ f.normal).normalized()
            if mi_fixed is None:
                nf.material_index = self.mat(mat(nf.calc_center_median(), n))
            else:
                nf.material_index = mi_fixed
            nf.smooth = False
            for loop in nf.loops:
                if color is None:
                    c = WHITE
                elif callable(color):
                    c = color(loop.vert.co, n)
                else:
                    c = color
                loop[self.col] = (c[0], c[1], c[2], 1.0)
        src.free()

    # -- convenience primitives -----------------------------------------------------------
    def box(self, mat: str, size: Sequence[float], loc: Sequence[float] = (0, 0, 0),
            r: Sequence[float] = (0, 0, 0), color=None) -> None:
        """Box of `size`, base-centre at `loc` (then rotated about loc)."""
        self.add(bm_box(*size), mat, trs(loc, r), color)

    def cbox(self, mat: str, size: Sequence[float], center: Sequence[float],
             r: Sequence[float] = (0, 0, 0), color=None) -> None:
        """Box centred at `center`."""
        m = trs(center, r) @ Matrix.Translation((0, 0, -size[2] / 2))
        self.add(bm_box(*size), mat, m, color)

    def cyl(self, mat: str, r_bot: float, h: float, loc: Sequence[float] = (0, 0, 0),
            r: Sequence[float] = (0, 0, 0), seg: int = 8, r_top: float | None = None,
            cap_bot: bool = True, cap_top: bool = True, color=None, phase: float = 0.0,
            scale: Sequence[float] = (1, 1, 1)) -> None:
        rt = r_bot if r_top is None else r_top
        self.add(bm_cyl(r_bot, rt, h, seg, cap_bot, cap_top, phase), mat, trs(loc, r, scale), color)

    def cyl_between(self, mat: str, a: Sequence[float], b: Sequence[float], radius: float,
                    seg: int = 6, r_top: float | None = None, color=None, caps: bool = True) -> None:
        a, b = Vector(a), Vector(b)
        d = b - a
        rt = radius if r_top is None else r_top
        self.add(bm_cyl(radius, rt, d.length, seg, caps, caps), mat, look_matrix(a, d), color)

    def box_between(self, mat: str, a: Sequence[float], b: Sequence[float], w: float, t: float,
                    up: Sequence[float] = (0, 0, 1), color=None) -> None:
        """Beam of width w / thickness t from a to b (w measured along `side`, t along `up`)."""
        a, b = Vector(a), Vector(b)
        d = b - a
        fwd = d.normalized()
        upv = Vector(up)
        side = fwd.cross(upv)
        if side.length < 1e-4:
            side = fwd.cross(Vector((1, 0, 0)))
        side.normalize()
        upv = side.cross(fwd).normalized()
        basis = Matrix((side, upv, fwd)).transposed().to_4x4()
        self.add(bm_box(w, t, d.length), mat, Matrix.Translation(a) @ basis, color)

    def tube(self, mat: str, points: Sequence[Sequence[float]], radii: Sequence[float],
             sides: int = 6, cap_start: bool = False, cap_end: bool = True, color=None,
             twist: float = 0.0) -> None:
        self.add(bm_tube([Vector(p) for p in points], radii, sides, cap_start, cap_end, twist),
                 mat, None, color)

    def blob(self, mat: str, center: Sequence[float], radius: float,
             scale: Sequence[float] = (1, 1, 1), subdiv: int = 2, lump: float = 0.22,
             freq: float = 1.3, jit: float = 0.04, color=None, r: Sequence[float] | None = None,
             seed: float | None = None, pinch: float = 0.0) -> None:
        """Lumpy faceted cluster: noise-displaced icosphere. `pinch` narrows the upper half
        (teardrop / cone-like lumps for conifers)."""
        bm = bm_ico(subdiv, 1.0)
        so = Vector((self.r.uniform(-50, 50), self.r.uniform(-50, 50), self.r.uniform(-50, 50))) \
            if seed is None else Vector((seed, seed * 1.7, seed * 2.3))
        displace_radial(bm, lump, freq, so)
        jitter(bm, self.r, jit)
        if pinch > 0.0:
            for v in bm.verts:
                if v.co.z > 0:
                    k = max(0.05, 1.0 - pinch * v.co.z)
                    v.co.x *= k
                    v.co.y *= k
        rr = r if r is not None else (self.r.uniform(-8, 8), self.r.uniform(-8, 8), self.r.uniform(0, 360))
        m = trs(center, rr, (scale[0] * radius, scale[1] * radius, scale[2] * radius))
        self.add(bm, mat, m, color)

    def hull(self, mat: str, points: Iterable[Sequence[float]], m: Matrix | None = None, color=None) -> None:
        self.add(bm_hull(points), mat, m, color)

    def poly(self, mat: str, verts, faces, m: Matrix | None = None, color=None,
             recalc: bool = False) -> None:
        bm = bm_poly(verts, faces)
        if recalc:
            bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        self.add(bm, mat, m, color)

    def extrude_x(self, mat: str, profile: Sequence[Sequence[float]], xs: Sequence[float],
                  zfn: Callable[[float], float] | None = None, color=None, caps: bool = True,
                  m: Matrix | None = None) -> None:
        """Extrude a closed CCW profile [(y, z), ...] along X through stations `xs`
        (optionally bent by zfn(x)). Used for beams, rails, lintels."""
        bm = bmesh.new()
        rings = []
        for x in xs:
            dz = zfn(x) if zfn else 0.0
            rings.append([bm.verts.new((x, y, z + dz)) for y, z in profile])
        n = len(profile)
        for a, b in zip(rings, rings[1:]):
            for k in range(n):
                bm.faces.new((a[k], a[(k + 1) % n], b[(k + 1) % n], b[k]))
        if caps:
            bm.faces.new(list(reversed(rings[0])))
            bm.faces.new(rings[-1])
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        self.add(bm, mat, m, color)

    def flower(self, mat: str, m: Matrix, radius: float, center_mat: str | None = None,
               color=None) -> None:
        """Flat five-petal sakura blossom (notched petals) in local XY, facing +Z."""
        verts = [(0.0, 0.0, 0.0)]
        faces = []
        for k in range(5):
            a = math.pi / 2 + k * 2 * math.pi / 5
            def pol(ang: float, rr: float) -> tuple[float, float, float]:
                return (math.cos(ang) * rr, math.sin(ang) * rr, 0.0)
            i = len(verts)
            verts += [pol(a - 0.5, radius * 0.55), pol(a - 0.24, radius), pol(a, radius * 0.82),
                      pol(a + 0.24, radius), pol(a + 0.5, radius * 0.55)]
            faces += [(0, i, i + 1), (0, i + 1, i + 2), (0, i + 2, i + 3), (0, i + 3, i + 4)]
        self.poly(mat, verts, faces, m, color)
        if center_mat:
            c = [(math.cos(k * 2 * math.pi / 5) * radius * 0.2, math.sin(k * 2 * math.pi / 5) * radius * 0.2,
                  0.004) for k in range(5)]
            self.poly(center_mat, c, [(0, 1, 2, 3, 4)], m)

    def empty(self, name: str, loc: Sequence[float]) -> None:
        self.empties.append((name, Vector(loc)))

    def text(self, mat: str, body: str, size: float, depth: float, m: Matrix,
             font_path: str | None = None, align: str = "CENTER", resolution: int = 2,
             spacing: float = 1.0) -> tuple[float, float]:
        """Text-to-mesh. Text lies in local XY plane (reading along +X, up +Y), extruded along
        local Z both ways by depth/2; `m` places it. Returns (width, height) in metres."""
        curve = bpy.data.curves.new(f"txt_{body}", "FONT")
        curve.body = body
        curve.size = size
        curve.extrude = depth / 2
        curve.resolution_u = resolution
        curve.align_x = align
        curve.align_y = "CENTER"
        curve.space_character = spacing
        curve.fill_mode = "BOTH"
        if font_path:
            try:
                curve.font = bpy.data.fonts.load(font_path, check_existing=True)
            except RuntimeError:
                pass
        obj = bpy.data.objects.new("txt_tmp", curve)
        bpy.context.scene.collection.objects.link(obj)
        dg = bpy.context.evaluated_depsgraph_get()
        ev = obj.evaluated_get(dg)
        mesh = bpy.data.meshes.new_from_object(ev)
        bm = bmesh.new()
        bm.from_mesh(mesh)
        bmesh.ops.triangulate(bm, faces=bm.faces)
        bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
        xs = [v.co.x for v in bm.verts]
        ys = [v.co.y for v in bm.verts]
        w = max(xs) - min(xs) if xs else 0.0
        h = max(ys) - min(ys) if ys else 0.0
        bpy.data.objects.remove(obj)
        bpy.data.curves.remove(curve)
        bpy.data.meshes.remove(mesh)
        self.add(bm, mat, m, None)
        return w, h

    # -- finish ---------------------------------------------------------------------------
    def build_object(self) -> tuple[bpy.types.Object, list[bpy.types.Object]]:
        mesh = bpy.data.meshes.new(self.name)
        self.bm.to_mesh(mesh)
        self.bm.free()
        for n in self.mat_names:
            mesh.materials.append(get_material(n))
        for p in mesh.polygons:
            p.use_smooth = False
        if mesh.color_attributes:
            ca = mesh.color_attributes[0]
            mesh.color_attributes.active_color = ca
            mesh.color_attributes.render_color_index = 0
        obj = bpy.data.objects.new(self.name, mesh)
        bpy.context.scene.collection.objects.link(obj)
        empties = []
        for en, loc in self.empties:
            e = bpy.data.objects.new(en, None)
            e.empty_display_type = "PLAIN_AXES"
            e.empty_display_size = 0.2
            e.location = loc
            bpy.context.scene.collection.objects.link(e)
            empties.append(e)
        return obj, empties


def reset_scene() -> None:
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    for m in list(bpy.data.meshes):
        bpy.data.meshes.remove(m)
    for c in list(bpy.data.curves):
        bpy.data.curves.remove(c)
    noise.seed_set(0)


def tri_count(obj: bpy.types.Object) -> int:
    return sum(len(p.vertices) - 2 for p in obj.data.polygons)
