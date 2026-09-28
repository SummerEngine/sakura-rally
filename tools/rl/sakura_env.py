"""Sakura Rally as a vectorised stable-baselines3 environment.

Each worker is a headless Summer process running tools/rl/train_env.gd with `cars` cars; every car
is one environment. The protocol is described at the top of train_env.gd. Workers are launched at
low priority (nice) with no window, no audio and no rendering, so training stays out of the way
of whatever else runs on the Mac.
"""

from __future__ import annotations

import json
import os
import socket
import struct
import subprocess
import time
from pathlib import Path

import numpy as np
from gymnasium import spaces
from stable_baselines3.common.vec_env.base_vec_env import VecEnv

SUMMER = os.environ.get("SUMMER_BIN", "/Applications/Summer.app/Contents/MacOS/Summer")
PROJECT = Path(__file__).resolve().parents[2]
STEP, RESET, QUIT = 1, 2, 0


def _recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = bytearray(n)
    view = memoryview(buf)
    got = 0
    while got < n:
        k = sock.recv_into(view[got:], n - got)
        if k == 0:
            raise ConnectionError("worker closed the connection")
        got += k
    return bytes(buf)


class Worker:
    """One headless Summer process and its socket."""

    def __init__(self, index: int, cmd: list[str], log_path: Path):
        self.index = index
        self.log_path = log_path
        self.log = open(log_path, "w")
        self.proc = subprocess.Popen(cmd, stdout=self.log, stderr=subprocess.STDOUT, cwd=PROJECT,
                                     stdin=subprocess.DEVNULL)
        self.sock: socket.socket | None = None
        self.hello: dict = {}

    def tail(self, lines: int = 30) -> str:
        try:
            return "".join(open(self.log_path, errors="replace").readlines()[-lines:])
        except OSError:
            return ""

    def close(self, timeout: float = 10.0) -> None:
        if self.sock is not None:
            try:
                self.sock.sendall(bytes([QUIT]))
            except OSError:
                pass
            self.sock.close()
            self.sock = None
        try:
            self.proc.wait(timeout)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        self.log.close()


class SakuraVecEnv(VecEnv):
    """`procs` workers x `cars` cars. Observations are DriveSense vectors, actions DriveHands
    option indices (MultiDiscrete). A car whose episode ended is already at its next start;
    `infos` carry the finished episode's metres, end reason and route."""

    def __init__(self, procs: int = 4, cars: int = 16, routes: str = "hanami", car: str = "sakura",
                 seed: int = 1, episode_s: float = 90.0, nice: int = 10, log_dir: Path | None = None,
                 timeout: float = 180.0):
        self.cars = cars
        self.timeout = timeout
        log_dir = Path(log_dir or PROJECT / "tools/rl/runs/_logs")
        log_dir.mkdir(parents=True, exist_ok=True)
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", 0))
        server.listen(procs)
        port = server.getsockname()[1]
        self.workers: list[Worker] = []
        for i in range(procs):
            cmd = ["nice", "-n", str(nice), SUMMER, "--headless", "--disable-crash-handler",
                   "--fixed-fps", "120", "--audio-driver", "Dummy", "--path", str(PROJECT),
                   "-s", "res://tools/rl/train_env.gd", "--", f"port={port}", f"id={i}",
                   f"cars={cars}", f"routes={routes}", f"car={car}", f"seed={seed * 1000 + i}",
                   f"episode_s={episode_s}"]
            self.workers.append(Worker(i, cmd, log_dir / f"worker{i}.log"))
        try:
            # Poll once a second: a worker whose script fails to compile never exits, so its log
            # is the only sign.
            server.settimeout(1.0)
            deadline = time.time() + timeout
            connected = 0
            while connected < procs:
                try:
                    sock, _ = server.accept()
                except socket.timeout:
                    for w in self.workers:
                        if w.proc.poll() is not None or "SCRIPT ERROR" in w.tail(200):
                            raise RuntimeError(f"worker {w.index} failed to start")
                    if time.time() > deadline:
                        raise TimeoutError(f"{procs - connected} workers not connected after {timeout:.0f}s")
                    continue
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                sock.settimeout(timeout)
                (size,) = struct.unpack("<I", _recv_exact(sock, 4))
                hello = json.loads(_recv_exact(sock, size))
                w = self.workers[hello["id"]]
                w.sock, w.hello = sock, hello
                connected += 1
        except Exception as e:
            tails = "\n".join(f"--- worker {w.index}\n{w.tail()}" for w in self.workers)
            self.close()
            raise RuntimeError(f"workers did not connect ({e}):\n{tails}") from e
        finally:
            server.close()
        h = self.workers[0].hello
        self.hello = h
        self.obs_size = h["obs_size"]
        self.info_size = h["info_size"]
        self.action_dims = list(h["action_dims"])
        self.reasons = h["reasons"]
        self.route_ids = [r["id"] for r in h["routes"]]
        n = procs * cars
        self._reply = cars * (self.obs_size * 4 + 4 + 1 + self.info_size * 4)
        self._actions: np.ndarray | None = None
        super().__init__(n, spaces.Box(-np.inf, np.inf, (self.obs_size,), np.float32),
                         spaces.MultiDiscrete(self.action_dims))

    # -------------------------------------------------------------- protocol

    def _gather(self):
        obs, rew, flags, info = [], [], [], []
        c, o, k = self.cars, self.obs_size, self.info_size
        for w in self.workers:
            try:
                data = _recv_exact(w.sock, self._reply)
            except (OSError, ConnectionError) as e:
                raise RuntimeError(f"worker {w.index} failed ({e}):\n{w.tail()}") from e
            a = 0
            obs.append(np.frombuffer(data, "<f4", c * o, a).reshape(c, o)); a += c * o * 4
            rew.append(np.frombuffer(data, "<f4", c, a)); a += c * 4
            flags.append(np.frombuffer(data, np.uint8, c, a)); a += c
            info.append(np.frombuffer(data, "<f4", c * k, a).reshape(c, k))
        return (np.concatenate(obs).astype(np.float32), np.concatenate(rew).astype(np.float32),
                np.concatenate(flags), np.concatenate(info))

    def reset(self):
        for w in self.workers:
            w.sock.sendall(bytes([RESET]))
        obs, _, _, info = self._gather()
        self.last_info = info
        return obs

    def step_async(self, actions: np.ndarray) -> None:
        a = np.asarray(actions, dtype=np.uint8).reshape(self.num_envs, len(self.action_dims))
        c = self.cars
        for i, w in enumerate(self.workers):
            w.sock.sendall(bytes([STEP]) + a[i * c:(i + 1) * c].tobytes())

    def step_wait(self):
        obs, rew, flags, info = self._gather()
        self.last_info = info
        dones = flags != 0
        infos = [{} for _ in range(self.num_envs)]
        for i in np.flatnonzero(dones):
            truncated = flags[i] == 2
            infos[i] = {
                "terminal_observation": obs[i].copy(),
                "TimeLimit.truncated": bool(truncated),
                "route": self.route_ids[int(info[i, 0])],
                "episode_m": float(info[i, 1]),
                "reason": self.reasons[int(info[i, 3])],
                "episode_s": float(info[i, 4]),
            }
        return obs, rew, dones, infos

    def close(self) -> None:
        for w in self.workers:
            w.close()

    # -------------------------------------------------------------- VecEnv plumbing

    def get_attr(self, attr_name, indices=None):
        return [getattr(self, attr_name, None)] * len(self._get_indices(indices))

    def set_attr(self, attr_name, value, indices=None):
        setattr(self, attr_name, value)

    def env_method(self, method_name, *args, indices=None, **kwargs):
        return [None] * len(self._get_indices(indices))

    def env_is_wrapped(self, wrapper_class, indices=None):
        return [False] * len(self._get_indices(indices))

    def seed(self, seed=None):
        return [None] * self.num_envs


def export_policy(model, path: Path, hello: dict, meta: dict) -> None:
    """Writes the policy half of an SB3 PPO MlpPolicy as a DrivePolicy JSON file, with a test
    observation and its logits so the GDScript forward pass can be checked against torch."""
    import torch

    pol = model.policy
    layers = []
    for m in pol.mlp_extractor.policy_net:
        if isinstance(m, torch.nn.Linear):
            layers.append(_linear(m))
        elif not isinstance(m, torch.nn.Tanh):
            raise ValueError(f"DrivePolicy only runs Linear+Tanh layers, found {m}")
    rng = np.random.default_rng(0)
    test_obs = rng.normal(0.0, 0.5, hello["obs_size"]).astype(np.float32)
    with torch.no_grad():
        x = torch.as_tensor(test_obs)[None]
        latent = pol.mlp_extractor.forward_actor(pol.extract_features(x, pol.pi_features_extractor))
        logits = pol.action_net(latent)[0].numpy()
    doc = {
        "format": "sakura-drive-policy",
        "sense_version": hello["sense_version"],
        "obs_size": hello["obs_size"],
        "action_dims": hello["action_dims"],
        "layers": layers,
        "head": _linear(pol.action_net),
        "meta": {**meta, "test_obs": _floats(test_obs), "test_logits": _floats(logits)},
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(doc, separators=(",", ":"), default=lambda o: o.item()))
    tmp.replace(path)


def _linear(m) -> dict:
    return {"in": m.in_features, "out": m.out_features,
            "w": _floats(m.weight.detach().cpu().numpy().reshape(-1)),
            "b": _floats(m.bias.detach().cpu().numpy())}


def _floats(a) -> list[float]:
    return [float(f"{v:.7g}") for v in np.asarray(a, dtype=np.float64)]
