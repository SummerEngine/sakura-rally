"""The garage: a service workshop beside a road, from a map's GARAGE entry (maps/hanami.py).

Road-relative like the dressing: the display spot (where the menu car stands) sits `offset_m`
along the road from control point `road_at`, `lateral` metres to the side (+ = right of the
driving direction), heading along the road. Around it:

  lot       a paved drive-through lay-by joined to the road (a road Lot: levelled, collides,
            painted like the service parks); cars leave it forward onto the road and arrive
            into it from behind.
  workshop  the building (built at runtime by scripts/game/garage_set.gd) behind the display
            spot, its open front toward the road, on a terrain pad at the lot's height.
  keep-out  a rectangle over the lot, the workshop and a margin: no prop instance stays in it
            (mapgen reserves it for the scatter and drops authored dressing inside it).

Pure functions of the entry and the built road, in world space, so every road that carries a
garage (the v1 Hanami map, the one-world Hanami loop) gets the same layout:

  garage_lot(g)            -> road "lots" entry (add to spec["road"]["lots"] before build_road)
  garage_pad(g)            -> terrain "pads" entry (add to spec["terrain"]["pads"])
  garage_layout(g, road)   -> the map.json "garage" dict (world space; see below)
  in_keep_out(layout, x, z) / drop_kept_out(layout, instances) -> filter prop instances

map.json "garage":
  pos [x, y, z]      display spot on the lot surface; yaw: heading there (spawn convention,
                     forward = (-sin yaw, 0, -cos yaw)). MapWorld.garage = Transform3D(Basis(UP,
                     yaw), pos). Garage-local frame: -Z forward along the road, +X toward the road.
  workshop [x, z]    the workshop's centre in garage-local metres (its front faces +X)
  lot [x, z, half_across, half_along]   the lay-by rectangle in garage-local metres
  keep_out [[x, z] x4]                  world-space corners of the keep-out rectangle
  road_side          +1 when the road is on the garage's +X side (always, by construction)
"""
from __future__ import annotations

import math

import numpy as np

from .road import LOT_DROP, Road, road_index
from .terrain import CARVE_DROP


def _frame(g: dict, road: Road) -> tuple[np.ndarray, np.ndarray, np.ndarray, float]:
    """Display spot (x, z), forward (x, z), right (x, z) and the road height there."""
    s = float(road.control_s[g["road_at"]] + g.get("offset_m", 0.0))
    i = road_index(road, s % road.length if road.closed else s)
    fwd = road.fwd[i] / np.linalg.norm(road.fwd[i])
    right = road.right[i] / np.linalg.norm(road.right[i])
    p = road.pos[i, [0, 2]] + right * g["lateral"]
    return p, fwd, right, float(road.pos[i, 1])


def garage_lot(g: dict) -> dict:
    lot = g["lot"]
    return {"name": "garage", "road_at": g["road_at"], "offset_m": g.get("offset_m", 0.0),
            "lateral": lot["lateral"], "width": lot["width"], "length": lot["length"],
            "corner": lot.get("corner", 6.0), "surface": lot.get("surface", "tarmac")}


def garage_pad(g: dict) -> dict:
    w = g["workshop"]
    return {"road_at": g["road_at"], "offset_m": g.get("offset_m", 0.0), "lateral": w["lateral"],
            "radius": 0.5 * math.hypot(w["width"], w["depth"]), "blend": w.get("blend", 8.0),
            # terrain pads sit CARVE_DROP under the road; the workshop floor meets the lay-by
            "rise": CARVE_DROP - LOT_DROP}


def garage_layout(g: dict, road: Road) -> dict:
    p, fwd, right, y_road = _frame(g, road)
    lot = next((l for l in road.lots if l.name == "garage"), None)
    y = (lot.y if lot is not None else y_road) - LOT_DROP
    yaw = math.atan2(-fwd[0], -fwd[1])
    # garage-local x = metres toward the road (right of the car is -lateral), z = back along the road
    lat0 = g["lateral"]
    w, lt = g["workshop"], g["lot"]
    margin = g.get("keep_out", 3.0)
    road_edge = lt["lateral"] + lt["width"] / 2.0   # the lot's road-side edge (lateral metres)
    back = w["lateral"] - w["depth"] / 2.0 - margin
    half_along = max(lt["length"] / 2.0, w["width"] / 2.0) + margin
    corners = []
    for lat, along in ((road_edge, -half_along), (road_edge, half_along), (back, half_along), (back, -half_along)):
        c = p + right * (lat - lat0) + fwd * along
        corners.append([round(float(c[0]), 2), round(float(c[1]), 2)])
    return {
        "pos": [round(float(p[0]), 3), round(y, 3), round(float(p[1]), 3)],
        "yaw": round(float(yaw), 4),
        "workshop": [round(float(w["lateral"] - lat0), 2), 0.0],
        "lot": [round(float(lt["lateral"] - lat0), 2), 0.0, lt["width"] / 2.0, lt["length"] / 2.0],
        "keep_out": corners,
        "road_side": 1,
    }


def in_keep_out(layout: dict, x, z) -> np.ndarray:
    """True where (x, z) lies inside the keep-out rectangle (convex, corners in order)."""
    x = np.asarray(x, dtype=np.float64)
    z = np.asarray(z, dtype=np.float64)
    c = np.array(layout["keep_out"], dtype=np.float64)
    sign = None
    inside = np.ones(np.broadcast(x, z).shape, dtype=bool)
    for k in range(4):
        a, b = c[k], c[(k + 1) % 4]
        cross = (b[0] - a[0]) * (z - a[1]) - (b[1] - a[1]) * (x - a[0])
        if sign is None:
            m = (c[(k + 2) % 4] - a)
            sign = np.sign((b[0] - a[0]) * m[1] - (b[1] - a[1]) * m[0])
        inside &= cross * sign >= 0.0
    return inside


def keep_out_circles(layout: dict, spacing: float = 6.0) -> list[tuple[float, float, float]]:
    """Circles (x, z, r) covering the keep-out, to reserve it in the scatter's occupancy grid."""
    c = np.array(layout["keep_out"], dtype=np.float64)
    u, v = c[1] - c[0], c[3] - c[0]
    nu = max(1, int(math.ceil(np.linalg.norm(u) / spacing)))
    nv = max(1, int(math.ceil(np.linalg.norm(v) / spacing)))
    r = 0.75 * math.hypot(np.linalg.norm(u) / nu, np.linalg.norm(v) / nv)
    out = []
    for i in range(nu):
        for j in range(nv):
            q = c[0] + u * (i + 0.5) / nu + v * (j + 0.5) / nv
            out.append((float(q[0]), float(q[1]), r))
    return out


def drop_kept_out(layout: dict, instances: dict) -> int:
    """Removes every instance inside the keep-out from {prop: [[x, y, z, yaw, scale], ...]}."""
    dropped = 0
    for name in list(instances):
        rows = instances[name]
        if not rows:
            continue
        a = np.array([[r[0], r[2]] for r in rows])
        keep = ~in_keep_out(layout, a[:, 0], a[:, 1])
        dropped += int((~keep).sum())
        instances[name] = [r for r, k in zip(rows, keep) if k]
    return dropped
