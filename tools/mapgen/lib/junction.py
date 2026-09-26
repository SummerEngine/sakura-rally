"""Junctions where the open branch road leaves a loop (at its start) or joins one (at its end).

The branch's first and last control points lie on the loop, so its centreline starts (ends)
on the loop's and leaves (joins) it tangentially. Around a junction:

  fork     the branch sample where the branch parts from the loop centreline;
  clear    the first (last) branch sample whose near carriageway edge is off the loop's
           carriageway: the branch ribbon is built from there on (up to there);
  mouth    between the two, the apron: one paved mesh from the loop's carriageway edge to the
           branch's far edge and its verge. Row 0 is the loop's own cross-section at the fork
           (edge, shoulder, verge, skirt vertices copied), the last row is the branch ribbon's
           first (last) row, so both seams share vertices; the inner edge runs on the loop's
           carriageway edge line (no step for the wheels, nothing coincident for the eye).
           The loop's verge on that side is left out along the mouth (loop_skip_quads).
  levelling  near the junction the branch centreline sits on the loop's surface (its height
           and bank continued), easing to its own profile 50 m past `clear`.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from . import geom
from .road import PROFILE, SURFACES, Road, road_height_at

LEVEL_BLEND = 50.0  # m past the clear point over which the branch eases from the loop surface
KEEP_CLEAR = 35     # loop samples beyond the mouth kept free of rails and signs on the branch side


@dataclass
class Junction:
    loop_id: str
    end: str          # "start": the branch leaves the loop; "end": it joins it
    fork_i: int       # branch sample at the fork
    clear_i: int      # branch sample where the branch ribbon starts / ends
    near: int         # side of the branch facing the loop (-1 left, +1 right)
    side_l: int       # side of the loop the branch is on
    loop_fork: int    # loop sample at the fork
    loop_clear: int   # loop sample beside the clear point

    @property
    def step(self) -> int:
        """Direction from the fork into the branch (branch sample order)."""
        return 1 if self.end == "start" else -1


def _nearest(road: Road, x: float, z: float) -> int:
    return int(np.argmin((road.pos[:, 0] - x) ** 2 + (road.pos[:, 2] - z) ** 2))


def _lateral(road: Road, j: int, x: float, z: float) -> float:
    return float((x - road.pos[j, 0]) * road.right[j, 0] + (z - road.pos[j, 2]) * road.right[j, 1])


def find(branch: Road, loop: Road, fork_cp: int, end: str, loop_id: str) -> Junction:
    n = len(branch.pos)
    fork_i = int(np.clip(round(branch.control_s[fork_cp]), 0, n - 1))
    step = 1 if end == "start" else -1
    it = fork_i + step * 30
    j = _nearest(loop, branch.pos[it, 0], branch.pos[it, 2])
    lat = _lateral(loop, j, branch.pos[it, 0], branch.pos[it, 2])
    side_l = 1 if lat > 0 else -1
    blat = _lateral(branch, it, loop.pos[j, 0], loop.pos[j, 2])
    near = 1 if blat > 0 else -1
    # at the fork the branch's near edge lies on the loop's far edge; it sweeps across the loop's
    # carriageway and is clear once it is past the loop's edge on the branch's side
    i = fork_i
    while 0 <= i + step < n:
        q = branch.pos[i, [0, 2]] + branch.right[i] * near * branch.half_width[i]
        jq = _nearest(loop, q[0], q[1])
        if _lateral(loop, jq, q[0], q[1]) * side_l >= loop.half_width[jq]:
            break
        i += step
    q = branch.pos[i, [0, 2]] + branch.right[i] * near * branch.half_width[i]
    return Junction(loop_id=loop_id, end=end, fork_i=fork_i, clear_i=i, near=near, side_l=side_l,
                    loop_fork=_nearest(loop, branch.pos[fork_i, 0], branch.pos[fork_i, 2]),
                    loop_clear=_nearest(loop, q[0], q[1]))


def _loop_surface(loop: Road, x: float, z: float) -> tuple[float, float]:
    """(height, bank) of the loop's surface continued under (x, z): its carriageway height at
    that lateral offset (clamped to the edge), its bank fading out across the carriageway."""
    j = _nearest(loop, x, z)
    lat = _lateral(loop, j, x, z)
    y = float(road_height_at(loop, np.array([j]), np.array([lat]))[0])
    return y, float(loop.bank[j]) * (1.0 - float(geom.smoothstep(0.0, loop.half_width[j], abs(lat))))


def level(branch: Road, loop: Road, J: Junction) -> None:
    """Sit the branch on the loop's surface through the mouth, then ease from the height it has
    at the clear point to its own profile past it, over LEVEL_BLEND m or more when the heights
    differ a lot (at most ~5% extra grade), in place."""
    n = len(branch.pos)
    # the mouth and the stub on the loop beyond the fork (never built, but it carves the ground)
    lo, hi = (0, J.clear_i) if J.end == "start" else (J.clear_i, n - 1)
    for i in range(lo, hi + 1):
        y_t, bank_t = _loop_surface(loop, branch.pos[i, 0], branch.pos[i, 2])
        branch.pos[i, 1] = y_t
        branch.bank[i] = bank_t
    y_c = branch.pos[J.clear_i, 1]
    bank_c = branch.bank[J.clear_i]
    probe = int(np.clip(J.clear_i + J.step * int(LEVEL_BLEND), 0, n - 1))
    blend = float(np.clip(30.0 * abs(y_c - branch.pos[probe, 1]), LEVEL_BLEND, 2.5 * LEVEL_BLEND))
    for k in range(1, int(blend) + 1):
        i = J.clear_i + J.step * k
        if not 0 <= i < n:
            break
        w = 1.0 - float(geom.smoothstep(0.0, blend, float(k)))
        branch.pos[i, 1] += (y_c - branch.pos[i, 1]) * w
        branch.bank[i] += (bank_c - branch.bank[i]) * w


def built_mask(branch: Road, junctions: list[Junction]) -> np.ndarray:
    """Branch samples whose ribbon exists (between the clear points)."""
    m = np.ones(len(branch.pos), dtype=bool)
    for J in junctions:
        if J.end == "start":
            m[:J.clear_i] = False
        else:
            m[J.clear_i + 1:] = False
    return m


def _side_cols(side: int) -> tuple[int, int, int, int]:
    """(edge, shoulder, verge, skirt) profile columns on a side."""
    return (7, 8, 9, 10) if side > 0 else (3, 2, 1, 0)


def loop_skip_quads(loop: Road, J: Junction) -> tuple[int, set]:
    """(side, quads) of the loop's verge left out along the mouth: quad k spans rows k, k+1.
    The quad before the fork row stays (its row is the apron's first row); two rows before the
    clear point the verge returns (it tucks under the apron's end and the gore)."""
    n = len(loop.pos)
    if J.end == "start":
        a, b = J.loop_fork, (J.loop_clear - 2) % n
    else:
        a, b = (J.loop_clear + 2) % n, J.loop_fork
    count = (b - a) % n
    return J.side_l, {(a + k) % n for k in range(count)}


def keep_clear(loop: Road, branch: Road, J: Junction, lmask: np.ndarray, bmask: np.ndarray) -> None:
    """Mark where no rail, sign or marker post may stand: the loop's branch side around the
    mouth and gore, and the branch's near side past the clear point (in place, [left, right])."""
    n = len(loop.pos)
    lo, hi = sorted((J.loop_fork, J.loop_clear))
    if (hi - lo) > n // 2:
        lo, hi = hi, lo + n
    col = 1 if J.side_l > 0 else 0
    for k in range(lo - KEEP_CLEAR, hi + KEEP_CLEAR + 1):
        lmask[k % n, col] = True
    nb = len(branch.pos)
    bcol = 1 if J.near > 0 else 0
    for k in range(40):
        i = J.clear_i + J.step * k
        if 0 <= i < nb:
            bmask[i, bcol] = True


def _edge_point(loop: Road, lverts: np.ndarray, col: int, x: float, z: float) -> np.ndarray:
    """The point of the loop's carriageway edge line (column col) nearest to (x, z)."""
    n = len(loop.pos)
    j = _nearest(loop, x, z)
    best = None
    for a, b in (((j - 1) % n, j), (j, (j + 1) % n)):
        if not loop.closed and (a < 0 or b >= n or b < a):
            continue
        A, B = lverts[a, col], lverts[b, col]
        e = B[[0, 2]] - A[[0, 2]]
        L2 = float(e @ e)
        t = 0.0 if L2 < 1e-12 else float(np.clip(((x - A[0]) * e[0] + (z - A[2]) * e[1]) / L2, 0.0, 1.0))
        P = A + (B - A) * t
        d = (P[0] - x) ** 2 + (P[2] - z) ** 2
        if best is None or d < best[0]:
            best = (d, P)
    return best[1]


def apron(branch: Road, loop: Road, J: Junction, bverts: np.ndarray, lverts: np.ndarray):
    """The mouth's paved mesh: (pos (m, 3), idx, verge weight per vertex (m,)). Rows run from
    the fork to the clear point; per row: five carriageway vertices from the loop's edge line
    to the branch's far edge (crowned like the ribbon by the last row), then the far side's
    shoulder, verge and skirt."""
    far = -J.near
    edge_l = _side_cols(J.side_l)
    far_cols = _side_cols(far)
    near_edge = _side_cols(J.near)[0]
    crown = 0.03 if branch.surface[J.clear_i] == SURFACES.index("tarmac") else 0.06
    rows = list(range(J.fork_i, J.clear_i + J.step, J.step))
    last = len(rows) - 1
    carriage = np.array([0.0, 0.25, 0.5, 0.75, 1.0])
    crown_prof = np.array([0.0, 0.6, 1.0, 0.6, 0.0]) * crown
    P = []
    for r, i in enumerate(rows):
        if r == 0:
            e = lverts[J.loop_fork, edge_l[0]]
            row = [e] * 5 + [lverts[J.loop_fork, c] for c in edge_l[1:]]
        elif r == last:
            cols = [near_edge, 4 if near_edge == 3 else 6, 5, 6 if near_edge == 3 else 4, far_cols[0]]
            row = [bverts[i, c] for c in cols] + [bverts[i, c] for c in far_cols[1:]]
        else:
            q = branch.pos[i, [0, 2]] + branch.right[i] * J.near * branch.half_width[i]
            inner = _edge_point(loop, lverts, edge_l[0], q[0], q[1])
            outer = bverts[i, far_cols[0]]
            t = float(geom.smoothstep(0.0, float(last), float(r)))
            row = [inner + (outer - inner) * u + np.array([0.0, crown_prof[k] * t, 0.0]) for k, u in enumerate(carriage)]
            row += [bverts[i, c] for c in far_cols[1:]]
        P.append(np.array(row))
    P = np.array(P)                       # (rows, 8, 3)
    nr, nc = P.shape[:2]
    pos = P.reshape(-1, 3)
    tris = []
    for r in range(nr - 1):
        for c in range(nc - 1):
            a, b = r * nc + c, r * nc + c + 1
            d, e = (r + 1) * nc + c, (r + 1) * nc + c + 1
            for t in ((a, b, e), (a, e, d)):
                if c == nc - 2:  # the skirt hangs under the ground: both windings
                    tris += [t, t[::-1]]
                    continue
                A, B, C = pos[t[0]], pos[t[1]], pos[t[2]]
                ny = np.cross(B - A, C - A)[1]
                if abs(ny) < 1e-7:
                    continue  # zero area (the fork row's collapsed carriageway)
                # Godot front faces are clockwise seen from the front (above)
                tris.append(t if ny < 0 else t[::-1])
    idx = np.array(tris, dtype=np.int64).ravel()
    verge = np.tile(np.array([0.0] * 6 + [1.0, 1.0]), nr)
    return pos, idx, verge
