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
| G | Ghosts: every training generation in `assets/ai/generations/` joins as a labelled ghost car |
| V | Watch: the chase camera goes to the next ghost, then back to your car |

`scripts/ai/auto_drive.gd` (one line in `Main._ready`) does this. A driven car that stays off
the road or stuck for 2.5 s is put back on it, like the reset key. Command line: `-- auto-drive`,
`ghosts`, `policy=<file>`.

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
caffeinate -i nice -n 10 uv run --python 3.12 train.py --run gen1 \
    --routes hanami,hanami:rev,liaison,liaison:rev --procs 4 --cars 16 --steps 40e6
```

- `train.py` (Stable-Baselines3 PPO, CPU) starts `--procs` headless Summer processes running
  `train_env.gd`; each drives `--cars` stripped cars (`rl_car.gd`: the real physics without
  visuals or audio) on one world, over TCP. `:rev` drives a road backwards. `momiji` is held
  out to test generalisation.
- Reward: 0.05 per metre of road progress, minus impact strength; −3 and the episode ends when
  the car leaves the road, crashes hard, stalls 3 s, turns back or rolls. Starts are random
  along the road, ±2 m and ±0.2 rad.
- Every `--save-every` steps: a checkpoint in `runs/<run>/ckpt/` and a game policy JSON in
  `runs/<run>/policies/` (with a test vector the game checks). `--resume` continues a run.
- Four processes use about four cores; the trainer uses two threads.

## Checking a policy

```sh
S=/Applications/Summer.app/Contents/MacOS/Summer
timeout 600 nice -n 10 $S --headless --disable-crash-handler --fixed-fps 120 --audio-driver Dummy \
    --path . -s res://tools/rl/eval.gd -- policy=tools/rl/runs/gen1/policies/latest.json routes=hanami,momiji cars=2
timeout 900 nice -n 10 $S --headless --disable-crash-handler --audio-driver Dummy --fixed-fps 60 \
    --path . -s res://tools/rl/watch.gd -- route=hanami cycle=8
```

`eval.gd` prints `CHECK` (the GDScript network against PyTorch's logits, and the cost of one
decision) and one `EVAL` line per policy and route: laps finished, best and median time, resets,
average speed. `watch.gd` plays the real game hands off (title, stage, finish) with auto-drive
and ghosts on, cutting the camera between them every `cycle` seconds.

Pictures only from `--summer-offscreen` in place of `--headless`, never a window: `stills=<dir>`
saves a PNG before every cut and on the results card, `--write-movie <file>.avi` records the
run. Rendered runs take focus from a fullscreen app for now (docs/CONTRACTS.md), so shoot all
shots in one run.

## Shipping

Copy the chosen policy to `assets/ai/driver.json` (auto-drive and `NeuralPilot`'s default) and
a few milestones to `assets/ai/generations/NN_<steps>.json` (the ghosts, oldest first).
