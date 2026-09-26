class_name GarageDriver
extends Node
## Drives the parent Car along a short scripted line under its own engine: the garage's car
## switch (MenuStage). A leaving car pulls out of the lay-by and speeds off along the road; an
## arriving car comes up the road, turns in and brakes on a constant-deceleration profile to rest
## exactly on the line's last point, square to its last segment. Pure pursuit on the polyline
## (the ArrivalStop controller, on a free path instead of the track).

## Emitted once: the arriving car stands still on the end point, or the leaving car ran out of line.
signal finished

## World-space line; the car starts at or behind the first point.
var points := PackedVector3Array()
## true: stop on the last point (arrival); false: drive off its end (leaving).
var stop_at_end := true
## Target speed (m/s) up to `first_until` metres along the line, then `then_speed`.
var first_speed := 7.0
var first_until := 0.0
var then_speed := 11.0
## Throttle ceiling: a calm roll-in, a keen pull-away.
var max_throttle := 0.45
## Braking deceleration of the stop profile (m/s^2).
var decel := 4.0

var done := false
## Metres to go to the end point (along its heading on the last segment).
var left := INF

var _car: Car
var _cum := PackedFloat32Array()
var _seg := 0


func _ready() -> void:
	_car = get_parent() as Car
	process_physics_priority = -10
	_cum.resize(points.size())
	var total := 0.0
	for i in points.size():
		if i > 0:
			total += _flat(points[i] - points[i - 1]).length()
		_cum[i] = total


func _physics_process(_delta: float) -> void:
	if _car == null or points.size() < 2 or done:
		return
	var pos := _car.global_position
	var speed := _car.linear_velocity.length()
	var s := _project(pos)
	var total: float = _cum[_cum.size() - 1]
	var end_dir := _flat(points[points.size() - 1] - points[points.size() - 2]).normalized()
	left = total - s
	if _seg >= points.size() - 2:
		left = _flat(points[points.size() - 1] - pos).dot(end_dir)
	if not stop_at_end and left <= 0.0:
		_finish()
		return
	# Steer: pure pursuit on the line ahead (past its end, straight on along the last segment).
	var look := clampf(3.0 + speed * 0.45, 4.0, 12.0)
	var aim := _point_at(s + look, end_dir)
	var local := _car.global_transform.affine_inverse() * aim
	var alpha := atan2(local.x, -local.z)
	var k := 2.0 * sin(alpha) / maxf(Vector2(local.x, local.z).length(), 1.0)
	_car.input_steer = clampf(atan(k * Car.WHEELBASE) / _car.steer_lock_at(speed * 3.6), -1.0, 1.0) if speed > 0.3 else 0.0
	_car.input_handbrake = false
	var want := first_speed if s < first_until else then_speed
	if not stop_at_end:
		_car.input_brake = 0.0
		_car.input_throttle = clampf((want - speed) / 3.0, 0.0, max_throttle)
		return
	# Stop: v = sqrt(2 a d) down to a creep for the last few centimetres, then the brakes.
	want = minf(want, maxf(sqrt(2.0 * decel * maxf(left - 0.05, 0.0)), 0.9 if left > 0.12 else 0.0))
	if left <= 0.12 or (left <= 0.4 and speed < 0.25):
		_car.input_throttle = 0.0
		_car.input_brake = 1.0
		if speed < 0.05:
			_finish()
	elif speed > want + 0.3:
		_car.input_throttle = 0.0
		_car.input_brake = clampf((speed - want) / 2.5, 0.15, 1.0)
	else:
		_car.input_throttle = clampf((want - speed) / 3.0 + 0.08, 0.0, max_throttle)
		_car.input_brake = 0.0


func _finish() -> void:
	done = true
	_car.input_throttle = 0.0
	_car.input_steer = 0.0
	_car.input_brake = 1.0 if stop_at_end else 0.0
	finished.emit()


## Line distance of the closest point to pos, searching forward from the current segment.
func _project(pos: Vector3) -> float:
	var best := INF
	var best_s := 0.0
	var best_i := _seg
	for i in range(_seg, mini(_seg + 6, points.size() - 1)):
		var a := _flat(points[i])
		var ab := _flat(points[i + 1]) - a
		var l2 := maxf(ab.length_squared(), 1e-6)
		var t := clampf((_flat(pos) - a).dot(ab) / l2, 0.0, 1.0)
		var d := (a + ab * t).distance_squared_to(_flat(pos))
		if d < best:
			best = d
			best_i = i
			best_s = _cum[i] + sqrt(l2) * t
	_seg = best_i
	return best_s


func _point_at(s: float, end_dir: Vector3) -> Vector3:
	var n := points.size()
	if s >= _cum[n - 1]:
		return points[n - 1] + end_dir * (s - _cum[n - 1])
	var i := _seg
	while i < n - 2 and _cum[i + 1] < s:
		i += 1
	var t := (s - _cum[i]) / maxf(_cum[i + 1] - _cum[i], 1e-6)
	return points[i].lerp(points[i + 1], clampf(t, 0.0, 1.0))


static func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)
