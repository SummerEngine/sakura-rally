"""Ambience beds: 90 s seamless circular loops built from cached fal layers + synthesis.

Beds (wind, stream) are resynthesised from the fal source by shuffling long grains with
equal-power crossfades on a circular timeline (non-repeating, seamless by construction).
Events (birds, crows, leaves) are placed at seeded random, non-repeating times; every event
and its reverb tail is added modulo the loop length, so anything crossing the seam wraps.
The fal ElevenLabs SFX outputs carry a faint 200 Hz harmonic hum: all sources are notched.

Run: tools/audio/.venv/bin/python tools/audio/gen_ambience.py [hanami|momiji]
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import numpy as np
from scipy import signal

sys.path.insert(0, str(Path(__file__).resolve().parent))
import falcache  # noqa: E402
import synth_lib as sl  # noqa: E402
from assetio import read_any, true_peak_db, write_ogg  # noqa: E402
from audio_specs import SFX  # noqa: E402
from audiolib import (ASSETS, RENDERS, SR, filt, filt_circular, lufs, peak_db,  # noqa: E402
                      pink_circular, rng, seam_metrics, sos_bp, sos_hp, sos_lp,
                      spectrogram_png, undb)

OUT = ASSETS / "ambience"
LOOP_S = 90.0
TARGET_LUFS = -24.0


# ----------------------------------------------------------------- source prep

def dehum(x: np.ndarray, base: float = 200.0, k_max: int = 12, min_excess_db: float = 6.0,
          q: float = 45.0) -> tuple[np.ndarray, list[float]]:
    """The EL SFX outputs carry a faint hum on the 200 Hz harmonic series (and a 15.6 kHz
    line). Notch only the lines that actually stick out of this clip's spectrum."""
    f, p = signal.welch(x.mean(1), SR, nperseg=32768)
    pdb = 10 * np.log10(p + 1e-20)
    base_db = signal.medfilt(pdb, 301)
    y, hit = x, []
    for fc in [base * k for k in range(1, k_max + 1)] + [15625.0]:
        i = int(np.argmin(np.abs(f - fc)))
        if pdb[i - 2:i + 3].max() - base_db[i] >= min_excess_db:
            b, a = signal.iirnotch(fc, q, SR)
            y = signal.filtfilt(b, a, y, axis=0)
            hit.append(fc)
    return y, hit


def tame_transients(x: np.ndarray, max_over_db: float = 9.0) -> np.ndarray:
    """Soften clicks/crackles that poke out of a bed: where the ~0.1 ms envelope exceeds the
    60 ms envelope by more than max_over_db, pull it back (smoothed gain, stereo-linked)."""
    a = np.abs(x).max(1)
    fast = signal.sosfiltfilt(sos_lp(3000, 1), a)
    slow = signal.sosfiltfilt(sos_lp(8, 1), a)
    lim = slow * undb(max_over_db)
    g = np.minimum(1.0, lim / (fast + 1e-12))
    g = np.minimum.reduce([np.roll(g, s) for s in range(-44, 45, 4)])  # hold +-1 ms
    g = signal.sosfiltfilt(sos_lp(300, 1), g)
    return x * g[:, None]


HUM_LOG: dict[str, list[float]] = {}


def load(name: str) -> np.ndarray:
    spec = SFX[name]
    y, hit = dehum(falcache.decode(falcache.generate(name, spec["model"], spec["params"]), 2))
    HUM_LOG[name] = hit
    return y


def cut(x: np.ndarray, t0: float, t1: float, fade: float = 0.08) -> np.ndarray:
    y = x[int(t0 * SR):int(t1 * SR)].copy()
    n = int(fade * SR)
    w = np.sin(np.linspace(0, math.pi / 2, n)) ** 2
    y[:n] *= w[:, None]
    y[-n:] *= w[::-1][:, None]
    return y


def gate(x: np.ndarray, floor_db: float = -38.0, rel_s: float = 0.12) -> np.ndarray:
    """Soft downward expander on an event clip so its noise floor does not add up in the bed."""
    m = np.abs(x).max(1)
    env = signal.sosfiltfilt(sos_lp(1.0 / rel_s, 1), m)
    thr = undb(floor_db) * env.max()
    g = np.clip(env / thr, 0, 1) ** 2
    return x * g[:, None]


# ----------------------------------------------------------------- circular building

def shuffle_texture(src: np.ndarray, n_out: int, grain_s: float, xfade_s: float, seed: int,
                    exclude: list[tuple[float, float]] = (), skip_s: float = 0.3) -> np.ndarray:
    """Circular granular resynthesis: grains of grain_s from random source offsets, joined by
    equal-power crossfades; the last grain crossfades into the first across the seam."""
    r = rng(seed)
    g, x = int(grain_s * SR), int(xfade_s * SR)
    hop = g - x
    k = int(round(n_out / hop))
    hop = n_out // k
    g = hop + x
    out = np.zeros((n_out, src.shape[1]))
    t = (np.arange(x) + 0.5) / x
    fin, fout = np.sin(t * math.pi / 2), np.cos(t * math.pi / 2)
    lo, hi = int(skip_s * SR), len(src) - g - int(skip_s * SR)
    last = -10 * g
    for i in range(k):
        for _ in range(200):
            off = int(r.integers(lo, hi))
            s0, s1 = off / SR, (off + g) / SR
            bad = any(s1 > a and s0 < b for a, b in exclude)
            if not bad and abs(off - last) > g // 2:
                break
        last = off
        grain = src[off:off + g].copy()
        grain[:x] *= fin[:, None]
        grain[-x:] *= fout[:, None]
        idx = (i * hop + np.arange(g)) % n_out
        np.add.at(out, idx, grain)
    return out


def add_circ(buf: np.ndarray, clip: np.ndarray, t: float, gain_db: float = 0.0) -> None:
    idx = (int(t * SR) + np.arange(len(clip))) % len(buf)
    np.add.at(buf, idx, clip * undb(gain_db))


def place_events(n_events: int, span: float, min_gap: float, seed: int,
                 avoid: list[float] = ()) -> list[float]:
    """Seeded random event times on a circle of length span with a minimum circular spacing."""
    r = rng(seed)
    times: list[float] = []
    tries = 0
    while len(times) < n_events and tries < 10000:
        tries += 1
        t = float(r.uniform(0, span))
        ok = all(min(abs(t - u), span - abs(t - u)) >= min_gap for u in list(times) + list(avoid))
        if ok:
            times.append(t)
    return sorted(times)


def active_scale(clip: np.ndarray, ref_rms: float) -> float:
    """Gain that brings the RMS of the clip's active part (above -20 dB of its peak) to ref."""
    a = np.abs(clip).max(1) if clip.ndim == 2 else np.abs(clip)
    return ref_rms / (float(np.sqrt(np.mean(clip[a > 0.1 * a.max()] ** 2))) + 1e-12)


def distant(clip: np.ndarray, pan: float, lp_hz: float, wet: float, ir: np.ndarray,
            width: float = 1.0) -> np.ndarray:
    """Place a (mono or stereo) event in space: air absorption lowpass, pan, reverb tail."""
    if clip.ndim == 2:
        mono = clip.mean(1)
        side = (clip[:, 0] - clip[:, 1]) * 0.5 * width
    else:
        mono, side = clip, np.zeros_like(clip)
    mono = filt(sos_lp(lp_hz, 2), filt(sos_hp(250, 2), mono))
    st = sl.pan(mono, pan)
    st[:, 0] += filt(sos_lp(lp_hz, 2), side)
    st[:, 1] -= filt(sos_lp(lp_hz, 2), side)
    return sl.reverb(st, wet=wet, ir=ir)


def air_bed(n: int, seed: int, lp_hz: float, gust_s: float, depth: float) -> np.ndarray:
    """Procedural circular air: decorrelated pink noise, lowpassed, slow circular gust LFO."""
    r = rng(seed)
    out = np.zeros((n, 2))
    # gust envelope: smooth circular random curve (sum of integer-cycle sinusoids)
    t = np.arange(n) / n
    env = np.zeros(n)
    for c in range(1, int(LOOP_S / gust_s) + 1):
        env += r.standard_normal() / c ** 0.7 * np.sin(2 * math.pi * c * t + r.uniform(0, 6.28))
    env = (env - env.min()) / (env.max() - env.min() + 1e-9)
    env = (1 - depth) + depth * env
    for ch in range(2):
        p = pink_circular(n, r)
        p = filt_circular(sos_lp(lp_hz, 2), p)
        p = filt_circular(sos_hp(60, 2), p)
        out[:, ch] = p * env
    return out, env


def finish(name: str, mix: np.ndarray, extra_marks: list, meta: dict) -> dict:
    # make the whole loop band-safe (circular filters keep the seam intact)
    mix = np.stack([filt_circular(sos_hp(45, 2), mix[:, c]) for c in range(2)], axis=1)
    mix = mix * undb(TARGET_LUFS - lufs(mix))
    tp = true_peak_db(mix)
    if tp > -1.5:
        mix *= undb(-1.5 - tp)
    path = write_ogg(OUT / f"{name}.ogg", mix, quality=0.5)
    z, _ = read_any(path)
    mono = z.mean(1)
    seamL, seamR = seam_metrics(z[:, 0]), seam_metrics(z[:, 1])
    # RMS continuity across the wrap: last 200 ms vs first 200 ms, vs typical 200 ms step
    w = int(0.2 * SR)
    prof = np.array([np.sqrt(np.mean(mono[i:i + w] ** 2)) for i in range(0, len(mono) - w, w)])
    steps = np.abs(np.diff(20 * np.log10(prof + 1e-9)))
    wrap_rms = abs(20 * np.log10((np.sqrt(np.mean(mono[:w] ** 2)) + 1e-9)
                                 / (np.sqrt(np.mean(mono[-w:] ** 2)) + 1e-9)))
    png = RENDERS / f"amb_{name}.png"
    spectrogram_png(mono, png, f"ambience {name}.ogg ({len(z) / SR:.1f} s loop)",
                    extra_marks=extra_marks)
    wrap = np.concatenate([z[-3 * SR:], z[:3 * SR]]).mean(1)
    png_seam = RENDERS / f"amb_{name}_seam.png"
    spectrogram_png(wrap, png_seam, f"{name}: loop wrap (end-3s | start+3s), seam at 3.0 s",
                    extra_marks=[(3.0, "seam")])
    rep = {
        "path": str(path.relative_to(ASSETS.parents[1])),
        "duration_s": round(len(z) / SR, 3), "channels": z.shape[1],
        "lufs": round(lufs(z), 2), "sample_peak_db": round(peak_db(z), 2),
        "true_peak_db": round(true_peak_db(z), 2),
        "seam_L": {k: round(v, 4) for k, v in seamL.items()},
        "seam_R": {k: round(v, 4) for k, v in seamR.items()},
        "wrap_rms_step_200ms_db": round(wrap_rms, 2),
        "typical_rms_step_200ms_db_p50_p95": [round(float(np.percentile(steps, 50)), 2),
                                              round(float(np.percentile(steps, 95)), 2)],
        "png": str(png.relative_to(ASSETS.parents[1])),
        "png_seam": str(png_seam.relative_to(ASSETS.parents[1])),
        "hum_notches_hz": {k: v for k, v in HUM_LOG.items()}, **meta,
    }
    return rep


# ----------------------------------------------------------------- scenes

def hanami() -> dict:
    n = int(LOOP_S * SR)
    ir_forest = sl.room_ir(dur=2.0, rt60=1.6, damp_hz=4500, seed=41, predelay_s=0.025)
    HUM_LOG.clear()
    breeze = tame_transients(load("amb_hanami_breeze"), 9.0)
    stream = tame_transients(load("amb_hanami_stream"), 12.0)
    birds = load("amb_spring_birds")
    trill1 = load("amb_uguisu_1")
    trill2 = load("amb_uguisu_2")

    bed_breeze = shuffle_texture(breeze, n, 7.0, 2.5, seed=101)
    bed_breeze = np.stack([filt_circular(sos_lp(11000, 2), bed_breeze[:, c]) for c in range(2)], 1)
    air, _ = air_bed(n, 102, lp_hz=900, gust_s=9.0, depth=0.6)
    bed_stream = shuffle_texture(stream, n, 6.0, 2.0, seed=103)
    bed_stream = np.stack([filt_circular(sos_bp(300, 7000, 2), bed_stream[:, c])
                           for c in range(2)], 1)
    # distant stream sits a little to the right and narrow
    m = bed_stream.mean(1)
    bed_stream = 0.35 * bed_stream + 0.65 * sl.pan(m, 0.35)

    mix = undb(0) * bed_breeze + undb(-20) * air / np.sqrt(np.mean(air ** 2)) * \
        np.sqrt(np.mean(bed_breeze ** 2)) + undb(-9) * bed_stream * \
        np.sqrt(np.mean(bed_breeze ** 2)) / (np.sqrt(np.mean(bed_stream ** 2)) + 1e-12)
    bed_rms = float(np.sqrt(np.mean(mix ** 2)))
    marks: list = []
    events: list = []

    def ev(clip, t, level_db, label, pan, lp, wet):
        c = distant(clip, pan, lp, wet, ir_forest)
        add_circ(mix, c * active_scale(clip, bed_rms), t, level_db)
        marks.append((t % LOOP_S, label))
        events.append({"t": round(t % LOOP_S, 2), "what": label, "level_db_vs_bed": level_db,
                       "pan": pan, "lp_hz": lp})

    # uguisu: one bird calling 3 bouts (2 calls ~6-8 s apart), each from a fixed position
    r = rng(104)
    bouts = place_events(3, LOOP_S, 24.0, seed=105)
    for bi, t in enumerate(bouts):
        pan = float(r.uniform(-0.6, 0.6))
        for ci in range(2):
            call = sl.uguisu(variant=int(r.integers(0, 3)), pitch=float(r.uniform(0.95, 1.05)),
                             hoo_s=float(r.uniform(1.0, 1.6)), seed=200 + bi * 7 + ci)
            ev(call, t + ci * float(r.uniform(6.0, 8.5)), float(r.uniform(2.0, 5.0)),
               "uguisu", pan, 6500, 0.45)
    # other spring birds: segments from the fal chorus and the two trills
    segs = [cut(birds, 0.3, 3.95), cut(birds, 4.1, 5.3), cut(birds, 5.5, 7.3),
            cut(birds, 10.6, 13.8), cut(trill1, 1.5, 4.3, 0.15), cut(trill2, 4.1, 5.25, 0.05)]
    segs = [gate(s) for s in segs]
    times = place_events(9, LOOP_S, 6.0, seed=106, avoid=bouts)
    order = rng(107).permutation(9) % len(segs)
    for t, si in zip(times, order):
        ev(segs[si], t, float(r.uniform(-5.0, 0.0)), f"bird{si}", float(r.uniform(-0.9, 0.9)),
           float(r.uniform(5000, 8000)), 0.4)
    meta = {"layers": {
        "breeze_bed": "fal amb_hanami_breeze, dehummed, circular grain shuffle 7 s/2.5 s xfade",
        "air": "procedural circular pink noise LP 900 Hz, slow gust LFO, -20 dB",
        "stream": "fal amb_hanami_stream, dehummed, grain shuffle 6 s/2 s, BP 300-7000, "
                  "panned right/narrow, -9 dB vs breeze",
        "uguisu": "synth_lib.uguisu (synthesised 'hoo-hokekyo'), 3 bouts x 2 calls",
        "birds": "segments of fal amb_spring_birds / amb_uguisu_1 / amb_uguisu_2 (trills), "
                 "gated, air-absorption LP, panned, forest reverb"},
        "events": sorted(events, key=lambda e: e["t"])}
    return finish("hanami", mix, marks, meta)


def momiji() -> dict:
    n = int(LOOP_S * SR)
    ir_valley = sl.room_ir(dur=2.6, rt60=2.2, damp_hz=3500, seed=51, predelay_s=0.04)
    HUM_LOG.clear()
    wind = tame_transients(load("amb_momiji_wind"), 9.0)
    leaves = load("amb_leaves")
    crows = [load("amb_crows_1"), load("amb_crows_2")]
    chorus = tame_transients(load("amb_suzumushi"), 6.0)

    # avoid the tonal 'whistle' artefact at 12.4-16.4 s in the fal wind
    bed_wind = shuffle_texture(wind, n, 6.0, 2.0, seed=201, exclude=[(12.3, 16.6)])
    bed_wind = np.stack([filt_circular(sos_lp(9000, 2), bed_wind[:, c]) for c in range(2)], 1)
    air, _ = air_bed(n, 202, lp_hz=700, gust_s=11.0, depth=0.7)
    ref = np.sqrt(np.mean(bed_wind ** 2))
    mix = bed_wind + undb(-14) * air / np.sqrt(np.mean(air ** 2)) * ref
    # suzumushi: five individual bell crickets at fixed positions + faint distant chorus
    r = rng(203)
    crick = np.zeros((n, 2))
    for i in range(5):
        c = sl.bell_cricket(LOOP_S + 3.0, carrier=float(r.uniform(4100, 4800)),
                            period=float(r.uniform(0.9, 1.4)), seed=300 + i)
        c = c[: n + int(3.0 * SR)]
        gain = undb(float(r.uniform(-9, 0)))
        st = sl.pan(filt(sos_lp(float(r.uniform(6500, 9000)), 2), c), float(r.uniform(-0.85, 0.85)))
        st = sl.reverb(st, wet=0.3, ir=ir_valley)
        add_circ(crick, st * gain, 0.0)
    # 16.8-21.6 s of the fal chorus has loud clicky close insects: leave it out
    ch = shuffle_texture(chorus, n, 6.0, 2.0, seed=204, exclude=[(16.8, 21.6)])
    ch = np.stack([filt_circular(sos_bp(3500, 9000, 2), ch[:, c]) for c in range(2)], 1)
    crick_rms = np.sqrt(np.mean(crick ** 2))
    mix += undb(-6) * ref * crick / crick_rms
    mix += undb(-17) * ref * ch / np.sqrt(np.mean(ch ** 2))
    bed_rms = float(np.sqrt(np.mean(mix ** 2)))
    marks: list = []
    events: list = []

    def ev(clip, t, level_db, label, pan, lp, wet, ir):
        c = distant(clip, pan, lp, wet, ir)
        add_circ(mix, c * active_scale(clip, bed_rms), t, level_db)
        marks.append((t % LOOP_S, label))
        events.append({"t": round(t % LOOP_S, 2), "what": label, "level_db_vs_bed": level_db,
                       "pan": pan, "lp_hz": lp})

    crow_t = place_events(3, LOOP_S, 22.0, seed=205)
    for i, t in enumerate(crow_t):
        ev(sl_trim(crows[i % 2]), t, float(r.uniform(-1.0, 2.0)), f"crow{i % 2 + 1}",
           float(r.uniform(-0.8, 0.8)), 3800, 0.45, ir_valley)
    leaf_t = place_events(5, LOOP_S, 12.0, seed=206)
    for t in leaf_t:
        ev(leaves, t, float(r.uniform(-6.0, -2.0)), "leaves", float(r.uniform(-0.7, 0.7)),
           9000, 0.15, ir_valley)
    meta = {"layers": {
        "wind_bed": "fal amb_momiji_wind, dehummed, grain shuffle 6 s/2 s excluding the "
                    "12.3-16.6 s tonal artefact, LP 9 kHz",
        "air": "procedural circular pink noise LP 700 Hz, gust LFO, -14 dB",
        "suzumushi": "synth_lib.bell_cricket x5 (4.1-4.8 kHz 'riiin' chirps, fixed pans, "
                     "valley reverb) -6 dB vs wind + fal amb_suzumushi chorus BP 3.5-9 kHz "
                     "shuffled at -17 dB",
        "crows": "fal amb_crows_1/2, air-absorption LP 3.8 kHz, valley reverb, 3 events",
        "leaves": "fal amb_leaves, 5 soft rustle gusts"},
        "events": sorted(events, key=lambda e: e["t"])}
    return finish("momiji", mix, marks, meta)


def sl_trim(x: np.ndarray) -> np.ndarray:
    m = np.abs(x).max(1)
    idx = np.nonzero(m > undb(-45) * m.max())[0]
    y = x[max(0, idx[0] - 2000): idx[-1] + int(0.3 * SR)].copy()
    return cut(np.vstack([y, np.zeros((int(0.1 * SR), 2))]), 0, len(y) / SR + 0.1, 0.03)


def main() -> None:
    names = sys.argv[1:] or ["hanami", "momiji"]
    rp = RENDERS / "ambience_report.json"
    rep = json.loads(rp.read_text()) if rp.exists() else {}
    for nm in names:
        rep[nm] = {"hanami": hanami, "momiji": momiji}[nm]()
        print(json.dumps({nm: {k: v for k, v in rep[nm].items() if k != "events"}}, indent=1))
    rp.write_text(json.dumps(rep, indent=2) + "\n")


if __name__ == "__main__":
    main()
