"""Hanami Pass 花見峠 - spring noon. Lakeside village, a switchback climb, a summit
with a view over the lake, a vermilion bridge over the ravine, a gravel descent
through the blossom forest and a humped bridge back into the village straight.

Road points: (x, z, target height, {attributes applying from this point on}).
Driving direction: east along the lake, north up the switchbacks, west along the
ridge, south down the forest.
"""

POINTS = [
    (-400, 330, 18.0),                                   # 0 west end of the lakeside straight
    (-284, 342, 16.8, {"bridge": "vermilion"}),          # 1 humped bridge over the river
    (-250, 343, 19.0),                                   # 2
    (-216, 342, 17.0, {"bridge": None}),                 # 3
    (-120, 338, 17.4),                                   # 4 start line, village
    (-10, 322, 19.0),                                    # 5
    (90, 290, 22.0),                                     # 6
    (170, 225, 27.0),                                    # 7
    (215, 140, 33.0),                                    # 8
    (215, 60, 39.0),                                     # 9
    (250, 0, 44.0),                                      # 10
    (310, -20, 47.0),                                    # 11
    (345, -50, 49.0),                                    # 12 hairpin 1 (left)
    (325, -85, 51.0),                                    # 13
    (240, -95, 56.0),                                    # 14
    (140, -110, 61.0),                                   # 15
    (95, -130, 63.0),                                    # 16 hairpin 2 (right)
    (110, -165, 65.0),                                   # 17
    (200, -180, 70.0),                                   # 18
    (290, -200, 76.0),                                   # 19
    (335, -230, 79.0),                                   # 20 hairpin 3 (left)
    (315, -268, 82.0),                                   # 21
    (230, -300, 88.0),                                   # 22
    (130, -330, 96.0),                                   # 23
    (40, -345, 100.0),                                   # 24 summit
    (-50, -330, 98.0),                                   # 25
    (-92, -313, 96.0, {"bridge": "vermilion"}),          # 26 high bridge over the ravine
    (-168, -296, 94.0, {"bridge": None}),                # 27
    (-250, -300, 88.0, {"surface": "gravel"}),           # 28 forest gravel
    (-340, -260, 80.0),                                  # 29
    (-400, -180, 72.0),                                  # 30
    (-370, -90, 64.0),                                   # 31
    (-430, 0, 56.0),                                     # 32
    (-380, 90, 48.0),                                    # 33
    (-440, 170, 40.0),                                   # 34
    (-430, 235, 31.0, {"surface": "tarmac"}),            # 35
    (-445, 295, 23.0),                                   # 36
]

# ---------------------------------------------------------------------------- dressing
# Road-relative placement: (control point, metres along the road from it, lateral metres,
# + = right of the driving direction). Nothing rigid stands in the road corridor (half width +
# verge + 1.5 m = 6.4 m, wider at tight corners; lib/corridor.py moves offenders out);
# spectators stand 8 m or more from the road edge (road_clear 8), behind tape or bales. Order
# matters: singles first (they reserve their footprint), then lines (they skip occupied spots),
# then groups.

from lib.scatter import SPECTATOR_WEIGHTS, SPECTATORS  # noqa: E402 (the people kit)
FLAGS = ["flag_pole_pink", "flag_pole", "flag_pole_blue"]
LAP = 2952.11           # road length; checkpoints sit at LAP * k / 6 from the start line (cp 4)


def one(prop, cp, off, lat, face="road", **kw):
    return {"kind": "single", "prop": prop, "road_at": cp, "offset_m": off, "lateral": lat, "face": face, **kw}


def at(prop, x, z, face=0.0, **kw):
    return {"kind": "single", "prop": prop, "pos": (x, z), "face": face, **kw}


def row(props, cp, a, b, lat, spacing, sides=(1,), face="road_side", cp_to=None, **kw):
    kw.setdefault("sink", 0.12)
    props = [props] if isinstance(props, str) else list(props)
    return {"kind": "line", "props": props, "from_cp": cp, "from_offset": a, "to_cp": cp if cp_to is None else cp_to,
            "to_offset": b, "lateral": lat, "spacing": spacing, "sides": list(sides), "face": face, **kw}


def crowd(cp, off, lat, count, radius=5.0, face="road", clear=8.0, **kw):
    return {"kind": "group", "props": SPECTATORS, "weights": SPECTATOR_WEIGHTS, "count": count,
            "road_at": cp, "offset_m": off, "lateral": lat, "radius": radius, "road_clear": clear, "face": face,
            "yaw_jitter": 22.0, "scale": (0.95, 1.05), "sink": 0.05, **kw}


def bale_stack(cp, off, lat, face="road_side"):
    """Two square bales side by side and one on top: a hand-built stack."""
    return [one("hay_bale_square", cp, off - 1.0, lat, face), one("hay_bale_square", cp, off + 1.0, lat, face),
            one("hay_bale_square", cp, off, lat, face, y_offset=0.8, yaw_add=6.0)]


def gate(k):
    """Checkpoint dressing: a bale and a flag either side of the road (the runtime builds the
    fabric gate itself from map.checkpoints)."""
    off = LAP * k / 6.0
    return [one("hay_bale_square", 4, off, 7.9, "road_side"), one("hay_bale_square", 4, off, -7.9, "road_side"),
            one("flag_pole_pink", 4, off + 3.0, 9.0, "road_side"), one("flag_pole_blue", 4, off + 3.0, -9.0, "road_side")]


def hairpin(cp, outside, bales="hay_bale_round", banner=True, crowd_n=12, crowd_lat=19.0):
    """Outside of a hairpin: bale wall, sponsor banners and a crowd on the bank well back."""
    s = outside
    f = [row(bales, cp, -24.0, 24.0, 8.4, 1.5 if bales == "hay_bale_round" else 0.9, sides=(s,),
             face="road_side", yaw_add=90.0 if bales == "hay_bale_round" else 0.0)]
    if banner:
        f.append(row("banner_fence", cp, -9.0, 9.0, 10.6, 2.2, sides=(s,), face="road_side"))
    f += [row("tape_post", cp, -22.0, -10.0, 10.6, 2.3, sides=(s,), face="road_side"),
          row("tape_post", cp, 10.0, 22.0, 10.6, 2.3, sides=(s,), face="road_side"),
          crowd(cp, 0.0, s * crowd_lat, crowd_n, 6.0),
          crowd(cp, 16.0, s * (crowd_lat - 1.0), crowd_n // 3, 3.0),
          crowd(cp, -16.0, s * (crowd_lat - 1.0), crowd_n // 3, 3.0)]
    return f


def approach(cp, outside, sign, dist=(-95.0, -55.0)):
    """Warning sign and 100/50 boards before a bend, facing the approaching driver."""
    return [one(sign, cp, dist[0] - 25.0, outside * 6.7, "along", yaw_add=180.0),
            one("distance_board_100", cp, dist[0], outside * 6.9, "along", yaw_add=180.0),
            one("distance_board_50", cp, dist[1], outside * 6.9, "along", yaw_add=180.0)]


def torii_path(cp, off, lat0, n, step, side, shrine="hokora"):
    """A tunnel of small torii leading away from the road to a roadside shrine."""
    f = [one("torii_small", cp, off, side * (lat0 + k * step), "road", scale=1.15) for k in range(n)]
    end = lat0 + n * step + 1.5
    f += [one(shrine, cp, off, side * end, "road"),
          one("stone_lantern", cp, off - 2.2, side * (end - 1.2), "road", scale=0.8),
          one("stone_lantern", cp, off + 2.2, side * (end - 1.2), "road", scale=0.8)]
    return f


def _dressing():
    f = []
    # ------------------------------------------------------------ start / finish (cp 4)
    # road runs east here; right (+) is the lake side, left (-) the village plain
    f.append(one("start_arch", 4, 0.0, 0.0, "along", scale=1.35, sink=0.15))
    f += [one("tent", 4, -26.0, -19.0, "road"), one("tent", 4, -19.5, -19.5, "road", yaw_add=4.0),
          one("tent", 4, 26.0, 21.0, "road"),
          one("kei_truck", 4, -35.0, -21.0, "road", yaw_add=90.0), one("kei_truck", 4, -12.0, -22.5, "road", yaw_add=-80.0),
          one("kei_truck", 4, 33.0, 23.0, "road", yaw_add=100.0),
          one("marshal_post", 4, 6.0, -9.6, "road"), one("marshal_post", 4, -6.0, 9.6, "road"),
          one("bench", 4, -22.0, -14.8, "road"), one("vending_machine", 4, -30.5, -15.0, "road")]
    f += bale_stack(4, -46.0, 7.6) + bale_stack(4, -46.0, -7.6) + bale_stack(4, 46.0, 7.6) + bale_stack(4, 46.0, -7.6)
    f += [row("banner_fence", 4, -43.0, -4.0, 7.4, 3.1, sides=(-1, 1)),
          row("banner_fence", 4, 4.0, 43.0, 7.4, 3.1, sides=(-1, 1)),
          row(FLAGS, 4, -40.0, 40.0, 8.8, 8.0, sides=(-1, 1)),
          row("tape_post", 4, -40.0, 42.0, 11.0, 3.05, sides=(1,)),
          row("tape_post", 4, -8.0, 16.0, 11.0, 3.05, sides=(-1,)),
          crowd(4, 4.0, 15.0, 26, 9.0), crowd(4, -24.0, 14.5, 10, 5.0), crowd(4, 3.0, -14.0, 12, 5.0)]
    f += [one("distance_board_100", 4, -88.0, 6.9, "along", yaw_add=180.0),
          one("distance_board_50", 4, -50.0, 6.9, "along", yaw_add=180.0)]

    # ------------------------------------------------------------ village along the lakeside straight
    # west block (between the humped bridge and the start)
    f += [one("farmhouse_a", 4, -80.0, -23.0, "road", sink=0.35, radius=9.0),
          one("kura", 4, -67.0, -31.0, "road", sink=0.35, radius=4.5),
          one("farmhouse_b", 4, -57.0, -22.0, "road", sink=0.35, radius=9.0),
          one("water_well", 4, -68.5, -17.0, "road"),
          one("koinobori", 4, -69.0, -24.0, "road", yaw_add=70.0),
          one("vending_machine", 4, -47.5, -10.2, "road"), one("vending_machine", 4, -46.3, -10.2, "road"),
          one("shed", 4, -76.0, 15.0, "road", radius=3.4),
          one("farmhouse_b", 4, -61.0, 20.5, "road", sink=0.35, radius=9.0),
          one("sakura_young", 4, -70.0, 13.5, "road", scale=1.1),
          one("sakura_c", 4, -90.0, -16.0, "road"),
          one("sakura_young", 4, -51.0, -15.5, "road")]
    f += [row("stone_wall", 4, -89.0, -74.0, -14.8, 2.0, face="road_side"),
          row("stone_wall", 4, -63.0, -50.0, -14.8, 2.0, face="road_side"),
          row("fence_bamboo", 4, -72.0, -52.0, 13.2, 2.05, face="road_side"),
          row("lantern_string", 4, -86.0, -52.0, 9.0, 11.0, sides=(-1, 1))]
    # east block and the village shrine
    f += [one("torii_large", 4, 62.0, -15.5, "road"),
          one("shrine", 4, 62.0, -42.0, "road", sink=0.35, radius=7.0),
          one("shrine_bell", 4, 51.0, -35.0, "road"),
          one("stone_lantern", 4, 58.5, -20.5, "road"), one("stone_lantern", 4, 65.5, -20.5, "road"),
          one("stone_lantern", 4, 58.5, -30.0, "road"), one("stone_lantern", 4, 65.5, -30.0, "road"),
          one("sakura_a", 4, 52.0, -24.0, "road"), one("sakura_b", 4, 73.0, -26.0, "road"),
          one("sakura_c", 4, 72.0, -44.0, "road")]
    f += [one("jizo", 4, 68.0 + 0.8 * k, -8.6, "road") for k in range(6)]  # roku jizo by the shrine gate
    f += [one("farmhouse_a", 4, 88.0, -22.0, "road", sink=0.35, radius=9.0),
          one("kura", 4, 100.0, -30.0, "road", sink=0.35, radius=4.5),
          one("koinobori", 4, 97.0, -17.0, "road", yaw_add=60.0),
          one("bus_stop", 4, 106.0, -9.8, "road"),
          one("bench", 4, 106.0, -12.6, "road"),
          one("farmhouse_b", 4, 48.0, 20.5, "road", sink=0.35, radius=9.0),
          one("farmhouse_a", 4, 75.0, 21.0, "road", sink=0.35, radius=9.0),
          one("vending_machine", 4, 60.5, 10.0, "road"),
          one("sakura_young", 4, 61.5, 14.0, "road"),
          one("kei_truck", 4, 86.0, 12.5, "along", yaw_add=8.0)]
    f += [row("stone_wall", 4, 79.0, 96.0, -14.8, 2.0, face="road_side"),
          row("fence_wood", 4, 40.0, 56.0, 13.2, 2.05, face="road_side"),
          row("fence_wood", 4, 66.0, 84.0, 13.4, 2.05, face="road_side"),
          row("lantern_string", 4, 52.0, 96.0, 9.0, 11.0, sides=(-1, 1))]
    # utility poles along the whole village street, one side only
    f.append(row("telephone_pole", 3, 12.0, 0.0, -8.4, 34.0, face="road_side", cp_to=6))

    # ------------------------------------------------------------ rice paddies behind the village
    f += [at("scarecrow", -190.0, 262.0, 150.0), at("scarecrow", -312.0, 272.0, 200.0),
          at("hazagi", -172.0, 296.0, 5.0), at("hazagi", -214.0, 292.0, -8.0),
          at("hazagi", -336.0, 290.0, 12.0),
          at("shed", -160.0, 300.0, 180.0), at("kei_truck", -205.0, 300.0, 95.0)]
    f += [at("rice_paddy_marker", x, z, 0.0) for (x, z) in
          ((-200, 285), (-176, 280), (-196, 250), (-166, 244), (-300, 285), (-285, 262), (-320, 252))]

    # ------------------------------------------------------------ humped bridge (cp 1 .. 3) and the west hamlet
    f += [one("stone_lantern", 1, -4.0, 7.2, "road"), one("stone_lantern", 1, -4.0, -7.2, "road"),
          one("stone_lantern", 3, 5.0, 7.2, "road"), one("stone_lantern", 3, 5.0, -7.2, "road"),
          one("sakura_c", 1, -12.0, 12.0, "road"), one("sakura_a", 3, 12.0, -13.0, "road")]
    f += [crowd(2, -22.0, -19.0, 9, 4.5), crowd(2, 22.0, -19.0, 8, 4.5),
          crowd(2, -24.0, 20.0, 7, 4.0), crowd(2, 24.0, 21.0, 6, 4.0)]
    f += [one("farmhouse_a", 0, 12.0, 22.0, "road", sink=0.35, radius=9.0),
          one("kura", 0, 26.0, 19.0, "road", sink=0.35, radius=4.5),
          one("farmhouse_b", 36, 5.0, 21.0, "road", sink=0.35, radius=9.0),
          one("shed", 0, -12.0, 18.0, "road", radius=3.4),
          one("jizo", 0, 38.0, -8.4, "road"), one("hokora", 0, 40.0, -9.0, "road"),
          one("sakura_young", 0, 20.0, 14.0, "road"),
          one("kei_truck", 0, 0.0, 13.5, "along", yaw_add=175.0)]
    f += [row("stone_wall", 0, 4.0, 20.0, 15.0, 2.0, face="road_side"),
          row("telephone_pole", 36, -20.0, -8.0, -8.4, 36.0, face="road_side", cp_to=1)]

    # ------------------------------------------------------------ lakeside climb (cp 5 .. 8)
    f += [one("jizo", 6, -12.0, -8.6, "road"), one("stone_lantern", 6, -14.0, -8.8, "road", scale=0.8)]
    f += torii_path(6, 18.0, 10.0, 7, 2.4, 1)
    f += [one("farmhouse_b", 7, 4.0, 24.0, "road", sink=0.35, radius=9.0),
          one("shed", 7, 18.0, 17.0, "road", radius=3.4),
          one("kei_truck", 7, 12.0, 14.0, "along", yaw_add=160.0),
          one("koinobori", 7, -4.0, 16.0, "road", yaw_add=40.0),
          one("sakura_young", 7, -8.0, 13.0, "road")]
    f += [one("road_mirror", 8, 10.0, -6.7, "road"), one("sign_curve_right", 8, -45.0, 6.7, "along", yaw_add=180.0)]
    # the village power line keeps climbing with the road; a farm stall where the valley opens
    f.append(row("telephone_pole", 6, 22.0, -40.0, -8.4, 38.0, face="road_side", cp_to=9))
    f += [one("shed", 7, 58.0, -22.0, "road", radius=3.4), one("kei_truck", 7, 66.0, -16.0, "along", yaw_add=-10.0),
          one("hazagi", 7, 82.0, -22.0, "road"), one("scarecrow", 7, 96.0, -26.0, "road"),
          one("stone_lantern", 7, 100.0, 8.8, "road"), one("jizo", 7, 101.6, 8.5, "road"),
          one("sakura_young", 7, 104.0, 12.0, "road")]

    # ------------------------------------------------------------ crest after cp 9 and checkpoint 1
    f += gate(1)
    f += [row("tape_post", 9, 6.0, 36.0, -10.8, 3.05), row("tape_post", 9, 6.0, 36.0, 10.8, 3.05),
          crowd(9, 20.0, -16.0, 9, 5.0), crowd(9, 24.0, 16.5, 7, 4.0),
          one("marshal_post", 9, 40.0, 9.8, "road"), one("kei_truck", 9, 30.0, 27.0, "along", yaw_add=12.0)]
    f += [one("road_mirror", 10, 6.0, 6.7, "road"), one("sign_curve_left", 10, -40.0, -6.7, "along", yaw_add=180.0),
          one("shed", 11, -8.0, 27.0, "road", radius=3.4), one("log", 11, -20.0, 12.5, "along"),
          one("log", 11, -20.0, 13.2, "along"), one("log", 11, -19.8, 12.85, "along", y_offset=0.5)]
    # a mountain-road rest stop: vending machines, a bench and a lantern before the woods
    f += [one("vending_machine", 9, 88.0, 11.0, "road"), one("vending_machine", 9, 89.3, 11.0, "road"),
          one("bench", 9, 92.5, 11.6, "road"),
          one("stone_lantern", 9, 84.5, 10.5, "road", scale=0.8)]

    # ------------------------------------------------------------ hairpins
    f += approach(12, 1, "sign_curve_left") + hairpin(12, 1)
    # fans walking up from their cars to the hairpin
    f += [one("kei_truck", 13, 40.0, -22.0, "along", yaw_add=170.0), one("kei_truck", 13, 46.0, -22.5, "along", yaw_add=175.0),
          crowd(13, 34.0, -15.0, 5, 3.0),
          row(FLAGS, 13, 20.0, 60.0, -9.2, 10.0, sides=(-1,))]
    f += [one("road_mirror", 12, 26.0, 6.8, "road"), one("marshal_post", 12, 32.0, 10.0, "road"),
          one("stone_lantern", 14, 0.0, -8.6, "road"), one("jizo", 14, 1.4, -8.4, "road"),
          one("bench", 14, 5.0, -9.2, "road")]
    f += approach(16, -1, "sign_curve_right") + hairpin(16, -1, bales="tire_stack", banner=True)
    f += gate(2)
    f += [one("road_mirror", 16, 26.0, -6.8, "road"),
          one("hokora", 18, 52.0, -12.5, "road"), one("jizo", 18, 49.8, -8.6, "road"), one("jizo", 18, 50.6, -8.6, "road"),
          one("stone_lantern", 18, 55.0, -9.0, "road", scale=0.8), one("torii_small", 18, 52.0, -9.4, "road"),
          one("sakura_young", 18, 58.0, -13.0, "road"), one("bench", 18, 46.0, -9.4, "road"),
          one("road_mirror", 18, 90.0, 6.8, "road")]
    f += [one("kei_truck", 18, 34.0, 10.5, "along", yaw_add=4.0), crowd(18, 40.0, 15.0, 4, 2.5)]
    f += approach(20, 1, "sign_curve_left") + hairpin(20, 1, bales="hay_bale_square")
    f += [one("road_mirror", 20, 26.0, 6.8, "road"), one("marshal_post", 20, -32.0, 10.0, "road")]
    f += [one("torii_small", 21, 40.0, -9.6, "road"), one("hokora", 21, 40.0, -12.8, "road"),
          one("stone_lantern", 21, 37.5, -10.4, "road", scale=0.8), one("stone_lantern", 21, 42.5, -10.4, "road", scale=0.8),
          row(FLAGS, 21, 22.0, 54.0, 9.2, 8.0, sides=(1,))]
    # masonry retaining walls through the cutting before the summit
    f += [row("stone_wall", 22, -30.0, 30.0, 9.2, 2.0, sides=(-1, 1)),
          one("stone_lantern", 22, 34.0, -8.8, "road"), one("jizo", 22, 36.0, -8.5, "road")]

    # ------------------------------------------------------------ summit viewpoint (cp 24)
    # driving west; the view over the lake is on the left (-)
    f += gate(3)
    f += [one("bench", 24, -6.0, -21.0, "away"), one("bench", 24, 0.0, -22.0, "away"),
          one("bench", 24, 6.0, -21.0, "away"),
          one("stone_lantern", 24, -12.0, -11.5, "road"), one("stone_lantern", 24, 12.0, -11.5, "road"),
          one("torii_small", 24, 16.0, -13.5, "road"), one("hokora", 24, 16.0, -17.5, "road"),
          one("jizo", 24, 18.0, -16.5, "road"), one("jizo", 24, 18.8, -16.5, "road"),
          one("kei_truck", 24, -20.0, -15.0, "road", yaw_add=90.0), one("kei_truck", 24, -24.0, -15.5, "road", yaw_add=95.0),
          one("tent", 24, 26.0, -17.0, "road"), one("vending_machine", 24, -10.0, -15.5, "road"),
          one("sakura_c", 24, -30.0, -18.0, "road"), one("sakura_a", 24, 32.0, -24.0, "road"),
          one("marshal_post", 24, 4.0, 9.8, "road")]
    f += [row(FLAGS, 24, -16.0, 16.0, 9.0, 8.0, sides=(1,)),
          row("tape_post", 24, -8.0, 10.0, -11.0, 3.05, sides=(-1,)),
          crowd(24, 0.0, -17.0, 8, 4.5, face="away"), crowd(24, 8.0, -15.0, 5, 3.0)]

    # ------------------------------------------------------------ high bridge over the ravine (cp 26 .. 27)
    f += [one("stone_lantern", 26, -4.0, 7.2, "road"), one("stone_lantern", 26, -4.0, -7.2, "road"),
          one("stone_lantern", 27, 4.0, 7.2, "road"), one("stone_lantern", 27, 4.0, -7.2, "road"),
          crowd(26, -14.0, 17.0, 9, 4.5), crowd(26, -18.0, -17.0, 7, 4.0), crowd(27, 10.0, 16.5, 8, 4.0),
          row("tape_post", 26, -26.0, -6.0, 10.8, 3.05, sides=(-1, 1))]

    # ------------------------------------------------------------ gravel stage (cp 28 .. 35)
    f += [one("tent", 28, -4.0, 15.0, "road"), one("kei_truck", 28, 5.0, 15.5, "road", yaw_add=85.0),
          one("marshal_post", 28, 0.0, -9.8, "road"), one("traffic_cone", 28, -2.0, 6.4, "road"),
          one("traffic_cone", 28, 2.0, 6.4, "road"), one("traffic_cone", 28, -2.0, -6.4, "road")]
    f += bale_stack(28, -8.0, -8.0) + [row(FLAGS, 28, -12.0, 12.0, 9.0, 8.0, sides=(-1, 1)),
                                       crowd(28, 0.0, 16.0, 7, 4.0)]
    f += torii_path(29, 20.0, 12.0, 9, 2.5, -1)
    # fans camping on the bank above the gravel: tent, van and a small crowd behind tape
    f += [one("tent", 29, 72.0, -22.0, "road"), one("kei_truck", 29, 80.0, -22.5, "along", yaw_add=10.0),
          crowd(29, 76.0, -17.0, 5, 3.0), row("tape_post", 29, 64.0, 88.0, -11.0, 3.05, sides=(-1,))]
    f += gate(4)
    # forestry yard and a mountain shrine in the cedars
    f += [one("shed", 30, 52.0, -30.0, "road", radius=3.4), one("kei_truck", 30, 44.0, -22.0, "along", yaw_add=15.0, sink=0.25),
          one("log", 30, 60.0, -18.0, "along"), one("log", 30, 60.0, -18.7, "along"), one("log", 30, 60.0, -19.4, "along"),
          one("log", 30, 60.3, -18.35, "along", y_offset=0.5), one("log", 30, 60.3, -19.05, "along", y_offset=0.5),
          one("marshal_post", 30, 30.0, 9.8, "road"), one("sign_curve_right", 31, -60.0, -6.7, "along", yaw_add=180.0)]
    f += [one("torii_large", 31, 70.0, -12.5, "road", sink=0.3), one("stone_lantern", 31, 66.0, -16.0, "road"),
          one("stone_lantern", 31, 74.0, -16.0, "road"), one("shrine", 31, 70.0, -27.0, "road", sink=0.35, radius=7.0),
          one("jizo", 31, 62.0, -8.6, "road"), one("jizo", 31, 62.8, -8.6, "road"),
          one("sign_curve_left", 32, -55.0, 6.7, "along", yaw_add=180.0)]
    f += [one("stone_lantern", 30, 0.0, 8.8, "road"), one("jizo", 30, 2.0, 8.4, "road"),
          row("tape_post", 31, -10.0, 14.0, 11.0, 3.05, sides=(-1,)), crowd(31, 2.0, -16.0, 8, 4.5),
          one("shed", 32, 42.0, 24.0, "road", radius=3.4), one("kei_truck", 33, 0.0, -24.0, "along", yaw_add=20.0),
          one("log", 32, 12.0, 12.5, "along"), one("log", 32, 12.0, 13.2, "along"),
          one("log", 32, 12.3, 12.85, "along", y_offset=0.5),
          row("tape_post", 33, -10.0, 14.0, 11.0, 3.05, sides=(1,)), crowd(33, 2.0, 16.5, 8, 4.5),
          one("hokora", 34, -10.0, -9.2, "road"), one("stone_lantern", 34, -12.0, -8.8, "road", scale=0.8),
          one("bench", 33, 30.0, -12.0, "road"), one("kei_truck", 33, 40.0, -14.0, "along", yaw_add=-5.0, sink=0.25),
          crowd(33, 32.0, -16.0, 4, 3.0), one("road_mirror", 33, 58.0, 6.8, "road")]
    f += gate(5)
    f += [one("marshal_post", 35, 0.0, 9.8, "road"), one("traffic_cone", 35, -2.0, 6.4, "road"),
          one("traffic_cone", 35, 2.0, 6.4, "road")] + bale_stack(35, 6.0, -8.0)
    # back among the farms: a barn, a hay rack and a parked truck on the way to the village
    f += [one("farmhouse_b", 35, 44.0, 24.0, "road", sink=0.35, radius=9.0), one("hazagi", 35, 30.0, 16.0, "road"),
          one("kei_truck", 35, 56.0, 14.5, "along", yaw_add=170.0), one("koinobori", 35, 36.0, 22.0, "road", yaw_add=50.0)]
    return f


DRESSING = _dressing()

PADDY_EAST = [(-224, 298), (-150, 300), (-146, 236), (-220, 228)]
PADDY_WEST = [(-390, 298), (-302, 304), (-298, 250), (-382, 236)]
# village, paddies and viewpoints: trees, bushes and rocks keep out (explicit garden trees remain)
KEEP_OUT = [(-120, 338, 40), (-185, 325, 32), (-45, 322, 42), (-392, 345, 26), (-186, 266, 42),
            (-342, 272, 48), (35, -360, 26), (-250, -300, 14)]

# ---------------------------------------------------------------------------- garage (Garage)
# The Sakura Rally service workshop on the village side of the start straight, before the start
# line (the branch to Momiji leaves after the finish, on the lake side). lib/garage.py turns this
# into a drive-through lay-by (a paved road lot), a pad under the workshop, a keep-out for props
# and map.json "garage"; scripts/game/garage_set.gd builds the workshop, its lights, banners and
# colliders there at runtime. Numbers are road-relative metres like the dressing (lateral + =
# right of the driving direction). The workshop footprint includes its eaves; GarageSet's
# layout assumes these sizes.
GARAGE = {
    "road_at": 4, "offset_m": -28.0,  # the display spot, along the road
    "lateral": -11.0,                 # ... and beside it: the car stands 11 m left of the centreline
    "lot": {"lateral": -10.0, "width": 14.0, "length": 38.0, "corner": 6.0, "surface": "tarmac"},
    "workshop": {"lateral": -22.0, "width": 15.0, "depth": 11.0, "blend": 8.0},
    "keep_out": 3.0,
    # sakura and lanterns around it (placed like the dressing, outside the keep-out)
    "dressing": [
        one("sakura_a", 4, -40.0, -36.0, "road"), one("sakura_c", 4, -24.0, -37.5, "road"),
        one("sakura_b", 4, -12.0, -35.0, "road"), one("sakura_young", 4, -54.0, -24.0, "road"),
        one("sakura_young", 4, -3.0, -26.0, "road", scale=1.15),
        one("stone_lantern", 4, -52.5, -8.0, "road"), one("stone_lantern", 4, -4.0, -8.5, "road"),
        one("lantern_string", 4, -54.0, -14.0, "along", yaw_add=90.0),
        one("bench", 4, -2.5, -17.0, "road"), one("vending_machine", 4, -2.8, -20.8, "road"),
    ],
}

SPEC = {
    "garage": GARAGE,
    "id": "hanami",
    "seed": 11,
    "season": "spring",
    "atmosphere": "spring_noon",
    "size": 1600.0,
    "cell": 4.0,
    "play_half": 600.0,
    "road": {
        "points": POINTS,
        "width": 7.0,
        "verge": 1.4,
        "surface": "tarmac",
        "start_cp": 4,
        "start_offset": 0.0,
        "grid_back": 12.0,
        "checkpoints": 6,
        "bank_gain": 14.0,
        "bank_max": 0.05,
        "crests": [
            {"at": 9, "offset": 20.0, "height": 1.2, "width": 10.0},
            {"at": 31, "offset": -30.0, "height": 1.6, "width": 9.0},
            {"at": 33, "offset": -35.0, "height": 1.4, "width": 9.0},
        ],
    },
    "terrain": {
        "level_sigma": 110.0,
        "relief": {"amp": 30.0, "scale": 240.0, "near": 35.0, "far": 210.0, "detail": 1.3, "rise": 45.0},
        "hills": [
            {"pos": (430, -400), "radius": 280, "height": 120, "ridged": True},
            {"pos": (40, -10), "radius": 150, "height": 28},
            {"pos": (-620, -120), "radius": 220, "height": 70, "ridged": True},
            {"pos": (-30, 235), "radius": 55, "height": 10},
            {"pos": (150, 520), "radius": 200, "height": 45},
        ],
        "boundary": {"start": 560.0, "end": 790.0, "height": 210.0},
        # rice paddies on the plain behind the village, either side of the river
        "terraces": [
            {"poly": PADDY_EAST, "step": 1.1, "edge": 7.0},
            {"poly": PADDY_WEST, "step": 1.3, "edge": 7.0},
        ],
    },
    "lake": {
        "poly": [(-400, 432), (-330, 396), (-240, 386), (-150, 391), (-60, 401), (18, 430), (48, 482),
                 (18, 540), (-80, 574), (-200, 584), (-322, 570), (-410, 520)],
        "level": 12.0,
        "depth": 5.0,
        "shore": 45.0,
        "wobble": 16.0,
    },
    "river": {
        "points": [(-40, -780, 120), (-60, -600, 104), (-100, -450, 90), (-128, -304, 80), (-165, -175, 66),
                   (-160, -45, 52), (-200, 90, 38), (-240, 210, 26), (-252, 300, 17), (-250, 343, 14.5),
                   (-240, 400, 12.0), (-236, 440, 11.6)],
        "width": 9.0,
        "meander": 14.0,
        "pins": [(-250, 343), (-128, -304)],
        "depth": 1.3,
    },
    "backdrop": {"color": "8fb4ad", "color_far": "b7cad8", "snow": 470.0, "snow_color": "f5f3f4",
                 "height": 560.0, "base": 140.0, "inner": 170.0, "scale": 430.0},
    "palette": {
        "grass": ["9ccb6b", "86bf5f", "b4d67f"],
        "grass_dry": "c8d48d",
        "verge_grass": "bddc8c",
        "forest_floor": "6f9f55",
        "petal": "f5c6d5",
        "field": "b9d27c",
        "field2": "c9b98a",
        "rock": "aaa59e",
        "rock_dark": "8f8b8a",
        "dirt": "bb9a72",
        "sand": "e7dab4",
        "mountain": "6d9a62",
        "rail": "d8dee3",
        "rail_post": "9aa4ae",
        "bridge_rail": "e24a31",
        "bridge_cap": "f2c552",
        "stone": "bdb6a9",
        "wood": "a47148",
        "wood_dark": "6b4d42",
    },
    "materials": {
        "road": {"gravel_color": "c2ab86", "gravel_dark": "9d8566", "tarmac_color": "575d70",
                 "line_color": "f5f2ea", "centre_line": "f5f2ea", "petal_color": "f7c9d7"},
        "water": {"shallow": "8fd0cf", "deep": "3f86b0"},
    },
    "features": DRESSING,
    "scatter": [
        {"name": "sakura_road", "exclude": KEEP_OUT, "props": ["sakura_a", "sakura_b", "sakura_c"], "weights": {"sakura_c": 0.6},
         "spacing": 10.0, "density": 0.9, "road_min": 8.5, "road_max": 55.0, "road_peak": (12.0, 55.0),
         "mask": {"scale": 170.0, "threshold": -0.08, "seed": 1}, "slope_max": 30.0, "scale": (0.85, 1.2),
         "sink": 0.3},
        {"name": "sakura_lake", "exclude": KEEP_OUT, "props": ["sakura_a", "sakura_c"], "spacing": 13.0, "density": 0.55,
         "road_min": 9.0, "regions": [{"circle": (-170, 420, 280)}, {"circle": (40, 230, 150)}],
         "slope_max": 28.0, "scale": (0.9, 1.25), "sink": 0.3},
        {"name": "cedar_forest", "exclude": KEEP_OUT, "props": ["cedar_a", "cedar_b"], "spacing": 8.5, "density": 0.85,
         "road_min": 12.0, "mask": {"scale": 170.0, "threshold": 0.02, "seed": 1, "sign": -1.0},
         "h_min": 35.0, "slope_max": 40.0, "scale": (0.85, 1.3), "sink": 0.3},
        {"name": "pines", "exclude": KEEP_OUT, "props": ["pine_a", "pine_b"], "spacing": 16.0, "density": 0.35, "road_min": 10.0,
         "slope_max": 35.0, "scale": (0.8, 1.2), "sink": 0.3},
        {"name": "bamboo", "exclude": KEEP_OUT, "props": ["bamboo_clump"], "spacing": 13.0, "density": 0.45, "road_min": 9.0,
         "regions": [{"circle": (80, 240, 130)}, {"circle": (-330, -60, 110)}], "scale": (0.9, 1.2), "sink": 0.2},
        {"name": "mountain_forest", "props": ["cedar_a", "cedar_b", "pine_a"], "spacing": 15.0, "density": 0.6,
         "edge_min": 520.0, "edge_max": 780.0, "bounds": 790.0, "road_min": 60.0, "slope_max": 44.0,
         "scale": (1.0, 1.5), "sink": 0.4},
        {"name": "bushes", "exclude": KEEP_OUT, "props": ["bush_a", "bush_b", "azalea"], "weights": {"azalea": 1.4}, "spacing": 7.0,
         "density": 0.35, "road_min": 6.2, "road_max": 30.0, "slope_max": 35.0, "scale": (0.8, 1.3)},
        {"name": "rocks_slope", "exclude": KEEP_OUT, "props": ["rock_a", "rock_b", "rock_c", "rock_d", "rock_e"], "spacing": 13.0,
         "density": 0.4, "road_min": 7.0, "slope_min": 16.0, "slope_max": 60.0, "scale": (0.7, 1.6), "sink": 0.3},
        {"name": "cliffs", "props": ["cliff_a", "cliff_b"], "spacing": 26.0, "density": 0.5, "road_min": 9.0,
         "slope_min": 28.0, "slope_max": 70.0, "scale": (0.8, 1.4), "sink": 0.8},
        {"name": "boulders_river", "props": ["boulder", "rock_a", "rock_d"], "spacing": 9.0, "density": 0.45,
         "water_max": 9.0, "water_clear": 0.5, "road_min": 8.0, "scale": (0.6, 1.3), "sink": 0.3},
        {"name": "reeds", "props": ["reeds"], "spacing": 3.2, "density": 0.55, "water_max": 5.0,
         "water_clear": 0.3, "road_min": 7.0, "occupy": False, "scale": (0.8, 1.3), "sink": 0.1},
        {"name": "ferns", "props": ["fern"], "spacing": 5.0, "density": 0.35, "road_min": 6.0, "road_max": 90.0,
         "mask": {"scale": 170.0, "threshold": 0.02, "seed": 1, "sign": -1.0}, "occupy": False, "sink": 0.05},
        {"name": "logs", "exclude": KEEP_OUT, "props": ["log", "stump"], "spacing": 30.0, "density": 0.35, "road_min": 8.0,
         "road_max": 70.0, "sink": 0.05},
        {"name": "grass", "props": ["grass_tuft"], "spacing": 3.4, "density": 0.4, "road_min": 5.8,
         "road_max": 85.0, "occupy": False, "scale": (0.7, 1.4), "sink": 0.05},
        {"name": "flowers", "props": ["flowers_patch"], "spacing": 6.0, "density": 0.28, "road_min": 5.8,
         "road_max": 45.0, "occupy": False, "scale": (0.8, 1.3), "sink": 0.05},
    ],
}
