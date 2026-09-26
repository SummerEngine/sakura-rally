class_name Drivetrain
extends Resource
## Engine (turbo or naturally aspirated), clutch, sequential gearbox with auto/manual logic,
## AWD or RWD with a torque-splitting centre coupling and limited-slip axles.
## The defaults are the Sakura (2.0 turbo, 6 speeds, AWD 40:60). A car scene can carry its own
## Drivetrain resource with overrides (`Car.drivetrain`); the car duplicates it on _ready, so the
## exported tuning is shared and the runtime state below is per car.
##
## Per physics tick the car calls, in order:
##   update_transmission()  - auto/manual gear selection, reverse, shift timing
##   pre_wheels()           - engine + clutch; fills `drive_torque` and `extra_inertia` per wheel
##   (car integrates the wheels with its tyre model)
##   post_wheels()          - rigid clutch: engine speed follows the wheels
## Wheel order everywhere: FL, FR, RL, RR.

signal gear_changed(new_gear: int, old_gear: int)
signal backfire
signal rev_limiter

const RPM_TO_RADS := TAU / 60.0
const RADS_TO_RPM := 60.0 / TAU

# ---------------------------------------------------------------- engine tuning
@export var idle_rpm: float = 900.0
@export var max_rpm: float = 7800.0
## Crankshaft + flywheel inertia (kg m^2). Lower = snappier revs.
@export var engine_inertia: float = 0.16
## Engine friction (engine braking) = base + per_rpm * rpm, Nm at the crank.
@export var friction_base: float = 14.0
@export var friction_per_rpm: float = 0.0062
## Full-boost torque curve (rpm -> Nm). ~490 Nm at 4000, 283 kW at 6500, a fat low end.
@export var torque_curve_rpm: PackedFloat32Array = [0.0, 900.0, 1500.0, 2000.0, 2500.0, 3000.0, 3500.0, 4000.0, 4500.0, 5000.0, 5500.0, 6000.0, 6500.0, 7000.0, 7500.0, 7800.0, 8400.0]
@export var torque_curve_nm: PackedFloat32Array = [170.0, 225.0, 300.0, 360.0, 420.0, 462.0, 482.0, 490.0, 488.0, 478.0, 462.0, 444.0, 416.0, 376.0, 322.0, 272.0, 110.0]
## false = naturally aspirated: the curve is the engine's torque and `boost` stays 0.
@export var turbo: bool = true
## Zero-boost torque as a fraction of the full-boost curve (turbo engines).
@export var na_fraction: float = 0.75
## Turbo: boost starts building at spool_start rpm, full at spool_full; lag time constants (s).
@export var spool_start_rpm: float = 1500.0
@export var spool_full_rpm: float = 3000.0
@export var turbo_spool_time: float = 0.25
@export var turbo_release_time: float = 0.2
## Fuel cut duration when hitting the limiter (s) - short = fast "bouncing" limiter.
@export var limiter_cut_time: float = 0.055

# ---------------------------------------------------------------- transmission tuning
@export var gear_ratios: PackedFloat32Array = [3.76, 2.565, 1.963, 1.59, 1.344, 1.158]
@export var reverse_ratio: float = 3.4
@export var final_drive: float = 4.3
@export var efficiency: float = 0.9
@export var upshift_time: float = 0.09
@export var downshift_time: float = 0.1
## Clutch torque capacity (Nm) and launch bite: capacity ramps with engine rpm up to launch_rpm.
@export var clutch_max_torque: float = 900.0
@export var launch_rpm: float = 4500.0
@export var clutch_engage_time: float = 0.05
## Launch control: engine speed held in neutral during the countdown.
@export var launch_hold_rpm: float = 4600.0
## Centre diff torque split to the front axle (0.4 = 40:60, 0 = rear-wheel drive).
@export var front_split: float = 0.4
## Limited-slip axles: locking torque = min(stiffness * dOmega, preload + bias * |axle torque|).
@export var lsd_stiffness: float = 55.0
@export var lsd_front_preload: float = 30.0
@export var lsd_front_bias: float = 0.25
@export var lsd_rear_preload: float = 60.0
@export var lsd_rear_bias: float = 0.45
@export var center_stiffness: float = 45.0
@export var center_preload: float = 40.0
@export var center_bias: float = 0.2

# ---------------------------------------------------------------- auto gearbox tuning
@export var upshift_rpm_light: float = 4300.0
@export var upshift_rpm_full: float = 7250.0
@export var downshift_rpm_light: float = 1900.0
@export var downshift_rpm_full: float = 3700.0
## Light-throttle upshifts (below `upshift_rpm_full`) wait until the driver has cruised this
## long (s): no throttle above 0.8 and no brake. Lifting before a corner, braking into it and
## feeding the throttle back in on the way out all keep the gear instead of short-shifting
## and kicking down again a moment later.
@export var cruise_time: float = 1.5
## No light-throttle upshifts while the car decelerates harder than this (m/s^2), e.g. losing
## speed uphill on part throttle.
@export var upshift_min_accel: float = -0.8
## Low-rpm and kickdown downshifts only into a gear that stays below this rpm, leaving room to
## pull before the next upshift (no 1st-gear blip while rolling at 40+ km/h).
@export var downshift_target_max: float = 5250.0
## Full-throttle kickdown below this rpm; downshifts under braking into a gear below
## `brake_downshift_rpm`.
@export var kickdown_rpm: float = 4300.0
@export var brake_downshift_rpm: float = 5000.0

# ---------------------------------------------------------------- state
var rpm: float = 900.0
var gear: int = 1
var is_shifting: bool = false
var boost: float = 0.0
## Engine throttle actually applied (after limiter / shift cut), 0..1.
var throttle: float = 0.0
var clutch_locked: bool = false
var drive_torque: PackedFloat32Array = [0.0, 0.0, 0.0, 0.0]
var extra_inertia: PackedFloat32Array = [0.0, 0.0, 0.0, 0.0]
## Engine torque output this tick (Nm, after friction).
var engine_torque: float = 0.0
## Set by the car every tick: its traction-control scale (1 = no intervention). Besides the
## throttle cut it limits a slipping clutch, so a launch cannot keep feeding flywheel energy into
## spinning tyres.
var traction_scale: float = 1.0
## Set by the car every tick: the driver is holding a slide (drift intent). Road speed along the
## car's nose then says nothing about the gear it wants (at 40 deg of slip it reads 25 % low and
## the driven wheels spin), so the box holds the gear and only shifts on driveline speed (engine
## rpm with the clutch locked) against the usual up- and downshift points.
var sliding: bool = false

var _omega_e: float = 900.0 * RPM_TO_RADS
var _shift_timer: float = 0.0
var _shift_cooldown: float = 0.0
var _engage: float = 1.0
var _cut_timer: float = 0.0
var _reverse_hold: float = 0.0
var _launch_hold: bool = false
var _prev_thr_in: float = 0.0
var _overrun_timer: float = 0.0
var _backfire_cooldown: float = 0.0
var _cruise_t: float = 0.0 ## time since the last throttle stab (> 0.8) or brake
var _v_prev: float = NAN ## NAN = seed from the next tick (after reset / launch hold)
var _accel: float = 0.0 ## smoothed forward acceleration (m/s^2)
var _split: PackedFloat32Array = [0.2, 0.2, 0.3, 0.3]


func reset() -> void:
	_launch_hold = false
	var old := gear
	rpm = idle_rpm
	_omega_e = idle_rpm * RPM_TO_RADS
	gear = 1
	is_shifting = false
	boost = 0.0
	throttle = 0.0
	clutch_locked = false
	_shift_timer = 0.0
	_shift_cooldown = 0.0
	_engage = 1.0
	_cut_timer = 0.0
	_reverse_hold = 0.0
	_overrun_timer = 0.0
	_cruise_t = 0.0
	_accel = 0.0
	_v_prev = NAN
	engine_torque = 0.0
	if old != gear:
		gear_changed.emit(gear, old)


func ratio(g: int) -> float:
	if g == 0:
		return 0.0
	if g < 0:
		return -reverse_ratio * final_drive
	return gear_ratios[clampi(g, 1, gear_ratios.size()) - 1] * final_drive


func top_gear() -> int:
	return gear_ratios.size()


## Engine rpm the given gear would have at forward speed v (m/s) on wheels of radius r.
func rpm_for_speed(v: float, g: int, r: float) -> float:
	return absf(v / r * ratio(g)) * RADS_TO_RPM


## Full-throttle torque available at rpm with the current boost (Nm, before friction).
func available_torque(at_rpm: float) -> float:
	var full := _curve(at_rpm)
	if not turbo:
		return full
	var na := full * na_fraction
	return na + boost * (full - na)


func friction_torque(at_rpm: float) -> float:
	return friction_base + friction_per_rpm * at_rpm


# ---------------------------------------------------------------- transmission logic

## Manual request: +1 up, -1 down. Sequential R-N-1..6. Refuses over-revving downshifts.
func request_shift(direction: int, v_fwd: float, wheel_radius: float) -> void:
	if is_shifting:
		return
	var target := clampi(gear + direction, -1, top_gear())
	if target == gear:
		return
	if target == -1 and v_fwd > 1.5:
		return
	if gear == -1 and target >= 0 and v_fwd < -1.5:
		return
	if target > 0 and direction < 0 and rpm_for_speed(v_fwd, target, wheel_radius) > max_rpm + 200.0:
		return
	_start_shift(target)


## Countdown hold: neutral with the clutch open and launch control holding the revs at
## launch_hold_rpm. Releasing puts first gear in with the clutch slipping, and the launch
## bite follows the held rpm.
func set_launch_hold(on: bool) -> void:
	var old := gear
	_launch_hold = on
	gear = 0 if on else 1
	is_shifting = false
	clutch_locked = false
	_engage = 0.0
	_shift_timer = 0.0
	_reverse_hold = 0.0
	_cruise_t = 0.0
	_v_prev = NAN
	_accel = 0.0
	if old != gear:
		gear_changed.emit(gear, old)


func update_transmission(dt: float, v_fwd: float, thr_in: float, brk_in: float, can_auto_shift: bool,
		automatic: bool, wheel_radius: float) -> void:
	_shift_cooldown = maxf(_shift_cooldown - dt, 0.0)
	_backfire_cooldown = maxf(_backfire_cooldown - dt, 0.0)
	_cruise_t = 0.0 if thr_in > 0.8 or brk_in > 0.1 else _cruise_t + dt
	# Smoothed forward acceleration, updated every tick (also while shifting). The first tick
	# after reset() only seeds the previous speed.
	if is_nan(_v_prev):
		_v_prev = v_fwd
	_accel += ((v_fwd - _v_prev) / maxf(dt, 1e-4) - _accel) * (1.0 - exp(-dt / 0.25))
	_v_prev = v_fwd
	if is_shifting:
		return
	# Reverse by holding the brake at a standstill (both modes); throttle drives off in 1st.
	if gear >= 0 and absf(v_fwd) < 0.8 and brk_in > 0.5 and thr_in < 0.1:
		_reverse_hold += dt
		if _reverse_hold > 0.3:
			_reverse_hold = 0.0
			_start_shift(-1)
			return
	else:
		_reverse_hold = 0.0
	if gear == -1 and thr_in > 0.3 and v_fwd > -1.0:
		_start_shift(1)
		return
	if not automatic:
		return
	if gear == 0:
		_start_shift(1)
		return
	if gear < 1 or not can_auto_shift or _shift_cooldown > 0.0:
		return
	var here := rpm_for_speed(v_fwd, gear, wheel_radius)
	# With the clutch locked the engine's own speed counts too: on loose ground the driven wheels
	# spin up and the engine reaches the limiter before road speed says so.
	var up_here := maxf(here, rpm) if clutch_locked else here
	if v_fwd < 0.5:
		if gear > 1:
			_start_shift(1)
		return
	if sliding:
		if clutch_locked and gear < top_gear() and rpm > upshift_rpm_full:
			_start_shift(gear + 1)
		elif clutch_locked and gear > 1 and rpm < lerpf(downshift_rpm_light, downshift_rpm_full, clampf(thr_in, 0.0, 1.0)) \
				and rpm_for_speed(v_fwd, gear - 1, wheel_radius) < downshift_target_max:
			_start_shift(gear - 1)
		return
	var up_rpm := lerpf(upshift_rpm_light, upshift_rpm_full, clampf(thr_in, 0.0, 1.0))
	# Near the full-throttle point the box always upshifts (no bouncing off the limiter);
	# below it only while cruising and not slowing down.
	var may_upshift := up_here > upshift_rpm_full or (_cruise_t > cruise_time and _accel > upshift_min_accel)
	if gear < top_gear() and up_here > up_rpm and brk_in < 0.1 and may_upshift:
		_start_shift(gear + 1)
		return
	if gear <= 1:
		return
	var below := rpm_for_speed(v_fwd, gear - 1, wheel_radius)
	var down_rpm := lerpf(downshift_rpm_light, downshift_rpm_full, clampf(thr_in, 0.0, 1.0))
	var want_down := here < down_rpm and below < downshift_target_max
	var kickdown := thr_in > 0.85 and here < kickdown_rpm and below < downshift_target_max
	var braking := brk_in > 0.2 and below < brake_downshift_rpm
	if want_down or kickdown or braking:
		_start_shift(gear - 1)


func _start_shift(target: int) -> void:
	var old := gear
	var upshift := target > old and old > 0
	gear = target
	is_shifting = true
	clutch_locked = false
	_engage = 0.0
	_shift_timer = upshift_time if upshift else downshift_time
	_shift_cooldown = 0.55 if upshift else 0.35
	if upshift and _prev_thr_in > 0.6 and rpm > 5000.0:
		_try_backfire(0.5)
	gear_changed.emit(target, old)


# ---------------------------------------------------------------- engine + clutch

## thr_request: throttle after driver/assists (0..1). omegas: wheel speeds (rad/s).
## wheel_inertias: per wheel, the bare wheel inertia plus what the gripping tyre adds (the car
## it pushes, from the tyre linearisation); a slipping clutch feeds the car through it.
## rear_disconnected: handbrake releases the rear drive.
func pre_wheels(dt: float, thr_request: float, omegas: PackedFloat32Array,
		wheel_inertias: PackedFloat32Array, rear_disconnected: bool) -> void:
	_update_split(rear_disconnected)
	# Shift and limiter fuel cut.
	var thr := clampf(thr_request, 0.0, 1.0)
	if _cut_timer > 0.0:
		_cut_timer -= dt
		thr = 0.0
	elif rpm >= max_rpm and not is_shifting:
		_cut_timer = limiter_cut_time
		thr = 0.0
		rev_limiter.emit()
		_try_backfire(0.12)
	if is_shifting and gear != -1:
		thr = 0.0
	# Top gear: a soft governor instead of bouncing off the limiter at top speed.
	if gear == top_gear():
		thr *= clampf((max_rpm - 60.0 - rpm) / 300.0, 0.0, 1.0)
	elif _launch_hold:
		thr *= clampf((launch_hold_rpm - rpm) / 350.0, 0.0, 1.0)
	throttle = thr
	_update_turbo(dt, thr)
	_update_backfire(dt, thr_request)

	# RWD on the handbrake: the driver has the clutch in (no drive axle left to feed).
	var r := ratio(gear) if _drive_connected() else 0.0
	var torque := thr * (available_torque(rpm) + friction_torque(rpm)) - friction_torque(rpm)
	# Idle governor keeps the engine alive.
	torque += clampf((idle_rpm - rpm) * 0.9, 0.0, 90.0)
	engine_torque = torque

	for i in 4:
		drive_torque[i] = 0.0
		extra_inertia[i] = 0.0

	var omega_c := _carrier_speed(omegas)
	if is_shifting:
		_shift_timer -= dt
		# Rev-matching sequential box: engine swings to the new gear's speed while the clutch is open.
		var target_e := clampf(absf(omega_c * r), idle_rpm * RPM_TO_RADS, max_rpm * RPM_TO_RADS)
		_omega_e += (target_e - _omega_e) * (1.0 - exp(-dt / 0.035))
		if _shift_timer <= 0.0:
			is_shifting = false
		rpm = _omega_e * RADS_TO_RPM
		_apply_lsd(omegas, 0.0)
		return

	if clutch_locked and r != 0.0:
		var axle := torque * r * (efficiency if torque > 0.0 else 1.0)
		for i in 4:
			drive_torque[i] = _split[i] * axle
			extra_inertia[i] = _split[i] * engine_inertia * r * r
		_apply_lsd(omegas, absf(axle))
		return

	# Slipping clutch (launch, after a shift, or neutral).
	_engage = minf(_engage + dt / clutch_engage_time, 1.0)
	var t_c := 0.0
	var omega_in := omega_c * r
	if r != 0.0:
		var drivel_rpm := absf(omega_in) * RADS_TO_RPM
		var launch_bite := pow(clampf((rpm - 1500.0) / (launch_rpm - 1500.0), 0.0, 1.0), 2.0)
		# Pulling away gently the clutch also bites with driveline speed; on a real launch only the
		# engine speed sets the bite, so a wheelspin spike cannot dump the flywheel into the tyres.
		var bite := launch_bite if throttle >= 0.3 else maxf(launch_bite, smoothstep(1300.0, 2600.0, drivel_rpm))
		var cap := clutch_max_torque * _engage * bite * traction_scale
		var inv_carrier := 0.0
		for i in 4:
			inv_carrier += _split[i] * _split[i] / maxf(wheel_inertias[i], 0.01)
		var i_carrier := 1.0 / maxf(inv_carrier, 1e-4)
		var t_eq := (_omega_e - omega_in) / (dt * (1.0 / engine_inertia + r * r / i_carrier))
		t_c = clampf(t_eq, -cap, cap)
		# On a launch the clutch keeps slipping until the driveline is well into the power band;
		# locking on a wheelspin spike would drag the engine down to where it bogs.
		var lock_rpm := 1150.0 if throttle < 0.3 else launch_rpm * 0.6
		if absf(t_eq) < cap and drivel_rpm > lock_rpm and _engage >= 1.0:
			clutch_locked = true
		var axle := t_c * r * efficiency
		for i in 4:
			drive_torque[i] = _split[i] * axle
		_apply_lsd(omegas, absf(axle))
	_omega_e = maxf(_omega_e + (torque - t_c) * dt / engine_inertia, 300.0 * RPM_TO_RADS)
	rpm = _omega_e * RADS_TO_RPM


func post_wheels(omegas: PackedFloat32Array) -> void:
	if not clutch_locked or is_shifting:
		return
	var r := ratio(gear) if _drive_connected() else 0.0
	if r == 0.0:
		clutch_locked = false
		return
	_omega_e = _carrier_speed(omegas) * r
	if _omega_e * RADS_TO_RPM < 1000.0:
		clutch_locked = false
		_omega_e = maxf(absf(_omega_e), idle_rpm * RPM_TO_RADS)
	rpm = absf(_omega_e) * RADS_TO_RPM


func _carrier_speed(omegas: PackedFloat32Array) -> float:
	var w := 0.0
	for i in 4:
		w += _split[i] * omegas[i]
	return w


func _drive_connected() -> bool:
	return _split[0] + _split[2] > 0.0


func _update_split(rear_disconnected: bool) -> void:
	var f := front_split
	if rear_disconnected:
		f = 1.0 if front_split > 0.0 else 0.0
	var rear := 0.0 if rear_disconnected else 1.0 - f
	_split[0] = f * 0.5
	_split[1] = f * 0.5
	_split[2] = rear * 0.5
	_split[3] = rear * 0.5


## Limited-slip transfer from the faster to the slower wheel of each axle, and between axles.
func _apply_lsd(omegas: PackedFloat32Array, driveshaft_torque: float) -> void:
	var t_front := driveshaft_torque * (_split[0] + _split[1])
	var t_rear := driveshaft_torque * (_split[2] + _split[3])
	var cap_f := lsd_front_preload + lsd_front_bias * t_front
	var d_f := clampf(lsd_stiffness * (omegas[0] - omegas[1]), -cap_f, cap_f)
	drive_torque[0] -= d_f
	drive_torque[1] += d_f
	var cap_r := lsd_rear_preload + lsd_rear_bias * t_rear
	var d_r := clampf(lsd_stiffness * (omegas[2] - omegas[3]), -cap_r, cap_r)
	drive_torque[2] -= d_r
	drive_torque[3] += d_r
	if _split[0] > 0.0 and _split[2] > 0.0:
		var cap_c := center_preload + center_bias * driveshaft_torque
		var d_c := clampf(center_stiffness * ((omegas[0] + omegas[1]) - (omegas[2] + omegas[3])) * 0.5, -cap_c, cap_c)
		drive_torque[0] -= d_c * 0.5
		drive_torque[1] -= d_c * 0.5
		drive_torque[2] += d_c * 0.5
		drive_torque[3] += d_c * 0.5


func _update_turbo(dt: float, thr: float) -> void:
	if not turbo:
		boost = 0.0
		return
	var spool := clampf((rpm - spool_start_rpm) / (spool_full_rpm - spool_start_rpm), 0.0, 1.0)
	spool = spool * spool * (3.0 - 2.0 * spool)
	var target := thr * spool
	var tau := turbo_spool_time if target > boost else turbo_release_time
	boost += (target - boost) * (1.0 - exp(-dt / tau))


func _update_backfire(dt: float, thr_in: float) -> void:
	if _prev_thr_in > 0.6 and thr_in < 0.15 and rpm > 4300.0:
		_try_backfire(0.6)
		_overrun_timer = 1.0
	if _overrun_timer > 0.0:
		_overrun_timer -= dt
		if thr_in < 0.1 and rpm > 3500.0 and randf() < 3.0 * dt:
			_try_backfire(1.0)
	_prev_thr_in = thr_in


func _try_backfire(chance: float) -> void:
	if _backfire_cooldown > 0.0 or randf() > chance:
		return
	_backfire_cooldown = 0.09
	backfire.emit()


func _curve(at_rpm: float) -> float:
	var n := torque_curve_rpm.size()
	if at_rpm <= torque_curve_rpm[0]:
		return torque_curve_nm[0]
	for i in range(1, n):
		if at_rpm <= torque_curve_rpm[i]:
			var t := (at_rpm - torque_curve_rpm[i - 1]) / (torque_curve_rpm[i] - torque_curve_rpm[i - 1])
			return lerpf(torque_curve_nm[i - 1], torque_curve_nm[i], t)
	return maxf(torque_curve_nm[n - 1] - (at_rpm - torque_curve_rpm[n - 1]) * 0.2, 0.0)
