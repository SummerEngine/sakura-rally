"""Offline synthesis of the Sakura Rally engine sets.

Two sets share one physical model with different parameters (`PROFILES`):
  turbo4  the Sakura: 2.0 turbo inline-4 rally engine (assets/audio/engine/)
  na4     the Hayate: 1.6 naturally aspirated twin-cam inline-4, redline ~8000
          (assets/audio/engine/na4/)

Outputs per set (44.1 kHz mono 16-bit WAV):
  engine_on_<rpm>.wav / engine_off_<rpm>.wav   seamless loops at RPM points (off from 1750)
  engine_idle.wav                              seamless idle loop (turbo4 900, na4 1000 rpm)
  backfire_1..4.wav                            overrun / lift-off pops
  shift_up_1..2.wav, shift_down_1..2.wav       gear-change clunks (turbo4 dog box, na4 synchro)
  engine_loops.json                            exact loop rpm for runtime pitch = rpm / loop_rpm
turbo4 only (shared gearbox whine lives with it):
  turbo_whistle.wav                            seamless spool/whistle loop (pitch follows boost)
  gear_whine.wav                               seamless gearbox whine loop (both cars play it)
  bov_1.wav, bov_2.wav, bov_flutter.wav        blow-off valve one-shots

Every loop is synthesised circularly (exact integer number of engine cycles, all filters
run to steady state over repeated copies), so the wrap from the last sample to the first
is as continuous as any other pair of neighbouring samples.

Run: tools/audio/.venv/bin/python tools/audio/synth_engine.py [turbo4|na4 ...]
"""

from __future__ import annotations

import math
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np

import audiolib as al

SR = al.SR

RPM_POINTS = [1000, 1750, 2500, 3500, 4500, 5500, 6500, 7500]
LOOP_SECONDS = 2.2

# Firing order 1-3-4-2: which cylinder fires in each quarter of the 720 deg cycle.
FIRING_ORDER = [0, 2, 3, 1]


@dataclass(frozen=True)
class Profile:
    """Physical parameters of one engine set (see docs/AUDIO.md, "Engine synthesis model")."""
    key: str
    out: Path
    idle_rpm: float
    # Per-cylinder charge / timing differences -> half-order (cycle-rate) sub-harmonics.
    cyl_amp: tuple[float, float, float, float]
    cyl_timing: tuple[float, float, float, float]  # fraction of the firing interval
    pulse_rise_s: float
    pulse_decay: tuple[float, float]  # decay tau = a + b * firing interval
    header_refl: tuple[float, float]  # reflection delay s, strength
    tailpipe: tuple[float, float, float]  # comb delay s, feedback, loop damping Hz
    midpipe: tuple[float, float, float]
    body_hp_hz: float
    body_eq: tuple[tuple[float, float, float, float], ...]  # (f0, q, gain on, gain off)
    muffler_lp: tuple[float, float]  # on, off
    rasp_band: tuple[float, float]
    rasp_peak: tuple[float, float, float]
    rasp_env_exp: float
    intake_band: tuple[float, float]
    intake_peak: tuple[float, float, float]
    # mix weights: on (ex, rasp a, rasp b, intake a, intake b, ticks, belt, rumble) with
    # rasp/intake = a + b * x01; idle (ex, rasp, intake, ticks, belt, rumble);
    # off (ex, rasp a, rasp b, intake, ticks, belt, rumble, crackle)
    mix_on: tuple[float, ...]
    drive_on: tuple[float, float]
    mix_idle: tuple[float, ...]
    drive_idle: float
    mix_off: tuple[float, ...]
    drive_off: float
    off_hp: tuple[float, float]
    target_on: tuple[float, float, float]  # dB rel: a + b * x^c
    target_idle: float
    off_below_on: tuple[float, float]  # off = on - a + b * x
    # NA induction: harmonic intake-pulse howl through airbox/runner resonances
    howl_res: tuple[tuple[float, float, float], ...] = ()
    howl_on: tuple[float, float, float] = (0.0, 0.0, 1.0)  # a + b * x01^c
    howl_idle: float = 0.0
    howl_off: float = 0.0
    howl_rough: float = 0.0
    throttle_hiss_off: float = 0.0  # air rushing past the closed butterfly on overrun


TURBO4 = Profile(
    key="turbo4", out=al.ASSETS / "engine", idle_rpm=900.0,
    cyl_amp=(1.00, 0.89, 1.09, 0.95), cyl_timing=(0.0, 0.021, -0.017, 0.011),
    pulse_rise_s=0.00016, pulse_decay=(0.0004, 0.11), header_refl=(0.0034, 0.55),
    tailpipe=(0.0098, 0.42, 1600.0), midpipe=(0.0043, 0.25, 2600.0),
    body_hp_hz=28.0,
    body_eq=((95.0, 1.1, 4.5, 1.5), (230.0, 1.4, 3.0, 0.5), (520.0, 1.8, 2.0, 2.0),
             (1350.0, 1.2, -3.5, -3.5), (2600.0, 2.0, 0.5, 1.0)),
    muffler_lp=(3600.0, 2700.0),
    rasp_band=(420.0, 4200.0), rasp_peak=(1900.0, 1.5, 4.0), rasp_env_exp=2.2,
    intake_band=(700.0, 3200.0), intake_peak=(1150.0, 3.0, 6.0),
    mix_on=(1.0, 0.15, 0.18, 0.07, 0.15, 0.035, 0.012, 0.35), drive_on=(1.1, 0.8),
    mix_idle=(1.0, 0.16, 0.06, 0.05, 0.012, 0.45), drive_idle=1.0,
    mix_off=(0.8, 0.11, 0.10, 0.03, 0.07, 0.018, 0.18, 0.22), drive_off=0.7,
    off_hp=(70.0, 40.0),
    target_on=(-22.0, 8.0, 0.8), target_idle=-23.5, off_below_on=(7.5, 1.5),
)

# The Hayate's 1.6 twin-cam: shorter, sharper blowdown pulses straight into a 4-2-1 header
# (no turbine to smooth them), short pipes and a small free-flowing muffler, so energy sits
# an octave higher than the turbo car; a big harmonic induction howl from the airbox that
# grows with rpm and load; crisper, better balanced firing (less half-order gruffness);
# more audible valvetrain; overrun is thin, with air sucking past the closed throttle.
NA4 = Profile(
    key="na4", out=al.ASSETS / "engine" / "na4", idle_rpm=1000.0,
    cyl_amp=(1.00, 0.95, 1.05, 0.97), cyl_timing=(0.0, 0.012, -0.010, 0.006),
    pulse_rise_s=0.00011, pulse_decay=(0.0003, 0.075), header_refl=(0.0026, 0.5),
    tailpipe=(0.0072, 0.38, 2400.0), midpipe=(0.0031, 0.22, 3400.0),
    body_hp_hz=48.0,
    body_eq=((135.0, 1.1, 2.0, 0.5), (320.0, 1.4, 2.5, 0.5), (760.0, 1.6, 2.5, 1.5),
             (1850.0, 1.5, 2.0, 1.0), (3300.0, 2.0, 1.5, 2.0)),
    muffler_lp=(5600.0, 4000.0),
    rasp_band=(700.0, 6500.0), rasp_peak=(2700.0, 1.4, 5.0), rasp_env_exp=2.8,
    intake_band=(900.0, 4800.0), intake_peak=(1700.0, 3.0, 7.0),
    mix_on=(1.0, 0.20, 0.26, 0.10, 0.20, 0.05, 0.010, 0.18), drive_on=(1.35, 1.0),
    mix_idle=(1.0, 0.20, 0.08, 0.07, 0.012, 0.28), drive_idle=1.1,
    mix_off=(0.75, 0.12, 0.12, 0.05, 0.09, 0.016, 0.10, 0.18), drive_off=0.75,
    off_hp=(95.0, 55.0),
    target_on=(-23.0, 9.5, 0.9), target_idle=-24.0, off_below_on=(8.0, 1.5),
    howl_res=((1650.0, 3.5, 9.0), (2450.0, 4.0, 7.0), (3900.0, 3.0, 4.0)),
    howl_on=(0.12, 0.62, 1.3), howl_idle=0.06, howl_off=0.10, howl_rough=0.35,
    throttle_hiss_off=0.06,
)

PROFILES = {p.key: p for p in (TURBO4, NA4)}


def loop_geometry(rpm: float) -> tuple[int, int, float]:
    """(cycles, samples, exact_rpm) for a loop holding an integer number of 720 deg cycles."""
    tc = 120.0 / rpm
    cycles = max(4, int(round(LOOP_SECONDS / tc)))
    n = int(round(cycles * tc * SR))
    exact_rpm = cycles * 120.0 * SR / n
    return cycles, n, exact_rpm


def blowdown_pulse_spectrum(f: np.ndarray, tau_rise: float, tau_decay: float) -> np.ndarray:
    """Spectrum of p(t) = (1 - exp(-t/tr)) exp(-t/td): the steep-fronted pressure pulse an
    exhaust valve releases. Falls ~6 dB/oct above 1/(2 pi td) and 12 dB/oct above 1/(2 pi tr),
    so the firing harmonics stay present well into the kHz range (the engine 'buzz')."""
    w = 2j * math.pi * f
    tc = 1.0 / (1.0 / tau_rise + 1.0 / tau_decay)
    return tau_decay / (1.0 + w * tau_decay) - tc / (1.0 + w * tc)


def place_events(n: int, times: np.ndarray, amps: np.ndarray, pulse_spec: np.ndarray) -> np.ndarray:
    """Circular pulse train with sub-sample event times (frequency-domain placement)."""
    f = np.fft.rfftfreq(n, 1.0 / SR)
    acc = np.zeros(f.size, dtype=np.complex128)
    w = -2j * math.pi * f
    for s in range(0, times.size, 48):
        t = times[s:s + 48, None]
        a = amps[s:s + 48, None]
        acc += np.sum(a * np.exp(w[None, :] * t), axis=0)
    return np.fft.irfft(acc * pulse_spec * SR, n)


def periodic_lfo(n: int, r: np.random.Generator, depth: float, max_cycles: int = 5) -> np.ndarray:
    """Slow wobble made of sinusoids with integer cycles per loop (stays seamless)."""
    t = np.arange(n) / n
    y = np.zeros(n)
    for k in range(1, max_cycles + 1):
        y += r.uniform(0.3, 1.0) / k * np.sin(2 * math.pi * k * t + r.uniform(0, 2 * math.pi))
    y /= np.max(np.abs(y)) + 1e-12
    return 1.0 + depth * y


def smooth_env_circular(x: np.ndarray, fc: float) -> np.ndarray:
    return np.maximum(al.filt_circular(al.sos_lp(fc, 2), np.abs(x)), 0.0)


def induction_howl(p: Profile, n: int, cycles: int, fire_dt: float, r: np.random.Generator) -> np.ndarray:
    """NA intake howl: each intake stroke (half an interval after its firing event) sends a
    sharp suction pulse into the airbox; the pulse train rings the airbox/runner resonances,
    so the howl is harmonic (firing-order partials lit up around 1.6-4 kHz) and rises with
    rpm. A little slow noise on its amplitude gives the rasp of a real induction note."""
    events = cycles * 4
    k = np.arange(events)
    cyl = np.array(FIRING_ORDER)[k % 4]
    times = np.mod((k + 0.5 + np.array(p.cyl_timing)[cyl] * 0.5 + r.normal(0, 0.003, events)) * fire_dt,
                   n / SR)
    amps = np.array(p.cyl_amp)[cyl] * r.normal(1.0, 0.04, events)
    f = np.fft.rfftfreq(n, 1.0 / SR)
    pulses = place_events(n, times, np.clip(amps, 0.0, None),
                          blowdown_pulse_spectrum(f, 0.00009, 0.0002 + 0.05 * fire_dt))
    res = [al.sos_bp(500.0, 6500.0, 2)] + [al.peak_eq(f0, q, g) for f0, q, g in p.howl_res]
    y = al.filt_circular(np.vstack(res), pulses)
    rough = al.filt_circular(al.sos_lp(2500.0, 2), al.white(n, r))
    rough /= np.std(rough) + 1e-12
    y *= 1.0 + p.howl_rough * np.tanh(rough)
    return y / (np.std(y) + 1e-12)


def engine_loop(p: Profile, rpm_nominal: float, load: str, seed: int) -> tuple[np.ndarray, float]:
    r = al.rng(seed)
    cycles, n, rpm = loop_geometry(rpm_nominal)
    tc = 120.0 / rpm
    fire_dt = tc / 4.0
    x01 = min(max((rpm - 900.0) / 6600.0, 0.0), 1.0)  # 0 at idle, 1 near redline
    on = load in ("on", "idle")
    idle = load == "idle"
    cyl_amp = np.array(p.cyl_amp)
    cyl_timing = np.array(p.cyl_timing)

    # ---------------------------------------------------------------- firing events
    events = cycles * 4
    k = np.arange(events)
    cyl = np.array(FIRING_ORDER)[k % 4]
    jitter_amp = 0.05 if load == "on" else (0.12 if idle else 0.22)
    times = (k + cyl_timing[cyl] + r.normal(0, 0.004, events)) * fire_dt
    amps = cyl_amp[cyl] * r.normal(1.0, jitter_amp, events)
    if idle:
        amps *= np.where(cyl == 2, 1.12, 1.0)  # lumpy idle: one cylinder a bit stronger
    if load == "off":
        # overrun: combustion is lean and irregular; some events almost vanish
        drop = r.random(events) < 0.18
        amps[drop] *= r.uniform(0.05, 0.35, drop.sum())
    times = np.mod(times, n / SR)
    amps = np.clip(amps, 0.0, None)

    # Blowdown pulse gets shorter with rpm (valve open time shrinks), then a reflected
    # rarefaction from the header collector a few ms later gives the header "comb".
    f = np.fft.rfftfreq(n, 1.0 / SR)
    spec = blowdown_pulse_spectrum(f, p.pulse_rise_s, p.pulse_decay[0] + p.pulse_decay[1] * fire_dt)
    refl, refl_gain = p.header_refl
    spec = spec * (1.0 - refl_gain * np.exp(-2j * math.pi * f * refl))
    pulses = place_events(n, times, amps, spec)
    pulses /= np.std(pulses) + 1e-12

    # ---------------------------------------------------------------- exhaust system
    ex = al.comb_circular(pulses, delay_s=p.tailpipe[0], fb=p.tailpipe[1], damp_hz=p.tailpipe[2])
    ex = al.comb_circular(ex, delay_s=p.midpipe[0], fb=p.midpipe[1], damp_hz=p.midpipe[2])
    body = np.vstack([al.sos_hp(p.body_hp_hz, 2)]
                     + [al.peak_eq(f0, q, g_on if on else g_off) for f0, q, g_on, g_off in p.body_eq]
                     + [al.sos_lp(p.muffler_lp[0] if on else p.muffler_lp[1], 2)])
    ex = al.filt_circular(body, ex)
    ex /= np.std(ex) + 1e-12

    # Exhaust rasp: broadband combustion noise gated by the pulse envelope.
    env = smooth_env_circular(pulses, 900.0)
    env /= np.max(env) + 1e-12
    rasp_noise = al.white(n, r) * env ** p.rasp_env_exp
    rasp = al.filt_circular(np.vstack([al.sos_bp(*p.rasp_band, 2), al.peak_eq(*p.rasp_peak)]), rasp_noise)
    rasp /= np.std(rasp) + 1e-12

    # Induction: intake strokes interleave the firing events (offset half an interval).
    intake_env = np.zeros(n)
    it = np.mod((k + 0.5 + r.normal(0, 0.01, events)) * fire_dt, n / SR)
    idx = (it * SR).astype(int) % n
    intake_env[idx] = 1.0
    intake_env = al.filt_circular(al.sos_lp(min(60.0 + rpm / 60.0 * 2.0, 400.0), 2), intake_env)
    intake_env = np.maximum(intake_env / (np.max(intake_env) + 1e-12), 0.0)
    intake = al.white(n, r) * (0.35 + intake_env)
    intake = al.filt_circular(np.vstack([al.sos_bp(*p.intake_band, 2), al.peak_eq(*p.intake_peak)]), intake)
    intake /= np.std(intake) + 1e-12

    # Mechanical: valvetrain ticks (16 valves), timing-belt order tone, block rumble.
    crank_hz = rpm / 60.0
    t = np.arange(n) / SR
    ticks = np.zeros(n)
    vk = np.arange(cycles * 16)
    vt = np.mod((vk + r.normal(0, 0.02, vk.size)) * tc / 16.0, n / SR)
    np.add.at(ticks, (vt * SR).astype(int) % n, r.uniform(0.3, 1.0, vk.size))
    ticks = al.filt_circular(np.vstack([al.sos_bp(3200.0, 8500.0, 2)]), ticks)
    ticks /= np.std(ticks) + 1e-12
    belt = np.sin(2 * math.pi * 21.0 * crank_hz * t) * (0.7 + 0.3 * np.sin(2 * math.pi * crank_hz * t))
    belt += 0.3 * np.sin(2 * math.pi * 42.0 * crank_hz * t)
    rumble = al.filt_circular(al.sos_lp(140.0, 2), al.white(n, r) * (0.4 + env))
    rumble /= np.std(rumble) + 1e-12

    # Off-throttle burble: sparse unburnt-fuel crackles in the hot exhaust (seamless: events
    # are placed circularly and filtered in steady state).
    crackle = np.zeros(n)
    if load == "off":
        rate = 5.0 + 22.0 * math.exp(-((rpm - 3800.0) / 2200.0) ** 2)
        count = r.poisson(rate * n / SR)
        for _ in range(count):
            start = r.integers(0, n)
            ln = int(r.uniform(0.002, 0.009) * SR)
            burst = al.white(ln, r) * np.exp(-np.linspace(0, 5, ln)) * r.uniform(0.3, 1.0)
            crackle[(start + np.arange(ln)) % n] += burst
        crackle = al.filt_circular(np.vstack([al.sos_bp(600.0, 4500.0, 2)]), crackle)
        crackle /= np.std(crackle) + 1e-12

    # ---------------------------------------------------------------- mix
    if load == "on":
        w_ex, ra, rb, ia, ib, w_ti, w_be, w_ru = p.mix_on
        mix = (w_ex * ex + (ra + rb * x01) * rasp + (ia + ib * x01) * intake
               + w_ti * ticks + w_be * belt + w_ru * rumble)
        drive = p.drive_on[0] + p.drive_on[1] * x01
    elif idle:
        w_ex, w_ra, w_in, w_ti, w_be, w_ru = p.mix_idle
        mix = w_ex * ex + w_ra * rasp + w_in * intake + w_ti * ticks + w_be * belt + w_ru * rumble
        drive = p.drive_idle
    else:
        w_ex, ra, rb, w_in, w_ti, w_be, w_ru, w_cr = p.mix_off
        mix = (w_ex * ex + (ra + rb * x01) * rasp + w_in * intake + w_ti * ticks
               + w_be * belt + w_ru * rumble + w_cr * crackle)
        drive = p.drive_off
        mix = al.filt_circular(al.sos_hp(p.off_hp[0] + p.off_hp[1] * x01, 2), mix)
    if p.howl_res:
        # separate generator: the NA-only layers never shift the shared layers' random draws
        r2 = al.rng(seed + 7919)
        howl = induction_howl(p, n, cycles, fire_dt, r2)
        if load == "on":
            a, b, c = p.howl_on
            mix = mix + (a + b * x01 ** c) * howl
        elif idle:
            mix = mix + p.howl_idle * howl
        else:
            hiss = al.filt_circular(np.vstack([al.sos_bp(2500.0, 7000.0, 2), al.peak_eq(3800.0, 5.0, 6.0)]),
                                    al.white(n, r2) * (0.3 + intake_env))
            hiss /= np.std(hiss) + 1e-12
            mix = mix + p.howl_off * howl + p.throttle_hiss_off * (0.4 + x01) * hiss
    mix *= periodic_lfo(n, r, 0.05 if not idle else 0.09)
    mix /= np.percentile(np.abs(mix), 99.9) + 1e-12
    mix = np.tanh(drive * mix) / math.tanh(drive)
    mix -= np.mean(mix)
    return al.rotate_to_quiet_zero_crossing(mix), rpm


def target_rms_db(p: Profile, rpm: float, load: str) -> float:
    x = min(max((rpm - 1000.0) / 6500.0, 0.0), 1.0)
    a, b, c = p.target_on
    on_db = a + b * x ** c
    if load == "on":
        return on_db
    if load == "idle":
        return p.target_idle
    return on_db - p.off_below_on[0] + p.off_below_on[1] * x


# ======================================================================== accessory loops (turbo4 set; both cars play the gear whine)

def turbo_whistle() -> np.ndarray:
    """Compressor whistle + air rush. Base tone 3.0 kHz at pitch_scale 1."""
    r = al.rng(71)
    n = int(round(2.0 * SR))
    t = np.arange(n) / SR
    per = n / SR

    def hz(fq: float) -> float:  # snap to integer cycles per loop so it wraps perfectly
        return round(fq * per) / per

    vib = 0.004 * np.sin(2 * math.pi * hz(5.0) * t) + 0.002 * np.sin(2 * math.pi * hz(1.5) * t)
    f0 = hz(3000.0)
    phase = al.loop_phase(f0 * (1.0 + vib))
    tone = np.sin(phase) + 0.18 * np.sin(2 * phase) + 0.05 * np.sin(3 * phase)
    tone *= periodic_lfo(n, r, 0.15, 4)
    air = al.filt_circular(np.vstack([al.sos_bp(2400.0, 7500.0, 2)]), al.white(n, r))
    air /= np.std(air) + 1e-12
    whoosh = al.filt_circular(np.vstack([al.sos_bp(350.0, 1600.0, 2)]), al.white(n, r))
    whoosh /= np.std(whoosh) + 1e-12
    y = 0.55 * tone + 0.30 * air + 0.22 * whoosh
    return al.rotate_to_quiet_zero_crossing(y - np.mean(y))


def gear_whine() -> np.ndarray:
    """Straight-cut gear mesh whine: 900 Hz mesh tone (~82 km/h), shaft-order sidebands."""
    r = al.rng(33)
    n = int(round(2.0 * SR))
    t = np.arange(n) / SR
    per = n / SR

    def hz(fq: float) -> float:
        return round(fq * per) / per

    mesh = hz(900.0)
    shaft = hz(900.0 / 29.0)
    y = np.zeros(n)
    for h, a in ((1, 1.0), (2, 0.42), (3, 0.16), (4, 0.06)):
        y += a * np.sin(2 * math.pi * h * mesh * t + r.uniform(0, 6.28))
        for sb, sa in ((-1, 0.22), (1, 0.18), (-2, 0.07), (2, 0.06)):
            y += a * sa * np.sin(2 * math.pi * (h * mesh + sb * shaft) * t + r.uniform(0, 6.28))
    y *= 0.8 + 0.2 * np.sin(2 * math.pi * shaft * t)
    hiss = al.filt_circular(np.vstack([al.sos_bp(mesh * 0.9, mesh * 1.1, 2)]), al.white(n, r))
    hiss /= np.std(hiss) + 1e-12
    y = y / (np.std(y) + 1e-12) + 0.25 * hiss
    return al.rotate_to_quiet_zero_crossing(y - np.mean(y))


# ======================================================================== one-shots

def bov(seed: int, dur: float, f_hi: float, f_lo: float) -> np.ndarray:
    """Blow-off valve 'pssh': air release with a downward-sweeping band and a valve chirp."""
    r = al.rng(seed)
    n = int(dur * SR)
    t = np.arange(n) / SR
    noise = al.white(n, r)
    y = np.zeros(n)
    # time-varying band: process in overlapping blocks with a moving bandpass
    blk = 512
    centre = f_lo + (f_hi - f_lo) * np.exp(-t / (dur * 0.35))
    win = np.hanning(blk * 2)
    for s in range(0, n - blk, blk):
        seg = noise[s:s + blk * 2]
        if seg.size < blk * 2:
            break
        c = centre[s + blk]
        yb = al.filt(np.vstack([al.sos_bp(c * 0.55, c * 1.6, 2)]), seg) * win
        y[s:s + blk * 2] += yb
    env = al.env_ad(n, 0.004, dur * 0.28, 3.0) * (1.0 + 0.6 * np.exp(-t / 0.03))
    chirp_f = 2600.0 + 1800.0 * np.exp(-t / 0.02)
    chirp = np.sin(2 * math.pi * np.cumsum(chirp_f) / SR) * np.exp(-t / 0.025) * 0.35
    y = y / (np.std(y) + 1e-12) * env + chirp
    return al.fade_edges(y, 0.001, 0.03)


def bov_flutter(seed: int) -> np.ndarray:
    """Compressor surge 'stu-tu-tu-tu': air chuffs at ~16 Hz with decaying strength."""
    r = al.rng(seed)
    dur = 0.75
    n = int(dur * SR)
    y = np.zeros(n)
    t0 = 0.0
    amp = 1.0
    rate = 17.0
    while t0 < dur - 0.08 and amp > 0.08:
        ln = int(0.05 * SR)
        s = int(t0 * SR)
        chuff = al.white(ln, r) * al.env_ad(ln, 0.003, 0.035, 3.5)
        chuff = al.filt(np.vstack([al.sos_bp(500.0, 3200.0, 2), al.peak_eq(1100.0, 2.0, 5.0)]), chuff)
        thump = np.sin(2 * math.pi * 140.0 * np.arange(ln) / SR) * al.env_ad(ln, 0.002, 0.02, 4)
        e = min(n, s + ln)
        y[s:e] += amp * (chuff[: e - s] / (np.std(chuff) + 1e-12) * 0.6 + 0.4 * thump[: e - s])
        t0 += 1.0 / rate * r.uniform(0.9, 1.1)
        rate *= 0.96
        amp *= 0.72
    return al.fade_edges(y, 0.001, 0.02)


def backfire(seed: int) -> np.ndarray:
    """Anti-lag/overrun pop: sharp crack + pipe boom + optional secondary crackles."""
    r = al.rng(seed)
    dur = 0.6
    n = int(dur * SR)
    t = np.arange(n) / SR
    crack = al.white(n, r) * np.exp(-t / r.uniform(0.0015, 0.003))
    crack = al.filt(np.vstack([al.sos_hp(900.0, 2)]), crack)
    f_boom = r.uniform(75.0, 115.0)
    fb = f_boom * (1.0 + 0.6 * np.exp(-t / 0.015))
    boom = np.sin(2 * math.pi * np.cumsum(fb) / SR) * np.exp(-t / r.uniform(0.035, 0.06))
    body = al.filt(np.vstack([al.sos_bp(200.0, 2400.0, 2)]), al.white(n, r)) * np.exp(-t / 0.02)
    y = 0.9 * crack / (np.max(np.abs(crack)) + 1e-12) + 1.0 * boom + 0.5 * body / (np.max(np.abs(body)) + 1e-12)
    for _ in range(int(r.integers(0, 4))):
        dt = r.uniform(0.05, 0.3)
        s = int(dt * SR)
        ln = int(0.03 * SR)
        a = r.uniform(0.2, 0.55)
        sub = al.white(ln, r) * np.exp(-np.arange(ln) / SR / 0.004)
        sub = al.filt(np.vstack([al.sos_bp(500.0, 5000.0, 2)]), sub)
        subb = np.sin(2 * math.pi * f_boom * 1.3 * np.arange(ln) / SR) * np.exp(-np.arange(ln) / SR / 0.012)
        y[s:s + ln] += a * (sub / (np.max(np.abs(sub)) + 1e-12) + 0.7 * subb)
    y = al.comb_circular(np.concatenate([y, np.zeros(int(0.05 * SR))]), 0.0098, 0.35, 1800.0, reps=1)
    y = np.tanh(1.6 * y / (np.max(np.abs(y)) + 1e-12))
    return al.trim_tail(al.fade_edges(y, 0.0005, 0.05), -60.0)


def shift_clunk(seed: int, down: bool) -> np.ndarray:
    """Sequential dog-box shift: lever click, dog engagement clack, drivetrain thunk."""
    r = al.rng(seed)
    dur = 0.35
    n = int(dur * SR)
    t = np.arange(n) / SR
    y = np.zeros(n)
    base = r.uniform(0.9, 1.1) * (0.86 if down else 1.0)
    # lever / linkage click
    click = al.modal([4100 * base, 6300 * base], [0.004, 0.003], [0.4, 0.25], dur, r)
    # dog engagement: inharmonic steel partials, short
    clack_off = int((0.012 + r.uniform(0, 0.006)) * SR)
    clack = al.modal(np.array([1150, 1870, 2730, 3420, 4480]) * base,
                     [0.030, 0.022, 0.016, 0.012, 0.008], [1.0, 0.7, 0.55, 0.35, 0.2], dur, r)
    clack *= np.minimum(1.0, t / 0.0008)
    thunk = al.modal([118 * base, 190 * base], [0.045, 0.03], [1.0, 0.5], dur, r)
    thunk *= np.minimum(1.0, t / 0.002)
    grit = al.filt(np.vstack([al.sos_bp(900.0, 5000.0, 2)]), al.white(n, r)) * np.exp(-t / 0.01)
    y += 0.35 * click
    y[clack_off:] += (0.8 * clack + 1.1 * thunk + 0.25 * grit / (np.max(np.abs(grit)) + 1e-12))[: n - clack_off]
    if down:
        # downshift: second smaller engagement as the blip catches the dog
        off2 = clack_off + int(0.055 * SR)
        y[off2:] += 0.45 * (clack + thunk)[: n - off2]
    return al.trim_tail(al.fade_edges(y, 0.0005, 0.04), -60.0)


def backfire_na(seed: int) -> np.ndarray:
    """NA lift-off pop: a small hot exhaust, so a sharper, higher crack with a short, tighter
    boom from the shorter tailpipe and often a trailing 'pap-pap-crackle' of secondary pops."""
    r = al.rng(seed)
    dur = 0.55
    n = int(dur * SR)
    t = np.arange(n) / SR
    crack = al.white(n, r) * np.exp(-t / r.uniform(0.0009, 0.0018))
    crack = al.filt(np.vstack([al.sos_hp(1400.0, 2), al.peak_eq(3200.0, 1.2, 4.0)]), crack)
    f_boom = r.uniform(120.0, 165.0)
    fb = f_boom * (1.0 + 0.5 * np.exp(-t / 0.01))
    boom = np.sin(2 * math.pi * np.cumsum(fb) / SR) * np.exp(-t / r.uniform(0.022, 0.035))
    body = al.filt(np.vstack([al.sos_bp(350.0, 3800.0, 2)]), al.white(n, r)) * np.exp(-t / 0.012)
    y = 1.0 * crack / (np.max(np.abs(crack)) + 1e-12) + 0.7 * boom + 0.5 * body / (np.max(np.abs(body)) + 1e-12)
    t_sub = 0.0
    for _ in range(int(r.integers(1, 5))):
        t_sub += r.uniform(0.035, 0.11)
        s = int(t_sub * SR)
        ln = int(0.025 * SR)
        if s + ln >= n:
            break
        a = r.uniform(0.25, 0.6)
        u = np.arange(ln) / SR
        sub = al.filt(np.vstack([al.sos_bp(900.0, 7000.0, 2)]), al.white(ln, r) * np.exp(-u / 0.0025))
        subb = np.sin(2 * math.pi * f_boom * 1.2 * u) * np.exp(-u / 0.009)
        y[s:s + ln] += a * (sub / (np.max(np.abs(sub)) + 1e-12) + 0.5 * subb)
    y = al.comb_circular(np.concatenate([y, np.zeros(int(0.05 * SR))]), 0.0072, 0.32, 2400.0, reps=1)
    y = np.tanh(1.8 * y / (np.max(np.abs(y)) + 1e-12))
    return al.trim_tail(al.fade_edges(y, 0.0005, 0.05), -60.0)


def shift_synchro(seed: int, down: bool) -> np.ndarray:
    """H-pattern synchromesh shift (the Hayate's road box): lever clack through the gate, a
    short synchro 'shk' as the cones match speeds, then a soft drivetrain take-up knock.
    Softer and less metallic than the dog box; a downshift has a longer synchro rub."""
    r = al.rng(seed)
    dur = 0.4
    n = int(dur * SR)
    t = np.arange(n) / SR
    y = np.zeros(n)
    base = r.uniform(0.92, 1.08) * (0.9 if down else 1.0)
    # gate / knob clack: plastic-damped metal, short
    clack = al.modal(np.array([2350, 3650, 5200]) * base, [0.006, 0.004, 0.003], [1.0, 0.6, 0.3], dur, r)
    clack *= np.minimum(1.0, t / 0.0006)
    # synchro cone rub: band noise with a quick downward sweep of its centre
    rub_len = int((0.055 if down else 0.035) * SR)
    rub_off = int((0.018 + r.uniform(0, 0.006)) * SR)
    rn = al.white(rub_len, r)
    u = np.arange(rub_len) / SR
    rub = al.filt(np.vstack([al.sos_bp(1300.0, 5200.0, 2), al.peak_eq(2600.0 * base, 3.0, 6.0)]), rn)
    rub *= np.sin(math.pi * np.clip(u / (rub_len / SR), 0, 1)) ** 1.5
    # engagement: short soft steel tick + low take-up knock
    eng_off = rub_off + rub_len
    tick = al.modal(np.array([1480, 2320]) * base, [0.012, 0.008], [0.6, 0.35], dur, r)
    tick *= np.minimum(1.0, t / 0.0008)
    knock = al.modal([92 * base, 150 * base], [0.05, 0.03], [1.0, 0.4], dur, r)
    knock *= np.minimum(1.0, t / 0.003)
    y += 0.45 * clack
    y[rub_off:rub_off + rub_len] += 0.3 * rub / (np.max(np.abs(rub)) + 1e-12)
    y[eng_off:] += (0.45 * tick + 0.8 * knock)[: n - eng_off]
    return al.trim_tail(al.fade_edges(y, 0.0005, 0.04), -60.0)


# ======================================================================== main

def build_loops(p: Profile, first_seed: int, idle_seed: int) -> dict:
    """Synthesize, level and write one set's engine loops; returns its manifest."""
    p.out.mkdir(parents=True, exist_ok=True)
    manifest: dict = {"sample_rate": SR, "on": {}, "off": {}, "idle": {}}
    loops: list[tuple[str, np.ndarray, float, str]] = []
    seed = first_seed
    for load in ("on", "off"):
        # Below ~1750 rpm with the throttle closed the engine is idling, not on overrun:
        # the runtime blends the idle loop there instead of an off-load loop.
        for rpm in RPM_POINTS if load == "on" else RPM_POINTS[1:]:
            seed += 1
            x, exact = engine_loop(p, rpm, load, seed)
            loops.append((f"engine_{load}_{rpm}", x, exact, load))
    x, exact = engine_loop(p, p.idle_rpm, "idle", idle_seed)
    loops.append(("engine_idle", x, exact, "idle"))

    # Set each loop's loudness from the target curve, then one common gain for the set so
    # relative levels survive and the loudest peak sits at -1 dBFS.
    scaled = []
    # Anti-alias low-pass before level setting: the runtime pitches loops by up to ~1.4x,
    # which would fold content above ~15 kHz back down, and the strongest firing-pulse
    # fronts otherwise read as isolated broadband ticks that repeat once per loop.
    aa = al.sos_lp(12000.0, 4)
    for name, x, exact, load in loops:
        x = al.filt_circular(aa, x)
        g = al.undb(target_rms_db(p, exact, load) - al.rms_db(x))
        scaled.append((name, x * g, exact, load))
    # Common gain from the steady (on/idle) loops; overrun crackle transients above the
    # ceiling are caught by a static soft limiter (sample-wise, so seams stay intact).
    common = al.undb(-1.0) / max(float(np.max(np.abs(s[1]))) for s in scaled if s[3] != "off")
    for name, x, exact, load in scaled:
        # The limiter's knee bends crackle peaks sample-wise; re-band-limit the result (a
        # circular filter, so the seam stays exact) and trim any filter overshoot.
        y = al.filt_circular(aa, al.soft_limit(x * common, -1.0, knee_db=1.5))
        y = al.rotate_to_quiet_zero_crossing(y)
        y *= min(1.0, al.undb(-1.0) / float(np.max(np.abs(y))))
        al.write_wav(p.out / f"{name}.wav", y)
        entry = {"file": f"{name}.wav", "rpm": round(exact, 3), "samples": int(y.size)}
        if load == "idle":
            manifest["idle"] = entry
        else:
            manifest[load][str(int(name.split("_")[-1]))] = entry
        print(f"{p.key} {name:20s} rpm={exact:8.2f} peak={al.peak_db(y):6.2f} rms={al.rms_db(y):6.2f}"
              f" lufs={al.lufs(y):6.2f} seam_kink={al.seam_metrics(y)['seam_kink_over_p99']:.3f}")
    return manifest


def build_turbo4() -> None:
    out = TURBO4.out
    manifest = build_loops(TURBO4, 100, 99)
    al.write_wav(out / "turbo_whistle.wav", al.normalize_peak(turbo_whistle(), -3.0))
    al.write_wav(out / "gear_whine.wav", al.normalize_peak(gear_whine(), -3.0))
    al.write_wav(out / "bov_1.wav", al.normalize_peak(bov(11, 0.55, 6500.0, 2300.0), -1.0))
    al.write_wav(out / "bov_2.wav", al.normalize_peak(bov(12, 0.38, 7500.0, 2800.0), -1.0))
    al.write_wav(out / "bov_flutter.wav", al.normalize_peak(bov_flutter(13), -1.0))
    for i in range(4):
        al.write_wav(out / f"backfire_{i + 1}.wav", al.normalize_peak(backfire(200 + i * 7), -1.0))
    for i in range(2):
        al.write_wav(out / f"shift_up_{i + 1}.wav", al.normalize_peak(shift_clunk(300 + i, False), -1.0))
        al.write_wav(out / f"shift_down_{i + 1}.wav", al.normalize_peak(shift_clunk(310 + i, True), -1.0))
    manifest["turbo_whistle"] = {"file": "turbo_whistle.wav", "base_hz": 3000.0}
    manifest["gear_whine"] = {"file": "gear_whine.wav", "base_hz": 900.0, "base_kmh": 82.0}
    al.save_manifest(out / "engine_loops.json", manifest)


def build_na4() -> None:
    out = NA4.out
    manifest = build_loops(NA4, 500, 499)
    for i in range(4):
        al.write_wav(out / f"backfire_{i + 1}.wav", al.normalize_peak(backfire_na(600 + i * 7), -1.0))
    for i in range(2):
        al.write_wav(out / f"shift_up_{i + 1}.wav", al.normalize_peak(shift_synchro(700 + i, False), -1.0))
        al.write_wav(out / f"shift_down_{i + 1}.wav", al.normalize_peak(shift_synchro(710 + i, True), -1.0))
    al.save_manifest(out / "engine_loops.json", manifest)


def main(names: list[str]) -> None:
    builders = {"turbo4": build_turbo4, "na4": build_na4}
    for name in names or list(builders):
        builders[name]()


if __name__ == "__main__":
    main(sys.argv[1:])
