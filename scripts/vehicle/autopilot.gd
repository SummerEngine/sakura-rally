class_name Autopilot
extends Node
## AI driver for the parent Car: follows a racing line (Curve3D) with pure-pursuit steering and a
## grip-aware speed profile (curvature limit + braking-distance planning). Used for the menu
## background, the demo video and the physics tests.
##
## Give it either `path` (a Path3D, world transform taken from the node) or `curve` +
## `curve_transform`. The line is treated as closed when `closed` is true.

signal lap_completed(lap_time: float)

@export var path: Path3D
@export var enabled: bool = true
@export var closed: bool = true
## Multiplies the target speed everywhere (0.6 = relaxed cruise, 1.0 = committed).
@export_range(0.2, 1.3) var speed_scale: float = 1.0
## Drive this many metres to the right (+) / left (-) of the line.
@export var lateral_offset: float = 0.0
@export var max_speed_kmh: float = 195.0
## Fraction of the surface grip used in corners and under braking. The car reaches about 90 %
## of the surface mu on a skidpad; 0.76 in corners keeps ~15 % in hand for following the line.
@export var corner_grip: float = 0.76
@export var brake_grip: float = 0.72
## Pure-pursuit lookahead: base metres + seconds of travel, clamped.
@export var lookahead_base: float = 5.0
@export var lookahead_time: float = 0.42
@export var lookahead_min: float = 7.0
@export var lookahead_max: float = 30.0

var curve: Curve3D
var curve_transform: Transform3D = Transform3D.IDENTITY

## Distance along the line of the car's closest point, and the line length (m).
var progress: float = 0.0
var length: float = 0.0
var laps: int = 0
var lap_time: float = 0.0
var last_lap_time: float = 0.0
## Horizontal distance from the line (m, signed: + right of the line) - for tests and the camera.
var lateral_error: float = 0.0
var target_speed: float = 0.0

const STEP := 2.0

var _car: Car
var _points: PackedVector3Array = PackedVector3Array()
var _tangents: PackedVector3Array = PackedVector3Array()
var _speeds: PackedFloat32Array = PackedFloat32Array()
var _index: int = -1
var _stuck_time: float = 0.0
var _built: bool = false
var _mu_cache: PackedFloat32Array = PackedFloat32Array()


func _ready() -> void:
	_car = get_parent() as Car
	process_physics_priority = -10


## (Re)builds the speed profile; call after changing the line at runtime.
func rebuild() -> void:
	_built = false
	_index = -1


func _physics_process(delta: float) -> void:
	if _car == null or not enabled:
		return
	if not _built:
		if not _build():
			return
	_drive(delta)


func _build() -> bool:
	var xf := curve_transform
	var c := curve
	if path != null:
		c = path.curve
		xf = path.global_transform
	if c == null or c.point_count < 2:
		return false
	length = c.get_baked_length()
	_mu_cache.clear()
	var count := maxi(int(length / STEP), 8)
	var step := length / count
	_points.resize(count)
	_tangents.resize(count)
	for i in count:
		_points[i] = xf * c.sample_baked(i * step)
	for i in count:
		var a := _points[(i - 1 + count) % count] if closed or i > 0 else _points[i]
		var b := _points[(i + 1) % count] if closed or i < count - 1 else _points[i]
		_tangents[i] = (b - a).normalized()
	# Curvature from heading change over +-3 samples, smoothed.
	var curvature := PackedFloat32Array()
	curvature.resize(count)
	for i in count:
		var ia := (i - 3 + count) % count
		var ib := (i + 3) % count
		var ta := Vector2(_tangents[ia].x, _tangents[ia].z)
		var tb := Vector2(_tangents[ib].x, _tangents[ib].z)
		curvature[i] = absf(ta.angle_to(tb)) / (6.0 * step)
	var space := _car.get_world_3d().direct_space_state
	var g := float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	_speeds.resize(count)
	for i in count:
		var k := 0.0
		for j in range(-2, 3):
			k = maxf(k, curvature[(i + j + count) % count])
		var mu := _grip_at(space, _points[i])
		var v := sqrt(mu * corner_grip * g / maxf(k, 1e-4))
		_speeds[i] = minf(v, max_speed_kmh / 3.6)
	# Braking-distance planning: backwards pass (twice around for closed lines).
	var passes := count * (2 if closed else 1)
	for n in passes:
		var i := count - 1 - (n % count)
		var nxt := (i + 1) % count
		if not closed and i == count - 1:
			continue
		var mu := _grip_at_cached(i)
		var reach := sqrt(_speeds[nxt] * _speeds[nxt] + 2.0 * mu * brake_grip * g * step)
		_speeds[i] = minf(_speeds[i], reach)
	_built = true
	return true


func _grip_at(space: PhysicsDirectSpaceState3D, p: Vector3) -> float:
	var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 5.0, p + Vector3.DOWN * 5.0, 1)
	var hit := space.intersect_ray(q)
	var mu := TyreModel.get_surface(&"tarmac").mu
	if not hit.is_empty():
		mu = TyreModel.get_surface(Car.surface_of(hit["collider"], hit["position"])).mu
	_mu_cache.append(mu)
	return mu


func _grip_at_cached(i: int) -> float:
	return _mu_cache[i] if i < _mu_cache.size() else 1.0


func _drive(delta: float) -> void:
	var count := _points.size()
	var pos := _car.global_position
	_index = _closest_index(pos)
	var p := _points[_index]
	var t := _tangents[_index]
	# Sub-sample progress.
	var along := (pos - p).dot(t)
	var new_progress := fposmod(_index * (length / count) + along, length)
	lap_time += delta
	if closed and new_progress < length * 0.1 and progress > length * 0.9:
		laps += 1
		last_lap_time = lap_time
		lap_completed.emit(lap_time)
		lap_time = 0.0
	progress = new_progress
	var right := t.cross(Vector3.UP).normalized()
	lateral_error = (pos - p).dot(right) - lateral_offset

	var speed := _car.linear_velocity.length()
	var kmh := speed * 3.6
	# Steering: pure pursuit towards a lookahead point on the (offset) line.
	var look := clampf(lookahead_base + speed * lookahead_time, lookahead_min, lookahead_max)
	var target := _sample(progress + look)
	var local := _car.global_transform.affine_inverse() * target
	var dist := maxf(Vector2(local.x, local.z).length(), 1.0)
	var alpha := atan2(local.x, -local.z)
	var k := 2.0 * sin(alpha) / dist
	var delta_angle := atan(k * Car.WHEELBASE)
	_car.input_steer = clampf(delta_angle / _car.steer_lock_at(kmh), -1.0, 1.0)

	# Speed: profile value a little ahead, scaled. Off the line on a slower surface (grass
	# beside a gravel hairpin) the profile's grip is not under the tyres: scale down to it.
	var lead := speed * 0.35 + 3.0
	var i_ahead := int(fposmod(progress + lead, length) / (length / count)) % count
	var grip_ratio := clampf(_car.current_grip() / _grip_at_cached(_index), 0.5, 1.0)
	target_speed = minf(_speeds[_index], _speeds[i_ahead]) * speed_scale * sqrt(grip_ratio)
	var err := target_speed - speed
	if err >= 0.0:
		# No power while sideways: flooring it in a slide turns the slide into a spin.
		var v := _car.local_velocity
		var slip := rad_to_deg(absf(atan2(v.x, maxf(-v.z, 0.5))))
		_car.input_throttle = clampf(err / 2.5 + 0.15, 0.0, 1.0) * clampf(1.0 - (slip - 8.0) / 12.0, 0.3, 1.0)
		_car.input_brake = 0.0
	else:
		_car.input_throttle = clampf(0.15 + err / 2.0, 0.0, 1.0)
		_car.input_brake = clampf((-err - 0.3) / 1.5, 0.0, 1.0)
	_car.input_handbrake = false

	# Recover if wedged somewhere.
	if speed < 1.0:
		_stuck_time += delta
		if _stuck_time > 4.0:
			_stuck_time = 0.0
			_car.reset_to(transform_at(progress))
	else:
		_stuck_time = 0.0


func _closest_index(pos: Vector3) -> int:
	var count := _points.size()
	var best := -1
	var best_d := INF
	if _index < 0:
		for i in count:
			var d := pos.distance_squared_to(_points[i])
			if d < best_d:
				best_d = d
				best = i
		return best
	for j in range(-20, 40):
		var i := (_index + j + count) % count
		if not closed and (i < 0 or i >= count):
			continue
		var d := pos.distance_squared_to(_points[i])
		if d < best_d:
			best_d = d
			best = i
	# Lost the line (teleport): full search.
	if best_d > 900.0:
		_index = -1
		return _closest_index(pos)
	return best


## Point on the offset line at a distance along it (world space).
func _sample(offset: float) -> Vector3:
	var count := _points.size()
	var f := fposmod(offset, length) / (length / count)
	var i0 := int(f) % count
	var i1 := (i0 + 1) % count
	var p := _points[i0].lerp(_points[i1], f - floorf(f))
	var t := _tangents[i0].lerp(_tangents[i1], f - floorf(f)).normalized()
	return p + t.cross(Vector3.UP).normalized() * lateral_offset


## World transform on the line at a distance along it, facing the direction of travel.
func transform_at(offset: float) -> Transform3D:
	if not _built:
		_build()
	var p := _sample(offset)
	var ahead := _sample(offset + 3.0)
	return Transform3D(Basis.looking_at((ahead - p).normalized(), Vector3.UP), p)
