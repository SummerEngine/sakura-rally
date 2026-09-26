#!/usr/bin/env python3
"""Sakura Rally map compiler.

    uv run --with numpy --with pillow python tools/mapgen/mapgen.py [hanami|momiji|natsu|all]

Reads the map specs in tools/mapgen/maps/, the props manifest
(assets/models/props/manifest.json) and writes, per map:
  assets/maps/<id>/map.json   descriptors, track data, checkpoints, instances
  assets/maps/<id>/map.bin    mesh and grid blobs (see lib/meshpack.py)
  docs/renders/map_<id>.png   top-down preview
scripts/world/map_world.gd assembles these into the playable scene.
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
from lib.meshpack import MeshBuilder, MeshPack, rotation  # noqa: E402
from lib.road import (LOT_DROP, PROFILE, SURFACES, build_bridge, build_delineators,  # noqa: E402
                      build_guardrails, build_road, phys_surface, ribbon_indices,
                      road_chunks, road_height_at, road_index, road_vertices)
from lib import roadside  # noqa: E402
from lib.corridor import SMASHABLE, WALLS, Corridor, enforce, format_survey, survey  # noqa: E402
from lib.garage import drop_kept_out, garage_layout, garage_lot, garage_pad, keep_out_circles  # noqa: E402
from lib.scatter import Placer  # noqa: E402
from lib.terrain import LOT_SKIRT, build_terrain, build_water, chunk_mesh  # noqa: E402

MAPS = ("hanami", "momiji", "natsu")
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

    # terraces read as fields; "paddies" terraces alternate shades step by step and draw
    # the grassy bunds on the risers, so the stepped rice fields read from the road
    ny = ter.normal_y()
    slope = 1.0 - ny
    paddy = np.zeros(H.shape, dtype=bool)
    for terr in spec["terrain"].get("terraces", []):
        inside = geom.point_in_polygon(X, Z, np.array(terr["poly"], dtype=np.float64))
        fn = noise.fbm(X, Z, 20.0, 2, 2.0, 0.5, seed + 55) * 0.5 + 0.5
        fc = mix(pal["field"], pal.get("field2", pal["field"]), geom.smoothstep(0.4, 0.6, fn))
        if terr.get("paddies"):
            level = np.floor(H / terr["step"]).astype(np.int64)
            fc = mix(fc, pal.get("field2", pal["field"]), (level % 2 == 1) * 0.85)
            fc = mix(fc, pal["bund"], geom.smoothstep(0.03, 0.09, slope))
            paddy |= inside
        col = np.where(inside[..., None], mix(col, fc, 0.9), col)
        canopy_w = np.where(inside, 0.0, canopy_w)

    rock = geom.smoothstep(0.22, 0.4, slope + noise.fbm(X, Z, 24.0, 2, 2.0, 0.5, seed + 61) * 0.08)
    rock[paddy] = 0.0
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
    # surface weights for the shader: uv2 = (gravel_or_dirt, wood); tarmac = neither.
    # Negative uv2.y = markings fade: an open road's lane lines and shoulders fade out over
    # its last metres into the paved lot it ends in (never overlaps wood: lots carry no decks).
    sid = road.surface
    grav = np.isin(sid, [SURFACES.index("gravel"), SURFACES.index("dirt")]).astype(np.float64)
    wood = (sid == SURFACES.index("wood")).astype(np.float64)
    grav = np.clip(geom.smooth(grav, 4.0, closed=road.closed), 0, 1)
    wood = np.where(wood > 0, 1.0, 0.0)
    if not road.closed:
        end_d = np.minimum(road.dist, road.length - road.dist)
        wood = np.where(road.on_lot > 0.9, wood - (1.0 - geom.smoothstep(6.0, 26.0, end_d)), wood)
    for (a, b) in road_chunks(road):
        # each chunk shares its last row with the next one (around the seam on a loop)
        rows = [r % n for r in range(a, b + 1)] if road.closed else list(range(a, min(b + 1, n)))
        if len(rows) < 2:  # a one-sample tail at the end of an open road: the previous chunk covers it
            continue
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


# lot cross-section, from the paved edge outward: (offset m, height below the surface m, verge)
LOT_RINGS = ((0.0, 0.0, 0.0), (0.35, 0.05, 0.0), (1.2, 0.22, 1.0), (LOT_SKIRT, 0.95, 1.0))


def lot_outline(lot, grow: float, per_corner: int = 8) -> np.ndarray:
    """Rounded-rectangle outline (m, 2) in lot coordinates (across, along), grown by `grow`."""
    r = lot.corner + grow
    ca, cb = lot.half_w - lot.corner, lot.half_l - lot.corner
    pts = []
    for k, (sa, sb) in enumerate(((1, 1), (-1, 1), (-1, -1), (1, -1))):
        ang = np.linspace(k * np.pi / 2, (k + 1) * np.pi / 2, per_corner + 1)
        pts.append(np.stack([sa * ca + r * np.cos(ang), sb * cb + r * np.sin(ang)], axis=1))
    return np.concatenate(pts)


def emit_lots(pack: MeshPack, road, ter, rgba: np.ndarray) -> None:
    """Paved lots: concentric rings from the centre to the edge, then the verge and a skirt
    that tucks under the terrain, like the road ribbon's cross-section. uv = lot metres,
    uv2 = (gravel weight, verge weight) for the road shader's lot mode."""
    for lot in road.lots:
        rings = [lot_outline(lot, 0.0) * s for s in (0.3, 0.62, 0.86)]
        rings += [lot_outline(lot, g) for g, _, _ in LOT_RINGS]
        drops = [0.0, 0.0, 0.0] + [d for _, d, _ in LOT_RINGS]
        verge = [0.0, 0.0, 0.0] + [v for _, _, v in LOT_RINGS]
        m = len(rings[0])
        local = np.vstack([np.zeros((1, 2))] + rings)
        y = np.concatenate([[0.0]] + [np.full(m, -d) for d in drops]) + lot.y - LOT_DROP
        ax, rt = lot.axis, np.array([-lot.axis[1], lot.axis[0]])
        x = lot.center[0] + local[:, 0] * rt[0] + local[:, 1] * ax[0]
        z = lot.center[1] + local[:, 0] * rt[1] + local[:, 1] * ax[1]
        pos = np.stack([x, y, z], axis=1)
        idx = [[0, 1 + (k + 1) % m, 1 + k] for k in range(m)]
        for r in range(len(rings) - 1):
            a0, b0 = 1 + r * m, 1 + (r + 1) * m
            for k in range(m):
                k2 = (k + 1) % m
                idx += [[a0 + k, a0 + k2, b0 + k2], [a0 + k, b0 + k2, b0 + k]]
        idx = np.array(idx)
        # Godot front faces are clockwise from the front: flip any triangle facing down
        t = pos[idx]
        up = np.cross(t[:, 1] - t[:, 0], t[:, 2] - t[:, 0])[:, 1] > 0
        idx[up] = idx[up][:, ::-1]
        col = np.stack([ter.sample(rgba[..., k], x, z) for k in range(4)], axis=1)
        gravel = 1.0 if lot.surface == "gravel" else 0.0
        uv2 = np.stack([np.full(len(pos), gravel), np.concatenate([[0.0]] + [np.full(m, v) for v in verge])], axis=1)
        d = pack.add(f"lot_{lot.name}", pos, idx.ravel(), col=col, uv=local, material="lot",
                     nrm=np.tile([0.0, 1.0, 0.0], (len(pos), 1)), collide="trimesh", surface=lot.surface)
        raw = pack.add_raw(f"lot_{lot.name}_uv2", uv2, "<f4")
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


# ---------------------------------------------------------------------- main build

def _feature_frame(f: dict, placer: Placer) -> tuple[float, float, float, float]:
    """(x, ground y, z, yaw) of a road-relative item. face "approach": the front (+Z) looks
    back down the road at the approaching driver; "road": the front looks at the road."""
    x, z, i = placer.road_point(f)
    face = f.get("face", "approach")
    if face == "approach":
        f2 = placer.road.fwd[i]
        yaw = math.atan2(-f2[0], -f2[1])
    else:
        yaw = placer.resolve_yaw(face, x, z, i) + math.pi  # resolve_yaw points -Z; fronts are +Z
    yaw += math.radians(f.get("yaw_add", 0.0))
    return x, placer.ground_at(x, z), z, yaw


def sign_posts(s: dict) -> dict:
    """Collision shape of a sign's posts (see build_signs) in manifest form, board frame."""
    w = s["board"][0]
    xs = (0.0,) if s.get("posts", 2) == 1 else (-w * 0.34, w * 0.34)
    return {"type": "cylinder", "radius": 0.08, "offsets": [[x, 0.0, -0.07] for x in xs]}


def place_signs(signs: list, placer: Placer, cor: Corridor) -> list[dict]:
    """Resolve road signs (boards with painted text) and keep scatter away from them. They
    break at runtime like the kit's signs, but still stand clear of the rigid road corridor:
    a sign authored inside it steps out until its posts clear it."""
    out = []
    for f in signs:
        f = dict(f)
        x, y, z, yaw = _feature_frame(f, placer)
        col = sign_posts(f)
        side = 1.0 if f.get("lateral", 0.0) >= 0.0 else -1.0
        while cor.prop_margin(col, x, z, yaw, 1.0, "rigid")[0] < 0.0:
            f["lateral"] = f.get("lateral", 0.0) + side * 0.25
            x, y, z, yaw = _feature_frame(f, placer)
        placer.occ.add(x, z, f["board"][0] * 0.5 + 0.5)
        placer.reserved.append((x, z, f["board"][0] * 0.5))
        out.append(dict(f, x=x, y=y, z=z, yaw=yaw))
    return out


def place_parked(cars: list, placer: Placer) -> list[dict]:
    """Parked rally cars (static scene instances at runtime): pos, yaw, car id, livery index."""
    out = []
    for f in cars:
        x, z, i = placer.road_point(f)
        # a car's nose is -Z, which is what resolve_yaw aims at the target
        yaw = placer.resolve_yaw(f.get("face", "along"), x, z, i) + math.radians(f.get("yaw_add", 0.0))
        y = placer.ground_at(x, z)
        placer.occ.add(x, z, 2.4)
        placer.reserved.append((x, z, 2.4))
        out.append({"pos": [round(x, 3), round(y, 3), round(z, 3)], "yaw": round(yaw % (2 * math.pi), 4),
                    "car": f["car"], "livery": int(f["livery"])})
    return out


def build_signs(signs: list, pack: MeshPack) -> list[dict]:
    """Sign boards on posts, one mesh each in `pack` (named sign_<k>, "local": true) in the
    sign's own frame: origin at the base centre on the ground, board front = local +Z, yaw 0.
    The runtime places it at `base` turned by `yaw`, and breaks it like a smashable prop
    (`collider`, sign-local). Text goes to map.json for Label3Ds: `pos` is the board face
    centre in the world, line offsets are metres on the face from its centre."""
    out = []
    for k, s in enumerate(signs):
        w, h = s["board"]
        bottom = s.get("bottom", 1.6)
        rot = rotation(s["yaw"])
        origin = np.array([s["x"], s["y"], s["z"]])
        mb = MeshBuilder()
        post_col = lin(s.get("post_color", "9aa4ae"))
        posts = (0.0,) if s.get("posts", 2) == 1 else (-w * 0.34, w * 0.34)
        for px_ in posts:
            mb.prism((px_, -0.3, -0.07), (px_, bottom + h - 0.08, -0.07), 0.055, 8, post_col)
        cy = bottom + h / 2
        mb.box((0.0, cy, 0.0), (w, h, 0.07), 0.0, lin(s.get("color", "2f67b1")))
        trim = lin(s.get("trim", "f4f1ea"))
        inset, tw, tz = 0.07, 0.045, 0.041
        for (lx, ly, sx, sy) in ((0.0, h / 2 - inset, w - 2 * inset, tw), (0.0, -h / 2 + inset, w - 2 * inset, tw),
                                 (w / 2 - inset, 0.0, tw, h - 2 * inset), (-w / 2 + inset, 0.0, tw, h - 2 * inset)):
            mb.box((lx, cy + ly, tz), (sx, sy, 0.012), 0.0, trim)
        name = f"sign_{k}"
        p, nr, c, idx = mb.flat()
        pack.add(name, p, idx, col=c, nrm=nr, material="props_vc", collide="none", local=True)
        top = bottom + h
        face = origin + rot @ np.array([0.0, cy, 0.05])
        out.append({"pos": [round(float(v), 3) for v in face], "yaw": round(float(s["yaw"]), 4),
                    "base": [round(float(v), 3) for v in origin], "mesh": name,
                    # posts (z -0.125) to the trim (z +0.047), ground to the top of the board
                    "collider": {"type": "box", "size": [round(float(w), 3), round(float(top), 3), 0.26],
                                 "center": [0.0, round(float(top / 2), 3), 0.0]},
                    "lines": [{"text": ln["text"], "font": ln.get("font", "latin"), "size": ln["size"],
                               "offset": list(ln.get("at", (0.0, 0.0))), "color": ln.get("color", "f7f4ec")}
                              for ln in s["lines"]]})
    return out


def build(map_id: str) -> None:
    t0 = time.time()
    spec = importlib.import_module(f"maps.{map_id}").SPEC
    manifest = load_manifest()
    out_dir = os.path.join(REPO, "assets", "maps", map_id)
    os.makedirs(out_dir, exist_ok=True)

    # the garage (maps' GARAGE entry, lib/garage.py): a paved lay-by on the road, a pad under
    # the workshop and a keep-out for props
    garage = spec.get("garage")
    if garage is not None:
        spec = dict(spec, road=dict(spec["road"], lots=list(spec["road"].get("lots", [])) + [garage_lot(garage)]),
                    terrain=dict(spec["terrain"], pads=list(spec["terrain"].get("pads", [])) + [garage_pad(garage)]))
    road = build_road(spec["road"])
    garage_info = garage_layout(garage, road) if garage is not None else None
    grade = np.abs(np.diff(road.pos[:, 1])) / np.maximum(np.diff(road.dist), 1e-6)
    print(f"[{map_id}] road {road.length:.0f} m, y {road.pos[:, 1].min():.1f}..{road.pos[:, 1].max():.1f}, "
          f"max grade {grade.max() * 100:.1f}%, min radius {1.0 / max(np.abs(road.curv).max(), 1e-6):.1f} m")

    water = build_water(spec)
    ter = build_terrain(spec, road, water)
    print(f"[{map_id}] terrain {ter.n}x{ter.n}, h {ter.H.min():.1f}..{ter.H.max():.1f} ({time.time() - t0:.1f}s)")

    # the route: a lap from the start line, or start line to arrival on an open road
    rs = spec["road"]
    start_s = float(road.control_s[rs["start_cp"]] + rs.get("start_offset", 0.0))
    if road.closed:
        start_s %= road.length
        route = road.length
        arrival_s = None
    else:
        arrival_s = float(road.control_s[rs["arrival_cp"]] + rs.get("arrival_offset", 0.0))
        route = arrival_s - start_s

    # the road corridor, widened around every checkpoint (the runtime's fabric gates)
    ncp = rs.get("checkpoints", 6)
    cp_abs = [start_s + route * k / ncp for k in range(1, ncp + 1)]
    cor = Corridor(road, [s % road.length if road.closed else s for s in cp_abs])

    # corners, and the guardrails that keep a car that misses one on the road
    ground = roadside.Ground.from_terrain(ter, road.lots, LOT_DROP)
    corners = roadside.find_corners(road, rs.get("roadside"))
    runs = roadside.rail_runs(road, ground, corners, spec["play_half"], rs.get("roadside"))
    print(f"[{map_id}] roadside {roadside.summary(corners, runs, road)}")

    placer = Placer(ter, road, manifest, spec["season"], spec["seed"] + 7, spec["play_half"])
    placer.start_s = start_s
    placer.route = route
    # keep the start area and road corridor clear
    if garage_info is not None:
        for x, z, r in keep_out_circles(garage_info):
            placer.occ.add(x, z, r)
        placer.features(garage.get("dressing", []))
    placer.features(spec.get("features", []))
    signs = place_signs(spec.get("signs", []), placer, cor)
    parked = place_parked(spec.get("parked", []), placer)
    corner_signs = roadside.place_corner_signs(road, ground, corners, runs, placer, rs.get("roadside"))
    authored = {k: len(v) for k, v in placer.out.items()}
    print(f"[{map_id}] corner signs {dict(sorted(corner_signs.placed.items()))}; warnings visible from "
          + ", ".join("-" if w is None else "s" if w == "series" else f"{w:.0f}" for w in corner_signs.warnings)
          + " m (s: announced by the series sign before it)")
    counts = {}
    for r in spec.get("scatter", []):
        c = placer.rule(r)
        counts[r.get("name", r["props"][0])] = c
    print(f"[{map_id}] scatter {counts}")
    if placer.missing:
        print(f"[{map_id}] WARN missing props (skipped): {sorted(placer.missing)}")
    sight = roadside.clear_sightlines(placer, manifest, corner_signs.sightlines, SMASHABLE, WALLS, authored)
    print(f"[{map_id}] sign sightlines cleared {sight['removed']}"
          + (f", WARN still blocked by {sight['blocking']}" if sight["blocking"] else ""))
    before = survey(cor, placer.out, manifest)

    # roadside dressing
    pal = spec["palette"]
    dress = MeshBuilder()
    boxes: list = []
    build_guardrails(road, runs, dress, boxes, lin(pal.get("rail_post", "8f98a3")), lin(pal.get("rail", "d7dde2")))
    build_delineators(road, dress, lin("f4f1ea"), lin("e0452f"), skip=corner_signs.marker_skip)
    # bridges
    n = len(road.pos)
    i = 0
    br = road.bridge
    bridge_info = []
    visited = np.zeros(n, dtype=bool)
    for i in range(n):
        prev = br[i - 1] if road.closed or i > 0 else ""
        if br[i] != "" and prev == "" and not visited[i]:
            j = i
            while br[j % n] != "" and not visited[j % n]:
                visited[j % n] = True
                j += 1
            build_bridge(road, i, j % n, br[i], ter.height_at, dress, boxes,
                         {k: lin(v) for k, v in pal.items() if k in ("bridge_rail", "bridge_cap", "stone", "wood", "wood_dark")})
            s_off = 0.0 if road.closed else start_s
            bridge_info.append({"from": float(road.dist[i] - s_off), "to": float(road.dist[(j - 1) % n] - s_off),
                                "style": br[i]})

    # nothing rigid in the road corridor: offenders move out (or go), smashables leave the tarmac
    res = enforce(cor, placer, manifest, boxes)
    if garage_info is not None:
        print(f"[{map_id}] garage at {garage_info['pos']}: dropped {drop_kept_out(garage_info, placer.out)} "
              f"instances in its keep-out")
    after = survey(cor, placer.out, manifest)
    print(f"[{map_id}] corridor before: {format_survey(before)}")
    print(f"[{map_id}] corridor moved {res['moved']}, dropped {res['dropped']}: "
          + ", ".join(f"{k} {v[0]}/{v[1]}" for k, v in sorted(res["by_name"].items())))
    print(f"[{map_id}] corridor after:  {format_survey(after)}")
    for name, x, z, m in after["offenders"]:
        print(f"[{map_id}] WARN {name} at ({x}, {z}) is {-m:.2f} m inside the road corridor")

    rgba, surf = paint_terrain(spec, ter, road, placer.out, manifest)

    pack = MeshPack()
    emit_terrain(pack, ter, rgba, spec)
    emit_road(pack, road, ter, rgba, spec)
    emit_lots(pack, road, ter, rgba)
    water_info = emit_water(pack, ter, spec)
    emit_backdrop(pack, spec)

    p, nr, c, idx = dress.flat()
    if len(idx):
        pack.add("dressing", p, idx, col=c, nrm=nr, material="props_vc", collide="none")
    sign_info = build_signs(signs, pack)

    # track samples for the runtime (2 m); an open road measures distance from the start line
    step = 2
    ts = np.arange(0, n, step)
    flags = (road.bridge[ts] != "").astype(np.float64) + 2.0 * road.ford[ts]
    track = np.stack([road.pos[ts, 0], road.pos[ts, 1], road.pos[ts, 2], road.fwd[ts, 0], road.fwd[ts, 1],
                      road.half_width[ts], road.surface[ts].astype(np.float64), flags,
                      road.dist[ts] - (0.0 if road.closed else start_s), road.bank[ts]], axis=1)
    pack.add_raw("track", track, "<f4", columns=["x", "y", "z", "fx", "fz", "half_width", "surface",
                                                 "flags", "dist", "bank"])
    sg = surf[::2, ::2]
    pack.add_raw("surface_grid", sg, "u1", origin=ter.origin, cell=ter.cell * 2, codes=list(TERRAIN_SURFACES))

    # start and checkpoints
    ncp = rs.get("checkpoints", 6)
    cps = []
    for k in range(1, ncp + 1):
        s = start_s + route * k / ncp
        ii = road_index(road, s % road.length if road.closed else s)
        cps.append({"index": k - 1, "s": round(float((route * k / ncp)), 2),
                    "pos": [round(float(v), 3) for v in road.pos[ii]],
                    "yaw": round(float(math.atan2(-road.fwd[ii, 0], -road.fwd[ii, 1])), 4),
                    "half_width": round(float(road.half_width[ii] + road.verge + 1.0), 2)})
    si = road_index(road, start_s)
    spawn_i = road_index(road, start_s - rs.get("grid_back", 12.0 if road.closed else 0.0))
    spawn = {"pos": [round(float(road.pos[spawn_i, 0]), 3), round(float(road.pos[spawn_i, 1] + 0.6), 3),
                     round(float(road.pos[spawn_i, 2]), 3)],
             "yaw": round(float(math.atan2(-road.fwd[spawn_i, 0], -road.fwd[spawn_i, 1])), 4)}
    arrival = None
    if arrival_s is not None:
        ai = road_index(road, arrival_s)
        arrival = {"pos": [round(float(v), 3) for v in road.pos[ai]],
                   "yaw": round(float(math.atan2(-road.fwd[ai, 0], -road.fwd[ai, 1])), 4),
                   "radius": float(rs.get("arrival_radius", 12.0))}
        print(f"[{map_id}] open road: lead-in {start_s:.0f} m, route {route:.0f} m, "
              f"run-out {road.length - arrival_s:.0f} m")

    out = {
        "id": map_id, "version": 1, "season": spec["season"], "atmosphere": spec["atmosphere"],
        "size": ter.size, "cell": ter.cell, "play_half": spec["play_half"],
        "bin": f"res://assets/maps/{map_id}/map.bin",
        "closed": road.closed,
        "road": {"length": round(route, 2), "start_s": round(float(start_s if road.closed else 0.0), 2),
                 "verge": road.verge, "surfaces": list(SURFACES), "bridges": bridge_info,
                 "start": {"pos": [round(float(v), 3) for v in road.pos[si]],
                           "yaw": round(float(math.atan2(-road.fwd[si, 0], -road.fwd[si, 1])), 4),
                           "half_width": round(float(road.half_width[si] + road.verge + 1.0), 2)}},
        "spawn": spawn,
        "checkpoints": cps,
        "water": water_info,
        "collision_boxes": boxes,
        "signs": sign_info,
        "corners": roadside.corners_json(road, corners, 0.0 if road.closed else start_s, corner_signs),
        "parked": parked,
        "materials": spec.get("materials", {}),
        "meshes": pack.meshes,
        "raw": pack.raw,
        "instances": placer.out,
    }
    if arrival is not None:
        out["arrival"] = arrival
    if garage_info is not None:
        out["garage"] = garage_info
    pack.save(os.path.join(out_dir, "map.bin"))
    with open(os.path.join(out_dir, "map.json"), "w") as f:
        json.dump(out, f, separators=(",", ":"))
    total = sum(len(v) for v in placer.out.values())
    print(f"[{map_id}] wrote {len(pack.meshes)} meshes, {len(pack.buf) / 1e6:.1f} MB bin, {total} instances, "
          f"{len(boxes)} boxes ({time.time() - t0:.1f}s)")
    preview(map_id, spec, ter, road, rgba, placer.out, cps, spawn, arrival)


def preview(map_id: str, spec: dict, ter, road, rgba, placed, cps, spawn, arrival) -> None:
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
    for lot in road.lots:
        o = lot_outline(lot, 0.0)
        ax, rt = lot.axis, np.array([-lot.axis[1], lot.axis[0]])
        dr.polygon([px(lot.center[0] + a * rt[0] + b * ax[0], lot.center[1] + a * rt[1] + b * ax[1]) for a, b in o],
                   fill=colors[lot.surface])
    wpx = max(2, int(2 * road.half_width.mean() / ter.size * S))
    for i in range(len(road.pos) if road.closed else len(road.pos) - 1):
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
    if arrival is not None:
        X, Y = px(arrival["pos"][0], arrival["pos"][2])
        R = arrival["radius"] / ter.size * S
        dr.ellipse([X - R, Y - R, X + R, Y + R], outline=(230, 60, 60), width=3)
    for k, cpi in enumerate(road.control_s):
        i = min(int(cpi), len(road.pos) - 1)
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
