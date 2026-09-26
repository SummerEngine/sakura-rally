"""Natsu Road 夏道 - summer afternoon. The untimed liaison between Hanami Pass and Momiji
Valley: an open road from a small car park on the pass, down along the hillside past
terraced rice paddies, over a stone bridge into a village holding its summer festival,
along the forest edge and into the Momiji Valley time control (a rally service park).

Road points: (x, z, target height, {attributes applying from this point on}).
Driving direction: east along the pass, a wide right-hander south and west below the
terraces, south over the river, east through the village, south-east to the service park.
The road starts and ends inside paved lots (the pass car park and the service park), so
both ends of the ribbon finish on pavement.
"""

POINTS = [
    (-445, -478, 120.0, {"surface": "tarmac"}),    # 0 lead-in inside the pass car park
    (-385, -472, 120.0),                           # 1 start line on the pass
    (-310, -458, 118.0),                           # 2
    (-230, -432, 114.0),                           # 3
    (-150, -422, 110.0),                           # 4
    (-60, -438, 106.0),                            # 5 bus stop above the valley
    (30, -430, 101.0),                             # 6 farm at the top of the terraces
    (110, -397, 96.0),                             # 7
    (178, -347, 91.0),                             # 8
    (240, -298, 86.0),                             # 9
    (298, -238, 81.0),                             # 10 long right-hander, heading south
    (300, -165, 76.0),                             # 11
    (248, -110, 71.0),                             # 12 heading west below the terraces
    (160, -94, 67.0),                              # 13
    (70, -108, 63.0),                              # 14 terrace hamlet
    (-20, -100, 59.0),                             # 15
    (-110, -72, 56.0),                             # 16
    (-168, -18, 52.0),                             # 17 left, down toward the river
    (-183, 68, 47.0, {"bridge": "stone"}),         # 18 stone bridge
    (-177, 100, 47.5),                             # 19 over the river
    (-170, 130, 47.0, {"bridge": None}),           # 20
    (-138, 188, 45.0),                             # 21 village entry, festival banner
    (-80, 236, 43.0),                              # 22 festival street
    (-5, 258, 42.0),                               # 23
    (70, 262, 41.0),                               # 24 shrine gate
    (140, 250, 40.0),                              # 25 end of the village
    (215, 268, 38.0),                              # 26 forest edge
    (275, 318, 36.0),                              # 27
    (312, 385, 34.0),                              # 28
    (362, 440, 32.0),                              # 29 time-control approach
    (420, 462, 31.0),                              # 30 arrival: Momiji Valley TC
    (478, 481, 31.0),                              # 31 run-out inside the service park
]
START_CP = 1
ARRIVAL_CP = 30

# ---------------------------------------------------------------------------- dressing
# Road-relative placement: (control point, metres along the road from it, lateral metres,
# + = right of the driving direction). Nothing rigid stands in the road corridor (half width +
# verge + 1.5 m, wider at checkpoints; lib/corridor.py moves offenders out). Singles first
# (they reserve their footprint), then lines (they skip occupied spots), then groups.

SPECTATORS = ["spectator_a", "spectator_b", "spectator_c", "spectator_d", "spectator_e", "spectator_f"]
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
    """Props on a straight line between two absolute points (fences, stall rows, paths)."""
    props = [props] if isinstance(props, str) else list(props)
    return {"kind": "row", "props": props, "from": a, "to": b, "spacing": spacing, "face": face, **kw}


def crowd(cp, off, lat, count, radius=5.0, face="road", clear=8.0, **kw):
    return {"kind": "group", "props": SPECTATORS, "weights": [1.0, 1.0, 0.8, 1.0, 0.7, 0.7], "count": count,
            "road_at": cp, "offset_m": off, "lateral": lat, "radius": radius, "road_clear": clear, "face": face,
            "yaw_jitter": 22.0, "scale": (0.95, 1.05), "sink": 0.05, **kw}


def house(prop, cp, off, lat, yaw_add=0.0):
    r = {"farmhouse_a": 9.0, "farmhouse_b": 9.0, "kura": 4.5, "shed": 3.4}[prop]
    return one(prop, cp, off, lat, "road", sink=0.35, radius=r, yaw_add=yaw_add)


def stall(cp, off, side, vending=True):
    """A festival stall (yatai): a tent facing the street, a bench in front, a lantern
    string along the front, sometimes a vending machine at the side."""
    lat = side * 13.0
    f = [one("tent", cp, off, lat, "road"),
         one("bench", cp, off + 2.6, side * 10.2, "road", yaw_add=90.0 * side),
         one("lantern_string", cp, off, side * 10.0, "along")]
    if vending:
        f.append(one("vending_machine", cp, off - 3.0, side * 12.2, "road"))
    return f


def _dressing():
    f = []
    # ------------------------------------------------------------ the pass car park (cp 0 .. 1)
    # heading east; the lot is on the right (valley side), the hill on the left
    f += [one("vending_machine", 1, -30.0, 21.0, "road"), one("vending_machine", 1, -28.8, 21.0, "road"),
          one("bench", 1, -40.0, 22.5, "away"), one("bench", 1, -48.0, 22.5, "away"),
          one("stone_lantern", 1, -20.0, 22.0, "road"), one("jizo", 1, -53.0, 21.5, "road"),
          one("jizo", 1, -52.2, 21.5, "road"), one("hokora", 1, -56.0, 22.0, "road"),
          one("kei_truck", 1, -36.0, 12.0, "along", yaw_add=100.0),
          one("telephone_pole", 1, -12.0, -7.2, "road"), one("road_mirror", 1, 6.0, -6.6, "road"),
          one("maple_green", 1, -64.0, 26.0, "road"), one("pine_a", 1, 14.0, 22.0, "road")]
    f += [row("fence_wood", 1, -60.0, 0.0, 24.6, 2.05, face="road_side"),
          row(["bush_a", "azalea", "bush_b"], 1, -58.0, -6.0, -7.4, 4.5, sides=(-1,), sink=0.1)]
    f.append(row("telephone_pole", 2, 10.0, 0.0, -8.2, 36.0, face="road_side", cp_to=9))

    # ------------------------------------------------------------ along the pass (cp 2 .. 9)
    f += [one("stone_lantern", 4, 10.0, -8.4, "road", scale=0.8), one("jizo", 4, 12.0, -8.2, "road"),
          one("bus_stop", 5, 0.0, 8.8, "road"), one("bench", 5, 0.0, 11.4, "road"),
          one("vending_machine", 5, 4.2, 8.4, "road"),
          one("road_mirror", 7, 10.0, -6.8, "road")]
    # farm at the head of the terraces: house, storehouse, well, a truck by the barn
    f += [house("farmhouse_b", 6, 8.0, 22.0), house("kura", 6, 24.0, 20.0),
          one("water_well", 6, -4.0, 14.0, "road"), house("shed", 6, -14.0, 17.0),
          one("kei_truck", 6, 18.0, 11.0, "along", yaw_add=175.0),
          one("maple_green", 6, -24.0, 22.0, "road"), one("bamboo_clump", 6, 38.0, 24.0, "road")]
    f += [row("stone_wall", 6, -20.0, 30.0, 10.2, 2.0, face="road_side")]

    # ------------------------------------------------------------ the terraces (between the legs)
    f += [at("scarecrow", 60.0, -300.0, 160.0), at("scarecrow", 140.0, -230.0, 200.0),
          at("scarecrow", 20.0, -190.0, 120.0),
          at("shed", 190.0, -200.0, 250.0, radius=3.4), at("kei_truck", 180.0, -188.0, 160.0)]
    f += [at("rice_paddy_marker", x, z, 0.0) for (x, z) in
          ((0, -330), (40, -280), (95, -320), (120, -265), (160, -290), (70, -230), (110, -200),
           (-10, -240), (30, -180), (170, -170))]

    # ------------------------------------------------------------ the long right-hander (cp 10 .. 12)
    f += [one("road_mirror", 11, 8.0, -6.8, "road")]

    # ------------------------------------------------------------ terrace hamlet (cp 13 .. 15), heading west
    # right (+) is uphill toward the terraces, left (-) downhill toward the river
    f += [house("farmhouse_a", 14, -6.0, -22.0), house("kura", 14, 10.0, -20.0),
          house("farmhouse_b", 14, 26.0, -23.0, yaw_add=8.0), house("shed", 13, 18.0, 16.0),
          one("water_well", 14, 18.0, -13.0, "road"), one("kei_truck", 14, -18.0, -13.0, "along", yaw_add=-8.0),
          one("jizo", 15, 12.0, 8.2, "road"), one("hokora", 15, 14.0, 8.8, "road"),
          one("stone_lantern", 15, 10.0, 8.4, "road", scale=0.8),
          one("bamboo_clump", 14, -26.0, -34.0, "road"), one("bamboo_clump", 14, 40.0, -30.0, "road"),
          one("maple_green", 13, -4.0, -18.0, "road")]
    f += [row("stone_wall", 14, -16.0, 36.0, -10.4, 2.0, face="road_side"),
          row("fence_bamboo", 13, 6.0, 28.0, 10.4, 2.05, face="road_side"),
          row(["azalea", "bush_b"], 14, -14.0, 34.0, -9.0, 3.6, sides=(-1,), sink=0.1)]
    f.append(row("telephone_pole", 12, 10.0, 0.0, 8.2, 38.0, face="road_side", cp_to=17))
    f += [one("road_mirror", 17, 6.0, 6.8, "road")]

    # ------------------------------------------------------------ stone bridge over the river (cp 18 .. 20)
    f += [one("stone_lantern", 18, -6.0, 7.4, "road"), one("stone_lantern", 18, -6.0, -7.4, "road"),
          one("stone_lantern", 20, 6.0, 7.4, "road"), one("stone_lantern", 20, 6.0, -7.4, "road"),
          one("jizo", 20, 12.0, 8.2, "road"), one("jizo", 20, 12.8, 8.2, "road"),
          one("maple_green", 18, -16.0, 13.0, "road"), one("bamboo_clump", 20, 16.0, -14.0, "road")]

    # ------------------------------------------------------------ the festival village (cp 21 .. 25), heading east
    # right (+) is the south side with the shrine, left (-) the north side above the paddies
    f.append({"kind": "clear", "road_at": 23, "offset_m": 0.0, "lateral": 0.0, "radius": 6.0})
    # houses, both sides
    f += [house("farmhouse_a", 21, 26.0, -22.0), house("kura", 21, 42.0, -20.0),
          house("farmhouse_b", 22, 22.0, -23.0, yaw_add=6.0), house("shed", 22, 38.0, -16.0),
          house("farmhouse_a", 23, 28.0, -23.0), house("kura", 23, 44.0, -21.0),
          house("farmhouse_b", 24, 34.0, -23.0), house("farmhouse_a", 25, 10.0, -22.0),
          house("farmhouse_b", 21, 30.0, 22.0), house("farmhouse_a", 22, 10.0, 23.0),
          house("kura", 22, 26.0, 20.0), house("farmhouse_b", 23, 8.0, 23.0),
          house("farmhouse_a", 25, -12.0, 23.0), house("shed", 25, 6.0, 17.0)]
    # the shrine on the south side: big torii at the street, lantern path, bell and hokora
    f += [one("torii_large", 24, 0.0, 15.5, "road"),
          one("shrine", 24, 0.0, 42.0, "road", sink=0.35, radius=7.0),
          one("shrine_bell", 24, -10.0, 34.0, "road"), one("hokora", 24, 10.0, 33.0, "road"),
          one("stone_lantern", 24, -3.5, 20.5, "road"), one("stone_lantern", 24, 3.5, 20.5, "road"),
          one("stone_lantern", 24, -3.5, 27.0, "road"), one("stone_lantern", 24, 3.5, 27.0, "road"),
          one("bamboo_clump", 24, -16.0, 48.0, "road"), one("bamboo_clump", 24, 16.0, 50.0, "road"),
          one("maple_green", 24, -14.0, 22.0, "road"), one("maple_green", 24, 15.0, 23.0, "road")]
    f += [one("jizo", 24, 7.0 + 0.8 * k, 9.4, "road") for k in range(4)]
    # festival stalls along the street, lantern strings, visitors
    f += stall(22, 36.0, 1) + stall(22, 46.0, 1, vending=False) + stall(23, -18.0, 1)
    f += stall(23, 14.0, -1) + stall(23, 24.0, -1, vending=False) + stall(24, 14.0, -1)
    f += stall(24, 20.0, 1, vending=False) + stall(24, -20.0, -1, vending=False)
    f += [row("lantern_string", 21, 18.0, 0.0, 9.6, 11.0, sides=(-1, 1), cp_to=25)]
    f += [crowd(22, 42.0, 15.0, 7, 4.0, clear=7.5, face="random"), crowd(23, 18.0, -15.0, 7, 4.0, clear=7.5, face="random"),
          crowd(24, 6.0, 12.5, 6, 3.5, clear=7.0, face="random"), crowd(24, -18.0, -15.0, 5, 3.5, clear=7.5, face="random"),
          crowd(23, -18.0, 15.5, 4, 3.0, clear=7.5, face="random")]
    # street furniture and gardens: poles on the north side, hydrangea-coloured bushes
    f += [one("bus_stop", 25, 18.0, 9.2, "road"), one("bench", 25, 18.0, 11.8, "road"),
          one("water_well", 22, 26.0, 13.0, "road"), one("kei_truck", 23, 34.0, 12.5, "along", yaw_add=6.0),
          one("kei_truck", 21, 14.0, -12.5, "along", yaw_add=178.0)]
    f.append(row("telephone_pole", 21, 0.0, 0.0, -8.4, 34.0, face="road_side", cp_to=26))
    f += [row(["azalea", "bush_b", "azalea"], 21, 20.0, 60.0, -10.2, 3.2, sides=(-1,), sink=0.1),
          row(["azalea", "bush_a"], 23, 36.0, 60.0, -10.2, 3.2, sides=(-1,), sink=0.1),
          row(["azalea", "bush_b"], 25, -4.0, 30.0, 10.2, 3.0, sides=(1,), sink=0.1),
          row("stone_wall", 22, 0.0, 16.0, -14.6, 2.0, face="road_side"),
          row("fence_bamboo", 25, -30.0, -16.0, 14.4, 2.05, face="road_side")]

    # ------------------------------------------------------------ lowland paddies north of the street
    f += [at("scarecrow", 20.0, 190.0, 30.0), at("scarecrow", 100.0, 195.0, -40.0),
          at("shed", 150.0, 205.0, 200.0, radius=3.4)]
    f += [at("rice_paddy_marker", x, z, 0.0) for (x, z) in ((-20, 175), (40, 205), (70, 180), (120, 188))]

    # ------------------------------------------------------------ forest edge (cp 26 .. 29)
    f += [one("road_mirror", 27, 8.0, -6.8, "road"),
          one("stone_lantern", 26, 20.0, 8.6, "road", scale=0.8), one("jizo", 26, 22.0, 8.4, "road"),
          one("log", 28, 10.0, -12.5, "along"), one("log", 28, 10.0, -13.2, "along"),
          one("log", 28, 10.3, -12.85, "along", y_offset=0.5)]
    f += [one("distance_board_100", 30, -100.0, 6.9, "along", yaw_add=180.0),
          one("distance_board_50", 30, -50.0, 6.9, "along", yaw_add=180.0),
          one("flag_pole_pink", 29, -20.0, 8.8, "road_side"), one("flag_pole_blue", 29, -20.0, -8.8, "road_side")]

    # ------------------------------------------------------------ Momiji Valley time control (cp 29 .. 31)
    # heading east-north-east; the service park is on the right (+), spectators on the left. The
    # runtime puts up the time-control gate from map.checkpoints.
    f += [one("marshal_post", 30, -6.0, -9.6, "road"), one("marshal_post", 30, 4.0, 9.8, "road"),
          one("traffic_cone", 30, -14.0, -6.4, "road"), one("traffic_cone", 30, -10.0, -6.4, "road"),
          one("traffic_cone", 30, 22.0, -6.4, "road"), one("traffic_cone", 30, 30.0, -6.4, "road")]
    # the stage start for SS2 set up across the park, the queue of rally cars behind it
    f += [one("start_arch", 30, 34.0, 22.0, "along", scale=1.2, sink=0.15),
          one("marshal_post", 30, 30.0, 29.5, "road", yaw_add=90.0)]
    # service tents along the back of the park, banners and flags on its edge
    f += [one("tent", 30, -22.0, 33.0, "road"), one("tent", 30, -12.0, 34.0, "road", yaw_add=4.0),
          one("tent", 30, 0.0, 33.5, "road"), one("tent", 30, 12.0, 34.0, "road", yaw_add=-3.0),
          one("tire_stack", 30, -17.0, 31.0, "road"), one("tire_stack", 30, -16.2, 31.6, "road"),
          one("tire_stack", 30, -6.0, 31.4, "road"),
          one("bench", 30, 6.0, 30.0, "road"), one("vending_machine", 30, -30.0, 32.0, "road"),
          one("kei_truck", 30, -30.0, 22.0, "along", yaw_add=175.0)]
    f += [row("banner_fence", 30, -36.0, 44.0, 38.4, 3.1, face="road_side"),
          row(FLAGS, 30, -34.0, 46.0, 40.5, 8.0),
          row(FLAGS, 29, -30.0, 30.0, 8.8, 10.0, sides=(1,))]
    f += bale_stacks(30, -26.0, -8.0) + bale_stacks(30, 12.0, -8.0)
    f += [row("banner_fence", 30, -22.0, 8.0, -8.2, 3.1, sides=(-1,)),
          row("tape_post", 30, -40.0, 40.0, -11.0, 3.05, sides=(-1,)),
          crowd(30, -8.0, -16.0, 14, 7.0), crowd(30, 22.0, -15.5, 8, 4.5), crowd(29, 20.0, -15.0, 6, 4.0),
          crowd(30, -6.0, 40.0, 5, 3.0, clear=12.0, face="random")]
    return f


def bale_stacks(cp, off, lat, face="road_side"):
    """Two square bales side by side and one on top."""
    return [one("hay_bale_square", cp, off - 1.0, lat, face), one("hay_bale_square", cp, off + 1.0, lat, face),
            one("hay_bale_square", cp, off, lat, face, y_offset=0.8, yaw_add=6.0)]


DRESSING = _dressing()

# Paved lots: the pass car park (the road's lead-in starts inside it) and the service
# park (the run-out ends inside it).
LOTS = [
    {"name": "pass", "road_at": 1, "offset_m": -36.0, "lateral": 9.0, "width": 30.0, "length": 84.0,
     "corner": 8.0, "surface": "gravel"},
    {"name": "service", "road_at": 30, "offset_m": 17.0, "lateral": 13.0, "width": 50.0, "length": 116.0,
     "corner": 10.0, "surface": "tarmac"},
]

SIGNS = [
    # guide sign at the car park exit, facing the driver: onward to Momiji Valley
    {"road_at": 1, "offset_m": 26.0, "lateral": 6.2, "face": "approach", "board": (3.4, 1.7), "bottom": 1.7,
     "color": "2f67b1", "lines": [{"text": "↑ 紅葉谷", "font": "jp", "size": 0.62, "at": (0.0, 0.3)},
                                  {"text": "Momiji Valley 2.2 km", "size": 0.3, "at": (0.0, -0.42)}]},
    # and back the way the campaign came, on the hill side of the car park
    {"road_at": 1, "offset_m": -6.0, "lateral": -6.4, "face": "road", "yaw_add": -40.0, "board": (3.0, 1.5),
     "bottom": 1.6, "color": "2f67b1", "lines": [{"text": "← 花見峠", "font": "jp", "size": 0.56, "at": (0.0, 0.26)},
                                                 {"text": "Hanami Pass", "size": 0.3, "at": (0.0, -0.38)}]},
    # festival banner board at the village entry
    {"road_at": 21, "offset_m": 8.0, "lateral": 6.4, "face": "approach", "board": (2.6, 1.3), "bottom": 1.5,
     "color": "d9452b", "trim": "f5d27a", "post_color": "6b4d42",
     "lines": [{"text": "夏まつり", "font": "jp", "size": 0.62, "at": (0.0, 0.1)}]},
    # the time-control board ahead of the arrival
    {"road_at": 30, "offset_m": -28.0, "lateral": 6.4, "face": "approach", "board": (3.0, 1.9), "bottom": 1.4,
     "color": "d9452b", "trim": "f5d27a",
     "lines": [{"text": "TC", "size": 0.62, "at": (0.0, 0.42)},
               {"text": "紅葉谷", "font": "jp", "size": 0.46, "at": (0.0, -0.18)},
               {"text": "Momiji Valley", "size": 0.24, "at": (0.0, -0.66)}]},
]

# rally cars parked in the service park: two queued behind the SS2 start arch, one by the tents
PARKED = [
    {"road_at": 30, "offset_m": 24.0, "lateral": 22.0, "face": "along", "car": "sakura", "livery": 2},
    {"road_at": 30, "offset_m": 16.0, "lateral": 22.0, "face": "along", "car": "sakura", "livery": 1},
    {"road_at": 30, "offset_m": -6.0, "lateral": 27.0, "face": "road", "yaw_add": 180.0, "car": "sakura", "livery": 3},
]

# terraced paddies between the pass road and the road below; lowland paddies by the village
TERRACES = [(-40, -388), (110, -372), (205, -305), (222, -180), (120, -142), (-40, -146)]
PADDY_LOW = [(-60, 160), (150, 168), (150, 214), (-40, 212)]
PADS = [
    {"road_at": 24, "offset_m": 0.0, "lateral": 38.0, "radius": 16.0, "blend": 12.0},   # shrine precinct
    {"road_at": 6, "offset_m": 12.0, "lateral": 21.0, "radius": 16.0, "blend": 10.0},   # pass farm
    {"road_at": 14, "offset_m": 10.0, "lateral": -22.0, "radius": 24.0, "blend": 10.0},  # terrace hamlet
    {"road_at": 22, "offset_m": 20.0, "lateral": -22.0, "radius": 24.0, "blend": 10.0},  # village north
    {"road_at": 23, "offset_m": 30.0, "lateral": -22.0, "radius": 20.0, "blend": 10.0},
    {"road_at": 22, "offset_m": 18.0, "lateral": 22.0, "radius": 22.0, "blend": 10.0},   # village south
    {"road_at": 21, "offset_m": 30.0, "lateral": 22.0, "radius": 14.0, "blend": 10.0},
    {"road_at": 25, "offset_m": 0.0, "lateral": 22.0, "radius": 18.0, "blend": 10.0},
    {"road_at": 25, "offset_m": 10.0, "lateral": -22.0, "radius": 14.0, "blend": 10.0},
    {"road_at": 24, "offset_m": 34.0, "lateral": -22.0, "radius": 14.0, "blend": 10.0},
]
# village, farms and paddies: trees, bushes and rocks keep out (explicit garden trees remain)
KEEP_OUT = [(-110, 215, 40), (-40, 248, 44), (40, 262, 46), (110, 258, 44), (150, 250, 24),
            (40, -420, 34), (70, -120, 42), (-420, -470, 30), (425, 470, 62)]
NO_TREES = [TERRACES, PADDY_LOW]

SPEC = {
    "id": "natsu",
    "seed": 37,
    "season": "summer",
    "atmosphere": "summer_afternoon",
    "size": 1800.0,
    "cell": 4.5,
    "play_half": 600.0,
    "road": {
        "closed": False,
        "points": POINTS,
        "width": 7.0,
        "verge": 1.4,
        "surface": "tarmac",
        "start_cp": START_CP,
        "arrival_cp": ARRIVAL_CP,
        "arrival_radius": 12.0,
        "checkpoints": 4,
        "bank_gain": 12.0,
        "bank_max": 0.04,
        "bridge_clearance": 1.6,
        "lots": LOTS,
        "crests": [
            {"at": 4, "offset": 30.0, "height": 1.0, "width": 14.0},
            {"at": 15, "offset": 20.0, "height": 0.9, "width": 12.0},
            {"at": 27, "offset": 10.0, "height": 1.1, "width": 13.0},
        ],
    },
    "terrain": {
        "level_sigma": 100.0,
        "relief": {"amp": 26.0, "scale": 240.0, "near": 35.0, "far": 200.0, "detail": 1.2, "rise": 40.0},
        "hills": [
            {"pos": (-470, -330), "radius": 150, "height": 55, "ridged": True},    # frames the pass
            {"pos": (-260, -620), "radius": 180, "height": 70, "ridged": True},    # behind the car park
            {"pos": (430, -430), "radius": 200, "height": 90, "ridged": True},
            {"pos": (450, 90), "radius": 160, "height": 48},
            {"pos": (-420, 300), "radius": 180, "height": 60, "ridged": True},
            {"pos": (90, 470), "radius": 130, "height": 34},
            {"pos": (80, -250), "radius": 150, "height": 12},                      # rounds the terraces
        ],
        "boundary": {"start": 650.0, "end": 870.0, "height": 210.0},
        "terraces": [{"poly": TERRACES, "step": 2.6, "edge": 12.0, "paddies": True},
                     {"poly": PADDY_LOW, "step": 0.9, "edge": 8.0, "paddies": True}],
        "pads": PADS,
    },
    "river": {
        "points": [(-790, 40, 64.0), (-620, 60, 56.0), (-470, 88, 50.0), (-330, 96, 46.0), (-240, 100, 43.5),
                   (-177, 100, 42.0), (-100, 112, 40.5), (0, 126, 38.5), (100, 134, 36.5), (200, 152, 34.0),
                   (300, 182, 31.0), (400, 222, 28.0), (500, 280, 25.0), (620, 330, 22.0), (790, 380, 18.0)],
        "width": 10.0,
        "meander": 10.0,
        "pins": [(-177, 100)],
        "depth": 1.3,
    },
    "backdrop": {"color": "6f9d84", "color_far": "a8c2d4", "height": 520.0, "base": 140.0,
                 "inner": 170.0, "scale": 430.0},
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
    "features": DRESSING,
    "signs": SIGNS,
    "parked": PARKED,
    "scatter": [
        {"name": "green_road", "exclude": KEEP_OUT, "exclude_poly": NO_TREES,
         "props": ["maple_green", "pine_a", "pine_b"], "weights": {"maple_green": 1.6},
         "spacing": 11.0, "density": 0.7, "road_min": 9.0, "road_max": 55.0, "road_peak": (12.0, 55.0),
         "mask": {"scale": 170.0, "threshold": -0.1, "seed": 1}, "slope_max": 32.0, "scale": (0.85, 1.25),
         "sink": 0.3},
        {"name": "forest", "exclude": KEEP_OUT, "exclude_poly": NO_TREES,
         "props": ["cedar_a", "cedar_b", "maple_green"], "weights": {"maple_green": 0.5},
         "spacing": 8.5, "density": 0.85, "road_min": 13.0,
         "mask": {"scale": 170.0, "threshold": 0.0, "seed": 1, "sign": -1.0},
         "slope_max": 40.0, "scale": (0.85, 1.3), "sink": 0.3},
        {"name": "forest_edge", "exclude": KEEP_OUT, "props": ["cedar_a", "cedar_b", "maple_green", "pine_b"],
         "spacing": 8.0, "density": 0.85, "road_min": 12.0, "road_max": 140.0,
         "regions": [{"poly": [(170, 230), (260, 230), (400, 330), (470, 400), (380, 400), (300, 280)]}],
         "slope_max": 40.0, "scale": (0.9, 1.3), "sink": 0.3},
        {"name": "bamboo", "exclude": KEEP_OUT, "exclude_poly": NO_TREES, "props": ["bamboo_clump"],
         "spacing": 12.0, "density": 0.5, "road_min": 9.0,
         "regions": [{"circle": (-230, 180, 90)}, {"circle": (40, 320, 80)}, {"circle": (-120, 30, 60)}],
         "scale": (0.9, 1.2), "sink": 0.2},
        {"name": "mountain_forest", "props": ["cedar_a", "cedar_b", "pine_a", "maple_green"],
         "weights": {"maple_green": 0.4}, "spacing": 15.0, "density": 0.6,
         "edge_min": 560.0, "edge_max": 870.0, "bounds": 880.0, "road_min": 50.0, "slope_max": 46.0,
         "scale": (1.0, 1.5), "sink": 0.4},
        {"name": "bushes", "exclude": KEEP_OUT, "exclude_poly": NO_TREES, "props": ["bush_a", "bush_b"],
         "spacing": 7.0, "density": 0.35, "road_min": 6.4, "road_max": 30.0, "slope_max": 35.0,
         "scale": (0.8, 1.3)},
        {"name": "hydrangeas", "props": ["azalea"], "spacing": 6.0, "density": 0.4, "road_min": 6.6,
         "road_max": 18.0, "regions": [{"circle": (0, 250, 190)}, {"circle": (-180, 90, 70)}],
         "exclude_poly": NO_TREES, "slope_max": 30.0, "scale": (0.9, 1.3)},
        {"name": "rocks_slope", "exclude": KEEP_OUT, "props": ["rock_a", "rock_b", "rock_c", "rock_d", "rock_e"],
         "spacing": 13.0, "density": 0.4, "road_min": 7.0, "road_max": 60.0, "slope_min": 16.0, "slope_max": 60.0,
         "scale": (0.7, 1.6), "sink": 0.3},
        {"name": "cliffs", "props": ["cliff_a", "cliff_b"], "spacing": 24.0, "density": 0.45, "road_min": 9.0,
         "road_max": 90.0, "slope_min": 28.0, "slope_max": 70.0, "scale": (0.8, 1.4), "sink": 0.8},
        {"name": "boulders_river", "props": ["boulder", "rock_a", "rock_d", "rock_e"], "spacing": 8.0,
         "density": 0.4, "water_max": 9.0, "water_clear": 0.5, "road_min": 8.0, "scale": (0.6, 1.3), "sink": 0.3},
        {"name": "reeds", "props": ["reeds"], "spacing": 3.0, "density": 0.6, "water_max": 5.0,
         "water_clear": 0.3, "road_min": 7.0, "occupy": False, "scale": (0.8, 1.3), "sink": 0.1},
        {"name": "paddy_reeds", "props": ["reeds"], "spacing": 7.0, "density": 0.25, "road_min": 8.0,
         "regions": [{"poly": TERRACES}, {"poly": PADDY_LOW}], "occupy": False, "scale": (0.5, 0.8), "sink": 0.2},
        {"name": "ferns", "props": ["fern"], "spacing": 5.0, "density": 0.35, "road_min": 6.0, "road_max": 90.0,
         "mask": {"scale": 170.0, "threshold": 0.0, "seed": 1, "sign": -1.0}, "occupy": False, "sink": 0.05},
        {"name": "logs", "exclude": KEEP_OUT, "exclude_poly": NO_TREES, "props": ["log", "stump"],
         "spacing": 32.0, "density": 0.3, "road_min": 8.0, "road_max": 70.0, "sink": 0.05},
        {"name": "grass", "props": ["grass_tuft"], "spacing": 3.0, "density": 0.45, "road_min": 5.8,
         "road_max": 85.0, "occupy": False, "scale": (0.8, 1.5), "sink": 0.05, "exclude_poly": NO_TREES},
        {"name": "flowers", "props": ["flowers_patch"], "spacing": 5.5, "density": 0.3, "road_min": 5.8,
         "road_max": 45.0, "occupy": False, "scale": (0.8, 1.3), "sink": 0.05, "exclude_poly": NO_TREES},
    ],
}
