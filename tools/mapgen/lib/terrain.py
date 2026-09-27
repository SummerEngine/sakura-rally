"""The world heightfield: one grid over every region.

Road-following base level from every road, each region's relief (in its own frame, weighted by
its season), authored hills, one mountain rim around the whole world (each region's square and
a valley along the branch, merged smoothly), terraces, the lake, the rivers, the road cut/fill
for every road, pads, lots and caps under every paved mesh. Triangles use a per-cell diagonal
chosen by hash, shared by the mesh, the collision and `height_at`."""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from . import geom, noise, seasons
from .road import Road, road_height_at, road_index

CARVE_DROP = 0.25  # terrain sits this far below the road surface under the verges
LOT_SKIRT = 2.3    # a lot's verge skirt reaches this far beyond its paved edge (lot_mesh)
BRIDGE_CLEARANCE = 1.6  # ground sits at least this far below a bridge deck (ramping to 0 off the bridge)
RIVER_REF_WIDTH = 10.0  # Terrain.river_dist is normalised to a river of this width


@dataclass
class River:
    id: str
    pts: np.ndarray                 # (n, 3) centreline, 2 m apart, y = water surface
    s: np.ndarray                   # (n,) distance along
    width: float
    depth: float
    steep: list = field(default_factory=list)
    falls: list = field(default_factory=list)  # [(sample index of the lip, drop m, pool radius m)]


@dataclass
class Water:
    lake_poly: np.ndarray | None = None       # (n, 2) x, z
    lake_level: float = 0.0
    lake: dict | None = None                  # the lake spec (depth, shore, clamp_shore)
    rivers: list = field(default_factory=list)
    # Terrain.river_dist is the distance to the nearest river centreline minus the difference of
    # that river's half width to half this one: river_dist < river_width / 2 means "in a river".
    river_width: float = RIVER_REF_WIDTH
    pools: list = field(default_factory=list)  # [(x, water level, z, radius)] filled by build_terrain

    @property
    def river(self) -> np.ndarray | None:
        """Every river's centreline points stacked (None without rivers)."""
        return np.vstack([r.pts for r in self.rivers]) if self.rivers else None


@dataclass
class Terrain:
    cell: float
    ox: float                   # grid corner (x, z)
    oz: float
    X: np.ndarray
    Z: np.ndarray
    H: np.ndarray
    diag: np.ndarray
    road_dist: np.ndarray       # metres to the nearest road centreline (coarse beyond 95 m)
    road_edge: np.ndarray       # metres beyond the nearest carriageway edge, < 0 on the road (same)
    road_lat: np.ndarray
    road_seg: np.ndarray        # nearest sample index on road road_id (fine field only, -1 beyond)
    road_id: np.ndarray         # index into the road list (-1 beyond the fine field)
    lake_sd: np.ndarray         # signed distance to lake shore (negative inside)
    river_dist: np.ndarray      # see Water.river_width
    river_y: np.ndarray
    water: Water
    lot_sd: np.ndarray          # signed distance to the nearest paved lot (negative inside)
    edge: np.ndarray            # rim metric: < rim start inside the world, rim top at rim end
    weights: np.ndarray         # (nz, nx, 3) season weights (lib/seasons.py)
    extra: dict = field(default_factory=dict)

    @property
    def nx(self) -> int:
        return self.H.shape[1]

    @property
    def nz(self) -> int:
        return self.H.shape[0]

    @property
    def origin(self) -> tuple[float, float]:
        return (self.ox, self.oz)

    def height_at(self, x, z) -> np.ndarray:
        x = np.asarray(x, dtype=np.float64)
        z = np.asarray(z, dtype=np.float64)
        fx = np.clip((x - self.ox) / self.cell, 0, self.nx - 1.0001)
        fz = np.clip((z - self.oz) / self.cell, 0, self.nz - 1.0001)
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
        return geom.bilinear(grid, (self.ox, self.oz), self.cell, np.asarray(x, dtype=np.float64),
                             np.asarray(z, dtype=np.float64))


def cell_diag(ncx: int, ncz: int, seed: int) -> np.ndarray:
    j, i = np.meshgrid(np.arange(ncz), np.arange(ncx), indexing="ij")
    return (noise._hash(i.astype(np.int64), j.astype(np.int64), seed + 999) & np.uint64(1)).astype(np.int8)


def _river(r: dict, seed: int) -> River:
    pts = np.array([[p[0], p[2], p[1]] for p in r["points"]], dtype=np.float64)
    dense = geom.catmull_rom_open(pts, per_seg=24)
    rp, rs = geom.resample(dense, 2.0, closed=False)
    # meanders: lateral noise, pinned near the explicit points listed in `pins`
    fwd, right, _ = geom.frames(rp, closed=False)
    mea = noise.fbm(rs, np.zeros_like(rs), 110.0, 2, 2.0, 0.5, seed + 211) * r.get("meander", 10.0)
    for px, pz in r.get("pins", []):
        d = np.hypot(rp[:, 0] - px, rp[:, 2] - pz)
        mea *= geom.smoothstep(25.0, 90.0, d)
    rp[:, 0] += right[:, 0] * mea
    rp[:, 2] += right[:, 1] * mea
    rp, rs = geom.resample(rp, 2.0, closed=False)
    # water never flows uphill
    rp[:, 1] = np.minimum.accumulate(geom.smooth(rp[:, 1], 6.0, closed=False))
    return River(id=r["id"], pts=rp, s=rs, width=float(r["width"]), depth=float(r.get("depth", 1.4)),
                 steep=list(r.get("steep", [])))


def build_water(world: dict) -> Water:
    """The lake and every river in world coordinates. A river that `join`s another ends at
    that river's water level; `falls` lift everything upstream of their lip by their drop."""
    w = Water()
    lake = world.get("lake")
    if lake:
        poly = np.array([[p[0], 0.0, p[1]] for p in lake["poly"]], dtype=np.float64)
        dense = geom.catmull_rom(poly, per_seg=12, closed=True)
        xz, _ = geom.resample(dense, 3.0, closed=True)
        fwd, right, _ = geom.frames(xz, closed=True)
        wob = noise.fbm(xz[:, 0], xz[:, 2], 70.0, 3, 2.0, 0.5, lake.get("seed", world["seed"]) + 201) * lake.get("wobble", 14.0)
        xz[:, 0] += right[:, 0] * wob
        xz[:, 2] += right[:, 1] * wob
        w.lake_poly = xz[:, [0, 2]]
        w.lake_level = lake["level"]
        w.lake = lake
    by_id = {}
    for r in world.get("rivers", []):
        rv = _river(r, r.get("seed", world["seed"]))
        by_id[rv.id] = rv
        w.rivers.append(rv)
    for r in world.get("rivers", []):
        rv = by_id[r["id"]]
        if "join" in r:
            # meet the main river at its level: ease the last 200 m onto it, keep flowing down
            tgt = by_id[r["join"]]
            end = rv.pts[-1]
            k = int(np.argmin(np.hypot(tgt.pts[:, 0] - end[0], tgt.pts[:, 2] - end[2])))
            off = tgt.pts[k, 1] - end[1]
            rv.pts[:, 1] += off * geom.smoothstep(rv.s[-1] - 200.0, rv.s[-1], rv.s)
            rv.pts[:, 1] = np.minimum.accumulate(rv.pts[:, 1])
        for f in r.get("falls", []):
            k = int(np.argmin(np.hypot(rv.pts[:, 0] - f["at"][0], rv.pts[:, 2] - f["at"][1])))
            rv.pts[:k + 1, 1] += f["drop"]
            rv.falls.append((k, float(f["drop"]), float(f.get("pool", 0.0))))
    return w


def _block_fields(XC: np.ndarray, ZC: np.ndarray, samples: np.ndarray, sigma: np.ndarray,
                  valley: np.ndarray | None, rows: int = 12):
    """Coarse road level (Gaussian-weighted road height), distance to any road and distance to
    the valley road, in row blocks to bound memory."""
    R = np.empty(XC.shape)
    D = np.empty(XC.shape)
    V = np.full(XC.shape, 1e9)
    for j0 in range(0, XC.shape[0], rows):
        j1 = min(XC.shape[0], j0 + rows)
        xs = XC[j0:j1, :, None]
        zs = ZC[j0:j1, :, None]
        d = np.hypot(xs - samples[None, None, :, 0], zs - samples[None, None, :, 2])
        wgt = np.exp(-(d / sigma[j0:j1, :, None]) ** 2) + 1e-9
        R[j0:j1] = (wgt * samples[None, None, :, 1]).sum(axis=2) / wgt.sum(axis=2)
        D[j0:j1] = d.min(axis=2)
        if valley is not None:
            V[j0:j1] = np.hypot(xs - valley[None, None, :, 0], zs - valley[None, None, :, 2]).min(axis=2)
    return R, D, V


def cap_under_mesh(ter_H: np.ndarray, ox: float, oz: float, cell: float, pos: np.ndarray, idx: np.ndarray,
                   drop: float) -> int:
    """Lower grid vertices under the triangles of a paved mesh to `drop` below it. Returns the
    number of vertices lowered."""
    nz, nx = ter_H.shape
    tri = pos[np.asarray(idx).reshape(-1, 3)]
    lowered = 0
    for a, b, c in tri:
        i0 = max(0, int(np.floor((min(a[0], b[0], c[0]) - ox) / cell)))
        i1 = min(nx - 1, int(np.ceil((max(a[0], b[0], c[0]) - ox) / cell)))
        j0 = max(0, int(np.floor((min(a[2], b[2], c[2]) - oz) / cell)))
        j1 = min(nz - 1, int(np.ceil((max(a[2], b[2], c[2]) - oz) / cell)))
        if i0 > i1 or j0 > j1:
            continue
        jj, ii = np.mgrid[j0:j1 + 1, i0:i1 + 1]
        px = ox + ii * cell
        pz = oz + jj * cell
        # barycentric in XZ
        v0 = (b[0] - a[0], b[2] - a[2])
        v1 = (c[0] - a[0], c[2] - a[2])
        den = v0[0] * v1[1] - v1[0] * v0[1]
        if abs(den) < 1e-9:
            continue
        wx, wz = px - a[0], pz - a[2]
        u = (wx * v1[1] - v1[0] * wz) / den
        v = (v0[0] * wz - wx * v0[1]) / den
        inside = (u >= -0.02) & (v >= -0.02) & (u + v <= 1.02)
        if not inside.any():
            continue
        h = a[1] + u * (b[1] - a[1]) + v * (c[1] - a[1]) - drop
        sub = ter_H[j0:j1 + 1, i0:i1 + 1]
        m = inside & (sub > h)
        sub[m] = h[m]
        lowered += int(m.sum())
    return lowered


def build_terrain(world: dict, roads: dict[str, Road], water: Water, built: dict[str, np.ndarray],
                  pads: list[tuple[str, dict]], caps: list[tuple[np.ndarray, np.ndarray]]) -> Terrain:
    """roads: id -> Road (the loops and the branch); built[id]: per-sample bool, True where
    that road's ribbon exists (the terrain is kept under it); pads: (road id, pad spec);
    caps: (pos, idx) of other paved meshes (junction aprons) the terrain must stay under."""
    seed = world["seed"]
    cell = world["cell"]
    x0, z0, x1, z1 = world["bounds"]
    nx = int(round((x1 - x0) / cell)) + 1
    nz = int(round((z1 - z0) / cell)) + 1
    xs = x0 + np.arange(nx) * cell
    zs = z0 + np.arange(nz) * cell
    X, Z = np.meshgrid(xs, zs)  # X[j, i] = xs[i], Z[j, i] = zs[j]
    regions = world["regions"]
    scfg = world["seasons"]
    Wt = seasons.weights(X, Z, scfg, seed)
    region_w = [Wt[..., seasons.SEASONS.index(r["season"])] for r in regions]

    # --- coarse road-level field and distances (16 m grid)
    cc = 16.0
    xc = np.arange(x0, x1 + cc, cc)
    zc = np.arange(z0, z1 + cc, cc)
    XC, ZC = np.meshgrid(xc, zc)
    Wc = seasons.weights(XC, ZC, scfg, seed)
    sigma = np.zeros(XC.shape)
    for r in regions:
        sigma += Wc[..., seasons.SEASONS.index(r["season"])] * r["spec"]["terrain"].get("level_sigma", 110.0)
    samples = np.concatenate([rd.pos[::6] for rd in roads.values()])
    rim = world["rim"]
    valley_road = roads.get(rim.get("valley_road", ""))
    R_c, D_c, V_c = _block_fields(XC, ZC, samples, sigma, valley_road.pos[::4] if valley_road is not None else None)
    R = geom.bilinear(R_c, (x0, z0), cc, X, Z)
    D_far = geom.bilinear(D_c, (x0, z0), cc, X, Z)

    # --- natural relief, each region's in its own frame, by its weight
    H = R.copy()
    for r, w in zip(regions, region_w):
        m = w > 1e-4
        if not m.any():
            continue
        rel = r["spec"]["terrain"].get("relief", {})
        rs = r["spec"]["seed"]
        lx, lz = r["frame"].local(X[m], Z[m])
        amp = geom.smoothstep(rel.get("near", 25.0), rel.get("far", 220.0), D_far[m])
        base_noise = noise.fbm(lx, lz, rel.get("scale", 240.0), 5, 2.0, 0.5, rs)
        detail = noise.fbm(lx, lz, 38.0, 3, 2.1, 0.5, rs + 3)
        h = base_noise * rel.get("amp", 20.0) * (0.12 + 0.88 * amp) + detail * rel.get("detail", 1.2)
        h += np.maximum(0.0, noise.fbm(lx, lz, 420.0, 3, 2.0, 0.5, rs + 5)) * rel.get("rise", 30.0) * amp
        H[m] += w[m] * h

    for r in regions:
        rs = r["spec"]["seed"]
        for hill in r["spec"]["terrain"].get("hills", []):
            hx, hz = hill["pos"]
            reach = hill["radius"] * 2.2
            ia = max(0, int((hx - reach - x0) / cell))
            ib = min(nx, int((hx + reach - x0) / cell) + 2)
            ja = max(0, int((hz - reach - z0) / cell))
            jb = min(nz, int((hz + reach - z0) / cell) + 2)
            if ia >= ib or ja >= jb:
                continue
            Xs, Zs = X[ja:jb, ia:ib], Z[ja:jb, ia:ib]
            r2 = ((Xs - hx) ** 2 + (Zs - hz) ** 2) / (hill["radius"] ** 2)
            shape = np.exp(-r2 * 1.8)
            if hill.get("ridged"):
                lx, lz = r["frame"].local(Xs, Zs)
                shape *= 0.75 + 0.5 * noise.ridged(lx, lz, hill["radius"] * 0.6, 4, rs + 11)
            H[ja:jb, ia:ib] += hill["height"] * shape

    # --- one mountain rim: each region's rounded square and a valley along the branch
    p = rim.get("roundness", 4.0)
    edge = None
    for r in regions:
        if not r.get("rim", False):
            continue
        lx, lz = r["frame"].local(X, Z)
        er = (np.abs(lx) ** p + np.abs(lz) ** p) ** (1.0 / p)
        edge = er if edge is None else geom.smooth_min(edge, er, rim["blend"])
    if valley_road is not None:
        ev = geom.bilinear(V_c, (x0, z0), cc, X, Z) * rim["start"] / rim["valley"]
        edge = ev if edge is None else geom.smooth_min(edge, ev, rim["blend"])
    bmask = geom.smoothstep(rim["start"], rim["end"], edge)
    H += bmask * rim["height"] * (0.55 + 0.9 * noise.ridged(X, Z, 260.0, 5, seed + 21))

    # --- terraces (flat stepped fields)
    for r in regions:
        for tr in r["spec"]["terrain"].get("terraces", []):
            poly = np.array(tr["poly"], dtype=np.float64)
            inside = geom.point_in_polygon(X, Z, poly)
            dpoly, _ = geom.polyline_distance(X[inside], Z[inside],
                                              np.column_stack([poly[:, 0], np.zeros(len(poly)), poly[:, 1]]), closed=True)
            step = tr["step"]
            hq = np.floor(H[inside] / step) * step + step * 0.5
            wgt_t = geom.smoothstep(0.0, tr.get("edge", 18.0), dpoly)
            H[inside] = H[inside] + (hq - H[inside]) * wgt_t

    # --- lake bowl
    lake_sd = np.full(X.shape, 1e9)
    if water.lake_poly is not None:
        lp = water.lake_poly
        poly3 = np.column_stack([lp[:, 0], np.zeros(len(lp)), lp[:, 1]])
        box = (np.abs(X - lp[:, 0].mean()) < np.ptp(lp[:, 0]) / 2 + 160) & \
              (np.abs(Z - lp[:, 1].mean()) < np.ptp(lp[:, 1]) / 2 + 160)
        dl, _ = geom.polyline_distance(X[box], Z[box], poly3, closed=True)
        inside = geom.point_in_polygon(X[box], Z[box], lp)
        sd = np.where(inside, -dl, dl)
        lake_sd[box] = sd
        lvl = water.lake_level
        depth = water.lake.get("depth", 4.0)
        shore = water.lake.get("shore", 40.0)
        hb = H[box]
        bed = lvl - depth * geom.smoothstep(0.0, 45.0, -sd) - 0.4
        beach = lvl + 0.35 + (hb - lvl - 0.35) * geom.smoothstep(0.0, shore, sd)
        hb = np.where(sd < 0, bed, np.minimum(hb, beach) if water.lake.get("clamp_shore", False) else beach)
        H[box] = hb

    # --- river channels (each river in turn; the normalised distance of the nearest one). A
    # channel fades out as it climbs into the rim, well before the top: a river springs from the
    # mountainside and never notches the skyline at the world's edge.
    river_dist = np.full(X.shape, 1e9)
    river_y = np.zeros(X.shape)
    ref_half = water.river_width / 2.0
    carve_w = 1.0 - geom.smoothstep(rim["start"] + 0.55 * (rim["end"] - rim["start"]), rim["end"] - 20.0, edge)
    for rv in water.rivers:
        rf = geom.RoadField(X, Z, (x0, z0), cell)
        rf.add_polyline(rv.pts, rv.s, radius=110.0, closed=False)
        inner = rv.width / 2.0
        near = np.isfinite(rf.dist)
        dn = rf.dist[near]
        wy = rf.y[near]
        hn = H[near]
        dh = np.abs(hn - wy)
        E = np.clip(8.0 + 1.5 * dh, 8.0, 95.0)
        # gorges: steeper banks (shorter blend) around the listed points
        for st in rv.steep:
            dg = np.hypot(X[near] - st["pos"][0], Z[near] - st["pos"][1])
            wg = 1.0 - geom.smoothstep(st["radius"] * 0.5, st["radius"], dg)
            E = E * (1.0 - wg * (1.0 - st["bank"]))
        bed = wy - rv.depth * (1.0 - (np.minimum(dn, inner) / inner) ** 2) - 0.15
        bank = wy + 0.25 + (hn - wy - 0.25) * geom.smoothstep(inner, inner + E, dn)
        # a tributary never refills a channel already carved: its banks only cut down there
        carved = river_dist[near] < ref_half + 3.0
        cw = carve_w[near]
        H[near] = hn + (np.where(dn < inner, bed, np.where(carved, np.minimum(hn, bank), bank)) - hn) * cw
        dnorm = np.where(near, rf.dist - (inner - ref_half), 1e9)
        upd = (dnorm < river_dist) & (carve_w > 0.5)
        river_dist[upd] = dnorm[upd]
        river_y[upd] = rf.y[upd]
        # plunge pools below waterfalls: a round basin just downstream of the lip
        fr, _, _ = geom.frames(rv.pts, closed=False)
        for k, drop, pool in rv.falls:
            if pool <= 0.0:
                continue
            base = rv.pts[min(k + 1, len(rv.pts) - 1)]
            cx = base[0] + fr[k, 0] * pool * 0.55
            cz = base[2] + fr[k, 1] * pool * 0.55
            dp = np.hypot(X - cx, Z - cz)
            below = (dp < pool + 10.0) & (rf.y <= base[1] + 0.01) & np.isfinite(rf.dist)
            pb = base[1] - rv.depth * 1.6 * (1.0 - (np.minimum(dp, pool) / pool) ** 2) - 0.15
            pk = base[1] + 0.25 + (H - base[1] - 0.25) * geom.smoothstep(pool, pool + 10.0, dp)
            H = np.where(below, np.minimum(H, np.where(dp < pool, pb, pk)), H)
            water.pools.append((float(cx), float(base[1]), float(cz), pool))
            # the pool counts as river water for shores and scatter clearance
            river_dist = np.where(below, np.minimum(river_dist, dp - pool + ref_half), river_dist)

    # --- road cut and fill, every road in turn; the nearest road's fields
    best = np.full(X.shape, np.inf)
    best_edge = np.full(X.shape, np.inf)
    road_seg = np.full(X.shape, -1, dtype=np.int64)
    road_id = np.full(X.shape, -1, dtype=np.int16)
    road_lat = np.zeros(X.shape)
    fields = {}
    for k, (rid, road) in enumerate(roads.items()):
        rf = geom.RoadField(X, Z, (x0, z0), cell)
        step = 2
        rf.add_polyline(road.pos[::step], road.dist[::step], radius=95.0, closed=road.closed)
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
        # bridge ends: the carve fades out towards a deck (road.carve < 1), so natural ground would
        # keep its own height there and a bank higher than the deck pokes through the road. Cap it
        # under the ribbon and ramp it down under the deck at ~40 degrees from the deck edge, so
        # abutments read as cut banks.
        clr = world["roads"][rid].get("bridge_clearance", BRIDGE_CLEARANCE)
        edge_d = np.maximum(rf.dist[near] - hw - road.verge, 0.0)
        cap = y_road - clr * (1.0 - cw) + edge_d * 0.85
        H[near] = np.where(cw < 1.0, np.minimum(H[near], cap), H[near])
        fields[rid] = (rf, near, si)
        ed = np.full(X.shape, np.inf)
        ed[near] = rf.dist[near] - hw
        best_edge = np.minimum(best_edge, ed)
        upd = rf.dist < best
        best[upd] = rf.dist[upd]
        road_id[upd] = k
        road_lat[upd] = rf.lat[upd]
        segs = np.where(near, (rf.seg * step) % len(road.pos), -1)
        road_seg[upd] = segs[upd]
    road_dist = np.where(np.isfinite(best), best, D_far)
    # the roads' widths differ (10 m loops, 7 m branch): roadside rules measure from the edge
    road_edge = np.where(np.isfinite(best_edge), best_edge,
                         D_far - min(float(rd.half_width.min()) for rd in roads.values()))

    # --- pads: flat ground for buildings and plazas, kept off the road corridor
    verge_max = max(float(rd.verge) for rd in roads.values())
    for rid, pad in pads:
        if "road_at" in pad:
            road = roads[rid]
            s = road.control_s[pad["road_at"]] + pad.get("offset_m", 0.0)
            i = road_index(road, s % road.length if road.closed else s)
            px = road.pos[i, 0] + road.right[i, 0] * pad.get("lateral", 0.0)
            pz = road.pos[i, 2] + road.right[i, 1] * pad.get("lateral", 0.0)
            h0 = road.pos[i, 1] - CARVE_DROP
        else:
            px, pz = pad["pos"]
            h0 = float(geom.bilinear(H, (x0, z0), cell, np.array([px]), np.array([pz]))[0])
        h0 = pad.get("height", h0) + pad.get("rise", 0.0)
        r = pad["radius"]
        blend = pad.get("blend", 10.0)
        reach = r + blend
        ia = max(0, int((px - reach - x0) / cell))
        ib = min(nx, int((px + reach - x0) / cell) + 2)
        ja = max(0, int((pz - reach - z0) / cell))
        jb = min(nz, int((pz + reach - z0) / cell) + 2)
        dpad = np.hypot(X[ja:jb, ia:ib] - px, Z[ja:jb, ia:ib] - pz)
        wpad = 1.0 - geom.smoothstep(r, r + blend, dpad)
        keep = geom.smoothstep(verge_max + 1.5, verge_max + 5.0, road_edge[ja:jb, ia:ib])
        sub = H[ja:jb, ia:ib]
        H[ja:jb, ia:ib] = sub + (h0 - sub) * wpad * keep

    # --- lots: flat under the paved area and its verge ring, then easing into the ground
    lot_sd = np.full(X.shape, 1e9)
    for road in roads.values():
        for lot in road.lots:
            sd = lot.sdf(X, Z)
            y = lot.y - CARVE_DROP
            E = np.clip(6.0 + 1.3 * np.abs(H - y), 6.0, 75.0)
            tt = geom.smoothstep(LOT_SKIRT, LOT_SKIRT + E, sd)
            H = y + (H - y) * tt
            lot_sd = np.minimum(lot_sd, sd)

    # --- caps: the ground stays under every ribbon where it is built, and under the aprons
    for rid, road in roads.items():
        rf, near, si = fields[rid]
        lat = rf.lat[near]
        on = (rf.dist[near] <= road.half_width[si] + road.verge + 0.6) & (road.carve[si] >= 1.0) & built[rid][si]
        y = road_height_at(road, si, lat) - CARVE_DROP
        hn = H[near]
        H[near] = np.where(on, np.minimum(hn, y), hn)
    for pos, idx in caps:
        cap_under_mesh(H, x0, z0, cell, pos, idx, CARVE_DROP)

    diag = cell_diag(nx - 1, nz - 1, seed)
    return Terrain(cell=cell, ox=x0, oz=z0, X=X, Z=Z, H=H, diag=diag, road_dist=road_dist, road_edge=road_edge,
                   road_lat=road_lat, road_seg=road_seg, road_id=road_id, lake_sd=lake_sd, river_dist=river_dist,
                   river_y=river_y, water=water, lot_sd=lot_sd, edge=edge, weights=Wt)


def grid_normals(ter: Terrain) -> np.ndarray:
    """(nz, nx, 3) vertex normals of the whole triangulated grid (seamless across chunks)."""
    H, X, Z = ter.H, ter.X, ter.Z
    nz, nx = H.shape
    P = np.stack([X, H, Z], axis=2).reshape(-1, 3)
    jj, ii = np.meshgrid(np.arange(nz - 1), np.arange(nx - 1), indexing="ij")
    v00 = (jj * nx + ii).ravel()
    v10 = v00 + 1
    v01 = v00 + nx
    v11 = v01 + 1
    dg = ter.diag.ravel()
    t0 = np.where(dg[:, None] == 0, np.stack([v00, v10, v11], 1), np.stack([v00, v10, v01], 1))
    t1 = np.where(dg[:, None] == 0, np.stack([v00, v11, v01], 1), np.stack([v10, v11, v01], 1))
    tri = np.concatenate([t0, t1])
    a, b, c = P[tri[:, 0]], P[tri[:, 1]], P[tri[:, 2]]
    fn = np.cross(c - a, b - a)
    fn *= np.sign(fn[:, 1:2] + 1e-12)  # all up
    n = np.zeros_like(P)
    for k in range(3):
        np.add.at(n, tri[:, k], fn)
    n /= np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-12)
    return n.reshape(nz, nx, 3)


def chunk_mesh(ter: Terrain, i0: int, i1: int, j0: int, j1: int, colors: np.ndarray, normals: np.ndarray):
    """Vertices [j0..j1] x [i0..i1] (inclusive) and triangles of the cells inside."""
    sub_h = ter.H[j0:j1 + 1, i0:i1 + 1]
    sx = ter.X[j0:j1 + 1, i0:i1 + 1]
    sz = ter.Z[j0:j1 + 1, i0:i1 + 1]
    nzv, nxv = sub_h.shape
    pos = np.stack([sx.ravel(), sub_h.ravel(), sz.ravel()], axis=1)
    col = colors[j0:j1 + 1, i0:i1 + 1].reshape(-1, colors.shape[2])
    nrm = normals[j0:j1 + 1, i0:i1 + 1].reshape(-1, 3)
    jj, ii = np.meshgrid(np.arange(nzv - 1), np.arange(nxv - 1), indexing="ij")
    v00 = (jj * nxv + ii).ravel()
    v10 = v00 + 1
    v01 = v00 + nxv
    v11 = v01 + 1
    dg = ter.diag[j0:j1, i0:i1].ravel()
    t0 = np.where(dg[:, None] == 0, np.stack([v00, v10, v11], 1), np.stack([v00, v10, v01], 1))
    t1 = np.where(dg[:, None] == 0, np.stack([v00, v11, v01], 1), np.stack([v10, v11, v01], 1))
    idx = np.concatenate([t0, t1], axis=1).ravel()
    return pos, col, nrm, idx


def chunk_mesh_far(ter: Terrain, i0: int, i1: int, j0: int, j1: int, colors: np.ndarray, normals: np.ndarray,
                   step: int, skirt: float):
    """The same chunk every `step` vertices, with a skirt `skirt` m deep on every edge (both
    windings) so it never shows a crack against a finer neighbour."""
    ii = np.arange(i0, i1 + 1, step)
    jj = np.arange(j0, j1 + 1, step)
    if ii[-1] != i1:
        ii = np.append(ii, i1)
    if jj[-1] != j1:
        jj = np.append(jj, j1)
    J, I = np.meshgrid(jj, ii, indexing="ij")
    nzv, nxv = J.shape
    pos = np.stack([ter.X[J, I].ravel(), ter.H[J, I].ravel(), ter.Z[J, I].ravel()], axis=1)
    col = colors[J, I].reshape(-1, colors.shape[2])
    nrm = normals[J, I].reshape(-1, 3)
    a, b = np.meshgrid(np.arange(nzv - 1), np.arange(nxv - 1), indexing="ij")
    v00 = (a * nxv + b).ravel()
    v10 = v00 + 1
    v01 = v00 + nxv
    v11 = v01 + 1
    tris = [np.stack([v00, v10, v11], 1), np.stack([v00, v11, v01], 1)]
    # the ring around the edge, in order, and its copy lowered by the skirt depth
    ring = list(range(0, nxv)) + [k * nxv + nxv - 1 for k in range(1, nzv)] + \
        [(nzv - 1) * nxv + k for k in range(nxv - 2, -1, -1)] + [k * nxv for k in range(nzv - 2, 0, -1)]
    ring = np.array(ring)
    base = len(pos)
    low = pos[ring].copy()
    low[:, 1] -= skirt
    pos = np.vstack([pos, low])
    col = np.vstack([col, col[ring]])
    nrm = np.vstack([nrm, nrm[ring]])
    m = len(ring)
    k = np.arange(m)
    k2 = (k + 1) % m
    top_a, top_b = ring[k], ring[k2]
    bot_a, bot_b = base + k, base + k2
    quad = [np.stack([top_a, top_b, bot_b], 1), np.stack([top_a, bot_b, bot_a], 1)]
    quad += [q[:, ::-1] for q in quad]
    idx = np.concatenate(tris + quad).ravel()
    return pos, col, nrm, idx
