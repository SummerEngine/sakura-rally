class_name Car
extends RigidBody3D
## Rally car: RigidBody3D with shape-cast suspension, combined-slip tyres, turbo AWD drivetrain
## and light driving assists. Public API is fixed by docs/CONTRACTS.md; tuning is described in
## docs/PHYSICS.md. All simulation runs in _integrate_forces (120 Hz).

signal gear_changed(new_gear: int, old_gear: int)
signal backfire
signal rev_limiter
signal impact(strength: float, point: Vector3)
signal landed(strength: float)

const WHEEL_RADIUS := 0.33
const WHEEL_WIDTH := 0.24
const WHEELBASE := 2.55
const TRACK_HALF := 0.78
const FRONT_AXLE_Z := -1.27
const REAR_AXLE_Z := 1.28
const WHEEL_REST_Y := 0.33
const CAR_AUDIO_SCRIPT := "res://scripts/vehicle/car_audio.gd"
## Lateral slip uses at least this forward speed in its denominator (m/s).
const LAT_SPEED_FLOOR := 1.2
## Longitudinal slip ratio uses at least this ground speed in its denominator (m/s).
const LONG_SPEED_FLOOR := 1.5
## Suspension casts start this far above full bump (m).
const CAST_MARGIN := 0.3
## Upper limit of spring + bump-stop force per wheel (N).
const MAX_ELASTIC_LOAD := 26000.0

# ---------------------------------------------------------------- contract: read-only state
var rpm: float = 900.0
var idle_rpm: float = 900.0
var max_rpm: float = 7800.0
var throttle: float = 0.0
var brake: float = 0.0
var handbrake: float = 0.0
var steer: float = 0.0
var gear: int = 1
var is_shifting: bool = false
var boost: float = 0.0
var speed_kmh: float = 0.0
var airborne_time: float = 0.0
var wheels: Array = []

# ---------------------------------------------------------------- contract: control inputs
var input_throttle: float = 0.0
var input_brake: float = 0.0
var input_steer: float = 0.0
var input_handbrake: bool = false
@export var controlled_by_player: bool = false
## Start-line hold during the countdown (set by Main): gearbox in neutral, brakes on, the
## throttle still revs the engine. Releasing drops the clutch in first at the held rpm.
var launch_hold: bool = false:
	set(value):
		if value != launch_hold:
			launch_hold = value
			drivetrain.set_launch_hold(value)

# ---------------------------------------------------------------- livery (read by the toon converter)
var livery_primary: Color = Color("f6f1e8")
var livery_secondary: Color = Color("e8517c")

# ---------------------------------------------------------------- tuning
@export_group("Chassis")
@export var centre_of_mass: Vector3 = Vector3(0.0, 0.44, -0.1)
@export var body_inertia: Vector3 = Vector3(1550.0, 1700.0, 480.0)

@export_group("Suspension")
## Total wheel travel (m) and how much of it is available in bump from the rest position.
@export var travel: float = 0.22
@export var bump_travel: float = 0.1
@export var spring_front: float = 30000.0
@export var spring_rear: float = 30500.0
@export var damper_bump: float = 2600.0
@export var damper_rebound: float = 5000.0
## Bump damper speed (m/s) above which the rate drops to `damper_digressive` of its value.
@export var damper_knee: float = 0.22
@export var damper_digressive: float = 0.4
@export var bump_stop_length: float = 0.03
@export var hydraulic_stop_length: float = 0.06
@export var hydraulic_stop_damping: float = 10000.0
@export var bump_stop_rate: float = 240000.0
@export var anti_roll_front: float = 16000.0
@export var anti_roll_rear: float = 12000.0

@export_group("Tyres")
@export var grip_scale: float = 1.0
@export var wheel_inertia: float = 1.25
## Fraction of CoM height at which longitudinal forces act (anti-dive / anti-squat).
@export var anti_pitch: float = 0.3
## Roll-centre heights (m) at which lateral forces act.
@export var roll_centre_front: float = 0.1
@export var roll_centre_rear: float = 0.14

@export_group("Brakes")
@export var brake_torque_front: float = 1250.0
@export var brake_torque_rear: float = 700.0
@export var handbrake_torque: float = 3200.0

@export_group("Steering")
@export var steer_lock_low_deg: float = 32.0
@export var steer_lock_high_deg: float = 8.0
## Lock = low / (1 + kmh / ref), clamped to the high-speed lock.
@export var steer_lock_speed_ref: float = 55.0
@export var ackermann: float = 0.6
## Front wheels turn towards the direction of travel by this fraction of the body slip angle.
@export var countersteer_gain: float = 0.55

@export_group("Assists")
## Yaw torque (Nm per rad/s) that resists rotation beyond what the steering asks for.
@export var yaw_assist: float = 2200.0
## Extra yaw damping at speed with the wheel centred (Nm per rad/s at 150 km/h).
@export var straight_stability: float = 1500.0
## Traction control: allowed driven slip as a multiple of the surface's peak slip ratio.
@export var tc_slip_multiple: float = 2.4
## ABS: allowed brake slip as a multiple of the surface's peak slip ratio.
@export var abs_slip_multiple: float = 1.6
@export var air_level_torque: float = 5500.0
@export var air_damping: float = 5800.0
@export var air_yaw_torque: float = 900.0
@export var auto_reset_time: float = 2.5

@export_group("Aero")
@export var drag_area: float = 0.8
@export var downforce_area: float = 0.45
@export var aero_front_share: float = 0.45

# ---------------------------------------------------------------- internals
var drivetrain: Drivetrain = Drivetrain.new()
var player_input: CarInput = CarInput.new()
## Microseconds spent in the last _integrate_forces (telemetry).
var step_usec: int = 0
var grounded_wheels: int = 0
var local_velocity: Vector3 = Vector3.ZERO

var _shape: CylinderShape3D
var _queries: Array[PhysicsShapeQueryParameters3D] = []
var _free_length: PackedFloat32Array = [0.0, 0.0, 0.0, 0.0]
var _prev_length: PackedFloat32Array = [0.0, 0.0, 0.0, 0.0]
var _abs_scale: PackedFloat32Array = [1.0, 1.0, 1.0, 1.0]
var _omegas: PackedFloat32Array = [0.0, 0.0, 0.0, 0.0]
var _hold_anchor: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
var _hold_active: bool = false
var _tc_scale: float = 1.0
var _stuck_time: float = 0.0
var _prev_vertical_speed: float = 0.0
var _impact_cooldown: float = 0.0
var _pending_reset: bool = false
var _pending_transform: Transform3D
var _driver_delta: float = 0.0


func _ready() -> void:
	mass = 1250.0
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = centre_of_mass
	inertia = body_inertia
	can_sleep = false
	contact_monitor = true
	max_contacts_reported = 8
	collision_layer = 2
	collision_mask = 1 | 4
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp = 0.02
	idle_rpm = drivetrain.idle_rpm
	max_rpm = drivetrain.max_rpm
	drivetrain.gear_changed.connect(_on_gear_changed)
	drivetrain.backfire.connect(func() -> void: backfire.emit())
	drivetrain.rev_limiter.connect(func() -> void: rev_limiter.emit())
	_build_wheels()
	_add_audio()


func _build_wheels() -> void:
	_shape = CylinderShape3D.new()
	_shape.radius = WHEEL_RADIUS
	_shape.height = WHEEL_WIDTH
	var g := float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	var front_share := (REAR_AXLE_Z - centre_of_mass.z) / WHEELBASE
	var rest_length := bump_travel
	wheels.clear()
	_queries.clear()
	var positions: Array[Vector3] = [
		Vector3(-TRACK_HALF, WHEEL_REST_Y, FRONT_AXLE_Z), Vector3(TRACK_HALF, WHEEL_REST_Y, FRONT_AXLE_Z),
		Vector3(-TRACK_HALF, WHEEL_REST_Y, REAR_AXLE_Z), Vector3(TRACK_HALF, WHEEL_REST_Y, REAR_AXLE_Z),
	]
	for i in 4:
		var w := WheelState.new()
		w.rest_position = positions[i]
		w.is_front = i < 2
		w.is_left = i % 2 == 0
		w.suspension_length = rest_length
		w.compression = 1.0 - rest_length / travel
		wheels.append(w)
		var static_load := mass * g * (front_share if w.is_front else 1.0 - front_share) * 0.5
		var k := spring_front if w.is_front else spring_rear
		_free_length[i] = rest_length + static_load / k
		_prev_length[i] = rest_length
		var q := PhysicsShapeQueryParameters3D.new()
		q.shape = _shape
		q.collision_mask = 1
		q.exclude = [get_rid()]
		_queries.append(q)


func _add_audio() -> void:
	if has_node(^"CarAudio") or not ResourceLoader.exists(CAR_AUDIO_SCRIPT):
		return
	var audio := Node3D.new()
	audio.name = "CarAudio"
	audio.set_script(load(CAR_AUDIO_SCRIPT))
	add_child(audio)


# ---------------------------------------------------------------- public API

func reset_to(xform: Transform3D) -> void:
	var t := Transform3D(xform.basis.orthonormalized(), xform.origin + xform.basis.y * 0.12)
	_pending_transform = t
	_pending_reset = true
	global_transform = t
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	_reset_state()
	reset_physics_interpolation()


func set_livery(primary: Color, secondary: Color) -> void:
	livery_primary = primary
	livery_secondary = secondary
	var visuals := get_node_or_null(^"Visuals")
	if visuals != null and visuals.has_method(&"apply_livery"):
		visuals.apply_livery(primary, secondary)


func shift_up() -> void:
	drivetrain.request_shift(1, local_velocity.dot(Vector3.FORWARD), WHEEL_RADIUS)


func shift_down() -> void:
	drivetrain.request_shift(-1, local_velocity.dot(Vector3.FORWARD), WHEEL_RADIUS)


## Steering lock (radians) at a given speed - also used by the autopilot.
func steer_lock_at(kmh: float) -> float:
	var lock := steer_lock_low_deg / (1.0 + absf(kmh) / steer_lock_speed_ref)
	return deg_to_rad(maxf(lock, steer_lock_high_deg))


## Average grip coefficient under the grounded wheels (for the autopilot / camera).
func current_grip() -> float:
	var sum := 0.0
	var n := 0
	for w: WheelState in wheels:
		if w.contact:
			sum += w.surface_mu
			n += 1
	return sum / n if n > 0 else TyreModel.get_surface(&"tarmac").mu


## Places the car at the nearest reset point of the track (or upright in place).
func reset_to_track() -> void:
	reset_to(_find_reset_transform(global_transform))


# ---------------------------------------------------------------- simulation

func _physics_process(_delta: float) -> void:
	if controlled_by_player and not launch_hold and Input.is_action_just_pressed(&"reset_car"):
		reset_to_track()


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	var t0 := Time.get_ticks_usec()
	var dt := state.step
	if _pending_reset:
		_pending_reset = false
		state.transform = _pending_transform
		state.linear_velocity = Vector3.ZERO
		state.angular_velocity = Vector3.ZERO
	var xf := state.transform
	var up := xf.basis.y
	var fwd := -xf.basis.z
	var com := xf.origin + state.center_of_mass
	var lin := state.linear_velocity
	var ang := state.angular_velocity
	local_velocity = xf.basis.inverse() * lin
	var v_fwd := lin.dot(fwd)
	speed_kmh = v_fwd * 3.6

	if controlled_by_player:
		_read_player(dt)
		if not launch_hold and Input.is_action_just_pressed(&"shift_up"):
			shift_up()
		if not launch_hold and Input.is_action_just_pressed(&"shift_down"):
			shift_down()

	_update_suspension(state, xf, dt)
	var automatic: bool = str(_setting("transmission", "auto")) != "manual"
	var reversing := drivetrain.gear == -1
	var thr_in := clampf(input_brake if reversing else input_throttle, 0.0, 1.0)
	var brk_in := clampf(input_throttle if reversing else input_brake, 0.0, 1.0)
	handbrake = move_toward(handbrake, 1.0 if input_handbrake else 0.0, dt * 16.0)
	if not launch_hold:
		drivetrain.update_transmission(dt, v_fwd, input_throttle, input_brake,
				grounded_wheels >= 2 and handbrake < 0.1, automatic, WHEEL_RADIUS)
	reversing = drivetrain.gear == -1
	thr_in = clampf(input_brake if reversing else input_throttle, 0.0, 1.0)
	brk_in = 1.0 if launch_hold else clampf(input_throttle if reversing else input_brake, 0.0, 1.0)
	brake = brk_in
	_update_steering(v_fwd)

	var speed := lin.length()
	var hold := grounded_wheels >= 3 and speed < 0.3 and (thr_in < 0.02 or launch_hold)
	if hold and not _hold_active:
		for i in 4:
			var w: WheelState = wheels[i]
			_hold_anchor[i] = w.contact_point
	_hold_active = hold
	# Creep brake at walking pace with hill-hold: settles the car instead of coasting forever and
	# balances the slope so it slows below the hold threshold even on steep hills.
	if not hold and thr_in < 0.02 and absf(v_fwd) < 3.0 and grounded_wheels >= 3:
		var slope_accel := absf(state.total_gravity.dot(fwd))
		var total_brake := 2.0 * (brake_torque_front + brake_torque_rear)
		var hill := slope_accel * mass * WHEEL_RADIUS / total_brake * 1.4
		brk_in = maxf(brk_in, clampf(0.12 + hill, 0.0, 1.0))

	for i in 4:
		var w: WheelState = wheels[i]
		_omegas[i] = w.spin_speed
	drivetrain.pre_wheels(dt, thr_in * _tc_scale, _omegas, wheel_inertia, handbrake > 0.5)
	_update_tyres(state, xf, com, lin, ang, dt, brk_in, hold)
	for i in 4:
		var w: WheelState = wheels[i]
		_omegas[i] = w.spin_speed
	drivetrain.post_wheels(_omegas)
	_update_assists(state, xf, com, lin, ang, dt, v_fwd, thr_in)
	_apply_aero(state, xf, lin, v_fwd)
	_update_air(state, xf, ang, dt)
	_read_contacts(state)
	_update_reset(state, xf, lin, dt)

	rpm = drivetrain.rpm
	gear = drivetrain.gear
	is_shifting = drivetrain.is_shifting
	boost = drivetrain.boost
	throttle = drivetrain.throttle
	step_usec = Time.get_ticks_usec() - t0


func _read_player(dt: float) -> void:
	player_input.read(dt, speed_kmh)
	input_steer = player_input.steer
	input_throttle = player_input.throttle
	input_brake = player_input.brake
	input_handbrake = player_input.handbrake


func _update_steering(v_fwd: float) -> void:
	var kmh := absf(v_fwd) * 3.6
	var lock := steer_lock_at(kmh)
	_driver_delta = clampf(input_steer, -1.0, 1.0) * lock
	var delta := _driver_delta
	# Countersteer assist: front wheels lean towards the direction of travel when the body slides.
	if v_fwd > 3.0 and grounded_wheels >= 2:
		var slip_angle := atan2(local_velocity.x, -local_velocity.z)
		var gain := countersteer_gain * smoothstep(3.0, 12.0, v_fwd) * (1.0 - 0.7 * handbrake)
		delta += clampf(slip_angle, -0.7, 0.7) * gain
	var max_total := deg_to_rad(steer_lock_low_deg + 4.0)
	delta = clampf(delta, -max_total, max_total)
	steer = clampf(delta / lock, -1.0, 1.0)
	# Ackermann: inner wheel steers more.
	var left_angle := delta
	var right_angle := delta
	if absf(delta) > 0.001:
		var radius := WHEELBASE / tan(absf(delta))
		var inner := atan(WHEELBASE / maxf(radius - TRACK_HALF, 0.5))
		var outer := atan(WHEELBASE / (radius + TRACK_HALF))
		inner = lerpf(absf(delta), inner, ackermann) * signf(delta)
		outer = lerpf(absf(delta), outer, ackermann) * signf(delta)
		if delta > 0.0:
			right_angle = inner
			left_angle = outer
		else:
			left_angle = inner
			right_angle = outer
	var fl: WheelState = wheels[0]
	var fr: WheelState = wheels[1]
	fl.steer_angle = left_angle
	fr.steer_angle = right_angle


func _update_suspension(state: PhysicsDirectBodyState3D, xf: Transform3D, dt: float) -> void:
	var space := state.get_space_state()
	var up := xf.basis.y
	var cyl_basis := xf.basis * Basis(Vector3.BACK, PI * 0.5)
	grounded_wheels = 0
	for i in 4:
		var w: WheelState = wheels[i]
		var anchor := xf * (w.rest_position + Vector3(0.0, bump_travel, 0.0))
		# The cast starts CAST_MARGIN above full bump so a bottomed-out wheel still finds the ground;
		# a negative length means the tyre is pressed past the bump stop.
		var start := anchor + up * CAST_MARGIN
		var q := _queries[i]
		q.transform = Transform3D(cyl_basis, start)
		q.motion = -up * (travel + CAST_MARGIN)
		var frac := space.cast_motion(q)
		var length := travel
		var hit := false
		if frac.size() == 2 and frac[1] < 1.0:
			length = frac[0] * (travel + CAST_MARGIN) - CAST_MARGIN
			q.transform = Transform3D(cyl_basis, start - up * (frac[1] * (travel + CAST_MARGIN)))
			q.motion = Vector3.ZERO
			var info := space.get_rest_info(q)
			if not info.is_empty():
				hit = true
				var n: Vector3 = info["normal"]
				# Edge hits can return near-horizontal normals; keep the tyre plane sensible.
				if n.dot(up) < 0.5:
					n = (n + up).normalized()
				w.contact_normal = n
				# Forces act under the wheel centre (the cylinder may touch at a tread edge).
				w.contact_point = anchor - up * length - n * WHEEL_RADIUS
				var collider := instance_from_id(int(info["collider_id"]))
				w.surface = surface_of(collider, info["point"])
		w.contact = hit
		if not hit:
			length = travel
			w.surface = &"none"
			w.contact_normal = up
			w.contact_point = anchor - up * (travel + WHEEL_RADIUS)
		w.suspension_length = length
		w.compression = clampf(1.0 - length / travel, 0.0, 1.0)
		w.offset_y = bump_travel - maxf(length, 0.0)
		if hit:
			grounded_wheels += 1
			var surf := TyreModel.get_surface(w.surface)
			w.surface_mu = surf.mu * grip_scale
			w.surface_roughness = surf.roughness
		else:
			w.surface_mu = 0.0
			w.surface_roughness = 0.0

	# Spring, damper, bump stop and anti-roll bars -> tyre load.
	for i in 4:
		var w: WheelState = wheels[i]
		var length := w.suspension_length
		var comp_speed := clampf((_prev_length[i] - length) / dt, -6.0, 6.0)
		_prev_length[i] = length
		if not w.contact:
			w.load = 0.0
			continue
		var k := spring_front if w.is_front else spring_rear
		var elastic := k * (_free_length[i] - length)
		if length < bump_stop_length:
			var pen := bump_stop_length - length
			elastic += bump_stop_rate * pen * (1.0 + minf(pen / bump_stop_length, 3.0))
		var other: WheelState = wheels[i ^ 1]
		var arb := anti_roll_front if w.is_front else anti_roll_rear
		elastic += arb * (other.suspension_length - length)
		# Clamp the elastic part before damping so a bottomed-out wheel is still damped on rebound.
		var force := minf(elastic, MAX_ELASTIC_LOAD)
		# Digressive bump (soaks up sharp hits), linear rebound (kills the energy of big landings).
		if comp_speed > 0.0:
			var s := comp_speed
			force += damper_bump * s if s < damper_knee else damper_bump * (damper_knee + (s - damper_knee) * damper_digressive)
		else:
			force += damper_rebound * comp_speed
		# Hydraulic bump stop: extra damping near full bump.
		if length < hydraulic_stop_length:
			force += hydraulic_stop_damping * comp_speed
		w.load = clampf(force, 0.0, MAX_ELASTIC_LOAD * 1.5)


func _update_tyres(state: PhysicsDirectBodyState3D, xf: Transform3D, com: Vector3, lin: Vector3,
		ang: Vector3, dt: float, brk_in: float, hold: bool) -> void:
	var up := xf.basis.y
	var fwd := -xf.basis.z
	var gravity := state.total_gravity
	var total_load := 0.0
	for w: WheelState in wheels:
		total_load += w.load
	var com_height := centre_of_mass.y

	for i in 4:
		var w: WheelState = wheels[i]
		var inertia_i := wheel_inertia + drivetrain.extra_inertia[i]
		var t_drive := drivetrain.drive_torque[i]
		var t_brake := brk_in * (brake_torque_front if w.is_front else brake_torque_rear) * _abs_scale[i]
		if not w.is_front:
			t_brake = maxf(t_brake, handbrake * handbrake_torque)
		var omega := w.spin_speed

		if not w.contact or w.load <= 0.0:
			omega += t_drive * dt / inertia_i
			var b := (t_brake + 4.0) * dt / inertia_i
			omega = 0.0 if absf(omega) <= b else omega - signf(omega) * b
			w.spin_speed = omega
			w.spin_angle = wrapf(w.spin_angle + omega * dt, 0.0, TAU)
			w.slip_long = 0.0
			w.slip_lat = 0.0
			w.slip = 0.0
			w.slide_speed = 0.0
			continue

		var surf := TyreModel.get_surface(w.surface)
		var n := w.contact_normal
		var wheel_fwd := fwd.rotated(up, -w.steer_angle)
		var t_fwd := (wheel_fwd - n * wheel_fwd.dot(n)).normalized()
		var t_lat := t_fwd.cross(n)
		var v_pt := lin + ang.cross(w.contact_point - com)
		var v_long := v_pt.dot(t_fwd)
		var v_lat := v_pt.dot(t_lat)
		var load := w.load * grip_scale
		var tyre_load := minf(w.load, 14000.0) * grip_scale
		var denom := maxf(absf(v_long), LONG_SPEED_FLOOR)
		var tan_a := v_lat / maxf(absf(v_long), LAT_SPEED_FLOOR)

		# Wheel spin, semi-implicit: the tyre reaction is linearised around the current slip so stiff
		# tyres stay stable on a light wheel; drive torque is part of the same solve; brake last.
		var slip_v := omega * WHEEL_RADIUS - v_long
		var kappa_now := slip_v / denom
		var f0 := TyreModel.combined(kappa_now, tan_a, tyre_load, surf).x
		var f1 := TyreModel.combined(kappa_now + 0.002, tan_a, tyre_load, surf).x
		var stiffness := maxf((f1 - f0) / 0.002, 0.0) / denom
		var i_eff := inertia_i + stiffness * WHEEL_RADIUS * WHEEL_RADIUS * dt
		var omega_t := omega + dt * (t_drive - WHEEL_RADIUS * f0) / i_eff
		var slip_t := omega_t * WHEEL_RADIUS - v_long
		if slip_t * slip_v < 0.0 and absf(slip_v) > 1e-4:
			# A saturated tyre must not flip the slip sign in one step: fall back to the secant.
			stiffness = maxf(stiffness, f0 / slip_v)
			i_eff = inertia_i + stiffness * WHEEL_RADIUS * WHEEL_RADIUS * dt
			omega_t = omega + dt * (t_drive - WHEEL_RADIUS * f0) / i_eff
		var brake_step := t_brake * dt / i_eff
		omega = 0.0 if absf(omega_t) <= brake_step else omega_t - signf(omega_t) * brake_step
		if hold:
			omega = 0.0

		var kappa := (omega * WHEEL_RADIUS - v_long) / denom
		var f := TyreModel.combined(kappa, tan_a, tyre_load, surf)
		var fx := f.x
		var fy := f.y
		var peak := TyreModel.peak_force(tyre_load, surf)
		var share := w.load / maxf(total_load, 1.0)
		var m_eff := mass * share * 0.8
		var g_long := mass * share * gravity.dot(t_fwd)
		var g_lat := mass * share * gravity.dot(t_lat)
		# Low-speed stick: tyres cannot creep sideways, and a held car cannot creep at all.
		var contact_speed := v_pt.length()
		var stick_w := 1.0 - smoothstep(0.4, 2.5, contact_speed)
		if stick_w > 0.0:
			var fy_stick := clampf(-m_eff * v_lat / dt - g_lat, -peak, peak)
			fy = lerpf(fy, fy_stick, stick_w)
		if hold:
			var drift := (w.contact_point - _hold_anchor[i])
			var fx_stick := -m_eff * v_long / dt - g_long - drift.dot(t_fwd) * 20000.0
			fx = clampf(fx_stick, -peak, peak)
			fy -= drift.dot(t_lat) * 20000.0 * stick_w
		else:
			# Rolling resistance and soft-ground drag (sand, grass).
			fx -= surf.rolling * load * clampf(v_long / 0.5, -1.0, 1.0)
			fx -= clampf(surf.drag * load * v_long, -0.35 * load, 0.35 * load)
			fy -= clampf(surf.drag * load * v_lat, -0.35 * load, 0.35 * load)
		var total := sqrt(fx * fx + fy * fy)
		var cap := maxf(peak, surf.drag * load * 30.0)
		if total > cap:
			fx *= cap / total
			fy *= cap / total

		# Apply: longitudinal force partly raised (anti-pitch), lateral at the roll centre.
		var p_long := w.contact_point + up * (anti_pitch * com_height)
		var rc := roll_centre_front if w.is_front else roll_centre_rear
		var p_lat := w.contact_point + up * rc
		var origin := xf.origin
		state.apply_force(up * w.load, w.contact_point - origin)
		state.apply_force(t_fwd * fx, p_long - origin)
		state.apply_force(t_lat * fy, p_lat - origin)

		w.spin_speed = omega
		w.spin_angle = wrapf(w.spin_angle + omega * dt, 0.0, TAU)
		w.slip_long = kappa
		w.slip_lat = atan(tan_a)
		w.slip = f.z
		w.slide_speed = Vector2(omega * WHEEL_RADIUS - v_long, v_lat).length()

		# ABS modulation per wheel.
		var abs_limit := surf.long_peak * abs_slip_multiple
		if brk_in > 0.05 and kappa < -abs_limit and absf(v_long) > 3.0:
			_abs_scale[i] = maxf(_abs_scale[i] - dt * 10.0, 0.3)
		else:
			_abs_scale[i] = minf(_abs_scale[i] + dt * 5.0, 1.0)

	# Traction control from the worst driven wheel.
	var worst := 0.0
	for w: WheelState in wheels:
		if w.contact and w.slip_long > 0.0:
			var surf := TyreModel.get_surface(w.surface)
			worst = maxf(worst, w.slip_long / (surf.long_peak * tc_slip_multiple))
	if worst > 1.0:
		_tc_scale = maxf(_tc_scale - dt * 4.0 * (worst - 0.8), 0.35)
	else:
		_tc_scale = minf(_tc_scale + dt * 2.5, 1.0)


func _update_assists(state: PhysicsDirectBodyState3D, xf: Transform3D, _com: Vector3, _lin: Vector3,
		ang: Vector3, _dt: float, v_fwd: float, _thr: float) -> void:
	if grounded_wheels < 2 or v_fwd < 4.0:
		return
	var up := xf.basis.y
	var yaw_rate := ang.dot(up)
	var target := -v_fwd * tan(_driver_delta) / WHEELBASE
	var ground := float(grounded_wheels) / 4.0
	var torque := 0.0
	if absf(yaw_rate) > absf(target) and signf(yaw_rate - target) == signf(yaw_rate):
		torque -= (yaw_rate - target) * yaw_assist * (1.0 - 0.85 * handbrake)
	var centred := 1.0 - clampf(absf(input_steer) * 3.0, 0.0, 1.0)
	torque -= yaw_rate * straight_stability * centred * clampf(v_fwd / 41.7, 0.0, 1.2) * (1.0 - handbrake)
	torque = clampf(torque, -6000.0, 6000.0) * ground
	state.apply_torque(up * torque)


func _apply_aero(state: PhysicsDirectBodyState3D, xf: Transform3D, lin: Vector3, v_fwd: float) -> void:
	var speed := lin.length()
	if speed < 0.5:
		return
	state.apply_central_force(-lin * (0.5 * 1.225 * drag_area * speed))
	if grounded_wheels == 0:
		return
	var down := -xf.basis.y * (0.5 * 1.225 * downforce_area * v_fwd * v_fwd)
	var origin := xf.origin
	state.apply_force(down * aero_front_share, xf * Vector3(0.0, 0.3, FRONT_AXLE_Z) - origin)
	state.apply_force(down * (1.0 - aero_front_share), xf * Vector3(0.0, 0.3, REAR_AXLE_Z) - origin)


func _update_air(state: PhysicsDirectBodyState3D, xf: Transform3D, ang: Vector3, dt: float) -> void:
	var up := xf.basis.y
	var vertical_speed := state.linear_velocity.y
	if grounded_wheels == 0:
		airborne_time += dt
		var w := smoothstep(0.05, 0.35, airborne_time)
		var axis := up.cross(Vector3.UP)
		var spin := ang - up * ang.dot(up)
		var torque := (axis * air_level_torque - spin * air_damping) * w
		torque += up * (-input_steer * air_yaw_torque * w)
		state.apply_torque(torque)
	else:
		if airborne_time > 0.25 and grounded_wheels >= 2:
			landed.emit(clampf(-_prev_vertical_speed / 7.0, 0.0, 1.5))
		airborne_time = 0.0
	_prev_vertical_speed = vertical_speed


func _read_contacts(state: PhysicsDirectBodyState3D) -> void:
	_impact_cooldown = maxf(_impact_cooldown - state.step, 0.0)
	var count := state.get_contact_count()
	if count == 0:
		return
	var total := 0.0
	var point := Vector3.ZERO
	for c in count:
		var imp := state.get_contact_impulse(c).length()
		if imp > total:
			total = imp
			point = state.get_contact_collider_position(c)
	var strength := total / (mass * 5.0)
	if strength > 0.06 and _impact_cooldown <= 0.0:
		_impact_cooldown = 0.15
		impact.emit(minf(strength, 2.0), point)


func _update_reset(state: PhysicsDirectBodyState3D, xf: Transform3D, lin: Vector3, dt: float) -> void:
	var upside_down := xf.basis.y.y < 0.3
	var speed := lin.length()
	var tilted := xf.basis.y.y < 0.75 or grounded_wheels < 3
	var stuck := (upside_down and speed < 3.0) or (grounded_wheels == 0 and speed < 0.4 and airborne_time > 1.0) \
			or (tilted and speed < 0.5 and (input_throttle > 0.3 or input_brake > 0.3))
	_stuck_time = _stuck_time + dt if stuck else 0.0
	if _stuck_time > auto_reset_time:
		_stuck_time = 0.0
		var t := _find_reset_transform(xf)
		t = Transform3D(t.basis.orthonormalized(), t.origin + t.basis.y * 0.12)
		state.transform = t
		state.linear_velocity = Vector3.ZERO
		state.angular_velocity = Vector3.ZERO
		_reset_state()
		reset_physics_interpolation.call_deferred()
		_post_notice.call_deferred("Car reset")


func _find_reset_transform(from: Transform3D) -> Transform3D:
	for node in get_tree().get_nodes_in_group(&"track"):
		if node.has_method(&"nearest_reset_transform"):
			var t: Transform3D = node.nearest_reset_transform(from.origin)
			return t
	var fwd := -from.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.01:
		fwd = Vector3.FORWARD
	return Transform3D(Basis.looking_at(fwd.normalized(), Vector3.UP), from.origin + Vector3.UP * 0.5)


func _reset_state() -> void:
	_stuck_time = 0.0
	airborne_time = 0.0
	_tc_scale = 1.0
	_hold_active = false
	player_input.reset()
	drivetrain.reset()
	if launch_hold:
		drivetrain.set_launch_hold(true)
	for i in 4:
		var w: WheelState = wheels[i]
		w.spin_speed = 0.0
		w.slip = 0.0
		w.slip_long = 0.0
		w.slip_lat = 0.0
		w.slide_speed = 0.0
		_abs_scale[i] = 1.0
		_prev_length[i] = w.suspension_length


## Surface lookup shared with the autopilot: collider.surface_at(point), else its "surface" meta.
static func surface_of(collider: Object, point: Vector3) -> StringName:
	if collider == null:
		return &"tarmac"
	if collider.has_method(&"surface_at"):
		return StringName(collider.surface_at(point))
	if collider.has_meta(&"surface"):
		return StringName(collider.get_meta(&"surface"))
	return &"tarmac"


func _on_gear_changed(new_gear: int, old_gear: int) -> void:
	gear = new_gear
	gear_changed.emit(new_gear, old_gear)


func _setting(key: String, fallback: Variant) -> Variant:
	var game := get_node_or_null(^"/root/Game")
	if game == null:
		return fallback
	return game.get_setting(key)


func _post_notice(text: String) -> void:
	var game := get_node_or_null(^"/root/Game")
	if game != null:
		game.post_notice(text)
