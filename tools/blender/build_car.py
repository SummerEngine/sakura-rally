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
from mathutils.bvhtree import BVHTree

# --------------------------------------------------------------------------------------
# Paths / arguments
# --------------------------------------------------------------------------------------

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
DO_RENDER = "--render" in ARGS
GLB_PATH = os.path.join(ROOT, "assets", "models", "car", "rally_car.glb")
BLEND_PATH = os.path.join(ROOT, "assets", "models", "car", "rally_car.blend")
RENDER_DIR = os.path.join(ROOT, "docs", "renders")

# --------------------------------------------------------------------------------------
# Contract geometry
# --------------------------------------------------------------------------------------

Y_AXLE_F = 1.27
Y_AXLE_R = -1.28
TRACK_X = 0.78
WHEEL_Z = 0.33
TYRE_R = 0.33
TYRE_W = 0.24

WHEELS = {
    "FL": Vector((-TRACK_X, Y_AXLE_F, WHEEL_Z)),
    "FR": Vector((TRACK_X, Y_AXLE_F, WHEEL_Z)),
    "RL": Vector((-TRACK_X, Y_AXLE_R, WHEEL_Z)),
    "RR": Vector((TRACK_X, Y_AXLE_R, WHEEL_Z)),
}

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


def _lin(c: float) -> float:
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def hex_rgb(h: str):
    h = h.lstrip("#")
    return tuple(_lin(int(h[i:i + 2], 16) / 255.0) for i in (0, 2, 4))


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
MAT_NAMES = [m[0] for m in MAT_SPECS]
MI = {name: i for i, name in enumerate(MAT_NAMES)}
MATERIALS = []


def build_materials():
    for name, hx, rough, metal, ehx, estr in MAT_SPECS:
        mat = bpy.data.materials.new(name)
        if mat.node_tree is None:
            mat.use_nodes = True
        bsdf = mat.node_tree.nodes.get("Principled BSDF")
        rgb = hex_rgb(hx)
        bsdf.inputs["Base Color"].default_value = (*rgb, 1.0)
        bsdf.inputs["Roughness"].default_value = rough
        bsdf.inputs["Metallic"].default_value = metal
        if ehx:
            bsdf.inputs["Emission Color"].default_value = (*hex_rgb(ehx), 1.0)
            bsdf.inputs["Emission Strength"].default_value = estr
        mat.diffuse_color = (*rgb, 1.0)
        MATERIALS.append(mat)


# --------------------------------------------------------------------------------------
# Small math helpers
# --------------------------------------------------------------------------------------


class Curve:
    """Monotone cubic (Fritsch-Carlson) interpolation through (x, y) keys."""

    def __init__(self, keys):
        keys = sorted(keys)
        self.x = [k[0] for k in keys]
        self.y = [k[1] for k in keys]
        n = len(keys)
        d = [(self.y[i + 1] - self.y[i]) / (self.x[i + 1] - self.x[i]) for i in range(n - 1)]
        m = [0.0] * n
        m[0], m[-1] = d[0], d[-1]
        for i in range(1, n - 1):
            m[i] = 0.0 if d[i - 1] * d[i] <= 0.0 else 0.5 * (d[i - 1] + d[i])
        for i in range(n - 1):
            if d[i] == 0.0:
                m[i] = m[i + 1] = 0.0
                continue
            a, b = m[i] / d[i], m[i + 1] / d[i]
            s = a * a + b * b
            if s > 9.0:
                t = 3.0 / math.sqrt(s)
                m[i], m[i + 1] = t * a * d[i], t * b * d[i]
        self.m = m

    def __call__(self, x: float) -> float:
        xs = self.x
        if x <= xs[0]:
            return self.y[0]
        if x >= xs[-1]:
            return self.y[-1]
        i = 0
        while x > xs[i + 1]:
            i += 1
        h = xs[i + 1] - xs[i]
        t = (x - xs[i]) / h
        t2, t3 = t * t, t * t * t
        return ((2 * t3 - 3 * t2 + 1) * self.y[i] + (t3 - 2 * t2 + t) * h * self.m[i]
                + (-2 * t3 + 3 * t2) * self.y[i + 1] + (t3 - t2) * h * self.m[i + 1])


def smoothstep(e0: float, e1: float, x: float) -> float:
    t = min(1.0, max(0.0, (x - e0) / (e1 - e0)))
    return t * t * (3.0 - 2.0 * t)


def lerp(a, b, t):
    return a + (b - a) * t


def arch_z(y: float, r: float) -> float:
    """Height of an arch circle of radius r over either axle (or -1 outside)."""
    best = -1.0
    for yw in (Y_AXLE_F, Y_AXLE_R):
        d = y - yw
        if abs(d) < r:
            best = max(best, ARCH_ZC + math.sqrt(r * r - d * d))
    return best


def rot_x(a):
    return Matrix.Rotation(a, 3, "X")


def rot_y(a):
    return Matrix.Rotation(a, 3, "Y")


def rot_z(a):
    return Matrix.Rotation(a, 3, "Z")


# --------------------------------------------------------------------------------------
# bmesh helpers
# --------------------------------------------------------------------------------------


def faces_of(verts):
    return list({f for v in verts for f in v.link_faces})


def set_mat(faces, mat):
    for f in faces:
        f.material_index = MI[mat]


def loft(bm, rings, closed=True, cap_start=False, cap_end=False, mat_fn=None, cap_mat="Paint"):
    """Connect equal-length point rings with quads. Returns the vert rings."""
    vr = [[bm.verts.new(p) for p in ring] for ring in rings]
    m = len(rings[0])
    for a in range(len(vr) - 1):
        for j in range(m if closed else m - 1):
            j2 = (j + 1) % m
            f = bm.faces.new((vr[a][j], vr[a][j2], vr[a + 1][j2], vr[a + 1][j]))
            f.material_index = MI[mat_fn(a, j) if mat_fn else cap_mat]
    if cap_start:
        bm.faces.new(vr[0]).material_index = MI[cap_mat]
    if cap_end:
        bm.faces.new(list(reversed(vr[-1]))).material_index = MI[cap_mat]
    return vr


def prism(bm, poly2d, depth, to3d, mat, side_mat=None):
    """Extrude a simple 2D polygon (u, v) along w in [-depth/2, depth/2].
    to3d(u, v, w) -> Vector. Returns created verts."""
    h = depth * 0.5
    ring_a = [to3d(u, v, -h) for (u, v) in poly2d]
    ring_b = [to3d(u, v, h) for (u, v) in poly2d]
    vr = loft(bm, [ring_a, ring_b], closed=True, cap_start=True, cap_end=True,
              mat_fn=lambda a, j: side_mat or mat, cap_mat=mat)
    return vr[0] + vr[1]


def add_box(bm, size, center, mat, rot=None):
    ret = bmesh.ops.create_cube(bm, size=1.0)
    verts = ret["verts"]
    bmesh.ops.scale(bm, vec=Vector(size), verts=verts)
    if rot is not None:
        bmesh.ops.rotate(bm, cent=Vector((0, 0, 0)), matrix=rot, verts=verts)
    bmesh.ops.translate(bm, vec=Vector(center), verts=verts)
    set_mat(faces_of(verts), mat)
    return verts


def add_cylinder(bm, radius, depth, segs, mat, matrix, radius2=None, cap_mat=None):
    """Cylinder/cone along local Z, placed by a 4x4 matrix. Caps optionally recoloured."""
    ret = bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segs,
                                radius1=radius, radius2=radius if radius2 is None else radius2,
                                depth=depth, matrix=matrix)
    verts = ret["verts"]
    fs = faces_of(verts)
    set_mat(fs, mat)
    if cap_mat:
        axis = (matrix.to_3x3() @ Vector((0, 0, 1))).normalized()
        for f in fs:
            if f.normal_update() is None and abs(f.normal.dot(axis)) > 0.9 and len(f.verts) > 4:
                f.material_index = MI[cap_mat]
    return verts


def rounded_rect(w, h, r, n=3):
    """CCW rounded rectangle outline centred at the origin."""
    pts = []
    corners = [(w / 2 - r, h / 2 - r, 0.0), (-w / 2 + r, h / 2 - r, 90.0),
               (-w / 2 + r, -h / 2 + r, 180.0), (w / 2 - r, -h / 2 + r, 270.0)]
    for cx, cy, a0 in corners:
        for k in range(n + 1):
            a = math.radians(a0 + 90.0 * k / n)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def circle(r, n, a0=0.0):
    return [(r * math.cos(a0 + 2 * math.pi * k / n), r * math.sin(a0 + 2 * math.pi * k / n)) for k in range(n)]


def sakura_outline(radius, per_petal=10, rot=0.0):
    """Five notched petals, star-shaped around the centre (CCW)."""
    pts = []
    n = 5 * per_petal
    for k in range(n):
        a = 2 * math.pi * k / n
        phi = ((a * 5.0 / (2 * math.pi)) % 1.0) - 0.5          # -0.5..0.5 inside a petal
        petal = 0.42 + 0.58 * math.cos(phi * math.pi) ** 0.55
        notch = 0.20 * math.exp(-(phi / 0.07) ** 2)
        r = radius * (petal - notch)
        pts.append((r * math.cos(a + rot + math.pi / 2), r * math.sin(a + rot + math.pi / 2)))
    return pts


def fan_mesh(outline, rings=3):
    """Triangle fan + quad rings filling a star-shaped CCW outline."""
    verts = [(0.0, 0.0)]
    faces = []
    n = len(outline)
    for k in range(1, rings + 1):
        s = k / rings
        verts.extend((u * s, v * s) for (u, v) in outline)
    for i in range(n):
        faces.append((0, 1 + i, 1 + (i + 1) % n))
    for k in range(1, rings):
        b0, b1 = 1 + (k - 1) * n, 1 + k * n
        for i in range(n):
            i2 = (i + 1) % n
            faces.append((b0 + i, b1 + i, b1 + i2, b0 + i2))
    return verts, faces


def annulus_mesh(r_out, r_in, n):
    verts = [(r_out * math.cos(2 * math.pi * k / n), r_out * math.sin(2 * math.pi * k / n)) for k in range(n)]
    verts += [(r_in * math.cos(2 * math.pi * k / n), r_in * math.sin(2 * math.pi * k / n)) for k in range(n)]
    faces = [(k, (k + 1) % n, n + (k + 1) % n, n + k) for k in range(n)]
    return verts, faces


def strip_mesh(center_pts, samples=60, across=3):
    """Tapered ribbon along a Catmull-Rom path of (u, v, width) keys."""
    def cr(p0, p1, p2, p3, t):
        return 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                      + (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t)

    keys = [Vector(k) for k in center_pts]
    ext = [keys[0] * 2 - keys[1]] + keys + [keys[-1] * 2 - keys[-2]]
    path = []
    segs = len(keys) - 1
    for s in range(samples + 1):
        g = s / samples * segs
        i = min(int(g), segs - 1)
        path.append(cr(ext[i], ext[i + 1], ext[i + 2], ext[i + 3], g - i))
    verts, faces = [], []
    for s, p in enumerate(path):
        a = path[max(0, s - 1)]
        b = path[min(len(path) - 1, s + 1)]
        tan = Vector((b.x - a.x, b.y - a.y)).normalized()
        nrm = Vector((-tan.y, tan.x))
        w = max(p.z, 0.0005)
        for k in range(across):
            f = k / (across - 1) - 0.5
            verts.append((p.x + nrm.x * w * f, p.y + nrm.y * w * f))
    for s in range(len(path) - 1):
        for k in range(across - 1):
            a0 = s * across + k
            b0 = (s + 1) * across + k
            faces.append((a0, b0, b0 + 1, a0 + 1))
    return verts, faces


def text_mesh(text, size, font_path=None, offset=0.0):
    """Flat filled text converted to mesh, centred. Returns (verts2d, faces)."""
    cu = bpy.data.curves.new("TextTmp", "FONT")
    cu.body = text
    if font_path and os.path.exists(font_path):
        cu.font = bpy.data.fonts.load(font_path, check_existing=True)
    cu.size = size
    cu.align_x = "CENTER"
    cu.align_y = "CENTER"
    cu.resolution_u = 3
    cu.offset = offset
    ob = bpy.data.objects.new("TextTmp", cu)
    bpy.context.scene.collection.objects.link(ob)
    dg = bpy.context.evaluated_depsgraph_get()
    ev = ob.evaluated_get(dg)
    me = ev.to_mesh()
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    bmesh.ops.triangulate(bm, faces=bm.faces)
    verts = [(v.co.x, v.co.y) for v in bm.verts]
    idx = {v: i for i, v in enumerate(bm.verts)}
    faces = [tuple(idx[v] for v in f.verts) for f in bm.faces]
    bm.free()
    ev.to_mesh_clear()
    bpy.data.objects.remove(ob)
    bpy.data.curves.remove(cu)
    # re-centre on the glyph bounds so the number sits in the roundel centre
    xs = [v[0] for v in verts]
    ys = [v[1] for v in verts]
    cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    return [(x - cx, y - cy) for (x, y) in verts], faces


class Projector:
    """Places flat decal meshes onto a target surface with a small normal offset."""

    def __init__(self, bm_target):
        self.bvh = BVHTree.FromBMesh(bm_target)

    def hit(self, p, direction):
        if direction is None:
            loc, nrm, _, _ = self.bvh.find_nearest(p)
        else:
            loc, nrm, _, _ = self.bvh.ray_cast(p, direction, 10.0)
        return loc, nrm

    def _surface(self, to3d, direction, u, v, offset, label):
        loc, nrm = self.hit(to3d(u, v), direction)
        if loc is None:
            raise RuntimeError(f"decal '{label}' vertex ({u:.3f},{v:.3f}) missed the surface")
        return loc + nrm * offset, nrm

    def refine(self, verts2d, faces, to3d, direction, offset, label, tol=0.0012, min_len=0.006):
        """Split decal edges whose straight chord would sink below the offset surface
        (convex creases/bevels), so flat decals never z-fight or get swallowed."""
        bm2 = bmesh.new()
        vs = [bm2.verts.new((u, v, 0.0)) for (u, v) in verts2d]
        for fidx in faces:
            bm2.faces.new([vs[i] for i in fidx])
        for _ in range(5):
            cut = []
            for e in bm2.edges:
                a, b = e.verts[0].co, e.verts[1].co
                if (a - b).length < min_len:
                    continue
                pa, _ = self._surface(to3d, direction, a.x, a.y, offset, label)
                pb, _ = self._surface(to3d, direction, b.x, b.y, offset, label)
                m = (a + b) * 0.5
                pm, nm = self._surface(to3d, direction, m.x, m.y, offset, label)
                if (pm - (pa + pb) * 0.5).dot(nm) > tol:
                    cut.append(e)
            if not cut:
                break
            bmesh.ops.subdivide_edges(bm2, edges=cut, cuts=1, use_grid_fill=True, use_single_edge=True)
            bmesh.ops.triangulate(bm2, faces=[f for f in bm2.faces if len(f.verts) > 4])
        out_v = [(v.co.x, v.co.y) for v in bm2.verts]
        idx = {v: i for i, v in enumerate(bm2.verts)}
        out_f = [tuple(idx[v] for v in f.verts) for f in bm2.faces]
        bm2.free()
        return out_v, out_f

    def decal(self, bm, verts2d, faces, to3d, direction, offset, mat, label):
        verts2d, faces = self.refine(verts2d, faces, to3d, direction, offset, label)
        vs, ns = [], []
        for (u, v) in verts2d:
            p, nrm = self._surface(to3d, direction, u, v, offset, label)
            vs.append(bm.verts.new(p))
            ns.append(nrm)
        for fidx in faces:
            f = bm.faces.new([vs[i] for i in fidx])
            f.material_index = MI[mat]
            f.normal_update()
            avg = Vector((0, 0, 0))
            for i in fidx:
                avg += ns[i]
            if f.normal.dot(avg) < 0.0:
                f.normal_flip()
        return vs


def inherit_bevel_materials(new_faces):
    """Bevel faces take the material of their most common original neighbour (bmesh's
    default can pick slot 0, which would leave white Paint slivers on black trim)."""
    new = set(new_faces)
    pending = list(new_faces)
    for _ in range(4):
        left = []
        for f in pending:
            counts = {}
            for e in f.edges:
                for g in e.link_faces:
                    if g is not f and g not in new:
                        counts[g.material_index] = counts.get(g.material_index, 0) + 1
            if counts:
                f.material_index = max(sorted(counts), key=lambda k: counts[k])
            else:
                left.append(f)
        for f in pending:
            if f not in left:
                new.discard(f)
        pending = left
        if not pending:
            break


def bevel_sharp_edges(bm, angle, width, segments, skip_mats=()):
    lim = math.radians(angle)
    skip = {MI[m] for m in skip_mats}
    edges = [e for e in bm.edges
             if e.is_manifold and e.calc_face_angle(0.0) > lim
             and not all(f.material_index in skip for f in e.link_faces)]
    if edges:
        ret = bmesh.ops.bevel(bm, geom=edges, offset=width, offset_type="OFFSET",
                              segments=segments, profile=0.5, affect="EDGES", clamp_overlap=True)
        inherit_bevel_materials(ret["faces"])


def face_sort_key(f):
    c = f.calc_center_median()
    f.normal_update()
    n = f.normal
    return (f.material_index, round(c.x, 5), round(c.y, 5), round(c.z, 5),
            round(n.x, 4), round(n.y, 4), round(n.z, 4), len(f.verts),
            tuple(sorted(v.index for v in f.verts)))


def finalize(bm, name, smooth_angle=35.0, bevel_angle=None, bevel_width=0.01, bevel_segments=2,
             bevel_skip_mats=(), recalc=True, flat=False):
    """Clean, bevel, shade (smooth by angle) and turn a bmesh into an object."""
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-6)
    bmesh.ops.dissolve_degenerate(bm, dist=1e-6, edges=bm.edges)
    if recalc:
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    if bevel_angle is not None:
        bevel_sharp_edges(bm, bevel_angle, bevel_width, bevel_segments, bevel_skip_mats)
    bmesh.ops.dissolve_degenerate(bm, dist=1e-5, edges=bm.edges)
    ngons = [f for f in bm.faces if len(f.verts) > 4]
    if ngons:
        bmesh.ops.triangulate(bm, faces=ngons, quad_method="BEAUTY", ngon_method="BEAUTY")
    # bmesh ops (bevel) emit faces in pointer-hash order; sort so exports are byte-identical
    vrank = {v: i for i, v in enumerate(sorted(bm.verts, key=lambda v: (round(v.co.x, 5), round(v.co.y, 5),
                                                                         round(v.co.z, 5))))}
    bm.verts.sort(key=lambda v: vrank[v])
    bm.verts.index_update()
    frank = {f: i for i, f in enumerate(sorted(bm.faces, key=face_sort_key))}
    bm.faces.sort(key=lambda f: frank[f])
    lim = math.radians(smooth_angle)
    for f in bm.faces:
        f.smooth = not flat
    for e in bm.edges:
        if len(e.link_faces) == 2:
            e.smooth = e.calc_face_angle(0.0) <= lim
        else:
            e.smooth = True
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    for m in MATERIALS:
        me.materials.append(m)
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


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
GH_N = 2 * len(GH_RING0) - 2       # 20


def gh_loop(half):
    right = list(half)
    left = [(-x, y) for (x, y) in reversed(half[1:-1])]
    return right + left


def gh_rings():
    r0 = [Vector((x, y, body_top_z(x, y) - GH_SINK)) for (x, y) in gh_loop(GH_RING0)]
    r1 = [Vector((x, y, GH_Z1)) for (x, y) in gh_loop(GH_RING1)]
    yc = -0.70
    r2 = [Vector((x * 0.84, yc + (y - yc) * 0.93, GH_Z2)) for (x, y) in gh_loop(GH_RING1)]
    return r0, r1, r2


def ring_at(ring, t):
    n = len(ring)
    t = t % n
    i = int(math.floor(t))
    f = t - i
    return ring[i].lerp(ring[(i + 1) % n], f)


def ring_advance(ring, t, dist):
    """Walk `dist` metres along the ring polyline from parameter t (sign = direction)."""
    n = len(ring)
    step = 1 if dist >= 0 else -1
    remaining = abs(dist)
    while remaining > 1e-9:
        if step > 0:
            nxt = math.floor(t + 1e-9) + 1
        else:
            nxt = math.ceil(t - 1e-9) - 1
        a = ring_at(ring, t)
        b = ring_at(ring, nxt)
        seg = (b - a).length
        if seg >= remaining:
            return t + (nxt - t) * (remaining / seg)
        remaining -= seg
        t = nxt
    return t


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


def gh_columns(ring, scale):
    """Loop parameters of all greenhouse columns on one ring: every ring vertex plus the
    pillar edges of each window (pillar widths measured along this ring)."""
    ts = [float(k) for k in range(GH_N)]
    for (t0, t1, i0, i1) in WINDOWS:
        ts.append(ring_advance(ring, t0, i0 * scale) % GH_N)
        ts.append(ring_advance(ring, t1, -i1 * scale) % GH_N)
    return sorted(ts)


def window_of(ring0, t):
    """Index of the window whose glass (inside its pillars) covers loop parameter t, or -1."""
    for i, (t0, t1, i0, i1) in enumerate(WINDOWS):
        g0 = ring_advance(ring0, t0, i0)
        g1 = ring_advance(ring0, t1, -i1)
        tt = t if t >= g0 else t + GH_N
        if g0 < tt < g1:
            return i
    return -1


def build_greenhouse():
    r0, r1, _ = gh_rings()
    c0 = gh_columns(r0, 1.0)
    c1 = gh_columns(r1, 0.8)
    p0 = [ring_at(r0, t) for t in c0]
    p1 = [ring_at(r1, t) for t in c1]
    yc = -0.70
    p2 = [Vector((p.x * 0.84, yc + (p.y - yc) * 0.93, GH_Z2)) for p in p1]
    rings = [[a.lerp(b, v) for a, b in zip(p0, p1)] for v in GH_ROWS] + [p2]
    n = len(c0)

    def column_window(j):
        ta, tb = c0[j], c0[(j + 1) % n]
        if tb < ta:
            tb += GH_N
        return window_of(r0, ((ta + tb) * 0.5) % GH_N)

    def mat_fn(a, j):
        if a >= len(GH_ROWS) - 1:
            return "Paint2"
        w = column_window(j)
        if w >= 0 and a in GLASS_BANDS:
            return "Paint2" if (w == 0 and a == BANNER_BAND) else "Glass"
        return "Paint"

    bm = bmesh.new()
    loft(bm, rings, closed=True, cap_start=False, cap_end=True, mat_fn=mat_fn, cap_mat="Paint2")
    centre = Vector((0.0, -0.6, 1.0))
    for f in bm.faces:
        f.normal_update()
        if f.normal.dot(f.calc_center_median() - centre) < 0.0:
            f.normal_flip()
    return bm


def recess_glass(bm):
    """Inset every window into the greenhouse: a dark rubber seal and recessed glass,
    so the ink shader gets a real depth edge around each pane."""
    glass = [f for f in bm.faces if f.material_index == MI["Glass"]]
    ret = bmesh.ops.inset_region(bm, faces=glass, thickness=GLASS_INSET, depth=-GLASS_DEPTH,
                                 use_even_offset=True, use_boundary=True)
    set_mat(ret["faces"], "Trim")


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

FONT_NUMBER = "/System/Library/Fonts/Supplemental/DIN Alternate Bold.ttf"
FONT_BANNER = "/System/Library/Fonts/Supplemental/DIN Condensed Bold.ttf"

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
    r0, r1, _ = gh_rings()
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
# Wheels
# --------------------------------------------------------------------------------------

TYRE_PROFILE = [(0.215, -0.095), (0.252, -0.113), (0.287, -0.12), (0.303, -0.113), (0.311, -0.098),
                (0.312, -0.033), (0.312, 0.033), (0.311, 0.098), (0.303, 0.113), (0.287, 0.12),
                (0.252, 0.113), (0.215, 0.095)]
RIM_PROFILE = [(0.222, 0.098), (0.205, 0.106), (0.186, 0.093), (0.182, -0.095), (0.198, -0.095),
               (0.200, 0.083), (0.214, 0.089)]
WHEEL_SEGS = 24
TREAD_H = TYRE_R - 0.312


def lathe(bm, profile, segs, mat, closed_profile=False, a0=0.0):
    rings = []
    for (r, x) in profile:
        rings.append([Vector((x, r * math.cos(a0 + 2 * math.pi * k / segs), r * math.sin(a0 + 2 * math.pi * k / segs)))
                      for k in range(segs)])
    if closed_profile:
        rings.append(rings[0])
    vr = [[bm.verts.new(p) for p in ring] for ring in (rings[:-1] if closed_profile else rings)]
    if closed_profile:
        vr.append(vr[0])
    grid = []
    for a in range(len(vr) - 1):
        row = []
        for k in range(segs):
            k2 = (k + 1) % segs
            f = bm.faces.new((vr[a][k], vr[a][k2], vr[a + 1][k2], vr[a + 1][k]))
            f.material_index = MI[mat]
            row.append(f)
        grid.append(row)
    return grid


def build_wheel(name, center, side):
    bm = bmesh.new()
    segs = WHEEL_SEGS
    half = math.pi / segs
    grid = lathe(bm, TYRE_PROFILE, segs, "Rubber", closed_profile=True, a0=half)   # closed bead ring
    core_r = 0.265
    for row in grid:
        for f in row:
            f.normal_update()
            c = f.calc_center_median()
            radial = Vector((0.0, c.y, c.z)).normalized()
            out = c - radial * core_r
            out.x = c.x
            if f.normal.dot(out) < 0.0:
                f.normal_flip()
    # chunky staggered gravel blocks on the three tread bands
    sel = []
    for band, parity in ((4, 0), (5, 1), (6, 0)):
        for k, f in enumerate(grid[band]):
            if k % 2 == parity:
                sel.append(f)
    ret = bmesh.ops.extrude_discrete_faces(bm, faces=sel)
    for f in ret["faces"]:
        c = f.calc_center_median()
        radial = Vector((0.0, c.y, c.z)).normalized()
        for v in f.verts:
            v.co += radial * TREAD_H
        c2 = f.calc_center_median()
        for v in f.verts:
            d = v.co - c2
            v.co = c2 + Vector((d.x * 0.84, d.y * 0.80, d.z * 0.80))
        # land the block tops exactly on the contract tyre radius
        r_max = max(math.hypot(v.co.y, v.co.z) for v in f.verts)
        for v in f.verts:
            v.co += radial * (TYRE_R - r_max)
    # rim barrel (closed profile loop)
    lathe(bm, RIM_PROFILE, segs, "Rim", closed_profile=True, a0=half)
    # spokes
    n_sp = 6
    for i in range(n_sp):
        a = 2 * math.pi * i / n_sp + math.pi / 2
        ca, sa = math.cos(a), math.sin(a)
        ta, tb = Vector((0, -sa, ca)), Vector((0, ca, sa))

        def P(r, w, x):
            return Vector((x, 0, 0)) + tb * r + ta * w

        v_in = [P(0.05, -0.028, 0.060), P(0.05, 0.028, 0.060), P(0.05, 0.028, 0.036), P(0.05, -0.028, 0.036)]
        v_mid = [P(0.12, -0.021, 0.082), P(0.12, 0.021, 0.082), P(0.12, 0.021, 0.060), P(0.12, -0.021, 0.060)]
        v_out = [P(0.186, -0.017, 0.098), P(0.186, 0.017, 0.098), P(0.186, 0.017, 0.074), P(0.186, -0.017, 0.074)]
        loft(bm, [v_in, v_mid, v_out], closed=True, cap_start=True, cap_end=True,
             mat_fn=lambda a_, j_: "Rim", cap_mat="Rim")
    # hub + centre cap
    m = Matrix.Translation((0.048, 0, 0)) @ rot_y(math.pi / 2).to_4x4()
    add_cylinder(bm, 0.066, 0.03, 12, "Rim", m)
    m = Matrix.Translation((0.070, 0, 0)) @ rot_y(math.pi / 2).to_4x4()
    add_cylinder(bm, 0.034, 0.016, 12, "Chrome", m, radius2=0.022)
    # lug nuts
    for i in range(5):
        a = 2 * math.pi * i / 5 + math.pi / 2 + math.pi / 6
        mm = Matrix.Translation((0.066, 0, 0)) @ Matrix.Translation((0, 0.048 * math.cos(a), 0.048 * math.sin(a))) @ rot_y(math.pi / 2).to_4x4()
        add_cylinder(bm, 0.009, 0.014, 6, "Chrome", mm)
    # brake disc
    m = Matrix.Translation((-0.024, 0, 0)) @ rot_y(math.pi / 2).to_4x4()
    add_cylinder(bm, 0.168, 0.02, WHEEL_SEGS, "Chrome", m)
    bmesh.ops.recalc_face_normals(bm, faces=[f for f in bm.faces if f.material_index != MI["Rubber"]])
    if side < 0:
        bmesh.ops.scale(bm, vec=Vector((-1, 1, 1)), verts=bm.verts)
        bmesh.ops.reverse_faces(bm, faces=bm.faces)
    ob = finalize(bm, name, smooth_angle=35.0, recalc=False)
    ob.location = center
    return ob


def build_caliper(name, center, side):
    bm = bmesh.new()
    a_mid = math.radians(145.0)      # behind the axle, upper rear quadrant (angle from +Y toward +Z)
    span = math.radians(46.0)
    n = 5
    ri, ro = 0.118, 0.176
    inner, outer = [], []
    for k in range(n + 1):
        a = a_mid - span / 2 + span * k / n
        inner.append((ri * math.cos(a), ri * math.sin(a)))
        outer.append((ro * math.cos(a), ro * math.sin(a)))
    poly = outer + list(reversed(inner))
    prism(bm, poly, 0.062, lambda u, v, w: Vector((-0.024 + w, u, v)), "Accent")
    if side < 0:
        bmesh.ops.scale(bm, vec=Vector((-1, 1, 1)), verts=bm.verts)
    ob = finalize(bm, name, smooth_angle=35.0, bevel_angle=40.0, bevel_width=0.006, bevel_segments=1)
    ob.location = center
    return ob


# --------------------------------------------------------------------------------------
# Assembly
# --------------------------------------------------------------------------------------


def tri_count(ob):
    return sum(len(p.vertices) - 2 for p in ob.data.polygons)


def build_car():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    build_materials()

    # --- shell: build, bevel, keep a copy for decal projection
    bm_shell = build_shell()
    shell = finalize(bm_shell, "Body", bevel_angle=26.0, bevel_width=0.011, bevel_segments=2,
                     bevel_skip_mats=("Trim",))
    bm_shell_final = bmesh.new()
    bm_shell_final.from_mesh(shell.data)

    bm_gh = build_greenhouse()
    bevel_sharp_edges(bm_gh, 24.0, 0.012, 2)
    recess_glass(bm_gh)
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
    bpy.ops.object.select_all(action="DESELECT")
    for ob in (gh, parts, decals):
        ob.select_set(True)
    shell.select_set(True)
    bpy.context.view_layer.objects.active = shell
    bpy.ops.object.join()
    body = bpy.context.view_layer.objects.active
    body.name = "Body"
    body.data.name = "Body"

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


def export(objs):
    os.makedirs(os.path.dirname(GLB_PATH), exist_ok=True)
    bpy.ops.object.select_all(action="DESELECT")
    for ob in objs:
        ob.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.export_scene.gltf(
        filepath=GLB_PATH,
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_yup=True,
        export_cameras=False,
        export_lights=False,
        export_extras=False,
        export_animations=False,
        export_texcoords=False,
        export_normals=True,
        export_materials="EXPORT",
    )
    bpy.context.preferences.filepaths.save_version = 0      # no rally_car.blend1 backups
    bpy.ops.wm.save_mainfile(filepath=BLEND_PATH, compress=True)


def report(objs):
    total = 0
    for ob in objs:
        t = tri_count(ob)
        total += t
        mats = sorted({ob.data.materials[p.material_index].name for p in ob.data.polygons})
        print(f"[car] {ob.name:12s} tris={t:6d} loc=({ob.location.x:+.3f},{ob.location.y:+.3f},{ob.location.z:+.3f}) mats={mats}")
    body = objs[0]
    xs = [v.co.x for v in body.data.vertices]
    ys = [v.co.y for v in body.data.vertices]
    zs = [v.co.z for v in body.data.vertices]
    print(f"[car] body bounds x[{min(xs):+.3f},{max(xs):+.3f}] y[{min(ys):+.3f},{max(ys):+.3f}] z[{min(zs):+.3f},{max(zs):+.3f}]")
    print(f"[car] total tris={total}")


# --------------------------------------------------------------------------------------
# Preview renders (toon approximation: stepped diffuse ramp + Freestyle ink lines)
# --------------------------------------------------------------------------------------


def toonify_materials():
    shadow = Vector(hex_rgb("#9a92c8"))
    for mat in MATERIALS:
        nt = mat.node_tree
        bsdf = nt.nodes.get("Principled BSDF")
        base = bsdf.inputs["Base Color"].default_value
        out = nt.nodes.get("Material Output")
        emissive = bsdf.inputs["Emission Strength"].default_value > 0.0
        diff = nt.nodes.new("ShaderNodeBsdfDiffuse")
        s2r = nt.nodes.new("ShaderNodeShaderToRGB")
        ramp = nt.nodes.new("ShaderNodeValToRGB")
        mix = nt.nodes.new("ShaderNodeMix")
        mix.data_type = "RGBA"
        mix.blend_type = "MULTIPLY"
        mix.inputs["Factor"].default_value = 1.0
        emit = nt.nodes.new("ShaderNodeEmission")
        cr = ramp.color_ramp
        cr.interpolation = "CONSTANT"
        cr.elements[0].position = 0.0
        cr.elements[0].color = (*(shadow * 0.95), 1.0)
        cr.elements[1].position = 0.18
        cr.elements[1].color = (0.86, 0.85, 0.93, 1.0)
        e = cr.elements.new(0.55)
        e.color = (1.0, 1.0, 1.0, 1.0)
        if mat.name.startswith("Paint"):
            e2 = cr.elements.new(0.93)
            e2.color = (1.12, 1.12, 1.12, 1.0)
        nt.links.new(diff.outputs["BSDF"], s2r.inputs["Shader"])
        nt.links.new(s2r.outputs["Color"], ramp.inputs["Fac"])
        nt.links.new(ramp.outputs["Color"], mix.inputs["A"])
        mix.inputs["B"].default_value = base
        nt.links.new(mix.outputs["Result"], emit.inputs["Color"])
        if emissive:
            emit.inputs["Color"].default_value = (min(1, base[0] * 1.2), min(1, base[1] * 1.2), min(1, base[2] * 1.2), 1.0)
            for link in list(nt.links):
                if link.to_node == emit:
                    nt.links.remove(link)
        nt.links.new(emit.outputs["Emission"], out.inputs["Surface"])


def setup_render_scene():
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 1600
    scene.render.resolution_y = 1000
    scene.render.film_transparent = False
    scene.view_settings.view_transform = "Standard"
    world = bpy.data.worlds.new("PreviewWorld")
    scene.world = world
    if world.node_tree is None:
        world.use_nodes = True
    bg = world.node_tree.nodes.get("Background")
    bg.inputs["Color"].default_value = (*hex_rgb("#dce8f0"), 1.0)
    bg.inputs["Strength"].default_value = 1.0
    # ground
    me = bpy.data.meshes.new("Ground")
    bm = bmesh.new()
    bmesh.ops.create_grid(bm, x_segments=1, y_segments=1, size=30.0)
    bm.to_mesh(me)
    g = bpy.data.objects.new("Ground", me)
    scene.collection.objects.link(g)
    gm = bpy.data.materials.new("GroundPreview")
    if gm.node_tree is None:
        gm.use_nodes = True
    gm.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (*hex_rgb("#cfd6c4"), 1)
    me.materials.append(gm)
    MATERIALS.append(gm)
    # sun
    ld = bpy.data.lights.new("Sun", "SUN")
    ld.energy = 4.0
    ld.angle = math.radians(1.0)
    sun = bpy.data.objects.new("Sun", ld)
    sun.rotation_euler = (math.radians(50), math.radians(-18), math.radians(-35))
    scene.collection.objects.link(sun)
    # ink lines
    scene.render.use_freestyle = True
    scene.render.line_thickness_mode = "ABSOLUTE"
    scene.render.line_thickness = 1.6
    vl = scene.view_layers[0]
    fs = vl.freestyle_settings
    fs.crease_angle = math.radians(128)
    ls = fs.linesets[0] if len(fs.linesets) else fs.linesets.new("Ink")
    if ls.linestyle is None:
        ls.linestyle = bpy.data.linestyles.new("Ink")
    ls.select_silhouette = True
    ls.select_border = False
    ls.select_crease = True
    ls.select_material_boundary = True
    ls.linestyle.color = hex_rgb("#2a2235")
    ls.linestyle.thickness = 1.6


def render_views():
    scene = bpy.context.scene
    cam_data = bpy.data.cameras.new("PreviewCam")
    cam = bpy.data.objects.new("PreviewCam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    os.makedirs(RENDER_DIR, exist_ok=True)
    views = {
        "front34": ((4.6, 5.4, 1.9), (0.0, 0.15, 0.62), 45),
        "rear34": ((-4.4, -5.6, 2.1), (0.0, -0.2, 0.62), 45),
        "side": ((8.5, 0.0, 0.85), (0.0, 0.0, 0.66), 50),
        "front": ((0.0, 8.0, 1.0), (0.0, 0.0, 0.66), 50),
        "top": ((0.0, 0.0, 9.5), (0.0, 0.0, 0.0), 45),
        "wheel": ((2.2, 1.9, 0.55), (0.78, 1.27, 0.36), 50),
        "low": ((-3.2, 4.2, 0.35), (0.0, 0.3, 0.75), 35),
    }
    for name, (loc, target, lens) in views.items():
        cam.location = loc
        d = Vector(target) - Vector(loc)
        cam.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
        cam_data.lens = lens
        if name == "top":
            cam.rotation_euler = (0.0, 0.0, 0.0)
        scene.render.filepath = os.path.join(RENDER_DIR, f"car_{name}.png")
        bpy.ops.render.render(write_still=True)
        print(f"[car] rendered {scene.render.filepath}")


def main():
    objs = build_car()
    report(objs)
    export(objs)
    print(f"[car] exported {GLB_PATH}")
    if DO_RENDER:
        setup_render_scene()
        toonify_materials()
        render_views()


main()
