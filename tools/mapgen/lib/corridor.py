"""The drivable corridor: no rigid collider stands where a car that runs wide, or leans on
the outside of a corner, can hit it (docs/CONTRACTS.md, "Road corridor").

  corridor      |lateral| < half width + verge + 1.5 m from the centreline of any stretch of road
  wide          half width + verge + 4 m on the outside of corners tighter than 60 m and the
                40 m braking zone before them, and on both sides ±8 m around each checkpoint
                (room for the runtime's fabric gate uprights)
  low obstacles low rocks, stumps and logs clear the wide corridor everywhere (a car does not
                see them coming and they launch it)
  smashables    props the runtime makes soft (the car drives through them) and knockable
                spectators may stand in the corridor, but never on the tarmac:
                |lateral| >= half width + 0.3 (crowds are placed >= 8 m out anyway)
  walls         guardrails and bridge rails are built along the road on purpose; they stay

`enforce` moves every offender straight out from the road until it clears (keeping its
height above the ground and staying off water, paved lots, steep ground and other props), and
drops the few that find no room within reach.
"""
from __future__ import annotations

import math
from types import SimpleNamespace

import numpy as np

from .road import Road
from .scatter import Occupancy

BASE_MARGIN = 1.5   # m beyond the verge
WIDE_MARGIN = 4.0   # m beyond the verge on the outside of tight corners and at checkpoints
TIGHT_RADIUS = 60.0  # m, corners tighter than this widen their outside
BRAKING = 40.0      # m of approach before a tight corner that widens with it
CHECKPOINT_ALONG = 8.0  # m either side of a checkpoint kept wide on both sides
TARMAC_MARGIN = 0.3  # smashables keep this far off the carriageway edge
MOVE_REACH = 16.0   # m, how far out an offender may be moved before it is dropped

# Props the runtime makes soft (a car passes through them, knocking them over). Mirror of
# SoftCourse.SMASHABLE in scripts/world/soft_course.gd; keep the two in step.
SMASHABLE = frozenset((
    "tape_post", "banner_fence", "flag_pole", "flag_pole_pink", "flag_pole_blue", "traffic_cone",
    "distance_board_100", "distance_board_50", "tire_stack", "hay_bale_round", "hay_bale_square",
    "marshal_post", "road_mirror", "rice_paddy_marker", "scarecrow", "koinobori", "fence_wood",
    "fence_bamboo", "bench",
    "corner_chevron_left", "corner_chevron_right", "corner_warn_curve_left", "corner_warn_curve_right",
    "corner_warn_sharp_left", "corner_warn_sharp_right", "corner_warn_hairpin_left", "corner_warn_hairpin_right",
    "corner_warn_series_left", "corner_warn_series_right",
))
# Spectators the runtime makes knockable (a car knocks them over; they get back up). Mirror
# of Crowd.PEOPLE in scripts/world/crowd.gd; keep the two in step.
KNOCKABLE = frozenset((
    "spectator_a", "spectator_b", "spectator_c", "spectator_d", "spectator_e", "spectator_f",
    "spectator_g", "spectator_h", "spectator_i", "spectator_j", "spectator_k", "spectator_l",
))
# Built along the road on purpose (the car scrapes along them).
WALLS = frozenset(("guardrail", "bridge_rail"))
# Start and finish arches span the road; the runtime softens their uprights.
ARCHES = frozenset(("start_arch", "finish_arch"))
# Low obstacles: clear of the wide corridor everywhere.
LOW = frozenset(("rock_a", "rock_b", "rock_c", "rock_d", "rock_e", "stump", "log"))


def kind_of(name: str, manifest: dict) -> str:
    """Report bucket of a rigid prop: trees / poles / rocks / other."""
    m = manifest.get(name, {})
    if m.get("category") == "tree":
        return "trees"
    if name in LOW or m.get("category") == "rock":
        return "rocks"
    col = m.get("collision", {})
    if col.get("type") == "cylinder" and col.get("radius", 1.0) * 2 < col.get("height", 0.0) / 4:
        return "poles"  # tall and thin: telephone poles, lanterns' posts, flag masts
    return "other"


def collider_points(col: dict, x: float, z: float, yaw: float, sc: float) -> list[tuple[float, float, float]]:
    """Footprint of a manifest collision shape: (x, z, radius) circles covering it."""
    cy, sy = math.cos(yaw), math.sin(yaw)
    pts = []
    for o in col.get("offsets", [[0.0, 0.0, 0.0]]):
        ox, oz = o[0] * sc, o[2] * sc
        cx, cz = x + ox * cy + oz * sy, z - ox * sy + oz * cy
        if col["type"] == "box":
            hx, hz = col["size"][0] * sc / 2, col["size"][2] * sc / 2
            c = col.get("center", [0.0, 0.0, 0.0])
            ccx, ccz = c[0] * sc, c[2] * sc
            # corners, edge midpoints and centre
            for fx in (-1.0, 0.0, 1.0):
                for fz in (-1.0, 0.0, 1.0):
                    lx, lz = ccx + fx * hx, ccz + fz * hz
                    pts.append((cx + lx * cy + lz * sy, cz - lx * sy + lz * cy, 0.0))
        else:
            pts.append((cx, cz, col.get("radius", 0.3) * sc))
    return pts


class Corridor:
    def __init__(self, road: Road, checkpoint_s: list[float]) -> None:
        self.road = road
        n = len(road.pos)
        hw = road.half_width
        base = hw + road.verge + BASE_MARGIN
        wide = hw + road.verge + WIDE_MARGIN
        # clearance per sample and side: [:, 0] left (-1), [:, 1] right (+1)
        c = np.stack([base, base], axis=1)
        tight = np.abs(road.curv) > 1.0 / TIGHT_RADIUS
        idx = np.arange(n)
        for i in np.nonzero(tight)[0]:
            col = 0 if road.curv[i] > 0 else 1  # outside of a right turn (curv > 0) is the left
            j = i - np.arange(int(BRAKING) + 1)
            j = j % n if road.closed else j[j >= 0]
            c[j, col] = wide[j]
        for s in checkpoint_s:
            ds = road.dist - s
            if road.closed:
                ds = (ds + road.length / 2) % road.length - road.length / 2
            k = idx[np.abs(ds) <= CHECKPOINT_ALONG]
            c[k, 0] = wide[k]
            c[k, 1] = wide[k]
        self.c = c
        self.wide = wide
        self.tarmac = hw + TARMAC_MARGIN
        self.reach = float(wide.max()) + 2.0
        self._bucket()

    def _bucket(self) -> None:
        """Road samples bucketed on a coarse grid."""
        self.cell = 16.0
        keys = np.floor(self.road.pos[:, [0, 2]] / self.cell).astype(np.int64)
        buckets: dict[tuple[int, int], list[int]] = {}
        for i, (a, b) in enumerate(keys):
            buckets.setdefault((int(a), int(b)), []).append(i)
        self.grid = {k: np.array(v, dtype=np.int64) for k, v in buckets.items()}

    @classmethod
    def union(cls, cors: list["Corridor"]) -> "Corridor":
        """One corridor over several roads (the world's loops and branch): margins are measured
        to the nearest sample of any of them."""
        u = cls.__new__(cls)
        u.road = SimpleNamespace(**{k: np.concatenate([getattr(c.road, k) for c in cors])
                                    for k in ("pos", "right", "fwd", "half_width")})
        u.c = np.concatenate([c.c for c in cors])
        u.wide = np.concatenate([c.wide for c in cors])
        u.tarmac = np.concatenate([c.tarmac for c in cors])
        u.reach = max(c.reach for c in cors)
        u._bucket()
        return u

    def _near(self, x: float, z: float, reach: float) -> np.ndarray:
        c = self.cell
        out = []
        for a in range(int(math.floor((x - reach) / c)), int(math.floor((x + reach) / c)) + 1):
            for b in range(int(math.floor((z - reach) / c)), int(math.floor((z + reach) / c)) + 1):
                v = self.grid.get((a, b))
                if v is not None:
                    out.append(v)
        return np.concatenate(out) if out else np.zeros(0, dtype=np.int64)

    def margin(self, x: float, z: float, rad: float, mode: str) -> tuple[float, int]:
        """(metres the circle clears its limit by (negative: inside), nearest road sample).
        mode: "rigid" corridor, "low" wide corridor everywhere, "soft" off the tarmac,
        "edge" plain distance from the carriageway edge."""
        road = self.road
        j = self._near(x, z, self.reach + rad)
        if len(j) == 0:
            return 1e9, -1
        dx = x - road.pos[j, 0]
        dz = z - road.pos[j, 2]
        d = np.sqrt(dx * dx + dz * dz) - rad
        if mode == "rigid":
            side = (dx * road.right[j, 0] + dz * road.right[j, 1]) >= 0.0
            lim = np.where(side, self.c[j, 1], self.c[j, 0])
        elif mode == "low":
            lim = self.wide[j]
        elif mode == "soft":
            lim = self.tarmac[j]
        else:
            lim = road.half_width[j]
        m = d - lim
        k = int(np.argmin(m))
        return float(m[k]), int(j[k])

    def prop_margin(self, col: dict, x: float, z: float, yaw: float, sc: float, mode: str) -> tuple[float, int]:
        best = (1e9, -1)
        for px, pz, rad in collider_points(col, x, z, yaw, sc):
            m = self.margin(px, pz, rad, mode)
            if m[0] < best[0]:
                best = m
        return best


def mode_of(name: str, manifest: dict) -> str | None:
    """Which corridor rule a placed prop answers to (None: no collider, or exempt)."""
    m = manifest.get(name, {})
    col = m.get("collision", {})
    if col.get("type", "none") == "none" or name in WALLS or name in ARCHES:
        return None
    if name in SMASHABLE or name in KNOCKABLE:
        return "soft"
    if name in LOW:
        return "low"
    return "rigid"


def survey(cor: Corridor, placed: dict, manifest: dict) -> dict:
    """Rigid colliders inside the corridor by bucket, smashables on the tarmac, and the
    smallest clearance of any rigid collider from the carriageway edge."""
    out = {"trees": 0, "poles": 0, "rocks": 0, "other": 0, "soft_on_tarmac": 0, "min_edge": 1e9, "offenders": []}
    items = []
    for name, inst in placed.items():
        mode = mode_of(name, manifest)
        if mode is None:
            continue
        col = manifest[name]["collision"]
        for x, _y, z, yaw, sc in inst:
            items.append((name, mode, col, x, z, yaw, sc))
    for name, mode, col, x, z, yaw, sc in items:
        m, _ = cor.prop_margin(col, x, z, yaw, sc, mode)
        if mode != "soft":
            e, _ = cor.prop_margin(col, x, z, yaw, sc, "edge")
            out["min_edge"] = min(out["min_edge"], e)
        if m < 0.0:
            if mode == "soft":
                out["soft_on_tarmac"] += 1
            else:
                out[kind_of(name, manifest)] += 1
            out["offenders"].append((name, round(float(x), 1), round(float(z), 1), round(m, 2)))
    return out


def format_survey(s: dict) -> str:
    total = s["trees"] + s["poles"] + s["rocks"] + s["other"]
    return (f"rigid in corridor {total} (trees {s['trees']}, poles {s['poles']}, rocks/stumps/logs {s['rocks']}, "
            f"other {s['other']}), smashables on tarmac {s['soft_on_tarmac']}, "
            f"min rigid clearance from road edge {s['min_edge']:.2f} m")


def enforce(cor: Corridor, placer, manifest: dict, boxes: list) -> dict:
    """Move rigid props and low obstacles out of the corridor (smashables off the tarmac),
    in place in placer.out. boxes: map collision boxes (guardrails, bridge rails), which moved
    props must not land on, nor on placer.reserved (parked cars, sign boards).
    Returns {"moved": n, "dropped": n, "by_name": {...}}."""
    ter = placer.ter
    road = cor.road
    rw = ter.water.river_width / 2.0
    ny_min = math.cos(math.radians(40.0))

    def occ_radius(name: str, sc: float) -> float:
        return placer.footprint(name) * 0.45 * sc

    # everything that takes room: colliders and bushes (not ground cover, ferns or reeds)
    def takes_room(name: str) -> bool:
        m = manifest.get(name, {})
        if m.get("collision", {}).get("type", "none") != "none":
            return True
        return m.get("category") == "vegetation" and m.get("footprint_radius", 0.0) >= 1.0

    offenders = []
    occ = Occupancy()
    for name, inst in placer.out.items():
        mode = mode_of(name, manifest)
        col = manifest.get(name, {}).get("collision")
        for k, (x, y, z, yaw, sc) in enumerate(inst):
            if mode is not None and cor.prop_margin(col, x, z, yaw, sc, mode)[0] < 0.0:
                offenders.append((name, k, mode))
            elif takes_room(name):
                occ.add(x, z, occ_radius(name, sc))
    for bx, _by, bz, sx, _sy, sz, yaw in boxes:
        # boxes are long and thin (rails): cover them with circles along their length
        L = max(sx, sz)
        w = min(sx, sz)
        ax = (math.cos(yaw), -math.sin(yaw)) if sx >= sz else (math.sin(yaw), math.cos(yaw))
        steps = max(1, int(L / max(w, 0.5)))
        for t in np.linspace(-L / 2, L / 2, steps + 1):
            occ.add(bx + ax[0] * t, bz + ax[1] * t, max(w, 0.3) / 2)
    for x, z, r in placer.reserved:
        occ.add(x, z, r)

    moved = dropped = 0
    by_name: dict[str, list[int]] = {}
    drop: dict[str, set[int]] = {}
    for name, k, mode in offenders:
        x, y, z, yaw, sc = placer.out[name][k]
        col = manifest[name]["collision"]
        sink = placer.ground_at(x, z) - y
        tree = manifest[name].get("category") == "tree"
        rad = occ_radius(name, sc)
        _, j = cor.prop_margin(col, x, z, yaw, sc, mode)
        ux, uz = x - road.pos[j, 0], z - road.pos[j, 2]
        L = math.hypot(ux, uz)
        if L < 0.05:  # dead on the centreline: push it right
            ux, uz, L = road.right[j, 0], road.right[j, 1], 1.0
        ux, uz = ux / L, uz / L
        fx, fz = road.fwd[j, 0], road.fwd[j, 1]
        best = None
        for along in (0.0, 2.0, -2.0, 4.0, -4.0):
            for out_m in np.arange(0.5, MOVE_REACH + 1e-6, 0.5):
                nx = x + ux * out_m + fx * along
                nz = z + uz * out_m + fz * along
                if cor.prop_margin(col, nx, nz, yaw, sc, mode)[0] < 0.25:
                    continue
                if mode == "soft":  # smashables only need to leave the tarmac
                    best = (nx, nz)
                    break
                if float(ter.sample(ter.lake_sd, nx, nz)) < rad + 1.0:
                    continue
                if float(ter.sample(ter.river_dist, nx, nz)) < rw + rad + 1.0:
                    continue
                if tree and float(ter.sample(ter.lot_sd, nx, nz)) < rad + 1.0:
                    continue
                if float(ter.sample(placer.ny, nx, nz)) < ny_min:
                    continue
                if not occ.free(nx, nz, rad):
                    continue
                best = (nx, nz)
                break
            if best is not None:
                break
        rec = by_name.setdefault(name, [0, 0])
        if best is None:
            drop.setdefault(name, set()).add(k)
            dropped += 1
            rec[1] += 1
            continue
        nx, nz = best
        placer.out[name][k] = [round(nx, 2), round(placer.ground_at(nx, nz) - sink, 2), round(nz, 2), yaw, sc]
        occ.add(nx, nz, rad)
        moved += 1
        rec[0] += 1
    for name, ks in drop.items():
        placer.out[name] = [v for k, v in enumerate(placer.out[name]) if k not in ks]
        if not placer.out[name]:
            del placer.out[name]
    return {"moved": moved, "dropped": dropped, "by_name": by_name}
