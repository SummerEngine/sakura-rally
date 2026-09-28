"""Sakura Rally from pixels: tools/rl_pixels/pixel_env.gd workers as one batch of cars.

Each worker is the agents' dev build of Summer rendering offscreen (--summer-offscreen: it needs
pixels; never the installed Summer, never a window), running pixel_env.gd with `cars` cars. Every
step returns each car's hood-camera frame (uint8, H x W x 3), its DriveSense vector (the
privileged observation: what the geometry teacher and the critic see), its reward, end flag and
info, as tools/rl/train_env.gd describes. `looks`, `routes` and `seasons` given as lists go to
the workers in turn (looks: lean, no sun shadows; shade, with them).
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "rl"))
from sakura_env import PROJECT, QUIT, RESET, STEP, _recv_exact, start_workers  # noqa: E402,F401

DEV = os.environ.get("SUMMER_DEV_BIN", str(Path.home() / "opt/summer-dev/SummerDev.app/Contents/MacOS/Summer"))


class PixelEnv:
    def __init__(self, procs: int = 6, cars: int = 16, routes: str | list[str] = "hanami,hanami:rev",
                 car: str = "sakura,hayate", seed: int = 1, episode_s: float = 90.0,
                 looks: tuple[str, ...] = ("lean", "shade"), seasons: str | list[str] = "random",
                 mode: str = "train", eval_cars: int = 2, nice: int = 10, log_dir: Path | None = None,
                 timeout: float = 300.0, extra: dict | None = None):
        """`extra`: more pixel_env.gd options for every worker (e.g. replays=<dir>)."""
        log_dir = Path(log_dir or PROJECT / "tools/rl/runs/_logs")
        routes = [routes] if isinstance(routes, str) else list(routes)
        seasons = [seasons] if isinstance(seasons, str) else list(seasons)
        more = [f"{k}={v}" for k, v in (extra or {}).items()]

        def cmd(port: int, i: int) -> list[str]:
            return ["nice", "-n", str(nice), DEV, "--summer-offscreen", "--audio-driver", "Dummy",
                    "--disable-crash-handler", "--fixed-fps", "10", "--path", str(PROJECT),
                    "-s", "res://tools/rl_pixels/pixel_env.gd", "--", f"port={port}", f"id={i}",
                    f"cars={cars}", f"routes={routes[i % len(routes)]}", f"car={car}",
                    f"seed={seed * 1000 + i}", f"episode_s={episode_s}", f"look={looks[i % len(looks)]}",
                    f"seasons={seasons[i % len(seasons)]}", f"mode={mode}", f"eval_cars={eval_cars}"] + more

        self.workers = start_workers(procs, cmd, log_dir, timeout)
        h = self.workers[0].hello
        self.hello = h
        self.cars = h["cars"]
        self.n = procs * self.cars
        self.obs_size = h["obs_size"]
        self.info_size = h["info_size"]
        self.action_dims = list(h["action_dims"])
        self.reasons = h["reasons"]
        # route ids of every car's worker: info's route index is per worker
        self.worker_routes = [[r["id"] for r in w.hello["routes"]] for w in self.workers]
        self.lengths = {r["id"]: r["length"] for w in self.workers for r in w.hello["routes"]}
        self.h, self.w, _ = h["image"]
        self.rows, self.cols = h["atlas"]
        c = self.cars
        self._floats = c * (self.obs_size * 4 + 4 + 1 + self.info_size * 4)
        self._pixels = self.rows * self.h * self.cols * self.w * 3

    def route(self, k: int, info_row: np.ndarray) -> str:
        """Route id of car k from its info row (the route index counts in its worker's routes)."""
        return self.worker_routes[k // self.cars][int(info_row[0])]

    def _gather(self):
        c, o, k = self.cars, self.obs_size, self.info_size
        imgs, obs, rew, flags, info = [], [], [], [], []
        for w in self.workers:
            try:
                data = _recv_exact(w.sock, self._floats + self._pixels)
            except (OSError, ConnectionError) as e:
                raise RuntimeError(f"worker {w.index} failed ({e}):\n{w.tail()}") from e
            a = 0
            obs.append(np.frombuffer(data, "<f4", c * o, a).reshape(c, o)); a += c * o * 4
            rew.append(np.frombuffer(data, "<f4", c, a)); a += c * 4
            flags.append(np.frombuffer(data, np.uint8, c, a)); a += c
            info.append(np.frombuffer(data, "<f4", c * k, a).reshape(c, k)); a += c * k * 4
            atlas = np.frombuffer(data, np.uint8, self._pixels, a).reshape(self.rows, self.h, self.cols, self.w, 3)
            imgs.append(atlas.transpose(0, 2, 1, 3, 4).reshape(-1, self.h, self.w, 3)[:c])
        return (np.concatenate(imgs), np.concatenate(obs).astype(np.float32),
                np.concatenate(rew).astype(np.float32), np.concatenate(flags), np.concatenate(info))

    def reset(self):
        """Every car to a new start: (frames, DriveSense vectors, flags, info)."""
        for w in self.workers:
            w.sock.sendall(bytes([RESET]))
        img, obs, _, flags, info = self._gather()
        return img, obs, flags, info

    def send(self, actions: np.ndarray) -> None:
        """Starts one decision for every car (actions: n x len(action_dims) option indices); the
        workers drive it while the caller works, recv() collects it."""
        a = np.asarray(actions, dtype=np.uint8).reshape(self.n, len(self.action_dims))
        c = self.cars
        for i, w in enumerate(self.workers):
            w.sock.sendall(bytes([STEP]) + a[i * c:(i + 1) * c].tobytes())

    def recv(self):
        """(frames, DriveSense vectors, rewards, flags, info) after the decision send() started."""
        return self._gather()

    def step(self, actions: np.ndarray):
        self.send(actions)
        return self._gather()

    def close(self) -> None:
        for w in self.workers:
            w.close()
