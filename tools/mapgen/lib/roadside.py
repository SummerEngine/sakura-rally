"""Road safety for one road: the corners that need braking, their warning signs and chevron
boards, and the guardrails that keep a car that misses a corner on the road
(docs/CONTRACTS.md, "Corners").

Every function takes the road (lib.road.Road) and the terrain explicitly, never a global,
so a world with several roads calls them once per road:

    ground = Ground.from_terrain(ter)                         # or Ground(height=..., ...)
    corners = find_corners(road, opts)                        # speed profile -> corners
    runs = rail_runs(road, ground, corners, bounds, opts, keep_clear)   # RailRun list
    res = place_corner_signs(road, ground, corners, runs, placer, opts, keep_clear)
    ... scatter ...
    clear_sightlines(placer, manifest, res.sightlines, ..., authored)  # nothing rigid or leafy in front
    build_guardrails(road, runs, mb, boxes, post, rail)       # lib.road: meshes + colliders
    build_delineators(road, mb, white, red, skip=res.marker_skip)
    corners_json(road, corners, s_offset, res)                # map.json "corners"

`opts` is the road spec's optional "roadside" dict (see DEFAULTS); `bounds` is the play-area
half size (a float) or a callable (x, z) -> bool that is True inside the play area;
`keep_clear` is an optional (n, 2) bool array per road sample [left, right]: nothing (rail,
sign, marker post) is built on that side there (junction mouths).

Corners. A plausible speed profile (grip-limited corner speed per surface, power-limited
acceleration, firm braking, top speed) is run along the road; every local speed minimum
reached by braking at least BRAKE_DROP from the speed before it is a corner. Its extent is
where the curvature stays above a share of its peak; severity comes from its speed and how
far it turns: 1 fast (brake, curve arrow), 2 sharp (90 degree arrow), 3 hairpin (U arrow).

Rails. Where the edge drops (ground more than 2.6 m below the road 5 m past the verge, the v1
rule, or 3.5 m below it 12 m past the verge: an embankment a car rolls down), and
every corner casts miss lines: a car that stops turning anywhere between just before
turn-in and the apex runs straight on along the tangent, coasting, at 1.2 x the speed it
arrived with. If a line leaves the road where, before the car would stop, the ground is more
than DROP m below the road, water, or outside the play area, or the car would fly off the edge
and land more than DROP m lower, the outside of the corner gets a
rail from before turn-in to past where the lines cross the edge, and on as far as a car
scraping along it would leave it badly at its end. Runs merge across short gaps; the leading
end flares away and is buried, the trailing end dips into the ground, and an end at a bridge
tapers into its parapet.

Signs. Each corner gets a warning diamond (curve, sharp, hairpin; hairpins on both sides) 120-200
m before turn-in, at least 70 m before the braking point where there is room, placed where the
terrain and the props already standing leave it in view longest; a corner that follows the
previous one closely is announced by that one (the series sign when the next turns the other
way). Chevron boards stand on the outside from turn-in to the exit (on the rail where there is
one), more and bigger with severity; the marker posts they replace are skipped.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Callable

import numpy as np

from .corridor import SMASHABLE, WALLS
from .road import RAIL_BURY, RAIL_FACE, SURFACES, RailRun, Road, road_height_at

G = 9.81

DEFAULTS = {
    # lateral acceleration a plausible driver uses per surface (m/s^2); the cars' skidpad
    # limits are about 11.7 (tarmac) and 9.1 (gravel)
    "grip": {"tarmac": 10.0, "wood": 10.0, "gravel": 7.8, "dirt": 7.4},
    "brake": 8.5,          # m/s^2, firm braking (the cars stop from 100 km/h at ~14 m/s^2)
    "accel_power": 100.0,  # m^2/s^3: acceleration is min(accel_max, accel_power / v) - drag
    "accel_max": 6.0,
    "drag": 0.0004,        # 1/m
    "v_top": 50.0,         # m/s (180 km/h)
    "brake_drop": 3.5,     # m/s of braking that makes a corner (12.6 km/h)
    "min_angle": 12.0,     # degrees: a bend that turns less is a kink, whatever the braking
    "over_speed": 1.2,     # miss lines run at this multiple of the approach speed
    "coast": 0.6,          # m/s^2 lost coasting on the road
    "catch": 12.0,         # m/s: another stretch of road reached slower than this catches the car
    "scrape": 1.0,         # m/s^2 lost scraping along a rail (flyoff_probe: 106 -> 90 km/h in 4.5 s)
    "off_road": 2.2,       # m/s^2 lost rolling off the road (grass, gravel run-off), before slope
    "drop": 3.0,           # m below the road a missed corner must not end up
    "verge_drop": 2.6,     # v1 rule: ground this far below the road 5 m past the verge -> rail
    "bank_drop": 3.5,      # embankment: ground this far below the road 12 m past the verge -> rail
    "rail_gap": 20,        # m: rail runs closer than this merge
    "rail_min": 24,        # m: shortest rail run
    "flare": 8,            # m of flared end at a free rail end
    "rails": [],           # (s_from, s_to, side -1 left / +1 right), m along the road: rail a map
                           # asks for where the miss lines fall short (they run turn-in to apex only)
}

# prop names (tools/blender/props/corner.py); all but the rail-mounted boards are SMASHABLE
WARN_PROPS = {1: "corner_warn_curve", 2: "corner_warn_sharp", 3: "corner_warn_hairpin"}
WARN_SERIES = "corner_warn_series"  # a series of bends, the first one to that side
CHEVRON = "corner_chevron"
CHEVRON_RAIL = "corner_chevron_rail"
SIGN_PROPS = tuple(f"{p}_{d}" for p in (*WARN_PROPS.values(), WARN_SERIES, CHEVRON) for d in ("left", "right"))
MOUNTED_PROPS = tuple(f"{CHEVRON_RAIL}_{d}" for d in ("left", "right"))
KINDS = {1: "fast", 2: "sharp", 3: "hairpin"}

WARN_CENTRE = 3.05     # board centre height of a warning sign at scale 1 (m)
WARN_LATERAL = 1.3     # m past the verge at scale 1 (posts at +-0.55 m around it), times the scale
CHEVRON_LATERAL = 1.0  # m past the verge at scale 1, times the scale
CHEVRON_CENTRE = 1.65  # board centre height of a free-standing chevron at scale 1
# severity -> (chevron spacing m, minimum count, chevron scale, warning scale)
CHEVRON_SET = {1: (22.0, 3, 1.2, 1.4), 2: (15.0, 4, 1.35, 1.55), 3: (10.0, 5, 1.5, 1.7)}
EYE_HEIGHT = 1.2
SIGHT_DISTANCES = (220.0, 180.0, 150.0, 120.0, 90.0, 60.0)
SIGHT_CLEAR = 1.2      # m either side of a sightline kept free of rigid and leafy props
SERIES_ROOM = 60       # m: a corner closer than this after the previous one (25 m for one sharper than
                       # it) has no warning of its own; the first corner of such a series gets the
                       # series sign if the next one turns the other way
# categories that block a sign but are never removed for it (authored buildings); reported
KEEP_CATEGORIES = ("building", "village")
# authored props of these categories still make way for a sign (a spectator standing in the line)
MOVABLE_CATEGORIES = ("spectator",)
LOW_PROP = 1.6         # m: a prop lower than this does not hide a board (its bottom is >= 1.5 m up)
THIN_PROP = 0.25       # m: a post thinner than this (collider radius) does not hide a board


@dataclass
class Ground:
    """What the roadside needs to know about the world around one road. Every callable takes
    numpy arrays x, z (world metres) and returns an array of the same shape."""
    height: Callable                  # ground height (terrain, and paved lots where they cover it)
    wet: Callable | None = None       # True over water (lake, river)
    road_dist: Callable | None = None  # metres to the nearest road centreline of any road

    @classmethod
    def from_terrain(cls, ter, lots: list | None = None, lot_drop: float = 0.0) -> "Ground":
        """lib.terrain.Terrain (its road_dist field covers every road it was built with)."""
        def height(x, z):
            y = ter.height_at(x, z)
            for lot in lots or ():
                y = np.where(lot.sdf(np.asarray(x), np.asarray(z)) < 0.2, np.maximum(y, lot.y - lot_drop), y)
            return y

        def wet(x, z):
            w = ter.sample(ter.lake_sd, x, z) < 0.0
            if ter.water.river is not None:
                w |= ter.sample(ter.river_dist, x, z) < ter.water.river_width / 2.0
            return w

        return cls(height=height, wet=wet, road_dist=lambda x, z: ter.sample(ter.road_dist, x, z))


@dataclass
class Corner:
    brake: int       # sample where braking starts (speed profile peak before the corner)
    turn_in: int
    apex: int        # curvature peak
    exit: int
    dir: int         # +1 right-hander, -1 left-hander
    severity: int    # 1 fast, 2 sharp, 3 hairpin
    radius: float    # m at the apex
    angle: float     # degrees turned between turn-in and exit
    v_approach: float  # m/s at the braking point
    v_entry: float     # m/s at turn-in
    v_min: float       # m/s at the slowest point

    @property
    def outside(self) -> int:
        """Side of the outside of the corner: -1 left, +1 right of the driving direction."""
        return -self.dir


@dataclass
class SignResult:
    placed: dict = field(default_factory=dict)       # prop name -> count
    sightlines: list = field(default_factory=list)   # (x0, z0, x1, z1) eye -> board
    marker_skip: np.ndarray | None = None            # (n, 2) delineators left out [left, right]
    warnings: list = field(default_factory=list)     # per corner: m its warning is visible from,
                                                     # "series" (announced before) or None (no room)
    warn_at: list = field(default_factory=list)      # per corner: (sample, prop) of its warning or None


def _opts(opts: dict | None) -> dict:
    o = dict(DEFAULTS)
    for k, v in (opts or {}).items():
        o[k] = {**o[k], **v} if isinstance(o.get(k), dict) else v
    return o


# ------------------------------------------------------------------ index helpers

def _idx(road: Road, i: int) -> int:
    n = len(road.pos)
    return i % n if road.closed else int(np.clip(i, 0, n - 1))


def _ahead(road: Road, a: int, b: int) -> int:
    """Samples from a forward to b (a loop wraps; an open road may return a negative)."""
    return (b - a) % len(road.pos) if road.closed else b - a


def _span(road: Road, a: int, b: int) -> np.ndarray:
    """Sample indices from a forward to b inclusive."""
    n = len(road.pos)
    if road.closed:
        return (a + np.arange((b - a) % n + 1)) % n
    a, b = max(a, 0), min(b, n - 1)
    return np.arange(a, b + 1) if b >= a else np.zeros(0, dtype=np.int64)


def _in_bounds(bounds, x, z):
    if callable(bounds):
        return bounds(x, z)
    return np.maximum(np.abs(x), np.abs(z)) <= bounds


# ------------------------------------------------------------------ corners

def speed_profile(road: Road, opts: dict | None = None) -> np.ndarray:
    """Plausible speed (m/s) at every sample: grip-limited in corners, power-limited out of
    them, braking firmly before them, capped at the top speed."""
    o = _opts(opts)
    n = len(road.pos)
    grip = np.array([o["grip"][SURFACES[s]] for s in road.surface], dtype=np.float64)
    vlim = np.minimum(o["v_top"], np.sqrt(grip / np.maximum(np.abs(road.curv), 1e-6)))
    ds = np.diff(road.dist, append=road.length if road.closed else road.dist[-1] + 1.0)
    ds = np.maximum(ds, 1e-3)
    v = vlim.copy()
    laps = 2 if road.closed else 1
    pw, amax, drag, brk = o["accel_power"], o["accel_max"], o["drag"], o["brake"]
    for _ in range(laps):
        for i in range(1 if not road.closed else 0, n):
            j = i - 1
            vj = v[j]
            a = max(0.0, min(amax, pw / max(vj, 1.0)) - drag * vj * vj)
            v[i] = min(v[i], math.sqrt(vj * vj + 2.0 * a * ds[j]))
    for _ in range(laps):
        for i in range(n - 2 if not road.closed else n - 1, -1, -1):
            j = (i + 1) % n
            v[i] = min(v[i], math.sqrt(v[j] * v[j] + 2.0 * brk * ds[i]))
    return v


def find_corners(road: Road, opts: dict | None = None) -> list[Corner]:
    """Corners that need braking, in driving order from sample 0."""
    o = _opts(opts)
    n = len(road.pos)
    v = speed_profile(road, o)
    curv = road.curv
    ac = np.abs(curv)
    found: list[Corner] = []
    lo = 0 if road.closed else 1
    hi = n if road.closed else n - 1
    for m in range(lo, hi):
        vp, vn = v[(m - 1) % n], v[(m + 1) % n]
        if not (v[m] <= vp and v[m] < vn):
            continue
        # back to the braking point: speed rises going backwards
        b = m
        for _ in range(n):
            k = b - 1 if road.closed else max(b - 1, 0)
            k %= n
            if v[k] < v[b] - 1e-9 or k == b:
                break
            b = k
        if v[b] - v[m] < o["brake_drop"]:
            continue
        # apex: curvature peak between the braking point and just past the slowest point
        # (the speed bottoms out at the end of the tightest part), direction from its sign
        win = _span(road, b, _idx(road, m + 15))
        a = int(win[np.argmax(ac[win])])
        if ac[a] < 1.0 / 400.0:
            continue
        sgn = 1 if curv[a] > 0 else -1
        thr = max(0.4 * ac[a], 1.0 / 250.0)
        ti = a
        for _ in range(n):
            k = _idx(road, ti - 1)
            if k == ti or curv[k] * sgn < thr:
                break
            ti = k
        ex = a
        for _ in range(n):
            k = _idx(road, ex + 1)
            if k == ex or curv[k] * sgn < thr:
                break
            ex = k
        found.append((b, ti, a, ex, sgn, m))
    # merge corners of the same direction that overlap or nearly touch (double apex)
    found.sort(key=lambda c: road.dist[c[1]])
    merged: list[list] = []
    for c in found:
        if merged:
            p = merged[-1]
            gap = _ahead(road, p[3], c[1])
            if c[4] == p[4] and (gap <= 8 or _ahead(road, c[1], p[3]) >= 0 and gap > n // 2):
                slow = c if v[c[5]] < v[p[5]] else p
                p[:] = [p[0], p[1], slow[2], c[3] if _ahead(road, p[3], c[3]) < n // 2 else p[3], p[4], slow[5]]
                continue
        merged.append(list(c))
    if road.closed and len(merged) > 1:
        f, l = merged[0], merged[-1]
        if f[4] == l[4] and _ahead(road, l[3], f[1]) <= 8:
            slow = f if v[f[5]] < v[l[5]] else l
            merged[0] = [l[0], l[1], slow[2], f[3], f[4], slow[5]]
            merged.pop()
    out = []
    for b, ti, a, ex, sgn, m in merged:
        seg = _span(road, ti, ex)
        angle = float(np.degrees(np.sum(ac[seg])))
        radius = float(1.0 / ac[a])
        vmin = float(v[m])
        kmh = vmin * 3.6
        if angle < o["min_angle"]:
            continue  # a lift through a kink, not a corner
        if kmh < 50.0 or (angle >= 120.0 and radius <= 35.0):
            sev = 3
        elif kmh < 80.0 or (angle >= 70.0 and radius < 60.0):
            sev = 2
        else:
            sev = 1
        out.append(Corner(brake=int(b), turn_in=int(ti), apex=int(a), exit=int(ex), dir=int(sgn), severity=sev,
                          radius=radius, angle=angle, v_approach=float(max(v[b], v[ti])), v_entry=float(v[ti]),
                          v_min=vmin))
    return out


# ------------------------------------------------------------------ rails

def _miss_line(road: Road, ground: Ground, k: int, v0: float, bounds, o: dict,
               lat0: float = 0.0) -> tuple[bool, int, int, float, float]:
    """A car at sample k, lat0 m right of the centreline, runs straight on along the tangent at
    v0, coasting. Returns (danger, sample where it crosses the rail line, side it leaves by,
    drop m below the road, speed m/s at the crossing)."""
    reach = 260.0
    t = np.arange(1.0, reach, 1.0)
    fx, fz = road.fwd[k]
    px = road.pos[k, 0] + road.right[k, 0] * lat0
    pz = road.pos[k, 2] + road.right[k, 1] * lat0
    X, Z = px + fx * t, pz + fz * t
    win = _span(road, k, _idx(road, k + int(reach) + 60))
    wp = road.pos[win][:, [0, 2]]
    d2 = (X[:, None] - wp[None, :, 0]) ** 2 + (Z[:, None] - wp[None, :, 1]) ** 2
    near = np.argmin(d2, axis=1)
    j = win[near]
    lat = (X - road.pos[j, 0]) * road.right[j, 0] + (Z - road.pos[j, 2]) * road.right[j, 1]
    edge = road.half_width[j] + road.verge + RAIL_FACE
    off = np.nonzero(np.abs(lat) > edge)[0]
    if len(off) == 0:
        return False, -1, 0, 0.0, 0.0
    e = int(off[0])
    je = int(j[e])
    side = 1 if lat[e] > 0 else -1
    y_edge = float(road_height_at(road, np.array([je]), np.array([lat[e]]))[0])
    v2 = v0 * v0 - 2.0 * o["coast"] * t[e]
    v_edge = math.sqrt(max(v2, 0.0))
    H = ground.height(X[e:], Z[e:])
    dist = t[e:] - t[e]
    v2 = v2 - 2.0 * o["off_road"] * dist + 2.0 * G * (y_edge - H)
    stop = np.nonzero(v2 <= 0.0)[0]
    last = int(stop[0]) if len(stop) else len(H)
    # a steep bank (cut face) stops the car
    rise = H - y_edge
    slope = np.diff(H, prepend=H[0])
    wall = np.nonzero((rise > 1.0) & (slope > 0.6))[0]
    if len(wall):
        last = min(last, int(wall[0]))
    # another stretch of road at about this height catches a slow car; a fast one crosses it
    # (and flies off beyond, or into the traffic there): that is a miss to prevent
    crossing = False
    if ground.road_dist is not None:
        rd = ground.road_dist(X[e:], Z[e:])
        back = np.nonzero((rd < road.half_width.max()) & (np.abs(rise) < 2.0) & (dist > 6.0))[0]
        if len(back) and int(back[0]) < last:
            crossing = v2[int(back[0])] > o["catch"] ** 2
            last = int(back[0])
    # a jump: over ground falling away faster than the car's arc it flies, and lands this far down
    grade = float(road.pos[_idx(road, je + 1), 1] - road.pos[je, 1])
    arc = y_edge + grade * dist - G * dist * dist / (2.0 * max(v_edge, 1.0) ** 2)
    land = np.nonzero(H >= arc)[0]
    fall = float(y_edge - H[int(land[0])]) if len(land) else float(y_edge - H[-1])
    seg = slice(0, max(last, 1))
    # below the nearest stretch of this road (a car rolling down beside a descending road is
    # not falling off it)
    drop = float(np.max(road.pos[j[e:], 1][seg] - H[seg]))
    danger = drop > o["drop"] or fall > o["drop"] or crossing
    if not danger:
        inside = _in_bounds(bounds, X[e:][seg], Z[e:][seg])
        wet = ground.wet(X[e:][seg], Z[e:][seg]) if ground.wet is not None else np.zeros(1, dtype=bool)
        danger = bool((~np.asarray(inside)).any() or np.asarray(wet).any())
    return danger, je, side, drop, v_edge


def _scrape_along(road: Road, ground: Ground, want: np.ndarray, j: int, side: int, v: float, bounds,
                  o: dict) -> None:
    """A car that hit the rail at sample j at v scrapes along it (the wall keeps it aligned) and
    leaves it where the rail ends, straight on along the tangent there: extend the rail
    (want[:, col]) until that exit is safe or the car has stopped."""
    col = 0 if side < 0 else 1
    n = len(road.pos)
    for _ in range(600):
        if not road.closed and j >= n - 1:
            return
        j = _idx(road, j + 1)
        v = math.sqrt(max(v * v - 2.0 * o["scrape"], 0.0))
        if v < 4.0:
            return
        if want[j, col]:
            continue
        lat0 = side * (road.half_width[j] + road.verge + RAIL_FACE - 1.0)
        danger, _, s2, _, _ = _miss_line(road, ground, j, v, bounds, o, lat0)
        if not (danger and s2 == side):
            return
        want[j, col] = True


def _runs_from_mask(road: Road, want: np.ndarray, gap: int, min_len: int) -> list[tuple[int, int]]:
    """Index runs of `want`, closing gaps shorter than `gap` and dropping runs shorter than
    min_len (circular on a loop)."""
    n = len(want)
    if not want.any():
        return []
    if road.closed and want.all():
        return [(0, n - 1)]
    order = [(int(np.argmin(want)) + k) % n for k in range(n)] if road.closed else range(n)
    runs = []
    cur = None
    for k in order:
        if want[k]:
            if cur is None:
                cur = [k, k]
            else:
                cur[1] = k
        elif cur is not None:
            runs.append(cur)
            cur = None
    if cur is not None:
        runs.append(cur)
    merged: list[list[int]] = []
    for r in runs:
        g = (r[0] - merged[-1][1]) % n if (merged and road.closed) else (r[0] - merged[-1][1] if merged else n)
        if merged and g < gap:
            merged[-1][1] = r[1]
        else:
            merged.append(list(r))
    return [(a, b) for a, b in merged if _ahead(road, a, b) >= min_len]


def rail_runs(road: Road, ground: Ground, corners: list[Corner], bounds, opts: dict | None = None,
              keep_clear: np.ndarray | None = None) -> list[RailRun]:
    """Where guardrails go on this road (both sides): drops beside the verge and the outsides of
    corners whose miss lines end badly; never where keep_clear[i, side] is set."""
    o = _opts(opts)
    n = len(road.pos)
    want = np.zeros((n, 2), dtype=bool)  # [:, 0] left, [:, 1] right
    for c, side in enumerate((-1, 1)):
        lat = side * (road.half_width + road.verge + 5.0)
        gx = road.pos[:, 0] + road.right[:, 0] * lat
        gz = road.pos[:, 2] + road.right[:, 1] * lat
        want[:, c] |= (road.pos[:, 1] - ground.height(gx, gz)) > o["verge_drop"]
        lat = side * (road.half_width + road.verge + 12.0)
        gx = road.pos[:, 0] + road.right[:, 0] * lat
        gz = road.pos[:, 2] + road.right[:, 1] * lat
        want[:, c] |= (road.pos[:, 1] - ground.height(gx, gz)) > o["bank_drop"]
    for cn in corners:
        v0 = min(o["v_top"], cn.v_approach * o["over_speed"])
        hits = []
        for k in _span(road, _idx(road, cn.turn_in - 10), cn.apex)[::3]:
            danger, je, side, _, v_edge = _miss_line(road, ground, int(k), v0, bounds, o)
            if danger:
                hits.append((je, side, v_edge))
        for side in (-1, 1):
            js = [(je, ve) for je, s, ve in hits if s == side]
            if not js:
                continue
            # from before turn-in to past the farthest crossing (or the exit), then as far as a car
            # scraping along it needs
            jf, vf = max(js, key=lambda h: _ahead(road, cn.turn_in, h[0]) % n)
            far = max(jf, cn.exit, key=lambda j: _ahead(road, cn.turn_in, j) % n)
            span = _span(road, _idx(road, cn.turn_in - 15), _idx(road, far + 15))
            want[span, 0 if side < 0 else 1] = True
            _scrape_along(road, ground, want, jf, side, vf, bounds, o)
    for a, b, side in o["rails"]:
        want[_span(road, _idx(road, int(a)), _idx(road, int(b))), 0 if side < 0 else 1] = True
    ok = (road.bridge == "") & ~road.ford
    if road.on_lot is not None:
        ok &= road.on_lot < 0.5
    out: list[RailRun] = []
    for c, side in enumerate((-1, 1)):
        w = want[:, c] & ok
        if keep_clear is not None:
            w &= ~keep_clear[:, c]
        for a, b in _runs_from_mask(road, w, o["rail_gap"], o["rail_min"]):
            ends = []
            for end, step, free in ((a, -1, "flare"), (b, 1, "trail")):
                # a run that stops at a bridge tapers into its parapet; the leading end flares
                # away and is buried, the trailing end (cars pass it, never meet it) runs on
                # straight and dips into the ground so a car scraping along leaves it parallel
                near = [_idx(road, end + step * k) for k in range(1, 4)]
                ends.append("bridge" if any(road.bridge[i] != "" for i in near) else free)
            fl = o["flare"]
            a2 = _idx(road, a - (fl if ends[0] == "flare" else 3))
            b2 = _idx(road, b + (int(RAIL_BURY) if ends[1] == "trail" else 3))
            if road.closed and _ahead(road, a2, b2) >= n - 2 * fl:
                a2, b2, ends = a, _idx(road, a - 1), ["loop", "loop"]
            out.append(RailRun(a=a2, b=b2, side=side, a_end=ends[0], b_end=ends[1], flare=fl))
    return out


def rail_mask(road: Road, runs: list[RailRun]) -> np.ndarray:
    """(n, 2) True where a rail runs at full height (flares excluded) [left, right]."""
    n = len(road.pos)
    m = np.zeros((n, 2), dtype=bool)
    for r in runs:
        a = _idx(road, r.a + (r.flare if r.a_end == "flare" else 3)) if r.a_end != "loop" else r.a
        b = _idx(road, r.b - (int(RAIL_BURY) if r.b_end == "trail" else 3)) if r.b_end != "loop" else r.b
        m[_span(road, a, b), 0 if r.side < 0 else 1] = True
    return m


# ------------------------------------------------------------------ signs

def _point(road: Road, i: int, lat: float) -> tuple[float, float]:
    return (float(road.pos[i, 0] + road.right[i, 0] * lat), float(road.pos[i, 2] + road.right[i, 1] * lat))


def _visible(road: Road, ground: Ground, eye_i: int, x: float, y: float, z: float) -> bool:
    """Line of sight from a driver at sample eye_i to (x, y, z) clears the terrain."""
    e = road.pos[eye_i]
    ey = e[1] + EYE_HEIGHT
    L = math.hypot(x - e[0], z - e[2])
    k = max(2, int(L / 3.0))
    t = np.linspace(0.0, 1.0, k + 1)[1:-1]
    gx = e[0] + (x - e[0]) * t
    gz = e[2] + (z - e[2]) * t
    line = ey + (y - ey) * t
    return bool(np.all(ground.height(gx, gz) + 0.25 < line))


def _sight_distance(road: Road, ground: Ground, i: int, x: float, y: float, z: float) -> float:
    """Farthest distance back along the road from which (x, y, z) stays in view all the way in."""
    best = 0.0
    for D in sorted(SIGHT_DISTANCES):
        k = int(round(D))
        if not road.closed and i - k < 0:
            break
        if not _visible(road, ground, _idx(road, i - k), x, y, z):
            break
        best = D
    return best


def _free_ground(road: Road, ground: Ground, i: int, x: float, z: float, lat: float,
                 keep_clear: np.ndarray | None) -> bool:
    """A sign may stand here: not on a bridge, ford, lot or kept-clear side, no other road
    closer than this one, dry (1.5 m from water)."""
    if road.bridge[i] != "" or road.ford[i] or (road.on_lot is not None and road.on_lot[i] > 0.2):
        return False
    if keep_clear is not None and keep_clear[i, 0 if lat < 0 else 1]:
        return False
    if ground.road_dist is not None and float(ground.road_dist(np.array([x]), np.array([z]))[0]) < abs(lat) - 1.0:
        return False
    if ground.wet is not None:
        ring = np.array([0.0, 1.5, -1.5])
        if np.asarray(ground.wet(x + np.concatenate([ring, [0, 0]]), z + np.concatenate([[0, 0, 0], ring[1:]]))).any():
            return False
    return True


def place_corner_signs(road: Road, ground: Ground, corners: list[Corner], runs: list[RailRun], placer,
                       opts: dict | None = None, keep_clear: np.ndarray | None = None) -> SignResult:
    """Warning signs before and chevron boards through every corner, emitted into `placer`
    (lib.scatter.Placer: emit(), ground_at(), occ). Returns what was placed, the sightlines to
    keep clear (clear_sightlines) and the delineator posts the boards replace."""
    o = _opts(opts)
    n = len(road.pos)
    res = SignResult(marker_skip=np.zeros((n, 2), dtype=bool))
    mounted = rail_mask(road, runs)
    for r in runs:  # no marker posts along a rail
        res.marker_skip[_span(road, r.a, r.b), 0 if r.side < 0 else 1] = True
    warn_spots: list[tuple[float, float]] = []
    never_hide = set(SIGN_PROPS) | set(MOUNTED_PROPS) | SMASHABLE | WALLS

    def emit(name: str, x: float, z: float, yaw: float, sc: float, y: float | None = None) -> None:
        if placer.emit(name, x, z, yaw, sc, sink=0.05, y=y, radius=0.9):
            res.placed[name] = res.placed.get(name, 0) + 1

    def face(x: float, z: float, i: int) -> float:
        """Yaw that turns the board's front (-Z) towards the road centre at sample i."""
        p = road.pos[i]
        return math.atan2(-(p[0] - x), -(p[2] - z))

    # room before each corner (straight road after the previous corner's exit), and series:
    # corners with less than SERIES_ROOM before them are announced by the corner before
    rooms = []
    for ci, cn in enumerate(corners):
        prev = corners[ci - 1] if (ci > 0 or road.closed) and len(corners) > 1 else None
        room = _ahead(road, prev.exit, cn.turn_in) - 15 if prev is not None else n
        if room < -n // 2 or room > n:
            room = n
        if not road.closed:
            room = min(room, cn.turn_in - 20)
        rooms.append(room)
    follows = [(road.closed or ci > 0) and (rooms[ci] < 25 or rooms[ci] < SERIES_ROOM
                                            and cn.severity <= corners[ci - 1].severity)
               for ci, cn in enumerate(corners)]

    for ci, cn in enumerate(corners):
        spacing, min_count, ch_scale, w_scale = CHEVRON_SET[cn.severity]
        hand = "right" if cn.dir > 0 else "left"
        # ---------------------------------------------------------------- warning
        room = rooms[ci]
        series = []
        k = ci + 1
        while len(series) < len(corners) - 1 and follows[k % len(corners)] and (road.closed or k < len(corners)):
            series.append(corners[k % len(corners)])
            k += 1
        prop = f"{WARN_PROPS[cn.severity]}_{hand}"
        if series and series[0].dir != cn.dir:
            sev = max([cn.severity] + [c.severity for c in series])
            w_scale = CHEVRON_SET[sev][3]
            prop = f"{WARN_SERIES}_{hand}"
        brake_len = _ahead(road, cn.brake, cn.turn_in)
        if brake_len < 0 or brake_len > n // 2:
            brake_len = 0  # braking starts inside a long corner
        want = float(np.clip(brake_len + 70.0, 120.0, 200.0))
        want = min(want, room)
        best = None
        if not follows[ci] and want >= 25.0:
            for off in (0, -10, 10, -20, 20, -30, 30, -45, 45):
                d = want + off
                if d < 25.0 or d > room:
                    continue
                i = _idx(road, cn.turn_in - int(round(d)))
                for side in (cn.outside, -cn.outside):
                    lat = side * (road.half_width[i] + road.verge + WARN_LATERAL * w_scale)
                    x, z = _point(road, i, lat)
                    if not _free_ground(road, ground, i, x, z, lat, keep_clear):
                        continue
                    if any(math.hypot(x - a, z - b) < 8.0 for a, b in warn_spots):
                        continue
                    y = float(ground.height(np.array([x]), np.array([z]))[0]) + WARN_CENTRE * w_scale
                    vis = _sight_distance(road, ground, i, x, y, z)
                    lines = [(float(road.pos[_idx(road, i - D), 0]), float(road.pos[_idx(road, i - D), 2]), x, z)
                             for D in (150, 100, 50) if road.closed or i - D >= 0]
                    hidden = sum(int(h.sum()) for nm, mm, h in _sight_hits(placer, placer.manifest, lines, never_hide)
                                 if mm.get("category") not in MOVABLE_CATEGORIES)
                    score = vis - (25.0 if side != cn.outside else 0.0) - 0.4 * abs(off) - 60.0 * hidden \
                        - (15.0 if not placer.occ.free(x, z, 1.0) else 0.0)
                    if best is None or score > best[0]:
                        best = (score, i, side, x, z, vis)
        if best is not None:
            _, i, side, x, z, vis = best
            sides = (side, -side) if cn.severity == 3 or prop.startswith(WARN_SERIES) else (side,)
            for sd in sides:
                lat = sd * (road.half_width[i] + road.verge + WARN_LATERAL * w_scale)
                x, z = _point(road, i, lat)
                if sd != side and not _free_ground(road, ground, i, x, z, lat, keep_clear):
                    continue
                emit(prop, x, z, face(x, z, _idx(road, i - 60)), w_scale)
                warn_spots.append((x, z))
                for D in (150, 100, 50):
                    if road.closed or i - D >= 0:
                        e = road.pos[_idx(road, i - D)]
                        res.sightlines.append((float(e[0]), float(e[2]), x, z))
            res.warnings.append(vis)
            res.warn_at.append((int(i), prop))
        else:
            res.warnings.append("series" if follows[ci] else None)
            res.warn_at.append(None)
        # ---------------------------------------------------------------- chevrons
        a = _idx(road, cn.turn_in - 4)
        b = _idx(road, cn.exit + 6)
        length = max(_ahead(road, a, b), 1)
        count = max(min_count, int(length // spacing) + 1)
        col = 0 if cn.outside < 0 else 1
        for k in range(count):
            i = _idx(road, a + int(round(length * k / max(count - 1, 1))))
            if road.bridge[i] != "" or (road.on_lot is not None and road.on_lot[i] > 0.2):
                continue
            eye = _idx(road, i - 35)
            if mounted[i, col]:
                lat = cn.outside * (road.half_width[i] + road.verge + RAIL_FACE)
                x, z = _point(road, i, lat)
                y = float(road_height_at(road, np.array([i]), np.array([lat]))[0]) - 0.12
                emit(f"{CHEVRON_RAIL}_{hand}", x, z, face(x, z, eye), ch_scale, y=y)
            else:
                lat = cn.outside * (road.half_width[i] + road.verge + CHEVRON_LATERAL * ch_scale)
                x, z = _point(road, i, lat)
                if not _free_ground(road, ground, i, x, z, lat, keep_clear):
                    continue
                emit(f"{CHEVRON}_{hand}", x, z, face(x, z, eye), ch_scale)
            e = road.pos[eye]
            res.sightlines.append((float(e[0]), float(e[2]), x, z))
        res.marker_skip[_span(road, _idx(road, cn.turn_in - 10), _idx(road, cn.exit + 10)), col] = True
    return res


def _sight_hits(placer, manifest: dict, sightlines: list, skip=frozenset()):
    """Per prop name that can hide a board (rigid or leafy, tall, not a thin post): a bool
    array over its placed instances, True within SIGHT_CLEAR of one of the sightlines
    (x0, z0, x1, z1), the board's own last 1.5 m excepted. Yields (name, manifest entry, hit)."""
    seg = np.array(sightlines, dtype=np.float64).reshape(-1, 4)
    ax, az, bx, bz = seg[:, 0], seg[:, 1], seg[:, 2], seg[:, 3]
    dx, dz = bx - ax, bz - az
    L2 = np.maximum(dx * dx + dz * dz, 1e-6)
    lo = np.minimum(ax, bx) - 8.0, np.minimum(az, bz) - 8.0
    hi = np.maximum(ax, bx) + 8.0, np.maximum(az, bz) + 8.0
    for name in list(placer.out.keys()):
        if name in skip:
            continue
        m = manifest.get(name, {})
        cat = m.get("category", "")
        col = m.get("collision", {})
        rigid = col.get("type", "none") != "none"
        leafy = cat in ("tree", "vegetation") and m.get("footprint_radius", 0.0) >= 0.8
        if not (rigid or leafy) or cat == "ground_cover" or not placer.out[name]:
            continue
        inst = np.array(placer.out[name], dtype=np.float64)
        px, pz, sc = inst[:, 0], inst[:, 2], inst[:, 4]
        rad = m.get("footprint_radius", 1.0) * 0.6 * sc
        tall = float(m.get("size", [0.0, 9.0, 0.0])[1]) * sc >= LOW_PROP
        if not leafy and col.get("type") == "cylinder" and len(col.get("offsets", [0])) == 1:
            tall &= float(col.get("radius", 1.0)) * sc >= THIN_PROP
        hit = np.zeros(len(inst), dtype=bool)
        for k in range(len(seg)):
            near = (px > lo[0][k]) & (px < hi[0][k]) & (pz > lo[1][k]) & (pz < hi[1][k]) & tall
            if not near.any():
                continue
            t = np.clip(((px - ax[k]) * dx[k] + (pz - az[k]) * dz[k]) / L2[k], 0.0, 1.0)
            t = np.minimum(t, 1.0 - 1.5 / math.sqrt(L2[k]))
            d = np.hypot(px - (ax[k] + dx[k] * t), pz - (az[k] + dz[k] * t))
            hit |= near & (d < SIGHT_CLEAR + rad)
        if hit.any():
            yield name, m, hit


def clear_sightlines(placer, manifest: dict, sightlines: list, smashable=frozenset(),
                     walls=frozenset(), authored: dict | None = None) -> dict:
    """Remove scattered rigid and leafy props standing within SIGHT_CLEAR of a sightline
    (tarmac to board). Authored props stay and are reported as blocking: buildings
    (KEEP_CATEGORIES) and the first authored[name] instances of each prop (placer.out lists
    grow in placement order: snapshot the counts after the features, before the scatter).
    Returns {"removed": {name: n}, "blocking": {name: [(x, z), ...]}}."""
    removed: dict[str, int] = {}
    blocking: dict[str, list] = {}
    if not sightlines:
        return {"removed": removed, "blocking": blocking}
    skip = set(SIGN_PROPS) | set(MOUNTED_PROPS) | set(smashable) | set(walls)
    for name, m, hit in list(_sight_hits(placer, manifest, sightlines, skip)):
        cat = m.get("category", "")
        keep = len(hit) if cat in KEEP_CATEGORIES else \
            0 if cat in MOVABLE_CATEGORIES else min((authored or {}).get(name, 0), len(hit))
        if hit[:keep].any():
            blocking[name] = [(round(v[0]), round(v[2])) for v, h in zip(placer.out[name][:keep], hit[:keep]) if h]
        hit[:keep] = False
        if not hit.any():
            continue
        removed[name] = int(hit.sum())
        placer.out[name] = [v for v, h in zip(placer.out[name], hit) if not h]
        if not placer.out[name]:
            del placer.out[name]
    return {"removed": removed, "blocking": blocking}


# ------------------------------------------------------------------ export

def _pose(road: Road, i: int, s_offset: float) -> dict:
    p = road.pos[i]
    return {"pos": [round(float(p[0]), 2), round(float(p[1]), 2), round(float(p[2]), 2)],
            "yaw": round(float(math.atan2(-road.fwd[i, 0], -road.fwd[i, 1])), 4),
            "s": round(float(_s(road, i, s_offset)), 1)}


def _s(road: Road, i: int, s_offset: float) -> float:
    s = float(road.dist[i]) - s_offset
    return s % road.length if road.closed else s


def corners_json(road: Road, corners: list[Corner], s_offset: float = 0.0, signs: SignResult | None = None,
                 path_step: int = 4) -> list[dict]:
    """map.json "corners": per corner its kind, speeds (km/h), poses (world, with s along the
    route: road distance minus s_offset), its warning sign (`warning`: the road pose beside it,
    the prop and the distance it is in view from; null when the corner before announces it or
    there is no room) and `path`, the centreline [x, y, z, half width] from 20 m before turn-in
    to 150 m past the exit (every path_step m) for tools that judge where a car that missed it
    ended up (tools/physics/flyoff_probe.gd)."""
    out = []
    for ci, c in enumerate(corners):
        warning = None
        if signs is not None and signs.warn_at[ci] is not None:
            wi, prop = signs.warn_at[ci]
            warning = {**_pose(road, wi, s_offset), "prop": prop, "visible_m": signs.warnings[ci]}
        mid = _idx(road, c.turn_in + _ahead(road, c.turn_in, c.apex) // 2)
        path = _span(road, _idx(road, c.turn_in - 20), _idx(road, c.exit + 150))[::path_step]
        out.append({
            "dir": "right" if c.dir > 0 else "left", "severity": c.severity, "kind": KINDS[c.severity],
            "radius": round(c.radius, 1), "angle": round(c.angle, 1),
            "v_approach": round(c.v_approach * 3.6, 1), "v_entry": round(c.v_entry * 3.6, 1),
            "v_min": round(c.v_min * 3.6, 1),
            "brake": _pose(road, c.brake, s_offset), "turn_in": _pose(road, c.turn_in, s_offset),
            "mid": _pose(road, mid, s_offset), "apex": _pose(road, c.apex, s_offset),
            "exit": _pose(road, c.exit, s_offset), "warning": warning,
            "path": [[round(float(road.pos[i, 0]), 2), round(float(road.pos[i, 1]), 2),
                      round(float(road.pos[i, 2]), 2), round(float(road.half_width[i]), 2)] for i in path],
        })
    return out


def summary(corners: list[Corner], runs: list[RailRun], road: Road) -> str:
    kinds = {k: sum(1 for c in corners if c.severity == k) for k in (1, 2, 3)}
    rail_m = sum(_ahead(road, r.a, r.b) for r in runs)
    return (f"{len(corners)} corners (fast {kinds[1]}, sharp {kinds[2]}, hairpin {kinds[3]}), "
            f"{len(runs)} rail runs, {rail_m} m of rail")
