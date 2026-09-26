"""Shared building blocks for the procedural car models (tools/blender/build_car*.py).

Materials, curve and bmesh helpers, decal projection, the greenhouse (cabin) loft, the
contract wheels and brake calipers, export, the build report and the toon preview renders.
Every car script calls `build_materials()` once with its own material table; the helpers
read the slot order from `MI` / `MATERIALS` afterwards.

Conventions (docs/CONTRACTS.md): Blender Z up, car front = +Y, right = +X,
origin at axle midpoint on the ground.
"""

import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

# --------------------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------------------

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
DO_RENDER = "--render" in ARGS
RENDER_DIR = os.path.join(ROOT, "docs", "renders")

# --------------------------------------------------------------------------------------
# Contract geometry (shared by every car)
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

# --------------------------------------------------------------------------------------
# Materials
# --------------------------------------------------------------------------------------


def _lin(c: float) -> float:
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def hex_rgb(h: str):
    h = h.lstrip("#")
    return tuple(_lin(int(h[i:i + 2], 16) / 255.0) for i in (0, 2, 4))


MI = {}             # material name -> slot index, filled by build_materials()
MATERIALS = []


def build_materials(specs):
    """specs: [(name, hex, roughness, metallic, emission hex or None, emission strength)]."""
    MI.clear()
    MATERIALS.clear()
    for i, spec in enumerate(specs):
        MI[spec[0]] = i
    for name, hx, rough, metal, ehx, estr in specs:
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


# --------------------------------------------------------------------------------------
# Greenhouse (cabin) - vertical loft of plan-view rings
# --------------------------------------------------------------------------------------


def mirror_loop(half):
    """Closed loop from a right-half polyline running centre-front -> centre-rear."""
    right = list(half)
    left = [(-x, y) for (x, y) in reversed(half[1:-1])]
    return right + left


class Greenhouse:
    """Cabin lofted upward from ring0 (seated on the body top) to ring1 (roof edge), then in
    to a roof cap ring. `windows` are (t_start, t_end, inset_start, inset_end) ranges of
    loop parameter; the insets are the pillar widths in metres along ring0 (times `scale1`
    along ring1). `rows` are the loft rows as fractions ring0 -> ring1."""

    def __init__(self, ring0, ring1, windows, rows, roof_ring, scale1=0.8):
        self.r0 = ring0
        self.r1 = ring1
        self.windows = windows
        self.rows = rows
        self.roof_ring = roof_ring          # fn(ring1 column points) -> roof cap ring points
        self.scale1 = scale1
        self.n = len(ring0)

    def columns(self, ring, scale):
        """Loop parameters of all columns on one ring: every ring vertex plus the pillar
        edges of each window (pillar widths measured along this ring)."""
        ts = [float(k) for k in range(self.n)]
        for (t0, t1, i0, i1) in self.windows:
            ts.append(ring_advance(ring, t0, i0 * scale) % self.n)
            ts.append(ring_advance(ring, t1, -i1 * scale) % self.n)
        return sorted(ts)

    def window_of(self, t):
        """Index of the window whose glass (inside its pillars) covers loop parameter t, or -1."""
        for i, (t0, t1, i0, i1) in enumerate(self.windows):
            g0 = ring_advance(self.r0, t0, i0)
            g1 = ring_advance(self.r0, t1, -i1)
            tt = t if t >= g0 else t + self.n
            if g0 < tt < g1:
                return i
        return -1

    def build(self, mat_fn, cap_mat, centre):
        """mat_fn(row_band, window_index) -> material name. Normals face away from `centre`."""
        c0 = self.columns(self.r0, 1.0)
        c1 = self.columns(self.r1, self.scale1)
        p0 = [ring_at(self.r0, t) for t in c0]
        p1 = [ring_at(self.r1, t) for t in c1]
        p2 = self.roof_ring(p1)
        rings = [[a.lerp(b, v) for a, b in zip(p0, p1)] for v in self.rows] + [p2]
        n = len(c0)

        def column_window(j):
            ta, tb = c0[j], c0[(j + 1) % n]
            if tb < ta:
                tb += self.n
            return self.window_of(((ta + tb) * 0.5) % self.n)

        bm = bmesh.new()
        loft(bm, rings, closed=True, cap_start=False, cap_end=True,
             mat_fn=lambda a, j: mat_fn(a, column_window(j)), cap_mat=cap_mat)
        for f in bm.faces:
            f.normal_update()
            if f.normal.dot(f.calc_center_median() - centre) < 0.0:
                f.normal_flip()
        return bm


def recess_glass(bm, inset, depth):
    """Inset every window into the greenhouse: a dark rubber seal and recessed glass,
    so the ink shader gets a real depth edge around each pane."""
    glass = [f for f in bm.faces if f.material_index == MI["Glass"]]
    ret = bmesh.ops.inset_region(bm, faces=glass, thickness=inset, depth=-depth,
                                 use_even_offset=True, use_boundary=True)
    set_mat(ret["faces"], "Trim")


# --------------------------------------------------------------------------------------
# Livery fonts
# --------------------------------------------------------------------------------------

FONT_NUMBER = "/System/Library/Fonts/Supplemental/DIN Alternate Bold.ttf"
FONT_BANNER = "/System/Library/Fonts/Supplemental/DIN Condensed Bold.ttf"

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


def spokes_six(bm):
    """Six tapered spokes, each lofted hub -> barrel through a mid section."""
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


def build_wheel(name, center, side, spokes=spokes_six):
    """Contract tyre (radius TYRE_R, width TYRE_W, gravel tread blocks), rim barrel, the
    `spokes(bm)` face, hub, lug nuts and brake disc. Origin at the wheel centre, axle along X;
    left wheels (side < 0) are mirrored so the rim faces outward."""
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
    spokes(bm)
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
# Assembly, export, report
# --------------------------------------------------------------------------------------

def tri_count(ob):
    return sum(len(p.vertices) - 2 for p in ob.data.polygons)


def join_objects(target, others, name):
    """Join `others` into `target`; the result is renamed `name` (object and mesh)."""
    bpy.ops.object.select_all(action="DESELECT")
    for ob in others:
        ob.select_set(True)
    target.select_set(True)
    bpy.context.view_layer.objects.active = target
    bpy.ops.object.join()
    joined = bpy.context.view_layer.objects.active
    joined.name = name
    joined.data.name = name
    return joined


def export(objs, glb_path, blend_path=None):
    os.makedirs(os.path.dirname(glb_path), exist_ok=True)
    bpy.ops.object.select_all(action="DESELECT")
    for ob in objs:
        ob.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.export_scene.gltf(
        filepath=glb_path,
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
    if blend_path:
        bpy.context.preferences.filepaths.save_version = 0      # no .blend1 backups
        bpy.ops.wm.save_mainfile(filepath=blend_path, compress=True)


def report(objs, tag="car"):
    total = 0
    for ob in objs:
        t = tri_count(ob)
        total += t
        mats = sorted({ob.data.materials[p.material_index].name for p in ob.data.polygons})
        print(f"[{tag}] {ob.name:12s} tris={t:6d} loc=({ob.location.x:+.3f},{ob.location.y:+.3f},{ob.location.z:+.3f}) mats={mats}")
    body = objs[0]
    xs = [v.co.x for v in body.data.vertices]
    ys = [v.co.y for v in body.data.vertices]
    zs = [v.co.z for v in body.data.vertices]
    print(f"[{tag}] body bounds x[{min(xs):+.3f},{max(xs):+.3f}] y[{min(ys):+.3f},{max(ys):+.3f}] z[{min(zs):+.3f},{max(zs):+.3f}]")
    print(f"[{tag}] total tris={total}")


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


# name: (camera location, look-at target, lens mm); "top" looks straight down
PREVIEW_VIEWS = {
    "front34": ((4.6, 5.4, 1.9), (0.0, 0.15, 0.62), 45),
    "rear34": ((-4.4, -5.6, 2.1), (0.0, -0.2, 0.62), 45),
    "side": ((8.5, 0.0, 0.85), (0.0, 0.0, 0.66), 50),
    "front": ((0.0, 8.0, 1.0), (0.0, 0.0, 0.66), 50),
    "top": ((0.0, 0.0, 9.5), (0.0, 0.0, 0.0), 45),
    "wheel": ((2.2, 1.9, 0.55), (0.78, 1.27, 0.36), 50),
    "low": ((-3.2, 4.2, 0.35), (0.0, 0.3, 0.75), 35),
}


def render_views(prefix, views, tag="car"):
    """Render each named view to docs/renders/<prefix>_<name>.png."""
    scene = bpy.context.scene
    cam = scene.camera
    if cam is None:
        cam_data = bpy.data.cameras.new("PreviewCam")
        cam = bpy.data.objects.new("PreviewCam", cam_data)
        scene.collection.objects.link(cam)
        scene.camera = cam
    os.makedirs(RENDER_DIR, exist_ok=True)
    for name, (loc, target, lens) in views.items():
        cam.location = loc
        d = Vector(target) - Vector(loc)
        cam.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
        cam.data.lens = lens
        if name == "top":
            cam.rotation_euler = (0.0, 0.0, 0.0)
        scene.render.filepath = os.path.join(RENDER_DIR, f"{prefix}_{name}.png")
        bpy.ops.render.render(write_still=True)
        print(f"[{tag}] rendered {scene.render.filepath}")
