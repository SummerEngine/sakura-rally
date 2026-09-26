"""Render + check the fake-car recording made by scenes/test/audio_test.tscn.

Usage: tools/audio/.venv/bin/python tools/audio/render_test.py [audio_test.wav]
Writes <name>.png (full spectrogram with event marks), <name>_engine.png (0-2.5 kHz linear
zoom so the firing-frequency harmonics and shift drops are readable) and prints:
peak dBFS, LUFS, count of clipped samples, and a click detector (samples whose high-passed
residual jumps far above the local level).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
from scipy import signal

import audiolib as al


def click_scan(x: np.ndarray, sr: int) -> list[float]:
    """Times where a sample-level discontinuity sticks out of its neighbourhood.
    A step discontinuity is broadband up to Nyquist, while the synthesised content (valve
    ticks, gravel grains) is band-limited below ~9 kHz: high-pass at 15 kHz, then compare
    |residual| to a 20 ms rolling RMS."""
    hp = signal.sosfilt(al.sos_hp(15000.0, 6, sr), x)
    a = np.abs(hp)
    win = int(0.02 * sr)
    rms = np.sqrt(np.convolve(hp * hp, np.ones(win) / win, mode="same")) + 1e-5
    ratio = a / rms
    idx = np.nonzero((ratio > 12.0) & (a > 0.003))[0]
    times: list[float] = []
    for i in idx:
        t = i / sr
        if not times or t - times[-1] > 0.05:
            times.append(round(t, 3))
    return times


def main(argv: list[str]) -> None:
    wav = Path(argv[0]) if argv else al.RENDERS / "audio_test.wav"
    x, sr = al.read_wav(wav)
    ev_path = wav.with_name(wav.stem + "_events.json")
    events = json.loads(ev_path.read_text()) if ev_path.exists() else []
    # Log times start with the recording; the headless Dummy audio driver mixes slightly
    # slower than game time, so scale the log so the "end" event lands on the last sample.
    end_t = next((e["t"] for e in events if e["label"] == "end"), None)
    scale = (x.size / sr) / end_t if end_t else 1.0
    marks = [(e["t"] * scale, e["label"]) for e in events]
    al.spectrogram_png(x, wav.with_suffix(".png"), f"{wav.name}", sr=sr, extra_marks=marks)
    # engine zoom: linear 0..2500 Hz
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    f, t, s = signal.spectrogram(x, fs=sr, nperseg=8192, noverlap=8192 - 1024, window="hann")
    keep = f <= 2500
    sd = 10 * np.log10(s[keep] + 1e-14)
    fig, ax = plt.subplots(figsize=(16, 6))
    ax.pcolormesh(t, f[keep], sd, shading="auto", cmap="magma", vmin=sd.max() - 70, vmax=sd.max())
    for tm, label in marks:
        ax.axvline(tm, color="#6aa8e8", lw=0.5, alpha=0.6)
        ax.text(tm, 2450, label, fontsize=6, rotation=90, va="top", color="w")
    ax.set_title(f"{wav.name} 0-2.5 kHz (firing harmonics, shift drops)")
    ax.set_xlabel("s")
    ax.set_ylabel("Hz")
    fig.tight_layout()
    fig.savefig(wav.with_name(wav.stem + "_engine.png"), dpi=85)
    plt.close(fig)
    clipped = int(np.sum(np.abs(x) >= 0.999))
    clicks = click_scan(x, sr)
    print(f"{wav.name}: {x.size / sr:.2f} s, peak {al.peak_db(x):.2f} dBFS, "
          f"LUFS {al.lufs(x, sr):.2f}, clipped samples {clipped}, log time scale {scale:.4f}")
    print(f"click candidates ({len(clicks)}): {[float(c) for c in clicks[:40]]}")


if __name__ == "__main__":
    main(sys.argv[1:])
