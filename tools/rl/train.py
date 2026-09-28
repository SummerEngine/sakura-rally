# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = ["torch>=2.2", "stable-baselines3>=2.3", "gymnasium>=0.29", "numpy"]
# ///
"""Trains the Sakura Rally neural driver with PPO (docs/RL.md).

    caffeinate -i nice -n 10 uv run tools/rl/train.py --run hanami --routes hanami,hanami:rev

Writes tools/rl/runs/<run>/: progress.csv (one row per rollout), ckpt/ (SB3 checkpoints and the
reward normaliser, for --resume) and policies/<run>_<steps>.json, the DrivePolicy files the game
and tools/rl/eval.gd load. Every rollout prints one line: steps, env steps/s, episodes ended,
mean and 90th-percentile metres per episode, how episodes ended, mean speed.
"""

from __future__ import annotations

import argparse
import collections
import csv
import json
import shutil
import time
from pathlib import Path

import numpy as np
import torch
from stable_baselines3 import PPO
from stable_baselines3.common.callbacks import BaseCallback
from stable_baselines3.common.vec_env import VecMonitor, VecNormalize

from sakura_env import SakuraVecEnv, export_policy

RUNS = Path(__file__).resolve().parent / "runs"


class Progress(BaseCallback):
    def __init__(self, raw: SakuraVecEnv, run: str, run_dir: Path, save_every: int, meta: dict):
        super().__init__()
        self.raw = raw
        self.run = run
        self.run_dir = run_dir
        self.save_every = save_every
        self.meta = meta
        self.episodes: collections.deque = collections.deque(maxlen=1000)
        self.ended = 0
        self.speeds: list[float] = []
        self.t0 = time.time()
        self.steps0 = 0
        self.next_save = 0
        new = not (run_dir / "progress.csv").exists()
        self.csv_file = open(run_dir / "progress.csv", "a", newline="")
        self.csv = csv.writer(self.csv_file)
        self.reason_names = [r for r in raw.reasons if r]
        if new:
            self.csv.writerow(["steps", "wall_s", "steps_per_s", "episodes", "mean_m", "p90_m", "kmh",
                               "ep_reward"] + self.reason_names)

    def _on_training_start(self) -> None:
        self.steps0 = self.num_timesteps
        self.next_save = (self.num_timesteps // self.save_every + 1) * self.save_every
        if self.num_timesteps == 0:
            self.save()  # the untrained network: the start of the learning curve for ghosts and videos

    def _on_step(self) -> bool:
        for info in self.locals["infos"]:
            if "reason" in info:
                self.episodes.append((info["episode_m"], info["reason"], info["route"]))
                self.ended += 1
        if self.n_calls % 10 == 0:
            self.speeds.append(float(np.mean(self.raw.last_info[:, 2])))
        if self.num_timesteps >= self.next_save:
            self.save()
            self.next_save += self.save_every
        return True

    def _on_rollout_end(self) -> None:
        wall = time.time() - self.t0
        sps = (self.num_timesteps - self.steps0) / max(wall, 1e-6)
        recent = list(self.episodes)[-400:]
        metres = np.array([e[0] for e in recent]) if recent else np.zeros(1)
        counts = collections.Counter(e[1] for e in recent)
        total = max(len(recent), 1)
        shares = [counts.get(r, 0) / total for r in self.reason_names]
        kmh = float(np.mean(self.speeds)) if self.speeds else 0.0
        self.speeds.clear()
        ep_rew = float(np.mean([e["r"] for e in self.model.ep_info_buffer])) if self.model.ep_info_buffer else 0.0
        self.csv.writerow([self.num_timesteps, round(wall), round(sps), self.ended, round(float(metres.mean()), 1),
                           round(float(np.percentile(metres, 90)), 1), round(kmh, 1), round(ep_rew, 2)]
                          + [round(s, 3) for s in shares])
        self.csv_file.flush()
        ends = " ".join(f"{r}={s:.2f}" for r, s in zip(self.reason_names, shares) if s > 0)
        print(f"[{self.run}] {self.num_timesteps / 1e6:.2f}M steps {sps:.0f}/s  episodes {self.ended}  "
              f"m/ep {metres.mean():.0f} (p90 {np.percentile(metres, 90):.0f})  {kmh:.0f} km/h  {ends}", flush=True)

    def save(self) -> None:
        steps = self.num_timesteps
        if steps == getattr(self, "saved_at", -1):
            return
        self.saved_at = steps
        ckpt = self.run_dir / "ckpt"
        ckpt.mkdir(parents=True, exist_ok=True)
        self.model.save(ckpt / f"model_{steps}.zip")
        self.model.get_vec_normalize_env().save(str(ckpt / f"vecnormalize_{steps}.pkl"))
        policy = self.run_dir / "policies" / f"{self.run}_{steps}.json"
        recent = list(self.episodes)[-400:]
        export_policy(self.model, policy, self.raw.hello, {
            **self.meta, "steps": steps,
            "mean_m": round(float(np.mean([e[0] for e in recent])), 1) if recent else 0.0,
            "saved": time.strftime("%Y-%m-%d %H:%M:%S"),
        })
        shutil.copyfile(policy, self.run_dir / "policies" / "latest.json")
        print(f"[{self.run}] saved {policy.name}", flush=True)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--run", required=True, help="run name: tools/rl/runs/<run>")
    p.add_argument("--routes", default="hanami", help="route ids, ':rev' drives one backwards")
    p.add_argument("--procs", type=int, default=4, help="headless Summer workers")
    p.add_argument("--cars", type=int, default=16, help="cars per worker")
    p.add_argument("--car", default="sakura", help="car ids, dealt round-robin to the cars")
    p.add_argument("--steps", type=float, default=20e6, help="total decisions (all cars)")
    p.add_argument("--save-every", type=float, default=500e3)
    p.add_argument("--resume", type=Path, help="a ckpt/model_<steps>.zip to continue from")
    p.add_argument("--threads", type=int, default=2, help="torch CPU threads")
    p.add_argument("--nice", type=int, default=10)
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--episode-s", type=float, default=90.0)
    p.add_argument("--lr", type=float, default=3e-4)
    p.add_argument("--ent", type=float, default=0.01)
    args = p.parse_args()

    torch.set_num_threads(args.threads)
    run_dir = RUNS / args.run
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "args.json").write_text(json.dumps({k: str(v) for k, v in vars(args).items()}, indent=1))
    raw = SakuraVecEnv(procs=args.procs, cars=args.cars, routes=args.routes, car=args.car, seed=args.seed,
                       episode_s=args.episode_s, nice=args.nice, log_dir=run_dir / "logs")
    try:
        env = VecMonitor(raw)
        if args.resume:
            steps = args.resume.stem.split("_")[-1]
            env = VecNormalize.load(str(args.resume.parent / f"vecnormalize_{steps}.pkl"), env)
            model = PPO.load(args.resume, env=env, device="cpu", custom_objects={
                "learning_rate": args.lr, "lr_schedule": lambda _: args.lr, "ent_coef": args.ent})
        else:
            env = VecNormalize(env, norm_obs=False, norm_reward=True, gamma=0.99)
            model = PPO(
                "MlpPolicy", env, n_steps=256, batch_size=4096, n_epochs=5, learning_rate=args.lr,
                gamma=0.99, gae_lambda=0.95, clip_range=0.2, ent_coef=args.ent, vf_coef=0.5,
                max_grad_norm=0.5, seed=args.seed, device="cpu", verbose=0,
                policy_kwargs={"net_arch": {"pi": [128, 128], "vf": [256, 256]}, "activation_fn": torch.nn.Tanh})
            # Prior: the untrained driver mostly presses the throttle and seldom the handbrake.
            # Uniform pedals stall it (brake at a standstill selects reverse, throttle first gear,
            # and it hunts between them), so the first rollouts would teach nothing.
            with torch.no_grad():
                bias = model.policy.action_net.bias
                s = raw.action_dims[0]
                bias[s:s + 3] = torch.tensor([-1.0, 0.0, 1.2])
                bias[s + 3:s + 5] = torch.tensor([1.5, -1.5])
        meta = {"run": args.run, "routes": args.routes, "car": args.car}
        cb = Progress(raw, args.run, run_dir, int(args.save_every), meta)
        model.learn(total_timesteps=int(args.steps), callback=cb, reset_num_timesteps=args.resume is None)
        cb.save()
    finally:
        raw.close()


if __name__ == "__main__":
    main()
