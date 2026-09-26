#!/usr/bin/env python3
"""Sakura Rally map compiler.

    uv run --with numpy --with pillow python tools/mapgen/mapgen.py [hanami|momiji|all]

Reads the map specs in tools/mapgen/maps/, the props manifest
(assets/models/props/manifest.json) and writes, per map:
  assets/maps/<id>/map.json   descriptors, track data, checkpoints, instances
  assets/maps/<id>/map.bin    mesh and grid blobs (see lib/meshpack.py)
  docs/renders/map_<id>.png   top-down preview
scripts/world/map_loader.gd assembles these into the playable scene.
"""
from __future__ import annotations

import importlib
import json
import math
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)

from lib import geom, noise  # noqa: E402
from lib.meshpack import MeshBuilder, MeshPack  # noqa: E402
from lib.road import (PROFILE, SURFACES, build_bridge, build_delineators, build_guardrails,  # noqa: E402
                      build_road, guardrail_runs, phys_surface, ribbon_indices, road_chunks,
                      road_height_at, road_vertices)
from lib.scatter import Placer  # noqa: E402
from lib.terrain import build_terrain, build_water, chunk_mesh  # noqa: E402

MAPS = ("hanami", "momiji")
TERRAIN_SURFACES = ("grass", "dirt", "sand", "gravel")


def lin(hex_str: str) -> np.ndarray:
    h = hex_str.lstrip("#")
    c = np.array([int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)])
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def to_srgb(c: np.ndarray) -> np.ndarray:
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)


def mix(a, b, t):
    t = np.asarray(t)[..., None] if np.ndim(t) else t
    return a + (b - a) * t


def load_manifest() -> dict:
    path = os.environ.get("SR_PROPS_MANIFEST",
                          os.path.join(REPO, "assets", "models", "props", "manifest.json"))
    if not os.path.exists(path):
        print("WARN no props manifest; scatter uses fallback footprints")
        return {}
    with open(path) as f:
        return {p["name"]: p for p in json.load(f)["props"]}


# ---------------------------------------------------------------------- colour

def paint_terrain(spec: dict, ter, road, placed: dict, manifest: dict) -> tuple[np.ndarray, np.ndarray]:
    pal = {k: (lin(v) if isinstance(v, str) else [lin(x) for x in v]) for k, v in spec["palette"].items()}
    X, Z, H = ter.X, ter.Z, ter.H
    seed = spec["seed"]
    n1 = noise.fbm(X, Z, 110.0, 4, 2.0, 0.5, seed + 31) * 0.5 + 0.5
    n2 = noise.fbm(X, Z, 36.0, 3, 2.0, 0.5, seed + 37) * 0.5 + 0.5
    n3 = noise.fbm(X, Z, 300.0, 3, 2.0, 0.5, seed + 41)
    g = pal["grass"]
    col = mix(g[0], g[1], geom.smoothstep(0.35, 0.65, n1))
    col = mix(col, g[2], geom.smoothstep(0.62, 0.78, n2) * 0.8)
    col = mix(col, pal["grass_dry"], geom.smoothstep(0.15, 0.45, n3) * 0.3)

    # forest floor / petals / leaf litter under trees
    tree_w = np.zeros(H.shape)
    petal_w = np.zeros(H.shape)
    cell = ter.cell
    for name, inst in placed.items():
        m = manifest.get(name, {})
        if m.get("category") != "tree":
            continue
        blossom = name.startswith("sakura")
        maple = name.startswith("maple") or name.startswith("persimmon")
        rad = max(3.0, float(m.get("footprint_radius", 3.0)) * 1.4)
        k = int(math.ceil(rad / cell)) + 1
        for (x, y, z, yaw, sc) in inst:
            ci = int(round((x - ter.origin) / cell))
            cj = int(round((z - ter.origin) / cell))
            i0, i1 = max(0, ci - k), min(ter.n, ci + k + 1)
            j0, j1 = max(0, cj - k), min(ter.n, cj + k + 1)
            if i0 >= i1 or j0 >= j1:
                continue
            dx = X[j0:j1, i0:i1] - x
            dz = Z[j0:j1, i0:i1] - z
            w = np.exp(-(dx * dx + dz * dz) / (rad * sc) ** 2)
            tree_w[j0:j1, i0:i1] += w
            if blossom or maple:
                petal_w[j0:j1, i0:i1] += w * (1.6 if blossom else 1.3)
    tree_w = np.clip(tree_w, 0.0, 1.0)
    col = mix(col, pal["forest_floor"], tree_w * 0.75)
    petals = np.clip(petal_w, 0.0, 1.0) * geom.smoothstep(0.2, 0.7, n2 + 0.25)
    if "petal" in pal:
        col = mix(col, pal["petal"], petals * 0.7)
    if "litter" in pal:
        lit = pal["litter"]
        lc = mix(lit[0], lit[1], geom.smoothstep(0.3, 0.7, n1))
        lc = mix(lc, lit[2], geom.smoothstep(0.55, 0.8, n2))
        col = mix(col, lc, petals * 0.85)

    # painted forest canopy: away from the road the ground itself carries mottled patches
    # of tree-top colour, so distant slopes read as dense forest without instances
    canopy_w = np.zeros(H.shape)
    can = spec["terrain"].get("canopy")
    if can and "canopy" in pal:
        cc = pal["canopy"]
        nc = noise.fbm(X, Z, can.get("scale", 34.0), 3, 2.0, 0.55, seed + 91) * 0.5 + 0.5
        nb = noise.fbm(X, Z, can.get("scale", 34.0) * 0.35, 2, 2.0, 0.5, seed + 93) * 0.12
        ccol = cc[0]
        for k in range(1, len(cc)):
            edge = k / len(cc)
            ccol = mix(ccol, cc[k], geom.smoothstep(edge - 0.03, edge + 0.03, nc + nb))
        mask = noise.fbm(X, Z, can.get("mask_scale", 160.0), 3, 2.0, 0.5, seed + 95)
        canopy_w = geom.smoothstep(can.get("near", 50.0), can.get("far", 120.0), ter.road_dist)
        canopy_w *= geom.smoothstep(can.get("threshold", -0.25) - 0.1, can.get("threshold", -0.25) + 0.1, mask)
        canopy_w *= can.get("amount", 0.9)
        # canopy thins out into meadow near the water
        canopy_w *= geom.smoothstep(12.0, 40.0, np.minimum(ter.lake_sd, ter.river_dist))
        col = mix(col, ccol, canopy_w)

    # terraces read as fields
    for terr in spec["terrain"].get("terraces", []):
        inside = geom.point_in_polygon(X, Z, np.array(terr["poly"], dtype=np.float64))
        fn = noise.fbm(X, Z, 20.0, 2, 2.0, 0.5, seed + 55) * 0.5 + 0.5
        fc = mix(pal["field"], pal.get("field2", pal["field"]), geom.smoothstep(0.4, 0.6, fn))
        col = np.where(inside[..., None], mix(col, fc, 0.9), col)
        canopy_w = np.where(inside, 0.0, canopy_w)

    ny = ter.normal_y()
    slope = 1.0 - ny
    rock = geom.smoothstep(0.22, 0.4, slope + noise.fbm(X, Z, 24.0, 2, 2.0, 0.5, seed + 61) * 0.08)
    if can:  # forest clings to all but the steepest cliffs
        rock = rock * (1.0 - canopy_w * geom.smoothstep(0.55, 0.3, slope) * can.get("rock_cover", 0.8))
    rc = mix(pal["rock"], pal["rock_dark"], geom.smoothstep(0.4, 0.7, n2))
    col = mix(col, rc, rock)

    # road edges: gravel/dirt stages get a narrow worn dirt verge; tarmac keeps
    # grass to the edge with the soft, lighter mown strip of a painted background
    D = ter.road_dist
    si = np.where(ter.road_seg >= 0, ter.road_seg, 0)
    hw = road.half_width[si]
    carve = np.where(ter.road_seg >= 0, road.carve[si], 0.0)
    loose = np.isin(road.surface[si], [SURFACES.index("gravel"), SURFACES.index("dirt")]).astype(np.float64)
    edge_noise = noise.fbm(X, Z, 9.0, 2, 2.0, 0.5, seed + 71) * 1.2
    near = (1.0 - geom.smoothstep(hw + road.verge + 0.5, hw + road.verge + 2.5, D + edge_noise)) * carve
    verge = near * loose
    col = mix(col, pal["dirt"], verge * 0.8)
    col = mix(col, pal.get("verge_grass", pal["grass_dry"]), near * (1.0 - loose) * 0.55)

    # shores
    rw = ter.water.river_width / 2.0
    shore = np.maximum(1.0 - geom.smoothstep(2.0, 9.0, ter.lake_sd + edge_noise),
                       1.0 - geom.smoothstep(rw + 1.0, rw + 5.0, ter.river_dist + edge_noise))
    col = mix(col, pal["sand"], shore * 0.9)

    # boundary mountains get the mountain tint, higher = darker forest green
    e = np.maximum(np.abs(X), np.abs(Z))
    mt = geom.smoothstep(spec["terrain"]["boundary"]["start"], spec["terrain"]["boundary"]["end"], e)
    col = mix(col, pal["mountain"], mt * 0.6)

    jitter = noise.fbm(X, Z, 6.0, 1, 2.0, 0.5, seed + 81) * 0.05
    col = col * (1.0 + jitter[..., None])
    alpha = petals * (1.0 - rock) * (1.0 - verge * 0.3)
    rgba = np.concatenate([np.clip(col, 0, 1), alpha[..., None]], axis=2)

    # physics surface grid
    surf = np.zeros(H.shape, dtype=np.uint8)
    surf[verge > 0.5] = TERRAIN_SURFACES.index("dirt")
    surf[shore > 0.5] = TERRAIN_SURFACES.index("sand")
    surf[rock > 0.6] = TERRAIN_SURFACES.index("gravel")
    return rgba, surf


# ---------------------------------------------------------------------- meshes

def emit_terrain(pack: MeshPack, ter, rgba: np.ndarray, spec: dict) -> None:
    cells = ter.n - 1
    cs = spec.get("chunk_cells", 50)
    collide_half = spec["play_half"] + 90.0
    for cj in range(0, cells, cs):
        for ci in range(0, cells, cs):
            i1 = min(cells, ci + cs)
            j1 = min(cells, cj + cs)
            pos, col, idx = chunk_mesh(ter, ci, i1, cj, j1, rgba)
            x0, x1 = pos[:, 0].min(), pos[:, 0].max()
            z0, z1 = pos[:, 2].min(), pos[:, 2].max()
            collide = "trimesh" if (x1 > -collide_half and x0 < collide_half and z1 > -collide_half and z0 < collide_half) else "none"
            pack.add(f"terrain_{ci // cs}_{cj // cs}", pos, idx, col=col, material="terrain",
                     collide=collide, surface="grass")


def emit_road(pack: MeshPack, road, ter, rgba: np.ndarray, spec: dict) -> None:
    verts, lat = road_vertices(road)
    n = len(road.pos)
    hw = road.half_width[:, None]
    u = lat / hw
    v = np.repeat(road.dist[:, None], PROFILE, axis=1)
    # verge colour = terrain paint under it, alpha = petals
    vx = verts[..., 0].ravel()
    vz = verts[..., 2].ravel()
    col = np.stack([ter.sample(rgba[..., k], vx, vz) for k in range(4)], axis=1).reshape(n, PROFILE, 4)
    # surface weights for the shader: uv2 = (gravel_or_dirt, wood); tarmac = neither
    sid = road.surface
    grav = np.isin(sid, [SURFACES.index("gravel"), SURFACES.index("dirt")]).astype(np.float64)
    wood = (sid == SURFACES.index("wood")).astype(np.float64)
    grav = np.clip(geom.smooth(grav, 4.0, closed=True), 0, 1)
    wood = np.where(wood > 0, 1.0, 0.0)
    for (a, b) in road_chunks(road):
        rows = list(range(a, b + 1))
        rows = [r % n for r in rows]
        P = verts[rows].reshape(-1, 3)
        U = np.stack([u[rows].ravel(), v[rows].ravel()], axis=1)
        C = col[rows].reshape(-1, 4)
        U2 = np.stack([np.repeat(grav[rows], PROFILE), np.repeat(wood[rows], PROFILE)], axis=1)
        idx = ribbon_indices(len(rows), PROFILE, closed=False)
        surf = phys_surface(int(np.bincount(road.surface[a:b]).argmax()))
        d = pack.add(f"road_{a}", P, idx, col=C, uv=U, material="road", collide="trimesh", surface=surf)
        # second UV set rides in a raw block next to the mesh
        raw = pack.add_raw(f"road_{a}_uv2", U2, "<f4")
        d["uv2_raw"] = raw["name"]


def emit_water(pack: MeshPack, ter, spec: dict) -> dict:
    info = {}
    w = ter.water
    if w.lake_poly is not None:
        lvl = w.lake_level
        step = 8.0
        x0, x1 = w.lake_poly[:, 0].min() - 20, w.lake_poly[:, 0].max() + 20
        z0, z1 = w.lake_poly[:, 1].min() - 20, w.lake_poly[:, 1].max() + 20
        gx = np.arange(x0, x1 + step, step)
        gz = np.arange(z0, z1 + step, step)
        GX, GZ = np.meshgrid(gx, gz)
        sd = ter.sample(ter.lake_sd, GX, GZ)
        nzv, nxv = GX.shape
        keep_v = sd < 14.0
        pos = np.stack([GX.ravel(), np.full(GX.size, lvl), GZ.ravel()], axis=1)
        depth = np.clip((lvl - ter.height_at(GX, GZ)) / 4.0, 0.0, 1.0).ravel()
        col = np.stack([depth, depth, depth, np.ones_like(depth)], axis=1)
        idx = []
        for j in range(nzv - 1):
            for i in range(nxv - 1):
                a = j * nxv + i
                b, c, d = a + 1, a + nxv + 1, a + nxv
                if keep_v[j, i] or keep_v[j, i + 1] or keep_v[j + 1, i] or keep_v[j + 1, i + 1]:
                    idx.extend([a, b, c, a, c, d])
        uv = pos[:, [0, 2]] * 0.02
        pack.add("lake", pos, np.array(idx), col=col, uv=uv, material="water", nrm=np.tile([0.0, 1.0, 0.0], (len(pos), 1)))
        info["lake"] = {"level": lvl, "poly": [[round(float(a), 1), round(float(b), 1)] for a, b in w.lake_poly[::2]]}
    if w.river is not None:
        rp = w.river
        fwd, right, _ = geom.frames(rp, closed=False)
        half = w.river_width / 2.0 + 1.2
        cols = 5
        lat = np.linspace(-half, half, cols)
        P = np.empty((len(rp), cols, 3))
        P[..., 0] = rp[:, 0:1] + right[:, 0:1] * lat
        P[..., 2] = rp[:, 2:3] + right[:, 1:2] * lat
        P[..., 1] = rp[:, 1:2]
        U = np.stack([np.broadcast_to(lat / half, (len(rp), cols)),
                      np.broadcast_to(w.river_s[:, None], (len(rp), cols))], axis=2)
        # depth tint: centre deep, edges shallow
        dcol = np.broadcast_to((1.0 - np.abs(lat / half)) ** 0.7, (len(rp), cols))
        C = np.stack([dcol, dcol, dcol, np.ones_like(dcol)], axis=2)
        step = 120
        for a in range(0, len(rp) - 1, step):
            b = min(len(rp) - 1, a + step)
            rows = np.arange(a, b + 1)
            idx = ribbon_indices(len(rows), cols, closed=False)
            pack.add(f"river_{a}", P[rows].reshape(-1, 3), idx, col=C[rows].reshape(-1, 4),
                     uv=U[rows].reshape(-1, 2), material="water_river",
                     nrm=np.tile([0.0, 1.0, 0.0], (len(rows) * cols, 1)))
        info["river"] = {"width": w.river_width,
                         "points": [[round(float(p[0]), 2), round(float(p[1]), 2), round(float(p[2]), 2)] for p in rp[::2]]}
        emit_falls(pack, w, fwd, right)
    return info


def emit_falls(pack: MeshPack, w, fwd: np.ndarray, right: np.ndarray) -> None:
    """Waterfall curtains (a bowed sheet from the lip down to the pool, streaking in the
    river shader) and flat plunge-pool discs."""
    rp = w.river
    for n_fall, (k, drop, _pool) in enumerate(w.falls):
        top = rp[k].copy()
        bot = rp[min(k + 1, len(rp) - 1)]
        half = w.river_width / 2.0 + 0.8
        cols, rows = 7, 9
        lat = np.linspace(-half, half, cols)
        t = np.linspace(0.0, 1.0, rows)
        # the sheet leaves the lip forward and falls in a parabola, bellying out a little
        out = 0.4 + 1.6 * np.sqrt(t)
        y = top[1] + 0.05 - (top[1] + 0.05 - (bot[1] - 0.3)) * t
        P = np.empty((rows, cols, 3))
        P[..., 0] = top[0] + fwd[k, 0] * out[:, None] + right[k, 0] * lat[None, :] * (1.0 - 0.08 * t[:, None])
        P[..., 2] = top[2] + fwd[k, 1] * out[:, None] + right[k, 1] * lat[None, :] * (1.0 - 0.08 * t[:, None])
        P[..., 1] = y[:, None]
        # |u| >= 1 everywhere switches on the shader's streak foam; v runs down the sheet
        U = np.stack([np.broadcast_to(1.0 + (lat / half + 1.0) * 1.5, (rows, cols)),
                      np.broadcast_to((t * drop * 4.0)[:, None], (rows, cols))], axis=2)
        C = np.ones((rows, cols, 4))
        nrm = np.tile([fwd[k, 0], 0.3, fwd[k, 1]], (rows * cols, 1))
        nrm /= np.linalg.norm(nrm, axis=1, keepdims=True)
        pack.add(f"waterfall_{n_fall}", P.reshape(-1, 3), ribbon_indices(rows, cols, closed=False),
                 col=C.reshape(-1, 4), uv=U.reshape(-1, 2), material="water_river", nrm=nrm)
    for n_pool, (cx, lvl, cz, rad) in enumerate(w.pools):
        seg = 20
        ang = np.linspace(0.0, 2.0 * np.pi, seg, endpoint=False)
        ring = np.stack([cx + np.cos(ang) * (rad + 1.5), np.full(seg, lvl - 0.02), cz + np.sin(ang) * (rad + 1.5)], axis=1)
        pos = np.vstack([[cx, lvl - 0.02, cz], ring])
        idx = np.array([[0, 1 + (s + 1) % seg, 1 + s] for s in range(seg)]).ravel()
        col = np.tile([1.0, 1.0, 1.0, 1.0], (len(pos), 1))
        col[1:, :3] = 0.3
        pack.add(f"pool_{n_pool}", pos, idx, col=col, uv=pos[:, [0, 2]] * 0.02, material="water",
                 nrm=np.tile([0.0, 1.0, 0.0], (len(pos), 1)))


def emit_backdrop(pack: MeshPack, spec: dict) -> None:
    bd = spec["backdrop"]
    seed = spec["seed"] + 500
    radii = np.array([900.0, 1150.0, 1500.0, 1950.0, 2500.0, 3200.0, 4100.0, 5200.0])
    seg = 180
    ang = np.linspace(0, 2 * np.pi, seg, endpoint=False)
    A, Rr = np.meshgrid(ang, radii)
    X = np.cos(A) * Rr
    Z = np.sin(A) * Rr
    # jitter ring vertices so facets are irregular
    X += noise.fbm(X, Z, 90.0, 1, 2.0, 0.5, seed) * 60.0
    Z += noise.fbm(X, Z, 90.0, 1, 2.0, 0.5, seed + 1) * 60.0
    rid = noise.ridged(np.cos(A) * 900 + Rr * 0.3, np.sin(A) * 900 - Rr * 0.2, bd.get("scale", 420.0), 5, seed)
    big = noise.fbm(np.cos(A) * 1200, np.sin(A) * 1200, 900.0, 3, 2.0, 0.5, seed + 3) * 0.5 + 0.5
    rise = geom.smoothstep(radii[0], radii[2], Rr)
    fall = 1.0 - geom.smoothstep(radii[-3], radii[-1], Rr)
    Hh = bd.get("base", 120.0) + (bd.get("height", 520.0) * rid * (0.45 + 0.9 * big)) * rise
    Hh = Hh * (0.35 + 0.65 * fall)
    Hh[0] = bd.get("inner", 160.0)
    pos = np.stack([X.ravel(), Hh.ravel(), Z.ravel()], axis=1)
    snow = geom.smoothstep(bd.get("snow", 99999.0), bd.get("snow", 99999.0) + 80.0, Hh)
    c0 = lin(bd["color"])
    c1 = lin(bd.get("color_far", bd["color"]))
    tfar = geom.smoothstep(radii[1], radii[-2], Rr)
    col = mix(c0, c1, tfar)
    if "snow_color" in bd:
        col = mix(col, lin(bd["snow_color"]), snow)
    col = np.concatenate([col.reshape(-1, 3), np.ones((pos.shape[0], 1))], axis=1)
    idx = []
    nr = len(radii)
    for r in range(nr - 1):
        for s in range(seg):
            s2 = (s + 1) % seg
            a = r * seg + s
            b = r * seg + s2
            c = (r + 1) * seg + s2
            d = (r + 1) * seg + s
            # ring r is inner; outward is +r. Clockwise seen from above.
            idx.extend([a, d, c, a, c, b])
    # unshare for flat facets
    idx = np.array(idx)
    p = pos[idx]
    c = col[idx]
    tri = p.reshape(-1, 3, 3)
    fn = np.cross(tri[:, 2] - tri[:, 0], tri[:, 1] - tri[:, 0])
    fn /= np.maximum(np.linalg.norm(fn, axis=1, keepdims=True), 1e-12)
    pack.add("backdrop", p, np.arange(len(p)), col=c, nrm=np.repeat(fn, 3, axis=0), material="backdrop")


def check_corridor(map_id: str, road, ter, placed: dict, manifest: dict) -> None:
    """Warn about solid props (their collision shapes) inside the drivable corridor:
    half width + verge + 1 m from the centreline of any stretch of road."""
    corridor = road.half_width.max() + road.verge + 1.0
    bad = []
    for name, inst in placed.items():
        m = manifest.get(name, {})
        col = m.get("collision", {})
        if m.get("category") == "ground_cover" or col.get("type", "none") == "none" or not inst:
            continue
        a = np.array(inst, dtype=np.float64)
        near = ter.sample(ter.road_dist, a[:, 0], a[:, 2]) < corridor + 25.0
        for x, y, z, yaw, sc in a[near]:
            cy, sy = math.cos(yaw), math.sin(yaw)
            pts = []
            for o in col.get("offsets", [[0.0, 0.0, 0.0]]):
                ox, oz = o[0] * sc, o[2] * sc
                cx, cz = x + ox * cy + oz * sy, z - ox * sy + oz * cy
                if col["type"] == "box":
                    hx, hz = col["size"][0] * sc / 2, col["size"][2] * sc / 2
                    ccx, ccz = col.get("center", [0, 0, 0])[0] * sc, col.get("center", [0, 0, 0])[2] * sc
                    for lx, lz in ((ccx - hx, ccz - hz), (ccx + hx, ccz - hz), (ccx - hx, ccz + hz),
                                   (ccx + hx, ccz + hz), (ccx, ccz)):
                        pts.append((cx + lx * cy + lz * sy, cz - lx * sy + lz * cy, 0.0))
                else:
                    pts.append((cx, cz, col.get("radius", 0.3) * sc))
            for px, pz, rad in pts:
                d = np.sqrt(((road.pos[:, 0] - px) ** 2 + (road.pos[:, 2] - pz) ** 2).min()) - rad
                if d < corridor:
                    bad.append((name, round(float(x), 1), round(float(z), 1), round(float(d), 2)))
                    break
    for b in bad[:30]:
        print(f"[{map_id}] WARN solid prop in road corridor ({corridor:.1f} m): {b[0]} at ({b[1]}, {b[2]}) "
              f"edge {b[3]} m from centreline")
    if len(bad) > 30:
        print(f"[{map_id}] WARN ... {len(bad) - 30} more props in the road corridor")


# ---------------------------------------------------------------------- main build

def build(map_id: str) -> None:
    t0 = time.time()
    spec = importlib.import_module(f"maps.{map_id}").SPEC
    manifest = load_manifest()
    out_dir = os.path.join(REPO, "assets", "maps", map_id)
    os.makedirs(out_dir, exist_ok=True)

    road = build_road(spec["road"])
    grade = np.abs(np.diff(road.pos[:, 1])) / np.maximum(np.diff(road.dist), 1e-6)
    print(f"[{map_id}] road {road.length:.0f} m, y {road.pos[:, 1].min():.1f}..{road.pos[:, 1].max():.1f}, "
          f"max grade {grade.max() * 100:.1f}%, min radius {1.0 / max(np.abs(road.curv).max(), 1e-6):.1f} m")

    water = build_water(spec)
    ter = build_terrain(spec, road, water)
    print(f"[{map_id}] terrain {ter.n}x{ter.n}, h {ter.H.min():.1f}..{ter.H.max():.1f} ({time.time() - t0:.1f}s)")

    placer = Placer(ter, road, manifest, spec["season"], spec["seed"] + 7, spec["play_half"])
    placer.start_s = float((road.control_s[spec["road"]["start_cp"]] + spec["road"].get("start_offset", 0.0))
                           % road.length)
    # keep the start area and road corridor clear
    placer.features(spec.get("features", []))
    counts = {}
    for r in spec.get("scatter", []):
        c = placer.rule(r)
        counts[r.get("name", r["props"][0])] = c
    print(f"[{map_id}] scatter {counts}")
    if placer.missing:
        print(f"[{map_id}] WARN missing props (skipped): {sorted(placer.missing)}")
    check_corridor(map_id, road, ter, placer.out, manifest)

    rgba, surf = paint_terrain(spec, ter, road, placer.out, manifest)

    pack = MeshPack()
    emit_terrain(pack, ter, rgba, spec)
    emit_road(pack, road, ter, rgba, spec)
    water_info = emit_water(pack, ter, spec)
    emit_backdrop(pack, spec)

    # roadside dressing
    pal = spec["palette"]
    dress = MeshBuilder()
    boxes: list = []
    runs = []
    for side in (-1, 1):
        lat = side * (road.half_width + road.verge + 5.0)
        gx = road.pos[:, 0] + road.right[:, 0] * lat
        gz = road.pos[:, 2] + road.right[:, 1] * lat
        drop = road.pos[:, 1] - ter.height_at(gx, gz)
        for a, b in guardrail_runs(road, drop, side):
            runs.append((a, b, side))
    build_guardrails(road, runs, dress, boxes, lin(pal.get("rail_post", "8f98a3")), lin(pal.get("rail", "d7dde2")))
    build_delineators(road, dress, lin("f4f1ea"), lin("e0452f"), lin("2d2a33"))
    # bridges
    n = len(road.pos)
    i = 0
    br = road.bridge
    bridge_info = []
    visited = np.zeros(n, dtype=bool)
    for i in range(n):
        if br[i] != "" and br[i - 1] == "" and not visited[i]:
            j = i
            while br[j % n] != "" and not visited[j % n]:
                visited[j % n] = True
                j += 1
            build_bridge(road, i, j % n, br[i], ter.height_at, dress, boxes,
                         {k: lin(v) for k, v in pal.items() if k in ("bridge_rail", "bridge_cap", "stone", "wood", "wood_dark")})
            bridge_info.append({"from": float(road.dist[i]), "to": float(road.dist[(j - 1) % n]), "style": br[i]})
    p, nr, c, idx = dress.flat()
    if len(idx):
        pack.add("dressing", p, idx, col=c, nrm=nr, material="props_vc", collide="none")

    # track samples for the runtime (2 m)
    step = 2
    ts = np.arange(0, n, step)
    flags = (road.bridge[ts] != "").astype(np.float64) + 2.0 * road.ford[ts]
    track = np.stack([road.pos[ts, 0], road.pos[ts, 1], road.pos[ts, 2], road.fwd[ts, 0], road.fwd[ts, 1],
                      road.half_width[ts], road.surface[ts].astype(np.float64), flags, road.dist[ts],
                      road.bank[ts]], axis=1)
    pack.add_raw("track", track, "<f4", columns=["x", "y", "z", "fx", "fz", "half_width", "surface",
                                                 "flags", "dist", "bank"])
    sg = surf[::2, ::2]
    pack.add_raw("surface_grid", sg, "u1", origin=ter.origin, cell=ter.cell * 2, codes=list(TERRAIN_SURFACES))

    # start and checkpoints
    rs = spec["road"]
    start_s = (road.control_s[rs["start_cp"]] + rs.get("start_offset", 0.0)) % road.length
    ncp = rs.get("checkpoints", 6)
    cps = []
    for k in range(1, ncp + 1):
        s = (start_s + road.length * k / ncp) % road.length
        ii = int(round(s)) % n
        cps.append({"index": k - 1, "s": round(float((road.length * k / ncp)), 2),
                    "pos": [round(float(v), 3) for v in road.pos[ii]],
                    "yaw": round(float(math.atan2(-road.fwd[ii, 0], -road.fwd[ii, 1])), 4),
                    "half_width": round(float(road.half_width[ii] + road.verge + 1.0), 2)})
    si = int(round(start_s)) % n
    spawn_i = int(round(start_s - rs.get("grid_back", 12.0))) % n
    spawn = {"pos": [round(float(road.pos[spawn_i, 0]), 3), round(float(road.pos[spawn_i, 1] + 0.6), 3),
                     round(float(road.pos[spawn_i, 2]), 3)],
             "yaw": round(float(math.atan2(-road.fwd[spawn_i, 0], -road.fwd[spawn_i, 1])), 4)}

    out = {
        "id": map_id, "version": 1, "season": spec["season"], "atmosphere": spec["atmosphere"],
        "size": ter.size, "cell": ter.cell, "play_half": spec["play_half"],
        "bin": f"res://assets/maps/{map_id}/map.bin",
        "road": {"length": round(road.length, 2), "start_s": round(float(start_s), 2),
                 "verge": road.verge, "surfaces": list(SURFACES), "bridges": bridge_info,
                 "start": {"pos": [round(float(v), 3) for v in road.pos[si]],
                           "yaw": round(float(math.atan2(-road.fwd[si, 0], -road.fwd[si, 1])), 4),
                           "half_width": round(float(road.half_width[si] + road.verge + 1.0), 2)}},
        "spawn": spawn,
        "checkpoints": cps,
        "water": water_info,
        "collision_boxes": boxes,
        "materials": spec.get("materials", {}),
        "meshes": pack.meshes,
        "raw": pack.raw,
        "instances": placer.out,
    }
    pack.save(os.path.join(out_dir, "map.bin"))
    with open(os.path.join(out_dir, "map.json"), "w") as f:
        json.dump(out, f, separators=(",", ":"))
    total = sum(len(v) for v in placer.out.values())
    print(f"[{map_id}] wrote {len(pack.meshes)} meshes, {len(pack.buf) / 1e6:.1f} MB bin, {total} instances, "
          f"{len(boxes)} boxes ({time.time() - t0:.1f}s)")
    preview(map_id, spec, ter, road, rgba, placer.out, cps, spawn)


def preview(map_id: str, spec: dict, ter, road, rgba, placed, cps, spawn) -> None:
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        print("WARN pillow missing; no preview")
        return
    S = 1200
    half = ter.size / 2
    col = to_srgb(rgba[..., :3])
    gz, gx = np.gradient(ter.H, ter.cell)
    nx, nz = -gx, -gz
    ny = np.ones_like(nx)
    ln = np.sqrt(nx * nx + ny * ny + nz * nz)
    sun = np.array([-0.5, 0.75, -0.45])
    sun /= np.linalg.norm(sun)
    shade = np.clip((nx * sun[0] + ny * sun[1] + nz * sun[2]) / ln, 0.0, 1.0)
    col = col * (0.55 + 0.45 * shade[..., None])
    img = Image.fromarray((np.clip(col, 0, 1) * 255).astype(np.uint8)).resize((S, S), Image.BILINEAR)
    dr = ImageDraw.Draw(img)

    def px(x, z):
        return ((x + half) / ter.size * S, (z + half) / ter.size * S)

    if ter.water.lake_poly is not None:
        dr.polygon([px(x, z) for x, z in ter.water.lake_poly], fill=(122, 176, 214))
    if ter.water.river is not None:
        dr.line([px(p[0], p[2]) for p in ter.water.river], fill=(122, 176, 214),
                width=max(2, int(ter.water.river_width / ter.size * S)))
    colors = {"tarmac": (86, 90, 108), "gravel": (196, 170, 128), "dirt": (170, 130, 90), "wood": (150, 100, 60)}
    wpx = max(2, int(2 * road.half_width.mean() / ter.size * S))
    for i in range(len(road.pos)):
        j = (i + 1) % len(road.pos)
        c = colors[SURFACES[road.surface[i]]]
        if road.bridge[i]:
            c = (220, 70, 50)
        dr.line([px(road.pos[i, 0], road.pos[i, 2]), px(road.pos[j, 0], road.pos[j, 2])], fill=c, width=wpx)
    tree_col = {"sakura": (246, 190, 210), "maple": (220, 80, 50), "cedar": (40, 90, 70), "pine": (60, 110, 80),
                "bamboo": (130, 180, 90), "persimmon": (240, 150, 60)}
    for name, inst in placed.items():
        c = next((v for k, v in tree_col.items() if name.startswith(k)), None)
        if c is None:
            c = (70, 70, 80) if not name.startswith(("grass", "flower", "fern", "reed")) else None
        if c is None:
            continue
        for (x, y, z, yaw, sc) in inst:
            X, Y = px(x, z)
            dr.ellipse([X - 1.5, Y - 1.5, X + 1.5, Y + 1.5], fill=c)
    for cp in cps:
        X, Y = px(cp["pos"][0], cp["pos"][2])
        dr.ellipse([X - 5, Y - 5, X + 5, Y + 5], outline=(255, 220, 60), width=2)
    X, Y = px(spawn["pos"][0], spawn["pos"][2])
    dr.rectangle([X - 5, Y - 5, X + 5, Y + 5], fill=(255, 255, 255), outline=(0, 0, 0))
    for k, cpi in enumerate(road.control_s):
        i = int(cpi) % len(road.pos)
        X, Y = px(road.pos[i, 0], road.pos[i, 2])
        dr.text((X + 4, Y - 4), str(k), fill=(20, 20, 30))
    os.makedirs(os.path.join(REPO, "docs", "renders"), exist_ok=True)
    path = os.path.join(REPO, "docs", "renders", f"map_{map_id}.png")
    img.save(path)
    print(f"[{map_id}] preview {path}")


def main() -> None:
    which = sys.argv[1] if len(sys.argv) > 1 else "all"
    for m in (MAPS if which == "all" else [which]):
        build(m)


if __name__ == "__main__":
    main()
