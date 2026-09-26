# Sakura Rally 桜ラリー

A cel-shaded low-poly rally game in Godot 4.7: two small hand-dressed maps drawn like an anime
background, in the look of the yamazakura sakura bike ride
(`/Users/velizard/Projects/SummerEngineWorkspace/yamazakura`). The look comes from flat cel
bands, shadows tinted violet instead of darkened, thin ink lines, painted clouds and aerial haze.

![Hanami Pass from above](docs/renders/hanami_aerial.jpg)
![Momiji Valley from above](docs/renders/momiji_aerial.jpg)

## Play

Double-click `Play Sakura Rally.command`. It runs the project with stock Godot 4.7.2 from
`/Applications/Godot.app`; `Godot --path .` does the same from a shell. The Summer binary
(`/Applications/Summer.app/Contents/MacOS/Summer`, a Godot 4.7.2 build) runs the project unchanged.

The window opens at 16:9, sized to 80 % of the screen. Fullscreen is in Settings.

| Action | Keyboard | Gamepad |
|---|---|---|
| Throttle | W / ↑ | RT |
| Brake; hold at a standstill to reverse | S / ↓ | LT |
| Steer | A, D / ←, → | left stick |
| Handbrake | Space | A |
| Shift up / down (manual gearbox) | E / Q | RB / LB |
| Camera: chase, far chase, hood, bumper | C | Y |
| Put the car back on the road | R | Back |
| Pause | Esc / P | Start |
| Horn | H | L3 |
| Hide the UI for screenshots | F1 | |

During the countdown the car is held on the line. Hold the throttle: launch control keeps the
engine at 4600 rpm, and at GO the clutch drops into first.

## Modes and maps

- **Time Trial**: one lap through checkpoints, with splits against your best, a medal and a saved record.
- **Free Roam**: no timer. Drive anywhere; R puts you back on the route.

| Map | Setting | Gold / Silver / Bronze |
|---|---|---|
| Hanami Pass 花見峠 | spring noon, tarmac and gravel under the blossom | 2:15 / 2:30 / 2:55 |
| Momiji Valley 紅葉谷 | autumn golden hour, loose dirt through the maples | 1:58 / 2:12 / 2:34 |

The title screen has five liveries. Settings cover quality (low / medium / high), automatic or
manual gearbox, camera, km/h or mph, three volume sliders and fullscreen. The 3D view renders
at most 1920×1080 pixels before the quality scale, and FSR upscales bigger windows. A Retina
fullscreen frame therefore costs about as much as a 1080p window.

Settings and records live in
`~/Library/Application Support/Godot/app_userdata/Sakura Rally/sakura_rally.cfg`.

## Demo video

`export/sakura_rally_demo.mp4` is 63 s long: 1920×1080 at 60 fps, H.264 High + AAC-LC,
−14 LUFS. It is 232 MB, inside X's upload limits (512 MB, 140 s). Movie Maker renders it offline
from the real game, cutting on the beat of the drive theme. `export/` is not in git; rebuild it with
`tools/video/render_demo.sh`: about 10 min to render the footage, then 3 min to cut.

## How it is built

| Part | Source | What it is |
|---|---|---|
| Car | `tools/blender/build_car.py` → `assets/models/car/` | Low-poly rally car built by a script. Tyre and rim are one object per wheel, spinning and steering; calipers steer without spinning |
| Physics | `scripts/vehicle/`, [docs/PHYSICS.md](docs/PHYSICS.md) | Custom raycast car on a `RigidBody3D` (Jolt, 120 Hz): suspension, a combined-slip tyre model per surface, 6-speed gearbox, turbo, AWD with limited-slip couplings |
| Look | `shaders/`, `scripts/fx/` | Toon ramps with violet shade bands, depth-based ink lines, anime colour grade, painted sky, petals, low-poly dust |
| Maps | `tools/mapgen/` → `assets/maps/` | Python map compiler: terrain, road spline, surfaces, checkpoints, instances from an 86-prop kit (`tools/blender/build_props.py`) |
| Audio | `tools/audio/`, [docs/AUDIO.md](docs/AUDIO.md) | Synthesised engine loops (8 on load, 8 off load), turbo whistle and blow-off, dog-box gearbox whine, tyre sounds per surface, UI and stingers. Music is ElevenLabs Music via fal; ambience is fal sound-effect beds with synthesised birds and crickets |
| UI | `scripts/ui/`, [docs/UI.md](docs/UI.md) | Title, settings, ink transitions, intro card, countdown, HUD, finish, results and pause, all built in code |

Shared conventions and the runtime APIs: [docs/CONTRACTS.md](docs/CONTRACTS.md). Rebuild commands:

```sh
G=/Applications/Godot.app/Contents/MacOS/Godot
/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup --python tools/blender/build_car.py
uv run --with numpy --with pillow python tools/mapgen/mapgen.py all
timeout 180 $G --headless --disable-crash-handler --path . --import   # after changing raw assets
```

## Verification

Latest results, 2026-09-26, M1 Max:

```sh
timeout 900 $G --headless --disable-crash-handler --fixed-fps 120 --path . -s res://tools/physics/run_tests.gd
timeout 400 $G --disable-crash-handler --path . -s res://tools/game/flows.gd -- map=hanami
timeout 600 $G --disable-crash-handler --path . -s res://tools/game/playthrough.gd -- map=momiji mode=time_trial
```

- Physics suite: 26/26 passed. 0–100 km/h takes 5.0 s on tarmac and 5.5 s on gravel; top speed is
  188 km/h; skidpad grip is 1.03 g on tarmac and 0.74 g on gravel; the car settles after a jump
  landing in 0.26 s with no bounce; a 309 s soak over jumps, walls and banking produced no NaN.
- Game flows on both maps (free roam, pause and resume, reset, restart during the countdown,
  launch, camera cycling, all three quality presets): 0 failures. Median FPS in a 1920×1080
  window, low / medium / high: Hanami 120 / 120 / 109, Momiji 120 / 96 / 87. 120 is the vsync cap.
- End-to-end playthroughs, with the autopilot driving the real game from the title through the
  results and back: Time Trial and Free Roam on both maps. The autopilot takes gold on both:
  2:03.595 on Hanami Pass, 1:48.351 on Momiji Valley.
- Fullscreen on the built-in 3456×2168 display, through the render budget: high 78 fps,
  medium 80 fps, low 119 fps.
- The launcher, driven in a real window with OS key events: title, intro card, countdown, race,
  pause, and Cmd+Q mid-race, which exits with no errors or leaks.
