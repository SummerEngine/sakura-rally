"""Road centreline, per-sample attributes, road ribbon mesh and roadside dressing."""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from . import geom
from .meshpack import MeshBuilder

SURFACES = ("tarmac", "gravel", "dirt", "wood")
PROFILE = 11  # vertices per cross-section
LOT_DROP = 0.04  # a lot's paved surface sits this far below the road's carriageway edge


@dataclass
class Road:
    pos: np.ndarray      # (n, 3) centreline, 1 m spacing
    dist: np.ndarray     # (n,) distance along
    length: float
    fwd: np.ndarray      # (n, 2) horizontal tangent (x, z)
    right: np.ndarray    # (n, 2)
    curv: np.ndarray     # (n,) 1/m, + = right turn
    bank: np.ndarray     # (n,) height change per metre of lateral offset (+ lowers the right side)
    half_width: np.ndarray
    verge: float
    surface: np.ndarray  # (n,) index into SURFACES
    bridge: np.ndarray   # (n,) "" or bridge style
    ford: np.ndarray     # (n,) bool
    carve: np.ndarray    # (n,) 0..1 terrain carve weight (0 on bridges)
    control_s: np.ndarray  # distance of each control point
    closed: bool = True  # False: point to point, from control point 0 to the last one
    lots: list = field(default_factory=list)  # paved areas the road runs into (Lot)
    on_lot: np.ndarray | None = None  # (n,) 0..1, 1 where the road crosses a lot


@dataclass
class Lot:
    """Flat paved area (rounded rectangle) the road runs into: turn-arounds at the ends of
    an open road, service parks, lay-bys. The road is levelled to it."""
    name: str
    center: np.ndarray   # (x, z)
    axis: np.ndarray     # (x, z) unit vector along the lot's length
    half_w: float        # across
    half_l: float        # along
    corner: float
    y: float             # paved surface height
    surface: str         # "tarmac" or "gravel"

    def local(self, x, z) -> tuple[np.ndarray, np.ndarray]:
        """(across, along) lot coordinates in metres; across is + to the right of axis."""
        dx = np.asarray(x, dtype=np.float64) - self.center[0]
        dz = np.asarray(z, dtype=np.float64) - self.center[1]
        return dx * -self.axis[1] + dz * self.axis[0], dx * self.axis[0] + dz * self.axis[1]

    def sdf(self, x, z) -> np.ndarray:
        """Signed distance to the lot outline (m, negative inside)."""
        a, b = self.local(x, z)
        r = self.corner
        qa = np.abs(a) - (self.half_w - r)
        qb = np.abs(b) - (self.half_l - r)
        return np.hypot(np.maximum(qa, 0.0), np.maximum(qb, 0.0)) + np.minimum(np.maximum(qa, qb), 0.0) - r


def _attr_runs(points: list, key: str, default, closed: bool):
    """Persistent attribute per control segment: value set on a point applies to the
    segment that starts there and every following one until changed."""
    vals = []
    cur = default
    for p in points:
        if len(p) > 3 and key in p[3]:
            cur = p[3][key]
        vals.append(cur)
    if not closed:
        return vals
    # the loop wraps: segments before the first explicit value inherit the last one
    first_set = next((i for i, p in enumerate(points) if len(p) > 3 and key in p[3]), None)
    if first_set is not None and first_set > 0:
        for i in range(first_set):
            vals[i] = vals[-1] if vals[-1] is not None else default
    return vals


def road_index(road: Road, s: float) -> int:
    """Sample index at distance s (samples sit ~1 m apart): wraps around a loop, clamps
    to the ends of an open road."""
    n = len(road.pos)
    if road.closed:
        return int(round(s)) % n
    return int(np.clip(round(s), 0, n - 1))


def _build_lots(spec: dict, pos: np.ndarray, fwd: np.ndarray, right: np.ndarray,
                control_s: np.ndarray, closed: bool, length: float) -> list[Lot]:
    lots = []
    n = len(pos)
    for k, l in enumerate(spec.get("lots", [])):
        s = control_s[l["road_at"]] + l.get("offset_m", 0.0)
        i = int(round(s % length)) % n if closed else int(np.clip(round(s), 0, n - 1))
        c = pos[i, [0, 2]] + right[i] * l.get("lateral", 0.0) + fwd[i] * l.get("along", 0.0)
        ang = np.radians(l.get("yaw_add", 0.0))
        f = fwd[i]
        axis = np.array([f[0] * np.cos(ang) + f[1] * np.sin(ang), -f[0] * np.sin(ang) + f[1] * np.cos(ang)])
        lots.append(Lot(name=l.get("name", f"lot_{k}"), center=c, axis=axis, half_w=l["width"] / 2.0,
                        half_l=l["length"] / 2.0, corner=l.get("corner", 6.0), y=float(pos[i, 1]),
                        surface=l.get("surface", "tarmac")))
    return lots


def build_road(spec: dict) -> Road:
    closed = spec.get("closed", True)
    pts = spec["points"]
    ctrl = np.array([[p[0], p[2], p[1]] for p in pts], dtype=np.float64)  # (x, y, z)
    per_seg = 96
    dense = geom.catmull_rom(ctrl, per_seg=per_seg, closed=closed)
    n_seg = len(ctrl) if closed else len(ctrl) - 1
    seg_id = np.repeat(np.arange(n_seg), per_seg).astype(np.float64)
    # carry the control segment index through resampling
    if closed:
        path = np.vstack([dense, dense[:1]])
    else:
        path = dense
        seg_id = np.append(seg_id, n_seg - 1)  # the end point closes the last segment
    seglen = np.linalg.norm(np.diff(path[:, [0, 2]], axis=0), axis=1)
    cum = np.concatenate([[0.0], np.cumsum(seglen)])
    knots = cum[:-1] if closed else cum  # distance of each dense point
    pos, dist = geom.resample(dense, 1.0, closed=closed)
    sid = np.floor(np.interp(dist, knots, seg_id)).astype(np.int64) % len(ctrl)
    control_s = np.array([np.interp(i * per_seg, np.arange(len(knots)), knots) for i in range(len(ctrl))])
    length = float(cum[-1])
    n = len(pos)

    # heights: remove Catmull-Rom kinks, then add authored crests
    pos[:, 1] = geom.smooth(pos[:, 1], spec.get("height_smooth", 8.0), closed=closed)
    for c in spec.get("crests", []):
        s0 = control_s[c["at"]] + c.get("offset", 0.0)
        ds = (dist - s0 + length / 2) % length - length / 2 if closed else dist - s0
        pos[:, 1] += c["height"] * np.exp(-0.5 * (ds / c.get("width", 9.0)) ** 2)

    fwd, right, curv = geom.frames(pos, closed=closed)
    curv_s = geom.smooth(curv, 6.0, closed=closed)

    # paved lots: the road is levelled to each lot's height inside it, easing out over 30 m
    lots = _build_lots(spec, pos, fwd, right, control_s, closed, length)
    on_lot = np.zeros(n)
    for lot in lots:
        w = 1.0 - geom.smoothstep(0.0, 30.0, lot.sdf(pos[:, 0], pos[:, 2]))
        pos[:, 1] += (lot.y - pos[:, 1]) * w
        on_lot = np.maximum(on_lot, w)

    surf_runs = _attr_runs(pts, "surface", spec.get("surface", "tarmac"), closed)
    surface = np.array([SURFACES.index(surf_runs[i]) for i in sid])
    bridge_runs = _attr_runs(pts, "bridge", None, closed)
    bridge = np.array([bridge_runs[i] or "" for i in sid], dtype=object)
    ford_runs = _attr_runs(pts, "ford", False, closed)
    ford = np.array([bool(ford_runs[i]) for i in sid])
    width_runs = _attr_runs(pts, "width", spec["width"], closed)
    half_width = geom.smooth(np.array([width_runs[i] / 2.0 for i in sid], dtype=np.float64), 10.0, closed=closed)
    surface[bridge != ""] = np.where(np.array([b.startswith("wood") for b in bridge[bridge != ""]]),
                                     SURFACES.index("wood"), surface[bridge != ""])

    bank_gain = spec.get("bank_gain", 14.0)
    bank_max = spec.get("bank_max", 0.05)
    bank = geom.smooth(np.clip(curv_s * bank_gain, -bank_max, bank_max), 10.0, closed=closed)
    bank[bridge != ""] *= 0.2
    if lots:
        bank *= 1.0 - on_lot

    on_bridge = (bridge != "").astype(np.float64)
    carve = 1.0 - np.clip(geom.smooth(on_bridge, 1.5, closed=closed) * 1.2, 0.0, 1.0)
    carve[bridge != ""] = 0.0

    return Road(pos=pos, dist=dist, length=length, fwd=fwd, right=right, curv=curv_s, bank=bank,
                half_width=half_width, verge=spec.get("verge", 1.4), surface=surface, bridge=bridge,
                ford=ford, carve=carve, control_s=control_s, closed=closed, lots=lots, on_lot=on_lot)


def surface_at_lateral_offsets(road: Road) -> tuple[np.ndarray, np.ndarray]:
    """Lateral offsets (n, PROFILE) and height offsets (n, PROFILE) of the cross-section."""
    n = len(road.pos)
    hw = road.half_width[:, None]
    V = road.verge
    lat = np.empty((n, PROFILE))
    dy = np.empty((n, PROFILE))
    base_lat = [-(V + 1.1), -V, -0.35, 0.0]
    base_dy = [-0.95, -0.25, -0.05, 0.0]
    for k in range(4):
        lat[:, k] = -(hw[:, 0] + (-base_lat[k]))
        lat[:, PROFILE - 1 - k] = hw[:, 0] + (-base_lat[k])
        dy[:, k] = base_dy[k]
        dy[:, PROFILE - 1 - k] = base_dy[k]
    lat[:, 4] = -hw[:, 0] * 0.5
    lat[:, 5] = 0.0
    lat[:, 6] = hw[:, 0] * 0.5
    crown = np.where(road.surface == SURFACES.index("tarmac"), 0.03, 0.06)
    dy[:, 4] = crown * 0.6
    dy[:, 5] = crown
    dy[:, 6] = crown * 0.6
    # bridges: flat deck with a fascia instead of verges and skirts
    br = road.bridge != ""
    if br.any():
        lat[br, 0] = -(hw[br, 0] + 0.55)
        lat[br, 1] = -(hw[br, 0] + 0.55)
        lat[br, 2] = -(hw[br, 0] + 0.30)
        lat[br, PROFILE - 1] = hw[br, 0] + 0.55
        lat[br, PROFILE - 2] = hw[br, 0] + 0.55
        lat[br, PROFILE - 3] = hw[br, 0] + 0.30
        dy[br, 0] = -1.1
        dy[br, PROFILE - 1] = -1.1
        dy[br, 1] = 0.12
        dy[br, PROFILE - 2] = 0.12
        dy[br, 2] = 0.12
        dy[br, PROFILE - 3] = 0.12
        dy[br, 4:7] = 0.0
    # banking tilts the carriageway; verges follow the edge height
    lat_c = np.clip(lat, -hw, hw)
    dy = dy - lat_c * road.bank[:, None]
    return lat, dy


def road_vertices(road: Road) -> tuple[np.ndarray, np.ndarray]:
    lat, dy = surface_at_lateral_offsets(road)
    p = road.pos
    x = p[:, 0:1] + road.right[:, 0:1] * lat
    z = p[:, 2:3] + road.right[:, 1:2] * lat
    y = p[:, 1:2] + dy
    return np.stack([x, y, z], axis=2), lat  # (n, PROFILE, 3)


def road_height_at(road: Road, idx: np.ndarray, lat: np.ndarray) -> np.ndarray:
    """Carriageway height at a lateral offset (clamped to the road edge) for sample idx."""
    hw = road.half_width[idx]
    return road.pos[idx, 1] - np.clip(lat, -hw, hw) * road.bank[idx]


def ribbon_indices(n_rows: int, n_cols: int, closed: bool) -> np.ndarray:
    rows = n_rows if closed else n_rows - 1
    out = []
    for k in range(rows):
        k2 = (k + 1) % n_rows
        for m in range(n_cols - 1):
            a = k * n_cols + m          # (k, m)
            b = k * n_cols + m + 1      # (k, m+1)
            c = k2 * n_cols + m + 1     # (k+1, m+1)
            d = k2 * n_cols + m         # (k+1, m)
            out.extend([d, c, b, d, b, a])
    return np.array(out, dtype=np.int64)


def road_chunks(road: Road, chunk_len: int = 160) -> list[tuple[int, int]]:
    """Split the loop into index ranges, breaking at surface changes so each chunk
    carries a single physics surface."""
    n = len(road.pos)
    cuts = {0}
    phys = np.array([_phys_surface(s) for s in road.surface])
    for i in range(n):
        if phys[i] != phys[i - 1]:
            cuts.add(i)
    cuts = sorted(cuts)
    ranges = []
    for ci, a in enumerate(cuts):
        b = cuts[ci + 1] if ci + 1 < len(cuts) else n
        s = a
        while s < b:
            e = min(b, s + chunk_len)
            ranges.append((s, e))
            s = e
    return ranges


def _phys_surface(s: int) -> str:
    name = SURFACES[s]
    return "tarmac" if name == "wood" else name


def phys_surface(s: int) -> str:
    return _phys_surface(s)


# ------------------------------------------------------------------ dressing

@dataclass
class RailRun:
    """One continuous guardrail on one side of a road, sample a to sample b (forward, wrapping
    on a loop). Ends: "flare" (leading end: the first `flare` m bend away from the road and the
    beam dips into the ground), "trail" (trailing end: straight on, the beam dips into the
    ground over RAIL_BURY m), "bridge" (tapers in to meet the bridge parapet) or "loop" (a rail
    all round)."""
    a: int
    b: int
    side: int      # -1 left, +1 right of the driving direction
    a_end: str = "flare"
    b_end: str = "trail"
    flare: int = 8


RAIL_FACE = -0.45      # m past the verge: the rail's face line
RAIL_FLARE_OUT = 1.6   # m a flared end bends away from the road
RAIL_BURY = 4.0        # m over which a flared end's beam dips into the ground
RAIL_COLLIDER_TOP = 1.25     # collider top above the rail's base (the beam's top is at 0.77)
RAIL_COLLIDER_BOTTOM = -0.35
RAIL_COLLIDER_THICK = 0.5    # into the verge side it is flush with the beam; the rest is behind it


def build_guardrails(road: Road, runs: list[RailRun], mb: MeshBuilder, boxes: list,
                     post_color, rail_color) -> None:
    """W-beam guardrails for lib.roadside.rail_runs: posts every 4 m, the beam, and collision
    boxes (map.json collision_boxes, the runtime's rigid Barriers) tall and thick enough that a
    car cannot hop or pass through them, contiguous along the run."""
    n = len(road.pos)
    for r in runs:
        count = (r.b - r.a) % n if road.closed else r.b - r.a
        if r.a_end == "loop":
            count = n
        ks = list(range(0, count + 1, 2))
        if ks[-1] != count:
            ks.append(count)
        idxs = [(r.a + k) % n if road.closed else min(r.a + k, n - 1) for k in ks]
        pts, beam, keep_col = [], [], []
        for k, i in zip(ks, idxs):
            base = road.half_width[i] + road.verge + RAIL_FACE
            lat = base
            h = 1.0  # beam height factor
            for d, kind in ((k, r.a_end), (count - k, r.b_end)):
                if kind == "flare" and d < r.flare:
                    u = 1.0 - d / r.flare
                    lat = max(lat, base + RAIL_FLARE_OUT * u * u)
                if kind in ("flare", "trail") and d < RAIL_BURY:
                    h = min(h, 0.15 + 0.85 * d / RAIL_BURY)
                elif kind == "bridge" and d < 6:
                    lat = min(lat, road.half_width[i] + 0.35 + (base - road.half_width[i] - 0.35) * d / 6.0)
            lat *= r.side
            y = road_height_at(road, np.array([i]), np.array([lat]))[0] - 0.12
            pts.append((road.pos[i, 0] + road.right[i, 0] * lat, y, road.pos[i, 2] + road.right[i, 1] * lat))
            beam.append(h)
        pts = np.array(pts)
        for k in range(0, len(pts), 2):
            if beam[k] < 0.5:
                continue
            p = pts[k]
            mb.box((p[0], p[1] + 0.38, p[2]), (0.12, 0.8, 0.12), _yaw_of(road.fwd[idxs[k]]), post_color)
        for k in range(len(pts) - 1):
            p0, p1 = pts[k], pts[k + 1]
            h0, h1 = beam[k], beam[k + 1]
            mid = (p0 + p1) / 2
            d = p1 - p0
            L = np.linalg.norm(d[[0, 2]])
            if L < 1e-3:
                continue
            yaw = np.arctan2(-d[0], -d[2])
            # the beam's centre line dips with the height factor at a buried end
            c0, c1 = p0[1] + 0.62 * h0, p1[1] + 0.62 * h1
            pitch = np.arctan2(c1 - c0, L)
            mb.box((mid[0], (c0 + c1) / 2, mid[2]), (0.06, 0.3, L + 0.05), yaw, rail_color, pitch=pitch)
            if k % 2 == 0:  # every other segment, doubled length: contiguous cover
                hm = min(h0, h1)
                top = RAIL_COLLIDER_TOP if hm >= 0.999 else max(0.6, 0.77 * hm + 0.1)
                i = idxs[k]
                out = r.side * (RAIL_COLLIDER_THICK - 0.25) / 2.0  # inner face stays on the beam
                cx = mid[0] + road.right[i, 0] * out
                cz = mid[2] + road.right[i, 1] * out
                cy = mid[1] + (top + RAIL_COLLIDER_BOTTOM) / 2.0
                boxes.append([round(float(cx), 3), round(float(cy), 3), round(float(cz), 3),
                              RAIL_COLLIDER_THICK, round(top - RAIL_COLLIDER_BOTTOM, 3), round(float(2 * L + 0.1), 3),
                              round(float(yaw), 4)])


def _yaw_of(f2: np.ndarray) -> float:
    """Yaw (around +Y) that turns Godot forward (-Z) onto horizontal direction f2 (x, z)."""
    return float(np.arctan2(-f2[0], -f2[1]))


def build_delineators(road: Road, mb: MeshBuilder, white, red, skip: np.ndarray | None = None) -> list[dict]:
    """Marker posts on the outside of corners (the corner signs' chevrons and the guardrails
    replace them where skip[i, side] is set: [:, 0] left, [:, 1] right)."""
    n = len(road.pos)
    placed = []
    last = -999
    for i in range(0, n, 3):
        c = road.curv[i]
        if abs(c) < 1.0 / 140.0 or road.bridge[i] != "" or road.ford[i] or road.on_lot[i] > 0.2:
            continue
        spacing = 30 if abs(c) < 1.0 / 60.0 else 16
        if road.dist[i] - last < spacing:
            continue
        side = -1 if c > 0 else 1  # outside of a right turn is the left
        if skip is not None and skip[i, 0 if side < 0 else 1]:
            continue
        last = road.dist[i]
        lat = side * (road.half_width[i] + road.verge + 0.25)
        y = road_height_at(road, np.array([i]), np.array([lat]))[0] - 0.3
        x = road.pos[i, 0] + road.right[i, 0] * lat
        z = road.pos[i, 2] + road.right[i, 1] * lat
        yaw = _yaw_of(road.fwd[i])
        mb.box((x, y + 0.55, z), (0.1, 1.1, 0.1), yaw, white)
        mb.box((x, y + 0.95, z), (0.11, 0.14, 0.11), yaw, red)
        placed.append({"i": i, "side": side})
    return placed


def build_bridge(road: Road, a: int, b: int, style: str, ground_h, mb: MeshBuilder, boxes: list,
                 palette: dict) -> None:
    """Deck underside, railings with posts and piers for the sample range [a, b)."""
    n = len(road.pos)
    idxs = [(a + k) % n for k in range((b - a) % n + 1)]
    red = palette.get("bridge_rail", (0.86, 0.27, 0.19))
    gold = palette.get("bridge_cap", (0.95, 0.77, 0.32))
    stone = palette.get("stone", (0.73, 0.70, 0.65))
    wood = palette.get("wood", (0.64, 0.44, 0.28))
    wood_dark = palette.get("wood_dark", (0.45, 0.31, 0.21))
    wooden = style.startswith("wood")
    stony = style.startswith("stone")
    stone_dark = tuple(float(c) * 0.78 for c in stone)
    rail_col = wood if wooden else red
    post_col = wood_dark if wooden else red
    # underside slab
    for k in range(0, len(idxs) - 1):
        i0, i1 = idxs[k], idxs[k + 1]
        p0, p1 = road.pos[i0], road.pos[i1]
        mid = (p0 + p1) / 2
        d = p1 - p0
        L = np.linalg.norm(d[[0, 2]])
        yaw = np.arctan2(-d[0], -d[2])
        pitch = np.arctan2(d[1], max(L, 1e-4))
        w = 2 * road.half_width[i0] + 1.1
        mb.box((mid[0], mid[1] - 0.75, mid[2]), (w, 0.7, L + 0.02), yaw, wood_dark if wooden else stone, pitch=pitch)
    for side in (-1, 1):
        rail_pts = []
        for k, i in enumerate(idxs):
            lat = side * (road.half_width[i] + 0.35)
            x = road.pos[i, 0] + road.right[i, 0] * lat
            z = road.pos[i, 2] + road.right[i, 1] * lat
            y = road.pos[i, 1] + 0.12
            rail_pts.append((x, y, z))
        rail_pts = np.array(rail_pts)
        step = 3
        for k in range(0, len(rail_pts), step):
            p = rail_pts[k]
            yaw = _yaw_of(road.fwd[idxs[k]])
            if wooden:
                mb.prism(p - (0, 0.1, 0), p + (0, 1.05, 0), 0.09, 6, post_col)
            elif stony:
                if k % (2 * step) == 0:  # squat stone piers in the parapet
                    mb.box((p[0], p[1] + 0.5, p[2]), (0.62, 1.25, 0.62), yaw, stone_dark)
                    mb.box((p[0], p[1] + 1.17, p[2]), (0.72, 0.12, 0.72), yaw, stone)
            else:
                mb.box((p[0], p[1] + 0.55, p[2]), (0.2, 1.1, 0.2), yaw, post_col)
                mb.prism(p + (0, 1.1, 0), p + (0, 1.32, 0), 0.12, 8, gold)
        for k in range(len(rail_pts) - 1):
            p0, p1 = rail_pts[k], rail_pts[k + 1]
            mid = (p0 + p1) / 2
            d = p1 - p0
            L = np.linalg.norm(d[[0, 2]])
            if L < 1e-4:
                continue
            yaw = np.arctan2(-d[0], -d[2])
            pitch = np.arctan2(d[1], L)
            if wooden:
                mb.box((mid[0], mid[1] + 0.95, mid[2]), (0.14, 0.14, L + 0.04), yaw, rail_col, pitch=pitch)
                mb.box((mid[0], mid[1] + 0.5, mid[2]), (0.1, 0.1, L + 0.04), yaw, rail_col, pitch=pitch)
            elif stony:  # solid parapet wall with a lighter coping
                mb.box((mid[0], mid[1] + 0.38, mid[2]), (0.46, 0.9, L + 0.04), yaw, stone_dark, pitch=pitch)
                mb.box((mid[0], mid[1] + 0.87, mid[2]), (0.56, 0.1, L + 0.06), yaw, stone, pitch=pitch)
            else:
                mb.box((mid[0], mid[1] + 1.0, mid[2]), (0.16, 0.12, L + 0.04), yaw, rail_col, pitch=pitch)
                mb.box((mid[0], mid[1] + 0.45, mid[2]), (0.1, 0.08, L + 0.04), yaw, rail_col, pitch=pitch)
            if k % 2 == 0:
                boxes.append([round(float(mid[0]), 3), round(float(mid[1] + 0.6), 3), round(float(mid[2]), 3),
                              0.3, 1.2, round(float(L * 2 + 0.1), 3), round(float(yaw), 4)])
    # piers down to the ground every ~12 m
    for k in range(6, len(idxs) - 6, 12):
        i = idxs[k]
        p = road.pos[i]
        g = ground_h(p[0], p[2])
        if p[1] - g < 1.2:
            continue
        yaw = _yaw_of(road.fwd[i])
        w = 2 * road.half_width[i] * 0.8
        if wooden:
            for s in (-1, 1):
                lat = s * road.half_width[i] * 0.7
                x = p[0] + road.right[i, 0] * lat
                z = p[2] + road.right[i, 1] * lat
                mb.prism((x, g - 1.0, z), (x, p[1] - 0.9, z), 0.22, 6, wood_dark)
        else:
            mb.box((p[0], (g - 1.0 + p[1] - 1.0) / 2, p[2]), (w, p[1] - g, 1.4), yaw, stone)
