"""Heightfield: road-following base level, relief, authored hills, boundary mountains,
lake and river carving, and the road cut/fill. Triangles use a per-cell diagonal
chosen by hash, shared by the mesh, the collision and `height_at`."""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from . import geom, noise
from .road import Road, road_height_at

CARVE_DROP = 0.25  # terrain sits this far below the road surface under the verges


@dataclass
class Water:
    lake_poly: np.ndarray | None = None       # (n, 2) x, z
    lake_level: float = 0.0
    river: np.ndarray | None = None           # (n, 3) centreline, y = water surface
    river_s: np.ndarray | None = None
    river_width: float = 0.0


@dataclass
class Terrain:
    size: float
    cell: float
    n: int
    xs: np.ndarray
    X: np.ndarray
    Z: np.ndarray
    H: np.ndarray
    diag: np.ndarray
    road_dist: np.ndarray       # metres to road centreline (coarse beyond 90 m)
    road_lat: np.ndarray
    road_seg: np.ndarray        # nearest road sample index (fine field only, -1 beyond)
    lake_sd: np.ndarray         # signed distance to lake shore (negative inside)
    river_dist: np.ndarray
    river_y: np.ndarray
    water: Water
    extra: dict = field(default_factory=dict)

    @property
    def origin(self) -> float:
        return -self.size / 2.0

    def height_at(self, x, z) -> np.ndarray:
        x = np.asarray(x, dtype=np.float64)
        z = np.asarray(z, dtype=np.float64)
        fx = np.clip((x - self.origin) / self.cell, 0, self.n - 1.0001)
        fz = np.clip((z - self.origin) / self.cell, 0, self.n - 1.0001)
        i = np.floor(fx).astype(np.int64)
        j = np.floor(fz).astype(np.int64)
        u = fx - i
        v = fz - j
        H = self.H
        h00 = H[j, i]
        h10 = H[j, i + 1]
        h01 = H[j + 1, i]
        h11 = H[j + 1, i + 1]
        d = self.diag[j, i]
        a = np.where(u >= v, h00 + u * (h10 - h00) + v * (h11 - h10), h00 + v * (h01 - h00) + u * (h11 - h01))
        b = np.where(u + v <= 1.0, h00 + u * (h10 - h00) + v * (h01 - h00),
                     h11 + (1 - u) * (h01 - h11) + (1 - v) * (h10 - h11))
        return np.where(d == 0, a, b)

    def normal_y(self) -> np.ndarray:
        gz, gx = np.gradient(self.H, self.cell)
        return 1.0 / np.sqrt(1.0 + gx * gx + gz * gz)

    def sample(self, grid: np.ndarray, x, z) -> np.ndarray:
        return geom.bilinear(grid, self.origin, self.cell, np.asarray(x, dtype=np.float64),
                             np.asarray(z, dtype=np.float64))


def cell_diag(n_cells: int, seed: int) -> np.ndarray:
    j, i = np.meshgrid(np.arange(n_cells), np.arange(n_cells), indexing="ij")
    return (noise._hash(i.astype(np.int64), j.astype(np.int64), seed + 999) & np.uint64(1)).astype(np.int8)


def build_water(spec: dict) -> Water:
    w = Water()
    seed = spec["seed"]
    lake = spec.get("lake")
    if lake:
        poly = np.array([[p[0], 0.0, p[1]] for p in lake["poly"]], dtype=np.float64)
        dense = geom.catmull_rom_closed(poly, per_seg=12)
        xz, _ = geom.resample(dense, 3.0, closed=True)
        fwd, right, _ = geom.frames(xz, closed=True)
        wob = noise.fbm(xz[:, 0], xz[:, 2], 70.0, 3, 2.0, 0.5, seed + 201) * lake.get("wobble", 14.0)
        xz[:, 0] += right[:, 0] * wob
        xz[:, 2] += right[:, 1] * wob
        w.lake_poly = xz[:, [0, 2]]
        w.lake_level = lake["level"]
    river = spec.get("river")
    if river:
        pts = np.array([[p[0], p[2], p[1]] for p in river["points"]], dtype=np.float64)
        dense = geom.catmull_rom_open(pts, per_seg=24)
        rp, rs = geom.resample(dense, 2.0, closed=False)
        # meanders: lateral noise, pinned near the explicit points listed in `pins`
        fwd, right, _ = geom.frames(rp, closed=False)
        mea = noise.fbm(rs, np.zeros_like(rs), 110.0, 2, 2.0, 0.5, seed + 211) * river.get("meander", 10.0)
        for px, pz in river.get("pins", []):
            d = np.hypot(rp[:, 0] - px, rp[:, 2] - pz)
            mea *= geom.smoothstep(25.0, 90.0, d)
        rp[:, 0] += right[:, 0] * mea
        rp[:, 2] += right[:, 1] * mea
        rp, rs = geom.resample(rp, 2.0, closed=False)
        # water never flows uphill
        rp[:, 1] = np.minimum.accumulate(geom.smooth(rp[:, 1], 6.0, closed=False))
        w.river = rp
        w.river_s = rs
        w.river_width = river["width"]
    return w


def build_terrain(spec: dict, road: Road, water: Water) -> Terrain:
    t = spec["terrain"]
    seed = spec["seed"]
    size = spec["size"]
    cell = spec["cell"]
    n = int(round(size / cell)) + 1
    xs = np.linspace(-size / 2, size / 2, n)
    X, Z = np.meshgrid(xs, xs)  # X[j, i] = xs[i], Z[j, i] = xs[j]

    # --- coarse road-level field and distance (16 m grid)
    cc = 16.0
    nc = int(round(size / cc)) + 1
    xc = np.linspace(-size / 2, size / 2, nc)
    XC, ZC = np.meshgrid(xc, xc)
    rs = road.pos[::6]
    d = np.hypot(XC[..., None] - rs[None, None, :, 0], ZC[..., None] - rs[None, None, :, 2])
    sigma = t.get("level_sigma", 110.0)
    wgt = np.exp(-(d / sigma) ** 2) + 1e-9
    R_c = (wgt * rs[None, None, :, 1]).sum(axis=2) / wgt.sum(axis=2)
    D_c = d.min(axis=2)
    del d, wgt
    R = geom.bilinear(R_c, -size / 2, cc, X, Z)
    D_far = geom.bilinear(D_c, -size / 2, cc, X, Z)

    # --- natural relief
    rel = t.get("relief", {})
    amp = geom.smoothstep(rel.get("near", 25.0), rel.get("far", 220.0), D_far)
    base_noise = noise.fbm(X, Z, rel.get("scale", 240.0), 5, 2.0, 0.5, seed)
    detail = noise.fbm(X, Z, 38.0, 3, 2.1, 0.5, seed + 3)
    H = R + base_noise * rel.get("amp", 20.0) * (0.12 + 0.88 * amp) + detail * rel.get("detail", 1.2)
    H += np.maximum(0.0, noise.fbm(X, Z, 420.0, 3, 2.0, 0.5, seed + 5)) * rel.get("rise", 30.0) * amp

    for hill in t.get("hills", []):
        hx, hz = hill["pos"]
        r2 = ((X - hx) ** 2 + (Z - hz) ** 2) / (hill["radius"] ** 2)
        shape = np.exp(-r2 * 1.8)
        if hill.get("ridged"):
            shape *= 0.75 + 0.5 * noise.ridged(X, Z, hill["radius"] * 0.6, 4, seed + 11)
        H += hill["height"] * shape

    b = t["boundary"]
    p = b.get("roundness", 4.0)
    e = (np.abs(X) ** p + np.abs(Z) ** p) ** (1.0 / p)
    bmask = geom.smoothstep(b["start"], b["end"], e)
    H += bmask * b["height"] * (0.55 + 0.9 * noise.ridged(X, Z, 260.0, 5, seed + 21))

    # --- terraces (flat stepped fields)
    for ter in t.get("terraces", []):
        poly = np.array(ter["poly"], dtype=np.float64)
        inside = geom.point_in_polygon(X, Z, poly)
        dpoly, _ = geom.polyline_distance(X[inside], Z[inside], np.column_stack([poly[:, 0], np.zeros(len(poly)), poly[:, 1]]), closed=True)
        step = ter["step"]
        hq = np.floor(H[inside] / step) * step + step * 0.5
        wgt_t = geom.smoothstep(0.0, ter.get("edge", 18.0), dpoly)
        H[inside] = H[inside] + (hq - H[inside]) * wgt_t

    # --- lake bowl
    lake_sd = np.full(X.shape, 1e9)
    if water.lake_poly is not None:
        poly3 = np.column_stack([water.lake_poly[:, 0], np.zeros(len(water.lake_poly)), water.lake_poly[:, 1]])
        box = (np.abs(X - water.lake_poly[:, 0].mean()) < np.ptp(water.lake_poly[:, 0]) / 2 + 160) & \
              (np.abs(Z - water.lake_poly[:, 1].mean()) < np.ptp(water.lake_poly[:, 1]) / 2 + 160)
        dl, _ = geom.polyline_distance(X[box], Z[box], poly3, closed=True)
        inside = geom.point_in_polygon(X[box], Z[box], water.lake_poly)
        sd = np.where(inside, -dl, dl)
        lake_sd[box] = sd
        lvl = water.lake_level
        depth = spec["lake"].get("depth", 4.0)
        shore = spec["lake"].get("shore", 40.0)
        hb = H[box]
        bed = lvl - depth * geom.smoothstep(0.0, 45.0, -sd) - 0.4
        beach = lvl + 0.35 + (hb - lvl - 0.35) * geom.smoothstep(0.0, shore, sd)
        hb = np.where(sd < 0, bed, np.minimum(hb, beach) if spec["lake"].get("clamp_shore", False) else beach)
        H[box] = hb

    # --- river channel
    river_dist = np.full(X.shape, 1e9)
    river_y = np.zeros(X.shape)
    if water.river is not None:
        rf = geom.RoadField(X, Z, -size / 2, cell)
        rf.add_polyline(water.river, water.river_s, radius=110.0, closed=False)
        river_dist = rf.dist
        river_y = rf.y
        inner = water.river_width / 2.0
        depth = spec["river"].get("depth", 1.4)
        near = np.isfinite(rf.dist)
        dn = rf.dist[near]
        wy = rf.y[near]
        hn = H[near]
        dh = np.abs(hn - wy)
        E = np.clip(8.0 + 1.5 * dh, 8.0, 95.0)
        bed = wy - depth * (1.0 - (np.minimum(dn, inner) / inner) ** 2) - 0.15
        bank = wy + 0.25 + (hn - wy - 0.25) * geom.smoothstep(inner, inner + E, dn)
        H[near] = np.where(dn < inner, bed, bank)

    # --- road cut and fill
    rf = geom.RoadField(X, Z, -size / 2, cell)
    step = 2
    rf.add_polyline(road.pos[::step], road.dist[::step], radius=95.0, closed=True)
    near = np.isfinite(rf.dist)
    si = (rf.seg[near] * step) % len(road.pos)
    lat = rf.lat[near]
    hw = road.half_width[si]
    y_road = rf.y[near] - np.clip(lat, -hw, hw) * road.bank[si] - CARVE_DROP
    flat = hw + road.verge + 4.5
    hn = H[near]
    dh = np.abs(hn - y_road)
    E = np.clip(6.0 + 1.3 * dh, 6.0, 75.0)
    tt = geom.smoothstep(flat, flat + E, rf.dist[near])
    cw = road.carve[si]
    tt = 1.0 - (1.0 - tt) * cw
    H[near] = y_road + (hn - y_road) * tt

    road_dist = np.where(near, rf.dist, D_far)
    road_seg = np.full(X.shape, -1, dtype=np.int64)
    road_seg[near] = si
    road_lat = np.where(near, rf.lat, 0.0)

    diag = cell_diag(n - 1, seed)
    return Terrain(size=size, cell=cell, n=n, xs=xs, X=X, Z=Z, H=H, diag=diag,
                   road_dist=road_dist, road_lat=road_lat, road_seg=road_seg, lake_sd=lake_sd,
                   river_dist=river_dist, river_y=river_y, water=water)


def chunk_mesh(ter: Terrain, i0: int, i1: int, j0: int, j1: int, colors: np.ndarray):
    """Vertices [j0..j1] x [i0..i1] (inclusive) and triangles of the cells inside."""
    sub_h = ter.H[j0:j1 + 1, i0:i1 + 1]
    sx = ter.X[j0:j1 + 1, i0:i1 + 1]
    sz = ter.Z[j0:j1 + 1, i0:i1 + 1]
    nzv, nxv = sub_h.shape
    pos = np.stack([sx.ravel(), sub_h.ravel(), sz.ravel()], axis=1)
    col = colors[j0:j1 + 1, i0:i1 + 1].reshape(-1, colors.shape[2])
    jj, ii = np.meshgrid(np.arange(nzv - 1), np.arange(nxv - 1), indexing="ij")
    v00 = (jj * nxv + ii).ravel()
    v10 = v00 + 1
    v01 = v00 + nxv
    v11 = v01 + 1
    dg = ter.diag[j0:j1, i0:i1].ravel()
    t0 = np.where(dg[:, None] == 0, np.stack([v00, v10, v11], 1), np.stack([v00, v10, v01], 1))
    t1 = np.where(dg[:, None] == 0, np.stack([v00, v11, v01], 1), np.stack([v10, v11, v01], 1))
    idx = np.concatenate([t0, t1], axis=1).ravel()
    return pos, col, idx
