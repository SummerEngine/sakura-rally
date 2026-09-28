# Sakura Rally - replays

Every drive the player makes is recorded to disk as an input and state log (not video), so that
the lead can see afterwards where a drive went wrong: where Vel hesitated, crashed, flew off or
did not know which way the road went. `tools/replay/review.gd` lists and summarises the files
and renders what the player saw at any moment, offscreen.

| Piece | File |
|---|---|
| recorder (autoload `Replays`) | `scripts/autoload/replays.gd` |
| one car's recording (frames, events, blocks), for the recorder and for tools | `scripts/game/replay_writer.gd` |
| file format (offsets, blocks, events) | `scripts/game/replay_format.gd` |
| reader (frames, events, interpolated car and camera) | `scripts/game/replay_data.gd` |
| playback car (real model, livery, wheels) | `scripts/game/replay_ghost.gd` |
| playback scene (map, screen passes, camera; `build_world` alone for cars posed by a tool) | `scripts/game/replay_view.gd` |
| review tool: list, summary, render, compare | `tools/replay/review.gd` |
| the analysis behind summary and `render --events` | `tools/replay/analysis.gd` |
| round-trip check (record, read, summarise, render against live frames) | `tools/replay/record_lap.gd` |
| a game flow recorded, with live frames for `compare` | `tools/replay/capture_flow.gd` |
| pixel difference and side-by-side pairs of live and replay frames | `tools/replay/pairs.gd` |

## Where the files are

`user://replays/`, on this Mac
`~/Library/Application Support/Godot/app_userdata/Sakura Rally/replays/`. One file per driven
session, named `<date>_<time>_<route>_<mode>.srr` (local time, e.g.
`2026-09-26_16-03-40_hanami_time_trial.srr`). The route is the world pack's route id the session
drove (`MapWorld.route_id`: `hanami`, `liaison`, `momiji`). After each saved replay the folder is
pruned to the newest 100 files and at most 256 MB (`Replays.MAX_FILES`, `MAX_BYTES`).

## What is recorded, and when

The autoload follows the `Game` autoload only (no hooks in Main):

- A recording opens when `Game.state` enters COUNTDOWN, RACING, LIAISON or FREE_ROAM from any
  other state, or on a new `session_started`, while `Game.player_car` is set. A time trial
  therefore starts at the countdown (the countdown is part of the file), a liaison and free roam
  when the player gets the car.
- It closes 4 s into FINISHED or ARRIVED (the tail shows how the drive ended), on any other state
  (menu, loading, a restart), when `Game.player_car` changes, on the next `session_started`, or
  when the game quits (the file is completed before the tree goes).
- A campaign that chains legs on one car without a respawn (SS1 → FINISHED → LIAISON → ARRIVED →
  INTRO → COUNTDOWN of SS2) gets one file per leg: `session_started` for the next leg closes the
  running file, entering a driving state from FINISHED or ARRIVED starts a new one, and each
  header names the route of its own leg.

Per stored frame (every other physics tick, 60 Hz):

- keys (InputMap actions held: throttle, brake, steer left and right, handbrake; pressed since the
  last frame: shift up and down, reset, camera, pause, horn) and the car's shaped inputs (steer,
  throttle, brake as the car used them), steering output, handbrake, stick or keyboard steering;
- the car: position, rotation, linear and angular velocity, speed, body slip, gear, rpm,
  wheels on the ground, launch hold, shifting, player control;
- each wheel: contact and surface, suspension compression and travel, spin angle and speed,
  steer angle;
- the route: distance from the start line at the nearest road sample, lateral offset from the
  centreline, road half width, on or off the road; the session's next checkpoint, clock and
  whether it runs; the Game state;
- the camera of the last frame rendered before the tick: position, rotation, FOV, which camera
  (name and chase mode) and the exact time of that frame, so playback shows what was on screen.

Events, each with its time: `state`, `countdown`, `start`, `checkpoint` (split, delta to the
record; in a race the interval to the car ahead), `finish` (the whole result: time, splits, medal,
record, standing; in a race position, field, laps and classification), `arrived`, `notice`
(every HUD notice: wrong way, off the route, car reset, laps), `impact` (strength, point, speed),
`bump` (another car hit this one in a race: strength, point, speed and the other car's node
name), `landed`, `reset` (from, to, whether R was held), `hazard` (the session's water /
out-of-bounds resets), `smash` and `upright` (roadside props), `pause`, `camera`, `settings`
(what changed), `gate` (a road gate opened or closed: id, open), `surface` (id table for the
wheel surfaces) and `end` (why it closed, recording cost, and again the finish or the arrival).

The header: game name, version (the git branch and commit when run from a checkout, read from
`.git` once at boot), engine version, date (local, UTC, unix), route id, mode, the Game state it
opened in, campaign leg, car id and scene, livery (index and both colours), every setting
(camera, transmission, quality, units, volumes…), tool run or not, tick rate, frame size, the
names of the states and buttons, the route's length, whether it is a loop and its checkpoints,
the spawn pose, and each road gate of the world open or not (`gates`).

### Tool runs

Tool runs (`-s` scripts) never record unless a tool asks, and never into the player's folder:

- `Replays.record_to(dir)` from a tool, then `Replays.flush()` to close the recording in
  progress and wait until every file is on disk (`Replays.last_path` names the last one);
- or the user argument `replays=<dir>` on any run, e.g. forcing the game-flow tests to record:
  `$S --headless --path . -s res://tools/game/flows.gd -- flow=campaign replays=/tmp/flow_replays`;
- or a tool writes files of its own cars with a `ReplayWriter` per car, as the recorder does
  (`tools/rl/swarm.gd`: the AI's practice runs, `tools/rl/film.gd` plays them back).

`record_to` refuses the player's folder.

### Cost

The recorder encodes a frame straight into a memory buffer on the main thread; every 10 s of
frames the buffer goes to a worker thread that packs, compresses and appends it to the file, so
the main thread never touches the disk. Measured on the keyboard-bot lap of Hanami (M1 Max,
shared with seven other agents, so noisy): see [Verification](#verification).

## File format (version 1)

All little-endian. Offsets and codecs are constants in `scripts/game/replay_format.gd`.

```
"SRRP"  u16 version  u16 0  u32 header length  header JSON (UTF-8)
block*: u32 raw length  u32 compressed length  zstd(raw)
raw:    u32 frame count n
        n frames as FRAME_SIZE byte planes (byte 0 of every frame, then byte 1, ...), each byte
        stored as its difference to the same byte of the previous frame, mod 256
        event records to the end: f32 time  u16 length  event JSON
```

The byte planes and deltas pack about twice as small as the plain records (the slowly changing
high bytes of every field line up). A file cut short (crash, power loss) reads up to its last
whole block; its `end` event is missing (`ReplayData.complete == false`).

Frame, 126 bytes (f16 = half float, q16 = quaternion as 4 × s16 / 32767 with w ≥ 0,
u8n / s8n = 0..1 / -1..1 as 0..255 / -127..127):

| Offset | Type | Field |
|---|---|---|
| 0 | f32 | time since the recording opened (game time, s) |
| 4 | u16 | buttons (`ReplayFormat.BUTTONS`: bits 0–4 held, 5–10 pressed since the last frame) |
| 6 | u16 | flags: player control, launch hold, clock running, on the road, shifting, stick steering |
| 8 | u8 | Game state (names in the header `states`) |
| 9 | s8 | gear (-1 reverse, 0 neutral) |
| 10 | s8n | `Car.input_steer` |
| 11 | u8n | `Car.input_throttle` |
| 12 | u8n | `Car.input_brake` |
| 13 | s8n | `Car.steer` (output, share of the lock) |
| 14 | u8n | `Car.handbrake` |
| 15 | u8 | wheels on the ground |
| 16 | 3 × f32 | car position |
| 28 | q16 | car rotation |
| 36 | 3 × f16 | linear velocity (m/s) |
| 42 | 3 × f16 | angular velocity (rad/s) |
| 48 | u16 | rpm |
| 50 | f16 | `Car.speed_kmh` (signed, along the car) |
| 52 | f16 | body slip (rad) |
| 54 | 4 × 10 | wheels FL FR RL RR: u8 surface (0 = in the air, else 1 + surface id), u8n compression, u16 spin angle (0..2π as 0..65536), f16 spin speed, f16 steer angle, f16 travel from rest (m) |
| 94 | f32 | route distance from the start line (m; -1 without a route) |
| 98 | f16 | lateral offset from the centreline (m, + right) |
| 100 | u8 | road half width (dm) |
| 101 | u8 | next checkpoint |
| 102 | u8 | camera id (`camera` events; 255 none) |
| 103 | u8 | 0 |
| 104 | f32 | session clock |
| 108 | 3 × f16 | camera position minus car position |
| 114 | q16 | camera rotation |
| 122 | f16 | camera FOV (degrees) |
| 124 | f16 | camera sample time minus frame time (s) |

Inputs and pose share a frame although the shaped inputs are the ones the car used in the step
that produced the pose, and the held keys are read before the next step (8 ms apart at most).

## Reviewing

```sh
S=/Applications/Summer.app/Contents/MacOS/Summer
R="--disable-crash-handler --path . -s res://tools/replay/review.gd --"
timeout 60 $S --headless $R list                       # Vel's folder, newest first
timeout 120 $S --headless $R summary <file>            # a file name alone is looked up in Vel's folder
timeout 900 nice -n 5 $S --summer-offscreen --audio-driver Dummy $R render <file> 31.5 36 30
timeout 1800 nice -n 5 $S --summer-offscreen --audio-driver Dummy $R render <file> --events
timeout 900 nice -n 5 $S --summer-offscreen --audio-driver Dummy $R compare <capture folder>
```

- `list [folder]`: date, route, mode, car, length, size, and how it ended (finished with time
  and medal, arrived, or the state that closed it: a restart, the menu, quitting).
- `summary <file> [--json]`: builds the route's map headless (about 2 s) and prints the timeline
  with replay time, race clock, route distance, speed and where on the road (in a corner, so many
  metres before or after one, a straight): splits against the record (a race: the interval to
  the car ahead), the finish (a race: the position), crashes (impacts within a second grouped,
  strength ≥ 0.25), bumps from other cars (strength ≥ 0.3) and knocks, resets and their cause
  (R, the car's own reset when stuck or on its roof, water or out of bounds), off-road excursions
  (the whole car beyond the tarmac: side, duration, how far, entry speed), jumps and hard landings,
  wrong way (the notice and any second of driving against the road), pauses, camera and settings
  changes, and the hesitations: sudden lifts (flat out for a second, then off both pedals at speed
  outside a corner), heavy braking (flagged when already inside the corner, or with nothing to
  brake for), crawling under 15 km/h, zig-zag steering. Then the five worst 250 m sectors: time
  taken against a grip-limited reference speed profile of the road, with what happened in them.
  Corners are found from the route's curvature (C1… from the start line, direction, total angle,
  tightest radius; `hairpin` past 130° under 30 m). Time in a driving state with the car not
  under the player's control (the campaign flow's autopilot, a tool's bot) is reported as
  `autopilot drove … s` and left out of the top speed and the hesitations.
- `render <file> <t0> <t1> [fps]`: frames from replay second t0 to t1 (default 30 fps) as the
  player saw them: the world with the recorded route selected, its atmosphere, colour grade and
  ink lines, the road gates open or closed as they were at that moment, the car as a ghost with
  its real model and livery (wheels turning, steering and on their springs, body lean, pop-up
  lights), the camera from the recorded transform, FOV and lens. Into `dest=<folder>`
  (default `/tmp/sakura_replays/<replay name>/`): `frame_NNNN.png`, `sheet.png` (up to 12 frames)
  and `clip.mp4` (ffmpeg). `size=<w>x<h>` sets the resolution (default 1600x900).
- `render <file> --events [fps]`: a clip from 2.5 s before to 2 s after each notable moment
  (everything the summary weighs as notable, strongest twelve, default 15 fps), each in its own
  folder with its mp4, plus `moments.png` (the frame of each moment) and `moments.txt`.
- `compare <folder>`: the live frames `tools/replay/capture_flow.gd` saved during a recorded
  game flow (`<folder>/captures.json`: replay file, replay time, image) against the replay
  rendered at the same times: `replay_NN.png`, `pair_NN.png` (live left), `pairs.png` and the
  pixel difference of each pair.

Not in the renders: the HUD, dust and skid marks, props smashed during the drive (the map is as
built), spectators knocked over, the swing of a gate (it switches at the time of its event). The
replay time `t` is the one the summary prints.

## Verification

```sh
timeout 900 nice -n 5 $S --summer-offscreen --audio-driver Dummy --fixed-fps 60 --disable-crash-handler \
    --path . -s res://tools/replay/record_lap.gd -- map=hanami car=sakura at=15,40,70 dest=/tmp/ep3/replays/lap
timeout 600 nice -n 5 $S --headless --disable-crash-handler --path . -s res://tools/replay/record_lap.gd -- map=momiji
```

`record_lap.gd` drives a timed lap with the keyboard bot through the real input path, set up and
signalled as Main runs a time trial, records it with `Replays.record_to`, reads the file back,
checks it (one file, complete, every expected event, the finish time equal to the session's, the
last frame where the car is and in the FINISHED tail), prints the summary, the recording cost and
the size per minute, and offscreen renders the replay at the times it captured live frames, in
the same run on the same map, side by side with their pixel difference.

A game-flow run records too: `tools/game/flows.gd` takes `replays=<dir>` like any tool run.
`tools/replay/capture_flow.gd` runs a flow the same way and also saves live frames at chosen
replay times of one route's recordings; `review.gd compare <folder>` renders the replay at those
times:

```sh
timeout 1500 nice -n 5 $S --summer-offscreen --audio-driver Dummy --disable-crash-handler --path . \
    -s res://tools/replay/capture_flow.gd -- flow=campaign speed=3 replays=/tmp/ep3/replays/campaign \
    capture=liaison:35,50,65 dest=/tmp/ep3/replays/campaign_live
timeout 900 nice -n 5 $S --summer-offscreen --audio-driver Dummy $R compare /tmp/ep3/replays/campaign_live
```

Results on the one-world pack (routes `hanami`, `liaison`, `momiji`), 2026-09-26, M1 Max shared
with seven other agents:

- Hanami, Sakura, offscreen with live captures at 15, 40 and 70 s: 0 failures, lap 1:54.039.
  118.6 s recorded in 348 KB, 172 KB per minute (raw frames and events 444 KB per minute).
  Recording costs 24.8 µs per physics tick on average; 2 of 14 227 ticks took over 1 ms (max
  1.4 ms). Replay renders against the live frames: mean absolute difference 4.7-4.8 / 255,
  2.5-2.7 % of the pixels off by more than 32 (the HUD, dust and skid marks are not replayed).
  On the v1 packs, Momiji with the Hayate headless: 109.6 s in 325 KB (174 KB per minute),
  28.1 µs per tick, 3 of 13 156 ticks over 1 ms (max 11.7 ms, on a busy machine).
- The campaign (`flows.gd -- flow=campaign speed=3 replays=…`, headless: 0 flow failures): SS1,
  the liaison and SS2 are driven on one car without a respawn and give three files, each with
  its own route, mode, campaign leg, route length and gate states: `hanami` time trial
  (finished), `liaison` (open route, 2007 m, both branch gates open, ended by the arrival),
  `momiji` time trial (finished). Each resumed save adds one short file for its leg.
- The liaison's live frames at 35 and 50 s (`capture_flow.gd`) against its replay: mean absolute
  difference 9.9-10.0 / 255, 8-10 % of the pixels off by more than 32 (the HUD road sign and
  speedometer, dust, speed lines).
