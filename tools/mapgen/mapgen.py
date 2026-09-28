#!/usr/bin/env python3
"""Sakura Rally world compiler.

    uv run --with numpy --with pillow python tools/mapgen/mapgen.py

Reads the world spec (tools/mapgen/maps/world.py: the Hanami and Momiji region specs placed into
world coordinates and the branch road between them) and the props manifest
(assets/models/props/manifest.json), and writes:
  assets/maps/world/map.json   version 2: roads, routes, gates, season grid, instances ...
  assets/maps/world/map.bin    mesh and grid blobs (see lib/meshpack.py)
  docs/renders/map_world.png   top-down preview, and map_hanami / map_branch / map_momiji crops
scripts/world/map_world.gd assembles these into the playable world (docs/WORLD.md).
"""
from __future__ import annotations

import json
import math
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)

from lib import geom, junction, noise, roadside, seasons  # noqa: E402
from lib.corridor import SMASHABLE, WALLS, Corridor, enforce, format_survey, survey  # noqa: E402
from lib.garage import drop_kept_out, garage_layout, garage_lot, garage_pad, keep_out_circles  # noqa: E402
from lib.meshpack import MeshBuilder, MeshPack, rotation  # noqa: E402
from lib.road import (LOT_DROP, PROFILE, SURFACES, build_bridge, build_delineators,  # noqa: E402
                      build_guardrails, build_road, phys_surface, ribbon_indices, road_chunks,
                      road_index, road_vertices)
from lib.scatter import Placer  # noqa: E402
from lib.terrain import LOT_SKIRT, build_terrain, build_water, chunk_mesh, chunk_mesh_far, grid_normals  # noqa: E402

MAP_ID = "world"
TERRAIN_SURFACES = ("grass", "dirt", "sand", "gravel")
CHUNK_CELLS = 50        # terrain chunk: 50 x 50 cells (200 m at 4 m)
NEAR_END = 640.0        # m from the camera: fine terrain chunks hand over to coarse ones
FAR_STEP = 4            # coarse chunks keep every 4th grid vertex
OUT_STEP = 2            # chunks wholly beyond the rim top keep every 2nd vertex, no collider
FAR_SKIRT = 2.0         # m, skirt on every edge of a coarse chunk (no cracks against a finer one)
COLLIDE_EDGE = 800.0    # rim metric (lib/terrain.py): a chunk reaching inside this collides (rim top 790)
PLAY_EDGE = 600.0       # rim metric of the play area (roadside: a miss that leaves it is bad)
TRACK_STEP = 2          # m between route track samples
BACKDROP_TUCK = 15.0    # m, the backdrop's inner ring lies this far under the terrain


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


def yaw_of(f2) -> float:
    """Godot yaw of a horizontal heading (x, z): -Z forward turns to (-sin yaw, -cos yaw)."""
    return float(math.atan2(-f2[0], -f2[1]))


def r3(v) -> list[float]:
    return [round(float(a), 3) for a in v]


def load_manifest() -> dict:
    path = os.environ.get("SR_PROPS_MANIFEST",
                          os.path.join(REPO, "assets", "models", "props", "manifest.json"))
    if not os.path.exists(path):
        print("WARN no props manifest; scatter uses fallback footprints")
        return {}
    with open(path) as f:
        return {p["name"]: p for p in json.load(f)["props"]}


# ---------------------------------------------------------------------- colour

def _tree_weights(ter, placed: dict, manifest: dict) -> tuple[np.ndarray, np.ndarray]:
    """Forest floor under trees, and petals / leaf litter under blossom and maples."""
    tree_w = np.zeros(ter.H.shape)
    petal_w = np.zeros(ter.H.shape)
    cell = ter.cell
    for name, inst in placed.items():
        m = manifest.get(name, {})
        if m.get("category") != "tree":
            continue
        blossom = name.startswith("sakura")
        maple = name.startswith("maple") and name != "maple_green" or name.startswith("persimmon")
        rad = max(3.0, float(m.get("footprint_radius", 3.0)) * 1.4)
        k = int(math.ceil(rad / cell)) + 1
        for (x, y, z, yaw, sc) in inst:
            ci = int(round((x - ter.ox) / cell))
            cj = int(round((z - ter.oz) / cell))
            i0, i1 = max(0, ci - k), min(ter.nx, ci + k + 1)
            j0, j1 = max(0, cj - k), min(ter.nz, cj + k + 1)
            if i0 >= i1 or j0 >= j1:
                continue
            dx = ter.X[j0:j1, i0:i1] - x
            dz = ter.Z[j0:j1, i0:i1] - z
            w = np.exp(-(dx * dx + dz * dz) / (rad * sc) ** 2)
            tree_w[j0:j1, i0:i1] += w
            if blossom or maple:
                petal_w[j0:j1, i0:i1] += w * (1.6 if blossom else 1.3)
    return np.clip(tree_w, 0.0, 1.0), petal_w


def _paint_region(spec: dict, ter, tree_w, petal_w, slope, near, verge, loose, shore, mt):
    """One region's palette over the whole grid: (rgb, petal alpha, rock weight)."""
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
    col = mix(col, pal["forest_floor"], tree_w * 0.75)
    petals = np.clip(petal_w, 0.0, 1.0) * geom.smoothstep(0.2, 0.7, n2 + 0.25)
    if "petal" in pal:
        col = mix(col, pal["petal"], petals * 0.7)
    if "litter" in pal:
        lit = pal["litter"]
        lc = mix(lit[0], lit[1], geom.smoothstep(0.3, 0.7, n1))
        lc = mix(lc, lit[2], geom.smoothstep(0.55, 0.8, n2))
        col = mix(col, lc, petals * 0.85)
    if "petal" not in pal and "litter" not in pal:
        petals = np.zeros(H.shape)

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
            e = k / len(cc)
            ccol = mix(ccol, cc[k], geom.smoothstep(e - 0.03, e + 0.03, nc + nb))
        mask = noise.fbm(X, Z, can.get("mask_scale", 160.0), 3, 2.0, 0.5, seed + 95)
        canopy_w = geom.smoothstep(can.get("near", 50.0), can.get("far", 120.0), ter.road_dist)
        canopy_w *= geom.smoothstep(can.get("threshold", -0.25) - 0.1, can.get("threshold", -0.25) + 0.1, mask)
        canopy_w *= can.get("amount", 0.9)
        canopy_w *= geom.smoothstep(12.0, 40.0, np.minimum(ter.lake_sd, ter.river_dist))
        col = mix(col, ccol, canopy_w)

    # terraces read as fields; "paddies" terraces alternate shades step by step and draw
    # the grassy bunds on the risers, so the stepped rice fields read from the road
    paddy = np.zeros(H.shape, dtype=bool)
    for terr in spec["terrain"].get("terraces", []):
        inside = geom.point_in_polygon(X, Z, np.array(terr["poly"], dtype=np.float64))
        fn = noise.fbm(X, Z, 20.0, 2, 2.0, 0.5, seed + 55) * 0.5 + 0.5
        fc = mix(pal["field"], pal.get("field2", pal["field"]), geom.smoothstep(0.4, 0.6, fn))
        if terr.get("paddies"):
            level = np.floor(H / terr["step"]).astype(np.int64)
            fc = mix(fc, pal.get("field2", pal["field"]), (level % 2 == 1) * 0.85)
            fc = mix(fc, pal.get("bund", pal["forest_floor"]), geom.smoothstep(0.03, 0.09, slope))
            paddy |= inside
        col = np.where(inside[..., None], mix(col, fc, 0.9), col)
        canopy_w = np.where(inside, 0.0, canopy_w)

    rock = geom.smoothstep(0.22, 0.4, slope + noise.fbm(X, Z, 24.0, 2, 2.0, 0.5, seed + 61) * 0.08)
    rock[paddy] = 0.0
    if can:  # forest clings to all but the steepest cliffs
        rock = rock * (1.0 - canopy_w * geom.smoothstep(0.55, 0.3, slope) * can.get("rock_cover", 0.8))
    rc = mix(pal["rock"], pal["rock_dark"], geom.smoothstep(0.4, 0.7, n2))
    col = mix(col, rc, rock)

    # road edges: gravel/dirt stages get a narrow worn dirt verge; tarmac keeps grass to the
    # edge with the soft, lighter mown strip of a painted background
    col = mix(col, pal["dirt"], verge * 0.8)
    col = mix(col, pal.get("verge_grass", pal["grass_dry"]), near * (1.0 - loose) * 0.55)
    col = mix(col, pal["sand"], shore * 0.9)
    # the rim gets the mountain tint
    col = mix(col, pal["mountain"], mt * 0.6)
    jitter = noise.fbm(X, Z, 6.0, 1, 2.0, 0.5, seed + 81) * 0.05
    col = col * (1.0 + jitter[..., None])
    alpha = petals * (1.0 - rock) * (1.0 - verge * 0.3)
    return col, alpha, rock


def paint_terrain(world: dict, ter, roads: dict, placed: dict, manifest: dict) -> tuple[np.ndarray, np.ndarray]:
    """Vertex colours (rgb + petal alpha) of the world grid: each region's palette blended by
    its season weight (the same weights as the season grid), and the physics surface grid."""
    seed = world["seed"]
    X, Z, H = ter.X, ter.Z, ter.H
    tree_w, petal_w = _tree_weights(ter, placed, manifest)
    slope = 1.0 - ter.normal_y()
    # the nearest road's attributes per cell
    hw = np.zeros(H.shape)
    vg = np.zeros(H.shape)
    carve = np.zeros(H.shape)
    loose = np.zeros(H.shape)
    for k, road in enumerate(roads.values()):
        m = (ter.road_id == k) & (ter.road_seg >= 0)
        si = ter.road_seg[m]
        hw[m] = road.half_width[si]
        vg[m] = road.verge
        carve[m] = road.carve[si]
        loose[m] = np.isin(road.surface[si], [SURFACES.index("gravel"), SURFACES.index("dirt")])
    edge_noise = noise.fbm(X, Z, 9.0, 2, 2.0, 0.5, seed + 71) * 1.2
    near = (1.0 - geom.smoothstep(hw + vg + 0.5, hw + vg + 2.5, ter.road_dist + edge_noise)) * carve
    verge = near * loose
    rw = ter.water.river_width / 2.0
    shore = np.maximum(1.0 - geom.smoothstep(2.0, 9.0, ter.lake_sd + edge_noise),
                       1.0 - geom.smoothstep(rw + 1.0, rw + 5.0, ter.river_dist + edge_noise))
    rim = world["rim"]
    mt = geom.smoothstep(rim["start"], rim["end"], ter.edge)
    col = np.zeros(H.shape + (3,))
    alpha = np.zeros(H.shape)
    rock = np.zeros(H.shape)
    for reg in world["regions"]:
        w = ter.weights[..., seasons.SEASONS.index(reg["season"])]
        c, a, rk = _paint_region(reg["spec"], ter, tree_w, petal_w, slope, near, verge, loose, shore, mt)
        col += w[..., None] * c
        alpha += w * a
        rock += w * rk
    rgba = np.concatenate([np.clip(col, 0, 1), np.clip(alpha, 0, 1)[..., None]], axis=2)
    surf = np.zeros(H.shape, dtype=np.uint8)
    surf[verge > 0.5] = TERRAIN_SURFACES.index("dirt")
    surf[shore > 0.5] = TERRAIN_SURFACES.index("sand")
    surf[rock > 0.6] = TERRAIN_SURFACES.index("gravel")
    return rgba, surf


# ---------------------------------------------------------------------- meshes

def emit_terrain(pack: MeshPack, ter, rgba: np.ndarray) -> dict:
    """Terrain chunks. Inside the rim a fine chunk (collider, seen to NEAR_END) and a coarse
    copy with skirts (seen beyond); wholly beyond the rim top one medium chunk, no collider."""
    normals = grid_normals(ter)
    cs = CHUNK_CELLS
    ncx, ncz = ter.nx - 1, ter.nz - 1
    stats = {"near": [0, 0], "far": [0, 0], "out": [0, 0]}

    def add(name, mesh, kind, **kw):
        pos, col, nrm, idx = mesh
        pack.add(name, pos, idx, col=col, nrm=nrm, material="terrain", **kw)
        stats[kind][0] += 1
        stats[kind][1] += len(idx) // 3

    for cj in range(0, ncz, cs):
        for ci in range(0, ncx, cs):
            i1, j1 = min(ncx, ci + cs), min(ncz, cj + cs)
            name = f"terrain_{ci // cs}_{cj // cs}"
            if float(ter.edge[cj:j1 + 1, ci:i1 + 1].min()) >= COLLIDE_EDGE:
                add(name, chunk_mesh_far(ter, ci, i1, cj, j1, rgba, normals, OUT_STEP, FAR_SKIRT), "out")
                continue
            add(name, chunk_mesh(ter, ci, i1, cj, j1, rgba, normals), "near", collide="trimesh", surface="grass",
                visibility=[0.0, NEAR_END])
            add(name + "_far", chunk_mesh_far(ter, ci, i1, cj, j1, rgba, normals, FAR_STEP, FAR_SKIRT), "far",
                visibility=[NEAR_END, 0.0])
    return stats


def _ribbon_quads(n_rows: int, keep: np.ndarray) -> np.ndarray:
    """ribbon_indices for an open strip, only the quads where keep[k, m] (rows k, k+1; columns
    m, m+1)."""
    k, m = np.nonzero(keep)
    a = k * PROFILE + m
    b = a + 1
    c = (k + 1) * PROFILE + m + 1
    d = (k + 1) * PROFILE + m
    return np.stack([d, c, b, d, b, a], axis=1).ravel()


def _side_quads(side: int) -> list[int]:
    """Profile quad columns of the shoulder, verge and skirt on a side."""
    return [7, 8, 9] if side > 0 else [0, 1, 2]


def emit_road(pack: MeshPack, rid: str, road, verts, lat, ter, rgba: np.ndarray, built: np.ndarray,
              skips: list, fade: np.ndarray | None) -> int:
    """The road ribbon in chunks, only where `built`; `skips` [(side, rows)] leave out the
    shoulder, verge and skirt quads on a side (junction mouths); `fade` (0..1 per sample) fades
    the lane markings and shoulders (negative uv2.y) into a junction apron."""
    n = len(road.pos)
    u = lat / road.half_width[:, None]
    v = np.repeat(road.dist[:, None], PROFILE, axis=1)
    vx = verts[..., 0].ravel()
    vz = verts[..., 2].ravel()
    col = np.stack([ter.sample(rgba[..., k], vx, vz) for k in range(4)], axis=1).reshape(n, PROFILE, 4)
    # surface weights for the shader: uv2 = (gravel_or_dirt, wood); tarmac = neither
    sid = road.surface
    grav = np.isin(sid, [SURFACES.index("gravel"), SURFACES.index("dirt")]).astype(np.float64)
    grav = np.clip(geom.smooth(grav, 4.0, closed=road.closed), 0, 1)
    wood = np.where(sid == SURFACES.index("wood"), 1.0, 0.0)
    if fade is not None:
        wood = wood - fade
    count = 0
    for (a, b) in road_chunks(road):
        # each chunk shares its last row with the next one (around the seam on a loop)
        rows = [r % n for r in range(a, b + 1)] if road.closed else list(range(a, min(b + 1, n)))
        rows = [r for r in rows if built[r]]
        if len(rows) < 2:
            continue
        keep = np.ones((len(rows) - 1, PROFILE - 1), dtype=bool)
        for side, skip in skips:
            for q, r in enumerate(rows[:-1]):
                if r in skip:
                    keep[q, _side_quads(side)] = False
        P = verts[rows].reshape(-1, 3)
        U = np.stack([u[rows].ravel(), v[rows].ravel()], axis=1)
        C = col[rows].reshape(-1, 4)
        U2 = np.stack([np.repeat(grav[rows], PROFILE), np.repeat(wood[rows], PROFILE)], axis=1)
        surf = phys_surface(int(np.bincount(road.surface[rows]).argmax()))
        # the shader turns uv.x back into metres with the mesh's half width (one width per road)
        d = pack.add(f"road_{rid}_{rows[0]}", P, _ribbon_quads(len(rows), keep), col=C, uv=U, material="road",
                     collide="trimesh", surface=surf, half_width=round(float(road.half_width[rows].mean()), 3))
        raw = pack.add_raw(f"road_{rid}_{rows[0]}_uv2", U2, "<f4")
        d["uv2_raw"] = raw["name"]
        count += 1
    return count


def emit_apron(pack: MeshPack, J, branch, loop, bverts, blat, lverts, ter, rgba: np.ndarray) -> tuple:
    """A junction mouth (lib/junction.apron) as road: no markings or shoulders (uv2.y = -1, like
    the branch ribbon's faded first rows), the far side's verge from the branch's profile."""
    pos, idx, _verge = junction.apron(branch, loop, J, bverts, lverts)
    rows = list(range(J.fork_i, J.clear_i + J.step, J.step))
    far_cols = junction._side_cols(-J.near)
    U = np.zeros((len(rows), 8, 2))
    for r, i in enumerate(rows):
        U[r, :5, 0] = np.linspace(J.near, -J.near, 5)
        U[r, 5:, 0] = blat[i, list(far_cols[1:])] / branch.half_width[i]
        U[r, :, 1] = branch.dist[i]
    col = np.stack([ter.sample(rgba[..., k], pos[:, 0], pos[:, 2]) for k in range(4)], axis=1)
    grav = 1.0 if branch.surface[J.clear_i] != SURFACES.index("tarmac") else 0.0
    U2 = np.stack([np.full(len(pos), grav), np.full(len(pos), -1.0)], axis=1)
    d = pack.add(f"apron_{J.loop_id}", pos, idx, col=col, uv=U.reshape(-1, 2), material="road",
                 collide="trimesh", surface="gravel" if grav else "tarmac",
                 half_width=round(float(branch.half_width[J.clear_i]), 3))
    raw = pack.add_raw(f"apron_{J.loop_id}_uv2", U2, "<f4")
    d["uv2_raw"] = raw["name"]
    return pos, idx


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


def emit_lots(pack: MeshPack, lots: list, ter, rgba: np.ndarray) -> None:
    """Paved lots: concentric rings from the centre to the edge, then the verge and a skirt
    that tucks under the terrain, like the road ribbon's cross-section. uv = lot metres,
    uv2 = (gravel weight, verge weight) for the road shader's lot mode."""
    for lot in lots:
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


def emit_water(pack: MeshPack, ter) -> dict:
    """The lake sheet, every river's ribbon, waterfalls and plunge pools."""
    info = {}
    w = ter.water
    if w.lake_poly is not None:
        lvl = w.lake_level
        step = 8.0
        x0, x1 = w.lake_poly[:, 0].min() - 20, w.lake_poly[:, 0].max() + 20
        z0, z1 = w.lake_poly[:, 1].min() - 20, w.lake_poly[:, 1].max() + 20
        GX, GZ = np.meshgrid(np.arange(x0, x1 + step, step), np.arange(z0, z1 + step, step))
        keep_v = ter.sample(ter.lake_sd, GX, GZ) < 14.0
        nzv, nxv = GX.shape
        pos = np.stack([GX.ravel(), np.full(GX.size, lvl), GZ.ravel()], axis=1)
        depth = np.clip((lvl - ter.height_at(GX, GZ)) / 4.0, 0.0, 1.0).ravel()
        col = np.stack([depth, depth, depth, np.ones_like(depth)], axis=1)
        cell_keep = keep_v[:-1, :-1] | keep_v[:-1, 1:] | keep_v[1:, :-1] | keep_v[1:, 1:]
        j, i = np.nonzero(cell_keep)
        a = j * nxv + i
        b, c, d = a + 1, a + nxv + 1, a + nxv
        idx = np.stack([a, b, c, a, c, d], axis=1).ravel()
        pack.add("lake", pos, idx, col=col, uv=pos[:, [0, 2]] * 0.02, material="water",
                 nrm=np.tile([0.0, 1.0, 0.0], (len(pos), 1)))
        info["lake"] = {"level": lvl, "poly": [[round(float(a), 1), round(float(b), 1)] for a, b in w.lake_poly[::2]]}
    rivers = []
    n_fall = 0
    for rv in w.rivers:
        rp = rv.pts
        fwd, right, _ = geom.frames(rp, closed=False)
        half = rv.width / 2.0 + 1.2
        cols = 5
        lat = np.linspace(-half, half, cols)
        P = np.empty((len(rp), cols, 3))
        P[..., 0] = rp[:, 0:1] + right[:, 0:1] * lat
        P[..., 2] = rp[:, 2:3] + right[:, 1:2] * lat
        P[..., 1] = rp[:, 1:2]
        U = np.stack([np.broadcast_to(lat / half, (len(rp), cols)),
                      np.broadcast_to(rv.s[:, None], (len(rp), cols))], axis=2)
        # depth tint: centre deep, edges shallow
        dcol = np.broadcast_to((1.0 - np.abs(lat / half)) ** 0.7, (len(rp), cols))
        C = np.stack([dcol, dcol, dcol, np.ones_like(dcol)], axis=2)
        step = 120
        # the source is where the channel leaves the mountainside (lib/terrain.py fades the carve
        # out into the rim): rows still buried in the slope are not emitted
        open_ = ter.height_at(rp[:, 0], rp[:, 2]) < rp[:, 1] + 0.5
        k0 = max(0, int(np.argmax(open_)) - 2) if open_.any() else len(rp) - 1
        assert all(k >= k0 for k, _d, _p in rv.falls), f"river {rv.id}: a waterfall is buried in the rim"
        for a in range(k0, len(rp) - 1, step):
            b = min(len(rp) - 1, a + step)
            rows = np.arange(a, b + 1)
            pack.add(f"river_{rv.id}_{a}", P[rows].reshape(-1, 3), ribbon_indices(len(rows), cols, closed=False),
                     col=C[rows].reshape(-1, 4), uv=U[rows].reshape(-1, 2), material="water_river",
                     nrm=np.tile([0.0, 1.0, 0.0], (len(rows) * cols, 1)))
        rivers.append({"id": rv.id, "width": rv.width,
                       "points": [[round(float(p[0]), 2), round(float(p[1]), 2), round(float(p[2]), 2)] for p in rp[k0::2]]})
        print(f"[world] river {rv.id}: source at ({rp[k0, 0]:.0f}, {rp[k0, 2]:.0f}), {k0} rows buried in the rim")
        for (k, drop, _pool) in rv.falls:
            emit_fall(pack, f"waterfall_{n_fall}", rv, k, drop, fwd, right)
            n_fall += 1
    info["rivers"] = rivers
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
    return info


def emit_fall(pack: MeshPack, name: str, rv, k: int, drop: float, fwd: np.ndarray, right: np.ndarray) -> None:
    """A waterfall curtain: a bowed sheet from the lip down to the pool, streaking in the river
    shader."""
    rp = rv.pts
    top = rp[k].copy()
    bot = rp[min(k + 1, len(rp) - 1)]
    half = rv.width / 2.0 + 0.8
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
    pack.add(name, P.reshape(-1, 3), ribbon_indices(rows, cols, closed=False),
             col=C.reshape(-1, 4), uv=U.reshape(-1, 2), material="water_river", nrm=nrm)


def emit_backdrop(pack: MeshPack, world: dict, ter) -> None:
    """Faceted distant mountains in rings around the world rectangle (rounded like the rim),
    each region's colour and shape blended by the season weights around it. The inner ring lies
    inside the rectangle, BACKDROP_TUCK m under the terrain, so the backdrop runs on beneath the
    terrain's edge: from any height there is no gap between the two."""
    x0, z0, x1, z1 = world["bounds"]
    cx, cz, hx, hz = (x0 + x1) / 2, (z0 + z1) / 2, (x1 - x0) / 2, (z1 - z0) / 2
    seed = world["seed"] + 500
    off = np.array([-40.0, 350.0, 700.0, 1150.0, 1700.0, 2400.0, 3300.0, 4400.0])
    seg = 240
    ang = np.linspace(0, 2 * np.pi, seg, endpoint=False)
    A, O = np.meshgrid(ang, off)
    ca, sa = np.cos(A), np.sin(A)
    X = cx + np.sign(ca) * np.abs(ca) ** 0.5 * (hx + O)
    Z = cz + np.sign(sa) * np.abs(sa) ** 0.5 * (hz + O)
    jx = noise.fbm(X, Z, 90.0, 1, 2.0, 0.5, seed) * 60.0
    jz = noise.fbm(X, Z, 90.0, 1, 2.0, 0.5, seed + 1) * 60.0
    jx[0] = jz[0] = 0.0  # the inner ring stays inside the rectangle
    X += jx
    Z += jz
    W = seasons.weights(X, Z, world["seasons"], world["seed"])
    bds = {reg["season"]: reg["spec"]["backdrop"] for reg in world["regions"]}

    def blend(key, default):
        return sum(W[..., k] * bds[s].get(key, default) for k, s in enumerate(seasons.SEASONS))

    rid = noise.ridged(ca * 900 + O * 0.3, sa * 900 - O * 0.2, blend("scale", 420.0), 5, seed)
    big = noise.fbm(ca * 1200, sa * 1200, 900.0, 3, 2.0, 0.5, seed + 3) * 0.5 + 0.5
    rise = geom.smoothstep(100.0, off[2], O)
    fall = 1.0 - geom.smoothstep(off[-3], off[-1], O)
    Hh = blend("base", 120.0) + (blend("height", 520.0) * rid * (0.45 + 0.9 * big)) * rise
    Hh = Hh * (0.35 + 0.65 * fall)
    Hh[0] = np.minimum(blend("inner", 160.0)[0], ter.height_at(X[0], Z[0]) - BACKDROP_TUCK)
    pos = np.stack([X.ravel(), Hh.ravel(), Z.ravel()], axis=1)
    tfar = geom.smoothstep(off[1], off[-2], O)
    col = np.zeros(X.shape + (3,))
    for k, s in enumerate(seasons.SEASONS):
        bd = bds[s]
        c = mix(lin(bd["color"]), lin(bd.get("color_far", bd["color"])), tfar)
        if "snow_color" in bd:
            c = mix(c, lin(bd["snow_color"]), geom.smoothstep(bd["snow"], bd["snow"] + 80.0, Hh))
        col += W[..., k:k + 1] * c
    col = np.concatenate([col.reshape(-1, 3), np.ones((pos.shape[0], 1))], axis=1)
    idx = []
    for r in range(len(off) - 1):
        for s in range(seg):
            s2 = (s + 1) % seg
            a, b = r * seg + s, r * seg + s2
            c, d = (r + 1) * seg + s2, (r + 1) * seg + s
            # ring r is inner; outward is +r. Clockwise seen from above.
            idx.extend([a, d, c, a, c, b])
    # unshare for flat facets
    idx = np.array(idx)
    p = pos[idx]
    tri = p.reshape(-1, 3, 3)
    fn = np.cross(tri[:, 2] - tri[:, 0], tri[:, 1] - tri[:, 0])
    fn /= np.maximum(np.linalg.norm(fn, axis=1, keepdims=True), 1e-12)
    pack.add("backdrop", p, np.arange(len(p)), col=col[idx], nrm=np.repeat(fn, 3, axis=0), material="backdrop")


# ---------------------------------------------------------------------- signs and parked cars

def _feature_frame(f: dict, placer: Placer) -> tuple[float, float, float, float]:
    """(x, ground y, z, yaw) of a road-relative item. face "approach": the front (+Z) looks
    back down the road at the approaching driver; "road": the front looks at the road."""
    x, z, i = placer.road_point(f)
    face = f.get("face", "approach")
    if face == "approach":
        yaw = yaw_of(placer.road.fwd[i])
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


# ---------------------------------------------------------------------- routes

def _pose(road, i: int, lift: float = 0.0) -> dict:
    p = road.pos[i]
    return {"pos": r3((p[0], p[1] + lift, p[2])), "yaw": round(yaw_of(road.fwd[i]), 4)}


def _bridges(style: np.ndarray, dist: np.ndarray) -> list[dict]:
    """[{from, to, style}] runs of a per-sample bridge style along a track."""
    out = []
    i, n = 0, len(style)
    while i < n:
        if style[i] == "":
            i += 1
            continue
        j = i
        while j + 1 < n and style[j + 1] == style[i]:
            j += 1
        out.append({"from": round(float(dist[i]), 2), "to": round(float(dist[j]), 2), "style": style[i]})
        i = j + 1
    return out


def _track(pieces: list[tuple], dist: np.ndarray | None = None) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Track samples (TRACK_STEP m) along pieces [(road, sample indices)]: (rows (m, 10) in the
    v1 columns, their bridge styles, per-piece-sample distance). A closed lap passes `dist` = road.dist; an
    open track measures from its first sample and keeps its last one."""
    cols = []
    for road, ix in pieces:
        ix = np.asarray(ix)
        flags = (road.bridge[ix] != "").astype(np.float64) + 2.0 * road.ford[ix]
        cols.append((road.pos[ix], road.fwd[ix], road.half_width[ix], road.surface[ix].astype(np.float64), flags,
                     road.bank[ix], road.bridge[ix]))
    pos = np.concatenate([c[0] for c in cols])
    fwd = np.concatenate([c[1] for c in cols])
    hw = np.concatenate([c[2] for c in cols])
    surf = np.concatenate([c[3] for c in cols])
    flags = np.concatenate([c[4] for c in cols])
    bank = np.concatenate([c[5] for c in cols])
    style = np.concatenate([c[6] for c in cols])
    ts = np.arange(0, len(pos), TRACK_STEP)
    if dist is None:
        dist = np.concatenate([[0.0], np.cumsum(np.hypot(np.diff(pos[:, 0]), np.diff(pos[:, 2])))])
        if ts[-1] != len(pos) - 1:
            ts = np.append(ts, len(pos) - 1)
    rows = np.stack([pos[ts, 0], pos[ts, 1], pos[ts, 2], fwd[ts, 0], fwd[ts, 1], hw[ts], surf[ts], flags[ts],
                     dist[ts], bank[ts]], axis=1)
    return rows, style[ts], dist


def _route_json(track: str, closed: bool, length: float, start_s: float, verge: float, bridges: list,
                start: dict, half_width: float, spawn: dict, season: str, atmosphere: str, **extra) -> dict:
    return {"track": track, "closed": closed, "season": season, "atmosphere": atmosphere,
            "road": {"length": round(float(length), 2), "start_s": round(float(start_s), 2), "verge": verge,
                     "surfaces": list(SURFACES), "bridges": bridges,
                     "start": dict(start, half_width=round(float(half_width), 2))},
            "spawn": spawn, **extra}


# ---------------------------------------------------------------------- main build

def build() -> None:
    t0 = time.time()
    timings = {}

    def lap(key: str) -> None:
        timings[key] = round(time.time() - t0 - sum(timings.values()), 2)

    from maps import world as world_spec
    world = world_spec.WORLD
    manifest = load_manifest()
    out_dir = os.path.join(REPO, "assets", "maps", MAP_ID)
    os.makedirs(out_dir, exist_ok=True)
    regions = world["regions"]
    region_of_road = {reg["road"]: reg for reg in regions}
    lap("spec")

    # ------------------------------------------------------------------ roads and junctions
    road_specs = dict(world["roads"])
    garage = region_of_road["hanami"]["spec"].get("garage")
    if garage is not None:
        hs = road_specs["hanami"]
        road_specs["hanami"] = dict(hs, lots=list(hs.get("lots", [])) + [garage_lot(garage)])
    roads = {rid: build_road(s) for rid, s in road_specs.items()}
    branch = roads["branch"]
    J = [junction.find(branch, roads[f["road"]], f["cp"], f["end"], f["road"]) for f in road_specs["branch"]["forks"]]
    for j in J:
        junction.level(branch, roads[j.loop_id], j)
    built = {rid: np.ones(len(r.pos), dtype=bool) for rid, r in roads.items()}
    built["branch"] = junction.built_mask(branch, J)
    for rid, road in roads.items():
        grade = np.abs(np.diff(road.pos[:, 1])) / np.maximum(np.diff(road.dist), 1e-6)
        print(f"[world] road {rid}: {road.length:.0f} m {'loop' if road.closed else 'open'}, "
              f"y {road.pos[:, 1].min():.1f}..{road.pos[:, 1].max():.1f}, max grade {grade.max() * 100:.1f}%, "
              f"min radius {1.0 / max(np.abs(road.curv).max(), 1e-6):.1f} m")
    for j in J:
        print(f"[world] junction {j.loop_id} ({j.end}): fork at branch s {branch.dist[j.fork_i]:.0f}, "
              f"ribbon from s {branch.dist[j.clear_i]:.0f}, loop s {roads[j.loop_id].dist[j.loop_fork]:.0f}, "
              f"branch on the {'right' if j.side_l > 0 else 'left'} of the loop")
    verts = {rid: road_vertices(r) for rid, r in roads.items()}
    aprons = [junction.apron(branch, roads[j.loop_id], j, verts["branch"][0], verts[j.loop_id][0]) for j in J]
    lap("roads")

    # ------------------------------------------------------------------ terrain
    pads = [(pad.get("road", reg["road"]), pad) for reg in regions for pad in reg["spec"]["terrain"].get("pads", [])]
    if garage is not None:
        pads.append(("hanami", garage_pad(garage)))
    water = build_water(world)
    ter = build_terrain(world, roads, water, built, pads, [(p, i) for p, i, _ in aprons])
    garage_info = garage_layout(garage, roads["hanami"]) if garage is not None else None
    for rid, road in roads.items():
        wr = ter.sample(ter.weights[..., 0], road.pos[:, 0], road.pos[:, 2])
        wa = ter.sample(ter.weights[..., 2], road.pos[:, 0], road.pos[:, 2])
        print(f"[world] seasons on {rid}: spring {wr.min():.2f}..{wr.max():.2f}, autumn {wa.min():.2f}..{wa.max():.2f}")
    wp = world_spec.WP
    print("[world] seasons along the branch (spring/summer/autumn): " + ", ".join(
        f"{name} " + "/".join(f"{v:.1f}" for v in ter.weights[int(round((branch.pos[i, 2] - ter.oz) / ter.cell)),
                                                               int(round((branch.pos[i, 0] - ter.ox) / ter.cell))])
        for name, i in ((k, road_index(branch, branch.control_s[wp[k]])) for k in
                        ("sakura_1", "sakura_4", "orchard", "terrace_1", "farm", "village_in", "shrine_gate",
                         "village_out", "forest_edge", "maples_1", "tc"))))
    print(f"[world] terrain {ter.nx}x{ter.nz} ({ter.nx * ter.nz} vertices, cell {ter.cell} m), "
          f"h {ter.H.min():.1f}..{ter.H.max():.1f}")
    lap("terrain")

    # ------------------------------------------------------------------ routes
    stage = {}
    for rid in ("hanami", "momiji"):
        road, rs = roads[rid], road_specs[rid]
        start_s = float(road.control_s[rs["start_cp"]] + rs.get("start_offset", 0.0)) % road.length
        ncp = rs.get("checkpoints", 6)
        stage[rid] = {
            "start_s": start_s,
            "cp_abs": [(start_s + road.length * k / ncp) % road.length for k in range(1, ncp + 1)],
            "stop_i": road_index(road, (start_s + world["finish_stop"]) % road.length),
            "spawn_i": road_index(road, (start_s - rs.get("grid_back", 12.0)) % road.length),
            "start_i": road_index(road, start_s),
        }
    h, m = roads["hanami"], roads["momiji"]
    j0, j1 = J
    nh, nm = len(h.pos), len(m.pos)
    i_stop = stage["hanami"]["stop_i"]
    i_spawn = stage["momiji"]["spawn_i"]
    liaison_pieces = [
        (h, [(i_stop + k) % nh for k in range((j0.loop_fork - i_stop) % nh)]),
        (branch, list(range(j0.fork_i, j1.fork_i + 1))),
        (m, [(j1.loop_fork + 1 + k) % nm for k in range((i_spawn - j1.loop_fork - 1) % nm + 1)]),
    ]
    lia_rows, lia_style, lia_dist = _track(liaison_pieces)
    n1 = len(liaison_pieces[0][1])

    def liaison_s(bi: int) -> float:
        """Liaison distance of branch sample bi."""
        return float(lia_dist[n1 + bi - j0.fork_i])

    gates = []
    for g in world["gates"]:
        j = J[g["fork"]]
        gi = j.clear_i + j.step * int(g["offset"])
        gates.append({"id": g["id"], "route": "liaison", "s": round(liaison_s(gi), 2),
                      "pos": r3(branch.pos[gi]), "yaw": round(yaw_of(branch.fwd[gi]), 4),
                      "width": round(float(2.0 * (branch.half_width[gi] + branch.verge)), 2), "branch_i": gi})
    fs = stage["hanami"]["stop_i"]
    gate_ahead = gates[0]["s"]
    print(f"[world] liaison {lia_dist[-1]:.0f} m (Hanami loop {lia_dist[n1 - 1]:.0f} m, branch "
          f"{branch.dist[j1.fork_i] - branch.dist[j0.fork_i]:.0f} m, Momiji loop "
          f"{lia_dist[-1] - liaison_s(j1.fork_i):.0f} m); hanami finish_stop {h.dist[fs] - stage['hanami']['start_s']:.0f} m "
          f"past the line, gate {gate_ahead:.0f} m ahead of it")
    lap("routes")

    # ------------------------------------------------------------------ corridor and roadside
    cors = [Corridor(roads[r], stage[r]["cp_abs"]) for r in ("hanami", "momiji")]
    cors.append(Corridor(branch, [float(branch.dist[g["branch_i"]]) for g in gates]))
    cor = Corridor.union(cors)
    all_lots = [lot for r in roads.values() for lot in r.lots]
    ground = roadside.Ground.from_terrain(ter, all_lots, LOT_DROP)

    def in_play(x, z):
        return ter.sample(ter.edge, x, z) <= PLAY_EDGE

    keep = {rid: np.zeros((len(r.pos), 2), dtype=bool) for rid, r in roads.items()}
    for j in J:
        junction.keep_clear(roads[j.loop_id], branch, j, keep[j.loop_id], keep["branch"])
    keep["branch"][~built["branch"]] = True
    corners, runs = {}, {}
    for rid, road in roads.items():
        opts = road_specs[rid].get("roadside")
        corners[rid] = roadside.find_corners(road, opts)
        runs[rid] = roadside.rail_runs(road, ground, corners[rid], in_play, opts, keep[rid])
        print(f"[world] roadside {rid}: {roadside.summary(corners[rid], runs[rid], road)}")
    lap("roadside")

    # ------------------------------------------------------------------ placement
    placer = Placer(ter, roads["hanami"], manifest, "spring", world["seed"] + 7, PLAY_EDGE)
    placer.lots = all_lots
    if garage_info is not None:
        for x, z, r in keep_out_circles(garage_info):
            placer.occ.add(x, z, r)
    rp = {}
    for reg in regions:
        road = roads[reg["road"]]
        p = placer.for_road(road, reg["season"], ter.weights[..., seasons.SEASONS.index(reg["season"])])
        if reg["road"] in stage:
            p.start_s = stage[reg["road"]]["start_s"]
        rp[reg["id"]] = p
    if garage is not None:
        rp["hanami"].features(garage.get("dressing", []))
    signs, parked = [], []
    for reg in regions:
        rp[reg["id"]].features(reg["spec"].get("features", []))
    for reg in regions:
        signs += place_signs(reg["spec"].get("signs", []), rp[reg["id"]], cor)
        parked += place_parked(reg["spec"].get("parked", []), rp[reg["id"]])
    sign_res = {}
    for rid, road in roads.items():
        sign_res[rid] = roadside.place_corner_signs(road, ground, corners[rid], runs[rid],
                                                    rp[region_of_road[rid]["id"]], road_specs[rid].get("roadside"),
                                                    keep[rid])
        res = sign_res[rid]
        print(f"[world] corner signs {rid} {dict(sorted(res.placed.items()))}; warnings visible from "
              + ", ".join("-" if w is None else "s" if w == "series" else f"{w:.0f}" for w in res.warnings) + " m")
    authored = {k: len(v) for k, v in placer.out.items()}
    lap("features")
    counts = {}
    for reg in regions:
        for r in reg["spec"].get("scatter", []):
            counts[f"{reg['id']}.{r.get('name', r['props'][0])}"] = rp[reg["id"]].rule(r)
    print(f"[world] scatter {counts}")
    if placer.missing:
        print(f"[world] WARN missing props (skipped): {sorted(placer.missing)}")
    sight = roadside.clear_sightlines(placer, manifest, [s for r in sign_res.values() for s in r.sightlines],
                                      SMASHABLE, WALLS, authored)
    print(f"[world] sign sightlines cleared {sight['removed']}"
          + (f", WARN still blocked by {sight['blocking']}" if sight["blocking"] else ""))
    before = survey(cor, placer.out, manifest)
    lap("scatter")

    # ------------------------------------------------------------------ roadside dressing and bridges
    dress = MeshBuilder()
    boxes: list = []
    bridges_by_road = {}
    for rid, road in roads.items():
        pal = region_of_road[rid]["spec"]["palette"]
        build_guardrails(road, runs[rid], dress, boxes, lin(pal.get("rail_post", "8f98a3")), lin(pal.get("rail", "d7dde2")))
        build_delineators(road, dress, lin("f4f1ea"), lin("e0452f"), skip=sign_res[rid].marker_skip | keep[rid])
        n = len(road.pos)
        br = road.bridge
        visited = np.zeros(n, dtype=bool)
        bridges_by_road[rid] = []
        for i in range(n):
            prev = br[i - 1] if road.closed or i > 0 else ""
            if br[i] != "" and prev == "" and not visited[i] and built[rid][i]:
                j = i
                while br[j % n] != "" and not visited[j % n]:
                    visited[j % n] = True
                    j += 1
                build_bridge(road, i, j % n, br[i], ter.height_at, dress, boxes,
                             {k: lin(v) for k, v in pal.items() if k in ("bridge_rail", "bridge_cap", "stone", "wood", "wood_dark")})

    # nothing rigid in the road corridor: offenders move out (or go), smashables leave the tarmac
    res = enforce(cor, placer, manifest, boxes)
    if garage_info is not None:
        print(f"[world] garage at {garage_info['pos']}: dropped {drop_kept_out(garage_info, placer.out)} "
              f"instances in its keep-out")
    after = survey(cor, placer.out, manifest)
    print(f"[world] corridor before: {format_survey(before)}")
    print(f"[world] corridor moved {res['moved']}, dropped {res['dropped']}: "
          + ", ".join(f"{k} {v[0]}/{v[1]}" for k, v in sorted(res["by_name"].items())))
    print(f"[world] corridor after:  {format_survey(after)}")
    for name, x, z, mg in after["offenders"]:
        print(f"[world] WARN {name} at ({x}, {z}) is {-mg:.2f} m inside the road corridor")
    lap("dressing")

    # ------------------------------------------------------------------ meshes
    rgba, surf = paint_terrain(world, ter, roads, placer.out, manifest)
    lap("paint")
    pack = MeshPack()
    tstats = emit_terrain(pack, ter, rgba)
    lap("terrain_mesh")
    skips = {rid: [] for rid in roads}
    for j in J:
        skips[j.loop_id].append(junction.loop_skip_quads(roads[j.loop_id], j))
    # the branch's markings and shoulders fade out over its first / last 14 m into the aprons
    dc = np.minimum(branch.dist - branch.dist[j0.clear_i], branch.dist[j1.clear_i] - branch.dist)
    fade = {"branch": 1.0 - geom.smoothstep(0.0, 14.0, dc)}
    for rid, road in roads.items():
        emit_road(pack, rid, road, verts[rid][0], verts[rid][1], ter, rgba, built[rid], skips[rid], fade.get(rid))
    for j in J:
        emit_apron(pack, j, branch, roads[j.loop_id], verts["branch"][0], verts["branch"][1],
                   verts[j.loop_id][0], ter, rgba)
    emit_lots(pack, all_lots, ter, rgba)
    water_info = emit_water(pack, ter)
    emit_backdrop(pack, world, ter)
    p, nr, c, idx = dress.flat()
    if len(idx):
        pack.add("dressing", p, idx, col=c, nrm=nr, material="props_vc", collide="none")
    sign_info = build_signs(signs, pack)
    lap("meshes")

    # ------------------------------------------------------------------ routes, grids, json
    routes = {}
    for rid in ("hanami", "momiji"):
        road, rs, st = roads[rid], road_specs[rid], stage[rid]
        rcfg = world["routes"][rid]
        rows, style, dist = _track([(road, np.arange(len(road.pos)))], road.dist)
        pack.add_raw(f"track_{rid}", rows, "<f4", columns=["x", "y", "z", "fx", "fz", "half_width", "surface",
                                                          "flags", "dist", "bank"])
        ncp = rs.get("checkpoints", 6)
        cps = []
        for k in range(1, ncp + 1):
            ii = road_index(road, st["cp_abs"][k - 1])
            cps.append({"index": k - 1, "s": round(float(road.length * k / ncp), 2), "pos": r3(road.pos[ii]),
                        "yaw": round(yaw_of(road.fwd[ii]), 4),
                        "half_width": round(float(road.half_width[ii] + road.verge + 1.0), 2)})
        si = st["start_i"]
        routes[rid] = _route_json(f"track_{rid}", True, road.length, st["start_s"], road.verge,
                                  _bridges(style, rows[:, 8]), _pose(road, si),
                                  road.half_width[si] + road.verge + 1.0, _pose(road, st["spawn_i"], 0.6),
                                  rcfg["season"], rcfg["atmosphere"], checkpoints=cps,
                                  finish_stop=_pose(road, st["stop_i"], 0.6),
                                  corners=roadside.corners_json(road, corners[rid], 0.0, sign_res[rid]))
    lcfg = world["routes"]["liaison"]
    pack.add_raw("track_liaison", lia_rows, "<f4", columns=["x", "y", "z", "fx", "fz", "half_width", "surface",
                                                            "flags", "dist", "bank"])
    s_off = float(branch.dist[j0.fork_i]) - liaison_s(j0.fork_i)
    lo, hi = float(branch.dist[j0.clear_i]), float(branch.dist[j1.clear_i])
    lia_corners = [c for c in roadside.corners_json(branch, corners["branch"], s_off, sign_res["branch"])
                   if lo <= c["apex"]["s"] + s_off <= hi]
    spawn_m = _pose(m, i_spawn, 0.6)
    routes["liaison"] = _route_json("track_liaison", False, lia_dist[-1], 0.0, branch.verge,
                                    _bridges(lia_style, lia_rows[:, 8]),
                                    _pose(h, i_stop), h.half_width[i_stop] + h.verge + 1.0,
                                    _pose(h, i_stop, 0.6), lcfg["season"], lcfg["atmosphere"], checkpoints=[],
                                    arrival=dict(spawn_m, radius=float(lcfg["arrival_radius"])), corners=lia_corners)
    sg = surf[::2, ::2]
    pack.add_raw("surface_grid", sg, "u1", origin=[ter.ox, ter.oz], cell=ter.cell * 2, codes=list(TERRAIN_SURFACES))
    season_q, season_org, season_cell = seasons.grid(world["bounds"], world["seasons"], world["seed"])
    pack.add_raw("season_grid", season_q, "u1", origin=season_org, cell=season_cell,
                 dims=[int(season_q.shape[1]), int(season_q.shape[0])], order=list(seasons.SEASONS))
    road_info = {rid: {"length": round(float(r.length), 2), "closed": r.closed, "verge": r.verge,
                       "half_width": round(float(r.half_width.max()), 2)} for rid, r in roads.items()}
    road_info["branch"]["junctions"] = [{"road": j.loop_id, "end": j.end, "s": round(float(branch.dist[j.fork_i]), 2),
                                         "other_s": round(float(roads[j.loop_id].dist[j.loop_fork]), 2)} for j in J]
    for g in gates:
        del g["branch_i"]
    base_mats = region_of_road["hanami"]["spec"].get("materials", {})
    out = {
        "id": MAP_ID, "version": 2,
        "bin": f"res://assets/maps/{MAP_ID}/map.bin",
        "bounds": [float(v) for v in world["bounds"]], "cell": ter.cell,
        "roads": road_info,
        "routes": routes,
        "gates": gates,
        "season_grid": {"raw": "season_grid", "origin": season_org, "cell": season_cell,
                        "dims": [int(season_q.shape[1]), int(season_q.shape[0])], "order": list(seasons.SEASONS)},
        "water": water_info,
        "collision_boxes": boxes,
        "signs": sign_info,
        "parked": parked,
        "materials": base_mats,
        "meshes": pack.meshes,
        "raw": pack.raw,
        "instances": placer.out,
    }
    if garage_info is not None:
        out["garage"] = garage_info
    pack.save(os.path.join(out_dir, "map.bin"))
    with open(os.path.join(out_dir, "map.json"), "w") as f:
        json.dump(out, f, separators=(",", ":"))
    lap("write")
    total = sum(len(v) for v in placer.out.values())
    tris = sum(d.get("icount", 0) for d in pack.meshes) // 3
    print(f"[world] terrain chunks: near {tstats['near'][0]} ({tstats['near'][1]} tris), far {tstats['far'][0]} "
          f"({tstats['far'][1]} tris), beyond the rim {tstats['out'][0]} ({tstats['out'][1]} tris)")
    print(f"[world] wrote {len(pack.meshes)} meshes ({tris} tris), map.bin {len(pack.buf) / 1e6:.1f} MB, "
          f"map.json {os.path.getsize(os.path.join(out_dir, 'map.json')) / 1e6:.1f} MB, {total} instances "
          f"({len(placer.out)} props), {len(boxes)} boxes, {len(sign_info)} signs, {len(parked)} parked cars")
    preview(world, ter, roads, rgba, placer.out, routes, gates, J, built, garage_info)
    lap("preview")
    print(f"[world] timings (s): {timings}, total {time.time() - t0:.1f}")


# ---------------------------------------------------------------------- previews

def preview(world: dict, ter, roads: dict, rgba, placed: dict, routes: dict, gates: list, J: list, built: dict,
            garage_info) -> None:
    """docs/renders/map_world.png: the whole world (terrain colours, shaded; water; roads by
    surface; trees; route markers; gates) with a season strip, and crops per region."""
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        print("WARN pillow missing; no preview")
        return
    S = 0.64  # px per metre
    x0, z0 = ter.ox, ter.oz
    Wd, Hd = int((ter.nx - 1) * ter.cell * S), int((ter.nz - 1) * ter.cell * S)
    col = to_srgb(rgba[..., :3])
    gz, gx = np.gradient(ter.H, ter.cell)
    nx_, nz_ = -gx, -gz
    ln = np.sqrt(nx_ * nx_ + 1.0 + nz_ * nz_)
    sun = np.array([-0.5, 0.75, -0.45])
    sun /= np.linalg.norm(sun)
    shade = np.clip((nx_ * sun[0] + sun[1] + nz_ * sun[2]) / ln, 0.0, 1.0)
    col = col * (0.55 + 0.45 * shade[..., None])
    img = Image.fromarray((np.clip(col, 0, 1) * 255).astype(np.uint8)).resize((Wd, Hd), Image.BILINEAR)
    dr = ImageDraw.Draw(img)

    def px(x, z):
        return ((x - x0) * S, (z - z0) * S)

    water_c = (122, 176, 214)
    w = ter.water
    if w.lake_poly is not None:
        dr.polygon([px(x, z) for x, z in w.lake_poly], fill=water_c)
    for rv in w.rivers:
        dr.line([px(p[0], p[2]) for p in rv.pts], fill=water_c, width=max(2, int(rv.width * S)))
    colors = {"tarmac": (86, 90, 108), "gravel": (196, 170, 128), "dirt": (170, 130, 90), "wood": (150, 100, 60)}
    for road in roads.values():
        for lot in road.lots:
            o = lot_outline(lot, 0.0)
            ax, rt = lot.axis, np.array([-lot.axis[1], lot.axis[0]])
            dr.polygon([px(lot.center[0] + a * rt[0] + b * ax[0], lot.center[1] + a * rt[1] + b * ax[1]) for a, b in o],
                       fill=colors[lot.surface])
    tree_col = {"sakura": (246, 190, 210), "maple_green": (90, 150, 60), "maple": (220, 80, 50),
                "cedar": (40, 90, 70), "pine": (60, 110, 80), "bamboo": (130, 180, 90), "persimmon": (240, 150, 60),
                "ginkgo": (240, 200, 60)}
    for name, inst in placed.items():
        c = next((v for k, v in tree_col.items() if name.startswith(k)), None)
        if c is None:
            c = (70, 70, 80) if not name.startswith(("grass", "flower", "fern", "reed")) else None
        if c is None:
            continue
        for (x, y, z, yaw, sc) in inst:
            X, Y = px(x, z)
            dr.ellipse([X - 1.3, Y - 1.3, X + 1.3, Y + 1.3], fill=c)
    for rid, road in roads.items():
        wpx = max(2, int(2 * road.half_width.mean() * S))
        n = len(road.pos)
        for i in range(n if road.closed else n - 1):
            j = (i + 1) % n
            if not (built[rid][i] and built[rid][j]):
                continue
            c = (220, 70, 50) if road.bridge[i] else colors[SURFACES[road.surface[i]]]
            dr.line([px(road.pos[i, 0], road.pos[i, 2]), px(road.pos[j, 0], road.pos[j, 2])], fill=c, width=wpx)
    # the liaison route (thin yellow line on top) and the stage markers
    lia = routes["liaison"]
    for rid, r in routes.items():
        for cp in r.get("checkpoints", []):
            X, Y = px(cp["pos"][0], cp["pos"][2])
            dr.ellipse([X - 5, Y - 5, X + 5, Y + 5], outline=(255, 220, 60), width=2)
        for key, fill in (("spawn", (255, 255, 255)), ("finish_stop", (40, 40, 40))):
            if key in r:
                X, Y = px(r[key]["pos"][0], r[key]["pos"][2])
                dr.rectangle([X - 5, Y - 5, X + 5, Y + 5], fill=fill, outline=(0, 0, 0))
        st = r["road"]["start"]
        X, Y = px(st["pos"][0], st["pos"][2])
        a = st["yaw"]
        dx, dz = math.cos(a) * 9, -math.sin(a) * 9  # across the road
        dr.line([(X - dx, Y - dz), (X + dx, Y + dz)], fill=(250, 250, 250), width=3)
        dr.text((X + 8, Y + 6), rid, fill=(20, 20, 30))
    ar = lia["arrival"]
    X, Y = px(ar["pos"][0], ar["pos"][2])
    R = ar["radius"] * S
    dr.ellipse([X - R, Y - R, X + R, Y + R], outline=(230, 60, 60), width=3)
    for g in gates:
        X, Y = px(g["pos"][0], g["pos"][2])
        a = g["yaw"]
        hw = g["width"] / 2 * S + 2
        dx, dz = math.cos(a) * hw, -math.sin(a) * hw
        dr.line([(X - dx, Y - dz), (X + dx, Y + dz)], fill=(230, 40, 40), width=5)
        dr.text((X + 8, Y - 14), g["id"], fill=(160, 20, 20))
    if garage_info is not None:
        X, Y = px(garage_info["pos"][0], garage_info["pos"][2])
        dr.rectangle([X - 6, Y - 6, X + 6, Y + 6], outline=(200, 40, 40), width=2)
        dr.text((X + 8, Y), "garage", fill=(160, 20, 20))
    # season strip along the bottom: the season grid's colours along x at the branch's latitude
    strip = 18
    wts = seasons.weights(np.linspace(x0, x0 + (ter.nx - 1) * ter.cell, Wd), np.full(Wd, 340.0),
                          world["seasons"], world["seed"])
    tint = np.array([[246, 170, 200], [120, 190, 80], [220, 90, 40]], dtype=np.float64)
    band = (wts @ tint).astype(np.uint8)
    img.paste(Image.fromarray(np.repeat(band[None], strip, axis=0)), (0, Hd - strip))
    out_dir = os.path.join(REPO, "docs", "renders")
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "map_world.png")
    img.save(path)
    print(f"[world] preview {path}")
    crops = {"hanami": (-700.0, -700.0, 700.0, 700.0), "momiji": (1500.0, -250.0, 2850.0, 1100.0),
             "branch": (-100.0, 50.0, 1900.0, 650.0)}
    for name, (a, b, c, d) in crops.items():
        box = tuple(int(v) for v in (*px(a, b), *px(c, d)))
        sub = img.crop(box)
        k = 1400.0 / max(sub.size)
        sub = sub.resize((int(sub.size[0] * k), int(sub.size[1] * k)), Image.BILINEAR)
        p = os.path.join(out_dir, f"map_{name}.png")
        sub.save(p)
        print(f"[world] preview {p}")


def main() -> None:
    build()


if __name__ == "__main__":
    main()
