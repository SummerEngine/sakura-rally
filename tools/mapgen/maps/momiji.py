"""Momiji Valley 紅葉谷 - autumn golden hour. An onsen village on the river, a tarmac
run north up the valley floor beside the river and under the shrine hill towards the
waterfall gorge, a stone bridge at the gorge mouth, a long gravel stage switchbacking
up through the maple forest to the west ridge with the view down over the rice
terraces and the valley, and a sweeping tarmac descent back over the vermilion
bridge into the village.

Road points: (x, z, target height, {attributes applying from this point on}).
Driving direction (z grows southwards): east through the village, north up the east
valley, west over the stone bridge, the switchbacks and the ridge southwards, then
the descent loop west and back east over the river.
"""

POINTS = [
    (-196, 398, 35.0),                                   # 0 end of the descent
    (-120, 396, 30.6, {"bridge": "vermilion"}),          # 1 vermilion bridge over the river
    (-93, 396, 31.6),                                    # 2
    (-66, 395, 30.2, {"bridge": None}),                  # 3
    (0, 384, 28.0),                                      # 4 onsen village, start line
    (52, 362, 28.0),                                     # 5
    (88, 310, 30.0),                                     # 6
    (100, 234, 33.5),                                    # 7
    (88, 150, 37.5),                                     # 8
    (100, 70, 41.5),                                     # 9 under the shrine hill
    (86, -12, 45.0),                                     # 10
    (100, -96, 49.0),                                    # 11
    (88, -176, 52.5),                                    # 12 waterfall straight ahead
    (68, -248, 54.5),                                    # 13
    (48, -284, 55.5, {"bridge": "stone"}),               # 14 stone bridge at the gorge mouth
    (20, -296, 56.5),                                    # 15
    (-10, -298, 57.0, {"bridge": None, "surface": "gravel"}),  # 16 gravel stage
    (-46, -282, 58.5),                                   # 17
    (-62, -220, 61.0),                                   # 18
    (-68, -140, 64.5),                                   # 19
    (-74, -80, 67.5),                                    # 20
    (-90, -48, 69.0),                                    # 21 hairpin 1 (right)
    (-114, -44, 70.0),                                   # 22
    (-130, -66, 71.5),                                   # 23
    (-134, -140, 75.5),                                  # 24
    (-138, -220, 79.5),                                  # 25
    (-148, -278, 82.5),                                  # 26
    (-170, -300, 84.0),                                  # 27 hairpin 2 (left)
    (-196, -290, 85.5),                                  # 28
    (-206, -236, 88.5),                                  # 29
    (-214, -160, 92.0),                                  # 30
    (-232, -80, 95.0),                                   # 31 west ridge
    (-242, 10, 97.5),                                    # 32
    (-228, 96, 98.5),                                    # 33
    (-250, 180, 97.0),                                   # 34
    (-266, 248, 94.0, {"surface": "tarmac"}),            # 35 descent
    (-306, 304, 87.0),                                   # 36
    (-356, 350, 79.0),                                   # 37
    (-384, 416, 71.0),                                   # 38
    (-364, 478, 62.0),                                   # 39
    (-306, 500, 53.0),                                   # 40
    (-252, 468, 44.0),                                   # 41
]

START_CP = 4

# fields: rice terraces below the ridge, paddies by the village and in the east valley
FIELDS = [
    [(-212, 30), (-206, 150), (-168, 214), (-118, 196), (-104, 110), (-126, 36), (-170, 16)],
    [(-24, 428), (60, 418), (132, 394), (190, 424), (174, 506), (60, 524), (-12, 502)],
    [(124, 292), (126, 150), (176, 126), (206, 180), (200, 286)],
]
GORGE = [(6, -300), (40, -300), (72, -420), (62, -450), (36, -440), (18, -380)]
VILLAGE = (0, 384, 95)  # centre x, z, radius for keeping the forest out of the streets


def house(off, lat, prop, pad=9.0, cp=START_CP, yaw_add=0.0):
    """A building facing the road on a flattened pad (returns feature, pad)."""
    return ({"kind": "single", "prop": prop, "road_at": cp, "offset_m": off, "lateral": lat,
             "face": "road", "yaw_add": yaw_add, "sink": 0.15},
            {"road_at": cp, "offset_m": off, "lateral": lat, "radius": pad, "blend": 9.0})


def hairpin(cp, side):
    """Rally dressing for a hairpin whose apex is near control point `cp`; `side` is the
    outside of the corner (-1 left, +1 right of the driving direction). Its warning signs,
    chevrons and guardrail come from lib/roadside.py."""
    return [
        {"kind": "crowd", "road_at": cp, "offset_m": 10.0, "side": side, "length": 16.0, "gap": 6.8,
         "count": 9, "depth": 4.0, "extras": ["flag_pole", "tent", "flag_pole_blue"], "extras_spacing": 5.0},
        {"kind": "single", "prop": "marshal_post", "road_at": cp, "offset_m": 26.0, "lateral": side * 9.0,
         "face": "road"},
        {"kind": "single", "prop": "tire_stack", "road_at": cp, "offset_m": 0.0, "lateral": -side * 6.8},
        {"kind": "single", "prop": "tire_stack", "road_at": cp, "offset_m": 1.5, "lateral": -side * 7.4},
    ]


# village street around the start line (offsets from the start, + = east / onwards;
# lateral - = north side towards the river, + = south side towards the paddies)
_village = [
    house(-72.0, -17.0, "farmhouse_b", pad=10.0),
    house(-46.0, 17.5, "farmhouse_a", pad=10.0),
    house(-44.0, -16.0, "kura", pad=6.0),
    house(-26.0, 17.0, "farmhouse_b", pad=10.0),
    house(28.0, -16.0, "kura", pad=6.0),
    house(46.0, -17.5, "farmhouse_a", pad=10.0),
    house(32.0, 16.0, "shed", pad=6.0),
    house(50.0, 17.5, "farmhouse_a", pad=10.0),
    house(72.0, 17.0, "kura", pad=6.0),
]
_ridge_farm = [
    house(30.0, 20.0, "farmhouse_b", pad=10.0, cp=38),
    house(48.0, 17.0, "shed", pad=6.0, cp=38),
    house(10.0, 17.0, "kura", pad=6.0, cp=38),
]
_valley_farm = [
    house(-30.0, 19.0, "farmhouse_a", pad=10.0, cp=7),
    house(-12.0, 16.0, "kura", pad=6.0, cp=7),
    house(20.0, 16.0, "shed", pad=6.0, cp=7),
]

PADS = [p for _, p in _village + _ridge_farm + _valley_farm] + [
    {"pos": (192, 58), "radius": 11.0, "blend": 10.0},            # shrine terrace on the hill
    {"road_at": START_CP, "offset_m": 0.0, "lateral": 13.5, "radius": 10.0, "blend": 8.0},  # service park
    {"road_at": 32, "offset_m": -40.0, "lateral": -14.0, "radius": 8.0, "blend": 8.0},  # ridge viewpoint
]

FEATURES = [
    {"kind": "clear", "road_at": START_CP, "offset_m": -8.0, "radius": 16.0},
    # ---------------------------------------------------------------- start area
    {"kind": "single", "prop": "start_arch", "road_at": START_CP, "offset_m": 0.0, "face": "along",
     "scale": 1.4, "sink": 0.05},
    {"kind": "line", "props": ["banner_fence"], "from_cp": START_CP, "from_offset": -30.0, "to_cp": START_CP,
     "to_offset": 22.0, "spacing": 3.2, "lateral": 7.6, "sides": [-1, 1], "face": "road_side", "force": True},
    {"kind": "line", "props": ["flag_pole", "flag_pole_blue", "flag_pole_pink"], "from_cp": START_CP,
     "from_offset": -34.0, "to_cp": START_CP, "to_offset": 26.0, "spacing": 10.0, "lateral": 9.2,
     "sides": [-1, 1], "face": "road_side", "force": True},
    {"kind": "single", "prop": "tent", "road_at": START_CP, "offset_m": -6.0, "lateral": 13.5, "face": "road"},
    {"kind": "single", "prop": "tent", "road_at": START_CP, "offset_m": 0.0, "lateral": 13.5, "face": "road"},
    {"kind": "single", "prop": "tent", "road_at": START_CP, "offset_m": 6.0, "lateral": 13.5, "face": "road"},
    {"kind": "single", "prop": "kei_truck", "road_at": START_CP, "offset_m": -4.0, "lateral": 19.0,
     "face": "along", "yaw_add": 90.0},
    {"kind": "single", "prop": "kei_truck", "road_at": START_CP, "offset_m": 4.0, "lateral": 19.5,
     "face": "along", "yaw_add": 80.0},
    {"kind": "single", "prop": "tire_stack", "road_at": START_CP, "offset_m": 11.0, "lateral": 11.5},
    {"kind": "single", "prop": "tire_stack", "road_at": START_CP, "offset_m": 12.0, "lateral": 12.2},
    {"kind": "single", "prop": "marshal_post", "road_at": START_CP, "offset_m": 16.0, "lateral": -11.0,
     "face": "road"},
    {"kind": "crowd", "road_at": START_CP, "offset_m": -12.0, "side": -1, "length": 22.0, "gap": 4.1,
     "barrier": "hay_bale_square", "count": 14, "depth": 3.0},
    {"kind": "single", "prop": "tent", "road_at": START_CP, "offset_m": 6.0, "lateral": -14.0, "face": "road"},
    # ---------------------------------------------------------------- onsen village
    *[h for h, _ in _village],
    {"kind": "line", "props": ["lantern_string"], "from_cp": 3, "from_offset": 12.0, "to_cp": START_CP,
     "to_offset": -38.0, "spacing": 11.0, "lateral": 7.0, "sides": [-1, 1], "face": "road_side", "force": True},
    {"kind": "line", "props": ["lantern_string"], "from_cp": START_CP, "from_offset": 30.0, "to_cp": 5,
     "to_offset": 20.0, "spacing": 11.0, "lateral": 7.0, "sides": [-1, 1], "face": "road_side", "force": True},
    {"kind": "line", "props": ["stone_lantern"], "from_cp": 3, "from_offset": 8.0, "to_cp": 5,
     "to_offset": 26.0, "spacing": 11.0, "lateral": 8.4, "sides": [-1, 1], "face": "road"},
    {"kind": "single", "prop": "vending_machine", "road_at": START_CP, "offset_m": 36.0, "lateral": -9.2,
     "face": "road"},
    {"kind": "single", "prop": "vending_machine", "road_at": START_CP, "offset_m": 37.3, "lateral": -9.2,
     "face": "road"},
    {"kind": "single", "prop": "bench", "road_at": START_CP, "offset_m": 40.0, "lateral": -9.2, "face": "road"},
    {"kind": "single", "prop": "bus_stop", "road_at": 3, "offset_m": 18.0, "lateral": -9.5, "face": "road"},
    {"kind": "single", "prop": "water_well", "road_at": START_CP, "offset_m": 40.0, "lateral": 10.5},
    {"kind": "single", "prop": "kei_truck", "road_at": START_CP, "offset_m": -36.0, "lateral": 10.5,
     "face": "along"},
    {"kind": "group", "props": ["persimmon_tree"], "count": 7, "radius": 45.0, "road_at": START_CP,
     "lateral": 34.0, "road_clear": 9.0, "scale": (0.9, 1.15)},
    {"kind": "group", "props": ["persimmon_tree", "ginkgo", "maple_red"], "count": 6, "radius": 30.0,
     "road_at": START_CP, "offset_m": 20.0, "lateral": -34.0, "road_clear": 9.0, "scale": (0.9, 1.15)},
    # rotenburo: a bamboo-fenced bath on the river bank behind the village
    {"kind": "row", "prop": "fence_bamboo", "from": (-44, 350), "to": (-44, 366), "spacing": 2.0,
     "face": "across", "force": True},
    {"kind": "row", "prop": "fence_bamboo", "from": (-44, 366), "to": (-26, 366), "spacing": 2.0,
     "face": "across", "force": True},
    {"kind": "row", "prop": "fence_bamboo", "from": (-26, 366), "to": (-26, 350), "spacing": 2.0,
     "face": "across", "force": True},
    {"kind": "single", "prop": "stone_lantern", "pos": (-22, 368), "face": 0.0},
    {"kind": "single", "prop": "shed", "pos": (-35, 372), "face": 0.0},
    # rice harvest south of the village
    {"kind": "row", "prop": "hazagi", "from": (20, 446), "to": (56, 456), "spacing": 5.0, "face": "across"},
    {"kind": "row", "prop": "hazagi", "from": (60, 474), "to": (100, 480), "spacing": 5.0, "face": "across"},
    {"kind": "row", "prop": "hazagi", "from": (112, 432), "to": (142, 424), "spacing": 5.0, "face": "across"},
    {"kind": "single", "prop": "scarecrow", "pos": (86, 454), "face": 20.0},
    {"kind": "single", "prop": "scarecrow", "pos": (16, 474), "face": -30.0},
    {"kind": "row", "prop": "rice_paddy_marker", "from": (0, 438), "to": (140, 408), "spacing": 14.0,
     "face": "along"},
    # ---------------------------------------------------------------- vermilion bridge approach
    {"kind": "single", "prop": "stone_lantern", "road_at": 1, "offset_m": -4.0, "lateral": 6.8, "face": "road"},
    {"kind": "single", "prop": "stone_lantern", "road_at": 1, "offset_m": -4.0, "lateral": -6.8, "face": "road"},
    {"kind": "single", "prop": "stone_lantern", "road_at": 3, "offset_m": 4.0, "lateral": 6.8, "face": "road"},
    {"kind": "single", "prop": "stone_lantern", "road_at": 3, "offset_m": 4.0, "lateral": -6.8, "face": "road"},
    {"kind": "single", "prop": "torii_large", "road_at": 0, "offset_m": 10.0, "lateral": 10.0, "face": "road",
     "yaw_add": 90.0},
    # ---------------------------------------------------------------- east valley
    {"kind": "line", "props": ["telephone_pole"], "from_cp": 6, "from_offset": 0.0, "to_cp": 12,
     "to_offset": 0.0, "spacing": 42.0, "lateral": 8.0, "sides": [1], "face": "along"},
    *[h for h, _ in _valley_farm],
    {"kind": "single", "prop": "bus_stop", "road_at": 7, "offset_m": 4.0, "lateral": 9.5, "face": "road"},
    {"kind": "single", "prop": "vending_machine", "road_at": 7, "offset_m": 8.0, "lateral": 9.2, "face": "road"},
    {"kind": "single", "prop": "kei_truck", "road_at": 7, "offset_m": -2.0, "lateral": 11.0, "face": "along"},
    {"kind": "row", "prop": "hazagi", "from": (136, 250), "to": (150, 214), "spacing": 5.0, "face": "across"},
    {"kind": "row", "prop": "hazagi", "from": (160, 200), "to": (170, 164), "spacing": 5.0, "face": "across"},
    {"kind": "single", "prop": "scarecrow", "pos": (176, 236), "face": -60.0},
    {"kind": "single", "prop": "jizo", "road_at": 8, "offset_m": -20.0, "lateral": -7.5, "face": "road"},
    {"kind": "single", "prop": "jizo", "road_at": 8, "offset_m": -18.8, "lateral": -7.5, "face": "road"},
    {"kind": "single", "prop": "jizo", "road_at": 8, "offset_m": -17.6, "lateral": -7.5, "face": "road"},
    {"kind": "single", "prop": "hokora", "road_at": 11, "offset_m": 10.0, "lateral": -8.0, "face": "road"},
    # shrine hill: torii at the road, lantern path up to the shrine
    {"kind": "single", "prop": "torii_large", "road_at": 9, "offset_m": -8.0, "lateral": 11.0,
     "face": "road", "sink": 0.1},
    {"kind": "single", "prop": "stone_lantern", "road_at": 9, "offset_m": -12.5, "lateral": 13.0, "face": "road"},
    {"kind": "single", "prop": "stone_lantern", "road_at": 9, "offset_m": -3.5, "lateral": 13.0, "face": "road"},
    {"kind": "row", "prop": "torii_small", "from": (126, 64), "to": (176, 60), "spacing": 5.0, "face": "along",
     "skip_ends": True, "force": True},
    {"kind": "row", "prop": "stone_lantern", "from": (122, 68.5), "to": (178, 64.5), "spacing": 8.0,
     "face": "across"},
    {"kind": "row", "prop": "stone_lantern", "from": (122, 55.5), "to": (178, 51.5), "spacing": 8.0,
     "face": "across"},
    {"kind": "single", "prop": "shrine", "pos": (194, 58), "face": -86.0, "sink": 0.1},
    {"kind": "single", "prop": "shrine_bell", "pos": (190, 44), "face": 0.0},
    {"kind": "single", "prop": "ginkgo", "pos": (200, 76), "face": 0.0, "scale": 1.3},
    {"kind": "single", "prop": "ginkgo", "pos": (206, 40), "face": 0.0, "scale": 1.2},
    # crest in the valley
    {"kind": "crowd", "road_at": 9, "offset_m": 30.0, "side": -1, "length": 14.0, "gap": 6.8,
     "barrier": "tape_post", "count": 7, "depth": 3.5, "extras": ["flag_pole_pink"]},
    # ---------------------------------------------------------------- gorge and stone bridge
    {"kind": "single", "prop": "road_mirror", "road_at": 14, "offset_m": -6.0, "lateral": 7.0, "face": "road"},
    {"kind": "single", "prop": "stone_lantern", "road_at": 14, "offset_m": -3.0, "lateral": 6.8, "face": "road"},
    {"kind": "single", "prop": "stone_lantern", "road_at": 14, "offset_m": -3.0, "lateral": -6.8, "face": "road"},
    {"kind": "single", "prop": "stone_lantern", "road_at": 16, "offset_m": 3.0, "lateral": 6.8, "face": "road"},
    {"kind": "single", "prop": "stone_lantern", "road_at": 16, "offset_m": 3.0, "lateral": -6.8, "face": "road"},
    {"kind": "single", "prop": "torii_small", "road_at": 13, "offset_m": -10.0, "lateral": -12.0, "face": "road",
     "yaw_add": 90.0},
    {"kind": "single", "prop": "hokora", "pos": (66, -384), "face": 150.0},
    {"kind": "single", "prop": "bench", "pos": (70, -372), "face": 160.0},
    # gravel stage start
    {"kind": "single", "prop": "marshal_post", "road_at": 16, "offset_m": 18.0, "lateral": 9.0, "face": "road"},
    {"kind": "single", "prop": "flag_pole_blue", "road_at": 16, "offset_m": 12.0, "lateral": 8.0, "face": "road"},
    {"kind": "single", "prop": "flag_pole", "road_at": 16, "offset_m": 12.0, "lateral": -8.0, "face": "road"},
    {"kind": "single", "prop": "kei_truck", "road_at": 16, "offset_m": 26.0, "lateral": 12.0, "face": "along"},
    # ---------------------------------------------------------------- switchbacks
    *hairpin(22, -1),
    *hairpin(28, 1),
    {"kind": "single", "prop": "jizo", "road_at": 19, "offset_m": 0.0, "lateral": 7.6, "face": "road"},
    {"kind": "single", "prop": "hokora", "road_at": 25, "offset_m": 0.0, "lateral": -8.0, "face": "road"},
    # handmade rhythm on the gravel climb: wayside jizo, lanterns and marshal kit
    {"kind": "single", "prop": "stone_lantern", "road_at": 20, "offset_m": 10.0, "lateral": -7.6, "face": "road"},
    {"kind": "single", "prop": "tire_stack", "road_at": 24, "offset_m": 20.0, "lateral": 8.5, "face": "road"},
    {"kind": "single", "prop": "marshal_post", "road_at": 24, "offset_m": 26.0, "lateral": 10.0, "face": "road"},
    {"kind": "single", "prop": "jizo", "road_at": 26, "offset_m": -20.0, "lateral": -7.6, "face": "road"},
    {"kind": "single", "prop": "jizo", "road_at": 26, "offset_m": -18.6, "lateral": -7.6, "face": "road"},
    {"kind": "single", "prop": "stone_lantern", "road_at": 29, "offset_m": 30.0, "lateral": 7.6, "face": "road"},
    {"kind": "single", "prop": "flag_pole_pink", "road_at": 31, "offset_m": -20.0, "lateral": 8.0, "face": "road"},
    # ---------------------------------------------------------------- ridge viewpoint (valley on the left)
    {"kind": "single", "prop": "bench", "road_at": 32, "offset_m": -44.0, "lateral": -14.0, "face": "away"},
    {"kind": "single", "prop": "bench", "road_at": 32, "offset_m": -38.0, "lateral": -14.5, "face": "away"},
    {"kind": "single", "prop": "stone_lantern", "road_at": 32, "offset_m": -48.0, "lateral": -10.0, "face": "road"},
    {"kind": "single", "prop": "stone_lantern", "road_at": 32, "offset_m": -32.0, "lateral": -10.0, "face": "road"},
    {"kind": "single", "prop": "kei_truck", "road_at": 32, "offset_m": -40.0, "lateral": -9.5, "face": "along"},
    {"kind": "crowd", "road_at": 32, "offset_m": 20.0, "side": 1, "length": 14.0, "gap": 6.8,
     "barrier": "tape_post", "count": 8, "depth": 3.0, "extras": ["flag_pole", "flag_pole_pink"]},
    {"kind": "single", "prop": "torii_small", "road_at": 30, "offset_m": 0.0, "lateral": 9.0, "face": "road",
     "yaw_add": 90.0},
    {"kind": "single", "prop": "hokora", "road_at": 30, "offset_m": 0.0, "lateral": 12.0, "face": "road"},
    {"kind": "row", "prop": "hazagi", "from": (-190, 60), "to": (-180, 96), "spacing": 5.0, "face": "across"},
    {"kind": "row", "prop": "hazagi", "from": (-150, 120), "to": (-140, 156), "spacing": 5.0, "face": "across"},
    {"kind": "single", "prop": "farmhouse_a", "pos": (-150, 70), "face": 90.0},
    {"kind": "single", "prop": "shed", "pos": (-138, 88), "face": 100.0},
    {"kind": "group", "props": ["persimmon_tree"], "count": 5, "radius": 22.0, "pos": (-150, 76),
     "road_clear": 12.0, "scale": (0.9, 1.1)},
    {"kind": "line", "props": ["fence_wood"], "from_cp": 32, "from_offset": 10.0, "to_cp": 33, "to_offset": 40.0,
     "spacing": 3.2, "lateral": -8.0, "sides": [1], "face": "along"},
    {"kind": "single", "prop": "stone_lantern", "road_at": 34, "offset_m": 0.0, "lateral": -7.6, "face": "road"},
    {"kind": "single", "prop": "vending_machine", "road_at": 34, "offset_m": 30.0, "lateral": 8.5, "face": "road"},
    # ---------------------------------------------------------------- descent
    *[h for h, _ in _ridge_farm],
    {"kind": "row", "prop": "hazagi", "from": (-420, 450), "to": (-420, 420), "spacing": 5.0, "face": "across"},
    {"kind": "single", "prop": "road_mirror", "road_at": 38, "offset_m": 0.0, "lateral": 7.2, "face": "road"},
    {"kind": "line", "props": ["telephone_pole"], "from_cp": 36, "from_offset": 0.0, "to_cp": 0,
     "to_offset": 0.0, "spacing": 40.0, "lateral": -8.0, "sides": [1], "face": "along"},
    {"kind": "single", "prop": "jizo", "road_at": 40, "offset_m": 0.0, "lateral": 7.5, "face": "road"},
]

_NO_FOREST = FIELDS + [GORGE]
_NO_FOREST_CIRCLES = [VILLAGE]

SPEC = {
    "id": "momiji",
    "seed": 23,
    "season": "autumn",
    "atmosphere": "autumn_golden",
    "size": 1600.0,
    "cell": 4.0,
    "play_half": 600.0,
    "road": {
        "points": POINTS,
        "width": 7.0,
        "verge": 1.4,
        "surface": "tarmac",
        "start_cp": START_CP,
        "start_offset": 0.0,
        "grid_back": 12.0,
        "checkpoints": 6,
        "bank_gain": 14.0,
        "bank_max": 0.05,
        "crests": [
            {"at": 9, "offset": 30.0, "height": 1.3, "width": 10.0},
            {"at": 32, "offset": 20.0, "height": 1.5, "width": 9.0},
            {"at": 11, "offset": 40.0, "height": 1.1, "width": 9.0},
        ],
    },
    "terrain": {
        "level_sigma": 100.0,
        "relief": {"amp": 30.0, "scale": 240.0, "near": 35.0, "far": 200.0, "detail": 1.3, "rise": 45.0},
        "hills": [
            {"pos": (390, -60), "radius": 230, "height": 95, "ridged": True},
            {"pos": (330, 330), "radius": 170, "height": 55},
            {"pos": (140, -430), "radius": 110, "height": 90, "ridged": True},
            {"pos": (-40, -440), "radius": 100, "height": 80, "ridged": True},
            {"pos": (200, 58), "radius": 55, "height": 20},
            {"pos": (-480, 0), "radius": 200, "height": 60, "ridged": True},
            {"pos": (-110, 100), "radius": 110, "height": -38},   # bowl below the ridge: the view
        ],
        "boundary": {"start": 560.0, "end": 790.0, "height": 210.0},
        "terraces": [{"poly": FIELDS[0], "step": 1.6, "edge": 12.0},
                     {"poly": FIELDS[1], "step": 1.2, "edge": 14.0},
                     {"poly": FIELDS[2], "step": 1.2, "edge": 12.0}],
        "pads": PADS,
        "canopy": {"near": 45.0, "far": 110.0, "scale": 30.0, "mask_scale": 170.0, "threshold": -0.35,
                   "amount": 0.85, "rock_cover": 0.75},
    },
    "river": {
        "points": [(150, -790, 72), (110, -640, 66), (78, -520, 62), (60, -446, 59.6), (52, -412, 59.0),
                   (44, -385, 57.6), (32, -340, 54.4), (20, -296, 51.0), (30, -250, 49.5), (48, -180, 46.5),
                   (54, -100, 43.5), (46, -20, 40.5), (56, 60, 37.5), (48, 140, 34.0), (56, 220, 30.5),
                   (36, 290, 27.0), (-10, 330, 25.0), (-60, 360, 23.8), (-94, 396, 22.5), (-120, 480, 20.0),
                   (-160, 570, 17.0), (-200, 680, 13.0), (-230, 790, 10.0)],
        "width": 10.0,
        "meander": 9.0,
        "pins": [(-94, 396), (20, -296), (52, -412)],
        "depth": 1.4,
        "falls": [{"at": (52, -412), "drop": 13.0, "pool": 9.0}],
        "steep": [{"pos": (46, -400), "radius": 100.0, "bank": 0.3}],
    },
    "backdrop": {"color": "9a90b4", "color_far": "c9b6c6", "height": 540.0, "base": 140.0,
                 "inner": 170.0, "scale": 430.0},
    "palette": {
        "grass": ["a6b566", "93a85a", "c2bf76"],
        "grass_dry": "d4b877",
        "verge_grass": "cdc48a",
        "forest_floor": "8a8a4c",
        "litter": ["d2512e", "e8843a", "eab64a"],
        "canopy": ["c9452f", "e0773a", "3e6b50", "e9a844", "b83a32", "d9913c", "4b7550"],
        "field": "dcb66a",
        "field2": "c89d58",
        "rock": "b2a698",
        "rock_dark": "8f857f",
        "dirt": "ad8a60",
        "sand": "d9c7a0",
        "mountain": "a0784e",
        "rail": "d8dee3",
        "rail_post": "9aa4ae",
        "bridge_rail": "e24a31",
        "bridge_cap": "f2c552",
        "stone": "bdb4a6",
        "wood": "a47148",
        "wood_dark": "6b4d42",
    },
    "materials": {
        "road": {"gravel_color": "ad8a62", "gravel_dark": "7f6249", "tarmac_color": "575d70",
                 "line_color": "f5f2ea", "centre_line": "f5f2ea", "petal_color": "e27a3e"},
        "water": {"shallow": "86c6bb", "deep": "36789e"},
    },
    "features": FEATURES,
    "scatter": [
        {"name": "maple_road", "props": ["maple_red", "maple_orange", "maple_yellow"],
         "weights": {"maple_red": 1.3}, "spacing": 9.0, "density": 0.85, "road_min": 9.0, "road_max": 60.0,
         "road_peak": (12.0, 60.0), "slope_max": 32.0, "scale": (0.85, 1.25), "sink": 0.3,
         "exclude_poly": _NO_FOREST, "exclude": _NO_FOREST_CIRCLES},
        {"name": "cedar_forest", "props": ["cedar_a", "cedar_b"], "spacing": 9.0, "density": 0.8,
         "road_min": 16.0, "mask": {"scale": 150.0, "threshold": 0.05, "seed": 1, "sign": -1.0},
         "slope_max": 42.0, "scale": (0.85, 1.3), "sink": 0.3,
         "exclude_poly": _NO_FOREST, "exclude": _NO_FOREST_CIRCLES},
        {"name": "maple_forest", "props": ["maple_red", "maple_orange", "maple_yellow", "maple_green"],
         "weights": {"maple_green": 0.35}, "spacing": 10.0, "density": 0.6, "road_min": 12.0, "road_max": 260.0,
         "mask": {"scale": 150.0, "threshold": 0.05, "seed": 1, "soft": 0.2},
         "slope_max": 40.0, "scale": (0.9, 1.3), "sink": 0.3,
         "exclude_poly": _NO_FOREST, "exclude": _NO_FOREST_CIRCLES},
        {"name": "ginkgo", "props": ["ginkgo"], "spacing": 40.0, "density": 0.35, "road_min": 10.0,
         "road_max": 120.0, "slope_max": 30.0, "scale": (0.9, 1.2), "sink": 0.3,
         "exclude_poly": _NO_FOREST},
        {"name": "pines", "props": ["pine_a", "pine_b"], "spacing": 20.0, "density": 0.3, "road_min": 10.0,
         "slope_max": 35.0, "scale": (0.8, 1.2), "sink": 0.3, "exclude_poly": _NO_FOREST,
         "exclude": _NO_FOREST_CIRCLES},
        {"name": "mountain_forest", "props": ["cedar_a", "cedar_b", "maple_red", "maple_orange", "maple_yellow"],
         "weights": {"maple_red": 0.5, "maple_orange": 0.6, "maple_yellow": 0.4},
         "spacing": 15.0, "density": 0.6, "edge_min": 480.0, "edge_max": 780.0, "bounds": 790.0,
         "road_min": 60.0, "slope_max": 46.0, "scale": (1.0, 1.5), "sink": 0.4},
        {"name": "bushes", "props": ["bush_a", "bush_b"], "spacing": 8.0, "density": 0.3, "road_min": 6.4,
         "road_max": 30.0, "slope_max": 35.0, "scale": (0.8, 1.3)},
        {"name": "rocks_slope", "props": ["rock_a", "rock_b", "rock_c", "rock_d", "rock_e"], "spacing": 13.0,
         "density": 0.4, "road_min": 7.0, "road_max": 55.0, "slope_min": 16.0, "slope_max": 60.0, "scale": (0.7, 1.6), "sink": 0.3},
        {"name": "cliffs", "props": ["cliff_a", "cliff_b"], "spacing": 22.0, "density": 0.45, "road_min": 9.0, "road_max": 90.0,
         "slope_min": 28.0, "slope_max": 70.0, "scale": (0.8, 1.4), "sink": 0.8},
        {"name": "boulders_river", "props": ["boulder", "rock_a", "rock_d", "rock_e"], "spacing": 7.0,
         "density": 0.5, "water_max": 9.0, "water_clear": 0.5, "road_min": 8.0, "scale": (0.6, 1.3), "sink": 0.3},
        {"name": "reeds", "props": ["reeds"], "spacing": 3.4, "density": 0.45, "water_max": 5.0,
         "water_clear": 0.3, "road_min": 7.0, "occupy": False, "scale": (0.8, 1.3), "sink": 0.1},
        {"name": "ferns", "props": ["fern"], "spacing": 5.5, "density": 0.3, "road_min": 6.0, "road_max": 80.0,
         "mask": {"scale": 150.0, "threshold": 0.05, "seed": 1, "sign": -1.0}, "occupy": False, "sink": 0.05},
        {"name": "logs", "props": ["log", "stump"], "spacing": 30.0, "density": 0.35, "road_min": 8.0,
         "road_max": 70.0, "sink": 0.05, "exclude_poly": FIELDS},
        {"name": "grass", "props": ["grass_tuft"], "spacing": 3.4, "density": 0.4, "road_min": 5.8,
         "road_max": 80.0, "occupy": False, "scale": (0.7, 1.4), "sink": 0.05},
    ],
}
