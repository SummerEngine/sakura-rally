"""Vectorised 2D gradient noise (Perlin) and fractal sums on numpy arrays."""
from __future__ import annotations

import numpy as np

_TWO_PI_OVER_U32 = 2.0 * np.pi / 4294967296.0


def _hash(ix: np.ndarray, iz: np.ndarray, seed: int) -> np.ndarray:
    """32-bit integer hash of lattice coordinates (wraps like C unsigned math)."""
    m = np.uint64(0xFFFFFFFF)
    h = (ix.astype(np.uint64) * np.uint64(374761393)
         + iz.astype(np.uint64) * np.uint64(668265263)
         + np.uint64((seed * 144665 + 1013904223) & 0xFFFFFFFF)) & m
    h = ((h ^ (h >> np.uint64(13))) * np.uint64(1274126177)) & m
    return h ^ (h >> np.uint64(16))


def _fade(t: np.ndarray) -> np.ndarray:
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)


def perlin(x, z, seed: int = 0) -> np.ndarray:
    """Gradient noise in roughly [-1, 1], unit lattice spacing."""
    x = np.asarray(x, dtype=np.float64)
    z = np.asarray(z, dtype=np.float64)
    fx0 = np.floor(x)
    fz0 = np.floor(z)
    ix = fx0.astype(np.int64)
    iz = fz0.astype(np.int64)
    dx = x - fx0
    dz = z - fz0

    def corner(ci, cj, ox, oz):
        a = _hash(ci, cj, seed).astype(np.float64) * _TWO_PI_OVER_U32
        return np.cos(a) * ox + np.sin(a) * oz

    n00 = corner(ix, iz, dx, dz)
    n10 = corner(ix + 1, iz, dx - 1.0, dz)
    n01 = corner(ix, iz + 1, dx, dz - 1.0)
    n11 = corner(ix + 1, iz + 1, dx - 1.0, dz - 1.0)
    u = _fade(dx)
    v = _fade(dz)
    a = n00 + (n10 - n00) * u
    b = n01 + (n11 - n01) * u
    return (a + (b - a) * v) * 1.41421356


def fbm(x, z, scale: float, octaves: int = 4, lacunarity: float = 2.0,
        gain: float = 0.5, seed: int = 0) -> np.ndarray:
    """Fractal sum normalised to roughly [-1, 1]. `scale` = feature size in metres."""
    x = np.asarray(x, dtype=np.float64) / scale
    z = np.asarray(z, dtype=np.float64) / scale
    total = np.zeros(np.broadcast(x, z).shape)
    amp = 1.0
    norm = 0.0
    freq = 1.0
    for o in range(octaves):
        # Rotate each octave a little so lattice axes never line up.
        c, s = np.cos(0.6 * o), np.sin(0.6 * o)
        total += amp * perlin((x * c - z * s) * freq + 17.3 * o, (x * s + z * c) * freq - 9.1 * o, seed + o * 101)
        norm += amp
        amp *= gain
        freq *= lacunarity
    return total / norm


def ridged(x, z, scale: float, octaves: int = 4, seed: int = 0) -> np.ndarray:
    """Ridged multifractal in [0, 1]: sharp crests, useful for mountain ranges."""
    x = np.asarray(x, dtype=np.float64) / scale
    z = np.asarray(z, dtype=np.float64) / scale
    total = np.zeros(np.broadcast(x, z).shape)
    amp = 1.0
    norm = 0.0
    freq = 1.0
    for o in range(octaves):
        n = 1.0 - np.abs(perlin(x * freq + 3.7 * o, z * freq - 5.3 * o, seed + 7 + o * 131))
        total += amp * n * n
        norm += amp
        amp *= 0.5
        freq *= 2.03
    return total / norm


def hash01(*keys: int) -> float:
    """Deterministic scalar in [0, 1) from integers (for per-object randomness)."""
    h = 2166136261
    for k in keys:
        h = ((h ^ (k & 0xFFFFFFFF)) * 16777619) & 0xFFFFFFFF
    h ^= h >> 15
    h = (h * 2246822519) & 0xFFFFFFFF
    h ^= h >> 13
    return h / 4294967296.0
