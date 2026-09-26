# Sakura Rally — shared contracts

Cel-shaded, low-poly rally game in Godot 4.7 (GDScript only, Forward+, Jolt).
Visual target: the "hand-painted anime background" look of yamazakura, the author's earlier
three.js sakura bike ride (not public) — flat cel bands, shadows hue-shifted to violet instead of
darkened, soft aerial haze, pastel sky with puffy cel clouds, thin dark-violet ink lines.

## Engine and commands

- Engine binary: `/Applications/Summer.app/Contents/MacOS/Summer` (Godot 4.7.2 custom build).
  Official Godot 4.7.2 at `/Applications/Godot.app/Contents/MacOS/Godot` is equivalent; keep
  the project pure GDScript so both run it.
- Always pass `--disable-crash-handler`. Always wrap runs in `timeout`.
- Import after writing raw assets: `timeout 180 $S --headless --disable-crash-handler --path . --import`
- Run a headless script: `$S --headless --disable-crash-handler --path . -s res://path/script.gd`
  (script `extends SceneTree`, calls `quit()`; autoloads are NOT identifiers in `-s` scripts,
  use `root.get_node("Game")`).
- `-s` runs and the UI preview never read or write the player's save
  (`user://sakura_rally.cfg`): `Game.persistent` is false, so they start from default
  settings with no records, and nothing they finish or change reaches the player.
- Headless has no pixels. For screenshots use `--summer-offscreen` (the real renderer, no
  window; add `--audio-driver Dummy`): Vel works on this Mac, so nothing opens a window.
  Capture with `get_viewport().get_texture().get_image().save_png(...)`.
- Judge runs by stderr (`SCRIPT ERROR`, `Parse Error`, `ERROR:`) and by artifacts, not exit code.
  Summer prints harmless noise: `[SE] AuthManager`, `Sparkle`, `SSL module failed`, `TLS handshake`.
- Tools that run the game, a car or the Sound API end with `Game.request_quit(exit_code)`, not
  `quit()`. It stops every audio player and waits 100 ms of wall-clock time so no stream is
  still live at teardown; otherwise every run ends with `ERROR: N resources still in use at exit`.

## Units and axes

- Meters, kilograms, seconds. Godot: +Y up, **forward is -Z**, right is +X.
- Blender authoring: Z up, **car front points to Blender +Y** (glTF export maps Blender +Y to Godot -Z).
  Export glTF 2.0 binary (`.glb`), +Y up (default), apply modifiers, no cameras/lights.

## Directory ownership

| Path | Owner |
|---|---|
| `project.godot`, `scripts/autoload/game.gd`, `scripts/main.gd`, `scenes/main.tscn` | integrator (lead). Others: ask, don't edit |
| `shaders/`, `scripts/world/`, `scripts/fx/`, `assets/maps/`, `tools/build/` | lead (rendering + world) |
| `assets/models/car/`, `tools/blender/build_car.py` | car-model agent |
| `assets/models/props/`, `tools/blender/build_props.py` | props agent |
| `scripts/vehicle/` (except `car_audio.gd`), `scripts/camera/`, `scenes/car/` | physics agent |
| `scripts/autoload/sound.gd`, `scripts/vehicle/car_audio.gd`, `assets/audio/`, `tools/audio/` | audio agent |
| `scripts/ui/`, `scenes/ui/`, `assets/fonts/`, `assets/ui/` | UI agent |
| `docs/renders/` | anyone (preview images) |

## Car geometry (fixed; physics and model agree on this)

Origin: midpoint between axles, at ground level with the car at rest. Forward -Z.

| Item | Value |
|---|---|
| Body length / width / height | 4.20 / 1.80 / 1.40 m |
| Wheelbase | 2.55 m (front axle z = -1.27, rear axle z = +1.28) |
| Track (wheel centre x) | ±0.78 m |
| Wheel centre height at rest | 0.33 m |
| Tyre radius / width | 0.33 m / 0.24 m |
| Mass | 1250 kg |

GLB `assets/models/car/rally_car.glb` node names (exact):
- `Body` — everything that does not move relative to the chassis (may be several meshes/children).
- `Wheel_FL`, `Wheel_FR`, `Wheel_RL`, `Wheel_RR` — tyre+rim, origin exactly at wheel centre,
  axle along X. Left wheels may be mirrored/rotated; code applies steer (around car up) and spin
  (around car right) in car space on top of each wheel's rest basis.
- `Caliper_FL` … `Caliper_RR` (optional) — steer with the wheel, do not spin.
- Materials (names exact, base colours only, no textures needed): `Paint` (primary livery, recoloured
  at runtime), `Paint2` (secondary livery stripe), `Trim` (black plastic), `Chrome`, `Glass`,
  `Rubber`, `Rim`, `HeadLight` (emissive), `TailLight` (emissive red), `Decal_White`, `Number`.

## Material naming for all GLB assets (runtime converts to the toon shader)

Converter: `scripts/world/toon_materials.gd` walks imported scenes and replaces every
StandardMaterial3D with the toon ShaderMaterial, keeping albedo colour (and vertex colours if the
mesh has them — they multiply the albedo). Name keywords (case-insensitive substring) pick behaviour:

| Keyword in material name | Behaviour |
|---|---|
| `Blossom` | high-key ramp, does not receive cast shadows, wind sway |
| `Leaf`, `Leaves`, `Foliage`, `Grass`, `Needle` | foliage ramp, wind sway |
| `Glass` | glossy dark glass with sky reflection band |
| `Light`, `Emit`, `Lamp`, `Lantern` | emissive (glows at dusk) |
| `Water` | water shader |
| `Paint` | car paint (cel + small specular highlight) |
| anything else | standard cel ramp |

Wind sway weight is computed in the shader from object-space height, so foliage meshes should have
their origin at the ground (tree base).

## Surfaces

`StringName`s used by physics, audio and VFX: `&"tarmac"`, `&"gravel"`, `&"dirt"`, `&"grass"`,
`&"sand"`, `&"none"` (airborne). Static colliders carry `set_meta("surface", &"gravel")`; terrain may
override per position through the track node (`Track.surface_at(position) -> StringName`).
Physics layers: 1 world, 2 car, 3 props, 4 triggers, 5 debris (value 16: smashed dressing, collides
with layer 1 only). Layer 3 holds only rigid things: walls (mapgen `Barriers`: guardrails, bridge
rails, and sign posts in packs older than breakable signs) and the `PropBody_x_y` bodies of RIGID
props. Soft course dressing has no collider (see "Soft course" below).

## Car runtime API (`scenes/car/car.tscn`, root RigidBody3D, `scripts/vehicle/car.gd`)

Read-only state, updated every physics tick:

```
var rpm: float                 # engine rpm
var idle_rpm: float            # ~900
var max_rpm: float             # redline ~7800
var throttle: float            # 0..1 applied throttle after assists/limiter
var brake: float               # 0..1
var handbrake: float           # 0..1
var steer: float               # -1..1 applied steering (left negative)
var gear: int                  # -1 reverse, 0 neutral, 1..6
var is_shifting: bool
var boost: float               # 0..1 turbo boost (for whistle/spool)
var speed_kmh: float           # signed forward speed * 3.6
var airborne_time: float       # seconds since all wheels lost contact (0 when grounded)
var wheels: Array              # 4 entries, order FL, FR, RL, RR; each a WheelState object:
    contact: bool, surface: StringName, slip_long: float, slip_lat: float,
    slip: float (combined, 0 = rolling, ~1 = at the limit, >1 sliding),
    load: float (N), compression: float (0..1), contact_point: Vector3, contact_normal: Vector3,
    spin_speed: float (rad/s)
```

Signals: `gear_changed(new_gear: int, old_gear: int)`, `backfire`, `rev_limiter`,
`impact(strength: float, point: Vector3)` (strength ~0..1+), `landed(strength: float)`.

Control inputs (set by the player input reader or an autopilot):
`var input_throttle: float`, `var input_brake: float`, `var input_steer: float`,
`var input_handbrake: bool`, `var controlled_by_player: bool` (reads InputMap actions when true).
Methods: `reset_to(transform: Transform3D)`, `set_livery(primary: Color, secondary: Color)`,
`shift_up()`, `shift_down()`.

## Game flow (`Game` autoload, `scripts/autoload/game.gd`)

States: `BOOT, MENU, LOADING, INTRO, COUNTDOWN, RACING, FINISHED, FREE_ROAM`.
Modes: `"time_trial"` (one lap, checkpoints, medals, record) and `"free_roam"` (drive freely).
Maps: `Game.MAPS` (`hanami` — Hanami Pass 花見峠, spring noon; `momiji` — Momiji Valley 紅葉谷,
autumn golden hour).

UI calls: `Game.request_start(map_id, mode)`, `Game.request_restart()`, `Game.request_menu()`,
`Game.set_paused(bool)`, `Game.set_setting(key, value)`, `Game.request_quit()`.
UI listens: `state_changed`, `session_started`, `countdown_tick(3,2,1,0)`, `race_started`,
`checkpoint_passed(index, total, split, delta)`, `race_finished(result)`, `paused_changed`,
`settings_changed`, `notice(text)`.
Live data for the HUD: `Game.player_car` (car API above), `Game.session` with
`elapsed: float`, `checkpoint_index: int`, `checkpoint_total: int`, `progress: float` (0..1 lap),
`best_time: float`, `mode: String`.
`race_finished` result keys: `time, splits, best_time, previous_best, is_record, medal, map_id,
top_speed_kmh`.
Helpers: `Game.format_time(t)`, `Game.format_delta(d)`, `Game.best_time(map_id)`,
`Game.car_colors()`, `Game.CAR_COLORS`, `Game.get_setting(key)`.

Display: a player launch fits a 16:9 window to 80 % of the usable screen
(`Game._fit_window`). The 3D view renders at most 1920×1080 pixels before the quality preset's
own scale (`Quality.RENDER_BUDGET_PX`): bigger windows and fullscreen are upscaled with FSR, so a
Retina fullscreen costs about what a 1080p window does. Main re-applies the scale on every window
resize (`Quality.apply_render_scale`).

## Sound (`Sound` autoload, `scripts/autoload/sound.gd`)

Buses: Master → Music, Ambience, UI, SFX → (Engine, World).
`Sound.play_ui(&"hover"|&"click"|&"back"|&"start"|&"toggle")`,
`Sound.play_music(&"menu"|&"drive"|&"results", fade)`, `Sound.stop_music(fade)`,
`Sound.play_ambience(map_id, fade)`, `Sound.stop_ambience(fade)`,
`Sound.play_stinger(&"countdown"|&"go"|&"checkpoint"|&"finish"|&"record")`,
`Sound.play_3d(name, position, volume_db)`, `Sound.set_slowmo(time_scale)`.
Car audio: a `CarAudio` Node3D child of the car with `scripts/vehicle/car_audio.gd`, reading the car
API every frame.

## Style palette (sRGB hex, from yamazakura `src/core/palette.js`)

ink `#2a2235`, blossom `#fcd9e3 #f8c0d1 #f2a6be #fde9ef`, blossom deep `#e68aa8`,
leaf `#9ccb6b #6ea655 #3f7348`, cedar `#2f5d4a #3a6c55`, maple `#e75b3d #f2873e #d13f35 #f5b04a`,
bark `#6b4d42`, grass `#a3cf72 #8dc266 #bad981`, earth `#b38c64`, rock `#a29d96`,
asphalt `#505669`, line `#f5f2ea`, vermilion `#e44a30`, wood `#a47148`, plaster `#f4ede0`,
roof tile `#4f5a6d`, stone `#bab3a6`, paper lantern `#fff0d2`, gold `#f2c552`,
shadow tint `#9a92c8`, sky top `#6aa8e8`, sky haze `#e8eef0`, sun fog `#ffe2c0`.

## Episode 2 (branch `ep2`)

Goals: fun arcade handling (strong brakes, sharp turn-in, no spins at speed, quick launch), a
garage with two cars and a livery picker that shows on the car, track cards with a top-down map
and the route, and a campaign that chains stages with an untimed liaison drive.

### Ownership (ep2)

| Slice (agent name) | Owns |
|---|---|
| physics (`Physics`) | `scripts/vehicle/*` except `car_audio.gd`, `scripts/camera/chase_camera.gd`, `scenes/car/*`, `tools/physics/*`, `docs/PHYSICS.md`, the `medals` values in `Game.MAPS` and the `stats` values in `Game.CARS` |
| menu (`Menu`) | `scripts/ui/screens/title_screen.gd`, `scripts/ui/widgets/*`, new menu/garage UI files, `scripts/game/menu_stage.gd` (new), `scripts/camera/cine_camera.gd`, the menu functions of `scripts/main.gd` (`_enter_menu`, `_on_settings_changed`, new menu-view handler), `Game.set_menu_view`, the livery fix in `scripts/world/toon_materials.gd` / `scripts/fx/car_look.gd`, `tools/build/capture_topdown.gd`, `assets/ui/maps/`, `docs/UI.md` |
| campaign (`Campaign`) | the campaign API in `scripts/autoload/game.gd`, the rest of `scripts/main.gd`, `scripts/game/race_session.gd`, `scripts/ui/ui_root.gd`, `scripts/ui/screens/{results_screen,hud,race_intro,pause_menu}.gd`, new campaign UI files, `tools/game/*` |
| liaison map (`Map`) | `tools/mapgen/*`, `assets/maps/natsu/`, `scripts/world/*`, `shaders/` (season support) |
| second car (`CarModel`) | `tools/blender/build_car_hayate.py` (plus helpers shared with `build_car.py`), `assets/models/car/hayate.glb`, `docs/renders/car_hayate_*` |
| audio (`Audio`) | `tools/audio/*`, `assets/audio/*`, `scripts/autoload/sound.gd`, `scripts/vehicle/car_audio.gd`, `docs/AUDIO.md` |

Need a change in a file you do not own? Message the owner (`write agent://<Name>`); a one or
two line hook may be made by you once the owner agrees. Each agent works in
`~/Projects/sakura-rally-wt/ep2-<slice>` on branch `ep2-<slice>` cut from `ep2`, commits there,
never pushes and never touches `main`; the lead merges into `ep2`.

### Car catalogue

- `Game.CARS`, `Game.get_car(id)`, `Game.current_car()`, setting `car_id` (default `"sakura"`).
  Main spawns `load(Game.current_car()["scene"])`.
- `scenes/car/car_hayate.tscn` (Physics): root runs `scripts/vehicle/car.gd` with Hayate's
  handling as exported overrides; its `Visuals` shows `assets/models/car/hayate.glb` (CarModel).
- The Hayate GLB follows the car GLB contract above: same node names (`Body`, `Wheel_FL` …,
  optional `Caliper_*`), same material names, same chassis geometry (wheelbase 2.55 m, axles at
  z = -1.27 / +1.28, track ±0.78 m, tyre radius 0.33 m / width 0.24 m, wheel centres at
  y = 0.33). Body about 4.15 × 1.70 × 1.25 m: a low 1980s Japanese rear-drive coupe with
  pop-up headlights. Optional `PopUp_L` / `PopUp_R`: headlight pods, origin on the hinge,
  closed at rest, open by rotating about their local +X by about 55° (front edge lifts); code animates them.
- `Car.engine_sound: StringName` (Physics exports it, default `&"turbo4"`, Hayate `&"na4"`);
  `car_audio.gd` (Audio) picks its loop set from it.

### Liaison map `natsu` (Map)

- `Game.MAPS` has the entry (`"liaison": true`, no medals); `Game.stage_maps()` skips it.
- `SPEC["road"]["closed"] = False` builds an open road. `map.json` adds `"closed": false` and
  `"arrival": {"pos": [x, y, z], "yaw": rad, "radius": m}`; `spawn` / `start_line` sit at
  s = 0; `checkpoints` may be empty.
- `Track.closed: bool`. On an open track `point()`, `position_at_abs()`, `nearest()` clamp
  instead of wrapping, `to_curve()` returns an open curve, `Track.length` runs start → arrival.
- Atmosphere preset `summer_afternoon`; season `summer` in `MapWorld.SEASONS` and `SkyRig`.
- Ambience id `natsu`: Audio adds `assets/audio/ambience/natsu.ogg` and the `Sound.AMBIENCE` entry.

### Road corridor (mapgen, `tools/mapgen/lib/corridor.py`)

Mapgen keeps the road driveable wide: a car that runs wide or leans on the outside of a corner
meets only walls it can scrape along or props it knocks over.

- **Corridor:** |lateral| < half width + verge + 1.5 m from the centreline of any stretch of
  road. It widens to half width + verge + 4 m on the outside of corners tighter than 60 m and
  over the 40 m braking zone before them, and on both sides for ±8 m around every
  `map.checkpoints` entry (room for the runtime's fabric gate uprights).
- **Rigid** props (every collider not listed below: trees, poles, rocks, lanterns, jizo,
  buildings, spectators …) stay out of the corridor. Low rocks, stumps and logs stay out of
  the wide corridor everywhere. Natsu's sign boards (`signs`) break like smashables but still
  step out until their posts clear the corridor.
- **Smashable** props (`SMASHABLE`, the mirror of `SoftCourse.SMASHABLE` in
  `scripts/world/soft_course.gd`; keep the two in step) may stand in the corridor but never on
  the tarmac: |lateral| >= half width + 0.3 m.
- **Exempt:** guardrails and bridge rails (built along the road on purpose) and the start /
  finish arches (the runtime softens their uprights).
- Mapgen moves every offender straight out from the road until it clears, keeping its height
  above the ground and staying off water, paved lots (trees), ground steeper than 40° and other
  props and rails; one that finds no room within 16 m is dropped. Each build prints the survey
  before and after (`corridor before / moved / after`); after must read 0.
- Mapgen emits no `checkpoint_gate` instances; the runtime builds the gates from
  `map.checkpoints`.
- Bridge ends: where the carve fades out towards a deck, the ground is capped under the road
  and ramps down under the deck (`road.bridge_clearance`, default 1.6 m below the deck), so no
  bank shows through the road.
- Sign boards (`map.json` `signs[i]`, natsu only): each is its own `meshes` entry named by
  `signs[i].mesh` (`sign_<i>`, `"local": true`, material `props_vc`), in sign-local
  coordinates: origin at the base centre on the ground, board front +Z, yaw 0. The runtime
  places it at `Transform3D(Basis(Vector3.UP, yaw), base)` and must not add `local` meshes at
  the world origin. `signs[i].collider` = `{"type": "box", "size": [w, h, d], "center": [x, y, z]}`,
  sign-local, covers posts and board. `pos` (board face centre, world) and `lines` feed the
  Label3D text. No sign geometry is left in `dressing` and no sign post in `collision_boxes`:
  the runtime (SoftCourse) builds and breaks the signs.

### Session and campaign (Campaign)

- Session mode `Game.MODE_LIAISON`: no timer, no checkpoints, no wrong-way nag;
  `RaceSession.arrived` fires when the car enters the arrival zone (within
  `MapWorld.arrival_radius` of `map.arrival`, or on the road in its last `arrival_radius`
  metres) and `Game.notify_arrived()` re-emits it as `Game.arrived`. `RaceSession.progress`
  is start → arrival (0..1) and `RaceSession.distance_left` the road metres to go.
- Campaign API on `Game`: `const CAMPAIGN` (legs `{"map", "kind": "stage"|"liaison", "code",
  "title", "title_jp", "kanji"}`: SS1 `hanami`, L1 `natsu`, SS2 `momiji`), `const RIVALS`
  (`{"name", "name_jp", "team", "pace": [factor per stage]}`, stage time = gold × factor),
  `request_campaign(fresh: bool)` (a finished campaign always restarts),
  `request_campaign_continue()`, `campaign_status() -> {"started", "finished", "leg", "legs",
  "next", "results"}` (`leg` = next leg to play, `legs` when only the finale is left;
  `results` = map id → `{"time", "medal"}`), `var campaign_active: bool`, `var campaign_leg`
  (leg being played, -1 outside), `campaign_classification()` (rows `{"name", "name_jp",
  "team", "player", "times", "total", "gap"}`, fastest first), signals
  `campaign_leg_started(index, leg)`, `arrived`, `campaign_finished(summary)` (summary
  `{"classification", "results", "position", "field"}`). Main calls `notify_campaign_leg(i)`,
  `notify_campaign_finished()` and `end_campaign_session()` (title / Time Attack).
  A campaign stage's `race_finished` result adds `"campaign": true, "leg", "standing",
  "field"`. Progress (`[campaign]` leg, results, finished) lives in the player save
  (`persistent` rules); a quit resumes at the start of the saved leg.
- `Game.State` adds, in this order after `FREE_ROAM`: `JOURNEY` (the painted journey map,
  also the campaign's loading screen), `LIAISON` (driving a liaison; within braking distance
  of the time control Main takes the car over and brakes it in, "Time control ahead"),
  `ARRIVED` (the arrival beat: the car rolls to rest at the time control under a roadside
  shot, arrival card), `FINALE` (classification and end card). Pause works in `LIAISON` as in
  `RACING`.
- Campaign flow: title → `JOURNEY` → `LOADING` → `INTRO` → stage (`COUNTDOWN`, `RACING`,
  `FINISHED`, results Continue) or liaison (`LIAISON`, `ARRIVED`) → `JOURNEY` … → after the
  last leg `JOURNEY` → `FINALE` → `MENU`. Music: `liaison` on the liaison drive, `menu` on the
  journey map, `results` on the finale; stingers `arrived`, `campaign_complete`.

### Soft course (SoftCourse)

- `scripts/world/soft_course.gd` (`SoftCourse`, `MapWorld.soft_course`) owns the list:
  `SoftCourse.SMASHABLE` (prop name → speed share lost, sound, fling, chip colour). Mapgen keeps a
  copy for its corridor rules in `tools/mapgen/lib/corridor.py`; keep the two in sync. Every prop
  with a manifest collider that is not in that list is RIGID. Do not add fields to
  `assets/models/props/manifest.json` for this: it is generated.
- SMASHABLE instances get no static collider. Each physics tick SoftCourse tests every `Car` in the
  tree (found through `SceneTree.node_added`, so the player car, the menu flyover car and tool cars
  alike) against a spatial hash of their footprints (the manifest collider: a box, the span of a
  multi-post cylinder, or a circle). A hit applies `car.apply_central_impulse(-v_horizontal ×
  mass × loss)` (cone 1 %, tape 2 %, banner/flag 3 %, sign/fence 4 %, tyre stack 6 %, bales
  8–12 %; hits within ~0.6 s share a 14 % budget), hides the MultiMesh instance, flings a pooled
  debris body (at most 24 live, gone after 4.4–5.6 s), puffs dust and chips, and plays `thump` or
  `impact_light` through `Sound.play_3d`. No torque, no lift and no `Car.impact` signal.
  Signals: `smashed(prop, point, speed_before, loss)`, `upright_hit(point, speed_before, loss)`.
- `start_arch` / `finish_arch` legs (`SoftCourse.SOFT_UPRIGHT_PROPS`) are soft uprights: 2.5 %
  and the arch nods back; its visuals stay.
- Road signs (`signs[i]` with `mesh`, `base` and `collider`): MapWorld `_build_signs` puts the
  sign's mesh and its Label3D lines under one `Signs/Sign_<i>` node and registers it with
  `SoftCourse.add_sign()` as kind `road_sign` (`SoftCourse.ROAD_SIGN`, 4 %, `thump`). A hit
  hides the node (board and text together) and flings two debris pieces, the posts (triangles
  reaching below 40 % of the sign's height) and the board. In an older pack (no `mesh`) the board
  stays in `dressing` and its posts in `collision_boxes`, rigid as before.
- `checkpoint_gate` instances are skipped (`SoftCourse.SKIPPED_PROPS`); `FabricGate`
  (`scripts/world/fabric_gate.gd`, banner shader `shaders/world/fabric_banner.gdshader`) stands at
  every `map.checkpoints` entry of a closed stage except one within 20 m of a start/finish arch,
  and at the final checkpoint (time control) of an open road. Uprights (soft, 2.5 %, wobble back)
  stand at ±(track half width + verge + 1.5 m + 0.35 m) from the centre line; the banner spans
  4.4–5.55 m above the road. It billows when a car crosses the gate line between the uprights, and
  on `Game.checkpoint_passed` for its checkpoint. Mapgen keeps rigid props out of ±8 m along the
  road and out to half width + verge + 4 m around every checkpoint.
- The course comes back whole when a new car enters the tree (restart), when a car jumps farther
  than one physics step could move it (`Car.reset_to()`, reset to the track), and on a map reload.
- Nothing is created or loaded at hit time: the debris bodies, burst emitters and their materials
  are built with the map, the hit sounds sit in Sound's cache from boot, and once `MapWorld.built`
  fires (the loading cover is still up) every smashable mesh and burst type is drawn for a few
  frames, tiny, in front of the active camera, so their pipelines compile behind the cover
  (`SoftCourse.is_warm()`).
- Probe: `tools/game/softcourse_probe.gd -- map=hanami [car=hayate]` (headless). Run windowed
  (`--audio-driver Dummy`, no `--headless`) it also logs frame times, physics steps, pipeline
  compilations and node/resource counts in the second after the 1st, 2nd and 10th smash and the
  first gate pass and hit, and fails above 25 ms or on any compilation or creation there.

### Menu (Menu)

- Title hub: Campaign, Time Attack, Garage, Settings, Quit. The Campaign item calls
  `Game.request_campaign(...)` and labels itself from `Game.campaign_status()`.
- `Game.set_menu_view(view)` and signal `menu_view_changed(view)`, views `"title"`,
  `"time_attack"`, `"garage"`. In `"garage"` the menu car parks at the map spawn and the cine
  camera orbits it; a livery or car change shows on that car at once.
- Top-down card art from `tools/build/capture_topdown.gd`: `assets/ui/maps/<id>_top.png` and
  `assets/ui/maps/<id>_route.json` = `{"image_size": [w, h], "world_rect": [x0, z0, width,
  height], "closed": bool, "points": [[u, v] …], "surface": [ … ], "start": [u, v],
  "finish": [u, v], "checkpoints": [[u, v] …]}` with u, v in 0..1 image space.

### Autopilot styles (Showoff)

- `Autopilot.style`: `&"tidy"` (default; physics tests, liaison roll-out, finish cruise, tool
  flows, keyboard bot) or `&"showoff"` (title flyover via `MenuStage.FLYOVER_STYLE`, demo reel).
  `Main._attach_autopilot(scale, max_kmh, style = &"tidy")`.
- `Autopilot.next_slide_point(min_ahead, max_ahead) -> Vector3`: middle of the next slid
  corner (`Vector3.INF` if none); the flyover's roadside shot stands there.
- Measured by `tools/showoff/drift_probe.gd` with ep2 f5017a4 merged (headless, one flying lap
  per row; tidy = the flyover before, scale 0.82 / 150 km/h; showoff = the flyover now, scale
  1.0 / 150 km/h):

| map | car | style | lap s | mean km/h | slide>12° % | in corners % | slides>20° | max slip° | brake s | brake apps | lat/hw | rigid | resets |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| hanami | sakura | tidy | 131.58 | 80.9 | 0.0 | 0.0 | 0 | 4.5 | 30.3 | 175 | 0.31 | 0 | 0 |
| hanami | sakura | showoff | 113.04 | 94.2 | 8.2 | 17.5 | 7 | 35.0 | 14.4 | 29 | 0.94 | 0 | 0 |
| hanami | hayate | tidy | 134.64 | 79.0 | 0.0 | 0.0 | 0 | 4.1 | 23.7 | 250 | 0.31 | 0 | 0 |
| hanami | hayate | showoff | 117.57 | 90.5 | 11.3 | 23.9 | 10 | 34.4 | 11.6 | 25 | 1.04 | 0 | 0 |
| momiji | sakura | tidy | 114.25 | 83.4 | 0.0 | 0.0 | 0 | 3.5 | 26.8 | 190 | 0.35 | 0 | 0 |
| momiji | sakura | showoff | 98.33 | 97.5 | 4.4 | 9.4 | 4 | 31.6 | 13.0 | 20 | 1.52 | 0 | 0 |
| momiji | hayate | tidy | 117.68 | 81.0 | 0.0 | 0.0 | 0 | 4.3 | 20.6 | 231 | 0.27 | 0 | 0 |
| momiji | hayate | showoff | 102.02 | 93.8 | 4.6 | 10.0 | 4 | 32.0 | 9.4 | 15 | 1.19 | 0 | 0 |

  lat/hw > 1.0 means the car's centre crossed the road edge: in showoff that happens on the way
  out of the momiji gravel hairpins (up to 1.8 m onto the verge) and by 0.14 m once on hanami
  with Hayate. Open: hanami Sakura is at 17.5 % of corner time sliding (target 20 %).

## Episode 3 (branch `ep3`)

From Vel's third playtest. Goals:

- Replays: every drive the player makes is recorded to disk, and a tool reviews them (where he
  hesitated, got lost, crashed or flew off) so the lead can see what was unclear.
- Corners: big warning signs seen well ahead; barriers where the road edge drops, so a missed
  corner does not end off a cliff (it happened on Momiji).
- Chase camera: downhill the road ahead stays visible; today the car hides it.
- One connected world: Hanami, a branch road through the seasons, Momiji. After SS1 the car
  stops on the loop, the results say the stage is complete and point on to SS2; Continue opens
  the branch that was blocked and the player drives on from where he stopped. The road starts
  among sakura and blends spring → summer → autumn into Momiji. No journey map, no liaison
  level, no loading between legs.
- Garage: a real place, not the start grid; on a car switch the old car drives off and the new
  one drives in; every car in a strip at the bottom; no car ever drops from the air.
- People: better-looking spectators that tumble comically when hit and get back up.

### Ownership (ep3)

| Slice (agent) | Owns |
|---|---|
| world generation (`WorldGen`) | `tools/mapgen/*` except what RoadSafety and Garage own below, `assets/maps/`, `docs/renders/map_*`, `docs/WORLD.md` (new) |
| world runtime (`WorldRuntime`) | `scripts/world/*` except `soft_course.gd` and `crowd.gd`, `shaders/*` except `shaders/ui/`, `scripts/fx/post_fx.gd`, the ambience part of `scripts/autoload/sound.gd`, the map-id migration of `tools/physics/*`, `tools/build/capture_map.gd`, `tools/build/smoke.gd` |
| campaign (`Campaign`) | `scripts/autoload/game.gd`, `scripts/main.gd` except the menu functions (Garage), `scripts/game/race_session.gd`, `scripts/game/arrival_stop.gd`, `scripts/ui/ui_root.gd`, `scripts/ui/screens/*` except `garage_panel.gd`, `scripts/ui/widgets/journey_strip.gd`, `tools/game/*`, `tools/build/capture_topdown.gd`, `assets/ui/maps/`, the map-id migration of `tools/video/*` and `tools/showoff/*`, the flow sections of `docs/UI.md` |
| road safety (`RoadSafety`) | `tools/mapgen/lib/roadside.py` (new), the roadside dressing in `tools/mapgen/lib/road.py` (guardrails, delineators, chevrons) and its call sites in `mapgen.py`, corner-sign entries in `tools/mapgen/maps/*.py`, the new sign props (`tools/blender/props/*`, outputs in `assets/models/props/`), their `SoftCourse.SMASHABLE` entries and the `corridor.py` mirror, the sign view distance in `MapWorld.CATEGORY_VIEW`, `tools/physics/flyoff_probe.gd` (new) |
| camera (`Camera`) | `scripts/camera/chase_camera.gd`, `tools/physics/camera_probe.gd` (new), the camera section of `docs/PHYSICS.md` |
| replays (`Replays`) | `scripts/autoload/replays.gd` (new autoload `Replays`) and its `project.godot` line, `scripts/game/replay_*.gd` (new), `tools/replay/*` (new), `docs/REPLAYS.md` (new) |
| garage (`Garage`) | `scripts/game/menu_stage.gd`, the garage parts of `scripts/camera/cine_camera.gd`, `scripts/ui/screens/garage_panel.gd`, `scripts/ui/widgets/car_selector.gd` (becomes the car strip), `scripts/game/garage_set.gd` (new), garage props (`tools/blender/props/garage.py`, new, outputs in `assets/models/props/`), the `garage` entry of `tools/mapgen/maps/hanami.py` and its pass-through to `map.json`, `assets/ui/cars/`, the menu functions of `scripts/main.gd` (`_enter_menu`, `_on_settings_changed`, `_on_menu_view_changed`), the garage section of `docs/UI.md` |
| people (`People`) | `tools/blender/props/people.py` and the spectator outputs, `scripts/world/crowd.gd` (new), the crowd hooks in `soft_course.gd` / `map_world.gd`, the spectator rules in `corridor.py` and `scatter.py` (`_crowd`), crowd sounds |

Someone else's file: message the owner (`write agent://<Name>`); a hook of a few lines may be
made by you once the owner agrees. Work in `~/Projects/sakura-rally-wt/ep3-<slice>` on branch
`ep3-<slice>` cut from `ep3` (`git worktree add -b ep3-<slice> ~/Projects/sakura-rally-wt/ep3-<slice> ep3`),
copy the import cache first (`cp -R ~/Projects/sakura-rally/.godot <worktree>/`), then
`--import`. Commit there; never push; never touch `main`, `ep2` or `ep3`. The lead merges into
`ep3`.

### Running things while Vel uses the Mac

Nothing opens a window: pixels come from `--summer-offscreen --audio-driver Dummy`, the rest runs
`--headless`. Wrap runs in `timeout` and `nice -n 5`. Eight agents share the machine, so frame
rates measured during ep3 work are noisy: report them, the lead re-measures at integration.

### Scripted spawns (lead, done)

- `Car.place_at_rest(xform: Transform3D)`: the car on the ground under `xform.origin` as it sits
  at rest (origin on the plane through the four tyre contacts, level with it, heading from
  `xform`, still). Measured on all three maps with both cars: it moves 6 mm and is still after
  0.13 s, where `reset_to()` from the pack spawn drops 0.78 m and still bounces after 1 s. Every
  scripted spawn uses it (Main `_spawn_car` does; the garage, campaign legs and tools as well).
  `reset_to()` (+0.12 m) stays for resets during a drive.

### One world (WorldGen writes, WorldRuntime reads, Campaign drives)

- One pack, `assets/maps/world/` (`map.json` `"version": 2` + `map.bin`), loaded once at boot and
  kept for the whole session: menu, both stages, the liaison, free roam. The v1 packs (`hanami`,
  `momiji`, `natsu`) and every v1 code path are gone by the end of ep3.
- Layout: the Hanami region sits at the world origin, unrotated, so `maps/hanami.py`
  coordinates are world coordinates (the garage and the title flyover keep theirs). Momiji is
  placed (and turned if that helps) so that a branch road of about 2–2.5 km leaves the Hanami
  loop shortly after its finish line and joins the Momiji loop shortly before its start line.
  Natsu's content (village, river crossing, time control and service park, road signs, parked
  cars) moves onto that road. One mountain rim around the whole world and none between regions;
  no invisible walls; collision wherever a car can get to.
- Roads and routes. Roads are the physical ribbons: the two loops and the branch, with junction
  aprons where the branch meets a loop (no z-fighting, no step). Routes are what a session
  drives, each with its own track raw (the v1 ten columns), `season` and `atmosphere`
  (`spring_noon`, `summer_afternoon`, `autumn_golden`):
  - `hanami`, `momiji`: closed stage laps as today (`start`, `spawn`, `checkpoints`), plus
    `finish_stop` `{pos, yaw}`: where the car comes to rest after the finish line, on the road
    (on Hanami: before the branch gate, with the gate in view).
  - `liaison`: open. Its track starts at Hanami's `finish_stop`, follows the loop to the
    branch, runs the branch and follows the Momiji loop to its grid; `arrival` `{pos, yaw,
    radius}` is Momiji's spawn pose.
- Gates: `gates[]` = `{id, route, s, pos, yaw, width}` across the branch just past each junction
  (`hanami_branch`, `momiji_branch`). The runtime builds them (a closed road: striped barriers,
  a 通行止め board, a marshal); closed they are rigid, open they are out of the way.
- Seasons: the raw `season_grid` (u8 × 3 per cell: spring, summer, autumn weights summing to
  255; `origin`, `cell`, `dims` in `map.json`). The terrain palette is blended into the vertex
  colours by the same weights, and the scatter runs sakura → summer greens → maples along the
  branch (sakura around its first stretch, maples well before Momiji).
- The pack keeps v1's other keys (`water`, `collision_boxes`, `signs`, `parked`, `materials`,
  `meshes`, `raw`, `instances`) in world coordinates, and `garage` (from Garage). `map.bin`
  stays under 50 MB (compress it if needed and say how).
- WorldGen documents the final schema in this section and the layout and build in
  `docs/WORLD.md`. It ships an early skeleton pack (roads, terrain, routes, gates, season grid,
  sparse props) as soon as one loads and messages WorldRuntime and Campaign the commit.

### MapWorld v2 (WorldRuntime implements; Campaign and tools use it)

- `MapWorld.map_id` is a route id (`hanami`, `momiji`, `liaison`): `build()` always loads the
  world pack and selects that route, so a tool's `map.map_id = "hanami"; await map.build()`
  keeps working.
- `routes: Dictionary` (id → route), `route_id: String`, `select_route(id)`: points the fields
  every consumer reads today (`track`, `closed`, `spawn`, `start_line`, `checkpoints`,
  `arrival`, `arrival_radius`, `arrival_progress`) at that route, plus `finish_stop:
  Transform3D`. The fabric gates of both stages stand all the time.
- `gates: Dictionary` (id → node with `set_open(open: bool, animate := true)`, `is_open`,
  signal `opened`).
- `season_at(pos: Vector3) -> Vector3` (spring, summer, autumn). The atmosphere, colour grade,
  global shader parameters, sky particles (petals → fluff → leaves), ground and road litter and
  the ambience follow the season at the camera; shaders read the grid as the global texture
  `sr_season` (its rect in `sr_season_rect`).
- `garage: Transform3D` (identity when the pack has none).
- The world loads behind the boot / loading screen once; a start inside the loaded world only
  places the car (`place_at_rest`) under a short cover.

### Campaign in one world (Campaign)

- Legs stay SS1 `hanami`, L1 `liaison`, SS2 `momiji`, but the liaison is not a level: no
  JOURNEY state, no journey map, no leg code on the road. Flow: title → Campaign → INTRO →
  COUNTDOWN → SS1 → FINISHED: the car is brought to rest at Hanami's `finish_stop`; the results
  say the lap is complete (time, medal, standing) and a side panel says what comes next
  ("SS2 Momiji Valley: drive on, the road is open") → Continue: the `hanami_branch` gate opens
  in view and the player drives off from where he stopped (LIAISON; the HUD shows a road sign
  to Momiji with the distance) → at Momiji's grid the car is brought to rest (ARRIVED, a short
  beat) → SS2 start card and COUNTDOWN on the spot → SS2 → FINISHED at Momiji's `finish_stop` →
  results → FINALE. No cover and no reload between legs.
- Time Attack and free roam run in the world: time trials keep the gates closed, free roam
  opens them. Resume: SS1 → Hanami grid; L1 → Hanami `finish_stop` with the gate open; SS2 →
  Momiji grid. Records and campaign results stay keyed by stage id.

### Corners (RoadSafety)

- Every corner that needs braking gets big warning signs, computed from the road for every road
  (loops and branch): an advance warning well before the braking point and big chevron boards
  on the outside through the corner, scaled with severity; high contrast in the cel look, seen
  from far (their own view distance), never hidden by props. They are kit props in
  `SoftCourse.SMASHABLE` (they break), except where they are mounted on a guardrail.
- Guardrails wherever the road edge drops, outsides of corners first: a car that misses a corner
  at any speed the road allows scrapes along a rail and stays up on the road.
  `tools/physics/flyoff_probe.gd` proves it corner by corner.
- The code is functions of one road and the terrain (`tools/mapgen/lib/roadside.py`,
  `road.py`); WorldGen calls them for every road of the world.
- Props (`tools/blender/props/corner.py`, category `corner_sign`, `CATEGORY_VIEW` 1000 m):
  `corner_warn_{curve,sharp,hairpin,series}_{left,right}` (3.1 m yellow diamonds on two posts,
  board centre 3.05 m up at scale 1, placed at 1.4-1.7 with severity; `series` = linked bends, the first to
  that side), `corner_chevron_{left,right}` (1.2 x 1.5 m boards, placed at 1.2-1.5) and
  `corner_chevron_rail_{left,right}` (0.9 x 1.1 m on a rail post, same scale, no collider, not smashable). The old
  `chevron_*` and `sign_curve_*` props are gone.
- `map.json` `corners` (one list per road): `dir`, `severity` (1 fast, 2 sharp, 3 hairpin),
  `kind`, `radius`, `angle`, speeds `v_approach`/`v_entry`/`v_min` (km/h, the plausible profile),
  poses `brake`/`turn_in`/`mid`/`apex`/`exit` (`pos`, `yaw`, `s` in Track distance), `warning`
  (`pos`, `yaw`, `s` of the road beside it, `prop`, `visible_m`; null when the corner before
  announces it) and `path` (centreline `[x, y, z, half_width]` every 4 m from 20 m before
  turn-in to 150 m past the exit).

### Camera (Camera)

- `ChaseCamera` keeps its interface. Downhill the camera rises and pitches with the slope so the
  road ahead shows over the car; `tools/physics/camera_probe.gd` measures how much of the road
  ahead is visible on the descents of every stage.

### Replays (Replays)

- Autoload `Replays` records every drive the player controls (RACING, LIAISON, FREE_ROAM) from
  `Game` signals, `Game.player_car` and `Game.session`, with no Main edits: per physics tick the
  inputs, the car state and the camera; events (impacts, landings, resets, smashes, checkpoints,
  off-road, wrong way, finish). Files in `user://replays/` (format in `docs/REPLAYS.md`). Tool
  runs record only when a tool asks, and never into the player's folder.
- `tools/replay/review.gd` lists and summarises replays (where time went, where the car left the
  road, resets, hesitations) and renders what the player saw at chosen moments, offscreen.

### Garage (Garage)

- A real place in the Hanami region, before or beside the start straight and away from the
  branch (WorldGen and Garage agree on the spot by message): `map.json` `garage` `{pos, yaw, …}`,
  `MapWorld.garage`.
- On a car switch the old car drives off and the new one drives in and parks. The car choice is
  a strip of every car at the bottom of the screen (fixed layout; no arrows that move with the
  name). The garage car is placed at rest, never dropped.

### People (People)

- New spectator models: better-looking people in the cel look (same prop names, or a new set
  documented here).
- Spectators are not rigid anymore: a car that hits one knocks it over in a comic tumble (no
  gore); it lies a moment and gets back up, and the car loses a little speed.
  `scripts/world/crowd.gd` owns the list, mirrored in `corridor.py` like `SMASHABLE`.
