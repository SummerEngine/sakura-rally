"""Shared DSP helpers for the Sakura Rally offline audio tools.

Every generator in tools/audio imports this module. Conventions:
- float64 numpy arrays in [-1, 1], mono, SR = 44100.
- Loops are synthesised *circularly*: every filter is run over several
  repetitions of the loop and the steady-state last repetition is kept, so
  sample L-1 flows into sample 0 exactly like any other pair of samples.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np
import pyloudnorm
import soundfile as sf
from scipy import signal

SR = 44100
ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "assets" / "audio"
RENDERS = ROOT / "tools" / "audio" / "renders"


# ----------------------------------------------------------------- I/O

def write_wav(path: Path | str, x: np.ndarray, sr: int = SR) -> Path:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    y = np.clip(x, -1.0, 1.0)
    sf.write(str(path), y.astype(np.float32), sr, subtype="PCM_16")
    return path


def read_wav(path: Path | str) -> tuple[np.ndarray, int]:
    x, sr = sf.read(str(path), dtype="float64", always_2d=False)
    if x.ndim == 2:
        x = x.mean(axis=1)
    return x, sr


# ----------------------------------------------------------------- level

def db(x: float) -> float:
    return 20.0 * math.log10(max(x, 1e-12))


def undb(d: float) -> float:
    return 10.0 ** (d / 20.0)


def peak_db(x: np.ndarray) -> float:
    return db(float(np.max(np.abs(x))) if x.size else 0.0)


def rms_db(x: np.ndarray) -> float:
    return db(float(np.sqrt(np.mean(x * x))) if x.size else 0.0)


def lufs(x: np.ndarray, sr: int = SR) -> float:
    """Integrated loudness (ITU-R BS.1770-4). Short clips are tiled to 3 s."""
    if x.size < int(0.4 * sr) + 1:
        reps = int(math.ceil(3.0 * sr / max(x.size, 1)))
        x = np.tile(x, reps)
    meter = pyloudnorm.Meter(sr)
    return float(meter.integrated_loudness(x))


def normalize_peak(x: np.ndarray, target_db: float = -1.0) -> np.ndarray:
    p = float(np.max(np.abs(x)))
    return x if p <= 0 else x * (undb(target_db) / p)


def normalize_lufs(x: np.ndarray, target: float, peak_ceiling_db: float = -1.0,
                   sr: int = SR) -> np.ndarray:
    y = x * undb(target - lufs(x, sr))
    if peak_db(y) > peak_ceiling_db:
        y = soft_limit(y, peak_ceiling_db)
    return y


def soft_limit(x: np.ndarray, ceiling_db: float = -1.0, knee_db: float = 4.0) -> np.ndarray:
    """Transparent-ish static soft clipper: linear below ceiling-knee, tanh above."""
    c = undb(ceiling_db)
    k = undb(ceiling_db - knee_db)
    a = np.abs(x)
    over = a > k
    y = x.copy()
    span = c - k
    y[over] = np.sign(x[over]) * (k + span * np.tanh((a[over] - k) / span))
    return y


# ----------------------------------------------------------------- noise and filters

def rng(seed: int) -> np.random.Generator:
    return np.random.default_rng(seed)


def white(n: int, r: np.random.Generator) -> np.ndarray:
    return r.standard_normal(n)


def pink_circular(n: int, r: np.random.Generator) -> np.ndarray:
    """Periodic pink noise (1/f power) built in the frequency domain."""
    spec = np.fft.rfft(r.standard_normal(n))
    f = np.arange(spec.size, dtype=np.float64)
    f[0] = 1.0
    spec /= np.sqrt(f)
    spec[0] = 0.0
    y = np.fft.irfft(spec, n)
    return y / (np.std(y) + 1e-12)


def brown_circular(n: int, r: np.random.Generator) -> np.ndarray:
    spec = np.fft.rfft(r.standard_normal(n))
    f = np.arange(spec.size, dtype=np.float64)
    f[0] = 1.0
    spec /= f
    spec[0] = 0.0
    y = np.fft.irfft(spec, n)
    return y / (np.std(y) + 1e-12)


def sos_bp(lo: float, hi: float, order: int = 2, sr: int = SR) -> np.ndarray:
    return signal.butter(order, [lo, min(hi, sr * 0.49)], btype="bandpass", fs=sr, output="sos")


def sos_lp(fc: float, order: int = 2, sr: int = SR) -> np.ndarray:
    return signal.butter(order, min(fc, sr * 0.49), btype="lowpass", fs=sr, output="sos")


def sos_hp(fc: float, order: int = 2, sr: int = SR) -> np.ndarray:
    return signal.butter(order, fc, btype="highpass", fs=sr, output="sos")


def peak_eq(f0: float, q: float, gain_db: float, sr: int = SR) -> np.ndarray:
    """RBJ peaking biquad as an SOS row."""
    a = 10 ** (gain_db / 40.0)
    w = 2 * math.pi * f0 / sr
    alpha = math.sin(w) / (2 * q)
    b0, b1, b2 = 1 + alpha * a, -2 * math.cos(w), 1 - alpha * a
    a0, a1, a2 = 1 + alpha / a, -2 * math.cos(w), 1 - alpha / a
    return np.array([[b0 / a0, b1 / a0, b2 / a0, 1.0, a1 / a0, a2 / a0]])


def resonator(f0: float, q: float, sr: int = SR) -> np.ndarray:
    """Constant-peak-gain two-pole bandpass (RBJ BPF, 0 dB peak)."""
    w = 2 * math.pi * f0 / sr
    alpha = math.sin(w) / (2 * q)
    b0, b1, b2 = alpha, 0.0, -alpha
    a0, a1, a2 = 1 + alpha, -2 * math.cos(w), 1 - alpha
    return np.array([[b0 / a0, b1 / a0, b2 / a0, 1.0, a1 / a0, a2 / a0]])


def filt(sos: np.ndarray, x: np.ndarray) -> np.ndarray:
    return signal.sosfilt(sos, x)


def filt_circular(sos: np.ndarray, x: np.ndarray, reps: int = 3) -> np.ndarray:
    """Filter a loop as if it repeated forever: run over reps copies, keep the last."""
    n = x.size
    y = signal.sosfilt(sos, np.tile(x, reps))
    return y[(reps - 1) * n:]


def fft_filter_circular(x: np.ndarray, gain_fn) -> np.ndarray:
    """Zero-phase circular filtering with an arbitrary magnitude response gain_fn(freq_hz)."""
    n = x.size
    spec = np.fft.rfft(x)
    f = np.fft.rfftfreq(n, 1.0 / SR)
    return np.fft.irfft(spec * gain_fn(f), n)


def comb_circular(x: np.ndarray, delay_s: float, fb: float, damp_hz: float,
                  reps: int = 4) -> np.ndarray:
    """Feedback comb (pipe resonance) with a one-pole lowpass in the loop, run circularly.
    H(z) = (1 - c z^-1) / (1 - c z^-1 - fb (1 - c) z^-d)."""
    n = x.size
    d = max(2, int(round(delay_s * SR)))
    c = math.exp(-2 * math.pi * damp_hz / SR)
    b = np.array([1.0, -c])
    a = np.zeros(d + 1)
    a[0], a[1] = 1.0, -c
    a[d] += -fb * (1 - c)
    y = signal.lfilter(b, a, np.tile(x, reps))
    return y[(reps - 1) * n:]


# ----------------------------------------------------------------- envelopes and shapes

def env_ad(n: int, attack_s: float, decay_s: float, curve: float = 4.0) -> np.ndarray:
    t = np.arange(n) / SR
    a = np.clip(t / max(attack_s, 1e-5), 0, 1)
    d = np.exp(-curve * np.clip(t - attack_s, 0, None) / max(decay_s, 1e-5))
    return a * d


def fade_edges(x: np.ndarray, fade_in_s: float = 0.002, fade_out_s: float = 0.01) -> np.ndarray:
    y = x.copy()
    ni = min(int(fade_in_s * SR), y.size // 2)
    no = min(int(fade_out_s * SR), y.size // 2)
    if ni > 0:
        y[:ni] *= np.sin(np.linspace(0, math.pi / 2, ni)) ** 2
    if no > 0:
        y[-no:] *= np.cos(np.linspace(0, math.pi / 2, no)) ** 2
    return y


def trim_tail(x: np.ndarray, thresh_db: float = -70.0, fade_s: float = 0.02) -> np.ndarray:
    a = np.abs(x)
    th = undb(thresh_db) * max(float(a.max()), 1e-9)
    idx = np.nonzero(a > th)[0]
    if idx.size == 0:
        return x
    end = min(x.size, idx[-1] + int(fade_s * SR))
    return fade_edges(x[:end], 0.0, fade_s)


def modal(freqs, decays, amps, dur: float, r: np.random.Generator | None = None) -> np.ndarray:
    """Sum of exponentially decaying sines (modal synthesis). decays in seconds (T60/6.9)."""
    n = int(dur * SR)
    t = np.arange(n) / SR
    y = np.zeros(n)
    for f, d, a in zip(freqs, decays, amps):
        ph = 0.0 if r is None else r.uniform(0, 2 * math.pi)
        y += a * np.sin(2 * math.pi * f * t + ph) * np.exp(-t / d)
    return y


def loop_crossfade(x: np.ndarray, xfade_s: float) -> np.ndarray:
    """Make a seamless loop from a longer clip: overlap the tail onto the head (equal power).
    Output length = len(x) - xfade samples."""
    n = int(xfade_s * SR)
    head, body, tail = x[:n], x[n:-n] if n else x, x[-n:]
    t = np.linspace(0, 1, n, endpoint=False)
    fi, fo = np.sin(t * math.pi / 2), np.cos(t * math.pi / 2)
    mixed = tail * fo + head * fi
    return np.concatenate([mixed, body])


# ----------------------------------------------------------------- analysis

def seam_metrics(x: np.ndarray) -> dict:
    """Loop seam discontinuity: jump across the wrap vs the clip's typical sample step."""
    steps = np.abs(np.diff(x))
    wrap = abs(float(x[0] - x[-1]))
    p99 = float(np.percentile(steps, 99)) + 1e-12
    med = float(np.median(steps)) + 1e-12
    # second-difference (slope) discontinuity catches kinks, not only jumps
    d2 = np.abs(np.diff(x, 2))
    wrap2 = abs(float(x[1] - 2 * x[0] + x[-1]))
    return {
        "wrap_jump": wrap,
        # share of the clip's own sample steps that are smaller than the wrap step:
        # a seamless loop sits anywhere in 0..1 like any other step; a click reads ~1.0
        "wrap_step_percentile": float(np.mean(steps < wrap)),
        "wrap_jump_over_p99_step": wrap / p99,
        "wrap_jump_over_median_step": wrap / med,
        "wrap_kink_over_p99": wrap2 / (float(np.percentile(d2, 99)) + 1e-12),
    }


def spectrogram_png(x: np.ndarray, path: Path | str, title: str, sr: int = SR,
                    fmax: float = 12000.0, nfft: int = 2048, extra_marks=None) -> Path:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    f, t, s = signal.spectrogram(x, fs=sr, nperseg=nfft, noverlap=nfft * 3 // 4,
                                 window="hann", scaling="spectrum")
    s_db = 10 * np.log10(s + 1e-14)
    keep = f <= fmax
    fig, axes = plt.subplots(2, 1, figsize=(14, 7), sharex=True,
                             gridspec_kw={"height_ratios": [3, 1]})
    vmax = float(s_db[keep].max())
    axes[0].pcolormesh(t, f[keep], s_db[keep], shading="auto", cmap="magma",
                       vmin=vmax - 90, vmax=vmax)
    axes[0].set_yscale("symlog", linthresh=500)
    axes[0].set_ylim(30, fmax)
    axes[0].set_ylabel("Hz")
    axes[0].set_title(title)
    hop = max(1, sr // 200)
    env = np.array([np.max(np.abs(x[i:i + hop])) for i in range(0, x.size, hop)])
    te = np.arange(env.size) * hop / sr
    axes[1].plot(te, 20 * np.log10(env + 1e-9), lw=0.6, color="#e44a30")
    axes[1].axhline(-1.0, color="k", lw=0.5, ls="--")
    axes[1].set_ylim(-60, 3)
    axes[1].set_ylabel("peak dBFS")
    axes[1].set_xlabel("s")
    if extra_marks:
        for tm, label in extra_marks:
            for ax in axes:
                ax.axvline(tm, color="#6aa8e8", lw=0.6, alpha=0.7)
            axes[1].text(tm, 0, label, fontsize=6, rotation=90, va="top")
    fig.tight_layout()
    fig.savefig(path, dpi=90)
    plt.close(fig)
    return path


def save_manifest(path: Path | str, data: dict) -> None:
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
