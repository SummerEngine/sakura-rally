# Sakura Rally — audio

Everything the player hears, how each file was made, and how the runtime mixes it.
Owner paths: `scripts/autoload/sound.gd`, `scripts/vehicle/car_audio.gd`, `assets/audio/**`,
`tools/audio/**`, `scenes/test/audio_*.tscn`.

## Sonic identity

- **Car**: a characterful 2.0 turbo inline-4 rally engine that is always audible and always
  tells you the gear: clear firing-frequency harmonics, a gruff half-order from per-cylinder
  variation, turbo whistle and blow-off, straight-cut gearbox whine, dog-box clunks, pops on
  the overrun. Engine sits on top of the mix. The Hayate has its own set: a 1.6 NA twin-cam
  that revs to 8000, higher-pitched and raspier, with a harmonic intake howl, crisp pops on
  lift-off, a synchro road gearbox and no turbo at all.
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
Stingers `go`/`finish`/`record`/`campaign_complete` duck Music by 5/8/10/10 dB (Ambience by half) for their
length, then release over 1.2 s. Effects are never toggled at runtime (toggling clicks);
the low-passes are swept instead.

## `Sound` API (see docs/CONTRACTS.md)

| Call | Behaviour |
|---|---|
| `play_ui(name)` | `hover` (−4 dB, ±3 % pitch), `click`, `back`, `start`, `toggle`; 4-voice pool on UI bus |
| `play_music(track, fade)` | `menu`, `drive`, `results`, `liaison`; equal-power crossfade between two players; same track again = no restart |
| `stop_music(fade)` | equal-power fade out |
| `play_ambience(fade)` | the world bed: the `hanami` (spring), `natsu` (summer) and `momiji` (autumn) loops mixed by the season at the camera; equal-power fade in, each loop starts at a random point; playing already: no change |
| `set_ambience_mix(weights)` | season weights (spring, summer, autumn) at the listener, each loop at the square root of its weight; `MapWorld` calls it as the camera moves, loops at zero weight stop |
| `stop_ambience(fade)` | fade out |
| `play_stinger(name)` | `countdown`, `go`, `checkpoint`, `finish`, `record`, `arrived`, `campaign_complete`; UI bus, ducks music for the big ones |
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

Engine set: read once in `_ready` from the car's `engine_sound` (`&"turbo4"` when the
property is missing; an unknown id warns and falls back to it):

| `engine_sound` | Folder | Idle loop | Turbo layers | Gear whine trim |
|---|---|---|---|---|
| `&"turbo4"` (Sakura) | `assets/audio/engine/` | 900 rpm | whistle + blow-off | −21 dB (dog box) |
| `&"na4"` (Hayate) | `assets/audio/engine/na4/` | 1000 rpm | none (players not created) | −28 dB (road box) |

Both sets share the loop rpm points, the gearbox whine loop and the mixing below; the Hayate's
8000 rpm redline plays the 7500 loops at pitch ≤ 1.12.

Engine:
- 8 `on` loops (1000–7500 rpm) and 8 `off` loops (idle, then 1750–7500) all run
  continuously. For each set the two loops bracketing the smoothed rpm get equal-power gains
  `cos(x·π/2)`, `sin(x·π/2)`; each loop's `pitch_scale = rpm / loop_rpm` (exact loop rpm from
  the set's `engine_loops.json`, max ±22 % shift between neighbours).
- Load `L` (0..1) = applied throttle, smoothed (45 ms attack, 85 ms release), forced to 0
  while `is_shifting` and for a 110 ms (up) / 70 ms (down) dip after `gear_changed`. On/off
  sets blend equal-power: `on·sin(L·π/2)`, `off·cos(L·π/2)`.
- Rev limiter: on `rev_limiter` the load is chopped at 17 Hz for 120 ms (re-armed by every
  signal; the car emits one per ~55 ms fuel cut every 80–120 ms) — the classic stutter.
  Pops on limiter cuts, shifts and lift-off come from the car's own `backfire` signal.
- Turbo whistle (turbo4 only): gain `boost^1.5 · lerp(0.35, 1, load)`, pitch `(0.42 + 0.72·boost)·(0.85 +
  0.25·rpm/max_rpm)`.
- Blow-off (turbo4 only): when the driver's pedal (`input_throttle`) drops from > 0.6 to < 0.25 with boost
  > 0.45 (not during shifts/limiter), and on upshifts with boost > 0.3; 25 % of the time the
  compressor-surge flutter instead of the "pssh".
- Gearbox whine: pitch follows driveshaft speed `|speed_kmh| / 82` (the loop's 900 Hz mesh
  tone is 82 km/h), gain fades in 6→45 km/h and is louder off-throttle (as real straight-cut
  boxes are).
- Shift clunk (up/down variants) on every `gear_changed`. `backfire` plays a random pop
  variant (−4..0 dB, ±8 % pitch).

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

Engine synthesis model (per loop, all circular so the loop is exactly periodic; numbers are
the turbo4 `Profile`, the na4 differences follow in the next section):
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
   removal.
7. Circular 12 kHz 4th-order low-pass: the runtime pitches loops by up to ~1.4×, which
   would otherwise fold top-end content back down, and it keeps the steepest firing fronts
   from reading as isolated ticks that repeat once per loop.
8. Level: each loop set to a target RMS curve (on: −22 → −14 dB rel. with rpm, off ≈ 7 dB
   quieter), then one common gain for the set (loudest steady loop at −1 dBFS) and a
   sample-wise soft limiter at −1 dBFS for overrun crackle peaks, re-band-limited with the
   same circular low-pass, then rotated so the file starts at the quietest upward zero
   crossing.

### Hayate engine — `assets/audio/engine/na4/` (`synth_engine.py na4`)

Same file layout as turbo4 minus `turbo_whistle`, `gear_whine` and `bov_*`: `engine_on_*`,
`engine_off_*`, `engine_idle` (1000 rpm), `backfire_1..4`, `shift_up_1..2`, `shift_down_1..2`,
`engine_loops.json`. The same physical model runs with the `NA4` profile:

- Crisper, better balanced firing: cylinder spread 0.95–1.05 and ≤ 1.2 % timing offsets (turbo4
  0.89–1.09, ≤ 2.1 %), so less half-order gruffness.
- Sharper, shorter blowdown pulses (rise 0.11 ms, decay a third shorter) into a 4-2-1 header
  with no turbine to smooth them; shorter pipes (tailpipe 7.2 ms, mid-pipe 3.1 ms), body
  resonances moved up (135/320/760/1850/3300 Hz, no 1.35 kHz dip), small free-flowing muffler
  (low-pass 5.6 kHz on / 4.0 kHz off), rasp band 0.7–6.5 kHz peaking at 2.7 kHz.
- Induction howl (NA only): each intake stroke sends a pressure pulse into the airbox; the
  pulse train, roughened per stroke, is filtered through airbox/runner resonances at 1.65,
  2.45 and 3.9 kHz, so the firing-order partials light up there and the howl grows with rpm
  and load (`0.12 + 0.62·x^1.3` on throttle, 0.06 idle, 0.10 on the overrun).
- Overrun: thinner (higher high-pass), plus air hissing past the closed throttle butterfly.
- Harder saturation on load, target RMS on −23 → −13.5 dB with rpm (a steeper rise than
  turbo4, so the top end screams), off ≈ 8 dB below on.
- `backfire_na`: a sharper, higher crack (HP 1.4 kHz, +4 dB at 3.2 kHz), a short 120–165 Hz
  boom and 1–4 trailing "pap-pap" sub-pops through the short tailpipe comb.
- `shift_synchro`: H-pattern road box — gate clack, a 35 ms (up) / 55 ms (down) synchro cone
  rub, a soft steel tick and a low take-up knock; softer and less metallic than the dog box.

Measured against turbo4 (loops at the same rpm, whole-loop spectra; share of total energy
per band, centroid, energy at half-orders vs firing-order harmonics 1–8):

| load rpm | LUFS t4 / na4 | centroid Hz t4 / na4 | < 200 Hz | 0.8–2.5 kHz | 2.5–6 kHz | > 6 kHz | half/firing dB |
|---|---|---|---|---|---|---|---|
| on 1750 | −16.1 / −17.4 | 229 / 481 | −1.2 / −2.8 | −16.6 / −10.5 | −20.4 / −14.6 | −29.4 / −21.6 | −17.4 / −21.9 |
| on 3500 | −13.5 / −14.3 | 273 / 676 | −1.5 / −3.2 | −14.6 / −8.2 | −18.4 / −12.4 | −28.1 / −20.0 | −21.3 / −25.5 |
| on 5500 | −10.8 / −10.7 | 370 / 1101 | −0.8 / −4.7 | −12.6 / −7.6 | −16.0 / −9.2 | −26.5 / −17.3 | −21.1 / −25.5 |
| on 7500 | −8.6 / −8.0 | 620 / 1060 | −10.1 / −18.7 | −10.2 / −6.7 | −14.4 / −10.2 | −24.7 / −17.8 | −21.8 / −27.1 |
| off 3500 | −19.7 / −21.4 | 532 / 875 | −2.6 / −5.4 | −12.0 / −7.7 | −13.4 / −11.1 | −20.5 / −17.1 | −19.4 / −19.5 |
| off 7500 | −15.0 / −15.6 | 757 / 1047 | −10.7 / −15.6 | −10.7 / −7.2 | −12.5 / −9.9 | −20.5 / −16.3 | −18.2 / −19.4 |

On throttle the Hayate carries 3.5–9 dB more energy in every band above 800 Hz and 1.7–3×
the spectral centroid (the rasp and the howl), less below 200 Hz, and 4–5 dB less half-order
content (smoother, "zingier" firing); on the overrun the gap is 2–5 dB and the half-orders
match. Seam kink ≤ 0.71 × p99 (turbo4 worst 0.82).

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

### Music — `assets/audio/music/` (fal `elevenlabs/music/v2.5`, post: `tools/audio/gen_music.py`)

Stereo OGG Vorbis, −16 LUFS integrated. Loop = `loop_offset` → end of file, baked into the
`.import` (`loop=true`, `loop_offset`), also listed in `music.json` with the detected BPM.

| File | Length | BPM | Loop start | Loop | LUFS / true peak |
|---|---|---|---|---|---|
| `menu.ogg` | 137.2 s | 84 | 45.766 s | 32 bars, 1 s crossfade | −15.99 / −4.0 dBTP |
| `drive.ogg` | 147.7 s | 104 | 18.513 s | 56 bars, 0.75 s crossfade | −16.02 / −2.9 dBTP |
| `results.ogg` | 62.7 s | 92 | 20.931 s | 16 bars, 1 s crossfade | −15.98 / −2.0 dBTP |
| `liaison.ogg` | 134.0 s | 86 | 33.541 s | 36 bars, 1 s crossfade | −16.00 / −2.2 dBTP |

Prompts (all `force_instrumental: true`, `output_format: mp3_44100_192`; exact params in
`tools/audio/audio_specs.py`, request ids in `tools/audio/fal_log.json`):

- **menu** (150 s): "Calm, dreamy instrumental lo-fi city-pop with Japanese instrumentation for
  a video game main menu. 84 BPM, 4/4, key of D major. Warm Rhodes electric piano chords,
  gentle koto melody and plucked koto arpeggios, soft breathy shakuhachi flute phrases, round
  mellow bass, light brushed drum kit with soft kick and rim clicks, subtle tape warmth. Spring
  cherry blossom mood, peaceful and polished, studio quality mix. Short gentle intro, then a
  steady consistent groove at the same tempo throughout, no big ending, no fade out.
  Instrumental only, no vocals."
- **drive** (160 s): "Steady, sparse instrumental city-pop groove with Japanese
  instrumentation for a relaxed driving game, played underneath loud car engine sound. 104
  BPM, 4/4, key of D major. Tight crisp drums with clean hi-hats and snappy rimshot, occasional
  taiko drum accents, clean funky electric guitar chops, bright koto hook melody, light shamisen
  fills, airy high synth pad. Keep the low-mids and bass light and clean: small tight bass, no
  thick pads, no muddy low end, lots of space in the arrangement. Upbeat but chill, polished
  modern mix. Consistent tempo and energy throughout, no fade out, no ending. Instrumental
  only, no vocals."
- **results** (70 s): "Warm, celebratory but calm instrumental city-pop loop with Japanese
  instrumentation for a race results screen. 92 BPM, 4/4, key of D major. Sparkling Rhodes
  chords, joyful koto arpeggios, soft shakuhachi melody, gentle taiko accents and a light drum
  groove, warm round bass. Content, proud, relaxed feeling, polished studio mix. Consistent
  tempo throughout, no fade out, no ending. Instrumental only, no vocals."
- **liaison** (150 s): "Chill, warm instrumental lo-fi Japanese city-pop with an acoustic feel
  for a relaxed, untimed summer-afternoon drive between rally stages in a video game, played
  underneath a car engine. 86 BPM, 4/4, key of D major. Fingerpicked nylon-string acoustic
  guitar, mellow Rhodes electric piano chords, a few soft koto accents, round warm bass,
  laid-back lo-fi drum groove with soft kick, brushed snare and a gentle shaker, subtle tape
  warmth, an airy flute melody now and then. Lazy, sunny, carefree, low energy, lots of space,
  light low-mids, polished mix. Short gentle intro, then a steady consistent groove at the same
  tempo throughout, no big ending, no fade out. Instrumental only, no vocals."

Model choice: for `menu` the same prompt was also rendered with
`fal-ai/stable-audio-3/medium/text-to-audio` (150 s, seed 8401, negative prompt "vocals,
singing, voice, choir, speech, distortion, harsh, noisy, low quality, fade out"; kept in
`audio_specs.COMPARISON`, not fetched by default). ElevenLabs won: 0 vs 3260 clipped samples,
3.4 vs 5.0 ms beat-grid residual, clear 8-bar sections. The SA3 output is used nowhere.

Loop baking (`gen_music.py`): librosa beat grid, linear-fitted and re-phased onto the kick
(≈ 3 ms residual); 8-bar section downbeats from cymbal onsets; loop points A/B chosen among
section downbeats by beat-synced chroma + MFCC similarity over ±8 beats (bonus for longer
loops), B always before any generated fade; EQ first (so filter state is continuous), then
the file is cut at B and `x[B−X:B]` equal-power crossfaded with `x[A−X:A]`. Onset envelopes
before A and B line up at lag 0 ± 5 ms (no flams). `drive` gets −3 dB @ 260 Hz and −1.5 dB
@ 120 Hz to leave the engine band free (its 80–400 Hz share is −5.1 dB vs −1.8 dB for menu).
Seam RMS step equals the natural step at A in the source (a downbeat getting louder).
Per-track settings live in `gen_music.TRACKS`. `liaison` gets −2 dB @ 260 Hz (it also plays
under the engine); its cymbal-marked sections fall every 4 bars, so loop points may sit on any
4-bar phrase (`grid_beats=16`), not before 23 s (the drum-less intro ends in a full stop at
21–22 s) and at least 80 s apart (`min_loop`): a liaison drive lasts minutes and the
best-matching 16-bar loop (45 s, similarity 0.98) repeated audibly. Chosen loop: similarity
0.71 (menu 0.81, drive 0.68, results 0.69), onsets aligned at +3.5 ms, seam RMS step 3.3 dB
vs 3.2 dB natural step at A.

### Ambience — `assets/audio/ambience/` (fal SFX layers + synthesis, `tools/audio/gen_ambience.py`)

Stereo OGG, 90 s, loop the whole file, ≈ −24 LUFS. Built circularly: long grains of the fal
beds shuffled around the circle with equal-power crossfades (no audible repetition, seamless
by construction), a procedural circular pink-noise "air" layer with slow gusts, and events
placed at seeded times, each event + reverb tail added modulo the loop length. Every
ElevenLabs SFX clip carried a faint hum on the 200 Hz harmonic series (up to +24 dB over the
local floor) and sometimes a 15.6 kHz line: only lines that stick out are notched per clip.

- **`hanami.ogg`** (spring): breeze bed (grains 7 s / 2.5 s xfade, LP 11 kHz), distant stream
  (BP 300–7000 Hz, narrow right, −9 dB), air (−20 dB), synthesised **uguisu** "hoo-hokekyo"
  (`synth_lib.uguisu`: ~1.1 kHz whistle, ho upsweep, ke downsweep, FM kyo 3.4→2.0 kHz; 3 bouts
  × 2 calls, forest reverb) plus 9 gated songbird events from the fal bird clips. The fal
  "uguisu" prompts did not produce the real song, so they are only used as generic trills.
- **`momiji.ogg`** (autumn): wind bed (grains 6 s / 2 s, a tonal whistle artefact at
  12.3–16.6 s of the source skipped, LP 9 kHz), air (−14 dB), synthesised **suzumushi** bell
  crickets (`synth_lib.bell_cricket` ×5: 4.1–4.8 kHz "riiin" chirps with 38–46 Hz pulse
  texture, ~1/s, fixed pans) over the fal cricket chorus (BP 3.5–9 kHz, −17 dB), 3 distant crow
  events (LP 3.8 kHz, valley reverb), 5 dry-leaf gusts.
- **`natsu.ogg`** (summer afternoon, the liaison road): warm breeze in grass and bamboo (grains
  7 s / 2.5 s, LP 10 kHz), a nearby stream (BP 250–9000 Hz, panned left, −6 dB), air, the fal
  minminzemi chorus (grains 6.5 s / 2.2 s skipping a level step at 7.7–8.6 s of the source,
  BP 2.5–12 kHz, −8 dB). On top, synthesised voices from `synth_lib`: 7 **minminzemi**
  (`minminzemi`: 4.1–4.95 kHz "miiin-min-min-miiii" phrases, grove reverb, fixed pans),
  2 distant **higurashi** (`higurashi`: falling "kana-kana" note trains near 4.5 kHz) and 6
  **furin** wind-chime clusters (`furin`: glass modes around 2.6 kHz, distant, right) timed
  to the gust peaks of the air layer; 2 cicada swells from the first 6.9 s of the fal
  higurashi clip, which came out as a steady cicada buzz rather than the real "kana-kana".
  Band balance and loudness sit between hanami and momiji.

fal model `fal-ai/elevenlabs/sound-effects/v2`, `prompt_influence` 0.5 (0.6 for single calls),
`output_format mp3_44100_192`, `loop: true` for the 22 s beds:

| Cache name | s | Prompt |
|---|---|---|
| `amb_hanami_breeze` | 22 | Gentle spring breeze softly rustling through leafy trees on a quiet mountainside, soft continuous wind in foliage, calm and airy, no birds, no people |
| `amb_hanami_stream` | 22 | Distant small mountain stream gently babbling over rocks, soft continuous trickling water heard from far away, calm, no birds |
| `amb_spring_birds` | 15 | Small songbirds chirping sparsely in spring trees on a mountain, distant, occasional soft tweets and short melodic calls, quiet, no wind, no water |
| `amb_uguisu_1` | 6 | Japanese bush warbler (uguisu) singing its famous call 'hoo-hokekyo' once in a quiet spring forest, clear single bird, natural, slightly distant, no other sounds |
| `amb_uguisu_2` | 6 | A single Japanese bush warbler calling 'hoo-hokekyo' from a nearby tree in spring, long rising whistle followed by a quick warble, clean recording, quiet background |
| `amb_momiji_wind` | 22 | Soft autumn evening wind blowing through a valley of maple trees, gentle slow gusts with dry leaves rustling in the branches, continuous, calm, no birds |
| `amb_suzumushi` | 22 | Japanese bell crickets (suzumushi) chirping at dusk in autumn grass, soft ringing insect chorus, continuous, calm, gentle and distant, no wind |
| `amb_crows_1` | 6 | Two or three distant crows cawing far away across an autumn valley at sunset, spacious and echoing, quiet background |
| `amb_crows_2` | 5 | A single crow cawing a few times in the distance over mountains in the evening, natural outdoor recording, quiet background |
| `amb_leaves` | 5 | Dry autumn leaves rustling and skittering softly along the ground in a light gust of wind, then settling, gentle, no footsteps |
| `amb_natsu_breeze` | 22 | Light warm summer breeze through tall grass and bamboo leaves on a quiet countryside afternoon, soft continuous airy rustle, calm, no insects, no birds, no people |
| `amb_natsu_stream` | 22 | A clear shallow summer stream flowing over pebbles nearby, gentle continuous bright trickling and bubbling water, calm, no insects, no birds |
| `amb_natsu_minmin` | 22 | Japanese minminzemi cicadas singing in summer trees on a hot afternoon, the rhythmic 'meen-meen-meen' call rising and falling, a few cicadas at a medium distance, continuous, no birds, no people, no wind |
| `amb_natsu_higurashi` | 8 | A single higurashi cicada calling 'kana-kana-kana' in a Japanese forest on a summer evening, a clear bell-like trill that slowly falls and fades, slightly distant, quiet background, no other insects |

### UI — `assets/audio/ui/` (synthesised: `tools/audio/synth_ui.py` + `synth_lib.py`)

Mono WAV, modal synthesis in the D yo pentatonic, HP 90 Hz, 2 ms raised-sine attack, tail
faded to exactly 0. Levels by loudest-400 ms momentary loudness (integrated LUFS of a blip
is meaningless).

| File | Sound | Peak |
|---|---|---|
| `hover.wav` | 70 ms bamboo tap A6 | −8.7 dB |
| `click.wav` | wood-block "kon" A5 (free-bar modes 1/2.76/5.4/8.93, cavity resonance, mallet noise) + bamboo A6 overtone | −4.5 dB |
| `back.wav` | two darker descending wood taps D5 → A4 | −5.4 dB |
| `start.wav` | rising taps D5-G5-A5 landing on a small rin bell D6 | −5.0 dB |
| `toggle.wav` | double bamboo tick A6 → B6 | −8.2 dB |

### Stingers — `assets/audio/stingers/` (synthesised: `tools/audio/synth_stingers.py` + `synth_lib.py`)

Stereo WAV, D yo pentatonic (D E G A B — fits menu/results in D major and the D-centred
drive), small synthetic hall, true peak ≤ −1 dBTP, taiko/rin voices faded so nothing ends on a
cut drum. Instruments: Karplus-Strong koto (pitch within ±0.1 cent D3–D6), taiko (o-daiko /
shime), rin bell, breathy shakuhachi with scooped attack and delayed vibrato.

| File | Length | Content |
|---|---|---|
| `countdown.wav` | 0.58 s | soft high taiko tap + koto A4 |
| `go.wav` | 1.45 s | o-daiko hit with pitch glide + shime + bright koto strum D4-A4-D5-E5-A5 + rin D6 |
| `checkpoint.wav` | 0.95 s | two-note chime A5 → D6, rin doubled by koto |
| `finish.wav` | 2.95 s | taiko don-doko-DON, koto arpeggio resolving to a D chord, rin D5 |
| `record.wav` | 4.40 s | taiko pickup roll + 3 hits, two-octave koto arpeggio, shakuhachi A4-B4-D5, final D chord + rin |
| `arrived.wav` | 1.90 s | liaison arrival: soft, muted koto roll B4-D5-A5, rin D6 / A5 blooming on the last note, long hall tail; deliberately quiet (momentary max −18 LUFS vs −16 for checkpoint) |
| `campaign_complete.wav` | 4.80 s | campaign finale: taiko don … don-don DON + DON, koto arpeggio D4 → D6, shakuhachi D5-E5-A5, full D chord D3–D6 with rin D6 / A5 (momentary max −14 LUFS, like finish/record) |

`synth_stingers.py [name ...]` rebuilds only the named stingers (all when none are given).

### Provenance, spend and licensing

- fal generations: 19 total (4 × `elevenlabs/music/v2.5`, 14 × `fal-ai/elevenlabs/sound-effects/v2`,
  1 × `fal-ai/stable-audio-3/medium/text-to-audio` comparison, unused). Every call is logged
  in `tools/audio/fal_log.json` (model, params, request id); downloads are cached in
  `tools/audio/cache/` so `gen_music.py` / `gen_ambience.py` rebuild offline.
  `fetch_fal.py` only calls fal for missing cache entries (needs `FAL_KEY` in the env).
- ElevenLabs (music + SFX): the user owns the generated output; commercial use requires output
  created under a paid plan / API with commercial rights; output is not guaranteed exclusive.
  https://elevenlabs.io/music-terms, https://elevenlabs.io/eleven-music-model-specific-terms,
  https://elevenlabs.io/terms-of-use. fal: output is Customer Content; commercial use depends
  on each model's licence (models carry a "Commercial" label):
  https://fal.ai/legal/terms-of-service, https://fal.ai/docs/documentation/model-apis/faq.
  [INFERENCE] ElevenLabs endpoints on fal may be governed by fal's agreement with ElevenLabs
  rather than a personal ElevenLabs plan — confirm the "Commercial" tag on the fal model pages
  before shipping commercially.
- Stable Audio 3 (reference only, not shipped): Stability AI Community License,
  https://stability.ai/license.
- Engine sets (turbo4, na4), car world, UI, stingers, uguisu, suzumushi, minminzemi,
  higurashi and furin voices: original procedural synthesis
  in this repo, no third-party terms.

## Verification

Tools (all under `tools/audio/`, Python venv `tools/audio/.venv`, create with
`uv venv tools/audio/.venv && uv pip install --python tools/audio/.venv/bin/python numpy scipy matplotlib pyloudnorm soundfile requests librosa`):

- `analyze.py [paths]` — per-file duration, peak dBFS, integrated LUFS (stereo-aware), DC;
  loop seam metrics (worst channel); spectrogram PNG + seam-view PNG in
  `tools/audio/renders/` (scratch, git-ignored).
- `render_test.py [wav]` — spectrograms (full + 0–2.5 kHz engine zoom with event marks),
  peak/LUFS/clipped-sample count and a click detector (> 15 kHz residual vs local RMS).
- `test/sound_api_smoke.gd` — headless call of every `Sound` entry point with every
  documented name plus unknown names.
- `scenes/test/audio_test.tscn` (+ `test/audio_test_driver.gd`, `test/fake_car.gd`) —
  a scripted rally run of a toy-drivetrain car implementing the car API, recorded from the
  Master bus with `AudioEffectRecord` to `tools/audio/renders/audio_test*.wav`. `--na4`
  makes the fake car the Hayate (`engine_sound` na4, 1000–8000 rpm, no boost); with `--mix`,
  `--liaison` plays liaison music + natsu instead of drive + hanami.

Rebuild everything:

```
tools/audio/.venv/bin/python tools/audio/synth_engine.py      # [turbo4|na4], default both
tools/audio/.venv/bin/python tools/audio/synth_world.py
tools/audio/.venv/bin/python tools/audio/synth_ui.py
tools/audio/.venv/bin/python tools/audio/synth_stingers.py
tools/audio/.venv/bin/python tools/audio/gen_music.py       # from tools/audio/cache (fal)
tools/audio/.venv/bin/python tools/audio/gen_ambience.py    # from tools/audio/cache (fal)
timeout 180 $S --headless --disable-crash-handler --path . --import
tools/audio/.venv/bin/python tools/audio/set_loop_imports.py
timeout 180 $S --headless --disable-crash-handler --path . --import
tools/audio/.venv/bin/python tools/audio/analyze.py
timeout 200 $S --headless --disable-crash-handler --path . res://scenes/test/audio_test.tscn            # full run
timeout 200 $S --headless --disable-crash-handler --path . res://scenes/test/audio_test.tscn -- --clean # tarmac, no transients
timeout 200 $S --headless --disable-crash-handler --path . res://scenes/test/audio_test.tscn -- --mix   # + music & ambience
timeout 200 $S --headless --disable-crash-handler --path . res://scenes/test/audio_test.tscn -- --clean --na4   # Hayate engine
timeout 200 $S --headless --disable-crash-handler --path . res://scenes/test/audio_test.tscn -- --mix --liaison --na4
tools/audio/.venv/bin/python tools/audio/render_test.py tools/audio/renders/audio_test.wav
```
