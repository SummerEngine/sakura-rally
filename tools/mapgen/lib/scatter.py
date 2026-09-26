"""Prop placement: explicit features (absolute or road-relative, single, groups, lines)
followed by masked random scatter rules. Every placed prop registers its footprint
so later props never overlap earlier ones."""
from __future__ import annotations

import math

import numpy as np

from . import geom, noise
from .road import LOT_DROP, Road, road_index
from .terrain import Terrain


class Occupancy:
    def __init__(self, cell: float = 8.0) -> None:
        self.cell = cell
        self.grid: dict[tuple[int, int], list[tuple[float, float, float]]] = {}
        self.rmax = 0.0

    def free(self, x: float, z: float, r: float) -> bool:
        reach = r + self.rmax
        c = self.cell
        for ci in range(int(math.floor((x - reach) / c)), int(math.floor((x + reach) / c)) + 1):
            for cj in range(int(math.floor((z - reach) / c)), int(math.floor((z + reach) / c)) + 1):
                for (ox, oz, orr) in self.grid.get((ci, cj), ()):
                    if (ox - x) ** 2 + (oz - z) ** 2 < (orr + r) ** 2:
                        return False
        return True

    def add(self, x: float, z: float, r: float) -> None:
        key = (int(math.floor(x / self.cell)), int(math.floor(z / self.cell)))
        self.grid.setdefault(key, []).append((x, z, r))
        self.rmax = max(self.rmax, r)


class Placer:
    def __init__(self, ter: Terrain, road: Road, manifest: dict, season: str, seed: int,
                 play_half: float) -> None:
        self.ter = ter
        self.road = road
        self.manifest = manifest
        self.season = season
        self.rng = np.random.default_rng(seed)
        self.seed = seed
        self.play_half = play_half
        self.occ = Occupancy()
        self.out: dict[str, list[list[float]]] = {}
        self.missing: set[str] = set()
        self.ny = ter.normal_y()
        self.start_s = 0.0  # start line distance; features may use `lap_frac` instead of `road_at`
        self.route = road.length  # start line to finish (the lap, or start to arrival on an open road)

    # ---------------------------------------------------------------- helpers
    def footprint(self, name: str) -> float:
        m = self.manifest.get(name)
        if m is None:
            return 1.0
        return float(m.get("footprint_radius", 1.0))

    def available(self, name: str) -> bool:
        if not self.manifest:
            return True
        if name in self.manifest:
            return True
        self.missing.add(name)
        return False

    def road_frame(self, cp: int, offset: float) -> int:
        s = self.road.control_s[cp] + offset
        return road_index(self.road, s % self.road.length if self.road.closed else s)

    def road_yaw(self, i: int) -> float:
        f = self.road.fwd[i]
        return float(math.atan2(-f[0], -f[1]))

    def ground_at(self, x: float, z: float) -> float:
        """Walkable height: the terrain, or a paved lot's surface where one covers it."""
        y = float(self.ter.height_at(x, z))
        for lot in self.road.lots:
            if float(lot.sdf(x, z)) < 0.2:
                y = max(y, lot.y - LOT_DROP)
        return y

    def emit(self, name: str, x: float, z: float, yaw: float, scale: float, sink: float = 0.0,
             y: float | None = None, radius: float | None = None, occupy: bool = True) -> bool:
        if not self.available(name):
            return False
        if y is None:
            y = self.ground_at(x, z) - sink
        self.out.setdefault(name, []).append([round(x, 2), round(y, 2), round(z, 2),
                                              round(yaw % (2 * math.pi), 3), round(scale, 3)])
        if occupy:
            self.occ.add(x, z, (radius if radius is not None else self.footprint(name) * 0.7) * scale)
        return True

    def resolve_yaw(self, face, x: float, z: float, i: int | None, center=None) -> float:
        if isinstance(face, (int, float)):
            return math.radians(face)
        if face == "road" and i is not None:
            p = self.road.pos[i]
            return math.atan2(-(p[0] - x), -(p[2] - z))
        if face == "away" and i is not None:
            p = self.road.pos[i]
            return math.atan2((p[0] - x), (p[2] - z))
        if face == "along" and i is not None:
            return self.road_yaw(i)
        if face == "center" and center is not None:
            return math.atan2(-(center[0] - x), -(center[1] - z))
        return float(self.rng.uniform(0, 2 * math.pi))

    def road_point(self, spec: dict) -> tuple[float, float, int]:
        i = self.road_frame(spec["road_at"], spec.get("offset_m", 0.0))
        lat = spec.get("lateral", 0.0)
        p = self.road.pos[i]
        r = self.road.right[i]
        return float(p[0] + r[0] * lat), float(p[2] + r[1] * lat), i

    # ---------------------------------------------------------------- features
    def features(self, feats: list[dict]) -> None:
        for f in feats:
            if "lap_frac" in f:  # position as a fraction of the route from the start line
                s = self.start_s + f["lap_frac"] * self.route + f.get("offset_m", 0.0)
                f = dict(f, road_at=0, offset_m=s - float(self.road.control_s[0]))
            kind = f.get("kind", "single")
            if kind == "single":
                self._single(f)
            elif kind == "group":
                self._group(f)
            elif kind == "line":
                self._line(f)
            elif kind == "row":
                self._row(f)
            elif kind == "crowd":
                self._crowd(f)
            elif kind == "clear":
                # reserve space (e.g. start area) so scatter keeps out
                x, z, _ = self.road_point(f) if "road_at" in f else (f["pos"][0], f["pos"][1], None)
                self.occ.add(x, z, f["radius"])
            else:
                raise ValueError(kind)

    def _row(self, f: dict) -> None:
        """Props evenly spaced on a straight line between two absolute points (fences,
        lantern avenues, torii paths). face: "along" (-Z down the row), "across" or degrees."""
        x0, z0 = f["from"]
        x1, z1 = f["to"]
        L = math.hypot(x1 - x0, z1 - z0)
        n = max(1, int(round(L / f["spacing"])))
        base = math.atan2(-(x1 - x0), -(z1 - z0))
        face = f.get("face", "along")
        yaw0 = base if face == "along" else base + math.pi / 2 if face == "across" else math.radians(face)
        yaw0 += math.radians(f.get("yaw_add", 0.0))
        props = f["props"] if "props" in f else [f["prop"]]
        for k in range(n + 1):
            if f.get("skip_ends") and k in (0, n):
                continue
            t = k / n
            x = x0 + (x1 - x0) * t
            z = z0 + (z1 - z0) * t
            name = props[k % len(props)]
            if not f.get("force") and not self.occ.free(x, z, self.footprint(name) * 0.5):
                continue
            self.emit(name, x, z, yaw0, f.get("scale", 1.0), sink=f.get("sink", 0.05), radius=f.get("radius"))

    def _crowd(self, f: dict) -> None:
        """A spectator spot on one side of the road: a barrier row (hay bales or tape)
        `gap` m from the road edge along `length` m of road, spectators standing 1.5 m
        and more behind it facing the road, optional `extras` (flags, tent) further back."""
        road = self.road
        n = len(road.pos)
        side = f["side"]
        s0 = float(road.control_s[f["road_at"]]) + f.get("offset_m", 0.0)
        length = f.get("length", 14.0)
        gap = f.get("gap", 6.5)
        barrier = f.get("barrier", "hay_bale_square")
        spacing = f.get("barrier_spacing", 2.0 if barrier.startswith("hay") else 3.1)
        for s in np.arange(s0 - length / 2, s0 + length / 2 + 1e-6, spacing):
            i = road_index(road, s)
            lat = side * (road.half_width[i] + gap)
            x = float(road.pos[i, 0] + road.right[i, 0] * lat)
            z = float(road.pos[i, 2] + road.right[i, 1] * lat)
            yaw = self.road_yaw(i) + (math.pi / 2 if side > 0 else -math.pi / 2)
            if float(self.ter.sample(self.ter.road_dist, x, z)) < road.half_width[i] + gap - 0.6:
                continue  # another stretch of road is closer than this one
            self.emit(barrier, x, z, yaw, 1.0, sink=0.05, radius=0.6)
        people = f.get("props", ["spectator_a", "spectator_b", "spectator_c", "spectator_d",
                                 "spectator_e", "spectator_f"])
        depth = f.get("depth", 4.0)
        placed = 0
        tries = 0
        while placed < f.get("count", 8) and tries < 200:
            tries += 1
            s = s0 + float(self.rng.uniform(-0.5, 0.5)) * length
            i = road_index(road, s)
            lat = side * (road.half_width[i] + max(gap + 1.5, 8.0) + float(self.rng.uniform(0.0, depth)))
            x = float(road.pos[i, 0] + road.right[i, 0] * lat)
            z = float(road.pos[i, 2] + road.right[i, 1] * lat)
            if not self.occ.free(x, z, 0.4):
                continue
            if float(self.ter.sample(self.ter.road_dist, x, z)) < road.half_width[i] + 7.6:
                continue
            name = people[int(self.rng.integers(len(people)))]
            p = road.pos[i]
            yaw = math.atan2(-(p[0] - x), -(p[2] - z)) + float(self.rng.normal(0.0, 0.3))
            self.emit(name, x, z, yaw, float(self.rng.uniform(0.95, 1.05)), sink=0.03, radius=0.45)
            placed += 1
        for k, name in enumerate(f.get("extras", [])):
            s = s0 + (k - (len(f["extras"]) - 1) / 2) * f.get("extras_spacing", 6.0)
            i = road_index(road, s)
            lat = side * (road.half_width[i] + max(gap + 1.5, 8.0) + depth + 2.5)
            x = float(road.pos[i, 0] + road.right[i, 0] * lat)
            z = float(road.pos[i, 2] + road.right[i, 1] * lat)
            if not self.occ.free(x, z, self.footprint(name) * 0.6):
                continue
            if float(self.ter.sample(self.ter.road_dist, x, z)) < road.half_width[i] + 9.0:
                continue
            p = road.pos[i]
            self.emit(name, x, z, math.atan2(-(p[0] - x), -(p[2] - z)), 1.0, sink=0.05)

    def _single(self, f: dict) -> None:
        if "road_at" in f:
            x, z, i = self.road_point(f)
        else:
            x, z = f["pos"]
            i = self._nearest_road(x, z)
        yaw = self.resolve_yaw(f.get("face", "road"), x, z, i) + math.radians(f.get("yaw_add", 0.0))
        y = None
        if f.get("on_road"):
            y = float(self.road.pos[i, 1]) + f.get("y_offset", 0.0)
        elif "y_offset" in f:
            y = self.ground_at(x, z) + f["y_offset"]
        self.emit(f["prop"], x, z, yaw, f.get("scale", 1.0), sink=f.get("sink", 0.05), y=y,
                  radius=f.get("radius"))

    def _group(self, f: dict) -> None:
        if "road_at" in f:
            cx, cz, _ = self.road_point(f)
        else:
            cx, cz = f["pos"]
        props = f["props"]
        weights = np.array(f.get("weights", [1.0] * len(props)), dtype=np.float64)
        weights /= weights.sum()
        placed = 0
        tries = 0
        road_clear = f.get("road_clear", 6.0)
        while placed < f["count"] and tries < f["count"] * 40:
            tries += 1
            a = self.rng.uniform(0, 2 * math.pi)
            r = f["radius"] * math.sqrt(self.rng.uniform(f.get("inner", 0.0), 1.0))
            x = cx + math.cos(a) * r
            z = cz + math.sin(a) * r
            if float(self.ter.sample(self.ter.road_dist, x, z)) < road_clear + self.road.half_width.max():
                continue
            if float(self.ter.sample(self.ter.lake_sd, x, z)) < 2.0:
                continue
            if float(self.ter.sample(self.ter.river_dist, x, z)) < self.ter.water.river_width / 2 + 2.0:
                continue
            name = props[int(self.rng.choice(len(props), p=weights))]
            if not self.available(name):
                continue
            sc = float(self.rng.uniform(*f.get("scale", (0.9, 1.1))))
            rad = self.footprint(name) * 0.7 * sc
            if not self.occ.free(x, z, rad):
                continue
            i = self._nearest_road(x, z)
            yaw = self.resolve_yaw(f.get("face", "random"), x, z, i, center=(cx, cz))
            yaw += float(self.rng.normal(0.0, math.radians(f.get("yaw_jitter", 0.0))))
            self.emit(name, x, z, yaw, sc, sink=f.get("sink", 0.1), radius=self.footprint(name) * 0.7)
            placed += 1

    def _line(self, f: dict) -> None:
        a = self.road.control_s[f["from_cp"]] + f.get("from_offset", 0.0)
        b = self.road.control_s[f["to_cp"]] + f.get("to_offset", 0.0)
        if b < a and self.road.closed:
            b += self.road.length
        props = f["props"] if "props" in f else [f["prop"]]
        k = 0
        s = a
        while s <= b:
            i = road_index(self.road, s)
            for side in f.get("sides", [f.get("side", 1)]):
                lat = side * f["lateral"]
                p = self.road.pos[i]
                r = self.road.right[i]
                x = float(p[0] + r[0] * lat)
                z = float(p[2] + r[1] * lat)
                name = props[k % len(props)]
                if f.get("skip_bridges", True) and self.road.bridge[i] != "":
                    continue
                if not f.get("force") and not self.occ.free(x, z, self.footprint(name) * 0.5):
                    continue
                yaw = self.resolve_yaw(f.get("face", "along"), x, z, i) + math.radians(f.get("yaw_add", 0.0))
                if f.get("face") == "road_side":
                    yaw = self.road_yaw(i) + (math.pi / 2 if side > 0 else -math.pi / 2)
                self.emit(name, x, z, yaw, f.get("scale", 1.0), sink=f.get("sink", 0.05),
                          radius=f.get("radius"))
            k += 1
            s += f["spacing"]

    def _nearest_road(self, x: float, z: float) -> int:
        d = (self.road.pos[:, 0] - x) ** 2 + (self.road.pos[:, 2] - z) ** 2
        return int(np.argmin(d))

    # ---------------------------------------------------------------- scatter
    def rule(self, r: dict) -> int:
        props = [p for p in r["props"] if self.available(p)]
        if not props:
            return 0
        weights = np.array([r.get("weights", {}).get(p, 1.0) for p in props], dtype=np.float64)
        weights /= weights.sum()
        spacing = r["spacing"]
        half = r.get("bounds", self.play_half + 60.0)
        g = np.arange(-half, half, spacing)
        GX, GZ = np.meshgrid(g, g)
        x = GX.ravel() + self.rng.uniform(-0.48, 0.48, GX.size) * spacing
        z = GZ.ravel() + self.rng.uniform(-0.48, 0.48, GZ.size) * spacing
        ter = self.ter
        D = ter.sample(ter.road_dist, x, z)
        prob = np.full(x.shape, r.get("density", 1.0))
        prob *= (D >= r.get("road_min", 0.0)) & (D <= r.get("road_max", 1e9))
        prob *= ter.sample(ter.lot_sd, x, z) > r.get("lot_clear", 4.0)
        if "road_peak" in r:  # denser close to the road, thinning out
            a, b = r["road_peak"]
            prob *= 1.0 - 0.85 * geom.smoothstep(a, b, D)
        ny = ter.sample(self.ny, x, z)
        prob *= ny >= math.cos(math.radians(r.get("slope_max", 38.0)))
        if "slope_min" in r:
            prob *= ny <= math.cos(math.radians(r["slope_min"]))
        y = ter.height_at(x, z)
        prob *= (y >= r.get("h_min", -1e9)) & (y <= r.get("h_max", 1e9))
        lake = ter.sample(ter.lake_sd, x, z)
        river = ter.sample(ter.river_dist, x, z)
        rw = ter.water.river_width / 2.0
        prob *= (lake > r.get("water_clear", 3.0)) & (river > rw + r.get("water_clear", 3.0))
        if "water_max" in r:
            prob *= (lake < r["water_max"]) | (river < rw + r["water_max"])
        if "mask" in r:
            m = r["mask"]
            nv = noise.fbm(x, z, m["scale"], 3, 2.0, 0.5, self.seed + m.get("seed", 0))
            prob *= geom.smoothstep(m["threshold"] - m.get("soft", 0.12), m["threshold"] + m.get("soft", 0.12), nv * m.get("sign", 1.0))
        if "regions" in r:
            inside = np.zeros(x.shape, dtype=bool)
            for reg in r["regions"]:
                if "circle" in reg:
                    cx, cz, rad = reg["circle"]
                    inside |= (x - cx) ** 2 + (z - cz) ** 2 < rad * rad
                if "poly" in reg:
                    inside |= geom.point_in_polygon(x, z, np.array(reg["poly"], dtype=np.float64))
            prob *= np.where(inside, 1.0, r.get("outside", 0.0))
        if "exclude" in r:
            for reg in r["exclude"]:
                cx, cz, rad = reg
                prob *= (x - cx) ** 2 + (z - cz) ** 2 >= rad * rad
        for poly in r.get("exclude_poly", []):
            prob *= ~geom.point_in_polygon(x, z, np.array(poly, dtype=np.float64))
        edge = np.maximum(np.abs(x), np.abs(z))
        prob *= (edge < r.get("edge_max", 790.0)) & (edge >= r.get("edge_min", 0.0))
        keep = self.rng.random(x.shape) < prob
        idx = np.nonzero(keep)[0]
        self.rng.shuffle(idx)
        placed = 0
        occupy = r.get("occupy", True)
        sc_lo, sc_hi = r.get("scale", (0.85, 1.15))
        choice = self.rng.choice(len(props), size=len(idx), p=weights)
        for k, j in enumerate(idx):
            name = props[choice[k]]
            sc = float(self.rng.uniform(sc_lo, sc_hi))
            rad = self.footprint(name) * r.get("radius_scale", 0.7) * sc
            if not self.occ.free(float(x[j]), float(z[j]), rad if occupy else r.get("clear_radius", 0.4)):
                continue
            yaw = float(self.rng.uniform(0, 2 * math.pi))
            self.emit(name, float(x[j]), float(z[j]), yaw, sc, sink=r.get("sink", 0.15),
                      y=float(y[j]) - r.get("sink", 0.15), radius=rad / sc, occupy=occupy)
            placed += 1
        return placed
