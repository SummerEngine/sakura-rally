"""Stingers: taiko, Karplus-Strong koto, rin bell, shakuhachi, all synthesised.

Key: D yo pentatonic (D E G A B), which avoids F/F# so it sits over both the D-major menu /
results tracks and the D-centred drive track. Stereo 16-bit WAV with a small hall.

Run: tools/audio/.venv/bin/python tools/audio/synth_stingers.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

sys.path.insert(0, str(Path(__file__).resolve().parent))
import synth_lib as sl  # noqa: E402
from assetio import true_peak_db  # noqa: E402
from audiolib import (ASSETS, RENDERS, SR, filt, lufs, peak_db, soft_limit,  # noqa: E402
                      sos_hp, sos_lp, spectrogram_png, undb)

OUT = ASSETS / "stingers"
HALL = sl.room_ir(dur=2.4, rt60=1.8, damp_hz=5500, seed=71, predelay_s=0.02)
H = sl.hz


def st(n_s: float) -> np.ndarray:
    return np.zeros((int(n_s * SR), 2))


def put(buf: np.ndarray, x: np.ndarray, t: float, gain_db: float = 0.0, pan: float = 0.0):
    sl.place(buf, sl.pan(x, pan), t, undb(gain_db))


def momentary_max(x: np.ndarray) -> float:
    pad = np.concatenate([x, np.zeros((SR, x.shape[1]))])
    return max(lufs(pad[i:i + int(0.4 * SR)]) for i in range(0, len(x), 441))


def master(dry: np.ndarray, dur: float, wet: float, target: float, fade_s: float) -> np.ndarray:
    """Reverb, truncate to dur with a smooth fade to 0, loudness (momentary max), peak safety."""
    y = sl.reverb(dry, wet=wet, ir=HALL)[: int(dur * SR)]
    y = np.stack([filt(sos_hp(40, 2), y[:, c]) for c in range(2)], axis=1)
    n = int(fade_s * SR)
    y[-n:] *= (np.cos(np.linspace(0, np.pi / 2, n)) ** 2)[:, None]
    ni = int(0.001 * SR)
    y[:ni] *= np.linspace(0, 1, ni)[:, None]
    y *= undb(target - momentary_max(y))
    # the taiko transient is the only thing that can exceed the ceiling: soft-limit it
    if true_peak_db(y) > -1.2:
        y = soft_limit(y, -1.5, knee_db=6.0)
    if true_peak_db(y) > -1.0:
        y *= undb(-1.0 - true_peak_db(y) - 0.05)
    return y


def strum(buf, notes, t0, spread, gain_db, pans, bright=0.75, decay=1.8, seed=0, dur=2.5):
    for k, (nm, p) in enumerate(zip(notes, pans)):
        put(buf, sl.koto(H(nm), dur, bright=bright, decay_s=decay, seed=seed + k),
            t0 + k * spread, gain_db - 1.0 * k, p)


# ----------------------------------------------------------------- stingers

def countdown() -> np.ndarray:
    """3-2-1 tick: soft high taiko tap (shime-daiko-like) + a single koto A4."""
    buf = st(0.9)
    put(buf, sl.taiko(150.0, 0.9, force=0.3, seed=81, rim=0.15), 0.0, -2.0, 0.0)
    put(buf, sl.koto(H("A4"), 0.9, bright=0.7, decay_s=1.0, seed=82), 0.004, -3.0, 0.15)
    return master(buf, 0.58, 0.12, -16.0, 0.2)


def go() -> np.ndarray:
    """Big o-daiko hit + bright koto D chord strum + rin bell."""
    buf = st(2.2)
    put(buf, sl.taiko(66.0, 2.0, force=1.0, seed=83), 0.0, 0.0, 0.0)
    put(buf, sl.taiko(132.0, 0.6, force=0.6, seed=84, rim=0.2), 0.0, -9.0, -0.2)
    strum(buf, ["D4", "A4", "D5", "E5", "A5"], 0.01, 0.018, -4.0,
          [-0.5, -0.25, 0.0, 0.25, 0.5], bright=0.85, decay=1.6, seed=90, dur=1.8)
    put(buf, sl.rin(H("D6"), 1.6, decay=1.1, bright=0.6, seed=85), 0.02, -12.0, 0.3)
    return master(buf, 1.45, 0.2, -13.0, 0.45)


def checkpoint() -> np.ndarray:
    """Bright two-note chime: A5 then D6 (rin + koto doubling), a fourth up."""
    buf = st(1.6)
    for t, nm, p, g in ((0.0, "A5", -0.25, -1.0), (0.11, "D6", 0.25, 0.0)):
        put(buf, sl.rin(H(nm), 1.2, decay=0.7, bright=0.75, seed=86 + int(t * 100)), t, g, p)
        put(buf, sl.koto(H(nm), 1.0, bright=0.85, decay_s=0.9, seed=87 + int(t * 100)),
            t + 0.002, g - 5.0, p * 0.5)
    return master(buf, 0.95, 0.2, -16.0, 0.4)


def finish() -> np.ndarray:
    """Taiko flourish (don - doko - DON) under a rising koto arpeggio that resolves on D."""
    buf = st(3.6)
    for t, f0, force, g in ((0.0, 90, 0.6, -5), (0.30, 96, 0.45, -8), (0.40, 96, 0.5, -7),
                            (0.60, 68, 1.0, 0)):
        put(buf, sl.taiko(f0, 2.4, force=force, seed=100 + int(t * 100)), t, g, 0.0)
    arp = ["D4", "E4", "G4", "A4", "B4", "D5"]
    for k, nm in enumerate(arp):
        put(buf, sl.koto(H(nm), 2.4, bright=0.75, decay_s=1.8, seed=110 + k),
            0.05 + 0.1 * k, -5.0, -0.5 + 0.2 * k)
    # resolution chord on the big hit's afterglow
    strum(buf, ["D4", "A4", "D5", "A5"], 0.64, 0.02, -3.0, [-0.4, -0.1, 0.1, 0.4],
          bright=0.7, decay=2.4, seed=120, dur=2.8)
    put(buf, sl.rin(H("D5"), 2.8, decay=1.8, bright=0.5, seed=125), 0.62, -10.0, 0.0)
    return master(buf, 2.95, 0.22, -14.0, 1.0)


def record() -> np.ndarray:
    """Celebratory fanfare: two-octave koto arpeggio, taiko rolls, a shakuhachi phrase
    (A4 - B4 - D5, scooped attack, delayed vibrato), rin bells, closing D chord."""
    buf = st(5.2)
    # taiko: doko-doko pickup into two strong hits
    hits = [(0.0, 110, 0.4, -9), (0.12, 110, 0.4, -10), (0.24, 110, 0.45, -9),
            (0.36, 110, 0.5, -8), (0.5, 70, 1.0, -1), (1.7, 70, 0.9, -3), (2.6, 66, 1.0, 0)]
    for t, f0, force, g in hits:
        put(buf, sl.taiko(f0, 2.2, force=force, seed=130 + int(t * 100)), t, g, 0.0)
    arp = ["D4", "E4", "G4", "A4", "B4", "D5", "E5", "G5", "A5", "B5", "D6"]
    for k, nm in enumerate(arp):
        put(buf, sl.koto(H(nm), 2.0, bright=0.8, decay_s=1.6, seed=140 + k),
            0.5 + 0.075 * k, -6.0, -0.6 + 0.12 * k)
    # shakuhachi phrase over the middle
    phrase = [("A4", 1.25, 0.55, -1.2), ("B4", 1.78, 0.35, -0.6), ("D5", 2.1, 1.35, -1.0)]
    for nm, t, d, scoop in phrase:
        put(buf, sl.shakuhachi(H(nm), d + 0.25, seed=150 + int(t * 10), scoop=scoop,
                               vib_depth=0.2 if d > 1 else 0.05, release_s=0.2 if d < 1 else 0.6),
            t, -7.0, -0.15)
    # final chord + bells
    strum(buf, ["D4", "A4", "D5", "E5", "A5", "D6"], 2.6, 0.022, -3.0,
          [-0.6, -0.35, -0.1, 0.1, 0.35, 0.6], bright=0.75, decay=2.6, seed=160, dur=2.6)
    put(buf, sl.rin(H("D6"), 2.2, decay=1.6, bright=0.6, seed=170), 0.5, -14.0, 0.4)
    put(buf, sl.rin(H("A5"), 2.4, decay=1.8, bright=0.55, seed=171), 2.62, -11.0, -0.3)
    return master(buf, 4.4, 0.25, -14.0, 1.2)


CLIPS = {"countdown": countdown, "go": go, "checkpoint": checkpoint, "finish": finish,
         "record": record}
DESCR = {
    "countdown": "taiko(150 Hz, force 0.3, light rim) + koto A4; D yo pentatonic",
    "go": "o-daiko taiko(66 Hz, force 1) + shime layer 132 Hz + koto strum D4 A4 D5 E5 A5 "
          "+ rin D6",
    "checkpoint": "rin A5 then D6 (110 ms) each doubled by koto",
    "finish": "taiko don-doko-DON + koto arpeggio D4 E4 G4 A4 B4 D5 + D chord strum + rin D5",
    "record": "taiko doko-doko pickup + 3 big hits, 2-octave koto arpeggio D4..D6, "
              "shakuhachi A4-B4-D5 phrase, final koto D chord strum, rin D6/A5",
}


def main() -> None:
    rep = {}
    for name, fn in CLIPS.items():
        y = fn()
        path = OUT / f"{name}.wav"
        path.parent.mkdir(parents=True, exist_ok=True)
        sf.write(str(path), np.clip(y, -1, 1).astype(np.float32), SR, subtype="PCM_16")
        z, _ = sf.read(str(path), dtype="float64", always_2d=True)
        png = RENDERS / f"stinger_{name}.png"
        spectrogram_png(z.mean(1), png, f"stingers/{name}.wav", fmax=16000, nfft=1024)
        rep[name] = {
            "path": str(path.relative_to(ASSETS.parents[1])),
            "duration_s": round(len(z) / SR, 3), "channels": 2, "bits": 16,
            "lufs_integrated": round(lufs(z), 2),
            "momentary_max_lufs_400ms": round(momentary_max(z), 2),
            "sample_peak_db": round(peak_db(z), 2), "true_peak_db": round(true_peak_db(z), 2),
            "last_sample_abs": float(np.abs(z[-1]).max()),
            "synthesis": DESCR[name], "script": "tools/audio/synth_stingers.py",
            "png": str(png.relative_to(ASSETS.parents[1])),
        }
        print(name, json.dumps(rep[name]))
    (RENDERS / "stingers_report.json").write_text(json.dumps(rep, indent=2) + "\n")


if __name__ == "__main__":
    main()
