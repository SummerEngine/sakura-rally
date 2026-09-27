# The world

One connected world pack, `assets/maps/world/` (`map.json` `"version": 2` + `map.bin`), built by
`tools/mapgen/mapgen.py` from `tools/mapgen/maps/world.py` and read by `scripts/world/map_world.gd`
(`MapWorld`). The schema is in `docs/CONTRACTS.md`, "One world"; this file covers the layout and
the build.

## Build

```sh
uv run --with numpy --with pillow python tools/mapgen/mapgen.py
```

Deterministic (fixed seeds, no clock or hash-order input). It prints per road: length, height
range, max grade, min radius; each junction (fork and clear samples, side); season weights per
road and at named places along the branch; the liaison makeup; corner and guardrail counts
(RoadSafety's `lib/roadside.py`); the corridor survey before and after `enforce` (after must be
0 rigid props in the corridor, 0 smashables on tarmac); meshes, triangles, instances, sizes and
timings. Previews go to `docs/renders/map_world.png` (roads, routes, gates, season tint) and the
crops `map_hanami.png`, `map_branch.png`, `map_momiji.png`.

Last build (M1 Max, shared with other jobs): about 9 s total (terrain 1.8 s, scatter 1.9 s,
paint 2.6 s, dressing 0.6 s, preview 0.6 s). 462 meshes, 1.16 M triangles, 67 470 instances of 90
props, 870 collision boxes, 5 signs, 3 parked cars. `map.bin` 45.1 MB (uncompressed blobs, see
`lib/meshpack.py`), `map.json` 2.6 MB. Corridor: 24 rigid props in the corridor before, 0 after.

## Layout

World bounds x -800..2950, z -800..1240 (metres, Godot axes).

| region | placement | content |
| --- | --- | --- |
| Hanami (`maps/hanami.py`) | identity: its coordinates are world coordinates | spring loop, 2952 m, lake, village, garage beside the start straight |
| Momiji (`maps/momiji.py`) | turned a quarter left and moved east (`lib/region.py` `Frame`) | autumn loop, 2643 m, onsen village, gorge |
| branch (`maps/world.py`) | authored in world coordinates | open road, 1794 m, Natsu's content: terraces, village, stone bridge, time control and service park near the Momiji end, signs, parked cars |

`lib/region.py` places a region spec into world coordinates (points, features, pads, lots,
hills, rivers, keep-out polygons). Natsu's own spec is gone; its content lives in `maps/world.py`.

## Roads, junctions, routes

- Roads: `hanami` and `momiji` (closed), `branch` (open). The branch forks off the Hanami loop
  at loop s 466 (185 m past the Hanami start line, right side) and joins the Momiji loop at loop
  s 2612 (right side, before its start line). `lib/junction.py` finds the fork and the point
  where the branch clears the loop's carriageway, sits the branch on the loop's surface through
  the mouth (same height and bank, so no step and no z-fighting: the branch ribbon starts at the
  clear point, the loop carries the mouth) and eases to the branch profile past it.
- Routes: `hanami` and `momiji` stage laps (`start`, `spawn`, `checkpoints`, `finish_stop` 150 m
  past the line); `liaison` (2007 m: Hanami loop 34 m, branch 1755 m, Momiji loop 217 m) starts at
  Hanami's `finish_stop` and ends at Momiji's spawn (`arrival`).
- Gates: `hanami_branch` at liaison s 73 (73 m ahead of the Hanami `finish_stop`, in view),
  `momiji_branch` at liaison s 1743, each across the branch just past its junction.

## Terrain, water, seasons

- One heightfield (cell 4 m, 939 × 511 vertices) with each region's relief, hills and terraces,
  blended by region weight; one mountain rim around the whole world and none between regions.
  Fine chunks near the roads and coarse far chunks with visibility ranges; collision everywhere a
  car can reach. The rim's crest stays above about 190 m all round the world rectangle, and the
  backdrop's inner ring lies 15 m under the terrain just inside it, so the world is closed from
  any camera height (checked from about 450 m over every route).
- Water: Hanami's lake; `water.rivers[]` `{id, width, points}` run end to end (Momiji's river
  and the branch's river under the stone bridge drain into Hanami's lake). A river springs from
  the rim's slope: its channel fades out as it climbs into the rim (it never cuts the crest), and
  its ribbon and `points` start where the channel opens (the build prints each source).
- `season_grid`: u8 × 3 (spring, summer, autumn, summing to 255), cell 8 m, 470 × 256, origin
  (-800, -800). Hanami is pure spring, Momiji pure autumn; along the branch sakura runs its first
  ~500 m, summer greens, rice terraces and the village fill the middle, maples start well before
  Momiji. The terrain palette and the scatter rules are blended by the same weights.
