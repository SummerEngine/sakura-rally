"""Spline, polyline and distance-field helpers. Coordinates are Godot axes:
x right (east), y up, z back (south). Arrays of points are (n, 3) as (x, y, z)."""
from __future__ import annotations

import numpy as np


def catmull_rom_closed(pts: np.ndarray, per_seg: int = 32, alpha: float = 0.5) -> np.ndarray:
    """Centripetal Catmull-Rom through a closed loop of control points (n, 3)."""
    pts = np.asarray(pts, dtype=np.float64)
    n = len(pts)
    out = []
    for i in range(n):
        p0, p1, p2, p3 = pts[(i - 1) % n], pts[i], pts[(i + 1) % n], pts[(i + 2) % n]

        def knot(t, a, b):
            return t + max(np.linalg.norm((b - a)[[0, 2]]), 1e-6) ** alpha

        t0 = 0.0
        t1 = knot(t0, p0, p1)
        t2 = knot(t1, p1, p2)
        t3 = knot(t2, p2, p3)
        t = np.linspace(t1, t2, per_seg, endpoint=False)[:, None]
        a1 = (t1 - t) / (t1 - t0) * p0 + (t - t0) / (t1 - t0) * p1
        a2 = (t2 - t) / (t2 - t1) * p1 + (t - t1) / (t2 - t1) * p2
        a3 = (t3 - t) / (t3 - t2) * p2 + (t - t2) / (t3 - t2) * p3
        b1 = (t2 - t) / (t2 - t0) * a1 + (t - t0) / (t2 - t0) * a2
        b2 = (t3 - t) / (t3 - t1) * a2 + (t - t1) / (t3 - t1) * a3
        out.append((t2 - t) / (t2 - t1) * b1 + (t - t1) / (t2 - t1) * b2)
    return np.concatenate(out)


def catmull_rom_open(pts: np.ndarray, per_seg: int = 24) -> np.ndarray:
    """Uniform Catmull-Rom through an open polyline (end points duplicated)."""
    pts = np.asarray(pts, dtype=np.float64)
    ext = np.vstack([2 * pts[0] - pts[1], pts, 2 * pts[-1] - pts[-2]])
    out = []
    t = np.linspace(0.0, 1.0, per_seg, endpoint=False)[:, None]
    for i in range(1, len(ext) - 2):
        p0, p1, p2, p3 = ext[i - 1], ext[i], ext[i + 1], ext[i + 2]
        out.append(0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t ** 2
                          + (-p0 + 3 * p1 - 3 * p2 + p3) * t ** 3))
    out.append(pts[-1:])
    return np.concatenate(out)


def resample(poly: np.ndarray, step: float, closed: bool) -> tuple[np.ndarray, np.ndarray]:
    """Resample by horizontal (XZ) arc length. Returns (points, distance along)."""
    p = np.vstack([poly, poly[:1]]) if closed else poly
    seg = np.linalg.norm(np.diff(p[:, [0, 2]], axis=0), axis=1)
    cum = np.concatenate([[0.0], np.cumsum(seg)])
    total = cum[-1]
    n = max(2, int(round(total / step)))
    d = np.linspace(0.0, total, n, endpoint=not closed)
    out = np.stack([np.interp(d, cum, p[:, k]) for k in range(3)], axis=1)
    return out, d


def smooth(values: np.ndarray, sigma: float, closed: bool) -> np.ndarray:
    """Gaussian smoothing along a sequence (sigma in samples)."""
    if sigma <= 0:
        return values.copy()
    k = int(np.ceil(sigma * 3))
    x = np.arange(-k, k + 1)
    w = np.exp(-0.5 * (x / sigma) ** 2)
    w /= w.sum()
    if closed:
        pad = np.concatenate([values[-k:], values, values[:k]])
    else:
        pad = np.concatenate([np.full(k, values[0]), values, np.full(k, values[-1])])
    return np.convolve(pad, w, mode="same")[k:-k]


def frames(p: np.ndarray, closed: bool) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Horizontal unit tangent (n, 2 as x, z), right vector (n, 2) and signed curvature
    (1/m, positive = turning right) for a resampled polyline."""
    xz = p[:, [0, 2]]
    if closed:
        fwd = np.roll(xz, -1, axis=0) - np.roll(xz, 1, axis=0)
    else:
        fwd = np.gradient(xz, axis=0)
    fwd /= np.maximum(np.linalg.norm(fwd, axis=1, keepdims=True), 1e-9)
    right = np.stack([-fwd[:, 1], fwd[:, 0]], axis=1)
    ang = np.unwrap(np.arctan2(fwd[:, 1], fwd[:, 0]))
    seg = np.linalg.norm(np.diff(np.vstack([xz, xz[:1]]) if closed else xz, axis=0), axis=1)
    if closed:
        ds = 0.5 * (seg + np.roll(seg, 1))
        dang = np.roll(ang, -1) - np.roll(ang, 1)
        dang = (dang + np.pi) % (2 * np.pi) - np.pi
        curv = dang / np.maximum(2 * ds, 1e-6)
    else:
        curv = np.gradient(ang) / np.maximum(np.gradient(np.concatenate([[0.0], np.cumsum(seg)])), 1e-6)
    return fwd, right, curv


class RoadField:
    """Nearest-road-point queries over a regular (jittered) vertex grid, computed per
    segment inside a bounded window so it stays cheap for big maps."""

    def __init__(self, vx: np.ndarray, vz: np.ndarray, origin: float, cell: float):
        self.vx, self.vz = vx, vz
        self.origin, self.cell = origin, cell
        shape = vx.shape
        self.dist = np.full(shape, np.inf)
        self.y = np.zeros(shape)
        self.s = np.zeros(shape)
        self.lat = np.zeros(shape)
        self.seg = np.full(shape, -1, dtype=np.int64)

    def add_polyline(self, p: np.ndarray, s: np.ndarray, radius: float, closed: bool,
                     index_offset: int = 0) -> None:
        n = len(p)
        count = n if closed else n - 1
        nz, nx = self.vx.shape
        for i in range(count):
            a = p[i]
            b = p[(i + 1) % n]
            sa = s[i]
            ex, ez = b[0] - a[0], b[2] - a[2]
            L2 = ex * ex + ez * ez
            if L2 < 1e-12:
                continue
            L = np.sqrt(L2)
            i0 = max(0, int(np.floor((min(a[0], b[0]) - radius - self.origin) / self.cell)) - 1)
            i1 = min(nx, int(np.ceil((max(a[0], b[0]) + radius - self.origin) / self.cell)) + 2)
            j0 = max(0, int(np.floor((min(a[2], b[2]) - radius - self.origin) / self.cell)) - 1)
            j1 = min(nz, int(np.ceil((max(a[2], b[2]) + radius - self.origin) / self.cell)) + 2)
            if i0 >= i1 or j0 >= j1:
                continue
            wx = self.vx[j0:j1, i0:i1]
            wz = self.vz[j0:j1, i0:i1]
            t = np.clip(((wx - a[0]) * ex + (wz - a[2]) * ez) / L2, 0.0, 1.0)
            px = a[0] + t * ex
            pz = a[2] + t * ez
            d = np.hypot(wx - px, wz - pz)
            cur = self.dist[j0:j1, i0:i1]
            m = d < cur
            if not m.any():
                continue
            side = np.sign(ex * (wz - a[2]) - ez * (wx - a[0]))
            cur[m] = d[m]
            self.y[j0:j1, i0:i1][m] = (a[1] + t * (b[1] - a[1]))[m]
            self.s[j0:j1, i0:i1][m] = (sa + t * L)[m]
            self.lat[j0:j1, i0:i1][m] = (side * d)[m]
            self.seg[j0:j1, i0:i1][m] = i + index_offset


def polyline_distance(px: np.ndarray, pz: np.ndarray, poly: np.ndarray, closed: bool,
                      chunk: int = 48) -> tuple[np.ndarray, np.ndarray]:
    """Brute-force distance from points to a polyline (use on coarse inputs only).
    Returns (distance, index of nearest segment start)."""
    px = np.asarray(px, dtype=np.float64).ravel()
    pz = np.asarray(pz, dtype=np.float64).ravel()
    a = poly[:, [0, 2]]
    b = np.roll(a, -1, axis=0) if closed else a[1:]
    a = a if closed else a[:-1]
    best = np.full(px.shape, np.inf)
    idx = np.zeros(px.shape, dtype=np.int64)
    for c0 in range(0, len(a), chunk):
        aa = a[c0:c0 + chunk]
        bb = b[c0:c0 + chunk]
        e = bb - aa
        L2 = np.maximum((e * e).sum(axis=1), 1e-12)
        dx = px[:, None] - aa[None, :, 0]
        dz = pz[:, None] - aa[None, :, 1]
        t = np.clip((dx * e[None, :, 0] + dz * e[None, :, 1]) / L2[None, :], 0.0, 1.0)
        qx = dx - t * e[None, :, 0]
        qz = dz - t * e[None, :, 1]
        d = np.sqrt(qx * qx + qz * qz)
        k = np.argmin(d, axis=1)
        dm = d[np.arange(len(px)), k]
        m = dm < best
        best[m] = dm[m]
        idx[m] = k[m] + c0
    return best, idx


def bilinear(grid: np.ndarray, origin: float, cell: float, x: np.ndarray, z: np.ndarray) -> np.ndarray:
    """Sample a (nz, nx) grid laid out from `origin` with spacing `cell`."""
    nz, nx = grid.shape
    fx = np.clip((x - origin) / cell, 0, nx - 1.001)
    fz = np.clip((z - origin) / cell, 0, nz - 1.001)
    i = np.floor(fx).astype(np.int64)
    j = np.floor(fz).astype(np.int64)
    u = fx - i
    v = fz - j
    g00 = grid[j, i]
    g10 = grid[j, i + 1]
    g01 = grid[j + 1, i]
    g11 = grid[j + 1, i + 1]
    return (g00 * (1 - u) + g10 * u) * (1 - v) + (g01 * (1 - u) + g11 * u) * v


def smoothstep(e0, e1, x):
    t = np.clip((np.asarray(x, dtype=np.float64) - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def point_in_polygon(px: np.ndarray, pz: np.ndarray, poly: np.ndarray) -> np.ndarray:
    """Even-odd test; poly (n, 2) as x, z."""
    inside = np.zeros(np.shape(px), dtype=bool)
    n = len(poly)
    for i in range(n):
        x1, z1 = poly[i]
        x2, z2 = poly[(i + 1) % n]
        cond = (z1 > pz) != (z2 > pz)
        xint = (x2 - x1) * (pz - z1) / ((z2 - z1) if z2 != z1 else 1e-12) + x1
        inside ^= cond & (px < xint)
    return inside
