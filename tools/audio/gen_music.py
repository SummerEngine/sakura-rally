"""Music: fetch (cached) fal generations, pick bar-aligned loop points, bake seamless loops.

For each track: decode raw fal output -> beat-track (librosa) -> fit a linear beat grid and
bar phase -> search bar-aligned (A, B) pairs (B - A a whole number of 4-bar phrases, B before
the generated outro/fade) maximising beat-synchronous chroma+MFCC similarity of the context
around A and B -> refine B by waveform cross-correlation (+-15 ms) -> truncate at B and
equal-power crossfade x[B-X:B] with x[A-X:A] -> tone EQ -> -16 LUFS, true peak <= -1 dBTP ->
OGG Vorbis. Writes assets/audio/music/music.json and verification renders.

Run: tools/audio/.venv/bin/python tools/audio/gen_music.py
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path
from typing import NamedTuple

import librosa
import numpy as np
from scipy import signal

sys.path.insert(0, str(Path(__file__).resolve().parent))
import falcache  # noqa: E402
from audio_specs import MUSIC  # noqa: E402
from assetio import read_any, true_peak_db, write_ogg  # noqa: E402
from audiolib import (ASSETS, RENDERS, SR, filt, lufs, peak_eq, peak_db,  # noqa: E402
                      rms_db, seam_metrics, sos_hp, spectrogram_png, undb)

OUT = ASSETS / "music"

class Track(NamedTuple):
    key: str  # fal cache name
    bpm: float  # expected tempo (beat-tracker hint)
    xfade: float  # loop crossfade, seconds
    eq: list  # tone EQ [(f0, q, gain_db)]
    grid_beats: int = 32  # loop points on section starts: 32 = 8-bar sections, 16 = 4-bar phrases
    min_a: float = 0.0  # earliest loop start, seconds
    min_loop: float = 0.0  # shortest acceptable loop, seconds


TRACKS = {
    "menu": Track("music_menu_el", 84, 1.0, []),
    # drive sits under the engine: carve the 150-400 Hz band a little
    "drive": Track("music_drive_el", 104, 0.75, [(260.0, 0.9, -3.0), (120.0, 1.0, -1.5)]),
    "results": Track("music_results_el", 92, 1.0, []),
    # liaison also plays under the engine (untimed drive): a lighter version of drive's carve.
    # Its cymbal-marked sections fall every 4 bars (section phases 0 and 16 score a tie), so
    # loop points may sit on any 4-bar phrase start. The loop starts after the drum-less intro
    # and its full stop at 21-22 s, and is at least 80 s long: a liaison drive lasts minutes,
    # and the best-matching 16-bar loop (45 s) would repeat audibly.
    "liaison": Track("music_liaison_el", 86, 1.0, [(260.0, 0.9, -2.0)], grid_beats=16,
                     min_a=23.0, min_loop=80.0),
}
TARGET_LUFS = -16.0
TP_CEIL_DB = -1.0


def beat_grid(mono: np.ndarray, bpm_hint: float) -> tuple[float, float, np.ndarray, float]:
    """Return (bpm, first_beat_s, beat_times, fit_resid_ms): least-squares line through the
    tracked beats (the generated tracks are metronomic, so a fixed grid is exact)."""
    hop = 256
    oenv = librosa.onset.onset_strength(y=mono.astype(np.float32), sr=SR, hop_length=hop)
    _, beats = librosa.beat.beat_track(onset_envelope=oenv, sr=SR, hop_length=hop,
                                       start_bpm=bpm_hint, tightness=400)
    bt = librosa.frames_to_time(beats, sr=SR, hop_length=hop)
    iv = np.diff(bt)
    idx = np.concatenate([[0], np.cumsum(np.round(iv / np.median(iv)))])
    k, c = np.polyfit(idx, bt, 1)
    res = bt - (k * idx + c)
    keep = np.abs(res) < 3 * res.std() + 1e-4
    k, c = np.polyfit(idx[keep], bt[keep], 1)
    resid_ms = float(1000 * np.std(bt[keep] - (k * idx[keep] + c)))
    # the tracker may lock onto off-beat hi-hats: re-phase the grid onto the kick drum by
    # maximising low-band (<150 Hz) onset strength over one beat period of offsets
    low = signal.sosfilt(signal.butter(4, 150, fs=SR, output="sos"), mono)
    lenv = librosa.onset.onset_strength(y=low.astype(np.float32), sr=SR, hop_length=hop)
    ft = librosa.frames_to_time(np.arange(lenv.size), sr=SR, hop_length=hop)
    offs = np.linspace(0, k, 48, endpoint=False)
    sc = [np.interp(c + d + k * np.arange(int((ft[-1] - c) / k) - 1), ft, lenv).mean()
          for d in offs]
    c = (c + offs[int(np.argmax(sc))]) % k
    n = int((len(mono) / SR - c) / k) + 1
    return 60.0 / k, c, c + k * np.arange(n), resid_ms


def full_level_end(mono: np.ndarray) -> float:
    """Last time the 1 s RMS is within 5 dB of the track median (start of any outro fade)."""
    hop = SR // 4
    r = np.array([np.sqrt(np.mean(mono[i:i + SR] ** 2) + 1e-12)
                  for i in range(0, len(mono) - SR, hop)])
    rdb = 20 * np.log10(r)
    ok = np.nonzero(rdb > np.median(rdb) - 5.0)[0]
    return ok[-1] * hop / SR + 1.0


def features(mono: np.ndarray, beats: np.ndarray) -> np.ndarray:
    frames = librosa.time_to_frames(beats, sr=SR, hop_length=512)
    y = mono.astype(np.float32)
    chroma = librosa.feature.chroma_cqt(y=y, sr=SR, hop_length=512)
    mfcc = librosa.feature.mfcc(y=y, sr=SR, hop_length=512, n_mfcc=20)[1:]
    cs = librosa.util.sync(chroma, frames, aggregate=np.median)
    ms = librosa.util.sync(mfcc, frames, aggregate=np.mean)
    cs = cs / (np.linalg.norm(cs, axis=0, keepdims=True) + 1e-9)
    ms = (ms - ms.mean(1, keepdims=True)) / (ms.std(1, keepdims=True) + 1e-9)
    ms = ms / (np.linalg.norm(ms, axis=0, keepdims=True) + 1e-9)
    return np.vstack([cs, 0.7 * ms])  # column i covers beat i..i+1 (sync prepends 0 frame)


def section_phase(mono: np.ndarray, beats: np.ndarray) -> tuple[int, list]:
    """Which beat mod 32 starts the 8-bar sections. In these arrangements every section is
    announced by a cymbal swell/crash landing on its downbeat, so score each beat by the
    0.25 s-smoothed >6 kHz level in [-0.2 s, +0.3 s] around it relative to the level 1-3 s
    earlier. Returns (phase in beats, top-3 (score, phase))."""
    hf = np.abs(filt(sos_hp(6000, 4), mono))
    hop = SR // 20
    e = np.array([hf[i:i + hop].mean() for i in range(0, len(hf) - hop, hop)])
    edb = np.convolve(20 * np.log10(e + 1e-9), np.ones(5) / 5, mode="same")
    score = np.full(len(beats), np.nan)
    for i, t in enumerate(beats):
        j = int(t * 20)
        if j - 60 >= 0 and j + 6 < edb.size:
            score[i] = edb[j - 4:j + 6].max() - edb[j - 60:j - 20].mean()
    ph = [float(np.nanmean(score[p::32])) for p in range(32)]
    best = int(np.nanargmax(ph))
    return best, sorted(((round(v, 2), p) for p, v in enumerate(ph)), reverse=True)[:3]


def choose_loop(mono: np.ndarray, tr: Track) -> dict:
    """A and B both on section starts every tr.grid_beats (B - A whole sections), A not before
    tr.min_a, B - A at least tr.min_loop, B before the generated outro. Score = context
    similarity around A vs B + a length bonus (long loops repeat less)."""
    bpm, b0, beats, resid_ms = beat_grid(mono, tr.bpm)
    feats = features(mono, beats)
    sec, sec_scores = section_phase(mono, beats)
    end_ok = full_level_end(mono)
    ctx = 8  # beats of context compared on either side of the seam
    best = None
    starts = np.arange(sec % tr.grid_beats, len(beats), tr.grid_beats)  # beat indices of section starts
    for ia in starts:
        A = beats[ia]
        if A < max(4.0, tr.xfade + 1.0, tr.min_a):
            continue
        for ib in starts[starts > ia]:
            B = beats[ib]
            if B > end_ok - 0.5:
                break
            if B - A < tr.min_loop:
                continue
            off = 0 if beats[0] * SR < 512 else 1  # sync prepends a [0, beat0) column
            ja, jb = ia + off, ib + off  # feature column of the beat at A / B
            if jb + ctx >= feats.shape[1] or ja - ctx < 0:
                continue
            fa = feats[:, ja - ctx: ja + ctx]
            fb = feats[:, jb - ctx: jb + ctx]
            sim = float(np.mean(np.sum(fa * fb, axis=0)) / (1 + 0.7 ** 2))
            score = sim + 0.004 * (B - A)
            if best is None or score > best["score"]:
                best = {"A": A, "B": B, "sim": sim, "score": score, "bars": int(ib - ia) // 4}
    best.update({"bpm": bpm, "first_beat": b0, "grid_resid_ms": resid_ms,
                 "section_phase_beats": sec, "section_phase_top3": sec_scores,
                 "full_level_end": end_ok})
    return best


def onset_alignment(mono: np.ndarray, a: int, b: int, max_lag_s: float = 0.04) -> dict:
    """Check (not change) the grid: correlate the onset envelope of the 4 s before A (+1 s
    after) with the same window at B over +-40 ms. Best lag near 0 => no flam in the xfade."""
    hop = 128
    w = 4 * SR

    def env(seg: np.ndarray) -> np.ndarray:
        o = librosa.onset.onset_strength(y=seg.astype(np.float32), sr=SR, hop_length=hop)
        return o - o.mean()

    ref = env(mono[a - w:a + SR])
    lags = range(-int(max_lag_s * SR), int(max_lag_s * SR) + 1, 64)
    cs = []
    for s in lags:
        e = env(mono[b + s - w:b + s + SR])
        cs.append(float(np.dot(ref, e) / (np.linalg.norm(ref) * np.linalg.norm(e) + 1e-12)))
    i = int(np.argmax(cs))
    return {"best_lag_ms": round(list(lags)[i] / SR * 1000, 1), "corr_best": round(cs[i], 3),
            "corr_at_0": round(cs[len(cs) // 2], 3)}


def bake_loop(x: np.ndarray, a: int, b: int, xfade: float) -> np.ndarray:
    n = int(xfade * SR)
    y = x[:b].copy()
    t = (np.arange(n) + 0.5) / n
    fo, fi = np.cos(t * math.pi / 2)[:, None], np.sin(t * math.pi / 2)[:, None]
    y[b - n:b] = x[b - n:b] * fo + x[a - n:a] * fi
    return y


def seam_report(y: np.ndarray, a: int, name: str) -> dict:
    """Join y[B-3s:B] + y[A:A+3s] (what the player hears at the loop) and measure it."""
    w = 3 * SR
    joined = np.concatenate([y[-w:], y[a:a + w]])
    mono = joined.mean(1)
    # sample-level seam jump vs typical step, both channels
    steps = np.abs(np.diff(joined, axis=0))
    jump = np.abs(joined[w] - joined[w - 1])
    p99 = np.percentile(steps, 99, axis=0)
    # RMS continuity: 100 ms windows either side of the seam and 50 ms sliding profile
    r_before = rms_db(mono[w - int(0.1 * SR): w])
    r_after = rms_db(mono[w: w + int(0.1 * SR)])
    hop = int(0.05 * SR)
    prof = [rms_db(mono[i:i + hop]) for i in range(0, len(mono) - hop, hop)]
    dprof = np.abs(np.diff(prof))
    seam_i = w // hop
    # baseline: the same boundary in the untouched source (y[A-0.1s:A] | y[A:A+0.1s]); a
    # downbeat naturally steps up, so the seam step should match this, not zero
    src = y[a - int(0.1 * SR): a + int(0.1 * SR)].mean(1)
    nb = int(0.1 * SR)
    base_step = rms_db(src[nb:]) - rms_db(src[:nb])
    # seam_metrics measures the wrap end->start, so rotate: y[A:A+3s] + y[B-3s:B]
    wrap = seam_metrics(np.concatenate([y[a:a + w], y[-w:]]).mean(1))
    png = RENDERS / f"music_{name}_seam.png"
    spectrogram_png(mono, png, f"{name}: loop seam (B-3s .. B | A .. A+3s), seam at 3.0 s",
                    extra_marks=[(3.0, "seam")])
    return {
        "seam_jump_over_p99_step_LR": [float(jump[0] / p99[0]), float(jump[1] / p99[1])],
        "rms_100ms_before_db": r_before, "rms_100ms_after_db": r_after,
        "rms_step_at_seam_db": float(r_after - r_before),
        "source_baseline_rms_step_at_A_db": float(base_step),
        "rms_50ms_profile_step_at_seam_db": float(dprof[seam_i - 1]),
        "rms_50ms_profile_step_p95_db": float(np.percentile(dprof, 95)),
        "joined_region_metrics": {k: float(v) for k, v in wrap.items()},
        "png": str(png.relative_to(RENDERS.parents[2])),
    }


def process(name: str) -> dict:
    tr = TRACKS[name]
    key, xfade, eq = tr.key, tr.xfade, tr.eq
    spec = MUSIC[key]
    raw = falcache.generate(key, spec["model"], spec["params"])
    x = falcache.decode(raw, 2)
    mono = x.mean(1)
    lp = choose_loop(mono, tr)
    a = int(round(lp["A"] * SR))
    b = int(round(lp["B"] * SR))
    align = onset_alignment(mono, a, b)
    # tone EQ on the continuous source (before baking) so the filter state is seamless at A/B
    for f0, q, g in eq:
        x = np.stack([filt(peak_eq(f0, q, g), x[:, c]) for c in range(2)], axis=1)
    y = bake_loop(x, a, b, xfade)
    # loudness then true-peak ceiling (plain gain; limiter only if still over)
    y = y * undb(TARGET_LUFS - lufs(y))
    tp = true_peak_db(y)
    if tp > TP_CEIL_DB - 0.3:  # headroom for Vorbis overshoot
        y = y * undb(TP_CEIL_DB - 0.3 - tp)
    path = write_ogg(OUT / f"{name}.ogg", y)
    # verify on the decoded OGG (what the game plays)
    z, zsr = read_any(path)
    assert zsr == SR and z.shape[1] == 2
    spectrogram_png(z.mean(1), RENDERS / f"music_{name}.png",
                    f"{name}.ogg (loop A={a / SR:.3f}s marked, B=end)",
                    extra_marks=[(a / SR, "A loop start")])
    rep = {
        "path": str(path.relative_to(ASSETS.parents[1])),
        "source": {"cache": str(raw.relative_to(ASSETS.parents[1])), "model": spec["model"],
                   "params": spec["params"]},
        "duration_s": round(len(z) / SR, 3), "channels": 2, "sample_rate": SR,
        "bpm": round(lp["bpm"], 3), "loop_offset": round(a / SR, 4),
        "loop_end": round(len(z) / SR, 4), "loop_bars": lp["bars"],
        "loop_similarity": round(lp["sim"], 3), "seam_onset_alignment": align,
        "crossfade_s": xfade, "eq": eq,
        "lufs": round(lufs(z), 2), "sample_peak_db": round(peak_db(z), 2),
        "true_peak_db": round(true_peak_db(z), 2),
        "seam": seam_report(z, a, name),
        "png": str((RENDERS / f"music_{name}.png").relative_to(ASSETS.parents[1])),
        "grid": {"first_beat_s": round(lp["first_beat"], 4),
                 "fit_resid_ms": round(lp["grid_resid_ms"], 2),
                 "section_phase_beats": lp["section_phase_beats"],
                 "section_phase_top3": lp["section_phase_top3"],
                 "raw_full_level_end_s": round(lp["full_level_end"], 2)},
    }
    return rep


def main() -> None:
    names = sys.argv[1:] or list(TRACKS)
    manifest_path = OUT / "music.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    reports = {}
    for n in names:
        rep = process(n)
        reports[n] = rep
        manifest[n] = {"loop_offset": rep["loop_offset"], "bpm": rep["bpm"],
                       "length": rep["duration_s"]}
        print(json.dumps({n: rep}, indent=1), flush=True)
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    rp = RENDERS / "music_report.json"
    old = json.loads(rp.read_text()) if rp.exists() else {}
    old.update(reports)
    rp.write_text(json.dumps(old, indent=2) + "\n")


if __name__ == "__main__":
    main()
