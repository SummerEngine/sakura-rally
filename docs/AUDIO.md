# Sakura Rally — audio

Everything the player hears, how each file was made, and how the runtime mixes it.
Owner paths: `scripts/autoload/sound.gd`, `scripts/vehicle/car_audio.gd`, `assets/audio/**`,
`tools/audio/**`, `scenes/test/audio_*.tscn`.

## Sonic identity

- **Car**: a characterful 2.0 turbo inline-4 rally engine that is always audible and always
  tells you the gear: clear firing-frequency harmonics, a gruff half-order from per-cylinder
  variation, turbo whistle and blow-off, straight-cut gearbox whine, dog-box clunks, pops on
  the overrun. Engine sits on top of the mix.
- **World**: surface-true tyres (gravel crunch vs tarmac hum vs grass swish), stones pinging
  the underbody, suspension thumps, wind that grows with speed.
- **Music / ambience / UI**: warm city-pop / lo-fi with Japanese colour (koto, shakuhachi,
  taiko), soft wooden "kon" UI, seasonal ambience beds, short Japanese-flavoured stingers.
  Music always sits behind the car.

## Bus layout (created at runtime by `Sound`)

```
Master  [Compressor -10 dB 2:1 20 ms/250 ms] [HardLimiter ceiling -1 dB]
├── Music     [LowPass: opens 20.5 kHz; 900 Hz while paused; 5 kHz in slow motion]
├── Ambience
├── UI        (UI one-shots + stingers)
└── SFX       [Reverb: 45 ms predelay, wet 0.07 — open-air slap] [LowPass: slow motion]
    ├── Engine  [Compressor -14 dB 2.5:1] — every engine/turbo/gearbox/shift/pop layer
    └── World   — tyres, stones, thumps, impacts, wind, horn, Sound.play_3d
```

Volumes: `Game.get_setting("master_volume"|"music_volume"|"sfx_volume")` (linear 0..1) map
to dB with `linear_to_db` (0 → muted) and are re-applied on `Game.settings_changed`.
`sfx_volume` drives SFX, UI and Ambience. Fixed trims under the settings
(`BUS_TRIM_DB` in `sound.gd`): Music −5, Ambience −2, UI −6, SFX 0, Engine +2, World 0 dB.
Stingers `go`/`finish`/`record` duck Music by 5/8/10 dB (Ambience by half) for their
length, then release over 1.2 s. Effects are never toggled at runtime (toggling clicks);
the low-passes are swept instead.

## `Sound` API (see docs/CONTRACTS.md)

| Call | Behaviour |
|---|---|
| `play_ui(name)` | `hover` (−4 dB, ±3 % pitch), `click`, `back`, `start`, `toggle`; 4-voice pool on UI bus |
| `play_music(track, fade)` | `menu`, `drive`, `results`; equal-power crossfade between two players; same track again = no restart |
| `stop_music(fade)` | equal-power fade out |
| `play_ambience(map_id, fade)` | `hanami`, `momiji`; crossfade, starts at a random point in the loop; unknown id fades the bed out |
| `stop_ambience(fade)` | fade out |
| `play_stinger(name)` | `countdown`, `go`, `checkpoint`, `finish`, `record`; UI bus, ducks music for the big ones |
| `play_3d(name, pos, db)` | names: `impact_light`, `impact_heavy`, `thump`, `stone`, `backfire`, `blowoff`, `shift` (random variant, ±6 % pitch) or any `res://` path; 16-voice AudioStreamPlayer3D pool on World |
| `set_slowmo(scale)` | tweens `Sound.slowmo` (0.1..1) over 0.25 s; car audio + play_3d multiply pitch by it; SFX low-pass sweeps to 2.2 kHz and music to 5 kHz at 0.3× |

Unknown names and missing files never error: they `push_warning` once and return.

## Car audio runtime (`scripts/vehicle/car_audio.gd`)

A `CarAudio` Node3D child of any node implementing the car API. It reads `rpm`, `throttle`,
`input_throttle`, `boost`, `speed_kmh`, `is_shifting`, `airborne_time`, `max_rpm`,
`controlled_by_player`, `wheels[i].{contact, surface, slip, spin_speed}` every frame (missing
properties fall back to safe defaults) and connects `gear_changed`, `backfire`,
`rev_limiter`, `impact`, `landed` when the parent has them.

**Why AudioStreamPlayer3D for everything**: the chase camera is the listener, so 3D players
give correct distance, positional impacts/stones and work for replays or other cars. For the
player's own car `panning_strength` is 0.35 and the distance low-pass is off, so the engine
stays centred and full-range (a 2D-like experience) while impacts at a corner and stones in
a wheel arch still localise. Non-player cars get full panning and air absorption.

Engine:
- 8 `on` loops (1000–7500 rpm) and 8 `off` loops (idle 900, then 1750–7500) all run
  continuously. For each set the two loops bracketing the smoothed rpm get equal-power gains
  `cos(x·π/2)`, `sin(x·π/2)`; each loop's `pitch_scale = rpm / loop_rpm` (exact loop rpm from
  `assets/audio/engine/engine_loops.json`, max ±22 % shift between neighbours).
- Load `L` (0..1) = applied throttle, smoothed (45 ms attack, 85 ms release), forced to 0
  while `is_shifting` and for a 110 ms (up) / 70 ms (down) dip after `gear_changed`. On/off
  sets blend equal-power: `on·sin(L·π/2)`, `off·cos(L·π/2)`.
- Rev limiter: on `rev_limiter` the load is chopped at 17 Hz for 120 ms (re-armed by every
  signal) — the classic stutter — with an occasional small pop.
- Turbo whistle: gain `boost^1.5 · lerp(0.35, 1, load)`, pitch `(0.42 + 0.72·boost)·(0.85 +
  0.25·rpm/max_rpm)`.
- Blow-off: when the driver's pedal (`input_throttle`) drops from > 0.6 to < 0.25 with boost
  > 0.45 (not during shifts/limiter), and on upshifts with boost > 0.3; 25 % of the time the
  compressor-surge flutter instead of the "pssh".
- Gearbox whine: pitch follows driveshaft speed `|speed_kmh| / 82` (the loop's 900 Hz mesh
  tone is 82 km/h), gain fades in 6→45 km/h and is louder off-throttle (as real straight-cut
  boxes are).
- Shift clunk (up/down variants) on every `gear_changed`; downshifts above 3000 rpm pop
  35 % of the time. `backfire` plays a random pop variant.

World:
- Per wheel with contact: rolling gain by surface ∝ `(speed/70)^0.85`, summed over wheels
  (then √ for power), pitch 0.75→1.25 with speed. Slide gain per surface
  `smoothstep(0.55, 1.3, slip)` × motion (speed or wheel spin), 35 ms attack / 120 ms
  release; the tarmac squeal pitch rises with slip beyond 1. Surface map: tarmac, gravel,
  dirt, grass → own loops; sand → dirt loops; grass slides → dirt scrub at 55 %.
- Stones: Poisson rate from gravel/dirt contact, speed and slip → random stone variant on
  that wheel's arch, −10..0 dB, 0.85–1.2 pitch.
- `landed(strength)` → suspension thump (+ light knock above 0.7).
  `impact(strength, point)` → light (< 0.4) or heavy variants at the contact point, gain
  scaled by strength.
- Wind: `smoothstep(15, 170, speed)^1.3`, +15 % while airborne, pitch rises with speed.
- Horn: player car only, while the `horn` action is held (12 ms attack, 40 ms release) —
  a cheerful dual-tone major third (415 + 523 Hz).
- Everything multiplies pitch by `Sound.slowmo`.

## Assets

All loops are seamless; WAVs import as uncompressed PCM with forward loop over the whole
file (`tools/audio/set_loop_imports.py` writes the `.import` params; one-shots have loop
disabled). All SFX peaks ≤ −1 dBFS.

### Engine — `assets/audio/engine/` (synthesised: `tools/audio/synth_engine.py`)

| File | What |
|---|---|
| `engine_on_{1000,1750,2500,3500,4500,5500,6500,7500}.wav` | throttle-on loops, ~2.2 s each |
| `engine_off_{1750,…,7500}.wav` | overrun loops (thinner, lean misfires, burble crackle) |
| `engine_idle.wav` | lumpy idle at 900 rpm (also the lowest `off` loop) |
| `turbo_whistle.wav` | 3 kHz compressor whistle + air rush loop |
| `gear_whine.wav` | straight-cut mesh whine loop (900 Hz, shaft-order sidebands) |
| `bov_1.wav`, `bov_2.wav`, `bov_flutter.wav` | blow-off "pssh" ×2, compressor-surge flutter |
| `backfire_1..4.wav` | anti-lag / overrun pops |
| `shift_up_1..2.wav`, `shift_down_1..2.wav` | dog-box clunks (downshift = double engagement) |
| `engine_loops.json` | exact loop rpm per file (runtime pitch reference) |

Engine synthesis model (per loop, all circular so the loop is exactly periodic):
1. Loop length = an integer number of 720° cycles (~2.2 s); exact rpm recorded.
2. Firing events at `rpm/60·2` Hz, firing order 1-3-4-2, per-cylinder amplitude
   (1.00/0.89/1.09/0.95) and timing offsets (≤ 2 % of the interval) → half-order
   sub-harmonics; per-event combustion jitter (5 % on, 22 % + 18 % weak events off).
3. Each event is a steep-fronted blowdown pulse `(1 − e^{−t/0.16ms}) e^{−t/τ}` (τ shrinks
   with rpm) minus a 3.4 ms header reflection, placed with sub-sample accuracy in the
   frequency domain.
4. Exhaust: two feedback combs (tailpipe 9.8 ms, mid-pipe 4.3 ms, damped) + body EQ
   (95/230/520 Hz resonances, 1.35 kHz dip) + muffler low-pass (3.6 kHz on / 2.7 kHz off).
5. Layers: pulse-gated combustion rasp, intake-stroke-gated induction roar (1.15 kHz airbox
   resonance), valvetrain ticks (16 valves/cycle), timing-belt order tone (21×/42× crank),
   block rumble; overrun adds sparse crackle bursts.
6. Periodic slow wobble (integer cycles per loop), tanh saturation (more on load), DC
   removal, rotate so the file starts at the quietest upward zero crossing.
7. Level: each loop set to a target RMS curve (on: −22 → −14 dB rel. with rpm, off ≈ 7 dB
   quieter), then one common gain for the set (loudest steady loop at −1 dBFS) and a
   sample-wise soft limiter at −1 dBFS for overrun crackle peaks.

### Car world — `assets/audio/car/` (synthesised: `tools/audio/synth_world.py`)

| File | What |
|---|---|
| `tyre_roll_{tarmac,gravel,dirt,grass}.wav` | 3 s rolling loops: tarmac hum + tread whirr; gravel = dense granular crunch (Pareto-amplitude grains in 5 bands) + rumble; dirt = softer crunch + mud; grass = modulated swish + blades |
| `tyre_slide_{tarmac,gravel,dirt}.wav` | 3 s slide loops: tarmac squeal (3 jittering stick-slip partials 780/1030/1340 Hz + scrub); gravel spray (very dense grains + hiss + stones); dirt scrub + clods |
| `wind.wav` | 6 s pink-noise wind with periodic gusts and a faint edge whistle |
| `horn.wav` | 1 s dual-tone horn loop (415 + 523 Hz, buzzy diaphragm, bell formants) |
| `stone_1..6.wav` | pebble pings (modal 1.8–5.6 kHz + tick + panel thud) |
| `thump_1..3.wav` | landing thumps (pitch-dropping 52–72 Hz + strut modes + rattle) |
| `impact_light_1..3.wav` | body knocks (modal panel + plastic crack + low body) |
| `impact_heavy_1..3.wav` | crashes (pitch-dropping boom + crunch grains + metal modes + debris) |

## Verification

Tools (all under `tools/audio/`, Python venv `tools/audio/.venv`, create with
`uv venv tools/audio/.venv && uv pip install --python tools/audio/.venv/bin/python numpy scipy matplotlib pyloudnorm soundfile requests`):

- `analyze.py [paths]` — per-file duration, peak dBFS, integrated LUFS, DC; loop seam metrics;
  spectrogram PNG + seam-view PNG in `tools/audio/renders/` (scratch, git-ignored).
- `render_test.py [wav]` — spectrograms (full + 0–2.5 kHz engine zoom with event marks),
  peak/LUFS/clipped-sample count and a click detector (> 15 kHz residual vs local RMS).
- `test/sound_api_smoke.gd` — headless call of every `Sound` entry point with every
  documented name plus unknown names.
- `scenes/test/audio_test.tscn` (+ `test/audio_test_driver.gd`, `test/fake_car.gd`) —
  a scripted rally run of a toy-drivetrain car implementing the car API, recorded from the
  Master bus with `AudioEffectRecord` to `tools/audio/renders/audio_test*.wav`.

Rebuild everything:

```
tools/audio/.venv/bin/python tools/audio/synth_engine.py
tools/audio/.venv/bin/python tools/audio/synth_world.py
timeout 180 $S --headless --disable-crash-handler --path . --import
tools/audio/.venv/bin/python tools/audio/set_loop_imports.py
timeout 180 $S --headless --disable-crash-handler --path . --import
tools/audio/.venv/bin/python tools/audio/analyze.py
timeout 200 $S --headless --disable-crash-handler --path . res://scenes/test/audio_test.tscn            # full run
timeout 200 $S --headless --disable-crash-handler --path . res://scenes/test/audio_test.tscn -- --clean # tarmac, no transients
timeout 200 $S --headless --disable-crash-handler --path . res://scenes/test/audio_test.tscn -- --mix   # + music & ambience
tools/audio/.venv/bin/python tools/audio/render_test.py tools/audio/renders/audio_test.wav
```
