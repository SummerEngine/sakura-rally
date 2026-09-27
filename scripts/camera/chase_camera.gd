class_name ChaseCamera
extends Camera3D
## Rally chase camera: tight-but-smooth follow that partly looks along the velocity in slides,
## look-ahead, speed-based FOV, terrain-aware (sphere cast so it never clips into the world),
## trauma shake from impacts, landings and bumps from other cars plus surface rumble. Modes:
## chase, chase_far, hood, bumper (cycle with `camera_next`, persisted in the "camera" setting).
## Runs in _process on the target's interpolated transform (physics interpolation is on), so it is
## itself not interpolated.
##
## The chase rig pitches with the road: on a descent (or before a crest) it swings up behind the
## car and looks down along the slope (`slope_descent_gain` times the grade), so the road ahead
## shows over the roof. The slope comes from the road profile ahead of the car (`road`, else the
## session's track) while the car is on or near that road and heading along it, else from the
## car's own pitch (low-passed, easing to level in the air). Uphill it follows only `slope_uphill_follow` of the
## grade, capped at `slope_max_up`, so it never stares at the sky.
## docs/PHYSICS.md, "Chase camera".

const MODES: Array[String] = ["chase", "chase_far", "hood", "bumper"]
## Distances (m) ahead of the car at which the road profile is read for the rig's slope, at up
## to SLOPE_AHEAD_SPEED; faster they stretch with the speed (up to twice), so a crest is seen
## coming the same time ahead.
const SLOPE_AHEAD: PackedFloat32Array = [6.0, 12.0, 18.0, 26.0, 36.0]
const SLOPE_AHEAD_SPEED := 25.0
## The road's slope at the car is its chord from this far behind to this far ahead of it (m).
const SLOPE_AT_CAR := 6.0
## Low-pass rate (1/s) of the car's own pitch grade (used off the road), and its decay to level
## in the air.
const OWN_GRADE_RATE := 1.5

## The car to follow (Car / any RigidBody3D). Falls back to Game.player_car when empty.
@export var target: RigidBody3D
@export var mode: String = "chase"
## Read `camera_next` and load/save the "camera" setting.
@export var player_camera: bool = true

@export_group("Chase")
@export var chase_distance: float = 5.4
@export var chase_height: float = 1.75
@export var far_distance: float = 7.6
@export var far_height: float = 2.6
@export var look_height: float = 0.95
## How far the view turns towards the direction of travel when sliding (0..1).
@export var velocity_bias: float = 0.45
## Heading follow rate (1/s): higher = tighter.
@export var yaw_rate: float = 5.5
@export var height_rate: float = 7.0
@export var look_ahead: float = 3.5

@export_group("Slope")
## Share of the slope the chase rig pitches with (0 = the level rig of episode 2, 1 = full).
@export var slope_follow: float = 1.0
## Grades within this of level are taken as level, so flat roads keep the level rig.
@export var slope_deadband: float = 0.015
## A downhill grade is followed this many times over: the road ahead shows above the roof
## with some margin instead of just clearing it.
@export var slope_descent_gain: float = 1.5
## Share of an uphill grade followed (the road ahead rising is visible anyway).
@export var slope_uphill_follow: float = 0.5
## Limits of the followed grade (rise over run): down, up.
@export var slope_max_down: float = 0.4
@export var slope_max_up: float = 0.08
## Smoothing time (s) of the rig's slope (critically damped).
@export var slope_smooth_time: float = 0.45

@export_group("Lens")
@export var fov_min: float = 70.0
@export var fov_max: float = 82.0
@export var fov_full_speed_kmh: float = 180.0

@export_group("Shake")
@export var shake_decay: float = 1.8
@export var shake_max_angle_deg: float = 2.2
@export var shake_max_offset: float = 0.06
@export var rumble_amount: float = 0.35

## Road whose profile ahead sets the rig's slope; null = the `track` of Game.session, if any.
var road: Track

var _yaw_dir: Vector3 = Vector3.FORWARD
var _height: float = 0.0
var _dist_extra: float = 0.0
var _trauma: float = 0.0
var _rumble: float = 0.0
var _time: float = 0.0
var _noise: FastNoiseLite = FastNoiseLite.new()
var _last_target_pos: Vector3 = Vector3.ZERO
var _prev_speed: float = 0.0
var _needs_snap: bool = true
var _connected_to: Object = null
## Followed grade (rise over run along the heading, - = downhill) and its rate.
var _slope: float = 0.0
var _slope_rate: float = 0.0
var _road_idx: int = -1
var _road_seen: Track = null
## The car's own grade along the heading, held while it is airborne.
var _own_grade: float = 0.0


func _ready() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = 1.0
	_noise.seed = 11
	if player_camera:
		var saved := str(_setting("camera", mode))
		if saved in MODES:
			mode = saved
	fov = fov_min


## Adds camera trauma (0..1). Shake grows with trauma squared, so small bumps stay subtle.
func shake(amount: float) -> void:
	_trauma = clampf(_trauma + amount, 0.0, 1.0)


## Skips all smoothing on the next frame (after teleports / resets / target changes).
func snap() -> void:
	_needs_snap = true


func set_mode(new_mode: String) -> void:
	if not new_mode in MODES:
		return
	mode = new_mode
	snap()
	if player_camera:
		var game := get_node_or_null(^"/root/Game")
		if game != null:
			game.set_setting("camera", mode)


func cycle_mode() -> void:
	set_mode(MODES[(MODES.find(mode) + 1) % MODES.size()])


func _process(delta: float) -> void:
	var car := _resolve_target()
	if car == null:
		return
	if player_camera and Input.is_action_just_pressed(&"camera_next"):
		cycle_mode()
	_time += delta
	var xf := car.get_global_transform_interpolated()
	if xf.origin.distance_to(_last_target_pos) > 15.0:
		_needs_snap = true
	_last_target_pos = xf.origin
	var vel := car.linear_velocity
	var speed := vel.length()
	var kmh := speed * 3.6
	_update_rumble(car, speed, delta)

	var cam_xf: Transform3D
	if mode == "hood" or mode == "bumper":
		cam_xf = _mounted(xf, mode == "hood")
	else:
		cam_xf = _chase(car, xf, vel, speed, delta, mode == "chase_far")
	_needs_snap = false

	var base_fov := fov_min + (fov_max - fov_min) * smoothstep(0.0, fov_full_speed_kmh, kmh)
	if mode == "hood" or mode == "bumper":
		base_fov += 4.0
	var boost_value := float(car.get(&"boost")) if &"boost" in car else 0.0
	fov = lerpf(fov, base_fov + boost_value * 1.5, 1.0 - exp(-4.0 * delta))
	global_transform = _apply_shake(cam_xf, delta)


func _resolve_target() -> RigidBody3D:
	var car := target
	if car == null:
		var game := get_node_or_null(^"/root/Game")
		if game != null:
			car = game.get(&"player_car") as RigidBody3D
	if car != _connected_to:
		_connect(car)
		snap()
	return car


func _connect(car: RigidBody3D) -> void:
	if _connected_to != null and is_instance_valid(_connected_to):
		if _connected_to.has_signal(&"impact") and _connected_to.is_connected(&"impact", _on_impact):
			_connected_to.disconnect(&"impact", _on_impact)
		if _connected_to.has_signal(&"bumped") and _connected_to.is_connected(&"bumped", _on_bumped):
			_connected_to.disconnect(&"bumped", _on_bumped)
		if _connected_to.has_signal(&"landed") and _connected_to.is_connected(&"landed", _on_landed):
			_connected_to.disconnect(&"landed", _on_landed)
	_connected_to = car
	if car == null:
		return
	if car.has_signal(&"impact"):
		car.connect(&"impact", _on_impact)
	if car.has_signal(&"bumped"):
		car.connect(&"bumped", _on_bumped)
	if car.has_signal(&"landed"):
		car.connect(&"landed", _on_landed)


func _on_impact(strength: float, _point: Vector3) -> void:
	shake(clampf(strength * 0.55, 0.0, 0.8))


## Another car hit ours (Car.bumped, race contacts): a lighter shake than a wall.
func _on_bumped(strength: float, _point: Vector3, _other: Car) -> void:
	shake(clampf(strength * 0.45, 0.0, 0.7))


func _on_landed(strength: float) -> void:
	shake(clampf(strength * 0.45, 0.0, 0.6))


func _chase(car: RigidBody3D, xf: Transform3D, vel: Vector3, speed: float, delta: float, far: bool) -> Transform3D:
	var dist := far_distance if far else chase_distance
	var height := far_height if far else chase_height
	var car_fwd := -xf.basis.z
	car_fwd.y = 0.0
	car_fwd = car_fwd.normalized() if car_fwd.length_squared() > 0.001 else _yaw_dir
	var desired := car_fwd
	var flat_vel := Vector3(vel.x, 0.0, vel.z)
	var fwd_speed := flat_vel.dot(car_fwd)
	if flat_vel.length() > 3.0 and fwd_speed > 0.0:
		var w := velocity_bias * smoothstep(3.0, 14.0, flat_vel.length())
		desired = car_fwd.slerp(flat_vel.normalized(), w).normalized()
	var slope_target := _slope_target(car, xf, speed, delta) * slope_follow if slope_follow > 0.0 else 0.0
	if _needs_snap:
		_yaw_dir = desired
		_height = xf.origin.y
		_dist_extra = 0.0
		_prev_speed = speed
		_slope = slope_target
		_slope_rate = 0.0
	else:
		var angle := _yaw_dir.signed_angle_to(desired, Vector3.UP)
		_yaw_dir = _yaw_dir.rotated(Vector3.UP, angle * (1.0 - exp(-yaw_rate * delta))).normalized()
		_height = lerpf(_height, xf.origin.y, 1.0 - exp(-height_rate * delta))
		# Pull back slightly under acceleration, close in under braking.
		var accel := (speed - _prev_speed) / maxf(delta, 1e-4)
		_prev_speed = speed
		_dist_extra = lerpf(_dist_extra, clampf(accel * 0.05, -0.5, 0.5), 1.0 - exp(-3.0 * delta))
		_smooth_slope(slope_target, delta)
	dist += speed * 0.012 + _dist_extra
	# The rig (offset and look target) turns about the heading's right axis by the followed slope:
	# a steady grade frames like a flat road, a crest ahead lifts the camera before the drop.
	var pitch := atan(_slope)
	var fwd := _yaw_dir * cos(pitch) + Vector3.UP * sin(pitch)
	var up := Vector3.UP * cos(pitch) - _yaw_dir * sin(pitch)
	var pivot := Vector3(xf.origin.x, _height, xf.origin.z)
	var look_at_point := pivot + up * look_height + fwd * clampf(speed * 0.1, 0.0, look_ahead)
	var desired_pos := pivot - fwd * dist + up * height
	var pos := _avoid_terrain(xf.origin + Vector3.UP * 1.1, desired_pos)
	var basis := Basis.looking_at((look_at_point - pos).normalized(), Vector3.UP)
	return Transform3D(basis, pos)


## Grade the rig should follow (before smoothing): the steeper of the road's slope at the car and
## its steepest drop within SLOPE_AHEAD, only partly followed uphill. Off the road (or across it)
## it blends to the car's own pitch, low-passed (OWN_GRADE_RATE) so a kicker or a bump barely
## registers, and easing back to level while the car is airborne.
func _slope_target(car: RigidBody3D, xf: Transform3D, speed: float, delta: float) -> float:
	var grounded: Variant = car.get(&"grounded_wheels")
	if grounded == null or int(grounded) >= 3 or _needs_snap:
		var nose := -xf.basis.z
		var run := maxf(Vector2(nose.x, nose.z).length(), 0.2)
		var pitch_grade := nose.y / run if nose.dot(_yaw_dir) >= 0.0 else -nose.y / run
		_own_grade = pitch_grade if _needs_snap else lerpf(_own_grade, pitch_grade, 1.0 - exp(-OWN_GRADE_RATE * delta))
	else:
		_own_grade *= exp(-OWN_GRADE_RATE * delta)
	var grade := _own_grade
	var track := _resolve_road()
	if track != null:
		var p := xf.origin
		_road_idx = track.nearest(p, _road_idx if not _needs_snap else -1)
		var i := _road_idx
		var along := track.forward(i).dot(_yaw_dir)
		var off := absf(track.lateral(i, p)) - track.half_width(i)
		var w := (1.0 - smoothstep(1.0, 8.0, off)) * smoothstep(0.35, 0.7, absf(along))
		w *= 1.0 - smoothstep(3.0, 6.0, absf(p.y - track.point(i).y))
		if w > 0.0:
			var dir := 1.0 if along >= 0.0 else -1.0
			var s := track.abs_s(i, p)
			var y0 := track.position_at_abs(s).y
			var at_car := (track.position_at_abs(s + dir * SLOPE_AT_CAR).y
					- track.position_at_abs(s - dir * SLOPE_AT_CAR).y) / (2.0 * SLOPE_AT_CAR)
			var ahead := INF
			var stretch := clampf(speed / SLOPE_AHEAD_SPEED, 1.0, 2.0)
			for k: float in SLOPE_AHEAD:
				var d := k * stretch
				ahead = minf(ahead, (track.position_at_abs(s + dir * d).y - y0) / d)
			grade = lerpf(_own_grade, minf(at_car, ahead), w)
	grade = signf(grade) * maxf(absf(grade) - slope_deadband, 0.0)
	grade *= slope_uphill_follow if grade > 0.0 else slope_descent_gain
	return clampf(grade, -slope_max_down, slope_max_up)


## Critically damped follow of the rig's slope (frame-rate independent).
func _smooth_slope(target_slope: float, delta: float) -> void:
	var omega := 2.0 / maxf(slope_smooth_time, 0.01)
	var x := omega * delta
	var decay := 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)
	var change := _slope - target_slope
	var temp := (_slope_rate + omega * change) * delta
	_slope_rate = (_slope_rate - omega * temp) * decay
	_slope = target_slope + (change + temp) * decay


func _resolve_road() -> Track:
	var track := road
	if track == null:
		var game := get_node_or_null(^"/root/Game")
		var session: Object = game.get(&"session") if game != null else null
		if session != null and is_instance_valid(session):
			track = session.get(&"track") as Track
	if track != _road_seen:
		_road_seen = track
		_road_idx = -1
	return track


func _mounted(xf: Transform3D, hood: bool) -> Transform3D:
	var local := Vector3(0.0, 1.34, -0.45) if hood else Vector3(0.0, 0.6, -2.2)
	var pos := xf * local
	# Keep the horizon calmer than the chassis: follow pitch, damp roll.
	var fwd := -xf.basis.z
	var up := xf.basis.y.lerp(Vector3.UP, 0.6).normalized()
	var basis := Basis.looking_at(fwd, up)
	return Transform3D(basis, pos)


func _avoid_terrain(from: Vector3, to: Vector3) -> Vector3:
	var world := get_world_3d()
	if world == null:
		return to
	var space := world.direct_space_state
	var sphere := SphereShape3D.new()
	sphere.radius = 0.3
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sphere
	q.collision_mask = 1
	q.transform = Transform3D(Basis.IDENTITY, from)
	q.motion = to - from
	var frac := space.cast_motion(q)
	var pos := to
	if frac.size() == 2 and frac[0] < 1.0:
		pos = from + (to - from) * frac[0]
	# Keep a little clearance above the ground below the camera.
	var ray := PhysicsRayQueryParameters3D.create(pos + Vector3.UP * 2.0, pos + Vector3.DOWN * 1.0, 1)
	var hit := space.intersect_ray(ray)
	if not hit.is_empty():
		var ground_y: float = (hit["position"] as Vector3).y
		pos.y = maxf(pos.y, ground_y + 0.5)
	return pos


func _update_rumble(car: RigidBody3D, speed: float, delta: float) -> void:
	var rough := 0.0
	var wheels: Variant = car.get(&"wheels")
	if wheels is Array:
		for w in wheels:
			var ws := w as WheelState
			if ws != null and ws.contact:
				rough += ws.surface_roughness * 0.25
	var target_rumble := rough * clampf(speed / 30.0, 0.0, 1.0) * rumble_amount
	_rumble = lerpf(_rumble, target_rumble, 1.0 - exp(-5.0 * delta))
	_trauma = maxf(_trauma - shake_decay * delta, 0.0)


func _apply_shake(xf: Transform3D, _delta: float) -> Transform3D:
	var amount := _trauma * _trauma + _rumble * 0.12
	if amount <= 0.0001:
		return xf
	var t := _time * (18.0 + 10.0 * _trauma)
	var max_angle := deg_to_rad(shake_max_angle_deg) * amount
	var pitch := _noise.get_noise_2d(t, 0.0) * max_angle
	var yaw := _noise.get_noise_2d(t, 50.0) * max_angle * 0.5
	var roll := _noise.get_noise_2d(t, 100.0) * max_angle * 0.6
	var offset := Vector3(_noise.get_noise_2d(t, 150.0), _noise.get_noise_2d(t, 200.0), 0.0) * shake_max_offset * amount
	var basis := xf.basis * Basis.from_euler(Vector3(pitch, yaw, roll))
	return Transform3D(basis, xf.origin + xf.basis * offset)


func _setting(key: String, fallback: Variant) -> Variant:
	var game := get_node_or_null(^"/root/Game")
	if game == null:
		return fallback
	return game.get_setting(key)
