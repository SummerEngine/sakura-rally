# The AI driver (reinforcement learning)

A small neural network drives the car the way a player does: it sees the road ahead from the
car, presses steer / pedal / handbrake ten times a second, and was trained by trial and error
(PPO) on headless copies of the game's own physics.

## In the game

A Time Attack run in which the AI had the car at any point after the countdown sets no record
and no medal (`Game.ai_drove`, cleared at each countdown). Campaign stages feed the rally
classification, so the driver sits them out; liaisons and free roam are fine.

| Key | What it does |
|---|---|
| I | Auto-drive: the AI takes your car (stage, liaison, free roam; in a race as a RaceBot among the rivals, at the free driver's own speed); I again gives it back |
| G | Ghosts: every training generation in `assets/ai/generations/` joins as a labelled ghost car on a staggered grid behind you, held on the line with you through the countdown |
| V | Watch: the chase camera goes to the next ghost, then back to your car |
| O | The pixel driver ([PIXELS.md](PIXELS.md)): a network that sees only a 128x72 picture from over the hood takes your car under I's rules, its view in the corner; O again gives it back, I or O while the other drives swaps them; in a race I's RaceBot drives instead |

`scripts/ai/auto_drive.gd` (one line in `Main._ready`) does this. Ghosts are on no collision
layer, so they pass through your car and a race's rivals; they hit the rigid world (trees,
rails) but leave the soft course alone (group `ghost_car`: tape, cones, gates and spectators
stay yours), park at the end of an open road and come back on the grid of every new run. A
driven car that stays off the road or stuck for 2.5 s is put back on it: your car as the reset
key would, a ghost on its own road (a RaceBot rescues itself, see Racing). A car standing still
for 1 s gets full throttle (the network still steers) until 15 km/h:
the likeliest action at a standstill after a reset can be to wait. The AI drives the automatic
gearbox whatever the Gearbox setting (`Car.always_automatic`), and in free roam it keeps to the
road the car is on. Command line: `-- auto-drive`, `pixel-drive`, `ghosts`, `policy=<file>`.

## What the network sees (`scripts/ai/drive_sense.gd`, 46 numbers)

Nothing that names the track or the progress along it, so one network can drive any road:

- 9 distance rays to the drivable edge (half width + verge), −90° to +90°, up to 60 m;
- 14 centreline points 5–220 m ahead, in the car's frame, as directions;
- forward and side speed, yaw rate, wheels on the ground, wheels on loose surface;
- its own current steer, throttle, brake and handbrake.

Actions (`drive_hands.gd`): steer in 7 levels, pedal brake / none / throttle, handbrake off / on,
at 10 Hz, smoothed like a gamepad. The same two files run in training and in the game.

## Training

```sh
cd tools/rl
caffeinate -i nice -n 10 uv run --python 3.12 train.py --run gen1 --car sakura,hayate \
    --routes hanami,hanami:rev,liaison,liaison:rev --procs 4 --cars 16 --steps 6e6 --save-every 1e6
caffeinate -i nice -n 10 uv run --python 3.12 train.py --run gen2 --car sakura,hayate \
    --routes hanami,hanami:rev,liaison,liaison:rev --procs 4 --cars 16 --steps 14e6 --save-every 1e6 \
    --resume runs/gen1/ckpt/model_6000000.zip
```

- `train.py` (Stable-Baselines3 PPO, CPU) starts `--procs` headless Summer processes running
  `train_env.gd`; each drives `--cars` stripped cars (`rl_car.gd`: the real physics without
  visuals or audio) on one world, over TCP. `:rev` drives a road backwards; `--car` lists the
  cars to share out. `momiji` (both ways) is held out to test generalisation.
- Reward: 0.05 per metre of road progress, minus impact strength, minus 0.1 per unit the steering
  target moves (against sawing at the wheel); −3 and the episode ends when the car leaves the
  road, crashes hard, stalls 3 s, turns back or rolls. Starts are random along the road, ±2 m
  and ±0.2 rad. gen1 trained without the steering cost; gen2 resumes gen1 at 6M with it.
- Every `--save-every` steps: a checkpoint in `runs/<run>/ckpt/` and a game policy JSON in
  `runs/<run>/policies/` (with a test vector the game checks). `--resume` continues a run.
- Four processes use about four cores; the trainer uses two threads. On the M1 Max gen1 (6M
  decisions) took 80 minutes and gen2 (14M more) 2 h 23 min, 1,300-1,650 decisions per second.

## Checking a policy

```sh
S=/Applications/Summer.app/Contents/MacOS/Summer
timeout -k 10 600 nice -n 10 $S --headless --disable-crash-handler --fixed-fps 120 --audio-driver Dummy \
    --path . -s res://tools/rl/eval.gd -- policy=tools/rl/runs/gen1/policies/latest.json routes=hanami,momiji cars=2
timeout -k 10 900 nice -n 10 $S --headless --disable-crash-handler --audio-driver Dummy --fixed-fps 60 \
    --path . -s res://tools/rl/watch.gd -- route=hanami cycle=8
```

`eval.gd` prints `CHECK` (the GDScript network against PyTorch's logits, and the cost of one
decision) and one `EVAL` line per policy and route: laps finished, best and median time, resets
(off the road / stalled / rolled), average speed and `steer` (steering-target travel per second,
lower is calmer). It drives the likeliest action; `sample=1`
draws from the network's odds instead. `watch.gd` plays the real game hands off (title, stage,
finish) with auto-drive and ghosts on, cutting the camera between them every `cycle` seconds, and
prints the stage time, rescues and whether the result counted.

Pictures only from `--summer-offscreen` in place of `--headless`, on the agents' dev build
(docs/CONTRACTS.md), never a window: `stills=<dir>` saves a PNG before every cut and on the
results card, `--write-movie <file>.avi` records the run. Shoot all shots in one run.

## Results

The shipped driver is gen2 at 7M decisions: of every checkpoint, the fewest resets on the final
world (both cars, three starts per route), steering about four times calmer than gen1 at the same
pace, and it never drove on Momiji in training. Median stage times, resets per car, from the eval
command in the README once per car (`car=hayate` for the second column):

| Route | Sakura | Hayate |
|---|---|---|
| hanami | 96.0 s, 0 | 100.0 s, 0 |
| hanami:rev | 96.4 s, 1.3 | 98.0 s, 0 |
| momiji (held out) | 82.8 s, 0 | 86.8 s, 0 |
| momiji:rev (held out) | 84.2 s, 0 | 89.8 s, 1.0 |
| liaison | 55.2 s, 1.0 | 57.6 s, 1.0 |

For scale, the gold medals are 124.5 s on Hanami and 109.5 s on Momiji. The cars of one eval
share one world and its smashed props, so a run with more cars can differ by about a second.

Known weakness: every gen2 and gen3 checkpoint misses one corner of the liaison, 230 m before
Momiji's grid (a 31 m-radius kink it enters at about 110 km/h); gen1 takes it, sampled driving
misses it too. In the game the rescue puts the car back after 2.5 s. Training longer (gen2 to
20M) made the reversed roads faster but left the road more often, and gen3 (3M more decisions
from gen2 7M with the liaison weighted) fixed neither.

## Racing

`scripts/ai/race_bot.gd` (`RaceBot`, a `NeuralPilot`) makes the shipped driver a race opponent.
Add it to a car with `track`, `pace`, `field` (every car of the race, its own included) and a
`phase` of its own (0-11: bots decide in different physics ticks), and hand the car over
(`controlled_by_player = false`); it holds while `launch_hold` is on and drives from GO. It
reports `lane` and `rescues`, and `held` (a car ahead made it lift or brake). In a race the I
key gives the player's car a RaceBot too, among the rivals, with no pace limit.

**Virtual road.** The network trained on 7 m carriageways with 1.4 m verges and never saw
itself off one. A RaceBot's DriveSense (`lane_half_width` 3.5 m, `lane`) shows it that road
centred `lane` metres right of the real centre line, clamped per sample to the real
carriageway, so the rays and road points look as in training on any width. Lane room is the
real half width minus 3.5 m: ±1.5 m on the 10 m loops, none on the 7 m liaison, where a RaceBot
drives exactly as NeuralPilot does. The lane moves 1.2 m/s across and only while the car stays
within 3 m of it. The racing line swings up to about 6 m either side of the lane (the network
cuts every corner), but two bots see the same road shifted, so their lines swing alike and bots
in the two outer lanes keep apart. Training, auto-drive and ghosts leave `lane_half_width` at 0
and see the real road exactly as before (checked bit for bit on 900 random poses).

**Pace.** `pace` scales v_ref(s), the shipped driver's own speed along the route in lane 0
(`assets/ai/pace/<route>.json`, recorded on the flying laps of three solo cars). The limit at s
is pace x v_ref brought forward by braking at 4 m/s² over the next 80 m: the network brakes for
each corner at the speeds it trained at, so a car arriving slower brakes too late for the
slower corner speed pace asks for. Within 2 m/s of the limit the throttle fades out, from 1 m/s
above it the brake comes in (up to 0.8 at 5 m/s over). A pace file matches only its own road
(length, half width, first sample), so a reversed or re-widened loop runs unlimited.
`RaceBot.pace_for_lap(route, lap_s, car)` interpolates the calibration table.

**Traffic.** Every decision the other cars from 20 m behind to 60 m ahead, in road coordinates
(distance, lateral, speed, and lane: a bot's intended lane, anyone else's position):

- brake assist on the car in its path (within 2 m laterally now or at the time to collision,
  counting its own move towards a new lane): off the throttle inside 2 m + 0.35 s of its speed
  or 1.5 s from it, braking at 1.0 s or when matching its speed takes more than 3 m/s²;
- a slower car ahead in its lane is passed on the side away from that car's lane (left of a car
  on the centre line) when that side is free, sticking to the side chosen; back home to lane 0
  once it is clear;
- a faster car behind gets room: this car moves to the other side from the one the passer took,
  or to the side it is on while the passer is straight behind (which is the side a passer
  leaves it);
- the lane never moves towards a car alongside.

**Rescue.** As AutoDrive's: 2.5 s more than 3 m past the verge, rolled, or under 3 m/s of
progress (not while a car ahead holds it up, so a bot never fights the grid). It goes back on its
own road 4 m behind, then further back 6 m at a time or into another lane, at least 8 m from
every car and out of the way of cars coming up behind (2 s at their speed). The car's own reset
is off while a RaceBot drives (it would ask the player's session); removing the RaceBot restores
it and releases the inputs.

**Calibration and checks.** `tools/rl/race_probe.gd` (usage in its header) records v_ref
(`mode=record`), calibrates pace against lap time (`mode=calibrate`, both cars, pace 0.5-1.0)
and races the race mode's grid (`route=hanami runs=3`). On the 10 m loops the flying lap runs
(sakura / hayate, s):

| pace | hanami | momiji |
|---|---|---|
| 0.60 | 152.4 / 153.6 | 133.5 / 134.6 |
| 0.70 | 131.4 / 132.3 | 115.0 / 116.0 |
| 0.80 | 115.9 / 116.8 | 101.2 / 102.2 |
| 0.90 | 104.6 / 105.5 | 90.9 / 91.9 |
| 1.00 | 96.7 / 98.8 | 83.7 / 85.5 |

which covers gold x 0.9-1.3 (hanami 112-162 s, momiji 99-142 s) with no rescue. Three 2-lap
races per loop (six rivals plus a bot at gold x 1.05, contacts on): 42/42 finished, no flip,
1 rescue in 6 races (a car stopped against the barriers after a 6.4 m/s hit), 19 overtakes a
race, 5-6 racing contacts a race, all but three under 1.3 m/s of speed change. Flying laps are
0.2 s from the calibration (median), 39 of 42 within 2 s (the others, up to 3.5 s, stuck behind
a car 3 % slower); lap 1 from the back of the grid loses up to 14 s in traffic. A decision costs
about 0.9 ms of network plus 0.08 ms of racing, about 0.6 ms a physics tick for seven bots on
seven phases.

## Shipping

Copy the chosen policy to `assets/ai/driver.json` (auto-drive and `NeuralPilot`'s default) and
a few milestones to `assets/ai/generations/NN_<steps>.json` (the ghosts, oldest first). `train.py`
also saves the untrained network (`<run>_0.json`) at the start of a fresh run. The ghosts now:
untrained and 100k steps from `demo` (the gen1 recipe run again from scratch, saved every 100k
steps: gen1 saved only every 1M, by which time it already drove), gen1 at 1M, 3M and 6M, and the
shipped driver (gen2 7M).
The default export filter (all resources) packs these `.json` files: a data pack exported that
way drove hanami from the pack alone with the driver and all ghosts. The maps' `map.bin` files are
not resources and need `include_filter="*.bin"` in the preset, or an exported game has no world.

## The video

`tools/rl/render_film.sh` makes "How the AI learned to drive", a narrated vertical video for
Shorts (1080x1920, 60 fps, about 1.5 min), once per voice in `tools/rl/film.json`
(`EXPORT=~/Projects/sakura-rally/export ELEVENLABS_API_KEY=... tools/rl/render_film.sh` writes
`rl_explainer_<voice>.mp4` and a contact sheet of each there). The story: its very first try and
the same AI 80 minutes later; what it gets (46 numbers ten times a second: the rays, the road
points, the car) and the network that turns them into a move; the score (+1 every 20 m, -3 for a
crash or leaving the road) and how the odds of the moves that scored more grow; 64 cars at once
and the learning curve; the corner at 3 and at 31 minutes; 45 of 64 finishing after 80 minutes;
61 of 64 on Momiji, a road it never practised on; and the keys to try it in the game.

1. `tools/rl/swarm.gd` records the practice, headless: per generation 64 cars leave Hanami's start
   line together and drive as in training (options sampled from the policy, a run ending by the
   training rules: off the road, a crash, stalled, the wrong way; a finisher drives on 4 s so it
   crosses the line at speed), every run a replay file in the player's format
   (`scripts/game/replay_writer.gd`, so `tools/replay/review.gd` reads it).
2. `tools/rl/narrate.py` voices `film.json`'s lines with ElevenLabs text-to-speech (each voice's
   id, model and settings are in the file; neighbouring lines go along so the reading flows),
   trims them, times every word with faster-whisper (matched back to the script's words) and lays
   the edit out; it voices a line again only when its text, its neighbours or the voice change.
3. `tools/rl/film.gd` plays the replays back under Movie Maker, offscreen and muted, under the
   render lock, every shot as long as the longest voice keeps it on screen. Every camera is worked
   out from the replays before its shot plays; for the chased car it also logs the 46 numbers its
   network got every frame (`DriveSense.observe` on the replayed car). It prints each shot's
   camera motion, nearest car size and cars in frame, and runs headless for a flow check (see its
   header); a render whose window macOS reports covered still records every frame.
4. `tools/rl/cut_film.py` lays the shots out on the voice's times and draws over the footage frame
   by frame: captions word by word; each shot's practice time and how many of 64 got round or
   finished (from the recording); the 46 numbers; the network running on them (the shipped
   driver's weights, then the untrained generation's for "guessing"); the score, the odds, the
   learning loop and the learning curve (`runs/gen1/progress.csv`); the end card. The narration
   sits over the drive theme, which ducks under the voice; -14 LUFS. `--preview` saves stills of
   the look without encoding.

Adding a voice is a new entry in `film.json` (an ElevenLabs voice id) and a `--no-record` run; a
new line, shot or beat is an edit there (beats name the word they start on). Recording takes about
5 min, the render about 6, each cut about 4.
