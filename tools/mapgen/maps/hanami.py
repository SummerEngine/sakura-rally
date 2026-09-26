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

SPEC = {
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
        "forest_floor": "6f9f55",
        "petal": "f5c6d5",
        "field": "d9c68f",
        "field2": "c7b27b",
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
    "features": [
        {"kind": "clear", "road_at": 4, "offset_m": -8.0, "radius": 16.0},
    ],
    "scatter": [
        {"name": "sakura_road", "props": ["sakura_a", "sakura_b", "sakura_c"], "weights": {"sakura_c": 0.6},
         "spacing": 10.0, "density": 0.9, "road_min": 8.5, "road_max": 55.0, "road_peak": (12.0, 55.0),
         "mask": {"scale": 170.0, "threshold": -0.08, "seed": 1}, "slope_max": 30.0, "scale": (0.85, 1.2),
         "sink": 0.3},
        {"name": "sakura_lake", "props": ["sakura_a", "sakura_c"], "spacing": 13.0, "density": 0.55,
         "road_min": 9.0, "regions": [{"circle": (-170, 420, 280)}, {"circle": (40, 230, 150)}],
         "slope_max": 28.0, "scale": (0.9, 1.25), "sink": 0.3},
        {"name": "cedar_forest", "props": ["cedar_a", "cedar_b"], "spacing": 8.5, "density": 0.85,
         "road_min": 12.0, "mask": {"scale": 170.0, "threshold": 0.02, "seed": 1, "sign": -1.0},
         "h_min": 35.0, "slope_max": 40.0, "scale": (0.85, 1.3), "sink": 0.3},
        {"name": "pines", "props": ["pine_a", "pine_b"], "spacing": 16.0, "density": 0.35, "road_min": 10.0,
         "slope_max": 35.0, "scale": (0.8, 1.2), "sink": 0.3},
        {"name": "bamboo", "props": ["bamboo_clump"], "spacing": 13.0, "density": 0.45, "road_min": 9.0,
         "regions": [{"circle": (80, 240, 130)}, {"circle": (-330, -60, 110)}], "scale": (0.9, 1.2), "sink": 0.2},
        {"name": "mountain_forest", "props": ["cedar_a", "cedar_b", "pine_a"], "spacing": 15.0, "density": 0.6,
         "edge_min": 520.0, "edge_max": 780.0, "bounds": 790.0, "road_min": 60.0, "slope_max": 44.0,
         "scale": (1.0, 1.5), "sink": 0.4},
        {"name": "bushes", "props": ["bush_a", "bush_b", "azalea"], "weights": {"azalea": 1.4}, "spacing": 7.0,
         "density": 0.35, "road_min": 6.2, "road_max": 30.0, "slope_max": 35.0, "scale": (0.8, 1.3)},
        {"name": "rocks_slope", "props": ["rock_a", "rock_b", "rock_c", "rock_d", "rock_e"], "spacing": 13.0,
         "density": 0.4, "road_min": 7.0, "slope_min": 16.0, "slope_max": 60.0, "scale": (0.7, 1.6), "sink": 0.3},
        {"name": "cliffs", "props": ["cliff_a", "cliff_b"], "spacing": 26.0, "density": 0.5, "road_min": 9.0,
         "slope_min": 28.0, "slope_max": 70.0, "scale": (0.8, 1.4), "sink": 0.8},
        {"name": "boulders_river", "props": ["boulder", "rock_a", "rock_d"], "spacing": 9.0, "density": 0.45,
         "water_max": 9.0, "water_clear": 0.5, "road_min": 8.0, "scale": (0.6, 1.3), "sink": 0.3},
        {"name": "reeds", "props": ["reeds"], "spacing": 3.2, "density": 0.55, "water_max": 5.0,
         "water_clear": 0.3, "road_min": 7.0, "occupy": False, "scale": (0.8, 1.3), "sink": 0.1},
        {"name": "ferns", "props": ["fern"], "spacing": 5.0, "density": 0.35, "road_min": 6.0, "road_max": 90.0,
         "mask": {"scale": 170.0, "threshold": 0.02, "seed": 1, "sign": -1.0}, "occupy": False, "sink": 0.05},
        {"name": "logs", "props": ["log", "stump"], "spacing": 30.0, "density": 0.35, "road_min": 8.0,
         "road_max": 70.0, "sink": 0.05},
        {"name": "grass", "props": ["grass_tuft"], "spacing": 3.4, "density": 0.4, "road_min": 5.8,
         "road_max": 85.0, "occupy": False, "scale": (0.7, 1.4), "sink": 0.05},
        {"name": "flowers", "props": ["flowers_patch"], "spacing": 6.0, "density": 0.28, "road_min": 5.8,
         "road_max": 45.0, "occupy": False, "scale": (0.8, 1.3), "sink": 0.05},
    ],
}
