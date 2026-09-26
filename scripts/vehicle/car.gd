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
## Brake torque (Nm, all four wheels) that settles a coasting car at walking pace.
const CREEP_BRAKE_TORQUE := 470.0
## Below this wheel speed (m/s) the ABS lets the wheels lock (final stop).
const ABS_MIN_SPEED := 3.0

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
## Enough torque to lock any surface: the ABS below decides how much reaches the road.
@export var brake_torque_front: float = 2800.0
@export var brake_torque_rear: float = 2000.0
@export var handbrake_torque: float = 3200.0
## ABS holds each braked wheel at this fraction of the surface's peak slip ratio: near the
## peak in a straight line, lower at full lock so the fronts keep lateral grip (trail braking).
@export var abs_slip_ratio: float = 0.95
@export var abs_slip_ratio_steer: float = 0.6
## Arcade braking grip: the longitudinal tyre force is multiplied by this while braking.
@export var brake_grip_bonus: float = 1.0

@export_group("Steering")
## Lock at walking pace (deg). At speed the lock is what the front tyres can use on the surface
## under them: the kinematic angle for the grip-limited radius plus the surface's peak slip angle.
@export var steer_lock_deg: float = 32.0
## Grip fraction assumed for the kinematic part of the lock.
@export var steer_grip_margin: float = 1.0
## Multiple of the surface's peak slip angle added to the kinematic angle.
@export var steer_slip_factor: float = 1.3
@export var ackermann: float = 0.6
## Front wheels turn towards the direction of travel by this fraction of the body slip angle
## beyond `countersteer_deadzone_deg`, so a slide is caught by centring the wheel.
@export var countersteer_gain: float = 0.55
@export var countersteer_deadzone_deg: float = 4.0

@export_group("Assists")
## Yaw-rate control. The steering asks for input * the grip-limited yaw rate
## (`yaw_grip` * mu * g / v, capped by the kinematic rate at full lock); torque (Nm per rad/s of
## error) helps the car reach it on turn-in and stops it rotating past it.
@export var yaw_grip: float = 0.95
@export var yaw_turn_in_gain: float = 3000.0
@export var yaw_damping_gain: float = 5000.0
@export var yaw_torque_max: float = 9000.0
## The assists read the steering through a short memory: it follows a larger input at once and
## decays with this time constant (s), so tapping a key through a long corner keeps asking for the
## corner instead of damping the car straight between taps. An opposite input resets it.
@export var steer_memory_time: float = 0.25
## Body-slip governor. Allowed slip without drift intent, as multiples of the rear surface's peak
## slip angle at low (<= 40 km/h) and high (>= 150 km/h) speed; with the wheel centred it
## shrinks to `slip_allow_centred_deg`.
@export var slip_allow_low: float = 1.4
@export var slip_allow_high: float = 0.7
@export var slip_allow_centred_deg: float = 2.0
## Governor torque per rad beyond the allowance, damping of slip growth (Nm per rad/s), limit.
@export var slip_governor_gain: float = 30000.0
@export var slip_governor_damping: float = 6000.0
@export var slip_governor_max: float = 16000.0
## Drift intent (0..1): the handbrake raises it, lifting or braking into a turn on a loose surface
## raises it to `lift_turn_intent`, throttle holds it, centring the wheel ends it
## (`drift_exit_rate` per second). With full intent the allowed slip is `drift_slip_*_deg`
## (at <= 70 and >= 160 km/h); on the handbrake itself up to `handbrake_slip_deg`.
@export var lift_turn_intent: float = 0.5
@export var drift_slip_low_deg: float = 45.0
@export var drift_slip_high_deg: float = 22.0
@export var handbrake_slip_deg: float = 85.0
@export var drift_exit_rate: float = 3.0
## Drift hold on throttle: yaw torque (Nm per rad) towards a slip angle set by the steering,
## from `drift_hold` * allowance (full countersteer) to the full allowance (steering into it),
## plus damping of slip changes (Nm per rad/s) so keyboard steering swings the slide smoothly
## between those angles instead of snapping it straight or past the target.
@export var drift_gain: float = 12000.0
@export var drift_hold: float = 0.7
@export var drift_damping: float = 5000.0
## Traction control: allowed driven slip as a multiple of the surface's peak slip ratio.
@export var tc_slip_multiple: float = 1.5
@export var air_level_torque: float = 5500.0
@export var air_damping: float = 5800.0
@export var air_yaw_torque: float = 900.0
@export var auto_reset_time: float = 2.5

@export_group("Aero")
@export var drag_area: float = 0.8
@export var downforce_area: float = 0.45
@export var aero_front_share: float = 0.45

@export_group("Engine")
## Engine, gearbox and driveline tuning; null = the Sakura defaults of `Drivetrain`.
@export var drivetrain: Drivetrain
## Loop set for car_audio.gd: &"turbo4" (Sakura), &"na4" (Hayate).
@export var engine_sound: StringName = &"turbo4"

# ---------------------------------------------------------------- read-only extras
## Body slip angle (rad): + when the velocity points right of the nose (nose rotated left).
var body_slip: float = 0.0
## 0..1, see `lift_turn_intent`.
var drift_intent: float = 0.0

# ---------------------------------------------------------------- internals
var player_input: CarInput = CarInput.new()
## Microseconds spent in the last _integrate_forces (telemetry).
var step_usec: int = 0
var grounded_wheels: int = 0
var local_velocity: Vector3 = Vector3.ZERO

var _shape: CylinderShape3D
var _queries: Array[PhysicsShapeQueryParameters3D] = []
var _free_length: PackedFloat32Array = [0.0, 0.0, 0.0, 0.0]
var _prev_length: PackedFloat32Array = [0.0, 0.0, 0.0, 0.0]
var _omegas: PackedFloat32Array = [0.0, 0.0, 0.0, 0.0]
## Wheel inertia plus the tyre's linearised grip term from the last tick (for the clutch).
var _wheel_inertias: PackedFloat32Array = [1.25, 1.25, 1.25, 1.25]
var _hold_anchor: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
var _hold_active: bool = false
var _tc_scale: float = 1.0
var _stuck_time: float = 0.0
var _prev_vertical_speed: float = 0.0
var _impact_cooldown: float = 0.0
var _pending_reset: bool = false
var _pending_transform: Transform3D
var _gravity: float = 9.8
## Grip under the front wheels (mu incl. grip_scale, peak slip angle) and the rear wheels'
## peak slip angle and looseness, kept from the last contact while airborne.
var _front_mu: float = 1.34
var _front_lat_peak: float = 0.125
var _rear_lat_peak: float = 0.125
var _rear_loose: bool = false
var _prev_slip: float = 0.0
var _steer_memory: float = 0.0


func _ready() -> void:
	drivetrain = drivetrain.duplicate() as Drivetrain if drivetrain != null else Drivetrain.new()
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
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


## Steering lock (radians) at a given speed on the surface under the front wheels - also used by
## the autopilot: the kinematic angle for the grip-limited radius plus the tyres' peak slip angle.
func steer_lock_at(kmh: float) -> float:
	var v := maxf(absf(kmh) / 3.6, 1.0)
	var kinematic := atan(WHEELBASE * _front_mu * _gravity * steer_grip_margin / (v * v))
	return minf(kinematic + _front_lat_peak * steer_slip_factor, deg_to_rad(steer_lock_deg))


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
	body_slip = atan2(local_velocity.x, -local_velocity.z) if Vector2(local_velocity.x, local_velocity.z).length() > 1.0 else 0.0

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
		var hill := slope_accel * mass * WHEEL_RADIUS * 1.4
		brk_in = maxf(brk_in, clampf((CREEP_BRAKE_TORQUE + hill) / total_brake, 0.0, 1.0))

	for i in 4:
		var w: WheelState = wheels[i]
		_omegas[i] = w.spin_speed
	drivetrain.traction_scale = _tc_scale
	drivetrain.pre_wheels(dt, thr_in * _tc_scale, _omegas, _wheel_inertias, handbrake > 0.5)
	_update_tyres(state, xf, com, lin, ang, dt, brk_in, hold)
	for i in 4:
		var w: WheelState = wheels[i]
		_omegas[i] = w.spin_speed
	drivetrain.post_wheels(_omegas)
	_update_assists(state, xf, ang, dt, v_fwd, thr_in)
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
	var delta := clampf(input_steer, -1.0, 1.0) * lock
	# Countersteer assist: front wheels lean towards the direction of travel when the body slides
	# (much less on the handbrake or while the driver holds a drift).
	if v_fwd > 3.0 and grounded_wheels >= 2:
		var excess := signf(body_slip) * maxf(absf(body_slip) - deg_to_rad(countersteer_deadzone_deg), 0.0)
		var gain := countersteer_gain * smoothstep(3.0, 12.0, v_fwd) * (1.0 - 0.7 * handbrake) \
				* (1.0 - 0.6 * drift_intent)
		delta += clampf(excess, -0.7, 0.7) * gain
	var max_total := deg_to_rad(steer_lock_deg + 4.0)
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
	_update_surface_grip()

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
	var abs_ratio := lerpf(abs_slip_ratio, abs_slip_ratio_steer, absf(clampf(input_steer, -1.0, 1.0)))

	for i in 4:
		var w: WheelState = wheels[i]
		var inertia_i := wheel_inertia + drivetrain.extra_inertia[i]
		var t_drive := drivetrain.drive_torque[i]
		var t_foot := brk_in * (brake_torque_front if w.is_front else brake_torque_rear)
		var t_hand := 0.0 if w.is_front else handbrake * handbrake_torque
		var t_brake := maxf(t_foot, t_hand)
		var omega := w.spin_speed

		_wheel_inertias[i] = wheel_inertia
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
		_wheel_inertias[i] = wheel_inertia + stiffness * WHEEL_RADIUS * WHEEL_RADIUS * dt
		var omega_t := omega + dt * (t_drive - WHEEL_RADIUS * f0) / i_eff
		var slip_t := omega_t * WHEEL_RADIUS - v_long
		if slip_t * slip_v < 0.0 and absf(slip_v) > 1e-4:
			# A saturated tyre must not flip the slip sign in one step: fall back to the secant.
			stiffness = maxf(stiffness, f0 / slip_v)
			i_eff = inertia_i + stiffness * WHEEL_RADIUS * WHEEL_RADIUS * dt
			omega_t = omega + dt * (t_drive - WHEEL_RADIUS * f0) / i_eff
		# ABS: the foot brake may slow the wheel only down to the target slip ratio, so the tyre
		# stays at (just under) its braking peak instead of locking. The handbrake bypasses it.
		if t_foot > 0.0 and absf(v_long) > ABS_MIN_SPEED and not hold:
			var omega_abs := maxf(absf(v_long) - surf.long_peak * abs_ratio * denom, 0.0) / WHEEL_RADIUS
			var room := absf(omega_t) - omega_abs if omega_t * v_long > 0.0 else absf(omega_t)
			t_foot = minf(t_foot, maxf(room, 0.0) * i_eff / dt)
			t_brake = maxf(t_foot, t_hand)
		var brake_step := t_brake * dt / i_eff
		omega = 0.0 if absf(omega_t) <= brake_step else omega_t - signf(omega_t) * brake_step
		if hold:
			omega = 0.0

		var kappa := (omega * WHEEL_RADIUS - v_long) / denom
		var f := TyreModel.combined(kappa, tan_a, tyre_load, surf)
		# Arcade braking grip: a braked tyre gets more longitudinal force (friction ellipse).
		var bx := brake_grip_bonus if t_foot > 1.0 and kappa * v_long < 0.0 else 1.0
		var fx := f.x * bx
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
		var total := sqrt(fx * fx / (bx * bx) + fy * fy)
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

	# Traction control from the worst driven wheel.
	var worst := 0.0
	for w: WheelState in wheels:
		if w.contact and w.slip_long > 0.0:
			var surf := TyreModel.get_surface(w.surface)
			# Holding a drift the driven wheels may spin further: throttle is what keeps it going.
			worst = maxf(worst, w.slip_long / (surf.long_peak * tc_slip_multiple * (1.0 + 2.0 * drift_intent)))
	if worst > 1.0:
		_tc_scale = maxf(_tc_scale - dt * 3.0 * (worst - 0.9), 0.5)
	else:
		_tc_scale = minf(_tc_scale + dt * 5.0, 1.0)


## Yaw-rate control, body-slip governor and drift hold: yaw torques about the car's up axis.
func _update_assists(state: PhysicsDirectBodyState3D, xf: Transform3D, ang: Vector3, dt: float,
		v_fwd: float, thr: float) -> void:
	var kmh := v_fwd * 3.6
	var s_in := clampf(input_steer, -1.0, 1.0)
	if absf(s_in) >= absf(_steer_memory) or s_in * _steer_memory < 0.0:
		_steer_memory = s_in
	else:
		_steer_memory = s_in + (_steer_memory - s_in) * exp(-dt / steer_memory_time)
	var s := _steer_memory
	_update_drift_intent(dt, kmh, thr, s)
	var slip_rate := angle_difference(_prev_slip, body_slip) / dt
	_prev_slip = body_slip
	if grounded_wheels < 2 or v_fwd < 4.0:
		return
	var up := xf.basis.y
	var yaw_rate := ang.dot(up)

	# Yaw rate: the steering asks for a share of the grip-limited rate. Below it (turn-in, direction
	# changes) the torque helps; above it (or with the wheel centred) it damps. Fades out while the
	# driver holds a drift or pulls the handbrake.
	var r_max := minf(v_fwd * tan(deg_to_rad(steer_lock_deg)) / WHEELBASE, yaw_grip * _front_mu * _gravity / v_fwd)
	var target := -s * r_max
	var under := absf(target) > 0.01 and yaw_rate * signf(target) < absf(target)
	var yaw_torque := (target - yaw_rate) * (yaw_turn_in_gain if under else yaw_damping_gain)
	yaw_torque = clampf(yaw_torque, -yaw_torque_max, yaw_torque_max) * (1.0 - maxf(drift_intent, handbrake))

	# Body-slip governor: rotates the nose back towards the velocity beyond the allowed slip and
	# damps slip growth close to it.
	var mag := absf(body_slip)
	var dir := signf(body_slip)
	var allow := _slip_allowance(kmh, absf(s))
	var gov := 0.0
	if mag > allow:
		gov -= dir * (mag - allow) * slip_governor_gain
	if slip_rate * dir > 0.0:
		gov -= slip_rate * slip_governor_damping * smoothstep(allow * 0.6, allow, mag)
	# Drift hold: on throttle with drift intent, steer the slip towards a target angle: steering
	# into the slide asks for the full allowance, full countersteer for `drift_hold` of it.
	if drift_intent > 0.05 and thr > 0.5 and mag > deg_to_rad(4.0):
		var into := -s * dir
		var wanted := _drift_allowance(kmh) * lerpf(drift_hold, 1.0, (into + 1.0) * 0.5)
		gov += (dir * (wanted - mag) * drift_gain - slip_rate * drift_damping) * drift_intent
	gov = clampf(gov, -slip_governor_max, slip_governor_max)

	state.apply_torque(up * ((yaw_torque + gov) * float(grounded_wheels) / 4.0))


## Allowed body slip (rad) for the speed, steering and drift intent.
func _slip_allowance(kmh: float, steer_abs: float) -> float:
	var t := smoothstep(40.0, 150.0, kmh)
	var base := _rear_lat_peak * lerpf(slip_allow_low, slip_allow_high, t)
	base = lerpf(deg_to_rad(slip_allow_centred_deg), base, clampf(steer_abs * 2.0, 0.0, 1.0))
	var allow := lerpf(base, _drift_allowance(kmh), drift_intent)
	if handbrake > 0.0:
		allow = maxf(allow, handbrake * deg_to_rad(lerpf(handbrake_slip_deg, drift_slip_high_deg, t)))
	return allow


func _drift_allowance(kmh: float) -> float:
	return deg_to_rad(lerpf(drift_slip_low_deg, drift_slip_high_deg, smoothstep(70.0, 160.0, kmh)))


## Drift intent: handbrake -> 1; lift or brake with the wheel turned on a loose surface ->
## `lift_turn_intent`; held by throttle while sliding; centring the wheel ends it.
func _update_drift_intent(dt: float, kmh: float, thr: float, s: float) -> void:
	if grounded_wheels < 2:
		return
	var steer_abs := absf(s)
	if handbrake > 0.5 and kmh > 15.0:
		drift_intent = move_toward(drift_intent, 1.0, dt * 8.0)
		return
	var lift_turn := _rear_loose and thr < 0.2 and steer_abs > 0.6 and kmh > 25.0 and kmh < 110.0
	if lift_turn and drift_intent < lift_turn_intent:
		drift_intent = move_toward(drift_intent, lift_turn_intent, dt * 1.5)
		return
	var decay := 0.0
	if steer_abs < 0.15:
		decay = drift_exit_rate
	elif kmh < 15.0 or absf(body_slip) < deg_to_rad(5.0):
		decay = 1.5
	elif thr < 0.5 and not lift_turn:
		decay = 1.0
	drift_intent = move_toward(drift_intent, 0.0, decay * dt)


## Grip under the front wheels and peak slip / looseness under the rear ones (kept while airborne).
func _update_surface_grip() -> void:
	var mu := 0.0
	var lat := 0.0
	var n := 0
	for i in 2:
		var w: WheelState = wheels[i]
		if w.contact:
			mu += w.surface_mu
			lat += TyreModel.get_surface(w.surface).lat_peak
			n += 1
	if n > 0:
		_front_mu = mu / n
		_front_lat_peak = lat / n
	lat = 0.0
	n = 0
	var loose := false
	for i in range(2, 4):
		var w: WheelState = wheels[i]
		if w.contact:
			var surf := TyreModel.get_surface(w.surface)
			lat += surf.lat_peak
			loose = loose or surf.loose
			n += 1
	if n > 0:
		_rear_lat_peak = lat / n
		_rear_loose = loose


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
	drift_intent = 0.0
	body_slip = 0.0
	_prev_slip = 0.0
	_steer_memory = 0.0
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
