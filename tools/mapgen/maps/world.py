"""The world: Hanami Pass at the origin, Momiji Valley to the east, and the branch road
between them through the seasons (the summer country that used to be the Natsu liaison map).

Hanami (maps/hanami.py) keeps its own coordinates. Momiji (maps/momiji.py) is turned a
quarter to the left and moved east, so its village and the end of its descent face Hanami.
The branch leaves the Hanami loop on the right 185 m after the start/finish line (Hanami's
finish_stop sits 35 m before the fork, the hanami_branch gate in view down the branch), runs
east among sakura, climbs past terraced rice paddies to a farm on a low crest, drops to a stone
bridge over the Kawabata stream, runs through the summer-festival village, along the forest
edge into the maples, past the Momiji time control and service park, and joins the Momiji loop
from the right 245 m before its start line (the momiji_branch gate just before the fork).

Seasons run along the Hanami -> Momiji axis: spring (Hanami), summer (the middle), autumn
(Momiji). The same weights pick each region's relief, palette and scatter rules, so the ground,
the trees and the season grid the runtime reads agree everywhere.
"""
from __future__ import annotations

import math

import numpy as np

from lib.region import Frame, place
from lib.road import build_road
from lib.scatter import SPECTATOR_WEIGHTS, SPECTATORS
from maps import hanami, momiji

HANAMI_FRAME = Frame()
MOMIJI_FRAME = Frame(2150.0, 440.0, -math.pi / 2)

HANAMI = place(hanami.SPEC, HANAMI_FRAME)
MOMIJI = place(momiji.SPEC, MOMIJI_FRAME)

# ------------------------------------------------------------------------------ the forks

_HR = build_road(HANAMI["road"])
_MR = build_road(MOMIJI["road"])
HANAMI_START_S = float(_HR.control_s[HANAMI["road"]["start_cp"]])
MOMIJI_START_S = float(_MR.control_s[MOMIJI["road"]["start_cp"]])
FORK_H = HANAMI_START_S + 185.0   # branch leaves the Hanami loop here (loop distance)
FORK_M = MOMIJI_START_S - 230.0   # and joins the Momiji loop here
FINISH_STOP = 150.0               # m past each stage's finish line


def _loop_point(road, s: float):
    s %= road.length
    x = float(np.interp(s, road.dist, road.pos[:, 0]))
    z = float(np.interp(s, road.dist, road.pos[:, 2]))
    y = float(np.interp(s, road.dist, road.pos[:, 1]))
    i = int(round(s)) % len(road.pos)
    return x, z, y, road.fwd[i].copy()


def _fork(road, s: float, turn: float, radius: float, sweep_deg: float, step: float = 7.0,
          leaving: bool = True) -> list[tuple]:
    """Control points of an arc tangent to a loop at distance s: leaving it (arc starts at the
    loop, turning `turn` = +1 right / -1 left) or joining it (arc ends at the loop, having
    turned `turn`). Includes two points on the loop before a leaving arc / after a joining
    one, so the spline's tangent at the fork is the loop's."""
    x0, z0, y0, f = _loop_point(road, s)
    sweep = math.radians(sweep_deg)
    n = max(2, int(math.ceil(radius * sweep / step)))
    pts = []
    h = math.atan2(f[1], f[0])  # heading angle in the x-z plane (z south: + turns right)
    if leaving:
        for back in (20.0, 10.0):
            xb, zb, yb, _ = _loop_point(road, s - back)
            pts.append((xb, zb, yb))
        pts.append((x0, z0, y0))
        cx = x0 - math.sin(h) * radius * turn
        cz = z0 + math.cos(h) * radius * turn
        for k in range(1, n + 1):
            a = h + turn * sweep * k / n
            # heights follow the loop alongside (the arc's length ~ the loop distance)
            yk = _loop_point(road, s + radius * sweep * k / n)[2]
            pts.append((cx + math.sin(a) * radius * turn, cz - math.cos(a) * radius * turn, yk))
    else:
        # the arc ends at the loop heading h; walk it backwards
        cx = x0 - math.sin(h) * radius * turn
        cz = z0 + math.cos(h) * radius * turn
        for k in range(n, 0, -1):
            a = h - turn * sweep * k / n
            yk = _loop_point(road, s - radius * sweep * k / n)[2]
            pts.append((cx + math.sin(a) * radius * turn, cz - math.cos(a) * radius * turn, yk))
        pts.append((x0, z0, y0))
        for fwd in (10.0, 20.0):
            xf, zf, yf, _ = _loop_point(road, s + fwd)
            pts.append((xf, zf, yf))
    return pts


_LEAVE = _fork(_HR, FORK_H, +1.0, 48.0, 44.0)
_JOIN = _fork(_MR, FORK_M, +1.0, 64.0, 40.0, leaving=False)

# Hand-placed waypoints between the forks: (x, z, target height, {attributes}), named for the
# dressing. Heights near the forks are levelled to the loops by the compiler.
_WAY = [
    ("sakura_1", 150, 334, 21.5),
    ("sakura_2", 235, 350, 23.0),
    ("sakura_3", 325, 348, 25.0),
    ("sakura_4", 415, 328, 27.5),
    ("orchard", 505, 318, 30.0),
    ("terrace_foot", 595, 332, 33.5),
    ("terrace_1", 675, 362, 38.0),
    ("terrace_2", 752, 382, 42.5),
    ("farm", 832, 380, 45.5),
    ("crest", 905, 352, 45.0),
    ("drop_1", 968, 322, 41.0),
    ("drop_2", 1030, 318, 36.0),
    ("bridge_in", 1112, 340, 31.0, {"bridge": "stone"}),
    ("bridge_mid", 1135, 344, 31.4),
    ("bridge_out", 1158, 348, 31.0, {"bridge": None}),
    ("village_in", 1215, 362, 31.0),
    ("festival", 1285, 372, 31.5),
    ("shrine_gate", 1355, 370, 32.0),
    ("village_out", 1420, 356, 32.5),
    ("forest_edge", 1480, 330, 33.5),
    ("maples_1", 1530, 296, 35.5),
    ("tc_approach", 1575, 262, 37.5),
    ("tc", 1620, 240, 39.0),
]
WP = {}
_POINTS = []
for p in _LEAVE:
    _POINTS.append(p)
for w in _WAY:
    WP[w[0]] = len(_POINTS)
    _POINTS.append(tuple(w[1:]))
WP["join"] = len(_POINTS)
for p in _JOIN:
    _POINTS.append(p)
# the fork control points: the branch's first sample sits on the Hanami loop 20 m before the
# fork, its last on the Momiji loop 20 m after its fork (the part on the loops is never built;
# the junction aprons pave the mouths)
FORK_CP_H = 2
FORK_CP_M = len(_POINTS) - 3

# ------------------------------------------------------------------------------ dressing

FLAGS = ["flag_pole_pink", "flag_pole", "flag_pole_blue"]


def one(prop, cp, off, lat, face="road", **kw):
    return {"kind": "single", "prop": prop, "road_at": cp, "offset_m": off, "lateral": lat, "face": face, **kw}


def at(prop, x, z, face=0.0, **kw):
    return {"kind": "single", "prop": prop, "pos": (x, z), "face": face, **kw}


def row(props, cp, a, b, lat, spacing, sides=(1,), face="road_side", cp_to=None, **kw):
    kw.setdefault("sink", 0.12)
    props = [props] if isinstance(props, str) else list(props)
    return {"kind": "line", "props": props, "from_cp": cp, "from_offset": a, "to_cp": cp if cp_to is None else cp_to,
            "to_offset": b, "lateral": lat, "spacing": spacing, "sides": list(sides), "face": face, **kw}


def line(props, a, b, spacing, face="along", **kw):
    props = [props] if isinstance(props, str) else list(props)
    return {"kind": "row", "props": props, "from": a, "to": b, "spacing": spacing, "face": face, **kw}


def crowd(cp, off, lat, count, radius=5.0, face="road", clear=8.0, **kw):
    return {"kind": "group", "props": SPECTATORS, "weights": SPECTATOR_WEIGHTS, "count": count,
            "road_at": cp, "offset_m": off, "lateral": lat, "radius": radius, "road_clear": clear, "face": face,
            "yaw_jitter": 22.0, "scale": (0.95, 1.05), "sink": 0.05, **kw}


def house(prop, cp, off, lat, yaw_add=0.0):
    r = {"farmhouse_a": 9.0, "farmhouse_b": 9.0, "kura": 4.5, "shed": 3.4}[prop]
    return one(prop, cp, off, lat, "road", sink=0.35, radius=r, yaw_add=yaw_add)


def stall(cp, off, side, vending=True):
    """A festival stall (yatai): tent facing the street, bench, lantern string, sometimes a
    vending machine at the side."""
    f = [one("tent", cp, off, side * 13.0, "road"),
         one("bench", cp, off + 2.6, side * 10.2, "road", yaw_add=90.0 * side),
         one("lantern_string", cp, off, side * 10.0, "along")]
    if vending:
        f.append(one("vending_machine", cp, off - 3.0, side * 12.2, "road"))
    return f


def bale_stack(cp, off, lat, face="road_side"):
    return [one("hay_bale_square", cp, off - 1.0, lat, face), one("hay_bale_square", cp, off + 1.0, lat, face),
            one("hay_bale_square", cp, off, lat, face, y_offset=0.8, yaw_add=6.0)]


def _dressing():
    w = WP
    f = []
    # --------------------------------------------------------- leaving Hanami among the sakura
    # heading east-south-east; the lake is to the right (+), the loop's climb to the left
    f += [one("stone_lantern", w["sakura_1"], -8.0, 8.2, "road"), one("stone_lantern", w["sakura_1"], -8.0, -8.2, "road"),
          one("jizo", w["sakura_1"], 30.0, -8.2, "road"), one("hokora", w["sakura_1"], 32.5, -8.8, "road"),
          one("sakura_young", w["sakura_2"], -20.0, 11.0, "road"), one("bench", w["sakura_2"], -4.0, 9.4, "road"),
          one("bench", w["sakura_2"], 2.0, 9.4, "road")]
    f.append(row("telephone_pole", w["sakura_1"], 20.0, 0.0, -8.4, 36.0, face="road_side", cp_to=w["terrace_1"]))
    # an orchard farm where the blossom thins out
    f += [house("farmhouse_b", w["orchard"], -10.0, 22.0), house("kura", w["orchard"], 8.0, 20.0),
          house("shed", w["orchard"], -26.0, -17.0), one("kei_truck", w["orchard"], 4.0, 12.5, "along", yaw_add=170.0),
          one("water_well", w["orchard"], -2.0, 14.0, "road"), one("koinobori", w["orchard"], -18.0, 16.0, "road", yaw_add=40.0),
          row("fence_wood", w["orchard"], -28.0, 18.0, 10.6, 2.05, face="road_side")]

    # --------------------------------------------------------- the terraces (summer)
    # the paddies step down the slope on the right (+) of the climb
    f += [one("bus_stop", w["terrace_foot"], 6.0, -9.2, "road"), one("bench", w["terrace_foot"], 6.0, -11.8, "road"),
          one("vending_machine", w["terrace_foot"], 10.5, -8.8, "road"),
          one("jizo", w["terrace_1"], -6.0, -8.2, "road"), one("stone_lantern", w["terrace_1"], -8.0, -8.4, "road", scale=0.8),
          one("road_mirror", w["terrace_2"], 10.0, -6.8, "road")]
    f += [at("scarecrow", 700.0, 440.0, 160.0), at("scarecrow", 780.0, 452.0, 200.0), at("scarecrow", 640.0, 418.0, 120.0),
          at("shed", 820.0, 468.0, 250.0, radius=3.4), at("kei_truck", 806.0, 480.0, 160.0),
          at("hazagi", 735.0, 470.0, 20.0), at("hazagi", 668.0, 452.0, 10.0)]
    f += [at("rice_paddy_marker", x, z, 0.0) for (x, z) in
          ((630, 400), (670, 425), (720, 418), (760, 440), (800, 432), (700, 470), (745, 492), (655, 470))]
    # the farm on the crest: house, storehouse, well, a truck by the barn
    f += [house("farmhouse_b", w["farm"], 8.0, -22.0), house("kura", w["farm"], 24.0, -20.0),
          one("water_well", w["farm"], -4.0, -14.0, "road"), house("shed", w["farm"], -14.0, -17.0),
          one("kei_truck", w["farm"], 18.0, -11.0, "along", yaw_add=175.0),
          one("maple_green", w["farm"], -24.0, -22.0, "road"), one("bamboo_clump", w["farm"], 38.0, -24.0, "road"),
          row("stone_wall", w["farm"], -20.0, 30.0, -10.2, 2.0, face="road_side")]
    f += [one("road_mirror", w["drop_1"], 6.0, -6.8, "road")]
    f.append(row("telephone_pole", w["farm"], 10.0, 0.0, 8.2, 38.0, face="road_side", cp_to=w["bridge_in"]))

    # --------------------------------------------------------- the stone bridge over the Kawabata
    f += [one("stone_lantern", w["bridge_in"], -6.0, 7.4, "road"), one("stone_lantern", w["bridge_in"], -6.0, -7.4, "road"),
          one("stone_lantern", w["bridge_out"], 6.0, 7.4, "road"), one("stone_lantern", w["bridge_out"], 6.0, -7.4, "road"),
          one("jizo", w["bridge_out"], 12.0, 8.2, "road"), one("jizo", w["bridge_out"], 12.8, 8.2, "road"),
          one("maple_green", w["bridge_in"], -16.0, 13.0, "road"), one("bamboo_clump", w["bridge_out"], 16.0, -14.0, "road")]

    # --------------------------------------------------------- the festival village, heading east
    # right (+) is the south side with the shrine, towards the river; left (-) the north side
    f.append({"kind": "clear", "road_at": w["festival"], "offset_m": 0.0, "lateral": 0.0, "radius": 6.0})
    f += [house("farmhouse_a", w["village_in"], 26.0, -22.0), house("kura", w["village_in"], 42.0, -20.0),
          house("farmhouse_b", w["festival"], 22.0, -23.0, yaw_add=6.0), house("shed", w["festival"], 38.0, -16.0),
          house("farmhouse_a", w["shrine_gate"], -34.0, -23.0), house("kura", w["shrine_gate"], -18.0, -21.0),
          house("farmhouse_b", w["shrine_gate"], 34.0, -23.0), house("farmhouse_a", w["village_out"], 10.0, -22.0),
          house("farmhouse_b", w["village_in"], 30.0, 22.0), house("farmhouse_a", w["festival"], 10.0, 23.0),
          house("kura", w["festival"], 26.0, 20.0), house("farmhouse_b", w["festival"], -26.0, 23.0),
          house("farmhouse_a", w["village_out"], -12.0, 23.0), house("shed", w["village_out"], 6.0, 17.0)]
    f += [one("torii_large", w["shrine_gate"], 0.0, 15.5, "road"),
          one("shrine", w["shrine_gate"], 0.0, 42.0, "road", sink=0.35, radius=7.0),
          one("shrine_bell", w["shrine_gate"], -10.0, 34.0, "road"), one("hokora", w["shrine_gate"], 10.0, 33.0, "road"),
          one("stone_lantern", w["shrine_gate"], -3.5, 20.5, "road"), one("stone_lantern", w["shrine_gate"], 3.5, 20.5, "road"),
          one("stone_lantern", w["shrine_gate"], -3.5, 27.0, "road"), one("stone_lantern", w["shrine_gate"], 3.5, 27.0, "road"),
          one("bamboo_clump", w["shrine_gate"], -16.0, 48.0, "road"), one("bamboo_clump", w["shrine_gate"], 16.0, 50.0, "road"),
          one("maple_green", w["shrine_gate"], -14.0, 22.0, "road"), one("maple_green", w["shrine_gate"], 15.0, 23.0, "road")]
    f += [one("jizo", w["shrine_gate"], 7.0 + 0.8 * k, 9.4, "road") for k in range(4)]
    f += stall(w["village_in"], 50.0, 1) + stall(w["village_in"], 60.0, 1, vending=False) + stall(w["festival"], -18.0, 1)
    f += stall(w["festival"], 14.0, -1) + stall(w["festival"], 44.0, -1, vending=False) + stall(w["shrine_gate"], 14.0, -1)
    f += stall(w["shrine_gate"], 22.0, 1, vending=False) + stall(w["shrine_gate"], -20.0, -1, vending=False)
    f += [row("lantern_string", w["village_in"], 18.0, 0.0, 9.6, 11.0, sides=(-1, 1), cp_to=w["village_out"])]
    f += [crowd(w["village_in"], 56.0, 15.0, 7, 4.0, clear=7.5, face="random"),
          crowd(w["festival"], 18.0, -15.0, 7, 4.0, clear=7.5, face="random"),
          crowd(w["shrine_gate"], 6.0, 12.5, 6, 3.5, clear=7.0, face="random"),
          crowd(w["shrine_gate"], -18.0, -15.0, 5, 3.5, clear=7.5, face="random"),
          crowd(w["festival"], -18.0, 15.5, 4, 3.0, clear=7.5, face="random")]
    f += [one("bus_stop", w["village_out"], 18.0, 9.2, "road"), one("bench", w["village_out"], 18.0, 11.8, "road"),
          one("water_well", w["festival"], 26.0, 13.0, "road"), one("kei_truck", w["festival"], 34.0, 12.5, "along", yaw_add=6.0),
          one("kei_truck", w["village_in"], 14.0, -12.5, "along", yaw_add=178.0)]
    f.append(row("telephone_pole", w["village_in"], 0.0, 0.0, -8.4, 34.0, face="road_side", cp_to=w["forest_edge"]))
    f += [row(["azalea", "bush_b", "azalea"], w["village_in"], 20.0, 60.0, -10.2, 3.2, sides=(-1,), sink=0.1),
          row(["azalea", "bush_a"], w["festival"], 36.0, 60.0, -10.2, 3.2, sides=(-1,), sink=0.1),
          row(["azalea", "bush_b"], w["village_out"], -4.0, 30.0, 10.2, 3.0, sides=(1,), sink=0.1),
          row("stone_wall", w["festival"], 0.0, 16.0, -14.6, 2.0, face="road_side"),
          row("fence_bamboo", w["village_out"], -30.0, -16.0, 14.4, 2.05, face="road_side")]
    # lowland paddies between the village and the river
    f += [at("scarecrow", 1260.0, 440.0, 30.0), at("scarecrow", 1340.0, 452.0, -40.0),
          at("shed", 1392.0, 430.0, 200.0, radius=3.4)]
    f += [at("rice_paddy_marker", x, z, 0.0) for (x, z) in ((1230, 432), (1290, 450), (1320, 428), (1370, 440))]

    # --------------------------------------------------------- forest edge into the maples
    f += [one("road_mirror", w["forest_edge"], 8.0, -6.8, "road"),
          one("stone_lantern", w["maples_1"], 20.0, 8.6, "road", scale=0.8), one("jizo", w["maples_1"], 22.0, 8.4, "road"),
          one("log", w["maples_1"], -10.0, -12.5, "along"), one("log", w["maples_1"], -10.0, -13.2, "along"),
          one("log", w["maples_1"], -9.7, -12.85, "along", y_offset=0.5)]

    # --------------------------------------------------------- Momiji Valley time control and service park
    # heading east; the park is on the right (+), spectators on the left
    tc = w["tc"]
    f += [one("flag_pole_pink", w["tc_approach"], -20.0, 8.8, "road_side"),
          one("flag_pole_blue", w["tc_approach"], -20.0, -8.8, "road_side"),
          one("marshal_post", tc, -6.0, -9.6, "road"), one("marshal_post", tc, 4.0, 9.8, "road"),
          one("traffic_cone", tc, -14.0, -6.4, "road"), one("traffic_cone", tc, -10.0, -6.4, "road"),
          one("traffic_cone", tc, 22.0, -6.4, "road"), one("traffic_cone", tc, 30.0, -6.4, "road")]
    f += [one("tent", tc, -22.0, 33.0, "road"), one("tent", tc, -12.0, 34.0, "road", yaw_add=4.0),
          one("tent", tc, 0.0, 33.5, "road"), one("tent", tc, 12.0, 34.0, "road", yaw_add=-3.0),
          one("tire_stack", tc, -17.0, 31.0, "road"), one("tire_stack", tc, -16.2, 31.6, "road"),
          one("tire_stack", tc, -6.0, 31.4, "road"),
          one("bench", tc, 6.0, 30.0, "road"), one("vending_machine", tc, -30.0, 32.0, "road"),
          one("kei_truck", tc, -30.0, 22.0, "along", yaw_add=175.0)]
    f += [row("banner_fence", tc, -36.0, 30.0, 38.4, 3.1, face="road_side"),
          row(FLAGS, tc, -34.0, 30.0, 40.5, 8.0),
          row(FLAGS, w["tc_approach"], -30.0, 20.0, 8.8, 10.0, sides=(1,))]
    f += bale_stack(tc, -26.0, -8.0) + bale_stack(tc, 12.0, -8.0)
    f += [row("banner_fence", tc, -22.0, 8.0, -8.2, 3.1, sides=(-1,)),
          row("tape_post", tc, -40.0, 30.0, -11.0, 3.05, sides=(-1,)),
          crowd(tc, -8.0, -16.0, 14, 7.0), crowd(tc, 22.0, -15.5, 8, 4.5), crowd(w["tc_approach"], 20.0, -15.0, 6, 4.0),
          crowd(tc, -6.0, 40.0, 5, 3.0, clear=12.0, face="random")]
    return f


LOTS = [
    {"name": "service", "road_at": WP["tc"], "offset_m": 0.0, "lateral": 22.0, "width": 34.0, "length": 84.0,
     "corner": 9.0, "surface": "tarmac"},
]

SIGNS = [
    # at the Hanami fork: the way on to Momiji, facing the car stopped at the finish
    {"road_at": FORK_CP_H + 3, "offset_m": 6.0, "lateral": -6.8, "face": "approach", "board": (3.4, 1.7), "bottom": 1.8,
     "color": "2f67b1", "lines": [{"text": "→ 紅葉谷", "font": "jp", "size": 0.62, "at": (0.0, 0.3)},
                                  {"text": "Momiji Valley  SS2", "size": 0.3, "at": (0.0, -0.42)}]},
    # past the gate: distance to go
    {"road_at": WP["sakura_1"], "offset_m": 10.0, "lateral": 6.2, "face": "approach", "board": (3.4, 1.7), "bottom": 1.7,
     "color": "2f67b1", "lines": [{"text": "↑ 紅葉谷", "font": "jp", "size": 0.62, "at": (0.0, 0.3)},
                                  {"text": "Momiji Valley 2 km", "size": 0.3, "at": (0.0, -0.42)}]},
    # festival banner board at the village entry
    {"road_at": WP["village_in"], "offset_m": 8.0, "lateral": 6.4, "face": "approach", "board": (2.6, 1.3), "bottom": 1.5,
     "color": "d9452b", "trim": "f5d27a", "post_color": "6b4d42",
     "lines": [{"text": "夏まつり", "font": "jp", "size": 0.62, "at": (0.0, 0.1)}]},
    # the time-control board ahead of the service park
    {"road_at": WP["tc"], "offset_m": -28.0, "lateral": 6.4, "face": "approach", "board": (3.0, 1.9), "bottom": 1.4,
     "color": "d9452b", "trim": "f5d27a",
     "lines": [{"text": "TC", "size": 0.62, "at": (0.0, 0.42)},
               {"text": "紅葉谷", "font": "jp", "size": 0.46, "at": (0.0, -0.18)},
               {"text": "Momiji Valley", "size": 0.24, "at": (0.0, -0.66)}]},
    # before the Momiji fork: the stage start is to the right, on the loop
    {"road_at": WP["join"], "offset_m": -10.0, "lateral": -6.6, "face": "approach", "board": (3.0, 1.5), "bottom": 1.7,
     "color": "2f67b1", "lines": [{"text": "→ SS2 紅葉谷", "font": "jp", "size": 0.5, "at": (0.0, 0.26)},
                                  {"text": "Stage start 230 m", "size": 0.28, "at": (0.0, -0.38)}]},
]

PARKED = [
    {"road_at": WP["tc"], "offset_m": 10.0, "lateral": 22.0, "face": "along", "car": "sakura", "livery": 2},
    {"road_at": WP["tc"], "offset_m": 2.0, "lateral": 22.0, "face": "along", "car": "sakura", "livery": 1},
    {"road_at": WP["tc"], "offset_m": -16.0, "lateral": 27.0, "face": "road", "yaw_add": 180.0, "car": "sakura", "livery": 3},
]

BRANCH = {
    "id": "branch",
    "closed": False,
    "points": _POINTS,
    "width": 7.0,
    "verge": 1.4,
    "surface": "tarmac",
    "bank_gain": 12.0,
    "bank_max": 0.04,
    "bridge_clearance": 1.6,
    "lots": LOTS,
    "crests": [
        {"at": WP["sakura_4"], "offset": 20.0, "height": 0.9, "width": 13.0},
        {"at": WP["crest"], "offset": 0.0, "height": 1.0, "width": 14.0},
        {"at": WP["village_out"], "offset": 40.0, "height": 0.8, "width": 12.0},
    ],
    # (end, loop road, loop distance of the fork, fork control point)
    "forks": [{"end": "start", "road": "hanami", "s": FORK_H, "cp": FORK_CP_H},
              {"end": "end", "road": "momiji", "s": FORK_M, "cp": FORK_CP_M}],
}

# terraced paddies on the slope below the climb; lowland paddies by the river south of the village
TERRACES = [(606, 372), (690, 398), (770, 414), (842, 410), (840, 500), (760, 520), (660, 500), (600, 440)]
PADDY_LOW = [(1210, 412), (1400, 404), (1410, 466), (1220, 470)]
PADS = [
    {"road": "branch", "road_at": WP["shrine_gate"], "offset_m": 0.0, "lateral": 38.0, "radius": 16.0, "blend": 12.0},
    {"road": "branch", "road_at": WP["farm"], "offset_m": 12.0, "lateral": -21.0, "radius": 16.0, "blend": 10.0},
    {"road": "branch", "road_at": WP["orchard"], "offset_m": 0.0, "lateral": 21.0, "radius": 14.0, "blend": 10.0},
    {"road": "branch", "road_at": WP["festival"], "offset_m": 20.0, "lateral": -22.0, "radius": 24.0, "blend": 10.0},
    {"road": "branch", "road_at": WP["village_in"], "offset_m": 30.0, "lateral": 22.0, "radius": 16.0, "blend": 10.0},
    {"road": "branch", "road_at": WP["festival"], "offset_m": 10.0, "lateral": 22.0, "radius": 22.0, "blend": 10.0},
    {"road": "branch", "road_at": WP["shrine_gate"], "offset_m": -26.0, "lateral": -22.0, "radius": 16.0, "blend": 10.0},
    {"road": "branch", "road_at": WP["shrine_gate"], "offset_m": 34.0, "lateral": -22.0, "radius": 14.0, "blend": 10.0},
    {"road": "branch", "road_at": WP["village_out"], "offset_m": 0.0, "lateral": 22.0, "radius": 18.0, "blend": 10.0},
    {"road": "branch", "road_at": WP["village_out"], "offset_m": 10.0, "lateral": -22.0, "radius": 14.0, "blend": 10.0},
]
KEEP_OUT = [(1250, 370, 46), (1330, 372, 46), (1400, 362, 40), (840, 380, 34), (505, 318, 30), (1600, 262, 60)]
NO_TREES = [TERRACES, PADDY_LOW]

# The summer country between the regions: Natsu's relief, palette and scatter rules.
MIDDLE = {
    "id": "natsu",
    "seed": 37,
    "season": "summer",
    "terrain": {
        "level_sigma": 100.0,
        "relief": {"amp": 26.0, "scale": 240.0, "near": 35.0, "far": 200.0, "detail": 1.2, "rise": 40.0},
        "hills": [
            {"pos": (720, 60), "radius": 220, "height": 70, "ridged": True},     # north of the terraces
            {"pos": (1000, 700), "radius": 200, "height": 55, "ridged": True},   # south of the river
            {"pos": (1350, 100), "radius": 170, "height": 48},                   # behind the village
            {"pos": (740, 470), "radius": 160, "height": 10},                    # rounds the terraces
            {"pos": (560, 620), "radius": 150, "height": 34},
        ],
        "terraces": [{"poly": TERRACES, "step": 2.6, "edge": 12.0, "paddies": True},
                     {"poly": PADDY_LOW, "step": 0.9, "edge": 8.0, "paddies": True}],
        "pads": PADS,
    },
    "palette": {
        "grass": ["7fba4f", "6cad45", "9ccb5c"],
        "grass_dry": "b9c96c",
        "verge_grass": "a9d06c",
        "forest_floor": "5b8f45",
        "field": "a6dc5e",
        "field2": "74c25a",
        "bund": "4f8a3c",
        "rock": "aaa59c",
        "rock_dark": "8c8a88",
        "dirt": "b39468",
        "sand": "dcd2a8",
        "mountain": "4f8a57",
        "rail": "d8dee3",
        "rail_post": "9aa4ae",
        "bridge_rail": "e24a31",
        "bridge_cap": "f2c552",
        "stone": "c2baab",
        "wood": "a47148",
        "wood_dark": "6b4d42",
    },
    "materials": {
        "road": {"gravel_color": "c4ad86", "gravel_dark": "9e8666", "tarmac_color": "555b6e",
                 "line_color": "f5f2ea", "centre_line": "f5f2ea", "petal_color": "8cb35a"},
        "water": {"shallow": "7fcfc6", "deep": "3585b0"},
    },
    "backdrop": {"color": "6f9d84", "color_far": "a8c2d4", "height": 520.0, "base": 140.0,
                 "inner": 170.0, "scale": 430.0},
    "features": _dressing(),
    "signs": SIGNS,
    "parked": PARKED,
    "scatter": [
        {"name": "green_road", "exclude": KEEP_OUT, "exclude_poly": NO_TREES,
         "props": ["maple_green", "pine_a", "pine_b"], "weights": {"maple_green": 1.6},
         "spacing": 11.0, "density": 0.7, "road_min": 5.5, "road_max": 51.5, "road_peak": (8.5, 51.5),
         "mask": {"scale": 170.0, "threshold": -0.1, "seed": 1}, "slope_max": 32.0, "scale": (0.85, 1.25),
         "sink": 0.3},
        {"name": "forest", "exclude": KEEP_OUT, "exclude_poly": NO_TREES,
         "props": ["cedar_a", "cedar_b", "maple_green"], "weights": {"maple_green": 0.5},
         "spacing": 8.5, "density": 0.85, "road_min": 9.5,
         "mask": {"scale": 170.0, "threshold": 0.0, "seed": 1, "sign": -1.0},
         "slope_max": 40.0, "scale": (0.85, 1.3), "sink": 0.3},
        {"name": "bamboo", "exclude": KEEP_OUT, "exclude_poly": NO_TREES, "props": ["bamboo_clump"],
         "spacing": 12.0, "density": 0.5, "road_min": 5.5,
         "regions": [{"circle": (1050, 300, 90)}, {"circle": (1180, 280, 80)}, {"circle": (930, 420, 60)}],
         "scale": (0.9, 1.2), "sink": 0.2},
        {"name": "mountain_forest", "props": ["cedar_a", "cedar_b", "pine_a", "maple_green"],
         "weights": {"maple_green": 0.4}, "spacing": 15.0, "density": 0.6,
         "edge_min": 520.0, "edge_max": 800.0, "road_min": 46.5, "slope_max": 46.0,
         "scale": (1.0, 1.5), "sink": 0.4},
        {"name": "bushes", "exclude": KEEP_OUT, "exclude_poly": NO_TREES, "props": ["bush_a", "bush_b"],
         "spacing": 7.0, "density": 0.35, "road_min": 2.9, "road_max": 26.5, "slope_max": 35.0,
         "scale": (0.8, 1.3)},
        {"name": "hydrangeas", "props": ["azalea"], "spacing": 6.0, "density": 0.4, "road_min": 3.1,
         "road_max": 14.5, "regions": [{"circle": (1310, 370, 170)}, {"circle": (1135, 344, 70)}],
         "exclude_poly": NO_TREES, "slope_max": 30.0, "scale": (0.9, 1.3)},
        {"name": "rocks_slope", "exclude": KEEP_OUT, "props": ["rock_a", "rock_b", "rock_c", "rock_d", "rock_e"],
         "spacing": 13.0, "density": 0.4, "road_min": 3.5, "road_max": 56.5, "slope_min": 16.0, "slope_max": 60.0,
         "scale": (0.7, 1.6), "sink": 0.3},
        {"name": "cliffs", "props": ["cliff_a", "cliff_b"], "spacing": 24.0, "density": 0.45, "road_min": 5.5,
         "road_max": 86.5, "slope_min": 28.0, "slope_max": 70.0, "scale": (0.8, 1.4), "sink": 0.8},
        {"name": "boulders_river", "props": ["boulder", "rock_a", "rock_d", "rock_e"], "spacing": 8.0,
         "density": 0.4, "water_max": 9.0, "water_clear": 0.5, "road_min": 4.5, "scale": (0.6, 1.3), "sink": 0.3},
        {"name": "reeds", "props": ["reeds"], "spacing": 3.0, "density": 0.6, "water_max": 5.0,
         "water_clear": 0.3, "road_min": 3.5, "occupy": False, "scale": (0.8, 1.3), "sink": 0.1},
        {"name": "paddy_reeds", "props": ["reeds"], "spacing": 7.0, "density": 0.25, "road_min": 4.5,
         "regions": [{"poly": TERRACES}, {"poly": PADDY_LOW}], "occupy": False, "scale": (0.5, 0.8), "sink": 0.2},
        {"name": "ferns", "props": ["fern"], "spacing": 5.0, "density": 0.35, "road_min": 2.5, "road_max": 86.5,
         "mask": {"scale": 170.0, "threshold": 0.0, "seed": 1, "sign": -1.0}, "occupy": False, "sink": 0.05},
        {"name": "logs", "exclude": KEEP_OUT, "exclude_poly": NO_TREES, "props": ["log", "stump"],
         "spacing": 32.0, "density": 0.3, "road_min": 4.5, "road_max": 66.5, "sink": 0.05},
        {"name": "grass", "props": ["grass_tuft"], "spacing": 3.0, "density": 0.45, "road_min": 2.3,
         "road_max": 81.5, "occupy": False, "scale": (0.8, 1.5), "sink": 0.05, "exclude_poly": NO_TREES},
        {"name": "flowers", "props": ["flowers_patch"], "spacing": 5.5, "density": 0.3, "road_min": 2.3,
         "road_max": 41.5, "occupy": False, "scale": (0.8, 1.3), "sink": 0.05, "exclude_poly": NO_TREES},
    ],
}

# ------------------------------------------------------------------------------ water

_MR_POINTS = momiji.SPEC["river"]["points"]
_MR_KEEP = [p for p in _MR_POINTS if p[1] <= 480]
RIVERS = [
    # Hanami's river: from the north rim down under the humped bridge into the lake
    {"id": "hanami", **HANAMI["river"]},
    # Momiji's river: the waterfall gorge, the valley, under the vermilion bridge, then west
    # along the middle valley south of the village into Hanami's lake
    {"id": "momiji", **{k: v for k, v in MOMIJI["river"].items() if k != "points"},
     "points": [(*MOMIJI_FRAME.xz(p[0], p[1]), p[2]) for p in _MR_KEEP] + [
         (1540, 360, 19.0), (1440, 440, 18.2), (1300, 505, 17.3), (1150, 522, 16.6), (980, 530, 15.8),
         (800, 548, 14.9), (620, 548, 14.1), (440, 520, 13.3), (260, 486, 12.6), (120, 470, 12.1),
         (40, 468, 11.7)]},
    # the Kawabata: down from the north rim, under the branch's stone bridge, into the Momiji river
    {"id": "kawabata", "points": [(1180, -330, 62.0), (1160, -170, 48.0), (1140, 20, 38.0), (1135, 180, 32.0),
                                  (1135, 300, 28.4), (1135, 390, 24.0), (1140, 460, 20.0), (1146, 512, 16.75)],
     "width": 7.0, "meander": 8.0, "pins": [(1135, 344), (1146, 512)], "depth": 1.1, "join": "momiji"},
]

# ------------------------------------------------------------------------------ the world

WORLD = {
    "id": "world",
    "seed": 5,
    "cell": 4.0,
    # terrain rectangle: both regions' squares (+-800 m around their centres)
    "bounds": (-800.0, -800.0, 2950.0, 1240.0),
    "regions": [
        {"id": "hanami", "spec": HANAMI, "frame": HANAMI_FRAME, "season": "spring", "road": "hanami", "rim": True},
        {"id": "natsu", "spec": MIDDLE, "frame": Frame(), "season": "summer", "road": "branch"},
        {"id": "momiji", "spec": MOMIJI, "frame": MOMIJI_FRAME, "season": "autumn", "road": "momiji", "rim": True},
    ],
    "roads": {"hanami": HANAMI["road"], "momiji": MOMIJI["road"], "branch": BRANCH},
    "rivers": RIVERS,
    "lake": HANAMI["lake"],
    # one mountain rim around the world: the regions' squares and a valley along the branch,
    # merged smoothly; "edge" 560 = foot of the rim (v1's boundary start), 790 = its top
    "rim": {"valley_road": "branch", "start": 560.0, "end": 790.0, "height": 210.0, "roundness": 4.0, "valley": 430.0,
            "blend": 160.0},
    # seasons along the Hanami -> Momiji axis (metres from the world origin along it)
    "seasons": {"axis": (2150.0, 440.0), "spring_end": (520.0, 720.0), "autumn_start": (1470.0, 1590.0),
                "wobble": 45.0, "cell": 8.0},
    "routes": {
        "hanami": {"road": "hanami", "atmosphere": "spring_noon", "season": "spring"},
        "momiji": {"road": "momiji", "atmosphere": "autumn_golden", "season": "autumn"},
        "liaison": {"atmosphere": "summer_afternoon", "season": "summer",
                    "from": ("hanami", "finish_stop"), "via": "branch", "to": ("momiji", "spawn"),
                    "arrival_radius": 12.0},
    },
    "finish_stop": FINISH_STOP,
    "gates": [
        {"id": "hanami_branch", "fork": 0, "offset": 14.0},
        {"id": "momiji_branch", "fork": 1, "offset": 14.0},
    ],
}
