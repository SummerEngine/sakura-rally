"""UI one-shots: soft wood / bamboo 'kon' taps and a tiny rin accent (modal synthesis).

Pitches from the D yo pentatonic (D E G A B), matching the D-centred music.
Mono 16-bit WAV, DC-free, 2 ms raised-sine fade-in, tail faded to digital silence.

Run: tools/audio/.venv/bin/python tools/audio/synth_ui.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import synth_lib as sl  # noqa: E402
from audiolib import (ASSETS, RENDERS, SR, fade_edges, filt, lufs, peak_db,  # noqa: E402
                      read_wav, sos_hp, sos_lp, spectrogram_png, undb, write_wav)

OUT = ASSETS / "ui"
IR = sl.room_ir(dur=0.35, rt60=0.28, damp_hz=6000, seed=61, predelay_s=0.006)


def space(x: np.ndarray, wet: float, dur: float) -> np.ndarray:
    """Tiny wooden-room ambience, folded to mono, truncated to dur."""
    y = sl.reverb(x, wet=wet, ir=IR).mean(1)
    return y[: int(dur * SR)]


def momentary_max(x: np.ndarray) -> float:
    """Max BS.1770 momentary loudness (400 ms window) of the clip followed by silence: how
    loud one isolated UI blip actually reads, unlike the tiled integrated value."""
    pad = np.concatenate([x, np.zeros(SR)])
    return max(lufs(pad[i:i + int(0.4 * SR)]) for i in range(0, len(x), 441))


def master(x: np.ndarray, dur: float, target_lufs: float, fade_out: float) -> np.ndarray:
    n = int(dur * SR)
    y = np.zeros(n)
    y[: min(n, len(x))] = x[:n]
    y = filt(sos_hp(90, 2), y)            # no DC / sub rumble
    y -= y.mean()
    y = fade_edges(y, 0.002, fade_out)     # 2 ms fade-in, smooth tail to exactly 0
    y *= undb(target_lufs - momentary_max(y))
    if peak_db(y) > -1.5:
        y *= undb(-1.5 - peak_db(y))
    return y


def hover() -> np.ndarray:
    # tiny high bamboo tick (A6 region), very short and dry
    x = sl.bamboo_tap(sl.hz("A6"), dur=0.07, seed=11, damp=0.55)
    x = filt(sos_lp(9000, 2), x)
    return master(space(x, 0.10, 0.07), 0.07, -27.0, 0.035)


def click() -> np.ndarray:
    # rounded wood block 'kon' on A5 with a soft bamboo overtone
    x = sl.wood_tap(sl.hz("A5"), dur=0.14, hardness=0.45, damp=1.0, seed=12)
    x += 0.35 * sl.bamboo_tap(sl.hz("A6"), dur=0.14, seed=13, damp=0.5)
    return master(space(x, 0.14, 0.14), 0.14, -22.0, 0.06)


def back() -> np.ndarray:
    # two descending, darker wood taps: D5 -> A4
    buf = sl.blank(0.34)
    sl.place(buf, sl.wood_tap(sl.hz("D5"), 0.2, hardness=0.35, damp=1.2, seed=14), 0.0, 1.0)
    sl.place(buf, sl.wood_tap(sl.hz("A4"), 0.25, hardness=0.25, damp=1.4, seed=15), 0.085, 0.85)
    buf = filt(sos_lp(6000, 2), buf)
    return master(space(buf, 0.16, 0.34), 0.34, -21.0, 0.12)


def start() -> np.ndarray:
    # confident ascending wood taps D5 - G5 - A5 (yo) landing on a small rin (D6-ish bell)
    buf = sl.blank(0.6)
    sl.place(buf, sl.wood_tap(sl.hz("D5"), 0.2, hardness=0.55, seed=16), 0.0, 0.8)
    sl.place(buf, sl.wood_tap(sl.hz("G5"), 0.2, hardness=0.6, seed=17), 0.07, 0.85)
    sl.place(buf, sl.wood_tap(sl.hz("A5"), 0.2, hardness=0.65, seed=18), 0.14, 1.0)
    bell = sl.rin(sl.hz("D6"), dur=0.46, decay=0.9, bright=0.5, seed=19)
    sl.place(buf, bell, 0.14, 0.32)
    return master(space(buf, 0.2, 0.6), 0.6, -19.0, 0.22)


def toggle() -> np.ndarray:
    # tiny double tick: two dry bamboo ticks 38 ms apart, second a tone higher (A6 -> B6)
    buf = sl.blank(0.11)
    sl.place(buf, sl.bamboo_tap(sl.hz("A6"), 0.05, seed=20, damp=0.45), 0.0, 0.9)
    sl.place(buf, sl.bamboo_tap(sl.hz("B6"), 0.06, seed=21, damp=0.45), 0.038, 1.0)
    buf = filt(sos_lp(10000, 2), buf)
    return master(space(buf, 0.08, 0.11), 0.11, -25.0, 0.04)


CLIPS = {"hover": hover, "click": click, "back": back, "start": start, "toggle": toggle}
DESCR = {
    "hover": "bamboo_tap A6 (1760 Hz), damp 0.55, LP 9 kHz, tiny room",
    "click": "wood_tap A5 (free-bar modes 1/2.76/5.4/8.93 + cavity + mallet contact) "
             "+ bamboo_tap A6 overtone",
    "back": "wood_tap D5 then A4 (85 ms later), darker/damper, LP 6 kHz",
    "start": "wood_tap D5-G5-A5 ascending (70 ms steps) + rin bell D6 (detuned partial pairs)",
    "toggle": "two bamboo ticks A6 -> B6, 38 ms apart",
}


def main() -> None:
    rep = {}
    for name, fn in CLIPS.items():
        y = fn()
        path = write_wav(OUT / f"{name}.wav", y)
        z, _ = read_wav(path)
        png = RENDERS / f"ui_{name}.png"
        spectrogram_png(z, png, f"ui/{name}.wav", fmax=16000, nfft=256)
        mom = momentary_max(z)
        rep[name] = {
            "path": str(path.relative_to(ASSETS.parents[1])),
            "duration_ms": round(len(z) / SR * 1000, 1), "channels": 1, "bits": 16,
            "lufs_tiled": round(lufs(z), 2), "momentary_max_lufs_400ms": round(mom, 2),
            "peak_db": round(peak_db(z), 2), "dc": float(np.mean(z)),
            "first_sample": float(z[0]), "last_sample": float(z[-1]),
            "synthesis": DESCR[name], "script": "tools/audio/synth_ui.py",
            "png": str(png.relative_to(ASSETS.parents[1])),
        }
        print(name, json.dumps(rep[name]))
    (RENDERS / "ui_report.json").write_text(json.dumps(rep, indent=2) + "\n")


if __name__ == "__main__":
    main()
