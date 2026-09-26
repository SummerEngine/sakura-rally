"""Instrument voices for the synthesised Sakura Rally UI clicks and stingers.

Deterministic (seeded) physical-ish models: wood/bamboo modal taps, taiko membrane,
Karplus-Strong koto with body resonance, rin bell, breathy shakuhachi, and a small
synthetic stereo room reverb. Builds on audiolib; audiolib itself is not modified.
"""

from __future__ import annotations

import math

import numpy as np
from scipy import signal

from audiolib import SR, filt, fade_edges, peak_eq, resonator, rng, sos_bp, sos_hp, sos_lp

# ----------------------------------------------------------------- pitch

A4 = 440.0
NOTE = {"C": -9, "C#": -8, "D": -7, "D#": -6, "E": -5, "F": -4, "F#": -3, "G": -2,
        "G#": -1, "A": 0, "A#": 1, "B": 2}


def hz(name: str) -> float:
    """'D5' -> Hz (sharps only)."""
    pc, octv = name[:-1], int(name[-1])
    return A4 * 2 ** ((NOTE[pc] + 12 * (octv - 4)) / 12)


def shift(f: float, semis: float) -> float:
    return f * 2 ** (semis / 12)


# ----------------------------------------------------------------- helpers

def blank(dur: float) -> np.ndarray:
    return np.zeros(int(dur * SR))


def place(buf: np.ndarray, x: np.ndarray, t: float, gain: float = 1.0) -> np.ndarray:
    """Add x into buf (mono or stereo (n,2)) at time t, clipping to buf length."""
    i = int(round(t * SR))
    if i >= len(buf):
        return buf
    n = min(len(x), len(buf) - i)
    buf[i:i + n] += gain * x[:n]
    return buf


def pan(x: np.ndarray, p: float) -> np.ndarray:
    """Equal-power pan of mono x; p in [-1, 1]."""
    a = (p + 1) * math.pi / 4
    return np.stack([x * math.cos(a), x * math.sin(a)], axis=1)


def burst(n_s: float, lo: float, hi: float, seed: int, decay_s: float | None = None) -> np.ndarray:
    """Band-limited noise burst (mallet / plectrum contact)."""
    n = max(8, int(n_s * SR))
    x = filt(sos_bp(lo, hi, 2), rng(seed).standard_normal(n))
    t = np.arange(n) / SR
    env = np.exp(-t / (decay_s or n_s / 4))
    env[: max(1, int(0.0004 * SR))] *= np.linspace(0, 1, max(1, int(0.0004 * SR)))
    return x * env


def modal_t(freqs, decays, amps, dur: float, attack_s: float = 0.0005, phases=None) -> np.ndarray:
    n = int(dur * SR)
    t = np.arange(n) / SR
    y = np.zeros(n)
    for k, (f, d, a) in enumerate(zip(freqs, decays, amps)):
        if f >= SR * 0.45:
            continue
        ph = 0.0 if phases is None else phases[k]
        y += a * np.sin(2 * math.pi * f * t + ph) * np.exp(-t / d)
    if attack_s > 0:
        na = int(attack_s * SR)
        y[:na] *= np.sin(np.linspace(0, math.pi / 2, na)) ** 2
    return y


# ----------------------------------------------------------------- wood / bamboo

def wood_tap(f0: float, dur: float = 0.12, hardness: float = 0.5, damp: float = 1.0,
             seed: int = 1) -> np.ndarray:
    """Hollow wood block 'kon': free-bar modes + mallet contact + cavity body."""
    ratios = [1.0, 2.76, 5.40, 8.93]
    decays = [0.045 * damp, 0.018 * damp, 0.009 * damp, 0.005 * damp]
    amps = [1.0, 0.35 * (0.5 + hardness), 0.14 * (0.3 + hardness), 0.06 * hardness]
    y = modal_t([f0 * r for r in ratios], decays, amps, dur, attack_s=0.0006)
    # cavity (Helmholtz-ish) resonance below the bar: gives the hollow "o"
    y += modal_t([f0 * 0.52], [0.030 * damp], [0.35], dur, attack_s=0.0015)
    click = burst(0.004, 1500 + 3000 * hardness, 9000, seed, 0.0008)
    y[: click.size] += 0.25 * (0.4 + hardness) * click
    return y


def bamboo_tap(f0: float, dur: float = 0.1, seed: int = 2, damp: float = 1.0) -> np.ndarray:
    """Bamboo tube tap: near-harmonic odd-ish partials, slightly airy, fast decay."""
    ratios = [1.0, 2.01, 3.03, 4.1]
    decays = [0.030 * damp, 0.016 * damp, 0.010 * damp, 0.006 * damp]
    amps = [1.0, 0.28, 0.22, 0.08]
    y = modal_t([f0 * r for r in ratios], decays, amps, dur, attack_s=0.0005)
    air = filt(resonator(f0, 12), rng(seed).standard_normal(int(dur * SR)))
    air *= np.exp(-np.arange(air.size) / SR / (0.012 * damp)) * 0.18
    y += air
    click = burst(0.003, 3000, 10000, seed + 7, 0.0006)
    y[: click.size] += 0.18 * click
    return y


def hyoshigi(f0: float = 2100.0, dur: float = 0.18, seed: int = 3) -> np.ndarray:
    """Hard wooden clapper strike: bright, dry, a touch of resonance."""
    y = modal_t([f0, f0 * 1.51, f0 * 2.37, f0 * 3.3], [0.035, 0.020, 0.012, 0.007],
                [1.0, 0.55, 0.3, 0.15], dur, attack_s=0.0004)
    y += modal_t([f0 * 0.31], [0.02], [0.3], dur, attack_s=0.001)
    click = burst(0.003, 2500, 12000, seed, 0.0006)
    y[: click.size] += 0.4 * click
    return y


# ----------------------------------------------------------------- bell

RIN_RATIOS = [1.0, 2.74, 5.12, 8.18, 11.9]


def rin(f0: float, dur: float = 2.0, decay: float = 1.4, bright: float = 0.6,
        seed: int = 4) -> np.ndarray:
    """Rin (Buddhist bowl bell): inharmonic partials in slightly detuned pairs (beating)."""
    r = rng(seed)
    freqs, decs, amps, phs = [], [], [], []
    base_amps = [1.0, 0.55 * bright + 0.1, 0.32 * bright, 0.16 * bright, 0.08 * bright]
    for k, (ratio, a) in enumerate(zip(RIN_RATIOS, base_amps)):
        f = f0 * ratio
        beat = 0.6 + 0.9 * k
        d = decay / (1 + 0.9 * k)
        for s in (-0.5, 0.5):
            freqs.append(f + s * beat)
            decs.append(d)
            amps.append(a * 0.5)
            phs.append(r.uniform(0, 2 * math.pi))
    y = modal_t(freqs, decs, amps, dur, attack_s=0.0008, phases=phs)
    strike = burst(0.003, 2000, 11000, seed + 3, 0.0007)
    y[: strike.size] += 0.12 * strike
    return fade_edges(y, 0.0, 0.25 * dur)


# ----------------------------------------------------------------- taiko

MEMBRANE = [1.0, 1.59, 2.14, 2.30, 2.65, 2.92, 3.16, 3.50]


def taiko(f0: float = 72.0, dur: float = 1.2, force: float = 1.0, seed: int = 5,
          rim: float = 0.0) -> np.ndarray:
    """Taiko 'don': pitch-dropping membrane fundamental, damped upper modes, stick attack,
    shell/body boom. force 0..1 scales brightness and pitch glide."""
    n = int(dur * SR)
    t = np.arange(n) / SR
    glide = 1.0 + 0.22 * force * np.exp(-t / 0.045)
    ph = 2 * math.pi * np.cumsum(f0 * glide) / SR
    y = np.sin(ph) * np.exp(-t / (0.32 + 0.12 * force))
    y += 0.5 * np.sin(2 * ph * 0.998 + 0.3) * np.exp(-t / 0.12) * (0.5 + 0.5 * force)
    r = rng(seed)
    for k, m in enumerate(MEMBRANE[1:], start=1):
        f = f0 * m * (1.0 + 0.08 * force * np.exp(-t / 0.03))
        ph_k = 2 * math.pi * np.cumsum(f) / SR + r.uniform(0, 6.28)
        y += (0.45 / k) * (0.4 + force) * np.sin(ph_k) * np.exp(-t / (0.07 / (1 + 0.3 * k)))
    # stick attack: lowpassed thump + skin slap
    thump = filt(sos_lp(900 + 1600 * force, 2), r.standard_normal(n)) * np.exp(-t / 0.010)
    slap = filt(sos_bp(1200, 5000, 2), r.standard_normal(n)) * np.exp(-t / 0.004)
    y += (0.9 * force + 0.3) * thump * 1.6 + 0.35 * force * slap
    if rim > 0:
        y += rim * hyoshigi(1700.0, dur, seed + 11)[:n] * 0.6
    na = int(0.0008 * SR)
    y[:na] *= np.linspace(0, 1, na)
    return fade_edges(y, 0.0, 0.3 * dur)  # never end on a truncated tail


# ----------------------------------------------------------------- koto (Karplus-Strong)

def koto(f0: float, dur: float = 2.0, bright: float = 0.7, decay_s: float = 1.6,
         pluck_pos: float = 0.18, seed: int = 6, bend: float = 0.0) -> np.ndarray:
    """Extended Karplus-Strong: plectrum-bright excitation, pluck-position comb, allpass
    fractional delay, frequency-dependent loop loss tuned to decay_s, bridge/body resonances.
    bend: semitones of initial upward pitch (oshide-like) relaxing to f0 over 120 ms."""
    n = int(dur * SR)
    r = rng(seed)
    # delay length per sample (supports a gentle pitch bend)
    t = np.arange(n) / SR
    f_t = f0 * 2 ** ((bend * np.exp(-t / 0.12)) / 12)
    period = SR / f_t
    N0 = int(period[0]) + 2
    # excitation: short bright noise burst shaped by plectrum hardness
    exc = r.uniform(-1, 1, N0)
    exc = filt(sos_lp(2000 + 9000 * bright, 1), exc)
    exc -= exc.mean()
    # pluck-position comb (removes harmonics at multiples of 1/pluck_pos)
    d = max(1, int(pluck_pos * N0))
    exc[d:] -= exc[:-d]
    # loop filter: one-zero lowpass (1-s) x[n] + s x[n-1] (delay s samples); loop gain g per
    # period sets the decay. Total loop delay = integer delay + allpass delay + s = period.
    s = 0.5 - 0.35 * bright
    g = 10 ** (-3.0 / (decay_s * f0))  # -60 dB after decay_s
    buf = np.zeros(n + N0 + 4)
    buf[:N0] = exc
    prev = 0.0
    ap_x1 = ap_y1 = 0.0
    for i in range(n):
        w = i + N0                       # write position
        target = period[i] - s
        D = int(target - 0.1)            # allpass delay d kept in [0.1, 1.1) for stability
        d = target - D
        c = (1 - d) / (1 + d)
        x0 = buf[w - D]
        ap = c * x0 + ap_x1 - c * ap_y1
        ap_x1, ap_y1 = x0, ap
        lp = (1 - s) * ap + s * prev
        prev = ap
        buf[w] = g * lp
    y = buf[:n].copy()
    y = filt(sos_hp(70, 2), y)
    # body / bridge resonances of the paulownia box
    for f, q, gdb in ((210, 2.0, 5.0), (430, 2.5, 3.5), (1150, 2.0, 2.5), (2900, 1.5, 3.0)):
        y = filt(peak_eq(f, q, gdb), y)
    # plectrum (tsume) click
    click = burst(0.002, 2500, 11000, seed + 5, 0.0005)
    y[: click.size] += 0.25 * bright * click * np.max(np.abs(y[:2000]) + 1e-9)
    return fade_edges(y, 0.0005, 0.03)


# ----------------------------------------------------------------- shakuhachi

def shakuhachi(f0: float, dur: float = 1.4, seed: int = 7, scoop: float = -1.0,
               vib_hz: float = 5.2, vib_depth: float = 0.25, breath: float = 0.35,
               attack_s: float = 0.12, release_s: float = 0.35) -> np.ndarray:
    """Breathy end-blown bamboo flute: scooped attack (meri to kari), delayed vibrato,
    weak odd/even harmonics, noise shaped around the partials, swelling breath envelope."""
    n = int(dur * SR)
    t = np.arange(n) / SR
    r = rng(seed)
    bend = scoop * np.exp(-t / 0.10)
    vib = vib_depth * np.clip((t - 0.35) / 0.4, 0, 1) * np.sin(2 * math.pi * vib_hz * t)
    f = f0 * 2 ** ((bend + vib) / 12)
    ph = 2 * math.pi * np.cumsum(f) / SR
    tone = np.sin(ph) + 0.22 * np.sin(2 * ph + 0.4) + 0.12 * np.sin(3 * ph + 1.1) \
        + 0.04 * np.sin(4 * ph)
    noise = r.standard_normal(n)
    breathy = filt(sos_bp(f0 * 0.8, f0 * 3.5, 2), noise) * 0.9 \
        + filt(sos_bp(2500, 7000, 2), noise) * 0.25
    # breath is louder at the attack (muraiki-ish chiff)
    b_env = breath * (0.6 + 1.6 * np.exp(-t / 0.08))
    amp = np.clip(t / attack_s, 0, 1) ** 1.5
    rel = np.clip((dur - t) / release_s, 0, 1) ** 1.2
    swell = 1.0 + 0.15 * np.sin(2 * math.pi * 0.7 * t)
    y = (tone * swell + breathy * b_env) * amp * rel
    return filt(sos_lp(6500, 2), y)


# ----------------------------------------------------------------- space

def room_ir(dur: float = 1.2, rt60: float = 0.9, damp_hz: float = 5000.0, seed: int = 8,
            predelay_s: float = 0.012) -> np.ndarray:
    """Stereo synthetic room impulse response: decorrelated exponentially decaying noise,
    progressively darker over time (mix of a bright and a dark decay)."""
    n = int(dur * SR)
    t = np.arange(n) / SR
    r = rng(seed)
    out = np.zeros((n, 2))
    tau = rt60 / 6.91
    for ch in range(2):
        w = r.standard_normal(n)
        bright = filt(sos_hp(250, 1), w) * np.exp(-t / (tau * 0.55))
        dark = filt(sos_lp(damp_hz, 2), filt(sos_hp(180, 1), w)) * np.exp(-t / tau)
        ir = 0.45 * bright + dark
        pd = int(predelay_s * SR)
        ir = np.concatenate([np.zeros(pd), ir[: n - pd]])
        ir[pd: pd + int(0.004 * SR)] *= np.linspace(0, 1, int(0.004 * SR))
        out[:, ch] = ir
    return out / np.sqrt(np.sum(out ** 2) / 2)


def reverb(x: np.ndarray, wet: float = 0.18, ir: np.ndarray | None = None) -> np.ndarray:
    """Convolve (mono or stereo) x with a stereo room IR; returns stereo (n + ir, 2)."""
    ir = room_ir() if ir is None else ir
    if x.ndim == 1:
        x = np.stack([x, x], axis=1)
    m = len(x) + len(ir) - 1
    y = np.zeros((m, 2))
    y[: len(x)] += x * (1 - wet * 0.5)
    for ch in range(2):
        y[:, ch] += wet * signal.fftconvolve(x[:, ch], ir[:, ch])
    return y


# ----------------------------------------------------------------- wildlife

def _tone_track(f: np.ndarray, amp: np.ndarray, h2: float = 0.06, seed: int = 0) -> np.ndarray:
    """Near-pure whistle from an instantaneous frequency/amplitude track (bird syrinx)."""
    r = rng(seed)
    jitter = 1.0 + 0.004 * filt(sos_lp(40, 1), r.standard_normal(f.size)) * 6
    ph = 2 * math.pi * np.cumsum(f * jitter) / SR
    return amp * (np.sin(ph) + h2 * np.sin(2 * ph + 0.7))


def _seg(n: int, f0: float, f1: float, a0: float, a1: float, att: float, rel: float,
         curve: float = 1.0) -> tuple[np.ndarray, np.ndarray]:
    u = np.linspace(0, 1, n, endpoint=False)
    f = f0 + (f1 - f0) * u ** curve
    a = np.ones(n) * np.linspace(a0, a1, n)
    na, nr = max(1, int(att * SR)), max(1, int(rel * SR))
    a[:na] *= np.sin(np.linspace(0, math.pi / 2, na)) ** 2
    a[-nr:] *= np.cos(np.linspace(0, math.pi / 2, nr)) ** 2
    return f, a


def uguisu(variant: int = 0, pitch: float = 1.0, hoo_s: float = 1.3, seed: int = 20) -> np.ndarray:
    """Japanese bush warbler song 'hoo-hokekyo' (Cettia diphone), mono, dry.

    Structure (from published sonograms): a long steady whistle 'hoo' (~1.0-1.2 kHz, slight
    rise, 0.8-1.8 s), a short gap, then the rapid 'ho-ke' notes (a quick ~1.6->2.4 kHz upsweep
    and a steep ~3.8->2.6 kHz downsweep) and the loud, frequency-modulated 'kyo' falling from
    ~3.4 to ~2.0 kHz. variant 1 adds a second 'kekyo'; variant 2 is the shorter 'ho-kekyo'."""
    r = rng(seed)
    parts_f, parts_a = [], []

    def add(dur, f0, f1, a0, a1, att, rel, curve=1.0):
        f, a = _seg(int(dur * SR), f0 * pitch, f1 * pitch, a0, a1, att, rel, curve)
        parts_f.append(f)
        parts_a.append(a)

    def gap(dur):
        n = int(dur * SR)
        parts_f.append(np.full(n, 1000.0 * pitch))
        parts_a.append(np.zeros(n))

    hoo = hoo_s if variant != 2 else hoo_s * 0.6
    add(hoo, 1080 + r.uniform(-40, 40), 1210 + r.uniform(-30, 30), 0.35, 0.6, 0.18, 0.06, 0.6)
    gap(0.11 + r.uniform(-0.02, 0.03))
    add(0.075, 1600, 2450, 0.55, 0.75, 0.008, 0.012, 1.4)          # ho
    gap(0.018)
    add(0.055, 3850, 2650, 0.8, 0.7, 0.004, 0.01)                  # ke
    gap(0.035)
    kyo_n = int(0.26 * SR)
    f, a = _seg(kyo_n, 3400 * pitch, 2050 * pitch, 1.0, 0.75, 0.006, 0.05, 0.7)
    u = np.arange(kyo_n) / SR
    f = f + 170 * pitch * np.sin(2 * math.pi * 34 * u) * np.exp(-u / 0.15)
    parts_f.append(f)
    parts_a.append(a)
    if variant == 1:
        gap(0.09)
        add(0.05, 3700, 2600, 0.6, 0.55, 0.004, 0.01)
        gap(0.03)
        f, a = _seg(int(0.22 * SR), 3250 * pitch, 2000 * pitch, 0.8, 0.6, 0.006, 0.05, 0.7)
        u = np.arange(f.size) / SR
        parts_f.append(f + 150 * pitch * np.sin(2 * math.pi * 31 * u) * np.exp(-u / 0.12))
        parts_a.append(a)
    gap(0.05)
    f = np.concatenate(parts_f)
    a = np.concatenate(parts_a)
    a = filt(sos_lp(180, 1), a)  # soften any envelope corners (no clicks)
    return _tone_track(f, np.clip(a, 0, None), seed=seed)


def bell_cricket(dur: float, carrier: float = 4400.0, period: float = 1.1, seed: int = 30,
                 rest_prob: float = 0.12) -> np.ndarray:
    """Suzumushi (Meloimorpha japonica) 'riiin': ~0.3-0.45 s tonal chirps near 4-4.8 kHz with
    a rapid pulse roughness, repeated about once a second with jitter and occasional rests."""
    r = rng(seed)
    n = int(dur * SR)
    env = np.zeros(n)
    t = r.uniform(0, period)
    while t < dur:
        if r.random() < rest_prob:
            t += r.uniform(2.0, 5.0)
            continue
        cl = r.uniform(0.28, 0.45)
        m = int(cl * SR)
        i = int(t * SR)
        if i + m >= n:
            break
        u = np.arange(m) / SR
        shape = np.clip(u / 0.03, 0, 1) * np.clip((cl - u) / 0.08, 0, 1) ** 1.5
        pulses = 0.55 + 0.45 * np.cos(2 * math.pi * r.uniform(38, 46) * u) ** 2
        env[i:i + m] += shape * pulses * r.uniform(0.75, 1.0)
        t += period * r.uniform(0.85, 1.2)
    tt = np.arange(n) / SR
    drift = 1.0 + 0.006 * np.sin(2 * math.pi * 0.05 * tt + r.uniform(0, 6.28))
    ph = 2 * math.pi * np.cumsum(carrier * drift) / SR
    y = env * (np.sin(ph) + 0.12 * np.sin(2 * ph + 0.3))
    return filt(sos_lp(9000, 2), y)
