# Sakura Rally - vehicle physics

A custom rally car on a plain `RigidBody3D` (Jolt, 120 Hz, physics interpolation on). No
`VehicleBody3D`. Everything runs in `Car._integrate_forces()`; the public API is the one in
`docs/CONTRACTS.md`.

| File | Role |
| --- | --- |
| `scenes/car/car.tscn` | Sakura: `Car` (RigidBody3D, layer 2, mask 1\|3), convex hull `Collision`, `Visuals` (CarVisuals) |
| `scenes/car/car_hayate.tscn` | Hayate: the same `Car` script with exported overrides, its own `Drivetrain` resource, a lower coupe hull and `hayate.glb` |
| `scripts/vehicle/car.gd` | `Car`: suspension, tyres, assists, air control, reset, contract API |
| `scripts/vehicle/wheel_state.gd` | `WheelState` (RefCounted), one per wheel in `Car.wheels` (FL, FR, RL, RR) |
| `scripts/vehicle/tyre_model.gd` | `TyreModel`: surface table and combined-slip tyre curve |
| `scripts/vehicle/drivetrain.gd` | `Drivetrain`: engine, turbo, clutch, gearbox, auto/manual logic, AWD diffs |
| `scripts/vehicle/car_input.gd` | `CarInput`: keyboard/gamepad shaping of the InputMap actions |
| `scripts/vehicle/car_visuals.gd` | `CarVisuals`: wheel spin/steer/travel, calipers, body lean, livery |
| `scripts/vehicle/car_placeholder.gd` | `CarPlaceholder`: code-built low-poly hatchback used when the GLB is missing |
| `scripts/vehicle/autopilot.gd` | `Autopilot`: AI driver along a Curve3D racing line |
| `scripts/camera/chase_camera.gd` | `ChaseCamera`: chase / chase_far / hood / bumper camera with shake |
| `scenes/test/physics_test.tscn` + `tools/physics/test_ground.gd` | Proving ground |
| `tools/physics/run_tests.gd` | Headless telemetry suite (below) |
| `tools/physics/keyboard_bot.gd` + `key_taps.gd` | Keyboard proxy driver: the autopilot's line and speed profile played on digital keys through the InputMap |
| `tools/physics/map_lap_runner.gd` / `map_drive.gd` | Timed laps of the real maps (tests; windowed camera check) |
| `tools/physics/before_after.gd` | Self-contained keyboard scenario that runs on ep1 and ep2 (numbers below) |
| `tools/physics/capture.gd` | Windowed screenshot / frame-strip capture into `docs/renders/` |


## Model

### Chassis
Two cars share `Car` and differ only in exported values (see the table under Tuning).
**Sakura** (default): 1250 kg, centre of mass `(0, 0.44, -0.1)` (low, a little forward: 55 % front
static weight), principal inertia `(1550, 1700, 480)` kg·m² (pitch, yaw, roll). **Hayate**:
1050 kg, centre of mass `(0, 0.42, 0)` (50:50), inertia `(1250, 1400, 390)`. The collision hulls
are convex (hatchback 4.2 × 1.8 × 1.4 m; the Hayate's coupe hull is lower, 1.24 m at the roof)
with the floor 0.2 m above the ground, so only the wheels touch the road; the body only collides on
crashes, rolls and big landings. The hull's physics material has friction 0 and bounce 0: what
happens on a crash is decided by `Car._update_crash` (see "Crashes and walls"), not by the solver
dragging a corner along a wall. Body linear damping is off (aero drag is modelled), angular
damping is a token 0.02.

### Suspension (per wheel)
- A `CylinderShape3D` (tyre radius 0.33, width 0.24, axle along X) is shape-cast down the car's up
  axis against layer 1, starting `CAST_MARGIN` above full bump. The cylinder rolls smoothly over
  kerbs, step edges and the lip of a ramp, where a raycast would snap. Near-vertical edge normals are
  bent towards the car's up axis.
- Force = spring `k·(free − length)` + bump-stop (progressive, last 3 cm) + hydraulic stop (extra
  bump damping in the last 6 cm), clamped to `MAX_ELASTIC_LOAD`, then the damper
  (bump/rebound rates, digressive above `damper_knee` m/s in bump), then the anti-roll bar
  (`arb · (other side length − this length)`). The elastic part is clamped before damping so a hard
  landing is absorbed without the spring slingshotting the car back up.
- Travel 0.22 m (0.10 m in bump from the static ride height). Free length is computed from the
  static axle load, so the car sits exactly at the contract ride height (wheel centres at y = 0.33).
- Surface lookup per contact: `collider.surface_at(point)` if the method exists, else
  `collider.get_meta("surface")`, else `&"tarmac"`.


### Tyres (`TyreModel`)
Similarity-method combined slip: `s = |(κ/κ_peak, tanα/tanα_peak)|`. Each direction uses its own
magic-formula shape `sin(C·atan(B·s))`, with `B = tan(π/2C)` so the peak sits exactly at `s = 1`
and `C` alone controls how much grip remains past the peak (lower C = broader, more forgiving). The
force is split back along `(sx, sy)/s`, which is the friction ellipse. Peak force is lightly
load-sensitive: `μ · Fz · (1 − 0.05 · (Fz/3100 − 1))`, clamped to 0.7-1.15 of nominal, so weight
transfer costs little grip and the car corners flat and predictably. `Car.grip_scale` multiplies μ.

| Surface | μ | lat peak α | lat C | long peak κ | long C | rolling | soft drag | roughness | loose |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| tarmac | 1.44 | 0.125 rad | 1.45 | 0.10 | 1.50 | 0.012 | 0 | 0.03 | no |
| gravel | 1.12 | 0.20 | 1.20 | 0.17 | 1.25 | 0.020 | 0.0020 | 0.55 | yes |
| dirt | 1.08 | 0.19 | 1.25 | 0.16 | 1.30 | 0.024 | 0.0025 | 0.40 | yes |
| grass | 0.78 | 0.17 | 1.30 | 0.15 | 1.35 | 0.040 | 0.0060 | 0.50 | yes |
| sand | 0.76 | 0.22 | 1.20 | 0.20 | 1.25 | 0.070 | 0.0110 | 0.30 | yes |

The μ values are arcade grip (ep1: 1.15 / 0.85 / 0.80 / 0.60 / 0.55); `loose` lets lift-off or
braking turn-in start a slide (drift intent).
Unknown surface ids fall back to tarmac. `soft drag` is a speed-proportional per-wheel drag (grass
and sand bog the car down); `roughness` drives camera rumble, visual jiggle and `WheelState.surface_roughness`.

**Wheel spin** is integrated per wheel with its own inertia (`wheel_inertia` plus the reflected
driveline inertia from the drivetrain). The tyre reaction is linearised around the current slip
(semi-implicit), so stiff tyres stay stable on a light wheel at 120 Hz; brake torque is applied last
and can lock the wheel exactly (no chatter). Longitudinal and lateral forces act at the contact point
raised to the roll-centre / anti-pitch heights (`roll_centre_*`, `anti_pitch`), which sets how much the
body rolls and dives without changing grip.

**Low-speed stabilisation.** Below ~2.5 m/s at the contact patch the lateral force blends into an
exact "stick" force (cancels lateral velocity and gravity along the slope within the grip limit).
When the car is (almost) stopped with no throttle it anchors each contact point and holds it with
a stiff spring-damper plus wheel lock; a creep brake (with a hill-hold term proportional to the
slope) settles a coasting car. The result: 0.2 cm drift over 5 s on a 15° slope, no jitter.


### Drivetrain (`Drivetrain`, a Resource per car scene)
- **Sakura engine**: 2.0 turbo, torque table peaking at 490 Nm at 4000 rpm, redline 7800, idle 900,
  engine inertia 0.16 kg·m², friction `14 + 0.0062·rpm` Nm. 75 % of the torque is naturally
  aspirated (`na_fraction`), the rest is boost; the boost target rises from 1500 to 3000 rpm and
  spools with a 0.25 s time constant (ep1: 60 % NA, 1800-3400 rpm, 0.42 s: 0-100 took 5.0 s).
  Exposed as `Car.boost` (0..1).
- **Hayate engine**: 1.6 NA twin-cam (`turbo = false`), idle 1000, redline 8000, torque 231 Nm at
  5500, about 166 kW at 7500 rpm, engine inertia 0.07. That is above the brief's "about 150 kW":
  at 150 kW the 0-100 target of 4.3-5.2 s was out of reach (5.33 s with the final drive already
  shortened), so the curve was raised 8 %.
- **Limiter**: 55 ms fuel cut at redline; the car bounces off it (`rev_limiter` per cut,
  occasionally `backfire`). In top gear a soft governor replaces it.
- **Gearbox**: Sakura 6 speeds `3.76 2.565 1.963 1.59 1.344 1.158`, final 4.3; Hayate
  `3.3 2.26 1.72 1.38 1.15 0.98`, final 5.2 (100 km/h in 3rd, no shift just before it). Reverse
  3.4, 90 % efficiency. Upshift 0.09 s / downshift 0.10 s with a throttle cut and clutch re-engagement.
- **Auto mode**: upshift rpm scales with throttle (`upshift_rpm_light` → `_full`), downshift
  `downshift_rpm_light` → `_full`, kickdown on full throttle below `kickdown_rpm`, downshifts under
  braking, no shifts while airborne or on the handbrake, 0.55 s / 0.35 s cooldown after up/down
  shifts. Below the full-throttle point it upshifts only after `cruise_time` of cruising and not
  while slowing by more than `upshift_min_accel`, so lifting into a corner holds the gear.
  Low-rpm and kickdown downshifts only land below `downshift_target_max`. With the clutch locked the
  full-throttle upshift also looks at engine rpm (on gravel the wheels spin up and the engine reaches
  the limiter before road speed says so). **While sliding** (drift intent > 0.1, set by the car in
  `Drivetrain.sliding`) road speed along the nose says nothing about the gear (at 40° of slip it
  reads 25 % low and the driven wheels spin), so the box holds the gear and shifts only on engine
  rpm against the same up/down points: no downshift or shift cut in the middle of a drift.
  **Manual mode** when `Game.get_setting("transmission") == "manual"` (`shift_up`/`shift_down`,
  `Car.shift_up()` / `shift_down()`; over-revving downshifts are refused). Reverse: hold brake at a
  standstill for 0.3 s; in reverse the brake pedal drives backwards and throttle brakes.
- **Clutch**: slipping launch clutch (Sakura 900 Nm, Hayate 320 Nm) whose bite rises with engine
  rpm up to `launch_rpm`; its capacity is scaled by the traction-control factor, and at full
  throttle it only locks once the driveline is past 0.6 × `launch_rpm`, so a wheelspin spike cannot
  drag the engine down into a bog. 50 ms engagement after shifts. A locked clutch couples engine
  inertia to the wheels.
- **Drive**: Sakura AWD 40:60 with a viscous/preloaded centre coupling and limited-slip axles
  (`center_*`, `lsd_*`); Hayate RWD (`front_split = 0`) with a rear LSD (preload 50, bias 0.5).
- **Handbrake** disconnects the rear axle from the drive and applies `handbrake_torque` to the rear
  wheels.

### Assists (tuned for fun, not realism)
The handling brief for episode 2 was arcade rally (Sega Rally, Dirt 2, Forza Horizon): decisive
brakes, the nose goes where you point it, planted at speed, slides only when asked for, a slide
holds on throttle and is caught by centring the wheel, hard to spin. Keyboard first.

- **Surface-aware steering lock** (`Car.steer_lock_at`): at speed the lock is what the front tyres
  can actually use on the surface under them: the kinematic angle for the grip-limited radius,
  `atan(L · μ · g · steer_grip_margin / v²)`, plus `steer_slip_factor` (1.3) × that surface's peak
  slip angle, capped at `steer_lock_deg` (32°). On gravel at 100 km/h that is about 17° (ep1:
  11.3°, below gravel's 11.5° peak slip angle, so the fronts could never reach peak force above
  ~70 km/h and corners ran long). 60 % Ackermann.
- **Keyboard steering** (`CarInput`): ramps to full lock at 6/s (standstill) to 4.5/s (speed);
  letting go returns it to centre at 9/s → 4.5/s, so taps through a long corner average out; the
  opposite key swings across centre at 9/s. Stick: 1.35 response curve and light smoothing. Pedals
  ramp in at 9/s on keyboard.
- **Countersteer**: the front wheels lean towards the direction of travel by 55 % of the body slip
  beyond 4°, so a slide is caught by centring the wheel.
- **Yaw-rate controller**: the steering asks for `input × r_max`, with `r_max` the smaller of the
  kinematic rate at full lock and `yaw_grip · μ_front · g / v`. Below the target (turn-in, direction
  changes) a torque of `yaw_turn_in_gain` per rad/s helps the car rotate; above it
  (`yaw_damping_gain`) it stops overshoot and damps the car straight when the wheel is centred.
  Fades out with drift intent and on the handbrake. The assists read the steering through a short
  memory (`steer_memory_time` 0.25 s) so key taps through a corner keep asking for the corner.
- **Body-slip governor**: beyond an allowed slip angle a yaw torque (`slip_governor_gain` per rad,
  max `slip_governor_max`) rotates the nose back to the velocity, and slip growth close to the limit
  is damped. The allowance is `slip_allow_low` → `slip_allow_high` × the rear surface's peak slip
  angle (≤ 40 → ≥ 150 km/h), shrinks to `slip_allow_centred_deg` with the wheel centred, and grows
  to the drift allowance with drift intent or on the handbrake (`handbrake_slip_deg`). This is what
  stops a full-lock panic at 160 km/h from turning into a spin.
- **Drift intent** (0..1, `Car.drift_intent`): the handbrake raises it to 1; lifting or braking
  with the wheel turned past 60 % on a loose rear surface (25-110 km/h) raises it to
  `lift_turn_intent`; throttle while sliding holds it; centring the wheel ends it
  (`drift_exit_rate`/s). With full intent the allowed slip is `drift_slip_low_deg` (≤ 70 km/h) →
  `drift_slip_high_deg` (≥ 160 km/h).
- **Drift hold**: on throttle with drift intent a yaw torque steers the slip towards a wanted angle
  set by the steering, from `drift_hold` × the allowance (full countersteer) to the full allowance
  (steering into the slide), with `drift_damping` on slip changes so bang-bang keyboard steering
  swings the slide smoothly between those angles instead of snapping it straight.
- **Brakes and ABS**: brake torque (2800 / 2000 Nm) can lock any surface; ABS holds every braked
  wheel at `abs_slip_ratio` (0.95) of the surface's peak slip ratio in a straight line and at
  `abs_slip_ratio_steer` (0.6) at full lock, so trail braking keeps front lateral grip. ep1 was
  torque-limited (1250 / 700 Nm ≈ 0.96 g whatever the surface: 42.5 m from 100 km/h on tarmac).
- **Traction control**: cuts throttle when a driven wheel's slip passes `tc_slip_multiple` × the
  surface's peak slip ratio, and limits a slipping clutch by the same factor so a launch cannot
  keep feeding flywheel energy into spinning tyres. With drift intent the allowed slip grows by
  `drift_tc_relax` × itself: throttle is what keeps a slide going.
- **Aero**: drag `½ρ·C_dA·v²`, downforce `½ρ·C_lA·v²` split `aero_front_share` front.
- **Air control**: after 0.05-0.35 s of airtime a levelling torque rights the car and damps its
  pitch/roll spin; steering adds a gentle yaw.
- **Auto-reset**: upside down, stuck in the air, or tilted and not moving while the driver presses
  throttle/brake for more than 2.5 s → reset to `nearest_reset_transform(pos)` of the first node in
  group `track` that has it, else upright in place. `reset_car` action → `reset_to_track()` immediately.

### Signals
`gear_changed(new, old)`, `backfire` (lift-off at high rpm, shifts, some limiter cuts; ≥ 90 ms apart),
`rev_limiter` (each limiter cut), `impact(strength, point)` from body contacts (impulse / (mass · 5 m/s),
0..2, ≥ 150 ms apart, threshold 0.06), `landed(strength)` after > 0.25 s airtime (landing speed / 7 m/s).


### Pop-up headlights (Hayate)
`CarVisuals` animates `PopUp_L` / `PopUp_R` when the model has them: the pods rise
`popup_open_deg` (55°) about their local +X while the car is awake (moving, revving, or any pedal
pressed) and fold away after `popup_sleep_time` (4 s) standing still. They move on a slightly
underdamped spring (`popup_period` 0.5 s, `popup_damping` 0.62): opening overshoots a few degrees
and settles, closing lands on the stop.

## Tuning parameters

Exported on `Car` (inspector groups). Defaults are the Sakura; the Hayate column lists only its
overrides in `car_hayate.tscn`.

| Param | Sakura | Hayate | Effect |
| --- | --- | --- | --- |
| `centre_of_mass` | (0, 0.44, -0.1) | (0, 0.42, 0) | Lower = less roll/weight transfer; forward = more understeer, less rear traction |
| `body_inertia` | (1550, 1700, 480) | (1250, 1400, 390) | Yaw (y) sets how lazily the car rotates |
| `travel` / `bump_travel` | 0.22 / 0.10 m | | Total wheel travel and the part available in bump |
| `spring_front` / `spring_rear` | 30000 / 30500 N/m | 26000 / 25000 | Ride frequency (~1.7 Hz) |
| `damper_bump` / `damper_rebound` | 2600 / 5000 N·s/m | 2250 / 4300 | Bump kick / how fast the body settles |
| `damper_knee` / `damper_digressive` | 0.22 m/s / 0.4 | | Bump damping softens above the knee |
| `bump_stop_length` / `bump_stop_rate` | 0.03 m / 240000 | | Progressive end stop |
| `hydraulic_stop_length` / `_damping` | 0.06 m / 10000 | | Extra damping near full bump; eats big landings |
| `anti_roll_front` / `anti_roll_rear` | 16000 / 12000 N/m | 14000 / 9000 | Roll stiffness and balance |
| `grip_scale` | 1.0 | 1.03 | Tyre μ multiplier (Hayate: skidpad gravel 0.91 → 0.94 g, dirt 0.87 → 0.91 g) |
| `wheel_inertia` | 1.25 kg·m² | 1.1 | Wheel spin-up/lock response |
| `anti_pitch` / `roll_centre_front` / `_rear` | 0.3 / 0.10 / 0.14 m | | Dive/squat and roll without changing grip |
| `brake_torque_front` / `_rear` | 2800 / 2000 Nm | | Enough to lock any surface; ABS decides the rest |
| `abs_slip_ratio` / `abs_slip_ratio_steer` | 0.95 / 0.6 | | ABS target (× peak slip ratio) straight / at full lock |
| `brake_grip_bonus` | 1.0 | | Extra longitudinal grip while braking (unused at 1.0: the μ table already gives 27 m) |
| `handbrake_torque` | 3200 Nm | | Rear lock on the handbrake |
| `steer_lock_deg` / `steer_grip_margin` / `steer_slip_factor` | 32 / 1.0 / 1.3 | | Low-speed lock; surface-aware lock at speed |
| `ackermann` | 0.6 | | Inner wheel extra steer fraction |
| `countersteer_gain` / `_deadzone_deg` | 0.55 / 4 | | Automatic countersteer on body slip |
| `yaw_grip` / `yaw_turn_in_gain` / `yaw_damping_gain` / `yaw_torque_max` | 0.95 / 3000 / 5000 / 9000 | | Yaw-rate controller |
| `steer_memory_time` | 0.25 s | | Assists' memory of the last larger steering input |
| `slip_allow_low` / `_high` / `slip_allow_centred_deg` | 1.4 / 0.7 / 2 | | Allowed body slip without intent |
| `slip_governor_gain` / `_damping` / `_max` | 30000 / 6000 / 16000 | | Slip governor strength |
| `lift_turn_intent` / `drift_exit_rate` | 0.5 / 3.0 | | Drift intent from lift/brake turn-in; decay when centred |
| `drift_slip_low_deg` / `_high_deg` / `handbrake_slip_deg` | 45 / 22 / 85 | | Allowed slip with full intent (≤ 70 / ≥ 160 km/h), on the handbrake |
| `drift_gain` / `drift_hold` / `drift_damping` | 12000 / 0.7 / 5000 | | Drift hold on throttle |
| `tc_slip_multiple` / `drift_tc_relax` | 1.5 / 2.0 | 1.25 / 5.0 | TC threshold; how much more wheelspin a held drift may use |
| `air_level_torque` / `air_damping` / `air_yaw_torque` | 5500 / 5800 / 900 | | In-flight levelling, spin damping, steering yaw |
| `auto_reset_time` | 2.5 s | | Stuck/upside-down time before auto-reset |
| `wall_scrape_loss` / `wall_scrape_drag` / `wall_align_rate` | 0.22 / 2 m/s² / 4 | | Wall hit speed loss × sin(angle); drag while scraping; nose-to-wall alignment |
| `impact_guard_time` / `impact_yaw_limit` / `impact_tilt_limit` / `impact_climb_speed` | 0.6 s / 1.1 / 1.0 rad/s / 1 m/s | | Rate and launch limits after any wall/obstacle contact |
| `low_obstacle_height` / `thin_obstacle_radius` | 0.5 m / 0.6 m | | Ride-over obstacles; poles and trunks that deflect the car |
| `drag_area` / `downforce_area` / `aero_front_share` | 0.8 / 0.45 / 0.45 | 0.74 / 0.3 / | Top speed; high-speed planting |
| `engine_sound` | `turbo4` | `na4` | Read by `CarAudio` |

`Drivetrain` exports (per car scene resource): `torque_curve_*`, `engine_inertia`, `friction_*`,
`turbo`, `na_fraction`, `spool_*`, `turbo_*_time`, `limiter_cut_time`, `gear_ratios`,
`final_drive`, `upshift_time`, `downshift_time`, `clutch_max_torque`, `launch_rpm`,
`launch_hold_rpm`, `front_split`, `lsd_*`, `center_*`, `upshift_rpm_*`, `downshift_rpm_*`,
`cruise_time`, `upshift_min_accel`, `downshift_target_max`, `kickdown_rpm`, `brake_downshift_rpm`.
`CarVisuals`: `model_path` (per scene), lean, jiggle and pop-up headlight exports. `CarInput`:
`key_steer_rate_*`, `key_release_rate_*`, `key_return_rate`, `stick_exponent`, `pedal_rate`.

### What each lever did (episode 2)
The ep1 → ep2 changes, in the order they were made, with the numbers they moved:

| Lever | Change | Effect |
| --- | --- | --- |
| Brakes | 1250 / 700 Nm torque-limited → 2800 / 2000 Nm with ABS at 0.95 × peak slip | 100-0 tarmac 42.5 → about 33 m (torque no longer the limit) |
| Tyre μ | tarmac 1.15 → 1.44, gravel 0.85 → 1.12 (all surfaces ~+30 %), load sensitivity 0.11 → 0.05 | 100-0 tarmac 27.4 m, gravel 35.2 m; skidpad tarmac 1.03 → 1.19 g, gravel 0.73 → 0.93 g |
| Steering lock | `32°/(1 + kmh/55)` → kinematic angle + 1.3 × surface peak slip | gravel lock at 100 km/h 11.3° → 17°: fronts reach peak force on loose surfaces |
| Keyboard steering | 5 → 2.4/s ramp, 8/s return → 6 → 4.5/s ramp, speed-dependent release | turn-in at 90 km/h: 80 % of steady yaw rate in 0.12 s tarmac / 0.24 s gravel |
| Yaw-rate controller | replaces the ep1 over-rotation damper | helps turn-in, stops overshoot; yaw-kick settle 0.17 s |
| Slip governor + drift intent | new | panic steer at 160 km/h: max 13° (ep1 hairpin scenario: 46°) |
| Turbo | NA 60 → 75 %, spool 0.42 → 0.25 s, boost from 1500-3000 rpm | Sakura 0-100 5.0 → 3.54 s, 0-60 1.87 s, top speed unchanged at 188.8 km/h |
| Launch clutch | TC scales clutch capacity; no lock below 0.6 × launch_rpm at full throttle | Hayate 0-60 3.25 → 2.95 s (no bog after a wheelspin spike) |
| Hayate COM, launch_rpm, TC | z -0.08 → 0, 5500 → 4200 rpm, tc 1.25 | Hayate 0-100 tarmac 5.49 → 5.43 s, gravel 7.62 → 6.44 s |
| Hayate final drive | 5.55 → 5.2 | 0-100 5.43 → 5.33 s (100 km/h in 3rd), top speed 176.7 → 187.9 km/h |
| Hayate torque | +8 % (peak ~166 kW) | 0-100 5.33 → 5.05 s, gravel 6.33 → 6.08 s |
| Upshift on engine rpm (clutch locked) | new | no limiter bouncing on gravel launches |
| Drift damping, drift_hold 0.55 → 0.7 | new export 5000 Nm/(rad/s) | keyboard drift stops swinging 50° → 5° → 50° |
| Gearbox holds gear while sliding | new (`Drivetrain.sliding`) | Sakura drift held 1.2 → 2.3 s, exit 52 → 88 km/h |
| `drift_tc_relax` | new, Sakura 2.0, Hayate 5.0 | Hayate drift exit 35 → 51 km/h |
| Hayate `grip_scale` | 1.0 → 1.03 | skidpad gravel 0.91 → 0.94 g, dirt 0.87 → 0.91 g |

### Targets and why
The Sakura targets are the episode 2 brief. The Hayate's brief targets were 0-100 on tarmac
4.3-5.2 s, top speed 175-190 km/h and braking as good as the Sakura or better; its other windows
were set here:

| Hayate target | Window | Reason |
| --- | --- | --- |
| 0-60 km/h tarmac | ≤ 2.8 s | A 1050 kg RWD NA car limited by rear traction; with 0-100 at 5.0 s it runs 2.6 s. The ≤ 2.6 s first set was too tight for 0-100 inside its window |
| 0-100 km/h gravel | 4.8-6.4 s | RWD on gravel has half the driven contact patches of the AWD car; 6.0 s measured |
| 100-0 tarmac / gravel | 25-33 / 29-38 m | "As good or better": the Sakura's windows with a lower bound 2 m shorter for the lighter car |
| drift slip | 30-50° | The Hayate is meant to drift more readily: 5° more allowed than the Sakura |
| everything else | same as the Sakura | Same no-spin guarantees, turn-in, skidpad and keyboard-bot requirements |

`Game.CARS` stats (0..1) come from this table: speed = top speed / 240 km/h; acceleration =
1 − (0-100 tarmac − 2.5 s) / 6 s; grip = tarmac skidpad g / 1.35; drift = peak held drift slip
/ 52°. Sakura 0.79 / 0.83 / 0.88 / 0.81, Hayate 0.78 / 0.59 / 0.90 / 0.88.

## Autopilot
`Autopilot` (Node child of the car) takes `path: Path3D` or `curve` + `curve_transform`; `closed`
false follows an open line from start to end and brakes to a stop. It precomputes a speed profile
from the line's curvature and the grip under each sample (`v = sqrt(corner_grip · μ · g · R)`),
then runs backwards/forwards braking- and acceleration-distance passes (`brake_grip`). Steering is
pure pursuit on a lookahead of `lookahead_base + lookahead_time · v` (7-30 m), converted to a steer
input through `Car.steer_lock_at()`. Throttle/brake come from a speed-error controller with
anticipation; off the line on a slower surface the target scales by √(grip under the tyres / grip
of the line), beyond `line_tolerance` it drops by `wide_slowdown` per metre, and the throttle backs
off while the body slides. `corner_grip` 0.68 / `brake_grip` 0.72 keep about 25 % of the car's
grip in hand on narrow loose roads. Exported: `enabled`, `closed`, `speed_scale` (0.2-1.3),
`lateral_offset`, `max_speed_kmh`; `laps`, `lap_time`, `last_lap_time`, `progress`,
`lateral_error` and `lap_completed` are available for menus and tests. The controls go out through
`_apply()`.

**Keyboard bot** (`tools/physics/keyboard_bot.gd`): extends `Autopilot` and overrides `_apply()`
so the same line and speed profile are driven on digital keys through the InputMap
(`controlled_by_player = true`, `Input.action_press/release`): bang-bang steering with hysteresis
and on/off throttle and brake. It is the proxy for "a keyboard player can drive it": it has to lap
both real maps clean within 1.12× the analog autopilot.

Reference laps (Sakura, analog, ep2): Hanami 113.3 s, Momiji 99.5 s (ep1: 123.4 / 108.2 s). The
`Game.MAPS` medals are 1.1 / 1.22 / 1.42× these, rounded to 0.5 s.

## Chase camera
`ChaseCamera` (Camera3D) follows `target.get_global_transform_interpolated()`. Heading follows a
blend of the car's forward axis and its velocity (`velocity_bias`), so a slide swings the view out,
with look-ahead and speed-based FOV (70 → 82 at 180 km/h). A sphere cast pulls it in front of
terrain/walls. Trauma shake (`shake(amount)`, decays) from impacts and landings, plus rumble from surface
roughness × speed. Modes `chase`, `chase_far`, `hood`, `bumper`: cycled with `camera_next` and
saved via `Game.set_setting("camera", mode)` when `player_camera` is true. `snap()` after teleports.

The chase camera itself is unchanged in episode 2. Checked with windowed keyboard-bot laps of both
maps (`tools/physics/map_drive.gd`, Hanami 114.4 s, Momiji 100.8 s, max slip 8-10°) and the
gravel handbrake slide capture (`docs/renders/physics_slide_gravel.png`, `tools/physics/capture.gd -- only=slide`): the view swings out
with the slide and keeps the car framed.

## Proving ground (`scenes/test/physics_test.tscn`)
Flat 2.4 km grass plane (meta `surface = grass`, group `track`) with: 900 m tarmac and gravel
runways, five 110 m skidpads (tarmac/gravel/dirt/grass/sand), a gravel jump lane with a kicker, a
bumpy dirt lane, three 200 × 1100 m handling plazas (tarmac, gravel, dirt: run-up to 160 km/h then
panic steer, slalom and drift tests), a banked turn, a 15° slope, a concrete wall, and a closed 1.5 km loop road (tarmac
first half, gravel second half, fast sweepers, tight esses and a hairpin). It implements
`surface_at(point)` and `nearest_reset_transform(pos)` like the real tracks. Spawns: `spawn(name)`,
`loop_transform(offset)`.


## Before / after (ep1 → ep2)
`tools/physics/before_after.gd` is self-contained (its own flat gravel field, plain
`Input.action_press` on the InputMap actions, only Car API that ep1 already had), so the same file
ran on the `ep1` tag (temporary worktree, since removed) and on this branch. Sakura, keyboard only:

1. **Brake into a hairpin**: 130 km/h on gravel, full brake at a marker down to 50 km/h, then full
   lock on throttle until the car has turned 180°.
2. **Panic steer at 140 km/h** on gravel: full lock for 1.5 s with the throttle held, lifted, or the
   brake pressed, then centre the wheel on throttle for 1 s.

| Scenario | ep1 | ep2 |
| --- | --- | --- |
| 130-50 braking distance | 67.3 m | 51.1 m |
| hairpin: marker to 180° | 7.97 s | 7.21 s |
| hairpin: max body slip | 46° (rear stepped out) | 13° |
| panic 140, throttle: max slip / slip 1 s after centring | 20° / 10.5° | 9° / 0.2° |
| panic 140, lift | 10° / 0.9° | 5° / 0.1° |
| panic 140, brake | 22° / 10.0° | 13° / 4.0° |
| panic 140: outcome | no spin, but still sliding 10° a second after centring on throttle or brake | no spin, straight within a second (4° on the brake case, which scrubbed to 102 km/h) |

Other ep1 → ep2 numbers from the suites: 0-100 tarmac 5.04 → 3.54 s, 100-0 tarmac 42.5 → 27.4 m,
gravel 46.2 → 35.2 m, skidpad gravel 0.73 → 0.93 g, Hanami lap 123.4 → 113.3 s, Momiji
108.2 → 99.5 s.

## Crashes and walls
Vel's ep2 playtest: a crash threw the car somewhere and could spin it several times; leaning on a
wall in a corner should cost a little speed and let you drive round along it, not cost 10 s of
recovery. `Car._update_crash` runs first in every tick on the contacts the solver reported for
the previous step and replaces what they did to the velocity:

- **What counts.** Only `StaticBody3D` contacts (loose and smashable props are left to the
  solver). A contact is a *wall* when its normal is mostly horizontal (`|n.y| < 0.6`: guardrails,
  bridge rails, stone walls, buildings, cliff and rock faces) and an *obstacle* when the body is on
  layer 3 (`PROPS_LAYER`, MapWorld's `Barriers` and `PropBody_x_y`). Obstacles whose top is less
  than `low_obstacle_height` (0.5 m) above the car's ground (rocks, stumps, logs) get the guard
  only: the car rides over them.
- **Wall scrape.** On the first hit of a crash the velocity keeps its component along the wall,
  scaled by `1 - wall_scrape_loss · sin(impact angle)` (0.22), and loses the part into the wall
  (no bounce-back); the rotation is restored to what it was before the solver's off-centre
  impulse. While the body stays against the wall the into-wall component is removed each tick,
  a `wall_scrape_drag` of 2 m/s² is the penalty for leaning on it, and above 8 m/s the yaw rate
  is steered to line the nose up with the velocity (`wall_align_rate` 4 /s per rad of slip,
  capped at the impact yaw limit), so the car ends up pointing along the wall and can drive on.
- **Thin cylinders** (radius < `thin_obstacle_radius` 0.6 m: poles, trunks) push the car sideways
  off the pole's axis and backwards in proportion to how much of the car's width overlaps it: a
  glancing hit deflects past it, a centred one stops.
- **Impact guard.** Any wall or obstacle contact (re)starts a 0.6 s guard (`impact_guard_time`).
  For its first half the yaw rate is limited to `impact_yaw_limit` (1.1 rad/s) and roll/pitch
  rates to `impact_tilt_limit` (1.0 rad/s); over the second half the limits relax to 3x. The car
  may not rise faster than `impact_climb_speed` (1 m/s) above its vertical speed before the hit,
  so a rock or a rail cannot launch it. The guard is gated on real contacts, so drifts, jumps
  and landings on open ground never see it.

Tests (`only=crash`, both cars, tarmac plaza, keyboard path): the car runs at the given speed into
a guardrail-like box (0.25 m thick, 1.0 m tall, the `Barriers` kind, on layer 3) crossing its path
at 10/25/45°, then holds throttle with the wheel centred. Loss is the lowest speed in the 0.5 s
after contact against the speed before it; yaw is the heading rate over 0.1 s windows (a one-tick
solver spike at contact is not what the driver sees); heading error is to the wall tangent 1 s
after contact; a spin is body slip > 75°. Pole and trunk hits are quarter-overlap (a quarter of
the 1.74 m body width) at 80 km/h; the rock is a 0.4 m tall, 1 m wide cylinder at 70 km/h; the
hairpin is a 90° right-hander (radius 20 m, 8 m wide) entered at 100 km/h with full lock and
throttle held and a rail on the outside.

Before = the car code and hull material of 54d0738 (ep2 as merged), after = this branch, same test
file:

| Test | Sakura before | Sakura after | Hayate before | Hayate after | Target |
| --- | --- | --- | --- | --- | --- |
| wall 10° at 90 km/h | loss 6 %, yaw 69°/s, head 1° @1s, air 0.00 s | loss 6 %, yaw 22°/s, head 0° @1s, air 0.00 s | loss 7 %, yaw 70°/s, head 0° @1s, air 0.00 s | loss 6 %, yaw 20°/s, head 1° @1s, air 0.00 s | loss 5-10 %, yaw < 90°/s, head < 10°, air < 0.05 s, 0 spins |
| wall 25° at 90 km/h | loss 20 %, yaw 163°/s, head 3° @1s, air 0.00 s **FAIL** | loss 18 %, yaw 52°/s, head 1° @1s, air 0.00 s | loss 22 %, yaw 163°/s, head 2° @1s, air 0.00 s **FAIL** | loss 18 %, yaw 50°/s, head 1° @1s, air 0.00 s | loss 15-25 %, yaw < 90°/s, head < 10°, air < 0.05 s, 0 spins |
| wall 45° at 90 km/h | loss 52 %, yaw 145°/s, head 0° @1s, air 0.00 s **FAIL** | loss 41 %, yaw 66°/s, head 2° @1s, air 0.00 s | loss 50 %, yaw 175°/s, head 0° @1s, air 0.00 s **FAIL** | loss 43 %, yaw 66°/s, head 4° @1s, air 0.00 s | loss 30-45 %, yaw < 90°/s, head < 10°, air < 0.05 s, 0 spins |
| wall 10° at 130 km/h | loss 7 %, yaw 86°/s, head 2° @1s, air 0.00 s | loss 5 %, yaw 25°/s, head 0° @1s, air 0.00 s | loss 7 %, yaw 80°/s, head 2° @1s, air 0.00 s | loss 5 %, yaw 24°/s, head 1° @1s, air 0.00 s | loss 5-10 %, yaw < 90°/s, head < 10°, air < 0.05 s, 0 spins |
| wall 25° at 130 km/h | loss 22 %, yaw 203°/s, head 0° @1s, air 0.00 s **FAIL** | loss 18 %, yaw 58°/s, head 0° @1s, air 0.00 s | loss 25 %, yaw 244°/s, head 6° @1s, air 0.00 s **FAIL** | loss 19 %, yaw 61°/s, head 1° @1s, air 0.00 s | loss 15-25 %, yaw < 90°/s, head < 10°, air < 0.05 s, 0 spins |
| wall 45° at 130 km/h | loss 53 %, yaw 173°/s, head 1° @1s, air 0.00 s **FAIL** | loss 41 %, yaw 65°/s, head 1° @1s, air 0.00 s | loss 51 %, yaw 224°/s, head 1° @1s, air 0.00 s **FAIL** | loss 44 %, yaw 67°/s, head 2° @1s, air 0.00 s | loss 30-45 %, yaw < 90°/s, head < 10°, air < 0.05 s, 0 spins |
| pole (r 0.16) hit 80 km/h (quarter overlap) | rotation 126°, yaw 144°/s, air 0.00 s, 69 km/h after **FAIL** | rotation 23°, yaw 41°/s, air 0.00 s, 74 km/h after | rotation 104°, yaw 146°/s, air 0.00 s, 49 km/h after **FAIL** | rotation 48°, yaw 54°/s, air 0.00 s, 50 km/h after | rotation < 90°, air < 0.2 s, upright |
| tree trunk (r 0.3) hit 80 km/h (quarter overlap) | rotation 92°, yaw 168°/s, air 0.00 s, 72 km/h after **FAIL** | rotation 28°, yaw 45°/s, air 0.00 s, 73 km/h after | rotation 53°, yaw 133°/s, air 0.00 s, 0 km/h after | rotation 29°, yaw 42°/s, air 0.00 s, 53 km/h after | rotation < 90°, air < 0.2 s, upright |
| 0.4 m rock at 70 km/h | air 1.23 s, min up 0.89, rotation 8°, 79 km/h after **FAIL** | air 0.26 s, min up 0.99, rotation 0°, 114 km/h after | air 0.72 s, min up 0.98, rotation 1°, 91 km/h after **FAIL** | air 0.20 s, min up 0.99, rotation 1°, 105 km/h after | air < 0.3 s, no roll-over |
| hairpin with outside rail, 100 km/h | exit 0.82 s later at 76 km/h, yaw 240°/s | exit 0.92 s later at 87 km/h, yaw 74°/s | exit 0.57 s later at 67 km/h, yaw 236°/s | exit 0.89 s later at 79 km/h, yaw 72°/s | exit <= 2.0 s after contact, 0 spins |

Before, none of these scripted hits spun the car outright (the multi-spins Vel saw came from hits
with steering and throttle already loading the car), but every 25-45° hit flicked it off the wall
at 145-245°/s, the pole hit rotated the Sakura 126°, and the rock launched it for 1.23 s. In the
hairpin the old car left the rail sooner only because it bounced off at 240°/s. After, no hit
turns the car faster than 74°/s, it points along the wall within 4° a second later, pole and trunk
hits turn it less than 50°, and nothing leaves the ground for more than 0.26 s. The hairpin exit
is 10 km/h faster.

Footage: `capture.gd only=crash` (see Visual review) on both versions. In the overhead pole sheet
the old car is swung round to about 90° across its path within 0.9 s; the new one is deflected
past the pole with the nose turned about 20° and drives on. `docs/renders/physics_wall_scrape.png`
is the chase view 0.25 s into a 25° guardrail hit at 110 km/h: the car runs along the rail.

## Telemetry (`tools/physics/run_tests.gd`)

```
S=/Applications/Summer.app/Contents/MacOS/Summer
timeout 2400 $S --headless --disable-crash-handler --fixed-fps 120 --path . -s res://tools/physics/run_tests.gd
# -- car=sakura|hayate|all  only=<groups in _run_car()>,maps  maps=hanami,momiji  soak=300
```

Every test except the straight-line braking tests and the skidpads drives through the real
keyboard path: `controlled_by_player = true` plus `Input.action_press/release` on the InputMap
actions, so `CarInput`'s keyboard shaping is part of every number. The `crash` group is described
under "Crashes and walls". The skidpad measures lateral g
from the turn rate of the velocity itself, not the body's yaw rate (which also counts changes of
body slip while the car slides in or out of the circle). "panic steer" reports max body slip /
time until the slip is below 3° after the key is released, for throttle held, lifted and full brake.
The `maps` group runs one lap per car and map with the analog autopilot and with the keyboard bot,
and prints the medal times the analog laps imply.

Latest results (2026-09-26, Apple M1 Max, headless, both cars): **108/108 PASS**.

| Test | Result | Target | |
| --- | --- | --- | --- |
| sakura: 0-100 km/h tarmac | 3.54 s | 3.3-3.9 s | PASS |
| sakura: 0-60 km/h tarmac | 1.87 s | <= 2.0 s | PASS |
| sakura: 0-100 km/h gravel | 3.85 s | 3.8-4.6 s | PASS |
| sakura: top speed | 188.8 km/h (gear 6) | 182-195 km/h | PASS |
| sakura: 100-0 braking tarmac | 27.4 m | 27-33 m | PASS |
| sakura: 100-0 braking gravel | 35.2 m | 31-38 m | PASS |
| sakura: 130-50 braking gravel | 49.9 m | <= 50 m | PASS |
| sakura: 150-0 braking, 0.2 steer held | 3.1 deg max body slip | < 8 deg | PASS |
| sakura: skidpad R30 tarmac | 1.19 g | 1.15-1.35 g | PASS |
| sakura: skidpad R30 gravel | 0.93 g | 0.92-1.08 g | PASS |
| sakura: skidpad R30 dirt | 0.90 g | 0.88-1.02 g | PASS |
| sakura: skidpad R30 grass | 0.64 g | 0.60-0.75 g | PASS |
| sakura: skidpad R30 sand | 0.59 g | 0.55-0.70 g | PASS |
| sakura: 150 km/h hands-off heading drift | 0.00 deg / 4 s | < 1.5 deg | PASS |
| sakura: 150 km/h yaw-kick settle | 0.17 s (overshoot 0.003) | < 1.5 s | PASS |
| sakura: turn-in 90 km/h tarmac (digital) | 0.12 s to 80 % of 27 deg/s | <= 0.35 s | PASS |
| sakura: turn-in 90 km/h gravel (digital) | 0.24 s to 80 % of 40 deg/s | <= 0.35 s | PASS |
| sakura: panic steer tarmac 130 km/h | throttle 4°/0.04s, lift 4°/0.01s, brake 6°/0.28s | slip < 20° (brake 25°), < 3° in 1 s | PASS |
| sakura: panic steer tarmac 160 km/h | throttle 5°/0.33s, lift 5°/0.33s, brake 6°/0.35s | slip < 20° (brake 25°), < 3° in 1 s | PASS |
| sakura: panic steer gravel 130 km/h | throttle 9°/0.70s, lift 5°/0.27s, brake 13°/0.78s | slip < 20° (brake 25°), < 3° in 1 s | PASS |
| sakura: panic steer gravel 160 km/h | throttle 8°/0.70s, lift 6°/0.35s, brake 10°/0.70s | slip < 20° (brake 25°), < 3° in 1 s | PASS |
| sakura: panic steer dirt 130 km/h | throttle 9°/0.69s, lift 5°/0.34s, brake 12°/0.79s | slip < 20° (brake 25°), < 3° in 1 s | PASS |
| sakura: panic steer dirt 160 km/h | throttle 8°/0.68s, lift 6°/0.41s, brake 9°/0.69s | slip < 20° (brake 25°), < 3° in 1 s | PASS |
| sakura: slalom 110 km/h gravel (0.9 s) | 13.9 deg max slip, 106 km/h min | < 20 deg, > 90 km/h | PASS |
| sakura: drift gravel 80 km/h: slip | 42 deg peak, held 2.3 s | 25-45 deg, >= 1.5 s | PASS |
| sakura: drift gravel: catch by centring | 0.76 s to < 5 deg, 88 km/h | <= 1.2 s, > 45 km/h | PASS |
| sakura: handbrake turn 60 km/h gravel | 117 deg/s peak, 83 deg @1.2s | > 60 deg/s, > 70 deg | PASS |
| sakura: handbrake turn drive-out | 70 deg total, 49 km/h @2s | > 15 km/h forward | PASS |
| sakura: wall 10° at 90 km/h | loss 6 %, yaw 22°/s, head 0° @1s, air 0.00 s, spins 0 | loss 5-10 %, yaw < 90°/s, head < 10°, air < 0.05 s, 0 spins | PASS |
| sakura: wall 25° at 90 km/h | loss 18 %, yaw 52°/s, head 1° @1s, air 0.00 s, spins 0 | loss 15-25 %, yaw < 90°/s, head < 10°, air < 0.05 s, 0 spins | PASS |
| sakura: wall 45° at 90 km/h | loss 41 %, yaw 66°/s, head 2° @1s, air 0.00 s, spins 0 | loss 30-45 %, yaw < 90°/s, head < 10°, air < 0.05 s, 0 spins | PASS |
| sakura: wall 10° at 130 km/h | loss 5 %, yaw 25°/s, head 0° @1s, air 0.00 s, spins 0 | loss 5-10 %, yaw < 90°/s, head < 10°, air < 0.05 s, 0 spins | PASS |
| sakura: wall 25° at 130 km/h | loss 18 %, yaw 58°/s, head 0° @1s, air 0.00 s, spins 0 | loss 15-25 %, yaw < 90°/s, head < 10°, air < 0.05 s, 0 spins | PASS |
| sakura: wall 45° at 130 km/h | loss 41 %, yaw 65°/s, head 1° @1s, air 0.00 s, spins 0 | loss 30-45 %, yaw < 90°/s, head < 10°, air < 0.05 s, 0 spins | PASS |
| sakura: pole (r 0.16) hit 80 km/h (quarter overlap) | rotation 23°, yaw 41°/s, air 0.00 s, 74 km/h after | rotation < 90°, air < 0.2 s, upright | PASS |
| sakura: tree trunk (r 0.3) hit 80 km/h (quarter overlap) | rotation 28°, yaw 45°/s, air 0.00 s, 73 km/h after | rotation < 90°, air < 0.2 s, upright | PASS |
| sakura: 0.4 m rock at 70 km/h | air 0.26 s, min up 0.99, rotation 0°, 114 km/h after | air < 0.3 s, no roll-over | PASS |
| sakura: hairpin with outside rail, 100 km/h | contact yes, out along the road 0.92 s later at 87 km/h, yaw 74°/s, spins 0 | exit <= 2.0 s after contact, 0 spins | PASS |
| sakura: jump airtime | 1.18 s (landing 1.00) | > 0.6 s | PASS |
| sakura: jump landing settle | 0.27 s, 0 bounces | < 1.0 s, 0 bounces | PASS |
| sakura: rest on 15° slope (up) | 0.069 cm / 5 s | < 1 cm | PASS |
| sakura: rest on 15° slope (across) | 0.044 cm / 5 s | < 1 cm | PASS |
| sakura: auto-reset when upside down | 2.82 s | 2.5-3.5 s, upright | PASS |
| sakura: reset_car onto track line | 0.00 m from line | < 1 m | PASS |
| sakura: autopilot laps (3 flying) | 67.2, 64.7, 64.7, 64.7 s | 3 laps | PASS |
| sakura: autopilot max line error | 1.06 m, 0 ticks off | wheels on road | PASS |
| sakura: autopilot crashes | 0 impacts > 0.25 | 0 | PASS |
| sakura: physics cost per tick (car) | 188 us avg, 5876 us max | < 400 us avg | PASS |
| sakura: soak 309 s (loop, jumps, wall, bumps, banking) | NaN=false vmax=44 m/s wmax=2.9 rad/s | no NaN, v<70, w<15 | PASS |
| sakura: soak events | 21 impacts (3 hard), 6 landings | signals fire | PASS |
| hayate: 0-100 km/h tarmac | 4.99 s | 4.3-5.2 s | PASS |
| hayate: 0-60 km/h tarmac | 2.60 s | <= 2.8 s | PASS |
| hayate: 0-100 km/h gravel | 5.99 s | 4.8-6.4 s | PASS |
| hayate: top speed | 188.2 km/h (gear 6) | 175-190 km/h | PASS |
| hayate: 100-0 braking tarmac | 26.5 m | 25-33 m | PASS |
| hayate: 100-0 braking gravel | 33.8 m | 29-38 m | PASS |
| hayate: 130-50 braking gravel | 47.8 m | <= 50 m | PASS |
| hayate: 150-0 braking, 0.2 steer held | 2.8 deg max body slip | < 8 deg | PASS |
| hayate: skidpad R30 tarmac | 1.21 g | 1.15-1.35 g | PASS |
| hayate: skidpad R30 gravel | 0.94 g | 0.92-1.08 g | PASS |
| hayate: skidpad R30 dirt | 0.91 g | 0.88-1.02 g | PASS |
| hayate: skidpad R30 grass | 0.64 g | 0.60-0.75 g | PASS |
| hayate: skidpad R30 sand | 0.65 g | 0.55-0.70 g | PASS |
| hayate: 150 km/h hands-off heading drift | 0.01 deg / 4 s | < 1.5 deg | PASS |
| hayate: 150 km/h yaw-kick settle | 0.21 s (overshoot 0.001) | < 1.5 s | PASS |
| hayate: turn-in 90 km/h tarmac (digital) | 0.11 s to 80 % of 27 deg/s | <= 0.35 s | PASS |
| hayate: turn-in 90 km/h gravel (digital) | 0.10 s to 80 % of 24 deg/s | <= 0.35 s | PASS |
| hayate: panic steer tarmac 130 km/h | throttle 4°/0.07s, lift 4°/0.01s, brake 6°/0.25s | slip < 20° (brake 25°), < 3° in 1 s | PASS |
| hayate: panic steer tarmac 160 km/h | throttle 4°/0.36s, lift 4°/0.33s, brake 6°/0.37s | slip < 20° (brake 25°), < 3° in 1 s | PASS |
| hayate: panic steer gravel 130 km/h | throttle 10°/0.72s, lift 5°/0.31s, brake 13°/0.78s | slip < 20° (brake 25°), < 3° in 1 s | PASS |
| hayate: panic steer gravel 160 km/h | throttle 8°/0.68s, lift 5°/0.39s, brake 10°/0.77s | slip < 20° (brake 25°), < 3° in 1 s | PASS |
| hayate: panic steer dirt 130 km/h | throttle 10°/0.70s, lift 5°/0.35s, brake 13°/0.78s | slip < 20° (brake 25°), < 3° in 1 s | PASS |
| hayate: panic steer dirt 160 km/h | throttle 8°/0.68s, lift 5°/0.45s, brake 10°/0.74s | slip < 20° (brake 25°), < 3° in 1 s | PASS |
| hayate: slalom 110 km/h gravel (0.9 s) | 13.2 deg max slip, 105 km/h min | < 20 deg, > 90 km/h | PASS |
| hayate: drift gravel 80 km/h: slip | 46 deg peak, held 2.4 s | 30-50 deg, >= 1.5 s | PASS |
| hayate: drift gravel: catch by centring | 1.06 s to < 5 deg, 51 km/h | <= 1.2 s, > 45 km/h | PASS |
| hayate: handbrake turn 60 km/h gravel | 133 deg/s peak, 82 deg @1.2s | > 60 deg/s, > 70 deg | PASS |
| hayate: handbrake turn drive-out | 83 deg total, 34 km/h @2s | > 15 km/h forward | PASS |
| hayate: wall 10° at 90 km/h | loss 6 %, yaw 20°/s, head 1° @1s, air 0.00 s, spins 0 | loss 5-10 %, yaw < 90°/s, head < 10°, air < 0.05 s, 0 spins | PASS |
| hayate: wall 25° at 90 km/h | loss 18 %, yaw 50°/s, head 1° @1s, air 0.00 s, spins 0 | loss 15-25 %, yaw < 90°/s, head < 10°, air < 0.05 s, 0 spins | PASS |
| hayate: wall 45° at 90 km/h | loss 43 %, yaw 66°/s, head 4° @1s, air 0.00 s, spins 0 | loss 30-45 %, yaw < 90°/s, head < 10°, air < 0.05 s, 0 spins | PASS |
| hayate: wall 10° at 130 km/h | loss 5 %, yaw 24°/s, head 1° @1s, air 0.00 s, spins 0 | loss 5-10 %, yaw < 90°/s, head < 10°, air < 0.05 s, 0 spins | PASS |
| hayate: wall 25° at 130 km/h | loss 19 %, yaw 61°/s, head 1° @1s, air 0.00 s, spins 0 | loss 15-25 %, yaw < 90°/s, head < 10°, air < 0.05 s, 0 spins | PASS |
| hayate: wall 45° at 130 km/h | loss 44 %, yaw 67°/s, head 2° @1s, air 0.00 s, spins 0 | loss 30-45 %, yaw < 90°/s, head < 10°, air < 0.05 s, 0 spins | PASS |
| hayate: pole (r 0.16) hit 80 km/h (quarter overlap) | rotation 48°, yaw 54°/s, air 0.00 s, 50 km/h after | rotation < 90°, air < 0.2 s, upright | PASS |
| hayate: tree trunk (r 0.3) hit 80 km/h (quarter overlap) | rotation 29°, yaw 42°/s, air 0.00 s, 53 km/h after | rotation < 90°, air < 0.2 s, upright | PASS |
| hayate: 0.4 m rock at 70 km/h | air 0.20 s, min up 0.99, rotation 1°, 105 km/h after | air < 0.3 s, no roll-over | PASS |
| hayate: hairpin with outside rail, 100 km/h | contact yes, out along the road 0.89 s later at 79 km/h, yaw 72°/s, spins 0 | exit <= 2.0 s after contact, 0 spins | PASS |
| hayate: jump airtime | 1.11 s (landing 0.95) | > 0.6 s | PASS |
| hayate: jump landing settle | 0.27 s, 0 bounces | < 1.0 s, 0 bounces | PASS |
| hayate: rest on 15° slope (up) | 0.169 cm / 5 s | < 1 cm | PASS |
| hayate: rest on 15° slope (across) | 0.022 cm / 5 s | < 1 cm | PASS |
| hayate: auto-reset when upside down | 2.87 s | 2.5-3.5 s, upright | PASS |
| hayate: reset_car onto track line | 0.00 m from line | < 1 m | PASS |
| hayate: autopilot laps (3 flying) | 69.9, 66.6, 66.6, 66.6 s | 3 laps | PASS |
| hayate: autopilot max line error | 0.77 m, 0 ticks off | wheels on road | PASS |
| hayate: autopilot crashes | 0 impacts > 0.25 | 0 | PASS |
| hayate: physics cost per tick (car) | 185 us avg, 9389 us max | < 400 us avg | PASS |
| hayate: soak 309 s (loop, jumps, wall, bumps, banking) | NaN=false vmax=40 m/s wmax=4.8 rad/s | no NaN, v<70, w<15 | PASS |
| hayate: soak events | 21 impacts (6 hard), 6 landings | signals fire | PASS |
| sakura: hanami analog lap | 113.31 s, 0 resets, 0 hard, off 0.0 s | clean | PASS |
| sakura: hanami keyboard-bot lap | 114.43 s (x1.010), 0 resets, 0 hard, slip 8° | clean, slip < 25°, <= x1.12 | PASS |
| hayate: hanami analog lap | 118.86 s, 0 resets, 0 hard, off 0.0 s | clean | PASS |
| hayate: hanami keyboard-bot lap | 119.77 s (x1.008), 0 resets, 0 hard, slip 7° | clean, slip < 25°, <= x1.12 | PASS |
| sakura: momiji analog lap | 99.53 s, 0 resets, 0 hard, off 0.0 s | clean | PASS |
| sakura: momiji keyboard-bot lap | 100.79 s (x1.013), 0 resets, 0 hard, slip 9° | clean, slip < 25°, <= x1.12 | PASS |
| hayate: momiji analog lap | 104.09 s, 0 resets, 0 hard, off 0.0 s | clean | PASS |
| hayate: momiji keyboard-bot lap | 105.28 s (x1.011), 0 resets, 0 hard, slip 7° | clean, slip < 25°, <= x1.12 | PASS |

The "max" tick cost is a scheduler outlier (other engines were running in parallel); the average
is the budget figure.

## Visual review (`tools/physics/capture.gd`)

```
timeout 300 $S --disable-crash-handler --summer-offscreen --fixed-fps 120 --path . -s res://tools/physics/capture.gd [-- only=corner,slide,jump,wheels,bumps,modes,crash]
```

`--summer-offscreen` renders with the real renderer without opening a window; drop it for a
windowed run. Writes `docs/renders/physics_*.png` (corner, gravel slide, jump in the air, wheel
close-up, bumps, the four camera modes, a chase frame of a guardrail scrape) plus frame strips in
`/tmp/sakura_capture/` (`crash_wall_sheet.png` and `crash_pole_sheet.png`: overhead 3x2 contact
sheets, 0.15 s apart from the moment of contact). `physics_placeholder_wheels.png` shows
the code-built placeholder; the other renders use the real `rally_car.glb`.

