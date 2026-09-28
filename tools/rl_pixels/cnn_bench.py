# /// script
# requires-python = ">=3.12"
# dependencies = ["torch>=2.4", "numpy"]
# ///
"""What a pixel policy costs to run and to train on this Mac: Nature CNN and IMPALA-style encoders
(shared by a policy head over the 7+3+2 action options and a value head, as SB3's CnnPolicy)
at the candidate observation sizes, on the CPU and on the GPU (PyTorch MPS).

Prints one CNNBENCH line per (encoder, input, device): parameters, inference samples/s at the
rollout batch (one decision for every car of the fleet) and training samples/s (forward,
backward and an Adam step) at the PPO minibatch. Random data: speed only.

    uv run --python 3.12 tools/rl_pixels/cnn_bench.py [--threads 2] [--quick]
"""

import argparse
import time

import torch
import torch.nn as nn

ACTIONS = 7 + 3 + 2
EXTRA = 12  # floats beside the image: speed, yaw rate, current inputs, previous action


class Nature(nn.Module):
    """Mnih et al. 2015: 32x8x8/4, 64x4x4/2, 64x3x3/1, FC 512."""

    def __init__(self, c: int, h: int, w: int):
        super().__init__()
        self.conv = nn.Sequential(
            nn.Conv2d(c, 32, 8, 4), nn.ReLU(), nn.Conv2d(32, 64, 4, 2), nn.ReLU(),
            nn.Conv2d(64, 64, 3, 1), nn.ReLU(), nn.Flatten())
        with torch.no_grad():
            n = self.conv(torch.zeros(1, c, h, w)).shape[1]
        self.fc = nn.Sequential(nn.Linear(n, 512), nn.ReLU())
        self.out = 512

    def forward(self, x):
        return self.fc(self.conv(x))


class Small(nn.Module):
    """A lighter encoder for 64 px inputs: 16x5x5/2, 32x3x3/2, 32x3x3/2, 32x3x3/1, FC 256."""

    def __init__(self, c: int, h: int, w: int):
        super().__init__()
        self.conv = nn.Sequential(
            nn.Conv2d(c, 16, 5, 2), nn.ReLU(), nn.Conv2d(16, 32, 3, 2), nn.ReLU(),
            nn.Conv2d(32, 32, 3, 2), nn.ReLU(), nn.Conv2d(32, 32, 3, 1), nn.ReLU(), nn.Flatten())
        with torch.no_grad():
            n = self.conv(torch.zeros(1, c, h, w)).shape[1]
        self.fc = nn.Sequential(nn.Linear(n, 256), nn.ReLU())
        self.out = 256

    def forward(self, x):
        return self.fc(self.conv(x))


class ResBlock(nn.Module):
    def __init__(self, ch: int):
        super().__init__()
        self.c1 = nn.Conv2d(ch, ch, 3, padding=1)
        self.c2 = nn.Conv2d(ch, ch, 3, padding=1)

    def forward(self, x):
        return x + self.c2(torch.relu(self.c1(torch.relu(x))))


class Impala(nn.Module):
    """Espeholt et al. 2018: three stages (16, 32, 32) of conv, max-pool /2, two res blocks; FC 256."""

    def __init__(self, c: int, h: int, w: int):
        super().__init__()
        c_in = c
        layers = []
        for ch in (16, 32, 32):
            layers += [nn.Conv2d(c, ch, 3, padding=1), nn.MaxPool2d(3, 2, padding=1), ResBlock(ch), ResBlock(ch)]
            c = ch
        layers += [nn.ReLU(), nn.Flatten()]
        self.conv = nn.Sequential(*layers)
        with torch.no_grad():
            n = self.conv(torch.zeros(1, c_in, h, w)).shape[1]
        self.fc = nn.Sequential(nn.Linear(n, 256), nn.ReLU())
        self.out = 256

    def forward(self, x):
        return self.fc(self.conv(x))


class Policy(nn.Module):
    def __init__(self, enc: nn.Module):
        super().__init__()
        self.enc = enc
        self.head = nn.Sequential(nn.Linear(enc.out + EXTRA, 256), nn.ReLU())
        self.pi = nn.Linear(256, ACTIONS)
        self.v = nn.Linear(256, 1)

    def forward(self, img, extra):
        h = self.head(torch.cat([self.enc(img.float() / 255.0), extra], 1))
        return self.pi(h), self.v(h)


def sync(dev: str) -> None:
    if dev == "mps":
        torch.mps.synchronize()


def bench(model: nn.Module, dev: str, c: int, h: int, w: int, infer_b: int, train_b: int, reps: int):
    model = model.to(dev)
    img = torch.randint(0, 255, (train_b, c, h, w), dtype=torch.uint8, device=dev)
    extra = torch.randn(train_b, EXTRA, device=dev)
    opt = torch.optim.Adam(model.parameters(), lr=3e-4)
    # inference: the rollout, uint8 frames from the CPU every call
    host = torch.randint(0, 255, (infer_b, c, h, w), dtype=torch.uint8)
    host_x = torch.randn(infer_b, EXTRA)
    with torch.no_grad():
        for _ in range(3):
            model(host.to(dev), host_x.to(dev))[0].cpu()
        t = time.perf_counter()
        for _ in range(reps):
            model(host.to(dev), host_x.to(dev))[0].cpu()
        infer = infer_b * reps / (time.perf_counter() - t)
    # training: forward, a PPO-like loss, backward, Adam
    for i in range(reps + 3):
        if i == 3:
            sync(dev)
            t = time.perf_counter()
        logits, v = model(img, extra)
        loss = logits.logsumexp(1).mean() + v.pow(2).mean()
        opt.zero_grad(set_to_none=True)
        loss.backward()
        nn.utils.clip_grad_norm_(model.parameters(), 0.5)
        opt.step()
    sync(dev)
    train = train_b * reps / (time.perf_counter() - t)
    return infer, train


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--threads", type=int, default=2)
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--infer-batch", type=int, default=64)
    ap.add_argument("--train-batch", type=int, default=1024)
    args = ap.parse_args()
    torch.set_num_threads(args.threads)
    devs = ["cpu"] + (["mps"] if torch.backends.mps.is_available() else [])
    # (name, channels, height, width): 4 stacked grey frames, or 3 stacked RGB frames
    inputs = [("64x64 grey x4", 4, 64, 64), ("64x64 rgb x3", 9, 64, 64), ("96x96 grey x4", 4, 96, 96),
              ("128x72 grey x4", 4, 72, 128), ("160x120 grey x4", 4, 120, 160)]
    encoders = {"small": Small, "nature": Nature, "impala": Impala}
    if args.quick:
        inputs = inputs[:1]
    print(f"torch {torch.__version__} threads {args.threads} devices {devs}")
    for name, c, h, w in inputs:
        for ename, E in encoders.items():
            model = Policy(E(c, h, w))
            params = sum(p.numel() for p in model.parameters())
            for dev in devs:
                reps = 20 if dev == "mps" else 6
                infer, train = bench(model, dev, c, h, w, args.infer_batch, args.train_batch, reps)
                print(f"CNNBENCH input='{name}' enc={ename} params={params/1e6:.2f}M dev={dev} "
                      f"infer_b{args.infer_batch}={infer:.0f}/s train_b{args.train_batch}={train:.0f}/s", flush=True)


if __name__ == "__main__":
    main()
