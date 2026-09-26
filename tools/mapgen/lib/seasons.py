"""Seasons across the world: spring (Hanami), summer (the country between), autumn (Momiji).

Weights follow the distance along one axis (the world origin towards Momiji), wobbled by a
little noise so the boundaries are not straight lines. The same function drives the terrain
relief and palette blend, the scatter rules of each region and the `season_grid` the runtime
reads (u8 x 3 per cell, summing to 255)."""
from __future__ import annotations

import numpy as np

from . import geom, noise

SEASONS = ("spring", "summer", "autumn")


def weights(x, z, cfg: dict, seed: int) -> np.ndarray:
    """(..., 3) spring, summer, autumn weights summing to 1 at world (x, z)."""
    x = np.asarray(x, dtype=np.float64)
    z = np.asarray(z, dtype=np.float64)
    ax, az = cfg["axis"]
    L = float(np.hypot(ax, az))
    t = (x * ax + z * az) / L + noise.fbm(x, z, cfg.get("wobble_scale", 260.0), 3, 2.0, 0.5, seed + 301) * cfg["wobble"]
    spring = 1.0 - geom.smoothstep(cfg["spring_end"][0], cfg["spring_end"][1], t)
    autumn = geom.smoothstep(cfg["autumn_start"][0], cfg["autumn_start"][1], t)
    summer = np.clip(1.0 - spring - autumn, 0.0, 1.0)
    return np.stack([spring, summer, autumn], axis=-1)


def grid(bounds: tuple, cfg: dict, seed: int) -> tuple[np.ndarray, list, float]:
    """The raw season grid over `bounds` (x0, z0, x1, z1): (nz, nx, 3) u8 summing to 255 per
    cell, cell (i, j) centred on origin + (i, j) * cell. Returns (grid, origin [x, z], cell)."""
    cell = float(cfg.get("cell", 8.0))
    x0, z0, x1, z1 = bounds
    xs = np.arange(x0, x1 + cell * 0.5, cell)
    zs = np.arange(z0, z1 + cell * 0.5, cell)
    X, Z = np.meshgrid(xs, zs)
    w = weights(X, Z, cfg, seed)
    q = np.floor(w * 255.0).astype(np.int64)
    # the rounding remainder goes to the strongest season, so every cell sums to exactly 255
    rest = 255 - q.sum(axis=-1)
    top = np.argmax(w, axis=-1)
    np.put_along_axis(q, top[..., None], np.take_along_axis(q, top[..., None], axis=-1) + rest[..., None], axis=-1)
    return q.astype(np.uint8), [float(x0), float(z0)], cell
