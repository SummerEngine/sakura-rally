# Sakura Rally: training the AI driver from pixels

Branch `rl-pixels` (worktree `~/Projects/sakura-rally-wt/rl-pixels`, on `ep3-rl`), tools in
`tools/rl_pixels/`. Sections 1-6 are the measured plan (written before any training, hood camera
at 1.34 m). §7 is what was built and trained from it, 2026-09-27/28.
Machine: M1 Max (8P+2E cores, 64 GB, macOS 27.2), dev build Summer 0.5.68 + PR #397, Metal Forward+.
All renders ran offscreen under `/usr/bin/lockf -k /tmp/sakura-render.lock`.

## 1. Recommendation

**What the network sees.** One RGB **128x72** frame from a hood camera (1.34 m up, 0.45 m forward,
pitched 8° down, 90° FOV). Beside the frame go **21 floats**: DriveSense's non-geometric part
(forward and side speed, yaw rate, wheels on the ground and on loose ground: 5; the current
steer/throttle/brake/handbrake: 4) and the previous action as one-hot (7+3+2 = 12). Drop the 9 edge
rays and the 14 centre-line points: the picture has to replace them. That is the "from the picture"
part. Use **no frame stack**, because the speed and yaw-rate floats carry the motion (Linesight does
the same: one 160x120 grey frame plus floats).
- Why 128x72: a 128x72 frame costs the same to render as 64x64 (the table below shows that
  resolution does not change the render cost). The CNN costs about half as much as at 160x120.
  The wide frame keeps the road edges and corners 100+ m ahead a few pixels wide.
- Colour: keep RGB. Tarmac, gravel, grass and autumn verges differ mainly in hue (see the samples).

**How it is rendered.**
- Every car in a training process gets its own SubViewport and Camera3D in the process's one world.
  All car viewports draw into one atlas SubViewport. The render loop is off
  (`RenderingServer.render_loop_enabled = false`).
- Each decision: set every viewport to `UPDATE_ONCE`, call `RenderingServer.force_draw(false)`
  once, then read the whole atlas with one `get_image()`.
- Physics: `--fixed-fps 10` runs all 12 physics ticks of a decision in one main-loop iteration
  (`max_physics_steps_per_frame` is already 12). DriveHands.apply moves into a `_physics_process`
  node.
- Look: the game world at the **low preset with sun shadows randomly on or off per process**
  (`low` / `lean` in the table), no ink quad, no AA. Props stay: they are the scenery the driver
  will see in the game.
- Domain randomisation: a season-weight vector per process, re-drawn every few hundred
  decisions; random ±4 px shift of the frame in the trainer (DrQ/RAD); mild colour jitter.

**Algorithm.** Keep SB3 PPO (the existing export and eval tooling) with three changes:
1. **Asymmetric actor-critic** (Pinto et al. 2017, https://arxiv.org/abs/1710.06542). The critic
   keeps the 46 DriveSense floats. Only the actor sees pixels and the 21 floats. Pixel PPO is weak
   because it has to learn the value function from pixels; here it does not.
2. **Random-shift augmentation** on the actor's frames.
3. **A warm start by imitation of the shipped gen2 driver (DAgger)**, before any RL. The
   privileged teacher labels every rendered frame for free, because the same process computes
   DriveSense. This is the "Learning by Cheating" recipe (Chen et al. 2019,
   https://arxiv.org/abs/1912.12294).

- Encoder: the Nature CNN (0.74-2.2 M parameters). The trainer runs on **PyTorch MPS**; the CPU is
  20-40x slower, so MPS is required.
- Fallback if PPO stalls: a Linesight-style IQN or a DrQ-v2-style off-policy learner with replay.
  It reuses each expensive frame many times, but means rewriting train.py.

**Expected throughput** (measured, 16 cars per process, 64x64 atlas; 128x72 costs within 5%):

| Setup | Car-decisions/s |
|---|---|
| **Now (geometry, headless, 4 procs; RL.md)** | **1,090-1,650** |
| lean look, 4 procs | 728 |
| lean look, 6 procs | 1,102 |
| bare world (no props), 4 procs | 990 |
| bare world (no props), 6 procs | 1,287 |
| Planning figure, game look, 4-6 procs | 700-1,000 |

**Expected wall-clock to gen1-level driving** (gen1 = 6M decisions, 80 min, ~95 s on Hanami):
- **From scratch** (asymmetric PPO + augmentation), assuming **3x** gen1's samples = **18M
  decisions** (range 2-5x; basis in §3). Each 1M decisions takes about 1,000-1,400 s of collection
  plus about 220 s of MPS update (5 epochs at 23k samples/s). That gives **≈ 6-8 h**, holding the
  GPU and the render lock throughout.
- **With the DAgger warm start**: about 3 rounds of 0.3-1M teacher-labelled frames (~20 min of
  rendering each, about 5 min of supervised training), then 3-6M PPO decisions to fine-tune. That
  gives **≈ 2.5-3.5 h** [INFERENCE: no source gives this exact budget; the imitation part rests on
  the teacher driving at ~96 s].
- Plain pixel PPO without the critic or augmentation tricks would need ≥10x (60M+ decisions,
  about 20 h+). Not recommended.

**What changes**
- `tools/rl/train_env.gd`: an `obs=pixels` option.
  - It builds the eyes (a new shared class, see below) and runs `--fixed-fps 10` with the render
    loop off and hands applied per tick in `_physics_process`.
  - The hello reports the image shape. The step/reset reply appends `cars x H x W x 3` u8 after the
    float block.
  - The float block keeps all 46 DriveSense floats, for the critic and the teacher.
  - Gates stay as the game sets them. Pixels can see a closed gate, but at an open fork nothing tells
    the network which branch is the route (see risks).
  - Seasons are drawn per process.
- `tools/rl/sakura_env.py`: the observation becomes `spaces.Dict(image=Box(0,255,(3,72,128),u8),
  vec=Box(21), priv=Box(46))`. Workers launch with the dev build and `--summer-offscreen`, not
  `--headless`, and under the render lock.
- `tools/rl/train.py`: a custom `MultiInputPolicy`. The actor gets CNN(image)+vec, the critic an
  MLP(priv). It adds random-shift augmentation, `device="mps"`, a `--teacher` DAgger phase, and
  exports the CNN weights.
- Game runtime: `NeuralPilot` gets a pixel mode with a `DriveEyes` SubViewport per AI car at
  10 Hz. Inference runs **on the GPU** in a compute shader (RenderingDevice) that reads the
  ViewportTexture directly and writes 12 logits to a small buffer, read back asynchronously
  (`RenderingDevice.texture_get_data_async` / `buffer_get_data_async`, present in 4.7.2).
  - A GDScript CNN is not viable: the Nature CNN at 128x72x3 is about 10.5 M multiply-adds per
    decision, against the ~24 k (46→128→128→12) of today's MLP [INFERENCE from the layer shapes].
  - A synchronous `get_image()` in the game would stall the GPU every decision.

## 2. Measured benchmark

Harness: `tools/rl_pixels/pixel_bench.gd`, driven by `tools/rl_pixels/run_bench.sh
[grid|scale|res|renderer|samples]`. It uses stripped cars (`tools/rl/rl_car.gd`) with
pure-pursuit steering and 12 ticks per decision (every line reports `ticks_per_dec=12.0`). It
reports step, draw and readback ms per decision and car-decisions/s. Logs are in
`/tmp/pixel_rl/bench/*.log`, machine load in `/tmp/pixel_rl/bench/load.txt`.
```
D=~/opt/summer-dev/SummerDev.app/Contents/MacOS/Summer
/usr/bin/lockf -k /tmp/sakura-render.lock timeout -k 10 1200 nice -n 10 $D --summer-offscreen --audio-driver Dummy \
  --disable-crash-handler --fixed-fps 10 --path . -s res://tools/rl_pixels/pixel_bench.gd -- configs="lean/128x72/16/atlas" decisions=30
```
Looks:
- **full**: the high preset in the car view (4-split 320 m sun shadows, glow, MSAA 4x, ink).
- **low**: the low preset (2 splits, 160 m, FXAA, ink).
- **lean**: low without shadows, ink or AA.
- **bare**: lean without props and sky particles.
- **road**: road meshes only, hood view.
- **top**: road only, orthographic top-down.

Machine load: the 1-minute load average was 11-18 during the grid and scale steps (other agents'
work, Codex, a Python job). During the Mobile-renderer step the 5-minute load was ~64 (1-minute
53-160); during the CNN step it was 150 at the start.

**One process, 16 cars, atlas readback, Forward+ (car-decisions/s):**

| Look | 64x64 | 96x96 | 128x72 | 160x120 | Render ms per car-decision |
|---|---|---|---|---|---|
| none (physics only) | 403 | | | | 0 |
| full | 116 | | 106 | | 6.2-7.0 |
| low | 165 | 164 | 157 | 160 | 3.6-3.9 |
| lean | 205 | 207 | 196 | 195 | 2.3-2.7 |
| bare | 285 | 284 | 279 | 277 | 1.1-1.3 |
| road | 339 | | 351 | | 0.5 |
| top | 353 | | 353 | | 0.5 |

**Cars per process (64x64, readback per car):**

| Look | N=1 | 4 | 16 | 32 |
|---|---|---|---|---|
| low | 59 | 109 | 153 | 176 |
| lean | 60 | 128 | 197 | 219 |
| none | 106 | | 403 | 463 |

- Physics costs ~2.1-2.5 ms per car-decision. Rendering a 16-car batch costs another 2.4 ms per
  car (lean) or 3.6 ms (low).
- A single viewport costs 5-6 ms, because each decision pays a full GPU round trip.
- Readback: one atlas `get_image()` beats 16 per-viewport calls by only ~7%. The time is the wait
  for the GPU, not the copy.

**Processes at once (16 cars each, 64x64 atlas, 120 decisions; summed car-decisions/s):**

| Processes | none | bare | lean |
|---|---|---|---|
| 1 | 421 | 284 | 198 |
| 2 | 840 | 588 | 394 |
| 4 | 1,650 | 990 (readback 15.7 → 23 ms) | 728 (26.6 → 33 ms) |
| 6 | 1,324 (2 procs CPU-starved) | 1,287 | 1,102 |

- Two processes scale perfectly. At four, the GPU queue starts to be shared: rendered processes
  lose 8-13% each.
- At six the CPU (8 P-cores, plus others' load) becomes the limit.
- In short, the render is neither purely GPU-bound nor CPU-bound: each viewport costs about 0.4 ms
  of CPU submit (`vp_cpu_ms` 6.7 ms / 16) plus GPU time.

**Mobile renderer** (`--rendering-method mobile`, 64x64, 16 cars, atlas):

| Look | Car-decisions/s | vs Forward+ |
|---|---|---|
| lean | 229 | +12% |
| bare | 310 | +9% |
| low | 182 | +10% |
| full | 118 | +2% |
| lean, 32 cars | 262 | |

Faster, but the game renders with Forward+. A policy trained on Mobile frames would face a small
domain gap in the game, so stay on Forward+.

**CNN (PyTorch 2.14, `tools/rl_pixels/cnn_bench.py`, 2 CPU threads, samples/s).** Inference is at
batch 64; training (forward, backward, Adam) at batch 1024.

| Input | Encoder | Params | MPS infer | MPS train | CPU infer | CPU train |
|---|---|---|---|---|---|---|
| 64x64 grey x4 | small | 0.23M | 15,154 | 34,843 | 946 | 1,102 |
| 64x64 grey x4 | nature | 0.74M | 19,884 | 45,759 | 1,672 | 1,663 |
| 64x64 grey x4 | impala | 0.69M | 10,055 | 8,165 | 825 | 248 |
| 96x96 grey x4 | nature | 2.31M | 18,173 | 22,571 | 1,330 | 899 |
| 128x72 grey x4 | nature | 2.18M | 12,938 | 23,237 | 1,277 | 859 |
| 128x72 grey x4 | impala | 1.35M | 6,425 | 3,496 | 329 | 128 |
| 160x120 grey x4 | nature | 5.98M | 12,424 | 11,250 | 817 | 435 |
| 160x120 grey x4 | impala | 2.63M | 5,925 | 1,045 | 207 | 65 |

- PPO at 1,000 decisions/s with 5 epochs needs 5,000 train samples/s. That is 22% of MPS
  time with Nature at 128x72, and impossible on the CPU.
- IMPALA on MPS is 3-7x slower than Nature. Keep it in reserve for when generalisation needs it.
- 64x64 RGB (9 channels) and grey x4 cost about the same.

**Cheaper alternatives, measured:**
- road-only perspective and top-down renders: 0.5 ms per car.
- the stripped world (bare): 1.1-1.3 ms per car.
- They buy 1.4-1.8x throughput, but the network never sees the game's scenery and would need the
  same simplified render in the game. That is possible (the AI's eyes are ours in the game too),
  but it drifts from "drives from the picture".
- Top-down road-only is a segmentation map of the geometry already available. It adds nothing
  over DriveSense.
- A depth render was not measured.

**Sample observations** (what the network would see; committed on the branch in
`tools/rl_pixels/samples/`, `.gdignore`d):
- `tools/rl_pixels/samples/sheet_64x64_x4.png`, 4x nearest-neighbour. Rows: Hanami lean, Hanami
  bare, Momiji lean, Momiji bare, Hanami forced to the autumn look.
- `tools/rl_pixels/samples/sheet_lean128x72_momiji_x4.png`, `sheet_top64_hanami_x4.png`.
- Native-size frames: `hanami_lean_128x72.png`, `momiji_lean_128x72.png`, `hanami_lean_64x64.png`,
  `hanami_low_64x64.png`, `momiji_bare_64x64.png`.
- Every rendered sample, including the Mobile renderer, the atlases and the full look:
  `/tmp/pixel_rl/bench/samples/{hanami,momiji,hanami_autumn,mobile}/`.

## 3. Prior art

Full notes with every link are in [PIXELS_PRIOR_ART.md](PIXELS_PRIOR_ART.md).
- **Linesight** (Trackmania, https://github.com/Linesight-RL/linesight, `config_files/config.py`,
  `trackmania_rl/agents/iqn.py`):
  - Input: **160x120 grey, one frame, no stack**, captured through TMInterface from a 640x480
    window.
  - Beside it, **184 floats**: 5 previous actions, wheel contact/slide/damper, gear/rpm, surface
    one-hot, car-frame velocity, angular velocity and up vector, **40 reference-line points out to
    400 m**, and distance to finish. It adds pixels to the geometry; it does not replace it.
  - Algorithm: **IQN** with dueling heads, 3-step returns, γ→1 over a 7 s horizon, batch 512, each
    transition reused 32 times. 12 actions at 20 Hz.
  - Speed and hardware: ~10x game speed, render-bound; 2-4 instances on a Ryzen 5700G + RTX
    4070 Ti.
  - Progress: 1M steps to finish regularly, 3-5M to near-top. 2 h to finish, 8 h to beat gold,
    40-70 h to beat the world records.
- **Yosh** (https://www.youtube.com/watch?v=Dw3BZ6O_8LY and later videos): **no images**. He feeds
  state numbers (speed, centre-line offset, next 3 corners, orientation, wheel contact) at
  10-20 Hz; runs of 35-40 h. The algorithm is not stated (UNVERIFIED).
- **GT Sophy** (Nature 2022): state, not pixels. 3x60 course points over 6 s, QR-SAC, 10 Hz.
- **WRC6 rally, Jaritz et al. 2018** (https://arxiv.org/abs/1807.02371):
  - Input: **84x84 RGB plus speed plus the previous action**, into an LSTM.
  - A3C with 32 actions including handbrake.
  - **140M steps** on 9 game instances; it generalises to unseen tracks.
- **CarRacing from pixels**: 96x96 RGB (usually grey 64-96 px, stack 2-4). PPO needs 4-10M steps
  to approach 900; PPO-LSTM scores 880 at 4M; World Models 906.
- **Pixel vs state sample efficiency on DMC** (CURL https://arxiv.org/abs/2004.04136, RAD
  https://arxiv.org/abs/2004.14990, DrQ https://arxiv.org/abs/2004.13649, DreamerV3
  https://arxiv.org/abs/2301.04104, SAC-AE https://arxiv.org/abs/1910.01741):
  - Pixel SAC without augmentation reaches a median of 188 at 500k steps, against 923 for state
    SAC: more than 5-10x worse on samples.
  - RAD, DrQ and CURL at 500k match state SAC: **~1x**.
  - DreamerV3 on pixels at 1M matches proprioception at 500k: **~2x**.
  - DrQ-v2 runs at 96 FPS on one V100 (1M steps ≈ 2.9 h). PPO is the weakest pixel learner in the
    DreamerV3 tables.
- **What image drivers get besides pixels:**
  - speed and previous actions: Linesight, WRC6, TMRL, Donkey (20 past commands);
  - speed and steering angle: Wayve's "Learning to drive in a day";
  - road geometry: Linesight;
  - nothing: DeepRacer (160x120 grey, simple lanes), TORCS A3C.
- **Augmentation and randomisation**:
  - Random shift ±4 px gives the largest gain (RAD, DrQ).
  - Random convolution or overlay handles colour and background shifts (SVEA
    https://arxiv.org/abs/2107.00644: walker, colour_hard, 520 → 760).
  - Procgen needs thousands of levels to close the generalisation gap.
- **Multiplier chosen, 3x (range 2-5x).** Three things put us between DrQ/RAD (~1x, off-policy
  with augmentation) and plain pixel PPO (≥10x):
  - PPO is on-policy and weaker (DreamerV3 tables);
  - the asymmetric critic removes most of the value-learning handicap;
  - Linesight's hybrid run needs about as many steps as gen1.

## 4. Risks and design

- **Route ambiguity at forks.** The one world has branches, gates and the liaison joins.
  DriveSense follows the route's centre line; pixels show every road.
  - In training: keep the gates as each route has them. train_env opens them all today.
  - At any open fork, add a small route hint, e.g. a junction flag and the route bearing 40 m ahead
    for the next 3 s. Linesight and GT Sophy both feed geometry for this reason.
- **Seasons are per process, not per car.**
  - `MapWorld._process` and `SkyRig` follow the root viewport's camera. The atmosphere, sun, fog,
    grade and sky particles are process-global. Terrain and road read the season grid per pixel,
    so the ground changes colour correctly in every car's view.
  - The root has no 3D camera in training, so the look freezes at the build-time season. Draw it
    per process and re-draw during the run: this doubles as domain randomisation.
  - Momiji's autumn has to be in the training distribution. A policy trained on Hanami spring alone
    would face orange trees, low sun and another sky. The forced-autumn sample row shows the
    difference. Momiji stays held out as a route; its look does not.
- **Game look vs a simplified training render.**
  - The AI's camera in the game is ours to configure, so ink, AA and glow can be left out of its
    view (the ink quad is in the world: put it on its own visual layer and cull it).
  - **Directional sun shadows cannot be turned off per viewport**: every SubViewport renders the
    sun's cascades. The in-game AI view will have shadows whenever the player's preset does.
  - Hence: randomise shadows on/off in training (low/lean), and expect higher-preset AI views to
    cost ~2x (full: 6.2 ms vs low: 3.6 ms per camera in a batch).
- **Petals and particles.** The sky particles (SkyRig) follow the root camera and appear in all car
  views near it only. Randomise their amount per process, or leave them off in training and
  randomise overlays in the trainer.
- **In-game cost with ghosts.**
  - Each AI car needs its own camera at 10 Hz. With the 6 generation ghosts and cameras staggered
    one per 60 fps frame, that is about 1 AI view per frame: ~0.4-0.6 ms CPU submit (measured
    `vp_cpu_ms`/N) plus GPU time [INFERENCE: Metal returned 0 for
    `viewport_get_measured_render_time_gpu`, so the GPU share was not measured].
  - A synchronous readback would stall the frame, so use async readback or GPU inference (§1).
  - The alternative: ghosts keep the geometry policy and only the showcase "AI from pixels" car
    uses pixels.
- **Render lock and Vel.**
  - Pixel training is a render: the dev build, `--summer-offscreen`, the render lock held for the
    whole run (hours). The lead's Movie Maker takes would wait behind it.
  - Schedule training runs; do not interleave with takes. The dev build's window is transparent and
    click-through (PR #397); the installed Summer must never be used for it.
- **Credit and reward** stay as today (progress along the route). Pixels only replace the policy's
  input.
- **Sample-efficiency uncertainty.** The 3x figure is a planning assumption. Milestone 4 measures
  it against gen1's own learning curve before a long run.

## 5. Implementation plan

1. **M0 DriveEyes (0.5 day).**
   - `scripts/ai/drive_eyes.gd` owns a car's SubViewport and camera (the hood pose, FOV, cull mask
     without the ink layer) and an optional shared atlas.
   - `render()` requests UPDATE_ONCE; `frame()` returns uint8 RGB. It is used by train_env and the
     game alike (as DriveSense and DriveHands are).
   - Move the PostFX ink quad to its own visual layer.
   - Done when: `pixel_bench.gd` numbers are reproduced through DriveEyes.
2. **M1 train_env pixels (1 day).**
   - `obs=pixels`, `--fixed-fps 10` with one iteration per decision, hands in `_physics_process`,
     the atlas readback, the image block in the protocol, and per-process season and shadow draws.
   - Done when: 16 cars run at ≥190 car-decisions/s per process at 128x72, and a Python client
     receives frames.
3. **M2 sakura_env / train.py (1 day).**
   - Dict observation, the asymmetric policy (CNN actor, privileged MLP critic), random shift, MPS,
     launch through the dev build and lockf, and export of the CNN weights to JSON or binary.
   - Done when: a 200k-decision smoke run learns (reward rising).
4. **M3 DAgger warm start (0.5-1 day).**
   - The gen2 7M teacher labels rendered frames; β-mixed rollouts over 3 rounds.
   - Done when: the student finishes Hanami offline in eval (`eval.gd` pixel mode) within 10% of the
     teacher's time.
5. **M4 Sample-efficiency check (0.5 day, ~1.5 h run).**
   - 1M-3M decisions from scratch (no DAgger), plotted with `plot_training.py` against gen1's first
     3M. This fixes the multiplier and decides between PPO and the IQN/DrQ fallback.
6. **M5 Full run (6-8 h from scratch, or ~3 h fine-tuning after M3).**
   - Eval Hanami, Hanami reversed, the liaison, and Momiji (held out) in both directions, for both
     cars.
   - Target: gen1-level times (~95 s Hanami) and resets ≤ gen1's.
7. **M6 Game runtime (2-3 days).**
   - A pixel mode for NeuralPilot: DriveEyes at 10 Hz staggered across frames, and a compute-shader
     CNN reading the ViewportTexture with async readback of the logits.
   - Profile with the 6 ghosts on the high and low presets.
   - Check the `CHECK` parity between GPU logits and torch logits, as eval.gd does today.

## 6. Tool lessons (for AGENTS.md)

- **Parked cars cost full physics.** A stripped `Car` costs ~150 µs per tick whether it drives or
  stands, so 64 spawned cars cost 64 cars' physics. Disable unused ones with
  `process_mode = PROCESS_MODE_DISABLED`. My first "none" run looked paced to real time; it was 64
  parked cars.
- **Render only on demand.** Offscreen pixels on demand: `RenderingServer.render_loop_enabled =
  false`, set each SubViewport's `RenderingServer.viewport_set_update_mode(rid, UPDATE_ONCE)`,
  then `RenderingServer.force_draw(false)`. Nothing draws between those calls. Set
  `root.disable_3d = true` so the 1600x900 root adds nothing.
- **One iteration per decision.** `--fixed-fps 10` with `max_physics_steps_per_frame=12` runs 12
  physics ticks per main-loop iteration: one iteration per 10 Hz decision (measured
  `ticks_per_dec=12.0`).
- **SubViewport cost is per viewport, not per pixel.** 64x64 up to 160x120 cost the same. Directional
  (sun) shadows are rendered again for every SubViewport camera.
- **No GPU timings on Metal.** `RenderingServer.viewport_get_measured_render_time_gpu()` returns 0
  on Metal (M1 Max, 0.5.68 dev build); `..._cpu()` works.
- **Mobile renderer.** `--rendering-method mobile` works with `--summer-offscreen` and renders the
  car views 9-12% faster. An invalid value aborts with "Unknown rendering method".
- **PyTorch on this Mac.** PyTorch 2.14 MPS works through `uv run --python 3.12`. Small CNNs train
  20-40x faster on MPS than on 2 CPU threads.

## Unverified

- The GPU share of the render cost (Metal reports 0).
- The 3x sample multiplier and the DAgger budget (planning assumptions; M4 measures them).
- The in-game cost with ghosts (inferred from `vp_cpu_ms`, not measured in the game).
- The depth render.
- The compute-shader inference cost.
- The absolute numbers were taken on a loaded machine (other agents' jobs; load 11-18 in the
  render steps, ~150 in the CNN step). The CPU CNN figures in particular are pessimistic.

## 7. Built and trained (2026-09-27/28)

**What differs from the plan.**
- The camera sits **3 m up** (10° down, 60° vertical FOV, about 92° across), not on the hood at
  1.34 m with a 90° vertical FOV: from the hood the road beyond ~40 m was a few flat pixels, and the
  bends 50-150 m ahead are what the driver has to read.
- Imitation first (DAgger, supervised), PPO after it. The critic is not learned from scratch: it
  starts as the teacher's value network, with the teacher's reward scaling.
- Branch gates: closed on the stage loops (as a timed stage has them), **open in liaison workers**.
  Both gates stand on the liaison road (s 75 and 1740 m), and the game opens them in liaison mode.

**Pieces.**
- `scripts/ai/drive_eyes.gd` (DriveEyes): the camera, a SubViewport updated only when asked.
- `tools/rl_pixels/pixel_env.gd`: extends `tools/rl/train_env.gd` (which gained the hooks `_build`,
  `_hello`, `_serve`, `_drive`). Every reply renders all cars at once into one atlas (render loop
  off, `force_draw`, one `get_image()`) and appends it to train_env's float block. A random season
  look every 600 decisions (spring, autumn, summer or a blend); `look=lean|shade` per worker. Eval
  mode drives laps from the start line by eval.gd's rules and can record them as replays.
- `tools/rl_pixels/pixel_env.py`: the workers as one batch; `tools/rl/sakura_env.py`'s
  `start_workers` launches both kinds.
- `tools/rl_pixels/train_pixels.py`: `imitate` (DAgger), `ppo`, `film`.
- `tools/rl_pixels/train.sh`: holds the render lock, keeps the Mac awake, resumes a run that
  crashed from its latest checkpoint.
- `tools/rl_pixels/film_render.gd`: films a recorded lap from its stored chase camera, one
  `force_draw` per frame (a covered or sleeping screen cannot hand back a stale frame).

**The student.** The Nature CNN on the 128x72 RGB frame, then 512 units, joined by 21 floats
(forward and side speed, yaw rate, wheels on the ground and on loose ground, the four controls
held, the last choice one-hot) into 256 units and 12 logits (DriveHands' 7+3+2). No track
geometry reaches it. Checkpoints: `tools/rl/runs/<run>/ckpt/actor_<steps>.pt` (torch).

**Imitation (`imitate`).** The teacher is gen2 7M (the shipped `assets/ai/driver.json`, SB3
checkpoint `tools/rl/runs/gen2/ckpt/model_7000000.zip`). It labels every rendered frame from the
same car's DriveSense vector. Its share of the driving falls from 1 to 0 over the first 300k
decisions; after that the student drives (a quarter of the cars sample its odds, the rest take its
likeliest choice) and the teacher labels the states the student gets itself into. Cross-entropy
against the teacher's odds, from a replay of the latest 400k frames, 2 batches of 256 per decision
of all cars, frames shifted up to 4 px and jittered in brightness, contrast, saturation and hue
(±60°).

**PPO (`ppo`).** From the imitation's last checkpoint. Rollouts of 128 decisions per car, 4 epochs
of 1024 (stopping early past 1.5x target KL 0.02), actor lr 1e-4, critic lr 3e-4, γ 0.99, λ 0.95,
clip 0.2, entropy 0.01. The critic sees DriveSense (asymmetric actor-critic). The teacher's odds
stay in the loss as an augmented imitation term, weight 0.5 falling to 0.1 over 2M decisions. A
time cut bootstraps from the critic (the car drives on).

**Eval.** Every 250k (imitate) or 500k (PPO) decisions, 2 cars each on Hanami and Momiji, both
ways, from the start line: Hanami in spring, Momiji in autumn, shadows on. Momiji is never
trained on. Rules as `tools/rl/eval.gd` (resets off the road, stalled or rolled, argmax, NeuralPilot's
stuck fallback), rows in `eval.csv`. The teacher through this pixel eval: Hanami 96.3 s, Hanami
reversed 95.6 s, Momiji 81.7 s, Momiji reversed 83.2 s. eval.gd gave it 96.0 / 95.6 / 81.5 /
84.6 s, so the two evals agree.

**Throughput.**
- 1 worker, 16 cars, shade look: 166 car-decisions/s (the benchmark's 157).
- Imitation, 6 workers (3 lean, 3 shade) with the MPS trainer learning while they drive: 430-480
  car-decisions/s. PPO: ~325 (its updates do not overlap the driving). The GPU is the limit
  (`ioreg` Device Utilization 92-94%; each worker ~40% of a core). That is below the plan's
  700-1,000 for 4-6 processes.

**Results: imitation (run `px1`).** Median time of 2 cars and resets per car, by the pixel eval.
Decisions 0-750k on Hanami only; from 750k (resumed) half the workers drove the liaison.

| Checkpoint | Hanami | Hanami rev | Momiji (held out) | Momiji rev (held out) |
|---|---|---|---|---|
| teacher (gen2 7M, geometry) | 96.9 s, 1.0 | 97.4 s, 1.5 | 81.9 s, 0 | 84.4 s, 0.5 |
| 250k | 98.0 s, 2.0 | 97.9 s, 3.0 | 96.0 s, 3.5 | 99.1 s, 5.5 |
| 500k | 96.8 s, 1.0 | 99.3 s, 3.0 | 101.4 s, 4.5 | 99.6 s, 4.5 |
| 1M | 96.6 s, 1.0 | 95.9 s, 1.5 | 98.7 s, 2.5 | 101.2 s, 6.0 |
| 1.5M | 96.3 s, 1.0 | 96.1 s, 1.5 | 97.9 s, 3.0 | 96.5 s, 4.5 |
| **2M** | **95.9 s, 0.5** | **95.8 s, 1.0** | **93.0 s, 1.0** | **101.2 s, 4.5** |
| 2.5M | 96.5 s, 1.0 | 96.1 s, 1.5 | 99.2 s, 2.0 | 102.5 s, 6.0 |
| 3M | 96.4 s, 1.0 | 99.5 s, 2.5 | 98.0 s, 3.0 | 98.6 s, 3.5 |

- On the trained stage the pixel driver matches its teacher from 250k decisions on (~20 min of
  driving): 128x72 is enough to drive Hanami at the teacher's pace with no road geometry.
- On Momiji, never trained on and never seen with its own orange trees, it finishes every run but
  is 10-20 s slower than the teacher (98-104 km/h against 113-116) and leaves the road 1-6 times
  a run. The teacher sees the road as geometry, which looks the same everywhere.
- The imitation loss sits at ~1.35-1.39 (the teacher's own entropy is part of it) from 1M on:
  more imitation does not help.

**Run.**
```
R="hanami,hanami:rev;liaison,liaison:rev"   # ';' deals route groups to the workers in turn
tools/rl_pixels/train.sh imitate --run px1 --procs 6 --steps 3e6 --beta-steps 3e5 --routes "$R" --eval-teacher
tools/rl_pixels/train.sh ppo --run px1ppo --init tools/rl/runs/px1/ckpt/latest.pt --procs 6 --steps 30e6 \
    --routes "$R" --bc 0.5 --bc-end 0.1 --bc-steps 2e6
uv run --python 3.12 tools/rl_pixels/train_pixels.py film --run px1 --ckpt tools/rl/runs/px1/ckpt/latest.pt
```
`film` records one lap of Hanami and one of Momiji, renders them at 1280x720 from a chase camera and
puts the network's frame of each moment in the corner:
`tools/rl/runs/<run>/film/<run>_<steps>_<route>.mp4`.

**Not built.** The pixel driver does not run in the game: its CNN is torch-only (M6, the compute
shader, is still to do).
