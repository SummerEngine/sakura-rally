class_name CineCamera
extends Camera3D
## Cinematic camera for everything that is not driving: the title-screen flyover
## (a cycle of shots around the autopilot car), the race intro swoop that lands
## in the chase pose, the slow orbit behind the results card and the garage's low
## showroom orbit around the parked car.
## Follows the car's interpolated transform in _process, in real time (ignores
## Engine.time_scale), and keeps running while the tree is paused.

signal intro_finished

enum Mode { IDLE, MENU, INTRO, FINISH, GARAGE }

const MENU_SHOTS: Array[String] = ["tracking", "roadside", "drone", "front", "scenic", "wheel"]
## Garage orbit: closest distance, lens height and look height above the car's origin, angular
## speed, lens.
const GARAGE_RADIUS := 6.4
const GARAGE_HEIGHT := 1.15
const GARAGE_LOOK := 0.55
const GARAGE_SPEED := 0.11
const GARAGE_FOV := 36.0
## Horizontal screen position of the parked car (NDC, 0 = centre): right of the garage panel.
const GARAGE_SCREEN_X := 0.3
## Half the car's length plus some air: the orbit backs off until this fits between the car's
## screen position and the right edge, so a long car seen side-on stays in frame on narrow screens.
const GARAGE_HALF_SPAN := 2.7


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
## Seconds the car has been out of sight of the roadside / scenic camera (terrain in between).
var _hidden_t: float = 0.0
var _rng := RandomNumberGenerator.new()
var _smooth_c: Vector3 = Vector3.ZERO
var _smooth_fwd: Vector3 = Vector3.FORWARD
var _lift: float = 0.0
var _smooth_pos: Vector3 = Vector3.ZERO
var _fresh: bool = true
## Garage orbit: angle (car space, 0 = straight ahead of the car) and the clear arc it swings
## through ([centre, half width]; half width >= PI = free to circle).
var _garage_a: float = 0.0
var _garage_arc: Vector2 = Vector2(0.0, PI)
var _garage_t: float = 0.0


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


## Cuts to one flyover shot now and keeps cycling from it (the demo reel's director).
## `side`: +1 right / -1 left of the car (or of the road for roadside / scenic).
## `anchor_s`: road distance of the roadside / scenic camera; NAN = ahead of the car.
func cut_to(new_car: Car, new_track: Track, shot: String, side: float, anchor_s: float = NAN) -> void:
	car = new_car
	track = new_track
	mode = Mode.MENU
	_begin_shot(MENU_SHOTS.find(shot), side, anchor_s)
	make_current()


## Low showroom orbit around a parked car. Circles from the front three-quarter view when the
## ground around the car is clear, otherwise swings through the widest clear arc (props,
## terrain, line of sight). Call again with the respawned car after a car switch; the orbit
## carries on.
func start_garage(new_car: Car) -> void:
	var fresh := mode != Mode.GARAGE
	car = new_car
	mode = Mode.GARAGE
	if fresh:
		_garage_arc = _clear_arc()
		_garage_t = 0.0
		_fresh = true
	make_current()


func stop() -> void:
	mode = Mode.IDLE


func _process(delta: float) -> void:
	# Only the garage frames off-centre.
	if mode != Mode.GARAGE:
		h_offset = 0.0
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
		Mode.GARAGE:
			_garage(real_delta)


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


# ------------------------------------------------------------------ garage orbit

## Orbit angle `a` (radians, car space: 0 = ahead of the car, positive = towards its left) to a
## world position around the parked car at `xf`.
func _garage_pos(xf: Transform3D, a: float, radius: float) -> Vector3:
	var b := Basis(Vector3.UP, xf.basis.get_euler().y)
	return xf.origin + b * Vector3(-sin(a) * radius, GARAGE_HEIGHT, -cos(a) * radius)


## Widest run of orbit angles (10° steps) whose camera spot is clear of props with a clear line
## to the car and above the ground. Returns (centre, half width); PI when every angle is clear.
func _clear_arc() -> Vector2:
	var xf := car.global_transform
	var space := get_world_3d().direct_space_state
	var room := PhysicsShapeQueryParameters3D.new()
	var ball := SphereShape3D.new()
	ball.radius = 1.1
	room.shape = ball
	room.collision_mask = MapWorld.LAYER_PROPS
	var steps := 36
	var clear: Array[bool] = []
	var target := xf.origin + Vector3.UP * GARAGE_LOOK
	for i in steps:
		var p := _garage_pos(xf, TAU * i / steps, _garage_radius())
		room.transform = Transform3D(Basis.IDENTITY, p)
		var ok := space.intersect_shape(room, 1).is_empty() and _ground(p) < p.y - 0.45
		if ok:
			var q := PhysicsRayQueryParameters3D.create(p, target, MapWorld.LAYER_WORLD | MapWorld.LAYER_PROPS)
			q.exclude = [car.get_rid()]
			ok = space.intersect_ray(q).is_empty()
		clear.append(ok)
	if not clear.has(false):
		return Vector2(deg_to_rad(35.0), PI)
	# Longest circular run of clear steps.
	var best_start := 0
	var best_len := 0
	for s in steps:
		if clear[s] and not clear[(s - 1 + steps) % steps]:
			var n := 0
			while n < steps and clear[(s + n) % steps]:
				n += 1
			if n > best_len:
				best_len = n
				best_start = s
	if best_len == 0:
		return Vector2(deg_to_rad(35.0), 0.0)
	var step := TAU / steps
	return Vector2((best_start + (best_len - 1) * 0.5) * step, maxf(best_len - 1, 0) * 0.5 * step)


func _garage(delta: float) -> void:
	_garage_t += delta
	var xf := car.get_global_transform_interpolated()
	var half := _garage_arc.y
	if half >= PI:
		_garage_a = _garage_arc.x + _garage_t * GARAGE_SPEED
	elif half > 0.01:
		# Swing through the clear arc, easing at its ends (peak speed GARAGE_SPEED).
		_garage_a = _garage_arc.x + half * sin(_garage_t * GARAGE_SPEED / half)
	else:
		_garage_a = _garage_arc.x
	var radius := _garage_radius()
	var pos := _garage_pos(xf, _garage_a, radius)
	pos.y = maxf(pos.y, _ground(pos) + 0.5)
	global_position = pos
	look_at(xf.origin + Vector3.UP * GARAGE_LOOK, Vector3.UP)
	fov = GARAGE_FOV
	# Shift the frame so the car sits right of centre, clear of the garage panel on the left.
	h_offset = -GARAGE_SCREEN_X * _garage_half_width() * radius
	_fresh = false


## Half the view width per metre of distance at the garage lens.
func _garage_half_width() -> float:
	return tan(deg_to_rad(GARAGE_FOV) * 0.5) * get_viewport().get_visible_rect().size.aspect()


func _garage_radius() -> float:
	return maxf(GARAGE_RADIUS, GARAGE_HALF_SPAN / ((1.0 - GARAGE_SCREEN_X) * _garage_half_width()))


# ------------------------------------------------------------------ menu flyover

func _next_shot() -> void:
	_begin_shot((_shot_i + 1) % MENU_SHOTS.size(), -1.0 if _rng.randf() < 0.5 else 1.0, NAN)


func _begin_shot(i: int, side: float, anchor_s: float) -> void:
	_shot_i = i
	_shot = MENU_SHOTS[i]
	_shot_t = 0.0
	_side = side
	_fresh = true
	_hidden_t = 0.0
	var s := _car_s()
	match _shot:
		"roadside":
			_anchor_s = s + 70.0 if is_nan(anchor_s) else anchor_s
			# A showoff autopilot slides the corners: stand at the next slid one when it is near.
			# Searched around the car, so a switchback's other leg cannot claim the apex.
			if is_nan(anchor_s):
				var apex := _next_slide_point()
				if apex.is_finite():
					_anchor_s = track.abs_s(track.nearest(apex, _hint, ceili(140.0 / track.spacing)), apex)
			# Map generation bakes marker posts and chevron boards (no colliders, so _clear_anchor
			# cannot see them) along the outside of every bend: on a bend the camera takes the inside.
			var turn := _turn_at(_anchor_s)
			if absf(turn) > deg_to_rad(10.0):
				_side = -signf(turn)
			# The camera must see the whole approach, from where the car is now.
			var sights: Array = [-40.0, -25.0, -12.0, 0.0, 12.0, 24.0]
			var ahead := -_past(_anchor_s)
			var d := -55.0
			while d > -ahead:
				sights.push_front(d)
				d -= 15.0
			_anchor = _clear_anchor(_anchor_s, _side * 6.5, 1.1, 5.0, sights)
		"scenic":
			_anchor_s = s + 110.0 if is_nan(anchor_s) else anchor_s
			_anchor = _clear_anchor(_anchor_s, _side * 38.0, 14.0, 12.0, [-60.0, -35.0, -10.0, 15.0, 40.0])
	fov = 55.0 if _shot in ["roadside", "scenic"] else 60.0


## World point of the next corner the car's autopilot slides, 40-120 m ahead (Vector3.INF if none).
func _next_slide_point() -> Vector3:
	for n in car.get_children():
		if n is Autopilot:
			return (n as Autopilot).next_slide_point(40.0, 120.0)
	return Vector3.INF


## Road distance of the car.
func _car_s() -> float:
	if track == null:
		return 0.0
	_track_car()
	return track.abs_s(_hint, car.global_position)


## Keeps `_hint`, the car's nearest track sample, on the car. `Track.nearest` only searches 40
## samples (80 m) around the hint, so it runs every menu frame; a car that is out of the window
## anyway (a reset, a respawn, a cut in from another mode) gets a full search.
func _track_car() -> void:
	var p := car.global_position
	_hint = track.nearest(p, _hint)
	var q := track.point(_hint)
	if Vector2(q.x - p.x, q.z - p.z).length() > 30.0:
		_hint = track.nearest(p)


## Seconds the car has been hidden from a camera at `pos` by the terrain. Props are not tested:
## the spot was picked with clear lines past them, and a tree in between only covers the car briefly.
func _hidden_for(pos: Vector3, delta: float) -> float:
	var q := PhysicsRayQueryParameters3D.create(pos, car.global_position + Vector3.UP * 1.0, MapWorld.LAYER_WORLD)
	q.exclude = [car.get_rid()]
	if get_world_3d().direct_space_state.intersect_ray(q).is_empty():
		_hidden_t = 0.0
	else:
		_hidden_t += delta
	return _hidden_t


## Metres the car is past road distance s (negative before it), across the lap seam.
func _past(s: float) -> float:
	return wrapf(_car_s() - s, -track.length * 0.5, track.length * 0.5)


func _roadside_point(s: float, lat: float, h: float) -> Vector3:
	var p := track.position_at_abs(s, lat)
	p.y = maxf(p.y, _ground(p)) + h
	return p


## Heading change of the road over the 30 m around distance s (radians, + = turning left).
func _turn_at(s: float) -> float:
	var a := track.forward_at_abs(s - 15.0)
	var b := track.forward_at_abs(s + 15.0)
	return atan2(a.cross(b).y, a.dot(b))


## A roadside / scenic camera spot near road distance s (lateral lat, height h) that keeps props
## (tyre stacks, fences, spectators, gate pillars) out of the picture and sees the road at every
## `sights` offset from s. Each sight is a direction the shot looks while the car goes by, so the
## near 7 m of the view toward it must hold no prop, and the line to it must be open. Tries spots
## shifted along the road by `step`, wider, then higher; falls back to the spot that passes the
## most checks.
func _clear_anchor(s: float, lat: float, h: float, step: float, sights: Array) -> Vector3:
	var space := get_world_3d().direct_space_state
	var room := PhysicsShapeQueryParameters3D.new()
	var ball := SphereShape3D.new()
	ball.radius = 2.5 # tree trunk colliders are as tall as the tree: this keeps out of canopies too
	room.shape = ball
	room.collision_mask = MapWorld.LAYER_PROPS
	# The near part of the frame: a pyramid from the lens, 7 m deep, 85% of the 16:9 view at fov 55.
	var view := PhysicsShapeQueryParameters3D.new()
	var cone := ConvexPolygonShape3D.new()
	var hh := 7.0 * tan(deg_to_rad(55.0) * 0.5) * 0.85
	var hw := hh * 16.0 / 9.0
	cone.points = PackedVector3Array([Vector3.ZERO, Vector3(-hw, -hh, -7.0), Vector3(hw, -hh, -7.0),
			Vector3(hw, hh, -7.0), Vector3(-hw, hh, -7.0)])
	view.shape = cone
	view.collision_mask = MapWorld.LAYER_PROPS
	var targets: Array[Vector3] = []
	for d: float in sights:
		targets.append(track.position_at_abs(s + d) + Vector3.UP * 1.0)
	var best := _roadside_point(s, lat, h)
	var best_score := -1
	for dh: float in [1.0, 1.6]:
		for ds: float in [0.0, -1.0, 1.0, -2.0, 2.0, -3.0, 3.0]:
			for k: float in [1.0, 1.3, 1.6, 2.0]:
				var p := _roadside_point(s + ds * step, lat * k, h * dh)
				room.transform = Transform3D(Basis.IDENTITY, p)
				if not space.intersect_shape(room, 1).is_empty():
					continue
				var score := 0
				for t in targets:
					view.transform = Transform3D(Basis.looking_at(t - p, Vector3.UP), p)
					if space.intersect_shape(view, 1).is_empty():
						score += 1
					var q := PhysicsRayQueryParameters3D.create(p, t, MapWorld.LAYER_WORLD | MapWorld.LAYER_PROPS)
					if space.intersect_ray(q).is_empty():
						score += 1
				if score == targets.size() * 2:
					return p
				if score > best_score:
					best_score = score
					best = p
	return best


## Follow frame of the car-relative shots. The origin is predicted from the car's velocity and
## corrected toward its interpolated transform, so it filters bumps without trailing at speed (a
## plain lerp lags v / rate metres, ~4.7 m at 100 km/h, which slid the wheel close-up off the car).
## The heading is the direction of travel, so a drift shows its angle against the frame; the wheel
## shot follows the body instead so its wheel stays framed.
func _follow(xf: Transform3D, delta: float) -> void:
	var head := -xf.basis.z
	var v := car.linear_velocity
	v.y = 0.0
	if _shot != "wheel" and v.length() > 3.0:
		head = v
	head.y = 0.0
	head = head.normalized() if head.length_squared() > 0.0001 else Vector3.FORWARD
	if _fresh:
		_smooth_c = xf.origin
		_smooth_fwd = head
		return
	_smooth_c += car.linear_velocity * Engine.time_scale * delta
	_smooth_c = _smooth_c.lerp(xf.origin, 1.0 - exp(-delta * 10.0))
	_smooth_fwd = _smooth_fwd.slerp(head, 1.0 - exp(-delta * (8.0 if _shot == "wheel" else 3.0))).normalized()


func _menu(delta: float) -> void:
	_shot_t += delta
	if track != null:
		_track_car()
	_follow(car.get_global_transform_interpolated(), delta)
	var fwd := _smooth_fwd
	var right := fwd.cross(Vector3.UP)
	var c := _smooth_c
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
			if _past(_anchor_s) > 30.0 or _shot_t > 14.0 or _hidden_for(pos, delta) > 0.8:
				_next_shot()
				return
		"scenic":
			pos = _anchor
			if _past(_anchor_s) > 70.0 or _shot_t > 16.0 or _hidden_for(pos, delta) > 0.8:
				_next_shot()
				return
	if _shot_t > length and not _shot in ["roadside", "scenic"]:
		_next_shot()
		return
	# Never below the ground: lift at once, settle back slowly.
	var need := maxf(0.0, _ground(pos) + 0.3 - pos.y)
	_lift = need if _fresh else maxf(need, lerpf(_lift, need, 1.0 - exp(-delta * 4.0)))
	pos.y += _lift
	_fresh = false
	global_position = pos
	if pos.distance_squared_to(look) > 0.01:
		look_at(look, Vector3.UP)


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
