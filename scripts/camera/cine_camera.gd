class_name CineCamera
extends Camera3D
## Cinematic camera for everything that is not driving: the title-screen flyover
## (a cycle of shots around the autopilot car), the race intro swoop that lands
## in the chase pose, and the slow orbit behind the results card.
##
## Follows the car's interpolated transform in _process, in real time (ignores
## Engine.time_scale), and keeps running while the tree is paused.

signal intro_finished

enum Mode { IDLE, MENU, INTRO, FINISH }

const MENU_SHOTS: Array[String] = ["tracking", "roadside", "drone", "front", "scenic", "wheel"]

var car: Car
var track: Track
var mode: int = Mode.IDLE
## Chase pose the intro lands on (car space), matching the ChaseCamera defaults.
var chase_offset: Vector3 = Vector3(0.0, 1.75, 5.4)
var chase_look: Vector3 = Vector3(0.0, 0.95, -3.5)

var _t: float = 0.0
var _dur: float = 1.0
var _shot: String = ""
var _shot_i: int = -1
var _shot_t: float = 0.0
var _anchor: Vector3 = Vector3.ZERO
var _anchor_s: float = 0.0
var _side: float = 1.0
var _orbit_a: float = 0.0
var _hint: int = -1
var _rng := RandomNumberGenerator.new()
var _smooth_look: Vector3 = Vector3.ZERO
var _smooth_pos: Vector3 = Vector3.ZERO
var _fresh: bool = true


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	near = 0.1
	far = 12000.0
	fov = 62.0
	_rng.seed = 7


func start_menu(new_car: Car, new_track: Track) -> void:
	car = new_car
	track = new_track
	mode = Mode.MENU
	_hint = -1
	_shot_i = _rng.randi_range(0, MENU_SHOTS.size() - 1)
	_next_shot()
	make_current()


## Swoop from a high establishing view in front of the car down to the chase pose.
func play_intro(new_car: Car, duration: float) -> void:
	car = new_car
	mode = Mode.INTRO
	_t = 0.0
	_dur = duration
	_intro(0.0)
	make_current()


## Slow orbit around the car (after the finish line), starting from the current view.
func start_finish(new_car: Car) -> void:
	car = new_car
	mode = Mode.FINISH
	var rel := global_position - car.get_global_transform_interpolated().origin
	_orbit_a = atan2(rel.x, rel.z)
	_fresh = true
	make_current()


func stop() -> void:
	mode = Mode.IDLE


func _process(delta: float) -> void:
	if car == null or not is_instance_valid(car):
		return
	var real_delta := delta / maxf(Engine.time_scale, 0.001)
	match mode:
		Mode.MENU:
			_menu(real_delta)
		Mode.INTRO:
			_intro(real_delta)
		Mode.FINISH:
			_finish(real_delta)


# ------------------------------------------------------------------ intro

func _intro(delta: float) -> void:
	_t += delta
	var k := clampf(_t / _dur, 0.0, 1.0)
	var e := _ease_in_out(k)
	var xf := car.get_global_transform_interpolated()
	var b := Basis(Vector3.UP, xf.basis.get_euler().y)
	# Bezier in car space: high in front, a wide arc on the left, down into the chase pose.
	var p := _bezier(Vector3(-9.0, 14.0, -24.0), Vector3(-16.0, 5.0, -6.0), Vector3(-6.0, 1.4, 9.0), chase_offset, e)
	var look := _bezier(Vector3(0.0, 0.6, 0.0), Vector3(0.0, 0.7, 0.0), Vector3(0.0, 0.9, -1.5), chase_look, e)
	var pos := xf.origin + b * p
	pos.y = maxf(pos.y, _ground(pos) + 0.4)
	global_position = pos
	look_at(xf.origin + b * look, Vector3.UP)
	fov = lerpf(50.0, 70.0, e)
	if k >= 1.0 and mode == Mode.INTRO:
		mode = Mode.IDLE
		intro_finished.emit()


# ------------------------------------------------------------------ finish orbit

func _finish(delta: float) -> void:
	var xf := car.get_global_transform_interpolated()
	_orbit_a += delta * 0.32
	var target := xf.origin + Vector3(sin(_orbit_a) * 7.0, 1.7, cos(_orbit_a) * 7.0)
	target.y = maxf(target.y, _ground(target) + 0.8)
	if _fresh:
		_smooth_pos = global_position
		_fresh = false
	_smooth_pos = _smooth_pos.lerp(target, 1.0 - exp(-delta * 2.5))
	global_position = _smooth_pos
	look_at(xf.origin + Vector3.UP * 0.8, Vector3.UP)
	fov = lerpf(fov, 48.0, 1.0 - exp(-delta * 1.5))


# ------------------------------------------------------------------ menu flyover

func _next_shot() -> void:
	_shot_i = (_shot_i + 1) % MENU_SHOTS.size()
	_shot = MENU_SHOTS[_shot_i]
	_shot_t = 0.0
	_side = -1.0 if _rng.randf() < 0.5 else 1.0
	_fresh = true
	var s := _car_s()
	match _shot:
		"roadside":
			_anchor_s = s + 70.0
			_anchor = _roadside_point(_anchor_s, _side * 6.5, 1.1)
		"scenic":
			_anchor_s = s + 110.0
			_anchor = _roadside_point(_anchor_s, _side * 38.0, 14.0)
	fov = 55.0 if _shot in ["roadside", "scenic"] else 60.0


func _car_s() -> float:
	if track == null:
		return 0.0
	_hint = track.nearest(car.global_position, _hint)
	return track.abs_s(_hint, car.global_position)


## Metres the car is past road distance s (negative before it), across the lap seam.
func _past(s: float) -> float:
	return wrapf(_car_s() - s, -track.length * 0.5, track.length * 0.5)


func _roadside_point(s: float, lat: float, h: float) -> Vector3:
	var p := track.position_at_abs(s, lat)
	p.y = maxf(p.y, _ground(p)) + h
	return p


func _menu(delta: float) -> void:
	_shot_t += delta
	var xf := car.get_global_transform_interpolated()
	var fwd := -xf.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length_squared() > 0.01 else Vector3.FORWARD
	var right := fwd.cross(Vector3.UP)
	var c := xf.origin
	var pos := global_position
	var look := c + Vector3.UP * 0.8
	var length := 7.0
	match _shot:
		"tracking":
			pos = c + right * (_side * 6.5) + fwd * (1.5 + sin(_shot_t * 0.3) * 1.5) + Vector3.UP * 1.1
		"front":
			pos = c + fwd * 8.5 + right * (_side * 1.6) + Vector3.UP * 0.9
			look = c + Vector3.UP * 0.7
		"wheel":
			pos = c + right * (_side * 2.3) + fwd * 1.6 + Vector3.UP * 0.35
			look = c - fwd + Vector3.UP * 0.5
			length = 5.0
		"drone":
			var a := _shot_t * 0.18
			pos = c + (right * cos(a) + fwd * sin(a)) * 26.0 * _side + Vector3.UP * 22.0
			length = 8.0
		"roadside":
			pos = _anchor
			if _past(_anchor_s) > 30.0 or _shot_t > 14.0:
				_next_shot()
				return
		"scenic":
			pos = _anchor
			if _past(_anchor_s) > 70.0 or _shot_t > 16.0:
				_next_shot()
				return
	if _shot_t > length and not _shot in ["roadside", "scenic"]:
		_next_shot()
		return
	pos.y = maxf(pos.y, _ground(pos) + 0.3)
	if _fresh:
		_smooth_pos = pos
		_smooth_look = look
		_fresh = false
	_smooth_pos = _smooth_pos.lerp(pos, 1.0 - exp(-delta * 6.0))
	_smooth_look = _smooth_look.lerp(look, 1.0 - exp(-delta * 8.0))
	global_position = _smooth_pos
	if global_position.distance_squared_to(_smooth_look) > 0.01:
		look_at(_smooth_look, Vector3.UP)


# ------------------------------------------------------------------ helpers

func _ground(p: Vector3) -> float:
	var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 60.0, p + Vector3.DOWN * 200.0, MapWorld.LAYER_WORLD)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit["position"].y if hit else p.y - 1.0


static func _bezier(a: Vector3, b: Vector3, c: Vector3, d: Vector3, t: float) -> Vector3:
	var u := 1.0 - t
	return a * u * u * u + b * 3.0 * u * u * t + c * 3.0 * u * t * t + d * t * t * t


static func _ease_in_out(x: float) -> float:
	return 4.0 * x * x * x if x < 0.5 else 1.0 - pow(-2.0 * x + 2.0, 3.0) / 2.0
