class_name Autopilot
extends Node
## AI driver for the parent Car: follows a racing line (Curve3D) with pure-pursuit steering and a
## grip-aware speed profile (curvature limit + braking-distance planning). Used for the menu
## background, the demo video and the physics tests.
##
## Give it either `path` (a Path3D, world transform taken from the node) or `curve` +
## `curve_transform`. The line is treated as closed when `closed` is true; an open line (a
## liaison road) is followed from its start to its end, where the car brakes to a stop.
##
## `style` picks how it drives:
##   &"tidy"     (default) grip driving with margin, lifts when the car slides. The physics tests,
##               the liaison roll-out, the finish cruise and the tool flows use it.
##   &"showoff"  the menu flyover and the demo reel: a committed pace with later, harder
##               straight-line braking and no brake dabs between corners; every real corner is
##               driven sideways. The car sets up on the outside, a lift-off flick (open loose
##               corners) or a handbrake stab (tarmac, tight loose corners) turns it in, throttle
##               and countersteer hold the slide, and part throttle near the exit catches it and
##               powers it out. Loose corners get long slides; tarmac gets short ones. A slip
##               guard catches the car before it spins, and a corner with a wall, rail or tree
##               close to the line is driven on grip. tools/showoff/drift_probe.gd measures it.
##
## The controls go out through `_apply()`, which a subclass can override (the keyboard bot in
## tools/physics/keyboard_bot.gd turns them into digital key presses). The showoff handbrake goes
## straight to the car beside it.

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
## of the surface mu on a skidpad; 0.68 in corners keeps ~25 % in hand for following the line on
## narrow loose roads (and leaves the keyboard bot the same margin on the same profile).
@export var corner_grip: float = 0.68
@export var brake_grip: float = 0.72
## Pure-pursuit lookahead: base metres + seconds of travel, clamped.
@export var lookahead_base: float = 5.0
@export var lookahead_time: float = 0.3
@export var lookahead_min: float = 7.0
@export var lookahead_max: float = 30.0
## Running wide: beyond `line_tolerance` metres off the line the target speed drops by
## `wide_slowdown` per metre (down to 60 %), the way a driver lifts when the car drifts out.
@export var line_tolerance: float = 2.0
@export var wide_slowdown: float = 0.05

@export_group("Showoff")
## Driving style: &"tidy" or &"showoff" (see the header).
@export var style: StringName = &"tidy"
## Grip fractions of the showoff speed profile (instead of corner_grip / brake_grip).
@export var show_corner_grip: float = 0.8
@export var show_brake_grip: float = 0.86
## ...in the fast loose-surface sweepers (profile speed above `show_sweeper_kmh`), held on grip:
## past this the car washes wide.
@export var show_corner_grip_loose: float = 0.7
@export var show_sweeper_kmh: float = 90.0
## ...under braking on loose surfaces (the tyres dig in and the ABS works harder: less bite).
@export var show_brake_grip_loose: float = 0.6
## A stretch of line tighter than this radius (m) is a corner; it is driven sideways when it
## turns the car at least `slide_min_turn_deg` and its tightest radius is under the surface's
## slide radius (tarmac corners are only slid when tight, loose ones nearly always).
@export var corner_radius: float = 110.0
@export var slide_min_turn_deg: float = 25.0
@export var slide_radius_tarmac: float = 100.0
@export var slide_radius_loose: float = 140.0
## Slid corners are driven at up to this multiple of their slowest point's speed, from 8 m before
## the turn-in to their end.
@export var slide_speed_factor: float = 1.08
## A corner with a wall, rail or tree this close to the line (m, either side, from 10 m before
## to 10 m after it) is driven on grip.
@export var slide_wall_clearance: float = 5.0
## The car sets up for a slid corner this far (m) towards its outside, from 1.5 s before the
## turn-in until the slide starts, so the slide's drift towards the inside ends on the road.
@export var slide_setup_offset: float = 1.2
## Turn-in: the flick starts this many seconds of travel before the corner tightens.
@export var flick_lead_time: float = 0.25
## Handbrake stab length (s) on tarmac and on loose surfaces. The car's drift intent grows with
## the time on the handbrake, so the stab sets how big the slide gets.
@export var stab_tarmac: float = 0.1
@export var stab_loose: float = 0.15
## Loose corners at least this wide (radius, m) turn in on a lift-off flick: full lock off the
## throttle for `lift_flick_time` s, a handbrake stab only if the car has not rotated by then.
@export var lift_flick_radius: float = 25.0
@export var lift_flick_time: float = 0.3
## The slide is caught (part throttle, the wheel on the line) this share of the corner's turn
## before its end: tarmac slides are short, loose ones run to the exit.
@export var exit_share_tarmac: float = 0.25
@export var exit_share_loose: float = 0.0
## Slip guard (deg): the slide is caught past this angle, or 14° past the wanted one.
@export var slip_guard: float = 45.0
## Body slip (deg) the slide is held at on tarmac and on loose surfaces.
@export var slide_slip_tarmac: float = 20.0
@export var slide_slip_loose: float = 32.0
## ...and at most this many degrees per degree of the corner's turn.
@export var slide_slip_per_turn: float = 0.4
## The slide is let go when the car will be this far inside the line (m) 0.15 s on, or this far
## outside it 0.3 s on.
@export var slide_inside_limit: float = 2.6
@export var slide_outside_limit: float = 2.0

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
var _spacing: float = STEP
var _loose_cache: PackedByteArray = PackedByteArray()
var _gravity: float = 9.8

# Showoff: corner table and slide state.
enum Phase { STRAIGHT, FLICK, SLIDE, EXIT }
## Per sample: index into _corners, or -1 on a straight / a corner driven on grip.
var _corner_of: PackedInt32Array = PackedInt32Array()
## Slid corners: {start, end, entry, exit (sample indices), dir (+1 right), loose, turn (rad),
## radius (m)}.
var _corners: Array[Dictionary] = []
var _phase: int = Phase.STRAIGHT
var _phase_time: float = 0.0
var _slide_corner: int = -1
var _braking: bool = false
var _brake_goal: float = 0.0
var _brake_goal_i: int = 0
var _handbrake: bool = false
var _lat_rate: float = 0.0
## Showoff: extra offset (m, + right) of the steering target, see `slide_setup_offset`.
var _setup: float = 0.0
var _prev_lat: float = 0.0


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
	_loose_cache.clear()
	var show := style == &"showoff"
	var cg := show_corner_grip if show else corner_grip
	var bg := show_brake_grip if show else brake_grip
	var count := maxi(int(length / STEP), 8)
	# A closed line wraps from the last sample to the first; an open one ends on its last sample.
	_spacing = length / (count if closed else count - 1)
	var step := _spacing
	_points.resize(count)
	_tangents.resize(count)
	for i in count:
		_points[i] = xf * c.sample_baked(i * step)
	for i in count:
		var a := _points[(i - 1 + count) % count] if closed or i > 0 else _points[i]
		var b := _points[(i + 1) % count] if closed or i < count - 1 else _points[i]
		_tangents[i] = (b - a).normalized()
	# Curvature from heading change over +-3 samples, smoothed (signed: + turning right).
	var curvature := PackedFloat32Array()
	curvature.resize(count)
	var turn := PackedFloat32Array()
	turn.resize(count)
	for i in count:
		var ia := _wrap_index(i - 3)
		var ib := _wrap_index(i + 3)
		var ta := Vector2(_tangents[ia].x, _tangents[ia].z)
		var tb := Vector2(_tangents[ib].x, _tangents[ib].z)
		turn[i] = ta.angle_to(tb) / (6.0 * step)
		curvature[i] = absf(turn[i])
	var space := _car.get_world_3d().direct_space_state
	var g := float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	_gravity = g
	_speeds.resize(count)
	var full := PackedFloat32Array() # showoff: the speeds at full show grip, for slid corners
	full.resize(count)
	for i in count:
		var k := 0.0
		for j in range(-2, 3):
			k = maxf(k, curvature[_wrap_index(i + j)])
		var mu := _grip_at(space, _points[i])
		full[i] = minf(sqrt(mu * cg * g / maxf(k, 1e-4)), max_speed_kmh / 3.6)
		_speeds[i] = full[i]
		if show and _loose_cache[i] == 1:
			var v_grip := sqrt(mu * show_corner_grip_loose * g / maxf(k, 1e-4))
			_speeds[i] = minf(full[i], maxf(v_grip, show_sweeper_kmh / 3.6))
	if not closed:
		_speeds[count - 1] = 0.0
	if show:
		_build_corners(turn, full)
	# Braking-distance planning: backwards pass (twice around for closed lines).
	var passes := count * (2 if closed else 1)
	for n in passes:
		var i := count - 1 - (n % count)
		var nxt := (i + 1) % count
		if not closed and i == count - 1:
			continue
		var mu := _grip_at_cached(i)
		var b := show_brake_grip_loose if show and _loose_cache[i] == 1 else bg
		var reach := sqrt(_speeds[nxt] * _speeds[nxt] + 2.0 * mu * b * g * step)
		_speeds[i] = minf(_speeds[i], reach)
	_built = true
	return true


func _grip_at(space: PhysicsDirectSpaceState3D, p: Vector3) -> float:
	var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 5.0, p + Vector3.DOWN * 5.0, 1)
	var hit := space.intersect_ray(q)
	var surf := TyreModel.get_surface(&"tarmac")
	if not hit.is_empty():
		surf = TyreModel.get_surface(Car.surface_of(hit["collider"], hit["position"]))
	_mu_cache.append(surf.mu)
	_loose_cache.append(1 if surf.loose else 0)
	return surf.mu


## Showoff corner table from the signed curvature: runs of samples tighter than
## `corner_radius`, merged across short gaps, kept when they turn far and tight enough to slide.
func _build_corners(turn: PackedFloat32Array, full: PackedFloat32Array) -> void:
	var count := _points.size()
	_corners.clear()
	_corner_of.resize(count)
	_corner_of.fill(-1)
	var k_min := 1.0 / corner_radius
	# Start scanning on a straight so a closed line's corner is not split at sample 0.
	var first := 0
	if closed:
		for i in count:
			if absf(turn[i]) < k_min:
				first = i
				break
	var i := 0
	while i < count:
		var s := first + i
		var dir := signf(turn[_wrap_index(s)])
		if absf(turn[_wrap_index(s)]) < k_min:
			i += 1
			continue
		# Extend while the line keeps turning the same way (gaps of up to 3 samples bridged).
		var e := s
		var gap := 0
		var total := 0.0
		var k_max := 0.0
		var loose := 0
		var n := 0
		var pend_total := 0.0
		var pend_loose := 0
		var pend_n := 0
		while i < count:
			var j := _wrap_index(first + i)
			pend_total += turn[j] * _spacing
			pend_loose += _loose_cache[j] if j < _loose_cache.size() else 0
			pend_n += 1
			if absf(turn[j]) >= k_min and signf(turn[j]) == dir:
				total += pend_total
				loose += pend_loose
				n += pend_n
				pend_total = 0.0
				pend_loose = 0
				pend_n = 0
				gap = 0
				e = first + i
				k_max = maxf(k_max, absf(turn[j]))
			else:
				gap += 1
				if gap > 3:
					break
			i += 1
			if not closed and first + i >= count:
				break
		# The bridged gap after the last tight sample belongs to whatever follows.
		i = e - first + 1
		var is_loose := loose * 2 > n
		var slide_r := slide_radius_loose if is_loose else slide_radius_tarmac
		if absf(total) >= deg_to_rad(slide_min_turn_deg) and k_max >= 1.0 / slide_r \
				and not _walled(s - int(10.0 / _spacing), e + int(10.0 / _spacing)):
			var id := _corners.size()
			# Turn-in where the corner tightens to half its peak curvature; the slide ends a share
			# of the way back from the corner's end.
			var entry := s
			while entry < e and absf(turn[_wrap_index(entry)]) < 0.5 * k_max:
				entry += 1
			var share := exit_share_loose if is_loose else exit_share_tarmac
			var exit := e - int((e - entry) * share)
			_corners.append({"start": _wrap_index(s), "end": _wrap_index(e), "entry": _wrap_index(entry),
					"exit": _wrap_index(exit), "dir": dir, "loose": is_loose, "turn": absf(total),
					"radius": 1.0 / k_max})
			# The car arrives at the turn-in already at the corner's speed (braked in a straight
			# line) and slides through at about that pace: the whole corner runs at a little over
			# its slowest point at full show grip.
			var v_min := INF
			for m in range(entry, e + 1):
				v_min = minf(v_min, full[_wrap_index(m)])
			for m in range(entry - int(8.0 / _spacing), e + 1):
				var w := _wrap_index(m)
				_speeds[w] = minf(full[w], v_min * slide_speed_factor)
			for m in range(s, e + 1):
				_corner_of[_wrap_index(m)] = id


## True when a solid body (wall, rail, barrier, tree) stands within `slide_wall_clearance` of
## the line anywhere between samples a and b: a slide there could swing the tail into it.
func _walled(a: int, b: int) -> bool:
	var space := _car.get_world_3d().direct_space_state
	for m in range(a, b + 1):
		var i := _wrap_index(m)
		var p := _points[i] + Vector3.UP * 0.6
		var side := _tangents[i].cross(Vector3.UP).normalized() * slide_wall_clearance
		for q: Vector3 in [p + side, p - side]:
			var ray := PhysicsRayQueryParameters3D.create(p, q, MapWorld.LAYER_PROPS | MapWorld.LAYER_WORLD)
			ray.exclude = [_car.get_rid()]
			var hit := space.intersect_ray(ray)
			if not hit.is_empty() and hit["collider"] is StaticBody3D and absf(hit["normal"].y) < 0.5:
				return true
	return false


func _grip_at_cached(i: int) -> float:
	return _mu_cache[i] if i < _mu_cache.size() else 1.0


func _drive(delta: float) -> void:
	var pos := _car.global_position
	_index = _closest_index(pos)
	var p := _points[_index]
	var t := _tangents[_index]
	# Sub-sample progress.
	var along := (pos - p).dot(t)
	var raw_progress := _index * _spacing + along
	var new_progress := fposmod(raw_progress, length) if closed else clampf(raw_progress, 0.0, length)
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
	if _setup != 0.0:
		var ahead_pt := _sample(progress + look + 1.0)
		target += (ahead_pt - target).cross(Vector3.UP).normalized() * _setup
	var local := _car.global_transform.affine_inverse() * target
	var dist := maxf(Vector2(local.x, local.z).length(), 1.0)
	var alpha := atan2(local.x, -local.z)
	var k := 2.0 * sin(alpha) / dist
	var delta_angle := atan(k * Car.WHEELBASE)
	var steer := clampf(delta_angle / _car.steer_lock_at(kmh), -1.0, 1.0)

	# Speed: profile value a little ahead, scaled. Off the line on a slower surface (grass
	# beside a gravel hairpin) the profile's grip is not under the tyres: scale down to it.
	var lead := speed * 0.35 + 3.0
	var i_ahead := _index_at(progress + lead)
	var grip_ratio := clampf(_car.current_grip() / _grip_at_cached(_index), 0.5, 1.0)
	target_speed = minf(_speeds[_index], _speeds[i_ahead]) * speed_scale * sqrt(grip_ratio)
	target_speed *= clampf(1.0 - (absf(lateral_error) - line_tolerance) * wide_slowdown, 0.6, 1.0)
	var err := target_speed - speed
	var thr := 0.0
	var brk := 0.0
	if style == &"showoff":
		var ctl := _show_controls(delta, speed, steer, err)
		steer = ctl.x
		thr = ctl.y
		brk = ctl.z
	elif err >= 0.0:
		# No power while sideways: flooring it in a slide turns the slide into a spin.
		var v := _car.local_velocity
		var slip := rad_to_deg(absf(atan2(v.x, maxf(-v.z, 0.5))))
		thr = clampf(err / 2.5 + 0.15, 0.0, 1.0) * clampf(1.0 - (slip - 8.0) / 12.0, 0.3, 1.0)
	else:
		thr = clampf(0.15 + err / 2.0, 0.0, 1.0)
		brk = clampf((-err - 0.3) / 1.5, 0.0, 1.0)
	var at_end := not closed and progress > length - 6.0
	if at_end:
		thr = 0.0
		brk = 1.0 if speed > 0.5 else 0.0
		_handbrake = false
	_apply(delta, steer, thr, brk, err)
	if style == &"showoff":
		_car.input_handbrake = _handbrake

	# Recover if wedged somewhere (not when parked at the end of an open line).
	if speed < 1.0 and not at_end:
		_stuck_time += delta
		if _stuck_time > 4.0:
			_stuck_time = 0.0
			_car.reset_to(transform_at(progress))
	else:
		_stuck_time = 0.0


## Showoff controls for this tick: (steer, throttle, brake); sets `_handbrake`. `steer` is the
## pure-pursuit steering, `err` the target minus current speed (m/s).
func _show_controls(delta: float, speed: float, steer: float, err: float) -> Vector3:
	var v := _car.local_velocity
	# + when the velocity points right of the nose (the nose has rotated left).
	var slip_signed := atan2(v.x, maxf(-v.z, 0.5))
	var slip := rad_to_deg(absf(slip_signed))
	_phase_time += delta
	_handbrake = false
	# Sideways speed off the line (m/s, + to the right), smoothed: where the car will be in a
	# moment matters more in a slide than where it is.
	_lat_rate = lerpf(_lat_rate, (lateral_error - _prev_lat) / maxf(delta, 1e-4), 0.2)
	_prev_lat = lateral_error
	# Straight-line pedals: one committed brake application per braking zone, started late (when
	# the slowest point ahead needs `show_brake_grip` of the surface's grip) and held until the
	# car is down to that speed; between zones only the throttle trims the speed (no dabs).
	var need := 0.0
	var goal := speed
	var goal_i := _index
	var d := 0.0
	var i := _index
	var reach := speed * speed / 8.0 + 20.0
	while d < reach:
		i = _wrap_index(i + 1)
		d += _spacing
		var vt := _speeds[i] * speed_scale
		# Small overspeeds are the throttle's to trim; the brake is for real speed drops.
		if vt < speed - 2.0:
			var a := (speed * speed - vt * vt) / (2.0 * _brake_room(d, speed))
			if a > need:
				need = a
				goal = vt
				goal_i = i
		if not closed and i == _points.size() - 1:
			break
	var a_full := _grip_at_cached(_index) * _gravity
	var bite := show_brake_grip_loose if _loose_cache[_index] == 1 else show_brake_grip
	if _braking:
		# Keep aiming at the point the stop started for (unless a stricter one shows up), so
		# braking a little ahead of schedule eases the pedal instead of ending the stop.
		var ahead_m := posmod(_brake_goal_i - _index, _points.size()) * _spacing
		if ahead_m > length * 0.5:
			ahead_m = 0.0
		var need_goal := (speed * speed - _brake_goal * _brake_goal) / (2.0 * _brake_room(ahead_m, speed))
		if need > need_goal:
			_brake_goal = goal
			_brake_goal_i = goal_i
		else:
			need = need_goal
		_braking = speed > _brake_goal + 0.5 and ahead_m > 0.0
	elif need > a_full * bite:
		_braking = true
		_brake_goal = goal
		_brake_goal_i = goal_i
	goal = _brake_goal if _braking else goal
	var thr := 0.0
	var brk := 0.0
	if _braking:
		brk = clampf(need / (a_full * bite), 0.3, 1.0)
	elif err >= 0.0:
		thr = clampf(0.35 + err / 2.0, 0.0, 1.0)
	else:
		thr = clampf(0.35 + err / 3.0, 0.0, 1.0)
	var here := _corner_of[_index]
	var i_lead := _index_at(progress + speed * flick_lead_time + 2.0)
	var ahead := _corner_of[i_lead]
	# Set up wide for the next slid corner while approaching it on a straight.
	var setup := 0.0
	var i_far := _index_at(progress + speed * (flick_lead_time + 1.5) + 2.0)
	for ci: int in [_corner_of[i_far], ahead]:
		if _phase == Phase.STRAIGHT and ci >= 0 and ci != _slide_corner and ci != here \
				and not _at_or_past(i_lead, _corners[ci]["entry"]):
			setup = -float(_corners[ci]["dir"]) * slide_setup_offset
	if _phase == Phase.FLICK:
		setup = _setup
	_setup = move_toward(_setup, setup, delta * 1.5)
	match _phase:
		Phase.STRAIGHT:
			if here != _slide_corner and ahead != _slide_corner:
				_slide_corner = -1
			# Flick once the lead point reaches the turn-in: with the braking for this corner
			# nearly done, and not when a slower corner right behind it already asks for the
			# brakes; never after the slide's end point.
			if ahead >= 0 and ahead != _slide_corner and speed > 8.0:
				var c: Dictionary = _corners[ahead]
				var settled := speed < goal + 2.5 if _braking else need < 0.4 * a_full * bite
				if _at_or_past(i_lead, c["entry"]) and not _at_or_past(_index, c["exit"]) and settled:
					_slide_corner = ahead
					_set_phase(Phase.FLICK)
			if _phase == Phase.STRAIGHT and slip > 30.0:
				thr *= 0.5
		Phase.FLICK:
			# Steer in off the throttle (the brakes stay on if the stop is not quite done). On a
			# loose surface lifting alone starts the slide; tarmac and tight loose corners get a
			# handbrake stab (longer for tighter, slower corners), and so does a loose corner
			# that has not rotated after the lift.
			var c: Dictionary = _corners[_slide_corner]
			var dir: float = c["dir"]
			var beta := rad_to_deg(slip_signed) * -dir
			var want := _slide_want(c)
			var lift: bool = c["loose"] and c["radius"] >= lift_flick_radius
			var stab: float = (stab_loose if c["loose"] else stab_tarmac) * clampf(35.0 / c["radius"], 1.0, 3.0)
			var t_lift := lift_flick_time if lift else 0.0
			if _phase_time < t_lift:
				steer = dir * maxf(steer * dir, 0.7)
				thr = 0.0
			elif _phase_time < t_lift + stab and (not lift or beta < 6.0):
				# Full lock on the handbrake.
				steer = dir
				thr = 0.0
				_handbrake = true
			else:
				# Let it rotate on the throttle, following the line.
				steer = dir * maxf(steer * dir, 0.2)
				thr = 0.7
				brk = 0.0
			if beta >= want * 0.6 or _phase_time > t_lift + stab + 0.35 or lateral_error * dir > slide_inside_limit:
				_handbrake = false
				_set_phase(Phase.SLIDE)
		Phase.SLIDE:
			# Hold the slip angle with the steering (into the corner below the wanted angle,
			# countersteer above it) on the throttle; drifting inside the line asks for less
			# angle, running wide for more.
			var c: Dictionary = _corners[_slide_corner]
			var dir: float = c["dir"]
			var beta := rad_to_deg(slip_signed) * -dir
			var inside := (lateral_error + _lat_rate * 0.3) * dir
			var want := _slide_want(c)
			want -= clampf(inside * 5.0, -8.0, 8.0)
			if _at_or_past(_index, c["exit"]) or (lateral_error + _lat_rate * 0.15) * dir > slide_inside_limit or -inside > slide_outside_limit \
					or beta > minf(want + 14.0, slip_guard) or (beta < 3.0 and _phase_time > 0.4):
				_set_phase(Phase.EXIT)
			else:
				steer = dir * clampf((want - beta) / 10.0, -1.0, 1.0)
				# A centred wheel ends the car's drift intent: keep it turned one way or the other.
				if absf(steer) < 0.2:
					steer = (signf(steer) if steer != 0.0 else -dir) * 0.2
				# Throttle holds the slide and sets its radius: more when the car tucks inside
				# the line (too slow for the corner), less when it runs wide.
				if err > -4.0:
					thr = clampf(0.75 + inside * 0.2, 0.55, 1.0)
					brk = 0.0
				else:
					thr = 0.0
					brk = clampf(-err / 8.0, 0.0, 0.6)
		Phase.EXIT:
			# Catch: part throttle (under half) ends the car's drift intent while the wheel follows
			# the line (countersteering the leftover angle); then power out.
			if slip > 10.0 or _phase_time < 0.15:
				if not _braking:
					thr = 0.45
			elif not _braking:
				thr = maxf(thr, clampf(0.6 + err * 0.3, 0.0, 0.6))
			if here != _slide_corner and slip < 10.0:
				_set_phase(Phase.STRAIGHT)
	return Vector3(steer, thr, brk)


## Body slip (deg) a slid corner is held at: the surface's angle, less on a corner that turns
## little (a big angle there points the car off the inside of the road).
func _slide_want(c: Dictionary) -> float:
	var want: float = slide_slip_loose if c["loose"] else slide_slip_tarmac
	return minf(want, rad_to_deg(c["turn"]) * slide_slip_per_turn)


## Braking distance to a point d metres ahead, less 0.1 s of pedal travel (at most half of it).
static func _brake_room(d: float, speed: float) -> float:
	return maxf(maxf(d - speed * 0.1, d * 0.5), 1.0)


## True when sample i is at or past sample ref (within half a line ahead of it).
func _at_or_past(i: int, ref: int) -> bool:
	var count := _points.size()
	return posmod(i - ref, count) < count / 2


func _set_phase(p: int) -> void:
	_phase = p
	_phase_time = 0.0


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
		var raw := _index + j
		if not closed and (raw < 0 or raw >= count):
			continue
		var i := (raw + count) % count
		var d := pos.distance_squared_to(_points[i])
		if d < best_d:
			best_d = d
			best = i
	# Lost the line (teleport): full search.
	if best_d > 900.0:
		_index = -1
		return _closest_index(pos)
	return best


## Controls for this tick. steer: -1..1 (fraction of the car's current lock), thr/brk 0..1,
## speed_error: target - current speed (m/s).
func _apply(_delta: float, steer: float, thr: float, brk: float, _speed_error: float) -> void:
	_car.input_steer = steer
	_car.input_throttle = thr
	_car.input_brake = brk
	_car.input_handbrake = false


## Sample index for sample i, wrapped on a closed line and clamped on an open one.
func _wrap_index(i: int) -> int:
	var count := _points.size()
	return (i % count + count) % count if closed else clampi(i, 0, count - 1)


## Sample index at a distance along the line.
func _index_at(offset: float) -> int:
	var count := _points.size()
	if closed:
		return int(fposmod(offset, length) / _spacing) % count
	return clampi(int(offset / _spacing), 0, count - 1)


## Point on the offset line at a distance along it (world space). Past the end of an open
## line it continues straight along the last tangent.
func _sample(offset: float) -> Vector3:
	var count := _points.size()
	if not closed and offset >= length:
		var tl := _tangents[count - 1]
		return _points[count - 1] + tl.cross(Vector3.UP).normalized() * lateral_offset + tl * (offset - length)
	if not closed:
		offset = maxf(offset, 0.0)
	var f := (fposmod(offset, length) if closed else offset) / _spacing
	var i0 := int(f) % count
	var i1 := (i0 + 1) % count
	var p := _points[i0].lerp(_points[i1], f - floorf(f))
	var t := _tangents[i0].lerp(_tangents[i1], f - floorf(f)).normalized()
	return p + t.cross(Vector3.UP).normalized() * lateral_offset


## World point in the middle of the next corner the showoff style slides, between min_ahead and
## max_ahead metres of line ahead of the car; Vector3.INF when there is none (or in the tidy
## style). The flyover camera stands there.
func next_slide_point(min_ahead: float, max_ahead: float) -> Vector3:
	if style != &"showoff" or not _built:
		return Vector3.INF
	var count := _points.size()
	var best := INF
	var at := Vector3.INF
	for c: Dictionary in _corners:
		var mid: int = int(c["entry"]) + posmod(int(c["exit"]) - int(c["entry"]), count) / 2
		var off := mid * _spacing
		var d := fposmod(off - progress, length) if closed else off - progress
		if d >= min_ahead and d <= max_ahead and d < best:
			best = d
			at = _sample(off)
	return at


## World transform on the line at a distance along it, facing the direction of travel.
func transform_at(offset: float) -> Transform3D:
	if not _built:
		_build()
	var p := _sample(offset)
	var ahead := _sample(offset + 3.0)
	return Transform3D(Basis.looking_at((ahead - p).normalized(), Vector3.UP), p)
