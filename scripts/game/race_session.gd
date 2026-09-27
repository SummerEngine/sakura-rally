class_name RaceSession
extends Node
## Follows the player car along the selected route of the world (MapWorld.select_route): lap
## progress, checkpoint splits, the lap timer, wrong-way and off-route notices, the reset point,
## and on the liaison the distance left and the arrival zone (the next stage's grid).
##
## `setup()` anchors on wherever the car stands, so Main calls it again on the same car when a
## campaign leg carries on from the previous one (the liaison from a stage's finish stop, a stage
## from its grid at the end of the liaison) without moving the car.
##
## Joins the "track" group for Car.reset_to_track(). In a time trial the car resets to
## the last point of the route it legitimately reached (no shortcuts by falling down a
## switchback). Free roam and liaisons go anywhere: back on the road somewhere else, or
## after R, the route carries on from the nearest stretch of road.
## Reports to the Game autoload through notify_*; Main owns the game state.

signal finished(result: Dictionary)
## Liaison: the car entered the arrival zone (once per session).
signal arrived
## The car needs a reset it cannot ask for itself (water, out of bounds).
signal reset_needed(reason: String)

## Metres beyond the road edge that still count as "on the route".
const ROUTE_MARGIN := 16.0
## Hinted nearest-sample search window (samples, 2 m each) per physics tick.
const SEARCH_WINDOW := 10
## Free roam, off route: physics ticks between full-track searches for road to rejoin.
const REANCHOR_TICKS := 30

var map: MapWorld
var track: Track
var car: Car
var mode: String = "free_roam"

## Contract fields read by the HUD (see docs/CONTRACTS.md).
var elapsed: float = 0.0
var checkpoint_index: int = 0 ## next checkpoint to pass
var checkpoint_total: int = 0
var progress: float = 0.0 ## 0..1 of the lap (of the road, start to arrival, on a liaison)
var best_time: float = INF
var top_speed_kmh: float = 0.0
var lap: int = 0 ## completed laps in free roam
var running: bool = false ## timer and checkpoints live
var distance_left: float = 0.0 ## liaison: road metres to the arrival
var has_arrived: bool = false

var _idx: int = 0 ## nearest route sample the car legitimately reached
var _last_p: float = 0.0 ## lap progress (m) at _idx
var _dist: float = 0.0 ## unwrapped distance driven along the route since the start line
var _next_line: float = 0.0 ## free roam: _dist of the next start-line crossing
var _splits: Array[float] = []
var _lap_start: float = 0.0
var _wrong_way_time: float = 0.0
var _wrong_way_shown: bool = false
var _off_route_time: float = 0.0
var _off_route_shown: bool = false
var _water_time: float = 0.0
var _lake_poly: PackedVector2Array
var _lake_level: float = -INF
## The world's rivers (pack `water.rivers`): per river its centreline and half width.
var _rivers: Array[PackedVector3Array] = []
var _river_halves := PackedFloat32Array()
## Driveable area on the ground plane (x, z); leaving it resets the car. The world pack's
## `bounds` (its terrain rectangle), or a v1 pack's `play_half` square plus 40 m.
var _area := Rect2(-640.0, -640.0, 1280.0, 1280.0)
var _tick: int = 0


func _ready() -> void:
	add_to_group(&"track")


func setup(new_map: MapWorld, new_car: Car, new_mode: String) -> void:
	map = new_map
	track = new_map.track
	car = new_car
	mode = new_mode
	checkpoint_total = map.checkpoints.size()
	best_time = _game().best_time(map.route_id) if _game() else INF
	var b: Array = map.info.get("bounds", [])
	if b.size() == 4:
		_area = Rect2(float(b[0]), float(b[1]), float(b[2]) - float(b[0]), float(b[3]) - float(b[1]))
	else:
		var half := float(map.info.get("play_half", 600.0)) + 40.0
		_area = Rect2(-half, -half, 2.0 * half, 2.0 * half)
	var water: Dictionary = map.info.get("water", {})
	var lake: Dictionary = water.get("lake", {})
	_lake_poly = PackedVector2Array()
	for p in lake.get("poly", []):
		_lake_poly.append(Vector2(p[0], p[1]))
	_lake_level = float(lake.get("level", -INF))
	_rivers.clear()
	_river_halves = PackedFloat32Array()
	for river: Dictionary in water.get("rivers", []):
		var pts := PackedVector3Array()
		for p in river.get("points", []):
			pts.append(Vector3(p[0], p[1], p[2]))
		if pts.size() >= 2:
			_rivers.append(pts)
			_river_halves.append(float(river.get("width", 0.0)) * 0.5)
	reset_progress()


## Re-anchor on the car's current position (after placing it, or where the last leg left it).
func reset_progress() -> void:
	running = false
	has_arrived = false
	elapsed = 0.0
	checkpoint_index = 0
	lap = 0
	top_speed_kmh = 0.0
	_splits.clear()
	_lap_start = 0.0
	_idx = track.nearest(car.global_position)
	_last_p = track.progress_of(_idx, car.global_position)
	# Standing start a few metres behind the line counts as negative distance.
	_dist = _last_p - track.length if track.closed and _last_p > track.length * 0.5 else _last_p
	_next_line = _line_after(_dist)
	progress = _last_p / track.length if not track.closed else 0.0
	distance_left = track.length - _last_p
	_wrong_way_time = 0.0
	_off_route_time = 0.0
	_water_time = 0.0


func start_timer() -> void:
	running = true
	elapsed = 0.0
	_lap_start = 0.0


## Called by Car.reset_to_track(): the last legitimately reached point of the route in
## a time trial, the nearest road in free roam.
func nearest_reset_transform(from: Vector3) -> Transform3D:
	var roam := mode != "time_trial"
	var i := track.nearest(from) if roam else _idx
	# Nudge back a little so the car does not land on the obstacle it just hit.
	var xf := track.transform_at_abs(track.dist(i) - 4.0, 0.0, 0.35)
	if roam:
		_reanchor(track.nearest(xf.origin, i, SEARCH_WINDOW), xf.origin)
	return xf


## Free roam: carry on along the route from sample i. The skipped (or doubled-back)
## stretch does not count as driven, so the lap in progress is void and the timer
## restarts at the next start-line crossing.
func _reanchor(i: int, pos: Vector3) -> void:
	_idx = i
	_last_p = track.progress_of(i, pos)
	_dist = _last_p
	_next_line = _line_after(_dist)
	running = false


## Route distance of the first start-line crossing ahead of d.
func _line_after(d: float) -> float:
	return (floorf(d / track.length) + 1.0) * track.length


func _physics_process(delta: float) -> void:
	if car == null or track == null:
		return
	var pos := car.global_position
	var kmh := absf(car.speed_kmh)
	if running:
		elapsed += delta
		top_speed_kmh = maxf(top_speed_kmh, kmh)
	var i := track.nearest(pos, _idx, SEARCH_WINDOW)
	var on_route := absf(track.lateral(i, pos)) < track.half_width(i) + track.verge + ROUTE_MARGIN
	if not on_route and mode != "time_trial" and _tick % REANCHOR_TICKS == 0:
		var g := track.nearest(pos)
		if absf(track.lateral(g, pos)) < track.half_width(g) + track.verge \
				and absf(pos.y - track.point(g).y) < 4.0:
			_reanchor(g, pos)
			i = g
			on_route = true
	if on_route:
		_off_route_time = 0.0
		_off_route_shown = false
		var p := track.progress_of(i, pos)
		var step := wrapf(p - _last_p, -track.length * 0.5, track.length * 0.5) if track.closed else p - _last_p
		var before := _dist
		_dist += step
		_idx = i
		_last_p = p
		_check_crossings(before, _dist, delta)
		if track.closed:
			progress = clampf(fposmod(_dist, track.length) / track.length, 0.0, 1.0)
		else:
			progress = clampf(p / track.length, 0.0, 1.0)
			distance_left = track.length - p
	else:
		_off_route_time += delta
		if _off_route_time > 3.0 and not _off_route_shown and kmh < 25.0:
			_off_route_shown = true
			_notice("Off the route — press R to reset")
	if mode == "liaison" and not has_arrived:
		_check_arrival(pos, on_route)
	# Direction only matters against the clock, and only judged on the road.
	if on_route and mode == "time_trial":
		_update_wrong_way(i, delta, kmh)
	else:
		_wrong_way_time = 0.0
	_tick += 1
	if _tick % 4 == 0:
		_update_hazards(pos, delta * 4.0)


func _check_crossings(before: float, after: float, delta: float) -> void:
	if after <= before:
		return
	if mode == "time_trial":
		if not running or checkpoint_index >= checkpoint_total:
			return
		var cp: Dictionary = map.checkpoints[checkpoint_index]
		var s: float = cp["progress"]
		if before < s and after >= s:
			# interpolate the crossing inside the tick for millisecond timing
			var t := elapsed - delta * (after - s) / maxf(after - before, 1e-5)
			_splits.append(t)
			checkpoint_index += 1
			if checkpoint_index >= checkpoint_total:
				_finish(t)
			elif _game():
				_game().notify_checkpoint(checkpoint_index - 1, checkpoint_total, t)
	elif mode == "free_roam" and track.closed:
		# free roam: quietly time laps across the start line
		if before < _next_line and after >= _next_line:
			var t := elapsed - delta * (after - _next_line) / maxf(after - before, 1e-5)
			_next_line += track.length
			if running:
				lap += 1
				_notice("Lap %d  %s" % [lap, _format(t - _lap_start)])
				_lap_start = t
			else:
				start_timer()


func _finish(t: float) -> void:
	running = false
	elapsed = t
	var result := {
		"time": t,
		"splits": _splits.duplicate(),
		"top_speed_kmh": top_speed_kmh,
	}
	if _game():
		_game().notify_finished(result)
		best_time = _game().best_time(map.route_id)
	finished.emit(result)


## Liaison: the arrival zone is the circle around the route's arrival point, or the last
## `arrival_radius` metres of the road for a car that reached them on the route.
func _check_arrival(pos: Vector3, on_route: bool) -> void:
	var r := map.arrival_radius
	if r <= 0.0:
		return
	var d := Vector2(pos.x - map.arrival.origin.x, pos.z - map.arrival.origin.z).length()
	if d > r and not (on_route and _last_p >= track.length - r):
		return
	has_arrived = true
	if _game():
		_game().notify_arrived()
	arrived.emit()


func _update_wrong_way(i: int, delta: float, kmh: float) -> void:
	var fwd := -car.global_transform.basis.z
	var vel := car.linear_velocity
	var backwards := vel.length() > 4.0 and vel.normalized().dot(track.forward(i)) < -0.35 \
			and fwd.dot(track.forward(i)) < -0.2
	_wrong_way_time = _wrong_way_time + delta if backwards else 0.0
	if _wrong_way_time > 1.5 and not _wrong_way_shown:
		_wrong_way_shown = true
		_notice("Wrong way")
	elif _wrong_way_time == 0.0 and kmh > 10.0:
		_wrong_way_shown = false


func _update_hazards(pos: Vector3, delta: float) -> void:
	if not _area.has_point(Vector2(pos.x, pos.z)) or pos.y < -50.0:
		reset_needed.emit("bounds")
		return
	var surface := _water_height(pos)
	if pos.y + 0.35 < surface:
		_water_time += delta
		if _water_time > 0.5:
			_water_time = 0.0
			reset_needed.emit("water")
	else:
		_water_time = 0.0


## Water surface height under pos, or -INF when there is no water.
func _water_height(pos: Vector3) -> float:
	var p2 := Vector2(pos.x, pos.z)
	if pos.y < _lake_level + 2.0 and not _lake_poly.is_empty() and Geometry2D.is_point_in_polygon(p2, _lake_poly):
		return _lake_level
	for r in _rivers.size():
		var h := _river_height(_rivers[r], _river_halves[r], p2)
		if h > -INF:
			return h
	return -INF


## Surface height of one river under p2, or -INF outside it.
func _river_height(river: PackedVector3Array, half: float, p2: Vector2) -> float:
	var best := INF
	var h := -INF
	for k in range(0, river.size() - 1, 2):
		var a := river[k]
		var b := river[mini(k + 2, river.size() - 1)]
		var ab := Vector2(b.x - a.x, b.z - a.z)
		var t := clampf((p2 - Vector2(a.x, a.z)).dot(ab) / maxf(ab.length_squared(), 1e-4), 0.0, 1.0)
		var d := p2.distance_squared_to(Vector2(a.x, a.z) + ab * t)
		if d < best:
			best = d
			h = lerpf(a.y, b.y, t)
	return h if best < half * half else -INF


func _notice(text: String) -> void:
	if _game():
		_game().post_notice(text)


func _format(t: float) -> String:
	return _game().format_time(t) if _game() else "%.3f" % t


func _game() -> Node:
	return get_node_or_null(^"/root/Game")
