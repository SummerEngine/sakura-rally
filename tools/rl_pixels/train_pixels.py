# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = ["torch>=2.2", "stable-baselines3>=2.3", "gymnasium>=0.29", "numpy", "pillow"]
# ///
"""Trains the pixel driver (docs/PIXELS.md): a CNN that drives from one 128x72 frame of its
DriveEyes camera and 21 floats (forward and side speed, yaw rate, wheels on the ground and on
loose ground, the controls it holds, its last choice). The workers render
(tools/rl_pixels/pixel_env.gd on the agents' dev build, offscreen), so a run holds the render lock
(tools/rl_pixels/train.sh launches it that way):

    tools/rl_pixels/train.sh imitate --run px1
    tools/rl_pixels/train.sh ppo --run px1ppo --init tools/rl/runs/px1/ckpt/latest.pt
    uv run --python 3.12 tools/rl_pixels/train_pixels.py film --run px1 --ckpt tools/rl/runs/px1/ckpt/latest.pt

imitate  DAgger from the geometry driver (--teacher: an SB3 checkpoint of tools/rl/train.py, the
         shipped gen2 7M by default), "learning by cheating" (Chen et al. 2019): every rendered
         frame comes with the car's DriveSense vector, so the teacher labels it for free. The
         teacher drives at first; its share of the choices falls to 0 over --beta-steps and the
         student drives into its own mistakes, which the teacher labels as well. The student
         learns the teacher's odds (cross-entropy per option group) from a replay of the latest
         --buffer frames, augmented: shifted up to 4 px, brightness, contrast, saturation and hue
         jittered (a road it never saw differs mostly in the hue of its trees and grass).
ppo      PPO fine-tuning of an imitate checkpoint. The actor keeps the pixels; the critic sees
         DriveSense (asymmetric actor-critic, Pinto et al. 2017) and starts as the teacher's value
         network, with the teacher's reward scaling, so the first updates already have sound
         advantages. The teacher's odds stay in the loss as an augmented imitation term, its
         weight falling from --bc to --bc-end over --bc-steps; an update stops its epochs once
         the policy moved past 1.5x --target-kl.
film     One lap of Hanami and one of Momiji by a checkpoint, recorded as replays, filmed from a
         chase camera (tools/rl_pixels/film_render.gd) with the frame the network saw at each
         moment in a corner: tools/rl/runs/<run>/film/<run>_<steps>_<route>.mp4.
eval     The periodic eval for one checkpoint, once per --delays value: physics ticks a choice
         waits before the hands take it, as the game's GPU answer comes back frames later.
export   A checkpoint's actor for the game (scripts/ai/pixel_policy.gd runs it on the GPU):
         assets/ai/pixel_driver.json, every layer's shape, weights and biases (base64 float32 in
         torch's order), and a test frame with the logits torch gives it, which the game checks
         its network against.

Every --eval-every decisions the student drives Hanami and Momiji (never trained on), each both
ways, from the start line by tools/rl/eval.gd's rules with NeuralPilot's stuck fallback, 2 cars
each, in the stage's own season, and an EVAL line per route is printed as eval.gd prints it.
Writes tools/rl/runs/<run>/: progress.csv, eval.csv, ckpt/actor_<steps>.pt (and latest.pt), logs/.
"""

from __future__ import annotations

import argparse
import collections
import csv
import json
import math
import shutil
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

from pixel_env import PROJECT, PixelEnv

RUNS = PROJECT / "tools/rl/runs"
DIMS = (7, 3, 2)
## DriveHands.release(): the wheel straight, no pedal, no handbrake.
REST = (3, 1, 0)
## DriveSense's last floats: motion (5) and the controls held (4).
MOTION_HANDS = 9
VEC = MOTION_HANDS + sum(DIMS)
EVAL_ROUTES = ["hanami,hanami:rev", "momiji,momiji:rev"]
EVAL_SEASONS = ["1,0,0", "0,0,1"]
## scripts/ai/neural_pilot.gd's stuck fallback.
STUCK_KMH, STUCK_S, UNSTICK_KMH = 3.0, 1.0, 15.0
DECISION_S = 0.1


def vec_of(obs: np.ndarray, prev: np.ndarray) -> np.ndarray:
    """The student's floats: DriveSense's motion and hands, and its last choice one-hot."""
    n = len(obs)
    v = np.zeros((n, VEC), np.float32)
    v[:, :MOTION_HANDS] = obs[:, -MOTION_HANDS:]
    rows = np.arange(n)
    o = MOTION_HANDS
    for g, d in enumerate(DIMS):
        v[rows, o + prev[:, g]] = 1.0
        o += d
    return v


def group_argmax(logits: np.ndarray) -> np.ndarray:
    out = np.empty((len(logits), len(DIMS)), np.int64)
    o = 0
    for g, d in enumerate(DIMS):
        out[:, g] = logits[:, o:o + d].argmax(1)
        o += d
    return out


def group_softmax(logits: np.ndarray) -> np.ndarray:
    p = np.empty_like(logits)
    o = 0
    for d in DIMS:
        e = np.exp(logits[:, o:o + d] - logits[:, o:o + d].max(1, keepdims=True))
        p[:, o:o + d] = e / e.sum(1, keepdims=True)
        o += d
    return p


def group_sample(logits: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    p = group_softmax(logits)
    out = np.empty((len(logits), len(DIMS)), np.int64)
    o = 0
    for g, d in enumerate(DIMS):
        out[:, g] = (p[:, o:o + d].cumsum(1) > rng.random((len(p), 1))).argmax(1)
        o += d
    return out


class Actor(nn.Module):
    """The Nature CNN (Mnih et al. 2015) on the frame, then with the floats through an MLP to one
    logit per option of every DriveHands group."""

    def __init__(self, h: int = 72, w: int = 128):
        super().__init__()
        self.cnn = nn.Sequential(
            nn.Conv2d(3, 32, 8, 4), nn.ReLU(),
            nn.Conv2d(32, 64, 4, 2), nn.ReLU(),
            nn.Conv2d(64, 64, 3, 1), nn.ReLU(), nn.Flatten())
        with torch.no_grad():
            flat = self.cnn(torch.zeros(1, 3, h, w)).shape[1]
        self.fc = nn.Sequential(nn.Linear(flat, 512), nn.ReLU())
        self.head = nn.Sequential(nn.Linear(512 + VEC, 256), nn.ReLU(), nn.Linear(256, sum(DIMS)))

    def forward(self, img: torch.Tensor, vec: torch.Tensor) -> torch.Tensor:
        return self.head(torch.cat([self.fc(self.cnn(img)), vec], 1))


def frames(img: np.ndarray, dev: torch.device) -> torch.Tensor:
    """uint8 N x H x W x 3 -> float N x 3 x H x W in 0..1 on `dev`."""
    return torch.from_numpy(img).to(dev).permute(0, 3, 1, 2).float().div_(255.0)


## Rotation about the grey axis (1, 1, 1): its cross-product matrix and projection.
_K = torch.tensor([[0.0, -1.0, 1.0], [1.0, 0.0, -1.0], [-1.0, 1.0, 0.0]]) / math.sqrt(3.0)
_G = torch.full((3, 3), 1.0 / 3.0)


def augment(x: torch.Tensor, pad: int = 4) -> torch.Tensor:
    """Per frame: brightness and contrast x0.7-1.3, hue turned up to 60° either way, saturation
    x0.6-1.4 (grey tarmac keeps its colour), then shifted up to `pad` px (DrQ, the edge pixels
    repeated)."""
    n, _, h, w = x.shape
    dev = x.device

    def u(lo: float, hi: float, *shape: int) -> torch.Tensor:
        return torch.empty(*shape, device=dev).uniform_(lo, hi)

    x = x * u(0.7, 1.3, n, 1, 1, 1)
    m = x.mean((1, 2, 3), keepdim=True)
    x = (x - m) * u(0.7, 1.3, n, 1, 1, 1) + m
    th = u(-math.pi / 3.0, math.pi / 3.0, n)
    c, s = th.cos()[:, None, None], th.sin()[:, None, None]
    g = _G.to(dev)
    rot = c * torch.eye(3, device=dev) + s * _K.to(dev) + (1.0 - c) * g
    mix = g + u(0.6, 1.4, n, 1, 1) * (rot - g)
    x = torch.einsum("nij,njhw->nihw", mix, x).clamp_(0.0, 1.0)
    xp = F.pad(x, (pad, pad, pad, pad), mode="replicate").permute(0, 2, 3, 1)
    rows = (torch.randint(0, 2 * pad + 1, (n, 1), device=dev) + torch.arange(h, device=dev))[:, :, None]
    cols = (torch.randint(0, 2 * pad + 1, (n, 1), device=dev) + torch.arange(w, device=dev))[:, None, :]
    return xp[torch.arange(n, device=dev)[:, None, None], rows, cols].permute(0, 3, 1, 2)


def imitation_loss(logits: torch.Tensor, target: torch.Tensor) -> torch.Tensor:
    """Cross-entropy of the student's odds against the teacher's, summed over the groups."""
    loss = logits.new_zeros(())
    o = 0
    for d in DIMS:
        loss = loss - (target[:, o:o + d] * F.log_softmax(logits[:, o:o + d], 1)).sum(1).mean()
        o += d
    return loss


class Teacher:
    """The geometry driver: an SB3 PPO checkpoint of tools/rl/train.py. Its observations are raw
    DriveSense vectors (its VecNormalize scales rewards only)."""

    def __init__(self, path: Path):
        from stable_baselines3 import PPO
        self.policy = PPO.load(path, device="cpu").policy
        self.policy.set_training_mode(False)

    @torch.no_grad()
    def logits(self, obs: np.ndarray) -> np.ndarray:
        p = self.policy
        return p.action_net(p.mlp_extractor.forward_actor(p.extract_features(torch.from_numpy(obs)))).numpy()


class Replay:
    """The latest `size` frames with float columns, overwritten oldest first."""

    def __init__(self, size: int, h: int, w: int, columns: dict[str, int]):
        self.size = size
        self.img = np.empty((size, h, w, 3), np.uint8)
        self.cols = {k: np.empty((size, d), np.float32) for k, d in columns.items()}
        self.n = 0
        self.i = 0

    def add(self, img: np.ndarray, **cols: np.ndarray) -> None:
        idx = (self.i + np.arange(len(img))) % self.size
        self.img[idx] = img
        for k, v in cols.items():
            self.cols[k][idx] = v
        self.i = (self.i + len(img)) % self.size
        self.n = min(self.n + len(img), self.size)

    def sample(self, b: int, rng: np.random.Generator):
        idx = rng.integers(0, self.n, b)
        return self.img[idx], {k: v[idx] for k, v in self.cols.items()}


class Evaluator:
    """Hanami and Momiji, both ways, from the start line: one worker per stage in its season.
    `extra`: more pixel_env.gd options (film: replays)."""

    def __init__(self, run_dir: Path, seed: int, cars: int = 2, routes: list[str] = EVAL_ROUTES,
                 seasons: list[str] = EVAL_SEASONS, extra: dict | None = None):
        self.env = PixelEnv(procs=len(routes), routes=routes, seasons=seasons, looks=("shade",), mode="eval",
                            eval_cars=cars, car="sakura", seed=seed, log_dir=run_dir / "logs_eval", extra=extra)
        self.csv_path = run_dir / "eval.csv"

    def run(self, act, name: str, steps: int, limit_s: float, keep: list | None = None) -> list[dict]:
        """Drives every car with `act(frames, DriveSense vectors, last choices) -> choices` until
        all finished or `limit_s`; prints and appends an EVAL row per route. `keep` collects every
        decision's frames (n x H x W x 3, the first from the start line)."""
        env = self.env
        img, obs, _, info = env.reset()
        n = env.n
        prev = np.tile(REST, (n, 1))
        stuck = np.zeros(n)
        unstick = np.zeros(n, bool)
        for _ in range(int(limit_s / DECISION_S)):
            if keep is not None:
                keep.append(img.copy())
            a = act(img, obs, prev)
            kmh = np.abs(info[:, 2])
            stuck = np.where(kmh < STUCK_KMH, stuck + DECISION_S, 0.0)
            unstick = np.where(stuck > STUCK_S, True, np.where(kmh > UNSTICK_KMH, False, unstick))
            a[unstick, 1] = 2
            a[unstick, 2] = 0
            img, obs, _, _, info = env.step(a)
            prev = a
            if (info[:, 3] >= 0.0).all():
                break
        self.last_info = info
        rows = []
        routes = [env.route(k, info[k]) for k in range(n)]
        for route in dict.fromkeys(routes):
            i = info[[k for k in range(n) if routes[k] == route]]
            times = sorted(float(t) for t in i[:, 3] if t >= 0.0)
            samples = np.maximum(i[:, 10], 1.0)
            rows.append({
                "steps": steps, "policy": name, "route": route, "finished": len(times), "cars": len(i),
                "best": round(times[0], 1) if times else "", "median": round(times[len(times) // 2], 1) if times else "",
                "resets": i[:, 4].mean(), "off": i[:, 5].mean(), "stall": i[:, 6].mean(), "roll": i[:, 7].mean(),
                "kmh": (i[:, 9] / samples).mean(), "steer": (i[:, 8] / (samples * DECISION_S)).mean(),
                "dist": i[:, 1].mean(), "length": env.lengths[route]})
        new = not self.csv_path.exists()
        with open(self.csv_path, "a", newline="") as f:
            wr = csv.DictWriter(f, rows[0].keys())
            if new:
                wr.writeheader()
            for r in rows:
                wr.writerow({k: round(v, 2) if isinstance(v, float) else v for k, v in r.items()})
                print(f"EVAL policy={name} route={r['route']} finished={r['finished']}/{r['cars']} "
                      f"best={r['best'] or '-'} median={r['median'] or '-'} resets={r['resets']:.1f} "
                      f"(off {r['off']:.1f} stall {r['stall']:.1f} roll {r['roll']:.1f}) kmh={r['kmh']:.0f} "
                      f"steer={r['steer']:.2f}/s dist={r['dist']:.0f} length={r['length']:.0f}", flush=True)
        return rows

    def close(self) -> None:
        self.env.close()


def student_act(actor: Actor, dev: torch.device):
    @torch.no_grad()
    def act(img: np.ndarray, obs: np.ndarray, prev: np.ndarray) -> np.ndarray:
        return group_argmax(actor(frames(img, dev), torch.from_numpy(vec_of(obs, prev)).to(dev)).cpu().numpy())
    return act


def save(run_dir: Path, state: dict, steps: int, args) -> None:
    """ckpt/actor_<steps>.pt (and latest.pt): `state` (state dicts), the steps and the options."""
    ckpt = run_dir / "ckpt"
    ckpt.mkdir(parents=True, exist_ok=True)
    path = ckpt / f"actor_{steps}.pt"
    torch.save({**state, "steps": steps, "args": {k: str(v) for k, v in vars(args).items()}}, path)
    shutil.copyfile(path, ckpt / "latest.pt")
    print(f"[{args.run}] saved {path.name}", flush=True)


def imitate(args, run_dir: Path) -> None:
    dev = torch.device(args.device)
    rng = np.random.default_rng(args.seed)
    torch.manual_seed(args.seed)
    teacher = Teacher(PROJECT / args.teacher)
    actor = Actor().to(dev)
    opt = torch.optim.Adam(actor.parameters(), lr=args.lr)
    steps = 0
    if args.resume:
        ck = torch.load(args.resume, map_location=dev)
        actor.load_state_dict(ck["actor"])
        opt.load_state_dict(ck["opt"])
        steps = int(ck["steps"])
        print(f"[{args.run}] resumed {args.resume} at {steps}", flush=True)
    env = PixelEnv(procs=args.procs, cars=args.cars, routes=args.routes.split(";"), car=args.car, seed=args.seed + steps,
                   episode_s=args.episode_s, looks=tuple(args.looks.split(",")), log_dir=run_dir / "logs")
    evaluator = Evaluator(run_dir, args.seed)
    try:
        if args.eval_teacher:
            evaluator.run(lambda img, obs, prev: group_argmax(teacher.logits(obs)), "teacher", steps, args.eval_s)
        n = env.n
        buf = Replay(args.buffer, env.h, env.w, {"vec": VEC, "target": sum(DIMS)})
        reasons = [r for r in env.reasons if r]
        new = not (run_dir / "progress.csv").exists()
        csv_file = open(run_dir / "progress.csv", "a", newline="")
        wr = csv.writer(csv_file)
        if new:
            wr.writerow(["steps", "wall_s", "steps_per_s", "beta", "loss", "agree_steer", "agree_pedal",
                         "agree_hand", "episodes", "mean_m", "p90_m"] + reasons)
        episodes: collections.deque = collections.deque(maxlen=400)
        losses: list[torch.Tensor] = []
        agree = np.zeros(len(DIMS))
        agree_n = 0
        ended = 0
        samplers = np.arange(n) % 4 == 0  # these cars sample the student's odds, the rest take its likeliest
        img, obs, _, _ = env.reset()
        prev = np.tile(REST, (n, 1))
        t0 = time.time()
        steps0 = saved_at = evaluated_at = steps
        next_log = steps + args.log_every
        next_save = (steps // args.save_every + 1) * args.save_every
        next_eval = (steps // args.eval_every + 1) * args.eval_every
        while steps < args.steps:
            beta = max(0.0, 1.0 - steps / args.beta_steps)
            vec = vec_of(obs, prev)
            t_logits = teacher.logits(obs)
            buf.add(img, vec=vec, target=group_softmax(t_logits))
            with torch.no_grad():
                s_logits = actor(frames(img, dev), torch.from_numpy(vec).to(dev)).cpu().numpy()
            s_best = group_argmax(s_logits)
            t_best = group_argmax(t_logits)
            agree += (s_best == t_best).sum(0)
            agree_n += n
            a = np.where(samplers[:, None], group_sample(s_logits, rng), s_best)
            a = np.where((rng.random(n) < beta)[:, None], t_best, a)
            env.send(a)
            # learn while the workers drive
            if buf.n >= args.warmup:
                for _ in range(args.updates):
                    b_img, cols = buf.sample(args.batch, rng)
                    logits = actor(augment(frames(b_img, dev)), torch.from_numpy(cols["vec"]).to(dev))
                    loss = imitation_loss(logits, torch.from_numpy(cols["target"]).to(dev))
                    opt.zero_grad(set_to_none=True)
                    loss.backward()
                    opt.step()
                    losses.append(loss.detach())
            img, obs, _, flags, info = env.recv()
            prev = a
            prev[flags == 1] = REST  # a car whose episode ended stands at its next start, hands off
            for k in np.flatnonzero(flags):
                episodes.append((float(info[k, 1]), env.reasons[int(info[k, 3])]))
                ended += 1
            steps += n
            if steps >= next_log:
                next_log += args.log_every
                wall = time.time() - t0
                sps = (steps - steps0) / max(wall, 1e-6)
                loss_v = float(torch.stack(losses).mean()) if losses else float("nan")
                losses.clear()
                ag = agree / max(agree_n, 1)
                agree[:] = 0
                agree_n = 0
                metres = np.array([e[0] for e in episodes]) if episodes else np.zeros(1)
                counts = collections.Counter(e[1] for e in episodes)
                shares = [counts.get(r, 0) / max(len(episodes), 1) for r in reasons]
                wr.writerow([steps, round(wall), round(sps), round(beta, 3), round(loss_v, 4)]
                            + [round(float(x), 3) for x in ag]
                            + [ended, round(float(metres.mean()), 1), round(float(np.percentile(metres, 90)), 1)]
                            + [round(s, 3) for s in shares])
                csv_file.flush()
                ends = " ".join(f"{r}={s:.2f}" for r, s in zip(reasons, shares) if s > 0)
                print(f"[{args.run}] {steps / 1e6:.2f}M {sps:.0f}/s beta {beta:.2f} loss {loss_v:.3f} "
                      f"agree {ag[0]:.2f}/{ag[1]:.2f}/{ag[2]:.2f} episodes {ended} m/ep {metres.mean():.0f} "
                      f"(p90 {np.percentile(metres, 90):.0f}) {ends}", flush=True)
            if steps >= next_save:
                next_save += args.save_every
                save(run_dir, {"actor": actor.state_dict(), "opt": opt.state_dict()}, steps, args)
                saved_at = steps
            if steps >= next_eval:
                next_eval += args.eval_every
                te = time.time()
                evaluator.run(student_act(actor, dev), f"{args.run}_{steps}", steps, args.eval_s)
                evaluated_at = steps
                t0 += time.time() - te  # the eval's wall time is not training's
        if saved_at != steps:
            save(run_dir, {"actor": actor.state_dict(), "opt": opt.state_dict()}, steps, args)
        if evaluated_at != steps:
            evaluator.run(student_act(actor, dev), f"{args.run}_{steps}", steps, args.eval_s)
    finally:
        env.close()
        evaluator.close()


class Critic(nn.Module):
    """The value of a DriveSense state, initialised as the teacher's value network (46 -> 256 ->
    256 -> 1, tanh), trained on the same rewards: fine-tuning starts with a critic that knows the
    road. Only the critic sees DriveSense (asymmetric actor-critic, Pinto et al. 2017)."""

    def __init__(self, obs_size: int = 46):
        super().__init__()
        self.net = nn.Sequential(nn.Linear(obs_size, 256), nn.Tanh(), nn.Linear(256, 256), nn.Tanh(),
                                 nn.Linear(256, 1))

    def forward(self, priv: torch.Tensor) -> torch.Tensor:
        return self.net(priv).squeeze(-1)

    @staticmethod
    def from_teacher(policy) -> "Critic":
        c = Critic()
        c.net[0].load_state_dict(policy.mlp_extractor.value_net[0].state_dict())
        c.net[2].load_state_dict(policy.mlp_extractor.value_net[2].state_dict())
        c.net[4].load_state_dict(policy.value_net.state_dict())
        return c


class RewardNorm:
    """VecNormalize's reward scaling (tools/rl/train.py): a reward over the running standard
    deviation of the discounted return, clipped. It continues the teacher's statistics, the scale
    its critic learned."""

    def __init__(self, path: Path, n: int):
        import pickle
        with open(path, "rb") as f:
            vn = pickle.load(f)
        self.mean, self.var, self.count = float(vn.ret_rms.mean), float(vn.ret_rms.var), float(vn.ret_rms.count)
        self.gamma, self.clip, self.eps = float(vn.gamma), float(vn.clip_reward), float(vn.epsilon)
        self.ret = np.zeros(n)

    def __call__(self, rew: np.ndarray, done: np.ndarray) -> np.ndarray:
        self.ret = self.ret * self.gamma + rew
        m, v, c = float(self.ret.mean()), float(self.ret.var()), len(self.ret)
        d = m - self.mean
        tot = self.count + c
        self.mean += d * c / tot
        self.var = (self.var * self.count + v * c + d * d * self.count * c / tot) / tot
        self.count = tot
        out = np.clip(rew / math.sqrt(self.var + self.eps), -self.clip, self.clip).astype(np.float32)
        self.ret[done] = 0.0
        return out

    def state(self) -> dict:
        return {"mean": self.mean, "var": self.var, "count": self.count}

    def load(self, s: dict) -> None:
        self.mean, self.var, self.count = s["mean"], s["var"], s["count"]


def log_prob_entropy(logits: torch.Tensor, act: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
    """Log-probability of the choices `act` (N x groups) and the entropy, summed over the groups."""
    logp = logits.new_zeros(len(logits))
    ent = logits.new_zeros(len(logits))
    o = 0
    for g, d in enumerate(DIMS):
        lp = F.log_softmax(logits[:, o:o + d], 1)
        logp = logp + lp.gather(1, act[:, g:g + 1]).squeeze(1)
        ent = ent - (lp.exp() * lp).sum(1)
        o += d
    return logp, ent


def ppo(args, run_dir: Path) -> None:
    """PPO on the pixel actor from an imitate checkpoint, the critic on DriveSense, with the
    teacher's odds as an augmented imitation term (weight --bc falling to --bc-end)."""
    dev = torch.device(args.device)
    rng = np.random.default_rng(args.seed)
    torch.manual_seed(args.seed)
    teacher_path = PROJECT / args.teacher
    teacher = Teacher(teacher_path)
    actor = Actor().to(dev)
    critic = Critic.from_teacher(teacher.policy).to(dev)
    opt = torch.optim.Adam([{"params": actor.parameters(), "lr": args.lr},
                            {"params": critic.parameters(), "lr": args.vf_lr}], eps=1e-5)
    steps = 0
    ck = torch.load(args.resume or PROJECT / args.init, map_location=dev)
    actor.load_state_dict(ck["actor"])
    if args.resume:
        critic.load_state_dict(ck["critic"])
        opt.load_state_dict(ck["opt"])
        steps = int(ck["steps"])
        print(f"[{args.run}] resumed {args.resume} at {steps}", flush=True)
    env = PixelEnv(procs=args.procs, cars=args.cars, routes=args.routes.split(";"), car=args.car, seed=args.seed + steps,
                   episode_s=args.episode_s, looks=tuple(args.looks.split(",")), log_dir=run_dir / "logs")
    norm = RewardNorm(teacher_path.parent / f"vecnormalize_{teacher_path.stem.split('_')[-1]}.pkl", env.n)
    if args.resume:
        norm.load(ck["norm"])
    evaluator = Evaluator(run_dir, args.seed)
    try:
        n, T = env.n, args.n_steps
        r_img = np.empty((T, n, env.h, env.w, 3), np.uint8)
        r_vec = np.empty((T, n, VEC), np.float32)
        r_priv = np.empty((T, n, env.obs_size), np.float32)
        r_act = np.empty((T, n, len(DIMS)), np.int64)
        r_logp = np.empty((T, n), np.float32)
        r_val = np.empty((T, n), np.float32)
        r_rew = np.empty((T, n), np.float32)
        r_done = np.empty((T, n), np.float32)
        r_tp = np.empty((T, n, sum(DIMS)), np.float32)
        reasons = [r for r in env.reasons if r]
        new = not (run_dir / "progress.csv").exists()
        csv_file = open(run_dir / "progress.csv", "a", newline="")
        wr = csv.writer(csv_file)
        if new:
            wr.writerow(["steps", "wall_s", "steps_per_s", "bc_coef", "pg", "vf", "entropy", "kl", "clip_frac",
                         "bc", "explained_var", "reward", "episodes", "mean_m", "p90_m"] + reasons)
        episodes: collections.deque = collections.deque(maxlen=400)
        ended = 0
        img, obs, _, _ = env.reset()
        prev = np.tile(REST, (n, 1))
        t0 = time.time()
        steps0 = saved_at = evaluated_at = steps
        next_save = (steps // args.save_every + 1) * args.save_every
        next_eval = (steps // args.eval_every + 1) * args.eval_every
        while steps < args.steps:
            bc_coef = args.bc_end + (args.bc - args.bc_end) * max(0.0, 1.0 - steps / args.bc_steps)
            for t in range(T):
                vec = vec_of(obs, prev)
                with torch.no_grad():
                    logits = actor(frames(img, dev), torch.from_numpy(vec).to(dev))
                    a = group_sample(logits.cpu().numpy(), rng)
                    logp, _ = log_prob_entropy(logits, torch.from_numpy(a).to(dev))
                    r_logp[t] = logp.cpu().numpy()
                    r_val[t] = critic(torch.from_numpy(obs).to(dev)).cpu().numpy()
                r_img[t], r_vec[t], r_priv[t], r_act[t] = img, vec, obs, a
                r_tp[t] = group_softmax(teacher.logits(obs))
                env.send(a)
                img, obs, rew, flags, info = env.recv()
                r = norm(rew, flags != 0)
                cut = flags == 2  # a time cut: the car drives on, so its return goes on (bootstrap)
                if cut.any():
                    with torch.no_grad():
                        r[cut] += norm.gamma * critic(torch.from_numpy(obs[cut]).to(dev)).cpu().numpy()
                r_rew[t] = r
                r_done[t] = flags != 0
                prev = a.copy()
                prev[flags == 1] = REST
                for k in np.flatnonzero(flags):
                    episodes.append((float(info[k, 1]), env.reasons[int(info[k, 3])]))
                    ended += 1
            steps += T * n
            with torch.no_grad():
                last_v = critic(torch.from_numpy(obs).to(dev)).cpu().numpy()
            adv = np.zeros((T, n), np.float32)
            gae = np.zeros(n, np.float32)
            for t in reversed(range(T)):
                next_v = last_v if t == T - 1 else r_val[t + 1]
                live = 1.0 - r_done[t]
                gae = r_rew[t] + norm.gamma * next_v * live - r_val[t] + norm.gamma * args.gae_lambda * live * gae
                adv[t] = gae
            ret = adv + r_val
            # the update
            B = T * n
            f_img, f_vec, f_priv = r_img.reshape(B, env.h, env.w, 3), r_vec.reshape(B, VEC), r_priv.reshape(B, -1)
            f_act, f_logp, f_adv = r_act.reshape(B, -1), r_logp.reshape(B), adv.reshape(B)
            f_ret, f_tp = ret.reshape(B), r_tp.reshape(B, -1)
            stats = collections.defaultdict(list)
            for epoch in range(args.epochs):
                idx = rng.permutation(B)
                kls = []
                for s in range(0, B - args.batch + 1, args.batch):
                    j = idx[s:s + args.batch]
                    x = frames(f_img[j], dev)
                    v_in = torch.from_numpy(f_vec[j]).to(dev)
                    a_t = torch.from_numpy(f_act[j]).to(dev)
                    adv_t = torch.from_numpy(f_adv[j]).to(dev)
                    adv_t = (adv_t - adv_t.mean()) / (adv_t.std() + 1e-8)
                    logp, ent = log_prob_entropy(actor(x, v_in), a_t)
                    log_ratio = logp - torch.from_numpy(f_logp[j]).to(dev)
                    ratio = log_ratio.exp()
                    pg = -torch.min(ratio * adv_t, ratio.clamp(1.0 - args.clip, 1.0 + args.clip) * adv_t).mean()
                    vf = F.mse_loss(critic(torch.from_numpy(f_priv[j]).to(dev)), torch.from_numpy(f_ret[j]).to(dev))
                    bc = imitation_loss(actor(augment(x), v_in), torch.from_numpy(f_tp[j]).to(dev))
                    loss = pg + args.vf_coef * vf - args.ent * ent.mean() + bc_coef * bc
                    opt.zero_grad(set_to_none=True)
                    loss.backward()
                    nn.utils.clip_grad_norm_(actor.parameters(), 0.5)
                    nn.utils.clip_grad_norm_(critic.parameters(), 0.5)
                    opt.step()
                    with torch.no_grad():
                        kl = ((ratio - 1.0) - log_ratio).mean()
                        clip_frac = ((ratio - 1.0).abs() > args.clip).float().mean()
                    kls.append(kl)
                    for key, val in (("pg", pg), ("vf", vf), ("entropy", ent.mean()), ("kl", kl),
                                     ("clip_frac", clip_frac), ("bc", bc)):
                        stats[key].append(val.detach())
                if float(torch.stack(kls).mean()) > 1.5 * args.target_kl:
                    break  # the policy moved far enough for this rollout
            wall = time.time() - t0
            sps = (steps - steps0) / max(wall, 1e-6)
            s = {k: float(torch.stack(v).mean()) for k, v in stats.items()}
            ev = 1.0 - float(np.var(f_ret - r_val.reshape(B))) / max(float(np.var(f_ret)), 1e-8)
            metres = np.array([e[0] for e in episodes]) if episodes else np.zeros(1)
            counts = collections.Counter(e[1] for e in episodes)
            shares = [counts.get(r, 0) / max(len(episodes), 1) for r in reasons]
            wr.writerow([steps, round(wall), round(sps), round(bc_coef, 3)]
                        + [round(s[k], 4) for k in ("pg", "vf", "entropy", "kl", "clip_frac", "bc")]
                        + [round(ev, 3), round(float(r_rew.mean()), 4), ended, round(float(metres.mean()), 1),
                           round(float(np.percentile(metres, 90)), 1)] + [round(x, 3) for x in shares])
            csv_file.flush()
            ends = " ".join(f"{r}={x:.2f}" for r, x in zip(reasons, shares) if x > 0)
            print(f"[{args.run}] {steps / 1e6:.2f}M {sps:.0f}/s pg {s['pg']:.3f} vf {s['vf']:.3f} ent {s['entropy']:.2f} "
                  f"kl {s['kl']:.4f} clip {s['clip_frac']:.2f} bc {s['bc']:.3f}x{bc_coef:.2f} ev {ev:.2f} "
                  f"episodes {ended} m/ep {metres.mean():.0f} (p90 {np.percentile(metres, 90):.0f}) {ends}", flush=True)
            state = {"actor": actor.state_dict(), "critic": critic.state_dict(), "opt": opt.state_dict(),
                     "norm": norm.state()}
            if steps >= next_save:
                next_save += args.save_every
                save(run_dir, state, steps, args)
                saved_at = steps
            if steps >= next_eval:
                next_eval += args.eval_every
                te = time.time()
                evaluator.run(student_act(actor, dev), f"{args.run}_{steps}", steps, args.eval_s)
                evaluated_at = steps
                t0 += time.time() - te
        if saved_at != steps:
            save(run_dir, {"actor": actor.state_dict(), "critic": critic.state_dict(), "opt": opt.state_dict(),
                           "norm": norm.state()}, steps, args)
        if evaluated_at != steps:
            evaluator.run(student_act(actor, dev), f"{args.run}_{steps}", steps, args.eval_s)
    finally:
        env.close()
        evaluator.close()


FONT = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"


def compose(frames_dir: Path, eyes: np.ndarray, out: Path, fps: float, title: str, subtitle: str = "") -> None:
    """The rendered frames with the network's view of the same moment in a corner (4x, nearest
    neighbour: its pixels as it gets them), a title and a subtitle line, as an H.264 mp4."""
    import subprocess
    from PIL import Image, ImageDraw, ImageFont
    files = sorted(frames_dir.glob("frame_*.png"))
    w, h = Image.open(files[0]).size
    scale = max(2, w // 320)
    iw, ih = eyes.shape[2] * scale, eyes.shape[1] * scale
    big, small = ImageFont.truetype(FONT, max(18, h // 26)), ImageFont.truetype(FONT, max(14, h // 40))
    enc = subprocess.Popen(["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
                            "-s", f"{w}x{h}", "-r", str(fps), "-i", "-", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                            "-crf", "18", str(out)], stdin=subprocess.PIPE)
    m = h // 30
    for i, f in enumerate(files):
        k = min(int(i / fps / DECISION_S + 1e-6), len(eyes) - 1)
        im = Image.open(f).convert("RGB")
        d = ImageDraw.Draw(im)
        x, y = m, h - ih - m
        d.rectangle((x - 3, y - 3, x + iw + 2, y + ih + 2), fill=(255, 255, 255))
        im.paste(Image.fromarray(eyes[k]).resize((iw, ih), Image.NEAREST), (x, y))
        for text, font, (tx, ty) in ((title, big, (m, m)), (subtitle, small, (m, m + big.size + 8)),
                                     (f"what the network sees: {eyes.shape[2]}x{eyes.shape[1]}", small,
                                      (x, y - small.size - 10))):
            d.text((tx + 2, ty + 2), text, font=font, fill=(0, 0, 0))
            d.text((tx, ty), text, font=font, fill=(255, 255, 255))
        enc.stdin.write(im.tobytes())
    enc.stdin.close()
    if enc.wait() != 0:
        raise RuntimeError(f"ffmpeg failed on {out}")


def evaluate(args, run_dir: Path) -> None:
    """The periodic eval for one checkpoint, once per --delays value (physics ticks a choice waits
    before the hands take it): rows <run>_<steps>_d<delay> in <run>/eval.csv."""
    dev = torch.device(args.device)
    actor = Actor().to(dev)
    ck = torch.load(PROJECT / args.ckpt, map_location=dev)
    actor.load_state_dict(ck["actor"])
    for d in (int(x) for x in args.delays.split(",")):
        ev = Evaluator(run_dir, args.seed, extra={"delay": d})
        try:
            ev.run(student_act(actor, dev), f"{Path(args.ckpt).parent.parent.name}_{ck['steps']}_d{d}",
                   int(ck["steps"]), args.eval_s)
        finally:
            ev.close()


def export(args, run_dir: Path) -> None:
    """--ckpt's actor as the game's pixel driver file (scripts/ai/pixel_policy.gd)."""
    import base64
    ck = torch.load(PROJECT / args.ckpt, map_location="cpu")
    actor = Actor()
    actor.load_state_dict(ck["actor"])
    actor.eval()
    h, w = 72, 128
    # the layout pixel_policy.gd runs: unpadded convolutions with ReLU, flatten, dense + ReLU,
    # the floats joining the head's first layer after the CNN's 512
    kinds = [type(m) for m in (*actor.cnn, *actor.fc, *actor.head)]
    assert kinds == [nn.Conv2d, nn.ReLU] * 3 + [nn.Flatten, nn.Linear, nn.ReLU, nn.Linear, nn.ReLU, nn.Linear], kinds

    def blob(t: torch.Tensor) -> str:
        return base64.b64encode(t.detach().float().contiguous().numpy().astype("<f4").tobytes()).decode()

    layers = []
    c, ih, iw = 3, h, w
    for m in actor.cnn:
        if isinstance(m, nn.Conv2d):
            assert m.padding == (0, 0) and m.dilation == (1, 1) and m.groups == 1
            k, s = m.kernel_size[0], m.stride[0]
            oh, ow = (ih - k) // s + 1, (iw - k) // s + 1
            layers.append({"type": "conv", "in": c, "in_h": ih, "in_w": iw, "out": m.out_channels,
                           "out_h": oh, "out_w": ow, "k": k, "stride": s, "w": blob(m.weight), "b": blob(m.bias)})
            c, ih, iw = m.out_channels, oh, ow
    for m, relu in ((actor.fc[0], True), (actor.head[0], True), (actor.head[2], False)):
        layer = {"type": "dense", "in": m.in_features, "out": m.out_features, "relu": relu,
                 "w": blob(m.weight), "b": blob(m.bias)}
        if m is actor.head[0]:
            layer["vec_at"] = actor.fc[0].out_features
        layers.append(layer)

    rng = np.random.default_rng(args.seed)
    yy, xx = np.mgrid[0:h, 0:w]
    img = np.stack([xx * 255 // (w - 1), yy * 255 // (h - 1), (xx + yy) * 255 // (w + h - 2)], -1)
    img = np.clip(img + rng.integers(-40, 41, img.shape), 0, 255).astype(np.uint8)
    vec = vec_of(rng.normal(0.0, 0.5, (1, MOTION_HANDS)).astype(np.float32), np.array([REST]))
    with torch.no_grad():
        logits = actor(frames(img[None], torch.device("cpu")), torch.from_numpy(vec))[0].numpy()
    run = Path(args.ckpt).parent.parent.name
    data = {
        "format": "sakura_pixel_driver",
        "meta": {"run": run, "steps": int(ck["steps"]), "ckpt": args.ckpt, "trained": ck.get("args", {})},
        "image": [h, w, 3], "vec": VEC, "action_dims": list(DIMS), "layers": layers,
        "test": {"image": base64.b64encode(img.tobytes()).decode(), "vec": [float(x) for x in vec[0]],
                 "logits": [float(x) for x in logits]},
    }
    out = PROJECT / args.out
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(data, separators=(",", ":")))
    print(f"EXPORT {args.out} {run}_{ck['steps']} {out.stat().st_size / 1e6:.1f} MB", flush=True)


def film(args, run_dir: Path) -> None:
    """One lap of Hanami and of Momiji by a checkpoint, filmed from a chase camera, with what the
    network saw at each moment: <dest>/<run>_<steps>_<route>.mp4."""
    import subprocess
    from pixel_env import DEV
    dev = torch.device(args.device)
    actor = Actor().to(dev)
    ck = torch.load(PROJECT / args.ckpt, map_location=dev)
    actor.load_state_dict(ck["actor"])
    name = f"{args.run}_{ck['steps']}"
    dest = Path(args.dest) if args.dest else run_dir / "film"
    replays = dest / "replays"
    shutil.rmtree(replays, ignore_errors=True)
    ev = Evaluator(dest, args.seed, cars=1, routes=["hanami", "momiji"], extra={"replays": replays, "policy_name": name})
    keep: list[np.ndarray] = []
    try:
        rows = ev.run(student_act(actor, dev), name, int(ck["steps"]), args.eval_s, keep)
        info = ev.last_info
    finally:
        ev.close()  # the workers write the replays as they quit
    frames = np.stack(keep)
    for k, row in enumerate(rows):
        route = row["route"]
        replay = next(replays.glob(f"{route}_0.*"))
        shots = dest / f"{route}_frames"
        shutil.rmtree(shots, ignore_errors=True)
        t1 = float(info[k, 3]) if info[k, 3] >= 0 else len(frames) * DECISION_S
        cmd = ["nice", "-n", "10", DEV, "--summer-offscreen", "--audio-driver", "Dummy", "--disable-crash-handler",
               "--fixed-fps", str(args.fps), "--path", str(PROJECT), "-s", "res://tools/rl_pixels/film_render.gd",
               "--", f"replay={replay}", f"dest={shots}", f"fps={args.fps}", f"size={args.size}", f"t1={t1:.2f}"]
        log = dest / f"{route}_render.log"
        with open(log, "w") as f:
            subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, cwd=PROJECT, timeout=3600, check=False)
        if "FILMED" not in log.read_text(errors="replace"):
            raise RuntimeError(f"render of {replay} failed, see {log}")
        took = f"{row['best']} s" if row["best"] != "" else "did not finish"
        resets = int(round(row["resets"]))
        title = (f"{route.capitalize()}{' (never trained on)' if route.startswith('momiji') else ''}: {took}, "
                 f"{resets} reset{'' if resets == 1 else 's'}")
        out = dest / f"{name}_{route}.mp4"
        compose(shots, frames[:, k], out, args.fps, title, args.label)
        print(f"FILM {out}", flush=True)



def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--run", required=True, help="run name: tools/rl/runs/<run>")
    common.add_argument("--procs", type=int, default=6, help="rendering Summer workers")
    common.add_argument("--cars", type=int, default=16, help="cars per worker")
    common.add_argument("--routes", default="hanami,hanami:rev",
                        help="route ids (':rev' drives one backwards); ';' separates groups dealt to the workers in turn "
                             "(a liaison worker opens the branch gates)")
    common.add_argument("--car", default="sakura,hayate")
    common.add_argument("--looks", default="lean,shade", help="worker looks, dealt in turn")
    common.add_argument("--seed", type=int, default=1)
    common.add_argument("--episode-s", type=float, default=90.0)
    common.add_argument("--teacher", default="tools/rl/runs/gen2/ckpt/model_7000000.zip")
    common.add_argument("--steps", type=float, default=4e6, help="car-decisions")
    common.add_argument("--save-every", type=float, default=250e3)
    common.add_argument("--eval-every", type=float, default=500e3)
    common.add_argument("--eval-s", type=float, default=200.0, help="eval time limit (s)")
    common.add_argument("--resume", type=Path, help="a ckpt/actor_<steps>.pt of this phase to continue from")
    common.add_argument("--device", default="mps")
    common.add_argument("--threads", type=int, default=2, help="torch CPU threads")
    sub = p.add_subparsers(dest="phase", required=True)
    im = sub.add_parser("imitate", parents=[common], help="DAgger from the geometry driver")
    im.add_argument("--beta-steps", type=float, default=1e6, help="decisions over which the teacher's share falls to 0")
    im.add_argument("--buffer", type=int, default=400_000, help="frames kept for replay")
    im.add_argument("--batch", type=int, default=256)
    im.add_argument("--updates", type=int, default=2, help="gradient steps per decision of all cars")
    im.add_argument("--warmup", type=int, default=20_000, help="frames before the first update")
    im.add_argument("--lr", type=float, default=3e-4)
    im.add_argument("--log-every", type=float, default=50e3)
    im.add_argument("--eval-teacher", action="store_true", help="drive the eval with the teacher first")
    pp = sub.add_parser("ppo", parents=[common], help="PPO fine-tuning of an imitate checkpoint")
    pp.add_argument("--init", help="the imitate checkpoint to start from (project-relative)")
    pp.add_argument("--n-steps", type=int, default=128, help="decisions per car per rollout")
    pp.add_argument("--epochs", type=int, default=4)
    pp.add_argument("--batch", type=int, default=1024)
    pp.add_argument("--lr", type=float, default=1e-4, help="actor learning rate")
    pp.add_argument("--vf-lr", type=float, default=3e-4, help="critic learning rate")
    pp.add_argument("--clip", type=float, default=0.2)
    pp.add_argument("--gae-lambda", type=float, default=0.95)
    pp.add_argument("--ent", type=float, default=0.01)
    pp.add_argument("--vf-coef", type=float, default=0.5)
    pp.add_argument("--target-kl", type=float, default=0.02, help="an update stops its epochs past 1.5x this")
    pp.add_argument("--bc", type=float, default=0.5, help="imitation term weight at the start")
    pp.add_argument("--bc-end", type=float, default=0.05)
    pp.add_argument("--bc-steps", type=float, default=4e6, help="decisions over which --bc falls to --bc-end")
    fm = sub.add_parser("film", parents=[common], help="film one lap of Hanami and Momiji by a checkpoint")
    fm.add_argument("--ckpt", required=True, help="a ckpt/actor_<steps>.pt (project-relative)")
    fm.add_argument("--dest", help="folder (default tools/rl/runs/<run>/film)")
    fm.add_argument("--fps", type=int, default=30)
    fm.add_argument("--size", default="1280x720")
    fm.add_argument("--label", default="", help="a second title line (what the checkpoint is)")
    ev = sub.add_parser("eval", parents=[common], help="the eval for one checkpoint, at several action delays")
    ev.add_argument("--ckpt", required=True, help="a ckpt/actor_<steps>.pt (project-relative)")
    ev.add_argument("--delays", default="0", help="physics ticks a choice waits, comma list")
    ex = sub.add_parser("export", parents=[common], help="a checkpoint's actor as the game's pixel driver")
    ex.add_argument("--ckpt", required=True, help="a ckpt/actor_<steps>.pt (project-relative)")
    ex.add_argument("--out", default="assets/ai/pixel_driver.json", help="project-relative")
    args = p.parse_args()
    for k in ("steps", "beta_steps", "log_every", "save_every", "eval_every", "bc_steps"):
        if hasattr(args, k):
            setattr(args, k, int(getattr(args, k)))
    if args.phase == "ppo" and not (args.init or args.resume):
        p.error("ppo needs --init (an imitate checkpoint) or --resume")
    torch.set_num_threads(args.threads)
    run_dir = RUNS / args.run
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / f"args_{args.phase}.json").write_text(json.dumps({k: str(v) for k, v in vars(args).items()}, indent=1))
    if args.phase == "imitate":
        imitate(args, run_dir)
    elif args.phase == "ppo":
        ppo(args, run_dir)
    elif args.phase == "eval":
        evaluate(args, run_dir)
    elif args.phase == "export":
        export(args, run_dir)
    else:
        film(args, run_dir)


if __name__ == "__main__":
    main()
