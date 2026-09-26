"""Offline synthesis of the spectators' comic knock-over sounds (scripts/world/crowd.gd).

Outputs 44.1 kHz mono 16-bit WAV into assets/audio/crowd/:
  bonk_1..3.wav   cartoon bonk: a hollow wood-block knock with a falling pitch
  oof_1..4.wav    a knocked person's voice: "oof" (low), "wah!" (high), "whoa" (low), "ah!" (child)
  ooh_1..3.wav    the crowd reacts: a rising "ooooh", a "whoa-oh" with a few laughs, an "oh!"
                  that breaks into claps and laughter
  hop.wav         the little boing of getting back up

Voices are source-filter additive synthesis: a glottal harmonic series under moving vowel
formants, with breath noise; the crowd is two dozen such voices with their own pitch, onset,
vowel colour and vibrato, in a small outdoor room.
Run: tools/audio/.venv/bin/python tools/audio/synth_crowd.py
"""

from __future__ import annotations

import math

import numpy as np

import audiolib as al
import synth_lib as sl

OUT = al.ASSETS / "crowd"
SR = al.SR

# formants (F1, F2, F3) of a few vowels, adult male; women and children scale them up
VOWELS = {
    "u": (320.0, 800.0, 2240.0),
    "o": (480.0, 900.0, 2400.0),
    "a": (730.0, 1150.0, 2500.0),
    "uh": (620.0, 1190.0, 2390.0),
    "e": (530.0, 1840.0, 2480.0),
}
BANDWIDTH = (90.0, 110.0, 170.0)


def track(points: list[tuple[float, float]], n: int) -> np.ndarray:
    """Piecewise-linear track through (time s, value) points, n samples."""
    t = np.arange(n) / SR
    ts = [p[0] for p in points]
    vs = [p[1] for p in points]
    return np.interp(t, ts, vs)


def voice(f0: np.ndarray, vowel_a: str, vowel_b: str, morph: np.ndarray, amp: np.ndarray,
          scale: float = 1.0, breath: float = 0.08, seed: int = 0, vibrato: float = 0.0) -> np.ndarray:
    """A voiced sound: harmonics of f0 (Hz per sample) shaped by formants moving from vowel_a
    to vowel_b as morph goes 0 -> 1, times the amplitude envelope."""
    r = al.rng(seed)
    n = f0.size
    t = np.arange(n) / SR
    if vibrato > 0.0:
        f0 = f0 * (1.0 + vibrato * np.sin(2 * math.pi * r.uniform(4.5, 6.0) * t + r.uniform(0, 6.3)))
    # a little pitch wander
    wander = al.filt(al.sos_lp(8.0, 1), r.standard_normal(n)) * 0.6
    f0 = f0 * (1.0 + 0.01 * wander)
    fa = np.array(VOWELS[vowel_a]) * scale
    fb = np.array(VOWELS[vowel_b]) * scale
    formants = [fa[k] + (fb[k] - fa[k]) * morph for k in range(3)]
    phase = 2 * math.pi * np.cumsum(f0) / SR
    y = np.zeros(n)
    hmax = int(5200.0 / max(float(f0.min()), 60.0))
    for h in range(1, hmax + 1):
        f = f0 * h
        env = np.zeros(n)
        for k in range(3):
            env += (1.0, 0.55, 0.25)[k] / (1.0 + ((f - formants[k]) / (BANDWIDTH[k] * scale * 0.5)) ** 2)
        y += env * np.sin(h * phase) / h ** 0.6
    noise = al.filt(al.sos_bp(900.0 * scale, 3200.0 * scale, 2), al.white(n, r))
    y = y / (np.max(np.abs(y)) + 1e-12) + breath * noise / (np.max(np.abs(noise)) + 1e-12)
    return y * amp


def bonk(r: np.random.Generator) -> np.ndarray:
    dur = 0.42
    n = int(dur * SR)
    t = np.arange(n) / SR
    f = r.uniform(520.0, 640.0) * (0.62 + 0.38 * np.exp(-t / 0.05))
    body = np.sin(2 * math.pi * np.cumsum(f) / SR) * np.exp(-t / 0.09)
    hollow = np.sin(2 * math.pi * np.cumsum(f * 2.74) / SR) * np.exp(-t / 0.03) * 0.35
    thud = np.sin(2 * math.pi * r.uniform(110, 150) * t) * np.exp(-t / 0.04) * 0.6
    click = al.filt(al.sos_bp(2000.0, 7000.0, 2), al.white(n, r)) * np.exp(-t / 0.003)
    y = body + hollow + thud + 0.4 * click / (np.max(np.abs(click)) + 1e-12)
    return al.trim_tail(al.fade_edges(y, 0.0003, 0.05), -60.0)


def oof(kind: int) -> np.ndarray:
    if kind == 0:  # "oof": low, a short falling grunt closing into an f
        dur, seed = 0.42, 11
        n = int(dur * SR)
        f0 = track([(0.0, 150.0), (0.08, 140.0), (0.3, 96.0)], n)
        morph = track([(0.0, 0.0), (0.2, 1.0)], n)
        amp = track([(0.0, 0.0), (0.02, 1.0), (0.18, 0.8), (0.3, 0.0)], n)
        y = voice(f0, "uh", "u", morph, amp, 1.0, 0.1, seed)
        fric_env = track([(0.0, 0.0), (0.24, 0.0), (0.28, 0.5), (0.42, 0.0)], n)
    elif kind == 1:  # "wah!": high, rising then falling
        dur, seed = 0.55, 12
        n = int(dur * SR)
        f0 = track([(0.0, 250.0), (0.12, 360.0), (0.45, 220.0)], n)
        morph = track([(0.0, 0.0), (0.12, 1.0)], n)
        amp = track([(0.0, 0.0), (0.03, 0.7), (0.12, 1.0), (0.4, 0.5), (0.5, 0.0)], n)
        y = voice(f0, "u", "a", morph, amp, 1.18, 0.07, seed, 0.02)
        fric_env = np.zeros(n)
    elif kind == 2:  # "whoa": low, sliding down
        dur, seed = 0.6, 13
        n = int(dur * SR)
        f0 = track([(0.0, 170.0), (0.1, 190.0), (0.55, 110.0)], n)
        morph = track([(0.0, 0.0), (0.18, 1.0)], n)
        amp = track([(0.0, 0.0), (0.04, 0.9), (0.35, 0.8), (0.58, 0.0)], n)
        y = voice(f0, "u", "o", morph, amp, 1.0, 0.08, seed, 0.03)
        fric_env = np.zeros(n)
    else:  # "ah!": a child, short and bright
        dur, seed = 0.4, 14
        n = int(dur * SR)
        f0 = track([(0.0, 360.0), (0.07, 430.0), (0.35, 330.0)], n)
        morph = track([(0.0, 0.0), (0.06, 1.0)], n)
        amp = track([(0.0, 0.0), (0.015, 1.0), (0.25, 0.6), (0.38, 0.0)], n)
        y = voice(f0, "uh", "a", morph, amp, 1.35, 0.06, seed, 0.02)
        fric_env = np.zeros(n)
    r = al.rng(seed + 100)
    fric = al.filt(al.sos_bp(1500.0, 7000.0, 2), al.white(n, r))
    y = y + fric_env * fric / (np.max(np.abs(fric)) + 1e-12)
    return al.trim_tail(al.fade_edges(y, 0.002, 0.04), -60.0)


def laugh(n: int, start: float, f0: float, scale: float, seed: int) -> np.ndarray:
    """A short "ha-ha-ha": /a/ pulsed at ~5 Hz with a falling pitch."""
    r = al.rng(seed)
    t = np.arange(n) / SR
    beats = int(r.integers(3, 6))
    rate = r.uniform(4.5, 6.0)
    end = start + beats / rate
    gate = ((t >= start) & (t < end)).astype(float)
    pulse = np.maximum(0.0, np.sin(2 * math.pi * rate * (t - start))) ** 1.5 * gate
    f = f0 * (1.0 - 0.25 * np.clip((t - start) / max(end - start, 1e-3), 0, 1))
    return voice(f, "a", "a", np.zeros(n), pulse, scale, 0.25, seed)


def clap(n: int, r: np.random.Generator) -> np.ndarray:
    dur = int(0.03 * SR)
    t = np.arange(dur) / SR
    c = al.filt(al.sos_bp(r.uniform(900, 1400), r.uniform(2500, 4000), 2), al.white(dur, r)) * np.exp(-t / 0.006)
    return c / (np.max(np.abs(c)) + 1e-12)


def ooh(kind: int) -> np.ndarray:
    dur = (1.8, 2.0, 2.2)[kind]
    n = int(dur * SR)
    r = al.rng(300 + kind)
    y = np.zeros(n)
    voices = 24
    for v in range(voices):
        female = v % 3 != 0
        child = v % 8 == 5
        base = r.uniform(190, 280) if female else r.uniform(100, 150)
        if child:
            base = r.uniform(300, 380)
        scale = (1.35 if child else 1.16 if female else 1.0) * r.uniform(0.96, 1.05)
        onset = r.uniform(0.0, 0.22)
        if kind == 0:  # "ooooh": rising, holding, sliding down
            f0 = track([(0.0, base), (onset, base), (onset + 0.35, base * 1.35), (onset + 0.9, base * 1.25),
                        (dur, base * 0.9)], n)
            a, b = "u", "o"
            morph = track([(onset, 0.0), (onset + 0.4, 1.0)], n)
            amp = track([(0.0, 0.0), (onset, 0.0), (onset + 0.12, 0.8), (onset + 0.5, 1.0), (dur - 0.5, 0.6),
                         (dur - 0.05, 0.0)], n)
        elif kind == 1:  # "whoa-oh": up, down
            f0 = track([(0.0, base), (onset, base * 1.1), (onset + 0.3, base * 1.45), (onset + 0.8, base),
                        (dur, base * 0.85)], n)
            a, b = "u", "a"
            morph = track([(onset, 0.0), (onset + 0.3, 1.0), (onset + 0.8, 0.4)], n)
            amp = track([(0.0, 0.0), (onset, 0.0), (onset + 0.1, 1.0), (onset + 0.9, 0.7), (dur - 0.6, 0.2),
                         (dur - 0.3, 0.0)], n)
        else:  # "oh!": a short burst
            f0 = track([(0.0, base * 1.2), (onset, base * 1.25), (onset + 0.2, base * 1.5), (onset + 0.6, base),
                        (dur, base)], n)
            a, b = "o", "uh"
            morph = track([(onset, 0.0), (onset + 0.4, 1.0)], n)
            amp = track([(0.0, 0.0), (onset, 0.0), (onset + 0.06, 1.0), (onset + 0.4, 0.6), (onset + 0.75, 0.0)], n)
        y += voice(f0, a, b, morph, amp, scale, 0.12, 400 + kind * 50 + v, 0.012) * r.uniform(0.6, 1.0)
    y /= np.max(np.abs(y)) + 1e-12
    if kind >= 1:  # a few laughs
        for j in range(5 if kind == 1 else 8):
            f = r.uniform(180, 300) if j % 2 else r.uniform(110, 160)
            start = r.uniform(0.5, 1.0) if kind == 1 else r.uniform(0.45, 1.1)
            y += laugh(n, start, f, 1.15 if j % 2 else 1.0, 700 + kind * 20 + j) * 0.22
    if kind == 2:  # claps
        for _ in range(60):
            s = int(r.uniform(0.55, dur - 0.3) * SR)
            c = clap(n, r) * r.uniform(0.15, 0.4)
            e = min(n, s + c.size)
            y[s:e] += c[: e - s]
    st = sl.reverb(y, 0.22, sl.room_ir(0.9, 0.6, 4500.0, 9))
    mono = st.mean(axis=1)
    return al.trim_tail(al.fade_edges(mono, 0.005, 0.2), -60.0)


def hop() -> np.ndarray:
    dur = 0.3
    n = int(dur * SR)
    t = np.arange(n) / SR
    f = 260.0 + 620.0 * (1 - np.exp(-t / 0.05))
    f = f * (1.0 + 0.06 * np.sin(2 * math.pi * 24.0 * t) * np.exp(-t / 0.12))
    y = np.sin(2 * math.pi * np.cumsum(f) / SR) * al.env_ad(n, 0.005, 0.22, 3.0)
    y += 0.3 * np.sin(2 * math.pi * np.cumsum(f * 2.0) / SR) * al.env_ad(n, 0.005, 0.1, 3.0)
    return al.trim_tail(al.fade_edges(y, 0.002, 0.05), -60.0)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    r = al.rng(900)
    for i in range(3):
        al.write_wav(OUT / f"bonk_{i + 1}.wav", al.normalize_peak(bonk(r), -1.0))
    for i in range(4):
        al.write_wav(OUT / f"oof_{i + 1}.wav", al.normalize_peak(oof(i), -1.5))
    for i in range(3):
        al.write_wav(OUT / f"ooh_{i + 1}.wav", al.normalize_lufs(ooh(i), -18.0, peak_ceiling_db=-1.0))
    al.write_wav(OUT / "hop.wav", al.normalize_peak(hop(), -3.0))


if __name__ == "__main__":
    main()
