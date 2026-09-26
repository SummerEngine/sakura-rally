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
- Headless has no pixels. For screenshots run windowed (no `--headless`); windows on screen are
  fine for this project. Capture with `get_viewport().get_texture().get_image().save_png(...)`.
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
