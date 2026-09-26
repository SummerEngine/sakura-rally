#!/usr/bin/env python3
"""Anime cumulus atlas for the sky (ported from yamazakura's cloudTexture).

    uv run --with numpy --with pillow python tools/build/gen_clouds.py

Writes assets/textures/clouds.png: 3x2 cells, R = lit (1) vs shade (0),
G = depth into the flat underside, A = coverage. Each puff paints a shade disc,
then a lit disc nudged up-left, bottom-first, so upper bumps overlap lower ones
the way painted clouds do.
"""
from __future__ import annotations

import os

import numpy as np
from PIL import Image

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
W, H = 1536, 512
COLS, ROWS = 3, 2


def disc(xx, yy, cx, cy, r):
    d = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2)
    return np.clip(r - d + 0.75, 0.0, 1.5) / 1.5


def main() -> None:
    rng = np.random.default_rng(900)
    cw, ch = W // COLS, H // ROWS
    R = np.zeros((H, W))
    A = np.zeros((H, W))
    G = np.zeros((H, W))
    yy, xx = np.mgrid[0:ch, 0:cw].astype(np.float64)
    for cell in range(COLS * ROWS):
        ox = (cell % COLS) * cw
        oy = (cell // COLS) * ch
        base = ch * 0.86
        wide = cell >= 4  # the last two cells are long, low stratocumulus
        n = (9 + cell * 2) if not wide else 16
        puffs = []
        for i in range(n):
            t = i / (n - 1)
            x = cw * (0.1 + 0.8 * t) + rng.uniform(-12, 12)
            hump = np.sin(t * np.pi) ** (0.6 if not wide else 1.4)
            r = ch * ((0.1 + 0.15 * hump * rng.uniform(0.75, 1.1)) if not wide else (0.07 + 0.08 * hump * rng.uniform(0.7, 1.2)))
            y = base - r * 0.55 - hump * ch * (rng.uniform(0.08, 0.2) if not wide else rng.uniform(0.02, 0.08))
            puffs.append((x, y, r))
        tops = 0 if wide else 2 + (cell % 3)
        for _ in range(tops):
            px, py, pr = puffs[2 + int(rng.integers(0, len(puffs) - 4))]
            puffs.append((px + rng.uniform(-20, 20), py - pr * rng.uniform(0.5, 0.8), pr * rng.uniform(0.55, 0.75)))
        # keep every puff (and its lit disc, nudged up by 0.2 r) inside the cell
        puffs = [(x, max(y, r * 1.1 + 6.0), r) for (x, y, r) in puffs]
        puffs.sort(key=lambda p: -p[1])
        r_cell = np.zeros((ch, cw))
        a_cell = np.zeros((ch, cw))
        for (px, py, pr) in puffs:
            cy = min(py, base - pr * 0.2)
            sh = disc(xx, yy, px, cy, pr)
            a_cell = np.maximum(a_cell, sh)
            r_cell = r_cell * (1 - sh)  # shade disc paints R = 0 over what is below
            lit = disc(xx, yy, px - pr * 0.14, cy - pr * 0.2, pr * 0.86)
            r_cell = r_cell * (1 - lit) + lit
        # flat base
        cut = np.clip(base - yy + 0.5, 0.0, 1.0)
        a_cell *= cut
        under = np.clip((yy / ch - 0.55) / 0.25, 0.0, 1.0)
        R[oy:oy + ch, ox:ox + cw] = r_cell
        A[oy:oy + ch, ox:ox + cw] = a_cell
        G[oy:oy + ch, ox:ox + cw] = under
    img = np.stack([R, G, np.zeros_like(R), A], axis=2)
    out = os.path.join(REPO, "assets", "textures", "clouds.png")
    Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8), "RGBA").save(out)
    print("CLOUDS", out)


if __name__ == "__main__":
    main()
