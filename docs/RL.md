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
| I | Auto-drive: the AI takes your car (stage, liaison, free roam); I again gives it back |
| G | Ghosts: every training generation in `assets/ai/generations/` joins as a labelled ghost car on a staggered grid behind you, held on the line with you through the countdown |
| V | Watch: the chase camera goes to the next ghost, then back to your car |

`scripts/ai/auto_drive.gd` (one line in `Main._ready`) does this. Cars never collide with each
other, so ghosts pass through your car; they hit the rigid world (trees, rails) but leave the
soft course alone (group `ghost_car`: tape, cones, gates and spectators stay yours), park at the
end of an open road and come back on the grid of every new run. A driven car that stays off the
road or stuck for 2.5 s is put back on it: your car as the reset key would, a ghost on its own
road. A car standing still for 1 s gets full throttle (the network still steers) until 15 km/h:
the likeliest action at a standstill after a reset can be to wait. The AI drives the automatic
gearbox whatever the Gearbox setting (`Car.always_automatic`), and in free roam it keeps to the
road the car is on. Command line: `-- auto-drive`, `ghosts`, `policy=<file>`.

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

Pictures only from `--summer-offscreen` in place of `--headless`, never a window: `stills=<dir>`
saves a PNG before every cut and on the results card, `--write-movie <file>.avi` records the
run. Rendered runs take focus from a fullscreen app for now (docs/CONTRACTS.md), so shoot all
shots in one run.

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

`tools/rl/render_film.sh` films how it learned, in the real game, offscreen and muted, and cuts
`/tmp/sakura_film/sakura_ai_learns.mp4` (about 25 min in all under `nice`; `--cut-only` recuts):
every generation driven from the same standstill into the same Hanami corners, the learning
curve (`tools/rl/plot_training.py`, which also plots any run to a PNG), the shipped driver with
its rays and road points drawn over the road, one race of every generation as ghosts, and Momiji.
`tools/rl/film.gd` shoots it and logs what each car did (where it left the road, how fast), and
`cut_film.py` captions each clip from that log only.
