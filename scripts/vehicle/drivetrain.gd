class_name Drivetrain
extends RefCounted
## Engine (2.0 turbo 4-cyl), turbo, clutch, 6-speed sequential gearbox with auto/manual logic,
## AWD with a torque-splitting centre diff and limited-slip axles.
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
var idle_rpm: float = 900.0
var max_rpm: float = 7800.0
## Crankshaft + flywheel inertia (kg m^2). Lower = snappier revs.
var engine_inertia: float = 0.16
## Engine friction (engine braking) = base + per_rpm * rpm, Nm at the crank.
var friction_base: float = 14.0
var friction_per_rpm: float = 0.0062
## Full-boost torque curve (rpm -> Nm). ~382 Nm at 4000, 220 kW at 6500.
var torque_curve_rpm: PackedFloat32Array = [0.0, 900.0, 1500.0, 2000.0, 2500.0, 3000.0, 3500.0, 4000.0, 4500.0, 5000.0, 5500.0, 6000.0, 6500.0, 7000.0, 7500.0, 7800.0, 8400.0]
var torque_curve_nm: PackedFloat32Array = [120.0, 165.0, 215.0, 268.0, 322.0, 360.0, 378.0, 382.0, 380.0, 372.0, 360.0, 346.0, 323.0, 292.0, 250.0, 214.0, 90.0]
## Naturally aspirated (zero boost) torque as a fraction of the full-boost curve.
var na_fraction: float = 0.6
## Turbo: boost starts building at spool_start rpm, full at spool_full; lag time constants (s).
var spool_start_rpm: float = 1800.0
var spool_full_rpm: float = 3400.0
var turbo_spool_time: float = 0.42
var turbo_release_time: float = 0.2
## Fuel cut duration when hitting the limiter (s) - short = fast "bouncing" limiter.
var limiter_cut_time: float = 0.055

# ---------------------------------------------------------------- transmission tuning
var gear_ratios: PackedFloat32Array = [3.76, 2.565, 1.963, 1.59, 1.344, 1.158]
var reverse_ratio: float = 3.4
var final_drive: float = 4.3
var efficiency: float = 0.9
var upshift_time: float = 0.12
var downshift_time: float = 0.1
## Clutch torque capacity (Nm) and launch bite: capacity ramps with engine rpm up to launch_rpm.
var clutch_max_torque: float = 720.0
var launch_rpm: float = 4000.0
var clutch_engage_time: float = 0.07
## Centre diff torque split to the front axle (0.4 = 40:60).
var front_split: float = 0.4
## Limited-slip axles: locking torque = min(stiffness * dOmega, preload + bias * |axle torque|).
var lsd_stiffness: float = 55.0
var lsd_front_preload: float = 30.0
var lsd_front_bias: float = 0.25
var lsd_rear_preload: float = 60.0
var lsd_rear_bias: float = 0.45
var center_stiffness: float = 45.0
var center_preload: float = 40.0
var center_bias: float = 0.2

# ---------------------------------------------------------------- auto gearbox tuning
var upshift_rpm_light: float = 4300.0
var upshift_rpm_full: float = 7250.0
var downshift_rpm_light: float = 1900.0
var downshift_rpm_full: float = 3700.0

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

var _omega_e: float = 900.0 * RPM_TO_RADS
var _shift_timer: float = 0.0
var _shift_cooldown: float = 0.0
var _engage: float = 1.0
var _cut_timer: float = 0.0
var _reverse_hold: float = 0.0
var _prev_thr_in: float = 0.0
var _overrun_timer: float = 0.0
var _backfire_cooldown: float = 0.0
var _split: PackedFloat32Array = [0.2, 0.2, 0.3, 0.3]


func reset() -> void:
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


func update_transmission(dt: float, v_fwd: float, thr_in: float, brk_in: float, can_auto_shift: bool,
		automatic: bool, wheel_radius: float) -> void:
	_shift_cooldown = maxf(_shift_cooldown - dt, 0.0)
	_backfire_cooldown = maxf(_backfire_cooldown - dt, 0.0)
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
	if v_fwd < 0.5:
		if gear > 1:
			_start_shift(1)
		return
	var up_rpm := lerpf(upshift_rpm_light, upshift_rpm_full, clampf(thr_in, 0.0, 1.0))
	if gear < top_gear() and here > up_rpm and brk_in < 0.1:
		_start_shift(gear + 1)
		return
	if gear <= 1:
		return
	var below := rpm_for_speed(v_fwd, gear - 1, wheel_radius)
	var down_rpm := lerpf(downshift_rpm_light, downshift_rpm_full, clampf(thr_in, 0.0, 1.0))
	var want_down := here < down_rpm and below < 6500.0
	var kickdown := thr_in > 0.85 and here < 4300.0 and below < 5800.0
	var braking := brk_in > 0.2 and below < 5000.0
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
## wheel_inertia: bare wheel inertia. rear_disconnected: handbrake releases the rear drive.
func pre_wheels(dt: float, thr_request: float, omegas: PackedFloat32Array, wheel_inertia: float,
		rear_disconnected: bool) -> void:
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
	throttle = thr
	_update_turbo(dt, thr)
	_update_backfire(dt, thr_request)

	var r := ratio(gear)
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
		var bite := maxf(launch_bite, smoothstep(1300.0, 2600.0, drivel_rpm))
		var cap := clutch_max_torque * _engage * bite
		var sum_a2 := 0.0
		for i in 4:
			sum_a2 += _split[i] * _split[i]
		var i_carrier := wheel_inertia / maxf(sum_a2, 0.01)
		var t_eq := (_omega_e - omega_in) / (dt * (1.0 / engine_inertia + r * r / i_carrier))
		t_c = clampf(t_eq, -cap, cap)
		if absf(t_eq) < cap and drivel_rpm > 1150.0 and _engage >= 1.0:
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
	var r := ratio(gear)
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


func _update_split(rear_disconnected: bool) -> void:
	var f := 1.0 if rear_disconnected else front_split
	_split[0] = f * 0.5
	_split[1] = f * 0.5
	_split[2] = (1.0 - f) * 0.5
	_split[3] = (1.0 - f) * 0.5


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
	if _split[2] > 0.0:
		var cap_c := center_preload + center_bias * driveshaft_torque
		var d_c := clampf(center_stiffness * ((omegas[0] + omegas[1]) - (omegas[2] + omegas[3])) * 0.5, -cap_c, cap_c)
		drive_torque[0] -= d_c * 0.5
		drive_torque[1] -= d_c * 0.5
		drive_torque[2] += d_c * 0.5
		drive_torque[3] += d_c * 0.5


func _update_turbo(dt: float, thr: float) -> void:
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
