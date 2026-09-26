"""Spectators in the cel look: anime background characters (~1.6-1.75 m adults, one child,
a course marshal). Front = +Y (facing the road), right hand side = +X, origin at the feet.

Every person uses two materials so a crowd costs two draw calls per MultiMesh:
  Crowd_Base  white; the vertex colours carry every colour (skin, hair, clothes, face)
  Crowd_Dye   white; the main garment, tinted per instance at runtime (MultiMesh custom data
              rgb, scripts/world/crowd.gd picks it from a palette), so one model makes many people
The vertex colour alpha weights the idle / cheer motion of shaders/inc/crowd.gdshaderinc:
0 on the body, rising along the arms to the pose's arm energy at the hands (and whatever the
hands hold). The marshal has no dyed part.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Callable, Sequence

import bmesh
from mathutils import Matrix, Vector

from .common import MATERIALS, Kit, bm_cyl, bm_hull, bm_ico, bm_tube, look_matrix, trs
from .registry import cyl, prop

MATERIALS.update({"Crowd_Base": ("#ffffff", 0.0), "Crowd_Dye": ("#ffffff", 0.0)})
BASE = "Crowd_Base"
DYE = "Crowd_Dye"
DYED = None  # a garment colour of None means "dyed per instance"

PEOPLE = ["spring", "autumn"]
PLACE = ["spectator_zone", "roadside"]


# ---------------------------------------------------------------------------------- colour
def hexc(h: str) -> tuple[float, float, float]:
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4))  # type: ignore[return-value]


def paint(col: str | None, low: float = 0.8, cool: bool = True) -> Callable:
    """Vertex colour: the sRGB colour (white for the dye) times a soft top-lit gradient
    (undersides cooler and darker)."""
    c = (1.0, 1.0, 1.0) if col is None else hexc(col)
    lo = (low * 0.97, low * 0.95, low * 1.04) if cool else (low, low, low)

    def fn(co: Vector, n: Vector) -> tuple[float, float, float, float]:
        t = max(0.0, min(1.0, n.z * 0.5 + 0.62))
        return (c[0] * (lo[0] + (1 - lo[0]) * t), c[1] * (lo[1] + (1 - lo[1]) * t),
                c[2] * (lo[2] + (1 - lo[2]) * t), 1.0)
    return fn


def flat(col: str) -> tuple[float, float, float, float]:
    c = hexc(col)
    return (c[0], c[1], c[2], 1.0)


def mat_of(col: str | None) -> str:
    return DYE if col is None else BASE


SKIN = {"fair": "#f8dcc8", "warm": "#f0c6a6", "tan": "#d9a47f", "deep": "#b27a58"}
HAIR = {"black": "#2c2731", "dark": "#47302a", "brown": "#74492f", "chestnut": "#94583a",
        "grey": "#bdb8ba", "ash": "#8f8a8e", "honey": "#c98f4e", "pink": "#e79ab7"}
INK = "#2a2233"
MOUTH = "#9c3a48"
BLUSH = "#f4a2a4"
WHITE = "#f6f3ec"


# ---------------------------------------------------------------------------------- weights
class Part:
    """Sets the vertex colour alpha (motion weight) of every face added inside the block:
    a constant, or a function of the vertex position."""

    def __init__(self, kit: Kit, w: float | Callable[[Vector], float] = 0.0):
        self.kit = kit
        self.w = w

    def __enter__(self) -> "Part":
        self.n0 = len(self.kit.bm.faces)
        return self

    def __exit__(self, *exc) -> None:
        bm = self.kit.bm
        bm.faces.ensure_lookup_table()
        for i in range(self.n0, len(bm.faces)):
            for loop in bm.faces[i].loops:
                c = loop[self.kit.col]
                w = self.w(loop.vert.co) if callable(self.w) else self.w
                loop[self.kit.col] = (c[0], c[1], c[2], max(0.0, min(1.0, w)))


def arm_weight(shoulder: Vector, length: float, energy: float) -> Callable[[Vector], float]:
    return lambda co: energy * max(0.0, min(1.0, ((co - shoulder).length / length - 0.2) / 0.8)) ** 1.3


# ---------------------------------------------------------------------------------- geometry
def loft(kit: Kit, mat: str, rings: Sequence[tuple], sides: int, color, m: Matrix | None = None,
         cap0: bool = True, cap1: bool = True, phase: float = 0.0, both: bool = False) -> None:
    """Rings (cx, cy, cz, rx, ry) of horizontal ellipses joined into a tube (bottom to top)."""
    verts = []
    faces = []
    for (cx, cy, cz, rx, ry) in rings:
        for k in range(sides):
            a = phase + 2 * math.pi * k / sides
            verts.append((cx + math.sin(a) * rx, cy + math.cos(a) * ry, cz))
    for r in range(len(rings) - 1):
        for k in range(sides):
            a0 = r * sides + k
            a1 = r * sides + (k + 1) % sides
            faces.append((a0, a1, a1 + sides, a0 + sides))
    if cap0:
        faces.append(tuple(range(sides))[::-1])
    if cap1:
        top = (len(rings) - 1) * sides
        faces.append(tuple(range(top, top + sides)))
    bm = bmesh.new()
    vs = [bm.verts.new(v) for v in verts]
    for f in faces:
        bm.faces.new([vs[i] for i in f])
    # a -> (sin, cos) runs clockwise seen from above: flip so the normals face out
    for f in bm.faces:
        f.normal_update()
    bmesh.ops.reverse_faces(bm, faces=list(bm.faces))
    if both:
        n = len(bm.faces)
        dup = bmesh.ops.duplicate(bm, geom=list(bm.faces))
        new_faces = [g for g in dup["geom"] if isinstance(g, bmesh.types.BMFace)]
        bmesh.ops.reverse_faces(bm, faces=new_faces)
        assert len(bm.faces) == 2 * n
    kit.add(bm, mat, m, color)


def tube(kit: Kit, mat: str, pts: Sequence[Vector], radii: Sequence[float], sides: int, color,
         cap0: bool = True, cap1: bool = True) -> None:
    kit.add(bm_tube([Vector(p) for p in pts], radii, sides, cap0, cap1), mat, None, color)


def blob(kit: Kit, mat: str, center: Vector, size: Sequence[float], color, sub: int = 1,
         r: Sequence[float] = (0, 0, 0)) -> None:
    kit.add(bm_ico(sub, 1.0), mat, trs(center, r, size), color)


def decal(kit: Kit, col: str, pts: Sequence[Vector], color=None, out: Vector | None = None) -> None:
    """Flat polygon (points in order, counter-clockwise seen from its front); with `out`, it
    faces that way whatever the order of the points."""
    if out is not None:
        nrm = Vector((0, 0, 0))
        for a, b in zip(pts, list(pts[1:]) + [pts[0]]):
            nrm += a.cross(b)
        if nrm.dot(out) < 0:
            pts = list(reversed(pts))
    bm = bmesh.new()
    vs = [bm.verts.new(p) for p in pts]
    bm.faces.new(vs)
    kit.add(bm, BASE, None, color or flat(col))


def oval(c: Vector, u: Vector, v: Vector, w: float, h: float, n: int = 6, squash_top: float = 1.0) -> list[Vector]:
    out = []
    for k in range(n):
        a = 2 * math.pi * k / n
        y = math.sin(a) * h
        if y > 0:
            y *= squash_top
        out.append(c + u * (math.cos(a) * w) + v * y)
    return out


# ---------------------------------------------------------------------------------- the head
HX, HY, HZ = 0.9, 0.97, 1.07  # unit head ellipsoid (x wide, y deep, z tall)


def head_shape(p: Vector) -> Vector:
    """Anime face: a narrower jaw and a pointed chin, a fuller back of the head."""
    x, y, z = p.x, p.y, p.z
    if z < 0:
        t = min(1.0, -z / HZ)
        x *= 1.0 - 0.3 * t ** 1.4
        if y > 0:
            y *= 1.0 - 0.14 * t
    if y < 0:
        y *= 1.06
    return Vector((x, y, z))


def head_point(x: float, z: float, lift: float = 0.02) -> tuple[Vector, Vector]:
    """Point on the unit head's front at (x, z), lifted along the normal, and the normal."""
    q = 1.0 - (x / HX) ** 2 - (z / HZ) ** 2
    y = HY * math.sqrt(max(q, 0.0))
    n = Vector((x / HX ** 2, y / HY ** 2, z / HZ ** 2)).normalized()
    p = head_shape(Vector((x, y, z)))
    return p + n * lift, n


def face_frame(x: float, z: float, lift: float = 0.02) -> tuple[Vector, Vector, Vector]:
    p, n = head_point(x, z, lift)
    u = Vector((1, 0, 0)) - n * n.x  # the head's x, in the tangent plane
    u.normalize()
    v = n.cross(u).normalized() * -1.0
    if v.z < 0:
        v = -v
    return p, u, v


@dataclass
class Look:
    skin: str = SKIN["warm"]
    hair: str = HAIR["black"]
    hair_style: str = "short"   # short, spiky, bob, long, ponytail, bun, twintails, buzz
    top: str = "tee"            # tee, hoodie, jacket, happi, cardigan, puffer, yukata, vest, hivis
    top_col: str | None = DYED
    inner: str = WHITE          # shirt under an open jacket, collar
    bottom: str = "pants"       # pants, shorts, skirt, long_skirt, none (yukata)
    bottom_col: str = "#44506f"
    shoes: str = "#f2efe8"
    sole: str = "#f6f3ec"
    socks: str | None = None
    hat: str | None = None      # cap, cap_back, bucket, hachimaki, school, helmet, beanie, flatcap, sunhat
    hat_col: str = "#d9483e"
    mouth: str = "smile"        # smile, open, o, line
    female: bool = False
    lashes: bool = False
    head: float = 0.118         # head radius (m)
    blush: bool = True


@dataclass
class Pose:
    hip_z: float = 0.9
    lean: float = 0.0           # degrees forward
    knee: tuple = ((0.1, 0.02, 0.48), (-0.1, 0.02, 0.48))      # right (+x), left
    ankle: tuple = ((0.11, -0.01, 0.075), (-0.11, -0.01, 0.075))
    elbow: tuple = ((0.24, -0.01, 1.1), (-0.24, -0.01, 1.1))    # in the upper body frame
    wrist: tuple = ((0.26, 0.03, 0.86), (-0.26, 0.03, 0.86))
    energy: tuple = (0.35, 0.35)
    head_turn: float = 0.0
    head_tilt: float = 0.0      # nod, degrees (positive looks up)
    head_roll: float = 0.0


HIP0 = 0.9
SHOULDER_Z = 1.37


class Figure:
    """Builds one person into a kit from a Look and a Pose; exposes the hands for props."""

    def __init__(self, kit: Kit, look: Look, pose: Pose, leg: float = 1.0):
        self.kit = kit
        self.l = look
        self.p = pose
        self.leg = leg
        self.up = (Matrix.Translation((0, 0, pose.hip_z)) @ Matrix.Rotation(math.radians(-pose.lean), 4, "X")
                   @ Matrix.Translation((0, 0, -HIP0)))
        self.sh_x = 0.165 if look.female else 0.185
        self.hands: dict[int, Vector] = {}
        self.hand_dir: dict[int, Vector] = {}
        self.head_m = Matrix.Identity(4)

    def U(self, x: float, y: float, z: float) -> Vector:
        return self.up @ Vector((x, y, z))

    # ---------------------------------------------------------------- torso
    def torso_rings(self, grow: float = 0.0, hem: float = 0.8, top: float = 1.45) -> list[tuple]:
        f = self.l.female
        prof = [(0.80, 0.15, 0.095), (0.9, 0.172 if f else 0.162, 0.1), (1.02, 0.128 if f else 0.142, 0.088),
                (1.19, 0.148 if f else 0.162, 0.104), (1.32, 0.162 if f else 0.18, 0.098),
                (1.395, 0.13 if f else 0.148, 0.082), (1.45, 0.062, 0.056)]
        rings = []
        for z, rx, ry in prof:
            if z < hem - 1e-6 or z > top + 1e-6:
                continue
            g = grow if z < 1.44 else grow * 0.4
            rings.append((0.0, 0.004 if z > 1.1 else 0.0, z, rx + g, ry + g))
        if rings[0][2] > hem + 1e-6:  # extend a longer garment below the hips
            _, cy, z0, rx0, ry0 = rings[0]
            flare = (z0 - hem) * 0.25
            rings.insert(0, (0.0, 0.0, hem, rx0 + flare, ry0 + flare * 0.7))
        return rings

    def front_y(self, z: float, grow: float) -> float:
        rings = self.torso_rings(grow, hem=0.6)
        for a, b in zip(rings, rings[1:]):
            if a[2] <= z <= b[2]:
                t = (z - a[2]) / max(1e-6, b[2] - a[2])
                return a[1] + a[4] + (b[1] + b[4] - a[1] - a[4]) * t
        return rings[-1][1] + rings[-1][4]

    def strip(self, col: str | None, x0: float, x1: float, z0: float, z1: float, grow: float, n: int = 4,
              lift: float = 0.006) -> None:
        """A vertical band on the torso front (open jacket, zip, collar bands)."""
        pts_l = []
        pts_r = []
        for i in range(n + 1):
            z = z0 + (z1 - z0) * i / n
            y = self.front_y(z, grow) + lift
            pts_l.append(self.U(x0, y, z))
            pts_r.append(self.U(x1, y, z))
        for i in range(n):
            decal(self.kit, col or WHITE, [pts_l[i], pts_r[i], pts_r[i + 1], pts_l[i + 1]],
                  None if col else (1, 1, 1, 1), out=self.up.to_3x3() @ Vector((0, 1, 0)))
            if col is None:  # a dyed strip: its face goes onto the dye material
                self.kit.bm.faces.ensure_lookup_table()
                self.kit.bm.faces[-1].material_index = self.kit.mat(DYE)

    def band(self, col: str | None, z: float, h: float, grow: float, sides: int = 10) -> None:
        rings = self.torso_rings(grow, hem=0.6)
        def at(zz: float) -> tuple:
            for a, b in zip(rings, rings[1:]):
                if a[2] <= zz <= b[2]:
                    t = (zz - a[2]) / max(1e-6, b[2] - a[2])
                    return tuple(a[i] + (b[i] - a[i]) * t for i in range(5))
            return rings[-1]
        r0 = at(z - h / 2)
        r1 = at(z + h / 2)
        loft(self.kit, mat_of(col), [(r0[0], r0[1], r0[2], r0[3] + 0.008, r0[4] + 0.008),
                                     (r1[0], r1[1], r1[2], r1[3] + 0.008, r1[4] + 0.008)],
             sides, paint(col), self.up, cap0=False, cap1=False)

    def torso(self) -> None:
        l = self.l
        k = self.kit
        top = l.top
        c = l.top_col
        if top == "tee":
            loft(k, mat_of(c), self.torso_rings(0.004, hem=0.84), 10, paint(c), self.up)
            self.collar(l.top_col, 0.012)
        elif top == "hoodie":
            loft(k, mat_of(c), self.torso_rings(0.018, hem=0.83), 10, paint(c), self.up)
            self.band(c, 0.85, 0.05, 0.028)
            # kangaroo pocket and drawstrings
            self.strip(None if c is None else c, -0.09, 0.09, 0.9, 1.02, 0.024, 1, 0.008)
            for sx in (-0.035, 0.035):
                self.strip(WHITE, sx - 0.006, sx + 0.006, 1.22, 1.36, 0.02, 1, 0.01)
            # the hood lying on the back
            blob(k, mat_of(c), self.U(0, -0.1, 1.43), (0.15, 0.08, 0.075), paint(c), 1, (15, 0, 0))
        elif top == "jacket":
            loft(k, mat_of(c), self.torso_rings(0.02, hem=0.82), 10, paint(c), self.up)
            self.strip(l.inner, -0.045, 0.045, 0.83, 1.4, 0.02, 4, 0.004)
            self.strip("#3a3440", -0.004, 0.004, 0.83, 1.28, 0.02, 3, 0.008)
            self.collar(c, 0.03, h=0.06)
        elif top == "cardigan":
            loft(k, mat_of(c), self.torso_rings(0.014, hem=0.82), 10, paint(c), self.up)
            self.strip(l.inner, -0.06, 0.06, 1.12, 1.41, 0.014, 2, 0.004)
            for z in (0.95, 1.04, 1.12):
                self.strip("#f2e6c8", -0.012, 0.012, z - 0.01, z + 0.01, 0.014, 1, 0.009)
        elif top == "puffer":
            rings = []
            for i, (cx, cy, z, rx, ry) in enumerate(self.torso_rings(0.03, hem=0.8)):
                bulge = 0.022 if i % 2 == 0 and z < 1.38 else 0.0
                rings.append((cx, cy, z, rx + bulge, ry + bulge))
            loft(k, mat_of(c), rings, 10, paint(c), self.up)
            self.collar(c, 0.04, h=0.08)
            self.strip("#3a3440", -0.004, 0.004, 0.81, 1.3, 0.05, 3, 0.012)
        elif top == "happi":
            loft(k, mat_of(c), self.torso_rings(0.022, hem=0.66), 10, paint(c), self.up)
            # dark collar bands down both sides of the front, a white inner shirt, the obi
            self.strip(l.inner, -0.03, 0.03, 0.9, 1.41, 0.022, 3, 0.004)
            for sx in (-1, 1):
                self.strip("#2d2a4a", sx * 0.03, sx * 0.07, 0.67, 1.42, 0.022, 5, 0.007)
            self.band("#2d2a4a", 0.99, 0.07, 0.03)
        elif top == "yukata":
            rings = self.torso_rings(0.02, hem=0.8)
            rings = [(0.0, 0.0, 0.1, 0.2, 0.15), (0.0, 0.0, 0.45, 0.19, 0.14)] + rings
            loft(k, mat_of(c), rings, 10, paint(c), self.up)
            for sx in (-1, 1):  # crossed collar
                self.strip(l.inner, sx * 0.01, sx * 0.05, 1.18, 1.43, 0.02, 3, 0.006)
            self.band("#e2a93b", 1.03, 0.12, 0.034)
            self.band("#d2413a", 1.03, 0.025, 0.05)
        elif top == "vest":  # shirt (dyed) under a many-pocket khaki vest
            loft(k, mat_of(c), self.torso_rings(0.006, hem=0.84), 10, paint(c), self.up)
            loft(k, BASE, self.torso_rings(0.024, hem=0.82, top=1.395), 10, paint("#b7a27a"), self.up, cap1=False)
            self.strip(None, -0.04, 0.04, 0.83, 1.4, 0.024, 3, 0.004)
            for sx in (-1, 1):
                for z in (0.9, 1.18):
                    self.strip("#9c8963", sx * 0.06, sx * 0.13, z, z + 0.08, 0.024, 1, 0.007)
            self.collar(c, 0.012)
        elif top == "hivis":
            loft(k, BASE, self.torso_rings(0.006, hem=0.84), 10, paint(WHITE), self.up)
            loft(k, BASE, self.torso_rings(0.022, hem=0.8, top=1.395), 10, paint("#f6781f"), self.up, cap1=False)
            for z in (0.92, 1.12):
                self.band("#dfe3e6", z, 0.035, 0.026)
            self.strip("#f6781f", -0.03, 0.03, 0.8, 1.38, 0.024, 3, 0.008)
        # neck
        tube(k, BASE, [self.U(0, 0.004, 1.42), self.U(0, 0.008, 1.5)], [0.045, 0.042], 6, paint(l.skin, 0.86))

    def collar(self, col: str | None, grow: float, h: float = 0.035) -> None:
        loft(self.kit, mat_of(col), [(0, 0.004, 1.43, 0.07 + grow, 0.062 + grow),
                                     (0, 0.004, 1.43 + h, 0.066 + grow, 0.058 + grow)],
             8, paint(col), self.up, cap0=False, cap1=False, both=True)

    # ---------------------------------------------------------------- legs
    def legs(self) -> None:
        l = self.l
        k = self.kit
        for i, side in enumerate((1, -1)):
            hip = self.U(side * 0.088, 0.0, HIP0 - 0.04)
            knee = Vector(self.p.knee[i])
            ankle = Vector(self.p.ankle[i])
            skin = paint(l.skin, 0.85)
            if l.bottom == "pants":
                tube(k, BASE, [hip, knee, ankle + Vector((0, 0, 0.02))], [0.085, 0.064, 0.056], 7,
                     paint(l.bottom_col), cap0=False)
            elif l.bottom == "shorts":
                mid = hip.lerp(knee, 0.62)
                tube(k, BASE, [hip, mid], [0.088, 0.082], 7, paint(l.bottom_col), cap0=False)
                tube(k, BASE, [mid, knee, ankle], [0.06, 0.05, 0.036], 6, skin, cap0=False)
            elif l.bottom in ("skirt", "long_skirt", "none"):
                tube(k, BASE, [hip, knee, ankle], [0.07, 0.048, 0.036], 6, skin, cap0=False)
            if l.socks:
                tube(k, BASE, [ankle + Vector((0, 0, 0.0)), ankle.lerp(knee, 0.55 if l.bottom == "skirt" else 0.25)],
                     [0.041, 0.047], 6, paint(l.socks), cap0=False, cap1=False)
            self.shoe(ankle, side)
        if l.bottom == "skirt":
            loft(k, BASE, [(0, 0.0, 0.58, 0.22, 0.19), (0, 0.0, 0.78, 0.18, 0.14), (0, 0.004, 1.0, 0.135, 0.095)],
                 10, paint(l.bottom_col), self.up, cap0=True, cap1=False)
        elif l.bottom == "long_skirt":
            loft(k, BASE, [(0, 0.0, 0.2, 0.25, 0.22), (0, 0.0, 0.6, 0.2, 0.16), (0, 0.004, 1.0, 0.135, 0.095)],
                 10, paint(l.bottom_col), self.up, cap0=True, cap1=False)

    def shoe(self, ankle: Vector, side: int) -> None:
        a = ankle
        pts = []
        for (x, y, z) in ((0.045, -0.06, 0.0), (-0.045, -0.06, 0.0), (0.05, 0.14, 0.0), (-0.05, 0.14, 0.0),
                          (0.04, -0.05, 0.075), (-0.04, -0.05, 0.075), (0.042, 0.1, 0.05), (-0.042, 0.1, 0.05),
                          (0.0, 0.16, 0.025)):
            pts.append(Vector((a.x + x, a.y + y, max(0.0, a.z - 0.075) + z)))
        self.kit.add(bm_hull(pts), BASE, None, paint(self.l.shoes))
        sole = [Vector((a.x + x, a.y + y, max(0.0, a.z - 0.075) + z)) for (x, y, z) in (
            (0.05, -0.065, 0.0), (-0.05, -0.065, 0.0), (0.055, 0.165, 0.0), (-0.055, 0.165, 0.0),
            (0.05, -0.065, 0.02), (-0.05, -0.065, 0.02), (0.055, 0.165, 0.02), (-0.055, 0.165, 0.02))]
        self.kit.add(bm_hull(sole), BASE, None, paint(self.l.sole))

    # ---------------------------------------------------------------- arms
    def arms(self) -> None:
        l = self.l
        k = self.kit
        top = l.top
        for i, side in enumerate((1, -1)):
            sh = self.U(side * self.sh_x, 0.0, SHOULDER_Z)
            el = self.U(*self.p.elbow[i])
            wr = self.U(*self.p.wrist[i])
            length = (el - sh).length + (wr - el).length
            w = arm_weight(sh, length, self.p.energy[i])
            with Part(k, w):
                skin = paint(l.skin, 0.85)
                sleeve_col = l.top_col if top not in ("vest", "hivis") else (l.top_col if top == "vest" else WHITE)
                sm = mat_of(sleeve_col)
                if top in ("tee", "hivis"):
                    mid = sh.lerp(el, 0.55)
                    tube(k, sm, [sh, mid], [0.062, 0.058], 7, paint(sleeve_col), cap0=True, cap1=True)
                    tube(k, BASE, [mid, el, wr], [0.043, 0.038, 0.031], 6, skin, cap0=False)
                elif top in ("happi", "yukata"):
                    cuff = el.lerp(wr, 0.45 if top == "happi" else 0.7)
                    tube(k, sm, [sh, el, cuff], [0.062, 0.075, 0.095 if top == "yukata" else 0.075], 7,
                         paint(sleeve_col), cap0=True, cap1=False)
                    tube(k, BASE, [el.lerp(cuff, 0.5), wr], [0.036, 0.031], 6, skin, cap0=False)
                    if top == "yukata":  # the long sleeve hangs below the forearm
                        hang = [el, cuff, cuff + Vector((0, 0, -0.16)), el + Vector((0, 0, -0.12))]
                        kit_quad(k, sm, hang, paint(sleeve_col))
                else:
                    r = 0.07 if top == "puffer" else 0.06
                    cuff = wr + (el - wr).normalized() * 0.03
                    tube(k, sm, [sh, el, cuff], [r, r * 0.88, r * 0.78], 7, paint(sleeve_col), cap0=True)
                    tube(k, BASE, [cuff, wr], [0.03, 0.03], 6, skin, cap0=False, cap1=False)
                # hand: a mitten along the forearm
                d = (wr - el).normalized()
                hand = wr + d * 0.05
                blob(k, BASE, hand, (0.036, 0.026, 0.05), skin, 1)
                self.hands[side] = hand
                self.hand_dir[side] = d

    # ---------------------------------------------------------------- head
    def head(self) -> None:
        l = self.l
        p = self.p
        k = self.kit
        r = l.head
        neck_top = self.U(0, 0.01, 1.5)
        rot = (Matrix.Rotation(math.radians(p.head_turn), 4, "Z") @ Matrix.Rotation(math.radians(-p.head_tilt), 4, "X")
               @ Matrix.Rotation(math.radians(p.head_roll), 4, "Y"))
        lean = Matrix.Rotation(math.radians(-self.p.lean), 4, "X")
        self.head_m = Matrix.Translation(neck_top) @ lean @ rot @ Matrix.Translation((0, 0.012, 0.1)) \
            @ Matrix.Diagonal((r, r, r, 1.0))
        M = self.head_m
        # skull
        bm = bm_ico(2, 1.0)
        for v in bm.verts:
            v.co = head_shape(Vector((v.co.x * HX, v.co.y * HY, v.co.z * HZ)))
        k.add(bm, BASE, M, paint(l.skin, 0.88))
        # ears
        for sx in (-1, 1):
            e = bm_cyl(0.2, 0.2, 0.08, 5)
            k.add(e, BASE, M @ trs((sx * HX * 0.97, -0.05, -0.08), (0, 90, 0), (1.0, 0.75, 1.0)), paint(l.skin, 0.85))
        self.face()
        self.hair()
        if l.hat:
            self.hat()

    def face(self) -> None:
        l = self.l
        k = self.kit
        M = self.head_m
        centre = M.to_translation()

        def put(col: str, pts: list[Vector]) -> None:
            wp = [M @ q for q in pts]
            decal(k, col, wp, out=sum(wp, Vector()) / len(wp) - centre)

        for sx in (-1, 1):
            # eyes: tall dark ovals with a lash line and a highlight
            c, u, v = face_frame(sx * 0.36, -0.1)
            pts = oval(c, u, v, 0.12, 0.17, 7, 0.9)
            put(INK, [q for q in pts])
            c2, _, _ = face_frame(sx * 0.36 + 0.035 - sx * 0.02, -0.03, 0.028)
            put(WHITE, [q for q in oval(c2, u, v, 0.035, 0.035, 4)])
            c3, u3, v3 = face_frame(sx * 0.36, 0.07, 0.026)
            lash = [c3 + u3 * (-0.15) + v3 * -0.01, c3 + u3 * 0.15 + v3 * -0.01,
                    c3 + u3 * 0.15 + v3 * 0.035, c3 + u3 * -0.15 + v3 * 0.035]
            if l.lashes:  # a little flick at the outer corner
                lash[1 if sx > 0 else 0] = lash[1 if sx > 0 else 0] + v3 * 0.05 + u3 * (0.04 * sx)
            put(INK, [q for q in lash])
            # brows
            cb, ub, vb = face_frame(sx * 0.36, 0.3, 0.03)
            tilt = 0.02 * sx
            brow = [cb + ub * -0.13 + vb * (-0.015 - tilt), cb + ub * 0.13 + vb * (-0.015 + tilt),
                    cb + ub * 0.13 + vb * (0.02 + tilt), cb + ub * -0.13 + vb * (0.02 - tilt)]
            put(darker(l.hair, 0.7), [q for q in brow])
            if l.blush:
                cc, uc, vc = face_frame(sx * 0.5, -0.36, 0.024)
                put(BLUSH, [q for q in oval(cc, uc, vc, 0.1, 0.05, 6)])
        cm, um, vm = face_frame(0.0, -0.56, 0.026)
        if l.mouth == "open":
            pts = [cm + um * -0.12 + vm * 0.04, cm + um * 0.12 + vm * 0.04, cm + um * 0.08 + vm * -0.07,
                   cm + vm * -0.1, cm + um * -0.08 + vm * -0.07]
            put(MOUTH, [q for q in pts])
        elif l.mouth == "o":
            put(MOUTH, [q for q in oval(cm, um, vm, 0.05, 0.065, 6)])
        elif l.mouth == "smile":
            pts = [cm + um * -0.1 + vm * 0.03, cm + um * -0.05 + vm * -0.02, cm + um * 0.05 + vm * -0.02,
                   cm + um * 0.1 + vm * 0.03, cm + um * 0.05 + vm * 0.0, cm + um * -0.05 + vm * 0.0]
            put(MOUTH, [q for q in pts])
        else:
            put(MOUTH, [q for q in (cm + um * -0.07 + vm * -0.01, cm + um * 0.07 + vm * -0.01,
                                             cm + um * 0.07 + vm * 0.015, cm + um * -0.07 + vm * 0.015)])

    def hair(self) -> None:
        l = self.l
        k = self.kit
        M = self.head_m
        col = paint(l.hair, 0.75)
        style = l.hair_style
        # the cap over the skull, open where the face is
        bm = bm_ico(2, 1.0)
        kill = []
        for v in bm.verts:
            d = v.co
            hairline = 0.42 - 0.3 * abs(d.x) if style != "buzz" else 0.5 - 0.3 * abs(d.x)
            front = d.y > -0.05 and d.z < hairline and abs(d.x) < 0.8
            low = d.z < (-0.62 if d.y < -0.2 else -0.25)
            if front or low:
                kill.append(v)
            v.co = head_shape(Vector((d.x * HX * 1.08, d.y * HY * 1.06 - 0.02, d.z * HZ * 1.05 + 0.04)))
        bmesh.ops.delete(bm, geom=kill, context="VERTS")
        k.add(bm, BASE, M, col)
        if style != "buzz":
            # bangs: flattened strands over the forehead
            n = 5
            for i in range(n):
                x = -0.6 + 1.2 * i / (n - 1)
                root, nrm = head_point(x * 0.9, 0.62, 0.06)
                tip, _ = head_point(x * 0.8 + (0.06 if x < 0 else -0.06), 0.22 - 0.06 * (i % 2), 0.05)
                w = 0.2
                side_v = Vector((1, 0, 0))
                pts = [root - side_v * w * 0.5, root + side_v * w * 0.5, tip, root + nrm * 0.07]
                k.add(bm_hull(pts), BASE, M, col)
            # side locks in front of the ears
            for sx in (-1, 1):
                top, _ = head_point(sx * 0.72, 0.3, 0.07)
                bot = Vector((sx * 0.86, 0.34, -0.45 if l.female else -0.25))
                k.add(bm_hull([top + Vector((0, -0.12, 0)), top + Vector((0, 0.08, 0)), bot,
                               top + Vector((sx * 0.1, -0.02, 0))]), BASE, M, col)
        if style == "spiky":
            for (x, y, z, rx, rz) in ((0.0, -0.1, 1.0, 10, 0), (0.45, -0.1, 0.8, 0, 35), (-0.45, -0.1, 0.8, 0, -35),
                                      (0.0, -0.7, 0.55, -40, 0), (0.35, -0.55, 0.65, -30, 30), (-0.35, -0.55, 0.65, -30, -30)):
                base = head_shape(Vector((x * HX, y * HY, z * HZ)))
                k.add(bm_cyl(0.2, 0.0, 0.42, 4), BASE, M @ trs(base, (rx, rz, 0)), col)
        elif style in ("bob", "long"):
            bottom = -0.75 if style == "bob" else -2.0
            rings = (0.35, -0.2, bottom)
            verts = []
            segs = 9
            a0, a1 = math.radians(50), math.radians(310)
            for z in rings:
                rr = 1.1 if z > 0 else (1.16 if z > -1 else 1.0)
                for j in range(segs + 1):
                    a = a0 + (a1 - a0) * j / segs
                    verts.append(Vector((math.sin(a) * HX * rr, math.cos(a) * HY * rr - 0.05, z * HZ)))
            faces = []
            for ri in range(len(rings) - 1):
                for j in range(segs):
                    a = ri * (segs + 1) + j
                    faces.append((a, a + segs + 1, a + segs + 2, a + 1))
            for flip in (False, True):
                bm = bmesh.new()
                vs = [bm.verts.new(v) for v in verts]
                for f in faces:
                    bm.faces.new([vs[i] for i in (f[::-1] if flip else f)])
                k.add(bm, BASE, M, col)
        elif style == "ponytail":
            tie = Vector((0, -1.0, 0.35))
            k.add(bm_ico(1, 0.18), BASE, M @ trs(tie), paint(self.l.hat_col if self.l.hat_col else "#d9483e"))
            k.add(bm_tube([tie + Vector((0, -0.05, 0)), Vector((0, -1.35, 0.1)), Vector((0, -1.4, -0.5)),
                           Vector((0, -1.25, -1.2))], [0.2, 0.24, 0.18, 0.0], 5, True, False), BASE, M, col)
        elif style == "bun":
            k.add(bm_ico(1, 0.36), BASE, M @ trs((0, -0.55, 0.95), (0, 0, 0), (1.0, 0.9, 0.85)), col)
            k.add(bm_cyl(0.02, 0.02, 0.9, 4), BASE, M @ trs((-0.4, -0.5, 0.95), (0, 80, 20)), paint("#d9483e"))
        elif style == "twintails":
            for sx in (-1, 1):
                tie = Vector((sx * 0.85, -0.45, 0.35))
                k.add(bm_ico(1, 0.14), BASE, M @ trs(tie), paint("#f05a8a"))
                k.add(bm_tube([tie, tie + Vector((sx * 0.35, -0.1, -0.3)), tie + Vector((sx * 0.3, -0.15, -1.1))],
                              [0.2, 0.22, 0.0], 5, True, False), BASE, M, col)

    def hat(self) -> None:
        l = self.l
        k = self.kit
        M = self.head_m
        hc = paint(l.hat_col)
        h = l.hat
        if h in ("cap", "cap_back"):
            dome = bm_ico(2, 1.0)
            kill = [v for v in dome.verts if v.co.z < 0.05]
            bmesh.ops.delete(dome, geom=kill, context="VERTS")
            k.add(dome, BASE, M @ trs((0, -0.03, 0.18), (0, 0, 0), (HX * 1.14, HY * 1.14, HZ * 0.95)), hc)
            yaw = 180 if h == "cap_back" else 0
            brim = [Vector((x, y, 0)) for (x, y) in ((-0.6, 0.0), (0.6, 0.0), (0.55, 0.55), (0.0, 0.8), (-0.55, 0.55))]
            brim += [p + Vector((0, 0, 0.06)) for p in brim]
            k.add(bm_hull(brim), BASE, M @ trs((0, 0, 0.24), (0, 0, yaw)) @ trs((0, 0.85, 0), (-8, 0, 0)), hc)
        elif h == "bucket":
            k.add(bm_cyl(1.05, 0.85, 0.55, 9), BASE, M @ trs((0, -0.03, 0.4)), hc)
            k.add(bm_cyl(1.5, 1.08, 0.2, 9, phase=0.2), BASE, M @ trs((0, -0.03, 0.28)), hc)
        elif h == "sunhat":
            k.add(bm_cyl(1.0, 0.8, 0.5, 9), BASE, M @ trs((0, -0.03, 0.45)), hc)
            k.add(bm_cyl(2.1, 1.05, 0.18, 12), BASE, M @ trs((0, -0.03, 0.4)), hc)
            k.add(bm_cyl(1.02, 1.02, 0.14, 9, False, False), BASE, M @ trs((0, -0.03, 0.47)), paint("#d9483e"))
        elif h == "school":
            k.add(bm_cyl(1.0, 0.92, 0.55, 10), BASE, M @ trs((0, -0.03, 0.42)), hc)
            k.add(bm_cyl(1.55, 1.02, 0.14, 12), BASE, M @ trs((0, -0.03, 0.36)), hc)
        elif h == "helmet":
            dome = bm_ico(2, 1.0)
            bmesh.ops.delete(dome, geom=[v for v in dome.verts if v.co.z < -0.05], context="VERTS")
            k.add(dome, BASE, M @ trs((0, -0.03, 0.12), (0, 0, 0), (HX * 1.2, HY * 1.2, HZ * 1.02)), hc)
            k.add(bm_cyl(1.3, 1.15, 0.1, 12), BASE, M @ trs((0, 0.02, 0.1)), hc)
        elif h == "beanie":
            dome = bm_ico(2, 1.0)
            bmesh.ops.delete(dome, geom=[v for v in dome.verts if v.co.z < 0.0], context="VERTS")
            k.add(dome, BASE, M @ trs((0, -0.04, 0.3), (0, 0, 0), (HX * 1.12, HY * 1.12, HZ * 0.95)), hc)
            k.add(bm_cyl(1.07, 1.07, 0.28, 10), BASE, M @ trs((0, -0.04, 0.2)), paint(darker(l.hat_col, 0.85)))
            k.add(bm_ico(1, 0.25), BASE, M @ trs((0, -0.04, 1.3)), paint(WHITE))
        elif h == "flatcap":
            k.add(bm_hull([Vector(p) for p in ((-0.95, -0.9, 0.3), (0.95, -0.9, 0.3), (-1.0, 0.7, 0.3), (1.0, 0.7, 0.3),
                                                 (0.0, 1.25, 0.28), (-0.8, -0.6, 0.72), (0.8, -0.6, 0.72),
                                                 (-0.7, 0.5, 0.62), (0.7, 0.5, 0.62))]), BASE, M @ trs((0, 0, 0.2)), hc)
        elif h == "hachimaki":
            k.add(bm_cyl(1.0, 1.0, 0.22, 10, False, False), BASE,
                  M @ trs((0, -0.04, 0.34), (0, 0, 0), (HX * 1.12, HY * 1.1, 1.0)), paint(WHITE))
            # the rising-sun dot on the forehead and the knot tails at the back
            p, n = head_point(0.0, 0.45, 0.14)
            k.add(bm_cyl(0.11, 0.11, 0.02, 8), BASE, M @ look_matrix(p, n), paint("#d9483e"))
            for sx in (-1, 1):
                k.add(bm_hull([Vector((0.0, -1.1, 0.44)), Vector((0.0, -1.1, 0.34)),
                               Vector((sx * 0.35, -1.25, -0.2)), Vector((sx * 0.25, -1.3, -0.25))]), BASE, M, paint(WHITE))

    def build(self) -> None:
        self.legs()
        self.torso()
        self.arms()
        self.head()


def darker(col: str, f: float) -> str:
    c = hexc(col)
    return "#%02x%02x%02x" % tuple(int(max(0, min(255, v * f * 255))) for v in c)


def kit_quad(kit: Kit, mat: str, pts: Sequence[Vector], color) -> None:
    for order in (pts, list(reversed(pts))):
        bm = bmesh.new()
        vs = [bm.verts.new(p) for p in order]
        bm.faces.new(vs)
        kit.add(bm, mat, None, color)


# ---------------------------------------------------------------------------------- props held
def flag(kit: Kit, hand: Vector, cloth: str, emblem: str | None, up: Vector, size: float = 1.0,
         pole: str = "#c89f72") -> None:
    u = up.normalized()
    top = hand + u * 0.75 * size
    tube(kit, BASE, [hand - u * 0.12, top], [0.011, 0.009], 4, paint(pole))
    side = u.cross(Vector((0, 1, 0))).normalized()
    if side.x < 0:
        side = -side
    w = 0.46 * size
    h = 0.3 * size
    q = [top, top - u * h, top - u * h + side * w + Vector((0, 0.04, -0.02)), top + side * w + Vector((0, 0.05, -0.02))]
    kit_quad(kit, BASE, q, paint(cloth, 0.92))
    if emblem:
        c = (q[0] + q[1] + q[2] + q[3]) / 4
        for lift in (0.006, -0.006):
            kit.flower(BASE, look_matrix(c + Vector((0, lift, 0)), Vector((0, 1 if lift > 0 else -1, 0))), 0.09 * size,
                       None, flat(emblem))


def uchiwa(kit: Kit, hand: Vector, d: Vector, face: str) -> None:
    tip = hand + d * 0.12
    tube(kit, BASE, [hand - d * 0.04, tip], [0.01, 0.01], 4, paint("#c89f72"))
    c = tip + d * 0.12
    n = Vector((0, 1, 0))
    u = d.cross(n).normalized()
    ring = oval(c, u, d, 0.13, 0.12, 8)
    kit_quad(kit, BASE, ring, paint(face, 0.95))
    kit.flower(BASE, look_matrix(c + n * 0.006, n), 0.06, None, flat("#e4506a"))


def camera(kit: Kit, at: Vector, lens_len: float = 0.14) -> None:
    kit.add(bm_hull([at + Vector(p) for p in ((-0.085, -0.03, -0.05), (0.085, -0.03, -0.05), (-0.085, 0.04, -0.05),
                                             (0.085, 0.04, -0.05), (-0.085, -0.03, 0.05), (0.085, -0.03, 0.05),
                                             (-0.085, 0.04, 0.05), (0.085, 0.04, 0.05), (0.03, 0.0, 0.08))]),
            BASE, None, paint("#35323b"))
    kit.add(bm_cyl(0.04, 0.043, lens_len, 8), BASE, look_matrix(at + Vector((0.02, 0.04, 0.0)), Vector((0, 1, 0))),
            paint("#2a282f"))
    kit.add(bm_cyl(0.03, 0.03, 0.005, 8), BASE,
            look_matrix(at + Vector((0.02, 0.041 + lens_len, 0.0)), Vector((0, 1, 0))), paint("#7fa3c4"))


def parasol(kit: Kit, hand: Vector, tilt: Vector) -> None:
    u = tilt.normalized()
    top = hand + u * 0.95
    tube(kit, BASE, [hand - u * 0.08, top + u * 0.08], [0.012, 0.012], 4, paint("#6b4a3a"))
    n = 12
    side = u.cross(Vector((0, 1, 0))).normalized()
    fwd = side.cross(u).normalized()
    rim = [top + (side * math.cos(2 * math.pi * i / n) + fwd * math.sin(2 * math.pi * i / n)) * 0.62 - u * 0.2
           for i in range(n)]
    # alternating red and white panels, and a pale underside
    for i in range(n):
        col = "#e0483c" if i % 2 == 0 else "#f6f1e6"
        a, b = rim[i], rim[(i + 1) % n]
        outer = [top + u * 0.12, a, b]
        if (a - top).cross(b - top).dot(u) < 0:
            outer = [top + u * 0.12, b, a]
        decal(kit, col, outer, paint(col, 0.9))
        decal(kit, "#c9b8a8", [top + u * 0.1, outer[2] - u * 0.004, outer[1] - u * 0.004], paint("#c9b8a8", 0.9))


def board(kit: Kit, a: Vector, b: Vector, col: str, emblem: str) -> None:
    """A cheer board held between two hands."""
    mid = (a + b) / 2 + Vector((0, 0.02, 0.2))
    side = (b - a).normalized()
    up = Vector((0, 0, 1))
    w = (b - a).length * 0.5 + 0.12
    q = [mid - side * w - up * 0.22, mid + side * w - up * 0.22, mid + side * w + up * 0.22, mid - side * w + up * 0.22]
    kit_quad(kit, BASE, q, paint(col, 0.95))
    n = Vector((0, 1, 0))
    kit.flower(BASE, look_matrix(mid + n * 0.008, n), 0.15, None, flat(emblem))
    kit.flower(BASE, look_matrix(mid - n * 0.008, -n), 0.15, None, flat(emblem))


def backpack(kit: Kit, fig: Figure, col: str, kid: bool = False) -> None:
    c = fig.U(0, -0.15 if not kid else -0.17, 1.16)
    s = (0.3, 0.14, 0.34) if not kid else (0.34, 0.16, 0.36)
    kit.add(bm_hull([c + Vector((x * s[0] / 2, y * s[1] / 2, z * s[2] / 2))
                     for x in (-1, 1) for y in (-1, 1) for z in (-1, 1)] + [c + Vector((0, -s[1] * 0.7, 0))]),
            BASE, None, paint(col))
    if kid:
        kit.add(bm_hull([c + Vector((x * 0.17, -0.09 + y * 0.02, 0.05 + z * 0.12))
                         for x in (-1, 1) for y in (-1, 1) for z in (-1, 1)]), BASE, None, paint(darker(col, 0.8)))


def stool(kit: Kit, z: float) -> None:
    kit.add(bm_cyl(0.17, 0.17, 0.04, 8), BASE, trs((0, -0.06, z - 0.04)), paint("#4a78c4"))
    for a in (45, 135, 225, 315):
        x = math.cos(math.radians(a)) * 0.13
        y = math.sin(math.radians(a)) * 0.13 - 0.06
        tube(kit, BASE, [Vector((x, y, 0.0)), Vector((x * 0.6, y * 0.6 - 0.024, z - 0.04))], [0.012, 0.012], 4,
             paint("#9aa0a8"))


# ---------------------------------------------------------------------------------- the people
@prop("spectator_a", "spectator", PLACE, PEOPLE, cyl(0.3))
def spectator_a(kit: Kit) -> None:
    """Cheering lad: hoodie (dyed), jeans, spiky black hair, both arms up, mouth open."""
    look = Look(skin=SKIN["warm"], hair=HAIR["black"], hair_style="spiky", top="hoodie", bottom="pants",
                bottom_col="#4f6b99", shoes="#e2503f", mouth="open")
    pose = Pose(elbow=((0.33, 0.02, 1.52), (-0.33, 0.02, 1.52)), wrist=((0.37, 0.07, 1.78), (-0.37, 0.07, 1.78)),
                energy=(1.0, 1.0), head_tilt=10)
    Figure(kit, look, pose).build()


@prop("spectator_b", "spectator", PLACE, PEOPLE, cyl(0.3))
def spectator_b(kit: Kit) -> None:
    """Student waving: cardigan (dyed), pleated navy skirt, knee socks, brown bob, shoulder bag."""
    look = Look(skin=SKIN["fair"], hair=HAIR["brown"], hair_style="bob", top="cardigan", inner=WHITE,
                bottom="skirt", bottom_col="#34406b", socks="#2f2f3a", shoes="#5a3d30", sole="#3a2d28",
                female=True, lashes=True, mouth="open", head=0.116)
    pose = Pose(knee=((0.085, 0.02, 0.47), (-0.085, 0.0, 0.47)), ankle=((0.09, 0.0, 0.075), (-0.1, -0.03, 0.075)),
                elbow=((0.32, 0.03, 1.46), (-0.2, 0.02, 1.1)), wrist=((0.3, 0.08, 1.72), (-0.12, 0.14, 0.99)),
                energy=(1.0, 0.1), head_roll=-6, head_tilt=4)
    fig = Figure(kit, look, pose)
    fig.build()
    # shoulder bag on the left hip, strap across the chest
    with Part(kit, 0.0):
        bag = fig.U(-0.2, 0.02, 0.9)
        kit.add(bm_hull([bag + Vector((x * 0.06, y * 0.04, z * 0.09)) for x in (-1, 1) for y in (-1, 1) for z in (-1, 1)]),
                BASE, None, paint("#c98f4e"))
        tube(kit, BASE, [bag + Vector((0, 0, 0.08)), fig.U(0.02, 0.12, 1.2), fig.U(0.15, 0.03, 1.4)], [0.012, 0.012, 0.012],
             4, paint("#8a5a34"))


@prop("spectator_c", "spectator", PLACE, PEOPLE, cyl(0.3))
def spectator_c(kit: Kit) -> None:
    """Festival fan in a happi coat (dyed) with a hachimaki, waving a big sakura flag."""
    look = Look(skin=SKIN["tan"], hair=HAIR["dark"], hair_style="short", top="happi", inner=WHITE,
                bottom="pants", bottom_col="#2f2d3a", shoes="#2f2d3a", sole="#f2efe8", hat="hachimaki", mouth="open")
    pose = Pose(elbow=((0.3, 0.04, 1.45), (-0.24, 0.04, 1.08)), wrist=((0.34, 0.1, 1.7), (-0.18, 0.18, 0.98)),
                energy=(0.9, 0.2), head_turn=8)
    fig = Figure(kit, look, pose)
    fig.build()
    with Part(kit, 0.9):
        flag(kit, fig.hands[1], "#f6f1e6", "#e8517c", Vector((0.25, 0.05, 1.0)), 1.25)


@prop("spectator_d", "spectator", PLACE, PEOPLE, cyl(0.28))
def spectator_d(kit: Kit) -> None:
    """Photographer: grey-haired, many-pocket vest over a dyed shirt, bucket hat, big lens up."""
    look = Look(skin=SKIN["warm"], hair=HAIR["grey"], hair_style="buzz", top="vest", bottom="pants",
                bottom_col="#6b6250", shoes="#4a3a30", sole="#3a2d28", hat="bucket", hat_col="#b7a27a",
                mouth="line", blush=False)
    pose = Pose(lean=4, elbow=((0.2, 0.18, 1.2), (-0.22, 0.14, 1.2)), wrist=((0.1, 0.25, 1.46), (-0.07, 0.27, 1.43)),
                energy=(0.12, 0.12), head_tilt=-4,
                knee=((0.11, 0.05, 0.48), (-0.1, -0.02, 0.48)), ankle=((0.13, 0.04, 0.075), (-0.11, -0.08, 0.075)))
    fig = Figure(kit, look, pose)
    fig.build()
    with Part(kit, 0.12):
        camera(kit, (fig.hands[1] + fig.hands[-1]) / 2 + Vector((0.0, 0.06, 0.02)), 0.2)


@prop("spectator_e", "spectator", PLACE, PEOPLE, cyl(0.3))
def spectator_e(kit: Kit) -> None:
    """Crouching fan: windbreaker jacket (dyed), cap on backwards, elbows on knees, chin up."""
    look = Look(skin=SKIN["warm"], hair=HAIR["black"], hair_style="short", top="jacket", inner="#34303a",
                bottom="pants", bottom_col="#35313b", shoes="#f2efe8", sole="#d9483e", hat="cap_back",
                hat_col="#34406b", mouth="smile")
    pose = Pose(hip_z=0.42, lean=28,
                knee=((0.17, 0.3, 0.5), (-0.17, 0.3, 0.5)), ankle=((0.14, 0.02, 0.08), (-0.14, 0.02, 0.08)),
                elbow=((0.2, 0.3, 1.02), (-0.2, 0.3, 1.02)), wrist=((0.1, 0.34, 1.26), (-0.1, 0.34, 1.26)),
                energy=(0.3, 0.3), head_tilt=22)
    Figure(kit, look, pose).build()


@prop("spectator_f", "spectator", PLACE, PEOPLE, cyl(0.22))
def spectator_f(kit: Kit) -> None:
    """Child (1.15 m): yellow school hat, red randoseru, T-shirt (dyed), shorts, twin tails,
    waving a little flag."""
    look = Look(skin=SKIN["fair"], hair=HAIR["black"], hair_style="twintails", top="tee", bottom="shorts",
                bottom_col="#34406b", socks=WHITE, shoes="#f08fb0", hat="school", hat_col="#f5c431",
                female=True, mouth="open", head=0.15)
    pose = Pose(knee=((0.08, 0.02, 0.46), (-0.08, 0.0, 0.46)), ankle=((0.1, 0.0, 0.075), (-0.1, -0.02, 0.075)),
                elbow=((0.3, 0.03, 1.5), (-0.26, 0.0, 1.1)), wrist=((0.34, 0.08, 1.74), (-0.28, 0.06, 0.88)),
                energy=(1.0, 0.25), head_tilt=12)
    fig = Figure(kit, look, pose)
    fig.build()
    with Part(kit, 1.0):
        flag(kit, fig.hands[1], "#f6f1e6", "#e0483c", Vector((0.2, 0.05, 1.0)), 0.8)
    with Part(kit, 0.0):
        backpack(kit, fig, "#d8413a", kid=True)
    for v in kit.bm.verts:  # a child: 0.7 of an adult, the big head kept
        v.co *= 0.7


@prop("spectator_g", "spectator", PLACE, PEOPLE, cyl(0.3))
def spectator_g(kit: Kit) -> None:
    """Lady with a red-and-white parasol: blouse (dyed), long skirt, long hair, a small wave."""
    look = Look(skin=SKIN["fair"], hair=HAIR["dark"], hair_style="long", top="tee", bottom="long_skirt",
                bottom_col="#e9dcc3", shoes="#b0503f", sole="#6b3a30", female=True, lashes=True, mouth="smile",
                head=0.114)
    pose = Pose(knee=((0.08, 0.02, 0.47), (-0.08, 0.0, 0.47)), ankle=((0.09, 0.0, 0.075), (-0.09, -0.03, 0.075)),
                elbow=((0.24, 0.1, 1.1), (-0.3, 0.05, 1.3)), wrist=((0.14, 0.26, 1.15), (-0.34, 0.12, 1.5)),
                energy=(0.05, 0.7), head_roll=5)
    fig = Figure(kit, look, pose)
    fig.build()
    with Part(kit, 0.05):
        parasol(kit, fig.hands[1], Vector((0.25, -0.35, 1.0)))


@prop("spectator_h", "spectator", PLACE, PEOPLE, cyl(0.28))
def spectator_h(kit: Kit) -> None:
    """Woman in a summer yukata (dyed) with a yellow obi, hair in a bun, fanning with an uchiwa."""
    look = Look(skin=SKIN["warm"], hair=HAIR["black"], hair_style="bun", top="yukata", inner="#f6f3ec",
                bottom="none", shoes="#c89f72", sole="#8a5a34", female=True, lashes=True, mouth="smile", head=0.114)
    pose = Pose(knee=((0.07, 0.02, 0.47), (-0.07, 0.0, 0.47)), ankle=((0.08, 0.0, 0.075), (-0.08, -0.02, 0.075)),
                elbow=((0.26, 0.12, 1.2), (-0.2, 0.08, 1.1)), wrist=((0.2, 0.26, 1.42), (-0.06, 0.22, 1.02)),
                energy=(0.6, 0.05), head_roll=-4)
    fig = Figure(kit, look, pose)
    fig.build()
    with Part(kit, 0.6):
        uchiwa(kit, fig.hands[1], Vector((0.2, 0.1, 1.0)).normalized(), "#f6f1e6")


@prop("spectator_i", "spectator", PLACE, PEOPLE, cyl(0.3))
def spectator_i(kit: Kit) -> None:
    """Rally nut pointing at the road: team jacket (dyed), red cap, fist on the hip."""
    look = Look(skin=SKIN["tan"], hair=HAIR["brown"], hair_style="short", top="jacket", inner=WHITE,
                bottom="pants", bottom_col="#3b4a6b", shoes="#35313b", sole=WHITE, hat="cap", hat_col="#d8413a",
                mouth="open")
    pose = Pose(elbow=((0.36, 0.2, 1.4), (-0.28, -0.08, 1.08)), wrist=((0.44, 0.44, 1.46), (-0.16, 0.0, 0.95)),
                energy=(0.45, 0.0), head_turn=-14,
                knee=((0.12, 0.04, 0.48), (-0.12, -0.04, 0.48)), ankle=((0.15, 0.06, 0.075), (-0.14, -0.08, 0.075)))
    Figure(kit, look, pose).build()


@prop("spectator_j", "spectator", PLACE, PEOPLE, cyl(0.32))
def spectator_j(kit: Kit) -> None:
    """Clapping woman: puffer jacket (dyed), jeans, ponytail, beanie."""
    look = Look(skin=SKIN["warm"], hair=HAIR["chestnut"], hair_style="ponytail", top="puffer", bottom="pants",
                bottom_col="#56709a", shoes=WHITE, sole="#b8a47a", hat="beanie", hat_col="#f2e6c8",
                female=True, lashes=True, mouth="open", head=0.115)
    pose = Pose(elbow=((0.24, 0.16, 1.14), (-0.24, 0.16, 1.14)), wrist=((0.05, 0.3, 1.24), (-0.05, 0.3, 1.24)),
                energy=(0.8, 0.8), head_tilt=6)
    Figure(kit, look, pose).build()


@prop("spectator_k", "spectator", PLACE, PEOPLE, cyl(0.32))
def spectator_k(kit: Kit) -> None:
    """Teen holding a sakura cheer board over the head: tee (dyed), shorts, pink-dyed bob."""
    look = Look(skin=SKIN["fair"], hair=HAIR["pink"], hair_style="bob", top="tee", bottom="shorts",
                bottom_col="#e9dcc3", socks=WHITE, shoes="#3f73c0", female=True, lashes=True, mouth="open",
                head=0.115)
    pose = Pose(elbow=((0.32, 0.02, 1.5), (-0.32, 0.02, 1.5)), wrist=((0.26, 0.06, 1.76), (-0.26, 0.06, 1.76)),
                energy=(0.55, 0.55), head_tilt=8)
    fig = Figure(kit, look, pose)
    fig.build()
    with Part(kit, 0.55):
        board(kit, fig.hands[-1], fig.hands[1], "#fbf7ee", "#e8517c")


@prop("spectator_l", "spectator", PLACE, PEOPLE, cyl(0.3))
def spectator_l(kit: Kit) -> None:
    """Grandpa on a folding stool: cardigan (dyed), flat cap, hands on the knees."""
    look = Look(skin=SKIN["warm"], hair=HAIR["grey"], hair_style="buzz", top="cardigan", inner="#b8a47a",
                bottom="pants", bottom_col="#6f6a62", shoes="#4a3a30", sole="#3a2d28", hat="flatcap",
                hat_col="#8f8274", mouth="smile", blush=False)
    pose = Pose(hip_z=0.52, lean=10,
                knee=((0.13, 0.4, 0.5), (-0.13, 0.4, 0.5)), ankle=((0.14, 0.38, 0.075), (-0.14, 0.36, 0.075)),
                elbow=((0.24, 0.12, 1.08), (-0.24, 0.12, 1.08)), wrist=((0.15, 0.36, 1.02), (-0.15, 0.36, 1.02)),
                energy=(0.2, 0.2), head_tilt=6)
    Figure(kit, look, pose).build()
    with Part(kit, 0.0):
        stool(kit, 0.46)


@prop("marshal", "spectator", PLACE, PEOPLE, cyl(0.3))
def marshal(kit: Kit) -> None:
    """Course marshal: hi-vis orange vest over white, white helmet, a red flag held down."""
    look = Look(skin=SKIN["tan"], hair=HAIR["black"], hair_style="short", top="hivis", bottom="pants",
                bottom_col="#2f3a60", shoes="#35313b", sole="#35313b", hat="helmet", hat_col="#f6f3ec",
                mouth="line", blush=False)
    pose = Pose(elbow=((0.25, 0.04, 1.1), (-0.25, 0.0, 1.1)), wrist=((0.3, 0.14, 0.9), (-0.27, 0.04, 0.86)),
                energy=(0.15, 0.1))
    fig = Figure(kit, look, pose)
    fig.build()
    with Part(kit, 0.15):
        flag(kit, fig.hands[1], "#e0322c", None, Vector((0.35, 0.3, -0.35)), 1.0, pole="#f6f3ec")
