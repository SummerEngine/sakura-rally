class_name DriveSense
extends RefCounted
## What the neural driver perceives, identical in training (tools/rl/train_env.gd) and in the
## game (scripts/ai/neural_pilot.gd). Only what a driver sees and feels, as in the Trackmania and
## Gran Turismo Sophy agents (docs/RL.md):
##
##   rays     9 distances from the car to the edge of the drivable road (carriageway plus verge),
##            fanned from 90° left to 90° right of the nose on the ground plane, / RAY_LENGTH
##   road     where the road goes: the centre line AHEAD_M metres further along it, each point as
##            (right, ahead) in the car's ground frame divided by its distance (a unit-ish bearing)
##   motion   forward and sideways speed, yaw rate, share of wheels on the ground and on loose
##            ground (gravel, dirt, grass)
##   hands    the steering, throttle, brake and handbrake the driver is holding
##
## Nothing else: no racing line, checkpoints, progress, track identity, tyre or engine state.
## Both the rays and the road points come from `track` (the route's centre-line samples and half
## widths), not from colliders, so grass, trees and walls all look alike: "not road".
##
## Race lanes (scripts/ai/race_bot.gd): with `lane_half_width` > 0 the driver sees a narrower road
## of that carriageway half width (plus the real verge) whose centre line runs `lane` metres right
## of the real one, clamped per sample so it never reaches past the real carriageway. The network
## trained on 7 m roads only; on a wider road this keeps what it sees familiar and puts it on one
## side. 0 (training, auto-drive, ghosts): the real road, computed exactly as before.

## Bump when the layout of observe() changes; exported policies carry the version they expect.
const VERSION := 1
const RAY_ANGLES_DEG: Array[float] = [-90.0, -50.0, -25.0, -10.0, 0.0, 10.0, 25.0, 50.0, 90.0]
const RAY_COUNT := 9
const RAY_LENGTH := 60.0
const AHEAD_M: Array[float] = [5.0, 10.0, 15.0, 20.0, 30.0, 40.0, 55.0, 70.0, 90.0, 110.0, 135.0, 160.0, 190.0, 220.0]
const AHEAD_COUNT := 14
const MOTION := 5
const HANDS := 4
const OBS_SIZE := RAY_COUNT + AHEAD_COUNT * 2 + MOTION + HANDS
## Road samples (Track.spacing apart, 2 m) whose edges the rays are tested against.
const BACK_SAMPLES := 4
const AHEAD_SAMPLES := 36
## Samples searched around the last nearest one per call (continuity across switchbacks).
const SEARCH_WINDOW := 24
## Scales that bring the motion features to about -1..1.
const SPEED_SCALE := 50.0
const SIDE_SCALE := 10.0
const YAW_SCALE := 2.0

var track: Track
## Nearest road sample to the car at the last observe() (-1 = search the whole road).
var hint: int = -1
## Ray distances (m) from the last observe(), for debug drawing.
var rays := PackedFloat32Array()
## Virtual road for racing (see above): carriageway half width (0 = the real road) and its centre
## line's offset right of the real one (m).
var lane_half_width: float = 0.0
var lane: float = 0.0

var _ray_x := PackedFloat32Array()
var _ray_z := PackedFloat32Array()
var _ray_a := PackedFloat32Array()
## First ray whose angle is >= each whole degree from -180 to 180 (RAY_COUNT when none). Exact
## because every ray sits on a whole degree.
var _first_ray := PackedInt32Array()
var _ex := PackedFloat32Array()
var _ez := PackedFloat32Array()
var _ea := PackedFloat32Array()


func _init(road: Track = null) -> void:
	track = road
	rays.resize(RAY_COUNT)
	_ray_x.resize(RAY_COUNT)
	_ray_z.resize(RAY_COUNT)
	_ray_a.resize(RAY_COUNT)
	for k in RAY_COUNT:
		var a := deg_to_rad(RAY_ANGLES_DEG[k])
		_ray_a[k] = a
		_ray_x[k] = sin(a)
		_ray_z[k] = cos(a)
	_first_ray.resize(361)
	var k := 0
	for d in 361:
		while k < RAY_COUNT and RAY_ANGLES_DEG[k] < float(d - 180):
			k += 1
		_first_ray[d] = k
	var n := (BACK_SAMPLES + AHEAD_SAMPLES + 1) * 2
	_ex.resize(n)
	_ez.resize(n)
	_ea.resize(n)


## Forget the car's place on the road (after a teleport); `s` is the new absolute distance along
## the road when known.
func reset(s: float = NAN) -> void:
	hint = -1 if is_nan(s) else track.index_at_abs(s)


## Writes OBS_SIZE floats for `car` into `out` from `offset`.
func observe(car: Car, out: PackedFloat32Array, offset: int = 0) -> void:
	var pos := car.global_position
	var basis := car.global_basis
	var fwd := -basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length_squared() > 1e-6 else Vector3.FORWARD
	var right := Vector3(-fwd.z, 0.0, fwd.x)
	hint = track.nearest(pos, hint, SEARCH_WINDOW)
	_cast_rays(pos, fwd, right)
	for k in RAY_COUNT:
		out[offset + k] = rays[k] / RAY_LENGTH
	var o := offset + RAY_COUNT
	var s := track.abs_s(hint, pos)
	for k in AHEAD_COUNT:
		var d := AHEAD_M[k]
		var p := _centre_at(s + d)
		var dx := p.x - pos.x
		var dz := p.y - pos.z
		out[o] = (dx * right.x + dz * right.z) / d
		out[o + 1] = (dx * fwd.x + dz * fwd.z) / d
		o += 2
	# Velocities from the body itself (a car placed this tick has them zeroed already, while
	# Car.local_velocity is only refreshed by its next physics step).
	var lv := basis.inverse() * car.linear_velocity
	out[o] = -lv.z / SPEED_SCALE
	out[o + 1] = lv.x / SIDE_SCALE
	out[o + 2] = car.angular_velocity.dot(basis.y) / YAW_SCALE
	out[o + 3] = car.grounded_wheels / 4.0
	var loose := 0
	for w: WheelState in car.wheels:
		if w.contact and TyreModel.get_surface(w.surface).loose:
			loose += 1
	out[o + 4] = loose / 4.0
	out[o + 5] = car.input_steer
	out[o + 6] = car.input_throttle
	out[o + 7] = car.input_brake
	out[o + 8] = 1.0 if car.input_handbrake else 0.0


## Absolute distance along the road (Track.abs_s) and signed offset from the centre line (+ right)
## of `pos` at the sample of the last observe().
func road_s(pos: Vector3) -> float:
	return track.abs_s(_hint_or_search(pos), pos)


func road_lateral(pos: Vector3) -> float:
	return track.lateral(_hint_or_search(pos), pos)


## Half width of the drivable road (carriageway plus verge) at the sample of the last observe().
func road_edge() -> float:
	return track.half_width(maxi(hint, 0)) + track.verge


func _hint_or_search(pos: Vector3) -> int:
	if hint < 0:
		hint = track.nearest(pos)
	return hint


## Centre line (x, z) at absolute distance s, like Track.position_at_abs on the ground plane; on a
## virtual road the lane's centre line.
func _centre_at(s: float) -> Vector2:
	var data := track.data
	var f: float
	if track.closed:
		f = fposmod(s, track.length) / track.spacing
	else:
		f = (clampf(s, track.first_s, track.last_s) - track.first_s) / track.spacing
	var i := int(f)
	var t := f - i
	var a: int
	var b: int
	if track.closed:
		a = wrapi(i, 0, track.count) * Track.COLS
		b = wrapi(i + 1, 0, track.count) * Track.COLS
	else:
		i = mini(i, track.count - 2)
		t = f - i
		a = i * Track.COLS
		b = a + Track.COLS
	var p := Vector2(lerpf(data[a], data[b], t), lerpf(data[a + 2], data[b + 2], t))
	if lane_half_width > 0.0 and lane != 0.0:
		var room := maxf(lerpf(data[a + 5], data[b + 5], t) - lane_half_width, 0.0)
		var fx := lerpf(data[a + 3], data[b + 3], t)
		var fz := lerpf(data[a + 4], data[b + 4], t)
		p += Vector2(-fz, fx) * (clampf(lane, -room, room) / sqrt(fx * fx + fz * fz))
	return p


## Both edges of the drivable road around the car, in the car's ground frame (x right, z ahead),
## each vertex with its bearing; every edge segment then shortens the rays that pass through its
## bearing span.
func _cast_rays(pos: Vector3, fwd: Vector3, right: Vector3) -> void:
	var data := track.data
	var cols := Track.COLS
	var count := track.count
	var closed := track.closed
	var verge := track.verge
	var n := BACK_SAMPLES + AHEAD_SAMPLES + 1
	for m in n:
		var i := hint - BACK_SAMPLES + m
		i = wrapi(i, 0, count) if closed else clampi(i, 0, count - 1)
		var o := i * cols
		var cx := data[o] - pos.x
		var cz := data[o + 2] - pos.z
		# Track.right() is (-forward.z, 0, forward.x); the edges lie lo and hi metres along it
		var hw := data[o + 5]
		var lo := -hw - verge
		var hi := hw + verge
		if lane_half_width > 0.0:
			var room := maxf(hw - lane_half_width, 0.0)
			var c := clampf(lane, -room, room)
			var vhw := minf(lane_half_width, hw)
			lo = c - vhw - verge
			hi = c + vhw + verge
		var rx := -data[o + 4]
		var rz := data[o + 3]
		var lx := cx + rx * lo
		var lz := cz + rz * lo
		var ux := cx + rx * hi
		var uz := cz + rz * hi
		# left edge in slot m, right edge in slot n + m
		var ax := lx * right.x + lz * right.z
		var az := lx * fwd.x + lz * fwd.z
		_ex[m] = ax
		_ez[m] = az
		_ea[m] = atan2(ax, az)
		var bx := ux * right.x + uz * right.z
		var bz := ux * fwd.x + uz * fwd.z
		_ex[n + m] = bx
		_ez[n + m] = bz
		_ea[n + m] = atan2(bx, bz)
	for k in RAY_COUNT:
		rays[k] = RAY_LENGTH
	var reach := (RAY_LENGTH + 4.0) * (RAY_LENGTH + 4.0)
	for side in 2:
		var base := side * n
		for m in n - 1:
			var p := base + m
			var ax := _ex[p]
			var az := _ez[p]
			var bx := _ex[p + 1]
			var bz := _ez[p + 1]
			# every ray points into z >= 0; a segment wholly behind the car or out of reach misses
			if az < 0.0 and bz < 0.0:
				continue
			if ax * ax + az * az > reach and bx * bx + bz * bz > reach:
				continue
			var a0 := _ea[p]
			var a1 := _ea[p + 1]
			if absf(a1 - a0) > PI:
				continue # straddles the bearing straight behind the car
			var lo := minf(a0, a1)
			var hi := maxf(a0, a1)
			var dx := bx - ax
			var dz := bz - az
			var k := _first_ray[clampi(int(ceil(rad_to_deg(lo))) + 180, 0, 360)]
			while k < RAY_COUNT and _ray_a[k] <= hi:
				var den := _ray_x[k] * dz - _ray_z[k] * dx
				if absf(den) > 1e-6:
					var t := (ax * dz - az * dx) / den
					if t > 0.0 and t < rays[k]:
						rays[k] = t
				k += 1
