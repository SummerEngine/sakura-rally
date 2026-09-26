"""Offline synthesis of the Sakura Rally engine set: a 2.0 turbo inline-4 rally engine.

Outputs (44.1 kHz mono 16-bit WAV) into assets/audio/engine/:
  engine_on_<rpm>.wav / engine_off_<rpm>.wav   seamless loops at RPM points (off from 1750)
  engine_idle.wav                              seamless idle loop
  turbo_whistle.wav                            seamless spool/whistle loop (pitch follows boost)
  gear_whine.wav                               seamless straight-cut gearbox whine loop
  bov_1.wav, bov_2.wav, bov_flutter.wav        blow-off valve one-shots
  backfire_1..4.wav                            anti-lag / overrun pops
  shift_up_1..2.wav, shift_down_1..2.wav       dog-box gear-shift clunks
and assets/audio/engine/engine_loops.json (exact loop rpm for runtime pitch = rpm / loop_rpm).

Every loop is synthesised circularly (exact integer number of engine cycles, all filters
run to steady state over repeated copies), so the wrap from the last sample to the first
is as continuous as any other pair of neighbouring samples.

Run: tools/audio/.venv/bin/python tools/audio/synth_engine.py
"""

from __future__ import annotations

import math

import numpy as np

import audiolib as al

OUT = al.ASSETS / "engine"
SR = al.SR

RPM_POINTS = [1000, 1750, 2500, 3500, 4500, 5500, 6500, 7500]
IDLE_RPM = 900
LOOP_SECONDS = 2.2

# Firing order 1-3-4-2: which cylinder fires in each quarter of the 720 deg cycle.
FIRING_ORDER = [0, 2, 3, 1]
# Per-cylinder character: slight differences in charge, runner length and spark give the
# half-order (cycle-rate) sub-harmonics that make a real four sound gruff, not a buzzer.
CYL_AMP = np.array([1.00, 0.89, 1.09, 0.95])
CYL_TIMING = np.array([0.0, 0.021, -0.017, 0.011])  # fraction of the firing interval


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


def engine_loop(rpm_nominal: float, load: str, seed: int) -> tuple[np.ndarray, float]:
    r = al.rng(seed)
    cycles, n, rpm = loop_geometry(rpm_nominal)
    tc = 120.0 / rpm
    fire_dt = tc / 4.0
    x01 = min(max((rpm - 900.0) / 6600.0, 0.0), 1.0)  # 0 at idle, 1 near redline
    on = load in ("on", "idle")
    idle = load == "idle"

    # ---------------------------------------------------------------- firing events
    events = cycles * 4
    k = np.arange(events)
    cyl = np.array(FIRING_ORDER)[k % 4]
    jitter_amp = 0.05 if load == "on" else (0.12 if idle else 0.22)
    times = (k + CYL_TIMING[cyl] + r.normal(0, 0.004, events)) * fire_dt
    amps = CYL_AMP[cyl] * r.normal(1.0, jitter_amp, events)
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
    spec = blowdown_pulse_spectrum(f, 0.00016, 0.0004 + 0.11 * fire_dt)
    refl = 0.0034
    spec = spec * (1.0 - 0.55 * np.exp(-2j * math.pi * f * refl))
    pulses = place_events(n, times, amps, spec)
    pulses /= np.std(pulses) + 1e-12

    # ---------------------------------------------------------------- exhaust system
    ex = al.comb_circular(pulses, delay_s=0.0098, fb=0.42, damp_hz=1600.0)  # tailpipe
    ex = al.comb_circular(ex, delay_s=0.0043, fb=0.25, damp_hz=2600.0)       # mid-pipe
    body = np.vstack([
        al.sos_hp(28.0, 2),
        al.peak_eq(95.0, 1.1, 4.5 if on else 1.5),
        al.peak_eq(230.0, 1.4, 3.0 if on else 0.5),
        al.peak_eq(520.0, 1.8, 2.0),
        al.peak_eq(1350.0, 1.2, -3.5),
        al.peak_eq(2600.0, 2.0, 1.0 if not on else 0.5),
        al.sos_lp(3600.0 if on else 2700.0, 2),
    ])
    ex = al.filt_circular(body, ex)
    ex /= np.std(ex) + 1e-12

    # Exhaust rasp: broadband combustion noise gated by the pulse envelope.
    env = smooth_env_circular(pulses, 900.0)
    env /= np.max(env) + 1e-12
    rasp_noise = al.white(n, r) * env ** 2.2
    rasp = al.filt_circular(np.vstack([al.sos_bp(420.0, 4200.0, 2), al.peak_eq(1900.0, 1.5, 4.0)]), rasp_noise)
    rasp /= np.std(rasp) + 1e-12

    # Induction: intake strokes interleave the firing events (offset half an interval).
    intake_env = np.zeros(n)
    it = np.mod((k + 0.5 + r.normal(0, 0.01, events)) * fire_dt, n / SR)
    idx = (it * SR).astype(int) % n
    intake_env[idx] = 1.0
    intake_env = al.filt_circular(al.sos_lp(min(60.0 + rpm / 60.0 * 2.0, 400.0), 2), intake_env)
    intake_env = np.maximum(intake_env / (np.max(intake_env) + 1e-12), 0.0)
    intake = al.white(n, r) * (0.35 + intake_env)
    intake = al.filt_circular(np.vstack([al.sos_bp(700.0, 3200.0, 2), al.peak_eq(1150.0, 3.0, 6.0)]), intake)
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
        mix = (1.0 * ex + (0.15 + 0.18 * x01) * rasp + (0.07 + 0.15 * x01) * intake
               + 0.035 * ticks + 0.012 * belt + 0.35 * rumble)
        drive = 1.1 + 0.8 * x01
    elif idle:
        mix = 1.0 * ex + 0.16 * rasp + 0.06 * intake + 0.05 * ticks + 0.012 * belt + 0.45 * rumble
        drive = 1.0
    else:
        mix = (0.8 * ex + (0.11 + 0.10 * x01) * rasp + 0.03 * intake + 0.07 * ticks
               + 0.018 * belt + 0.18 * rumble + 0.22 * crackle)
        drive = 0.7
        mix = al.filt_circular(al.sos_hp(70.0 + 40.0 * x01, 2), mix)
    mix *= periodic_lfo(n, r, 0.05 if not idle else 0.09)
    mix /= np.percentile(np.abs(mix), 99.9) + 1e-12
    mix = np.tanh(drive * mix) / math.tanh(drive)
    mix -= np.mean(mix)
    return al.rotate_to_quiet_zero_crossing(mix), rpm


def target_rms_db(rpm: float, load: str) -> float:
    x = min(max((rpm - 1000.0) / 6500.0, 0.0), 1.0)
    on_db = -22.0 + 8.0 * x ** 0.8
    if load == "on":
        return on_db
    if load == "idle":
        return -23.5
    return on_db - 7.5 + 1.5 * x


# ======================================================================== accessory loops

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


# ======================================================================== main

def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    manifest: dict = {"sample_rate": SR, "on": {}, "off": {}, "idle": {}}
    loops: list[tuple[str, np.ndarray, float, str]] = []
    seed = 100
    for load in ("on", "off"):
        # Below ~1750 rpm with the throttle closed the engine is idling, not on overrun:
        # the runtime blends the idle loop there instead of an off-load loop.
        for rpm in RPM_POINTS if load == "on" else RPM_POINTS[1:]:
            seed += 1
            x, exact = engine_loop(rpm, load, seed)
            loops.append((f"engine_{load}_{rpm}", x, exact, load))
    x, exact = engine_loop(IDLE_RPM, "idle", 99)
    loops.append(("engine_idle", x, exact, "idle"))

    # Set each loop's loudness from the target curve, then one common gain for the set so
    # relative levels survive and the loudest peak sits at -1 dBFS.
    scaled = []
    for name, x, exact, load in loops:
        g = al.undb(target_rms_db(exact, load) - al.rms_db(x))
        scaled.append((name, x * g, exact, load))
    # Common gain from the steady (on/idle) loops; overrun crackle transients above the
    # ceiling are caught by a static soft limiter (sample-wise, so seams stay intact).
    common = al.undb(-1.0) / max(float(np.max(np.abs(s[1]))) for s in scaled if s[3] != "off")
    for name, x, exact, load in scaled:
        y = al.soft_limit(x * common, -1.0, knee_db=1.5)
        al.write_wav(OUT / f"{name}.wav", y)
        entry = {"file": f"{name}.wav", "rpm": round(exact, 3), "samples": int(y.size)}
        if load == "idle":
            manifest["idle"] = entry
        else:
            manifest[load][str(int(name.split("_")[-1]))] = entry
        print(f"{name:20s} rpm={exact:8.2f} peak={al.peak_db(y):6.2f} rms={al.rms_db(y):6.2f}"
              f" lufs={al.lufs(y):6.2f} seam_kink={al.seam_metrics(y)['seam_kink_over_p99']:.3f}")

    al.write_wav(OUT / "turbo_whistle.wav", al.normalize_peak(turbo_whistle(), -3.0))
    al.write_wav(OUT / "gear_whine.wav", al.normalize_peak(gear_whine(), -3.0))
    al.write_wav(OUT / "bov_1.wav", al.normalize_peak(bov(11, 0.55, 6500.0, 2300.0), -1.0))
    al.write_wav(OUT / "bov_2.wav", al.normalize_peak(bov(12, 0.38, 7500.0, 2800.0), -1.0))
    al.write_wav(OUT / "bov_flutter.wav", al.normalize_peak(bov_flutter(13), -1.0))
    for i in range(4):
        al.write_wav(OUT / f"backfire_{i + 1}.wav", al.normalize_peak(backfire(200 + i * 7), -1.0))
    for i in range(2):
        al.write_wav(OUT / f"shift_up_{i + 1}.wav", al.normalize_peak(shift_clunk(300 + i, False), -1.0))
        al.write_wav(OUT / f"shift_down_{i + 1}.wav", al.normalize_peak(shift_clunk(310 + i, True), -1.0))
    manifest["turbo_whistle"] = {"file": "turbo_whistle.wav", "base_hz": 3000.0}
    manifest["gear_whine"] = {"file": "gear_whine.wav", "base_hz": 900.0, "base_kmh": 82.0}
    al.save_manifest(OUT / "engine_loops.json", manifest)


if __name__ == "__main__":
    main()
