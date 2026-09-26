"""Japanese architecture helpers: roofs, walls, wall-mounted panels. Front = +Y."""
from __future__ import annotations

from mathutils import Vector

from .common import Kit, underside

SHADE_UNDER = underside()


def gable_roof(kit: Kit, mat: str, w: float, d: float, z_eave: float, pitch_h: float,
               over_x: float, over_y: float, thick: float, attic_mat: str | None = None,
               ridge_mat: str | None = "Roof_Ridge", cx: float = 0.0, cy: float = 0.0,
               ridge: tuple[float, float] = (0.26, 0.24)) -> float:
    """Gable roof, ridge along X. Walls top at z_eave on y=±d/2. Returns ridge z."""
    s = pitch_h / (d / 2)
    hx = w / 2 + over_x
    hy = d / 2 + over_y
    zr = z_eave + pitch_h
    ze = z_eave - over_y * s
    for sy in (-1, 1):
        pts = []
        for x in (-hx, hx):
            pts += [(cx + x, cy, zr + thick * 0.5), (cx + x, cy + sy * hy, ze),
                    (cx + x, cy, zr - thick), (cx + x, cy + sy * hy, ze - thick)]
        kit.hull(mat, pts, None, SHADE_UNDER)
    if attic_mat:
        pts = []
        for x in (-w / 2, w / 2):
            pts += [(cx + x, cy - d / 2, z_eave - 0.01), (cx + x, cy + d / 2, z_eave - 0.01), (cx + x, cy, zr - thick)]
        kit.hull(attic_mat, pts)
    if ridge_mat:
        kit.cbox(ridge_mat, (2 * hx + ridge[0] * 0.4, ridge[0], ridge[1]), (cx, cy, zr + thick * 0.5 + 0.02),
                 color=SHADE_UNDER)
    return zr


def hip_roof(kit: Kit, mat: str, w: float, d: float, z_eave: float, h: float, over: float,
             thick: float, ridge_half: float | None = None, ridge_mat: str | None = "Roof_Ridge",
             cx: float = 0.0, cy: float = 0.0) -> tuple[float, float, float]:
    """Solid hip roof (flat soffit). Returns (ridge z, ridge half length, long-side slope)."""
    s = h / (d / 2)
    hx = w / 2 + over
    hy = d / 2 + over
    ze = z_eave - over * s
    zr = z_eave + h
    rh = max(0.0, (w - d) / 2) if ridge_half is None else ridge_half
    pts = [(cx + x, cy + y, z) for x in (-hx, hx) for y in (-hy, hy) for z in (ze, ze - thick)]
    pts += [(cx - rh, cy, zr), (cx + rh, cy, zr)]
    kit.hull(mat, pts, None, SHADE_UNDER)
    if ridge_mat and rh > 0:
        kit.cbox(ridge_mat, (2 * rh + 0.3, 0.3, 0.26), (cx, cy, zr - 0.02), color=SHADE_UNDER)
    return zr, rh, s


def irimoya_roof(kit: Kit, mat: str, gable_mat: str, w: float, d: float, z_eave: float, h: float,
                 over: float, thick: float, ridge_mat: str = "Roof_Ridge", upper: float = 0.5,
                 cx: float = 0.0, cy: float = 0.0) -> float:
    """Hip-and-gable roof: hip skirt with a gabled top whose vertical triangles show."""
    hx = w / 2 + over
    rh = max(0.3, w / 2 - d * 0.3)
    zr, rh, s = hip_roof(kit, mat, w, d, z_eave, h, over, thick, rh, None, cx, cy)
    ze = z_eave - over * s
    s_end = (zr - ze) / (hx - rh)
    yh = (d / 2 + over) * upper
    ext = yh * s / s_end + 0.08
    xg = rh + ext
    lift = 0.07
    ztop = zr + lift
    zlow = ztop - yh * s
    for sy in (-1, 1):
        pts = []
        for x in (-(xg + 0.35), xg + 0.35):
            pts += [(cx + x, cy, ztop + thick * 0.4), (cx + x, cy + sy * yh, zlow),
                    (cx + x, cy, ztop - thick * 0.6), (cx + x, cy + sy * yh, zlow - thick * 0.6)]
        kit.hull(mat, pts, None, SHADE_UNDER)
    for sx in (-1, 1):
        x = cx + sx * xg
        tri = [(x, cy - yh * 0.92, zlow - 0.02), (x, cy + yh * 0.92, zlow - 0.02), (x, cy, ztop - thick * 0.6)]
        pts = tri + [(p[0] - sx * 0.12, p[1], p[2]) for p in tri]
        kit.hull(gable_mat, pts)
    kit.cbox(ridge_mat, (2 * (xg + 0.35) + 0.2, 0.3, 0.26), (cx, cy, ztop + thick * 0.4 + 0.02), color=SHADE_UNDER)
    return ztop


def panel(kit: Kit, mat: str, side: str, W: float, D: float, off: float, z: float, pw: float,
          ph: float, depth: float = 0.05, cx: float = 0.0, cy: float = 0.0, color=None) -> None:
    """Thin panel on a wall face of a W x D box centred at (cx, cy). `off` = lateral offset
    along the face, z = panel centre height."""
    if side == "front":
        kit.cbox(mat, (pw, depth, ph), (cx + off, cy + D / 2 + depth / 2 - 0.01, z), color=color)
    elif side == "back":
        kit.cbox(mat, (pw, depth, ph), (cx - off, cy - D / 2 - depth / 2 + 0.01, z), color=color)
    elif side == "right":
        kit.cbox(mat, (depth, pw, ph), (cx + W / 2 + depth / 2 - 0.01, cy - off, z), color=color)
    elif side == "left":
        kit.cbox(mat, (depth, pw, ph), (cx - W / 2 - depth / 2 + 0.01, cy + off, z), color=color)
    else:
        raise ValueError(side)


def shoji(kit: Kit, side: str, W: float, D: float, off: float, z: float, pw: float, ph: float,
          cx: float = 0.0, cy: float = 0.0, paper: str = "Shoji") -> None:
    """Paper/glass window with dark frame and one mullion + one transom."""
    panel(kit, "Wood_Dark", side, W, D, off, z, pw + 0.1, ph + 0.1, 0.05, cx, cy)
    panel(kit, paper, side, W, D, off, z, pw, ph, 0.08, cx, cy)
    panel(kit, "Wood_Dark", side, W, D, off, z, 0.05, ph, 0.1, cx, cy)
    panel(kit, "Wood_Dark", side, W, D, off, z + ph * 0.18, pw, 0.04, 0.1, cx, cy)


def timber_walls(kit: Kit, W: float, D: float, H: float, z0: float, lower_h: float,
                 wall: str = "Plaster", lower: str = "Wood_Dark", post: str = "Wood_Dark",
                 bay: float = 1.8, cx: float = 0.0, cy: float = 0.0) -> None:
    """Plaster box with dark timber skirt, posts at corners/bays and a top beam."""
    kit.box(wall, (W, D, H), (cx, cy, z0))
    if lower_h > 0:
        kit.box(lower, (W + 0.04, D + 0.04, lower_h), (cx, cy, z0))
    kit.box(post, (W + 0.06, D + 0.06, 0.16), (cx, cy, z0 + H - 0.2))
    nx = max(1, round(W / bay))
    ny = max(1, round(D / bay))
    for i in range(nx + 1):
        x = cx - W / 2 + W * i / nx
        for y in (cy - D / 2, cy + D / 2):
            kit.box(post, (0.14, 0.1, H), (x, y, z0))
    for j in range(1, ny):
        y = cy - D / 2 + D * j / ny
        for x in (cx - W / 2, cx + W / 2):
            kit.box(post, (0.1, 0.14, H), (x, y, z0))


def steps(kit: Kit, mat: str, n: int, w: float, run: float, rise: float, y_front: float,
          x: float = 0.0, z0: float = 0.0) -> None:
    """Stair of n steps descending toward +Y from a landing of height n*rise at y_front."""
    for k in range(n):
        kit.box(mat, (w, run, rise * (n - k)), (x, y_front + run * (k + 0.5), z0))


def v(*a: float) -> Vector:
    return Vector(a)
