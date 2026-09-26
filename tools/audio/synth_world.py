"""Offline synthesis of the car's world sounds: tyres, wind, stones, thumps, impacts, horn.

Outputs 44.1 kHz mono 16-bit WAV into assets/audio/car/:
  tyre_roll_{tarmac,gravel,dirt,grass}.wav     seamless rolling loops (reference ~60 km/h)
  tyre_slide_{tarmac,gravel,dirt}.wav          seamless slide loops (squeal / spray / scrub)
  wind.wav                                     seamless wind-noise loop
  horn.wav                                     seamless dual-tone horn loop (415 + 523 Hz)
  stone_1..6.wav                               gravel stones ticking on the underbody
  thump_1..3.wav                               suspension bottoming / landing thumps
  impact_light_1..3.wav, impact_heavy_1..3.wav collision one-shots

Loops are built circularly (events wrap across the seam, filters run to steady state).
Run: tools/audio/.venv/bin/python tools/audio/synth_world.py
"""

from __future__ import annotations

import math

import numpy as np

import audiolib as al

OUT = al.ASSETS / "car"
SR = al.SR


def norm(x: np.ndarray) -> np.ndarray:
    return x / (np.std(x) + 1e-12)


def grains_circular(n: int, r: np.random.Generator, rate: float, f_lo: float, f_hi: float,
                    len_ms: tuple[float, float], amp_shape: float = 2.5) -> np.ndarray:
    """Dense granular crunch: many tiny band-limited noise bursts placed circularly.
    Grains are grouped into a few frequency bands so filtering stays cheap."""
    y = np.zeros(n)
    bands = np.geomspace(f_lo, f_hi, 6)
    count = r.poisson(rate * n / SR)
    band_of = r.integers(0, bands.size - 1, count)
    for b in range(bands.size - 1):
        layer = np.zeros(n)
        for _ in range(int(np.sum(band_of == b))):
            ln = max(8, int(r.uniform(*len_ms) * 1e-3 * SR))
            start = r.integers(0, n)
            a = r.pareto(amp_shape) + 0.2
            g = r.standard_normal(ln) * np.exp(-np.linspace(0, 6, ln))
            layer[(start + np.arange(ln)) % n] += a * g
        y += al.filt_circular(al.sos_bp(bands[b], bands[b + 1], 2), layer)
    return norm(y)


def periodic_noise_lfo(n: int, r: np.random.Generator, cycles_max: int, depth: float) -> np.ndarray:
    t = np.arange(n) / n
    y = np.zeros(n)
    for k in range(1, cycles_max + 1):
        y += r.uniform(0.2, 1.0) / math.sqrt(k) * np.sin(2 * math.pi * k * t + r.uniform(0, 6.28))
    y /= np.max(np.abs(y)) + 1e-12
    return np.clip(1.0 + depth * y, 0.0, None)


# ======================================================================== rolling loops

def roll_tarmac(n: int, r: np.random.Generator) -> np.ndarray:
    rumble = norm(al.filt_circular(np.vstack([al.sos_hp(35.0, 2), al.sos_lp(320.0, 2)]), al.brown_circular(n, r)))
    whirr = norm(al.filt_circular(np.vstack([al.sos_bp(500.0, 1600.0, 2), al.peak_eq(850.0, 2.0, 4.0)]), al.white(n, r)))
    t = np.arange(n) / SR
    tread = 1.0 + 0.25 * np.sin(2 * math.pi * round(38.0 * n / SR) / (n / SR) * t)
    hiss = norm(al.filt_circular(al.sos_bp(2500.0, 7000.0, 2), al.white(n, r)))
    return rumble * 1.0 + 0.35 * whirr * tread + 0.08 * hiss


def roll_gravel(n: int, r: np.random.Generator) -> np.ndarray:
    crunch = grains_circular(n, r, 1400.0, 700.0, 7000.0, (0.4, 2.5))
    big = grains_circular(n, r, 90.0, 300.0, 2500.0, (2.0, 6.0), 2.0)
    rumble = norm(al.filt_circular(np.vstack([al.sos_hp(30.0, 2), al.sos_lp(220.0, 2)]), al.brown_circular(n, r)))
    sh = norm(al.filt_circular(al.sos_bp(2500.0, 8000.0, 2), al.white(n, r)))
    return 0.9 * crunch * periodic_noise_lfo(n, r, 7, 0.3) + 0.45 * big + 0.8 * rumble + 0.12 * sh


def roll_dirt(n: int, r: np.random.Generator) -> np.ndarray:
    crunch = grains_circular(n, r, 500.0, 300.0, 2600.0, (1.0, 4.0))
    rumble = norm(al.filt_circular(np.vstack([al.sos_hp(28.0, 2), al.sos_lp(260.0, 2)]), al.brown_circular(n, r)))
    mud = norm(al.filt_circular(al.sos_bp(250.0, 1200.0, 2), al.white(n, r)))
    return 0.55 * crunch + 1.0 * rumble + 0.3 * mud * periodic_noise_lfo(n, r, 6, 0.4)


def roll_grass(n: int, r: np.random.Generator) -> np.ndarray:
    swish = norm(al.filt_circular(np.vstack([al.sos_bp(1200.0, 9000.0, 2), al.peak_eq(3500.0, 1.0, 3.0)]), al.white(n, r)))
    swish *= periodic_noise_lfo(n, r, 12, 0.55)
    rumble = norm(al.filt_circular(np.vstack([al.sos_hp(30.0, 2), al.sos_lp(180.0, 2)]), al.brown_circular(n, r)))
    blades = grains_circular(n, r, 250.0, 1500.0, 6000.0, (2.0, 8.0))
    return 0.8 * swish + 0.6 * rumble + 0.25 * blades


# ======================================================================== slide loops

def slide_tarmac(n: int, r: np.random.Generator) -> np.ndarray:
    """Tyre squeal: a cluster of jittering tonal partials (stick-slip) over rubber scrub."""
    per = n / SR
    t = np.arange(n) / SR
    y = np.zeros(n)
    for base, amp in ((780.0, 1.0), (1030.0, 0.55), (1340.0, 0.3)):
        # periodic smooth random frequency wander (sum of integer-cycle sinusoids)
        wander = np.zeros(n)
        for k in range(1, 18):
            wander += r.normal(0, 1.0) / k ** 1.1 * np.sin(2 * math.pi * k * t / per + r.uniform(0, 6.28))
        wander = wander / (np.max(np.abs(wander)) + 1e-12) * 0.035
        f0 = round(base * per) / per
        inst = f0 * (1.0 + wander)
        ph = 2 * math.pi * np.cumsum(inst) / SR
        # close the phase exactly over the loop (integer cycles)
        cyc = ph[-1] / (2 * math.pi)
        ph *= round(cyc) / cyc
        am = periodic_noise_lfo(n, r, 25, 0.6)
        y += amp * am * (np.sin(ph) + 0.35 * np.sin(2 * ph) + 0.12 * np.sin(3 * ph))
    scrub = norm(al.filt_circular(al.sos_bp(300.0, 3500.0, 2), al.white(n, r)))
    return norm(y) + 0.35 * scrub


def slide_gravel(n: int, r: np.random.Generator) -> np.ndarray:
    spray = grains_circular(n, r, 3200.0, 900.0, 9000.0, (0.3, 2.0), 2.2)
    stones = grains_circular(n, r, 160.0, 400.0, 3500.0, (2.0, 7.0), 1.8)
    hiss = norm(al.filt_circular(np.vstack([al.sos_bp(1500.0, 9000.0, 2)]), al.white(n, r)))
    scrub = norm(al.filt_circular(np.vstack([al.sos_hp(40.0, 2), al.sos_lp(500.0, 2)]), al.brown_circular(n, r)))
    return (0.9 * spray * periodic_noise_lfo(n, r, 9, 0.35) + 0.5 * stones + 0.45 * hiss
            * periodic_noise_lfo(n, r, 5, 0.3) + 0.7 * scrub)


def slide_dirt(n: int, r: np.random.Generator) -> np.ndarray:
    scrub = norm(al.filt_circular(np.vstack([al.sos_bp(180.0, 2200.0, 2), al.peak_eq(600.0, 1.2, 4.0)]), al.white(n, r)))
    clods = grains_circular(n, r, 700.0, 250.0, 3000.0, (1.5, 6.0))
    rumble = norm(al.filt_circular(np.vstack([al.sos_hp(30.0, 2), al.sos_lp(300.0, 2)]), al.brown_circular(n, r)))
    return 0.8 * scrub * periodic_noise_lfo(n, r, 8, 0.4) + 0.55 * clods + 0.6 * rumble


def wind(n: int, r: np.random.Generator) -> np.ndarray:
    """Wind rush past the body: pink noise, slowly sweeping band, gusts (all periodic)."""
    base = al.pink_circular(n, r)
    lo = norm(al.filt_circular(np.vstack([al.sos_hp(60.0, 2), al.sos_lp(700.0, 2)]), base))
    mid = norm(al.filt_circular(al.sos_bp(500.0, 2500.0, 2), base))
    hi = norm(al.filt_circular(al.sos_bp(2500.0, 9000.0, 2), al.white(n, r)))
    g1 = periodic_noise_lfo(n, r, 4, 0.35)
    g2 = periodic_noise_lfo(n, r, 7, 0.4)
    whistle_t = np.arange(n) / SR
    per = n / SR
    wf = round(1450.0 * per) / per
    whistle = np.sin(2 * math.pi * wf * whistle_t) * periodic_noise_lfo(n, r, 6, 0.9) * 0.06
    return 1.0 * lo * g1 + 0.55 * mid * g2 + 0.18 * hi * g2 + whistle


def horn(n: int) -> np.ndarray:
    """Cheerful dual-tone horn (415 + 523 Hz, a major third): buzzy diaphragm + bell formant."""
    t = np.arange(n) / SR
    y = np.zeros(n)
    for f0, a in ((415.0, 1.0), (523.0, 0.85)):
        for h in range(1, 16):
            y += a * (0.9 ** h) / h ** 0.6 * np.sin(2 * math.pi * f0 * h * t + h * 0.7)
    y = al.filt_circular(np.vstack([al.sos_hp(300.0, 2), al.peak_eq(2300.0, 1.5, 6.0),
                                    al.peak_eq(900.0, 1.0, 3.0), al.sos_lp(5500.0, 2)]), y)
    return np.tanh(1.8 * norm(y) * 0.5)


# ======================================================================== one-shots

def stone(r: np.random.Generator) -> np.ndarray:
    dur = 0.12
    base = r.uniform(0.8, 1.3)
    freqs = np.array([1850.0, 2930.0, 4100.0, 5600.0]) * base * r.uniform(0.95, 1.05, 4)
    y = al.modal(freqs, r.uniform(0.004, 0.018, 4), r.uniform(0.3, 1.0, 4), dur, r)
    n = y.size
    t = np.arange(n) / SR
    tick = al.filt(al.sos_hp(2500.0, 2), al.white(n, r)) * np.exp(-t / 0.0008)
    thud = np.sin(2 * math.pi * r.uniform(280, 420) * t) * np.exp(-t / 0.01)
    return al.fade_edges(y + 0.8 * tick / (np.max(np.abs(tick)) + 1e-12) + 0.3 * thud, 0.0003, 0.02)


def thump(r: np.random.Generator) -> np.ndarray:
    dur = 0.45
    n = int(dur * SR)
    t = np.arange(n) / SR
    f = r.uniform(52.0, 72.0) * (1.0 + 0.5 * np.exp(-t / 0.02))
    low = np.sin(2 * math.pi * np.cumsum(f) / SR) * np.exp(-t / r.uniform(0.07, 0.1))
    strut = al.modal(np.array([310.0, 540.0, 880.0]) * r.uniform(0.9, 1.1), [0.03, 0.02, 0.012],
                     [0.5, 0.35, 0.2], dur, r)
    rattle = al.filt(al.sos_bp(1200.0, 5000.0, 2), al.white(n, r)) * np.exp(-t / 0.03)
    y = 1.0 * low + 0.45 * strut + 0.15 * rattle / (np.max(np.abs(rattle)) + 1e-12)
    return al.trim_tail(al.fade_edges(y, 0.001, 0.05), -60.0)


def impact_light(r: np.random.Generator) -> np.ndarray:
    dur = 0.5
    n = int(dur * SR)
    t = np.arange(n) / SR
    knock = al.modal(np.array([420.0, 780.0, 1310.0, 2150.0]) * r.uniform(0.85, 1.15),
                     [0.04, 0.025, 0.015, 0.008], [1.0, 0.6, 0.4, 0.25], dur, r)
    plastic = al.filt(al.sos_bp(800.0, 4000.0, 2), al.white(n, r)) * np.exp(-t / 0.012)
    body = np.sin(2 * math.pi * r.uniform(90, 130) * t) * np.exp(-t / 0.05)
    scrape = al.filt(al.sos_bp(1500.0, 6000.0, 2), al.white(n, r)) * al.env_ad(n, 0.02, 0.12, 3) * 0.25
    y = knock + 0.5 * plastic / (np.max(np.abs(plastic)) + 1e-12) + 0.7 * body + scrape / (np.max(np.abs(scrape)) + 1e-12) * 0.25
    return al.trim_tail(al.fade_edges(y, 0.0005, 0.05), -60.0)


def impact_heavy(r: np.random.Generator) -> np.ndarray:
    dur = 1.3
    n = int(dur * SR)
    t = np.arange(n) / SR
    f = r.uniform(45.0, 60.0) * (1.0 + 0.8 * np.exp(-t / 0.03))
    boom = np.sin(2 * math.pi * np.cumsum(f) / SR) * np.exp(-t / 0.16)
    crunch_src = grains_circular(n, r, 2500.0, 400.0, 6000.0, (0.5, 3.0), 1.8)
    crunch = crunch_src * al.env_ad(n, 0.002, 0.3, 3.5)
    metal = al.modal(np.array([260.0, 437.0, 690.0, 1130.0, 1720.0, 2600.0]) * r.uniform(0.9, 1.1),
                     [0.09, 0.07, 0.05, 0.04, 0.03, 0.02], [0.7, 0.6, 0.5, 0.35, 0.25, 0.2], dur, r)
    debris = np.zeros(n)
    for _ in range(int(r.integers(5, 10))):
        s = int(r.uniform(0.08, 0.9) * SR)
        piece = stone(r) * r.uniform(0.1, 0.35)
        e = min(n, s + piece.size)
        debris[s:e] += piece[: e - s]
    y = 1.2 * boom + 0.55 * crunch + 0.35 * metal * np.minimum(1.0, t / 0.002) + debris
    y = np.tanh(2.6 * y / (np.max(np.abs(y)) + 1e-12))
    return al.trim_tail(al.fade_edges(y, 0.0005, 0.1), -60.0)


# ======================================================================== main

def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    loop_n = int(3.0 * SR)
    loops = {
        "tyre_roll_tarmac": (roll_tarmac, -14.0),
        "tyre_roll_gravel": (roll_gravel, -13.0),
        "tyre_roll_dirt": (roll_dirt, -13.5),
        "tyre_roll_grass": (roll_grass, -15.0),
        "tyre_slide_tarmac": (slide_tarmac, -13.0),
        "tyre_slide_gravel": (slide_gravel, -12.0),
        "tyre_slide_dirt": (slide_dirt, -12.5),
    }
    for i, (name, (fn, target)) in enumerate(loops.items()):
        x = fn(loop_n, al.rng(500 + i))
        x -= np.mean(x)
        y = al.soft_limit(al.normalize_lufs(x, target, peak_ceiling_db=-1.0), -1.0, 1.5)
        al.write_wav(OUT / f"{name}.wav", y)
    w = wind(int(6.0 * SR), al.rng(600))
    al.write_wav(OUT / "wind.wav", al.soft_limit(al.normalize_lufs(w - np.mean(w), -16.0), -1.0, 1.5))
    al.write_wav(OUT / "horn.wav", al.normalize_peak(horn(int(1.0 * SR)), -3.0))
    r = al.rng(700)
    for i in range(6):
        al.write_wav(OUT / f"stone_{i + 1}.wav", al.normalize_peak(stone(r), -1.0))
    for i in range(3):
        al.write_wav(OUT / f"thump_{i + 1}.wav", al.normalize_peak(thump(r), -1.0))
        al.write_wav(OUT / f"impact_light_{i + 1}.wav", al.normalize_peak(impact_light(r), -1.0))
        al.write_wav(OUT / f"impact_heavy_{i + 1}.wav", al.normalize_peak(impact_heavy(r), -1.0))


if __name__ == "__main__":
    main()
