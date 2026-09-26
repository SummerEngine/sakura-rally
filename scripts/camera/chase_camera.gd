class_name ChaseCamera
extends Camera3D
## Rally chase camera: tight-but-smooth follow that partly looks along the velocity in slides,
## look-ahead, speed-based FOV, terrain-aware (sphere cast so it never clips into the world),
## trauma shake from impacts/landings plus surface rumble. Modes: chase, chase_far, hood, bumper
## (cycle with `camera_next`, persisted in the "camera" setting). Runs in _process on the
## target's interpolated transform (physics interpolation is on), so it is itself not interpolated.

const MODES: Array[String] = ["chase", "chase_far", "hood", "bumper"]

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

@export_group("Lens")
@export var fov_min: float = 70.0
@export var fov_max: float = 82.0
@export var fov_full_speed_kmh: float = 180.0

@export_group("Shake")
@export var shake_decay: float = 1.8
@export var shake_max_angle_deg: float = 2.2
@export var shake_max_offset: float = 0.06
@export var rumble_amount: float = 0.35

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
		cam_xf = _chase(xf, vel, speed, delta, mode == "chase_far")
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
		if _connected_to.has_signal(&"landed") and _connected_to.is_connected(&"landed", _on_landed):
			_connected_to.disconnect(&"landed", _on_landed)
	_connected_to = car
	if car == null:
		return
	if car.has_signal(&"impact"):
		car.connect(&"impact", _on_impact)
	if car.has_signal(&"landed"):
		car.connect(&"landed", _on_landed)


func _on_impact(strength: float, _point: Vector3) -> void:
	shake(clampf(strength * 0.55, 0.0, 0.8))


func _on_landed(strength: float) -> void:
	shake(clampf(strength * 0.45, 0.0, 0.6))


func _chase(xf: Transform3D, vel: Vector3, speed: float, delta: float, far: bool) -> Transform3D:
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
	if _needs_snap:
		_yaw_dir = desired
		_height = xf.origin.y
		_dist_extra = 0.0
		_prev_speed = speed
	else:
		var angle := _yaw_dir.signed_angle_to(desired, Vector3.UP)
		_yaw_dir = _yaw_dir.rotated(Vector3.UP, angle * (1.0 - exp(-yaw_rate * delta))).normalized()
		_height = lerpf(_height, xf.origin.y, 1.0 - exp(-height_rate * delta))
		# Pull back slightly under acceleration, close in under braking.
		var accel := (speed - _prev_speed) / maxf(delta, 1e-4)
		_prev_speed = speed
		_dist_extra = lerpf(_dist_extra, clampf(accel * 0.05, -0.5, 0.5), 1.0 - exp(-3.0 * delta))
	dist += speed * 0.012 + _dist_extra
	var pivot := Vector3(xf.origin.x, _height, xf.origin.z)
	var look_at_point := pivot + Vector3.UP * look_height + _yaw_dir * clampf(speed * 0.1, 0.0, look_ahead)
	var desired_pos := pivot - _yaw_dir * dist + Vector3.UP * height
	var pos := _avoid_terrain(xf.origin + Vector3.UP * 1.1, desired_pos)
	var basis := Basis.looking_at((look_at_point - pos).normalized(), Vector3.UP)
	return Transform3D(basis, pos)


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
