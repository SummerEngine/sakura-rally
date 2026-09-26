class_name RaceSession
extends Node
## Follows the player car along the loaded map's road: lap progress, checkpoint
## splits, the lap timer, wrong-way and off-route notices, and the reset point.
##
## Joins the "track" group, so Car.reset_to_track() lands on the last point of the
## route the car legitimately reached (no shortcuts by falling down a switchback).
## Reports to the Game autoload through notify_*; Main owns the game state.

signal finished(result: Dictionary)
## The car needs a reset it cannot ask for itself (water, out of bounds).
signal reset_needed(reason: String)

## Metres beyond the road edge that still count as "on the route".
const ROUTE_MARGIN := 16.0
## Hinted nearest-sample search window (samples, 2 m each) per physics tick.
const SEARCH_WINDOW := 10

var map: MapWorld
var track: Track
var car: Car
var mode: String = "free_roam"

## Contract fields read by the HUD (see docs/CONTRACTS.md).
var elapsed: float = 0.0
var checkpoint_index: int = 0 ## next checkpoint to pass
var checkpoint_total: int = 0
var progress: float = 0.0 ## 0..1 of the lap
var best_time: float = INF
var top_speed_kmh: float = 0.0
var lap: int = 0 ## completed laps in free roam
var running: bool = false ## timer and checkpoints live

var _idx: int = 0 ## nearest route sample the car legitimately reached
var _last_p: float = 0.0 ## lap progress (m) at _idx
var _dist: float = 0.0 ## unwrapped distance driven along the route since the start line
var _splits: Array[float] = []
var _lap_start: float = 0.0
var _wrong_way_time: float = 0.0
var _wrong_way_shown: bool = false
var _off_route_time: float = 0.0
var _off_route_shown: bool = false
var _water_time: float = 0.0
var _lake_poly: PackedVector2Array
var _lake_level: float = -INF
var _river: PackedVector3Array
var _river_half: float = 0.0
var _play_half: float = 600.0
var _tick: int = 0


func _ready() -> void:
	add_to_group(&"track")


func setup(new_map: MapWorld, new_car: Car, new_mode: String) -> void:
	map = new_map
	track = new_map.track
	car = new_car
	mode = new_mode
	checkpoint_total = map.checkpoints.size()
	best_time = _game().best_time(map.map_id) if _game() else INF
	_play_half = float(map.info.get("play_half", 600.0)) + 40.0
	var water: Dictionary = map.info.get("water", {})
	var lake: Dictionary = water.get("lake", {})
	_lake_poly = PackedVector2Array()
	for p in lake.get("poly", []):
		_lake_poly.append(Vector2(p[0], p[1]))
	_lake_level = float(lake.get("level", -INF))
	var river: Dictionary = water.get("river", {})
	_river = PackedVector3Array()
	for p in river.get("points", []):
		_river.append(Vector3(p[0], p[1], p[2]))
	_river_half = float(river.get("width", 0.0)) * 0.5
	reset_progress()


## Re-anchor on the car's current position (after placing it at the spawn).
func reset_progress() -> void:
	running = false
	elapsed = 0.0
	checkpoint_index = 0
	lap = 0
	top_speed_kmh = 0.0
	_splits.clear()
	_lap_start = 0.0
	_idx = track.nearest(car.global_position)
	_last_p = track.progress_of(_idx, car.global_position)
	# Standing start a few metres behind the line counts as negative distance.
	_dist = _last_p - track.length if _last_p > track.length * 0.5 else _last_p
	progress = 0.0
	_wrong_way_time = 0.0
	_off_route_time = 0.0
	_water_time = 0.0


func start_timer() -> void:
	running = true
	elapsed = 0.0
	_lap_start = 0.0


## Called by Car.reset_to_track(): the last legitimately reached point of the route.
func nearest_reset_transform(_from: Vector3) -> Transform3D:
	var s := track.dist(_idx)
	# Nudge back a little so the car does not land on the obstacle it just hit.
	s -= 4.0
	return track.transform_at_abs(s, 0.0, 0.35)


func _physics_process(delta: float) -> void:
	if car == null or track == null:
		return
	var pos := car.global_position
	var kmh := absf(car.speed_kmh)
	if running:
		elapsed += delta
		top_speed_kmh = maxf(top_speed_kmh, kmh)
	var i := track.nearest(pos, _idx, SEARCH_WINDOW)
	var lat := absf(track.lateral(i, pos))
	var on_route := lat < track.half_width(i) + track.verge + ROUTE_MARGIN
	if on_route:
		_off_route_time = 0.0
		_off_route_shown = false
		var p := track.progress_of(i, pos)
		var step := wrapf(p - _last_p, -track.length * 0.5, track.length * 0.5)
		var before := _dist
		_dist += step
		_idx = i
		_last_p = p
		_check_crossings(before, _dist, delta)
		progress = clampf(fposmod(_dist, track.length) / track.length, 0.0, 1.0)
	else:
		_off_route_time += delta
		if _off_route_time > 3.0 and not _off_route_shown and kmh < 25.0:
			_off_route_shown = true
			_notice("Off the route — press R to reset")
	_update_wrong_way(i, delta, kmh)
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
	else:
		# free roam: quietly time laps across the start line
		var line := track.length * float(lap + 1)
		if before < line and after >= line:
			var t := elapsed - delta * (after - line) / maxf(after - before, 1e-5)
			lap += 1
			if running and lap > 1:
				_notice("Lap %d  %s" % [lap - 1, _format(t - _lap_start)])
			_lap_start = t
			if not running:
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
		best_time = _game().best_time(map.map_id)
	finished.emit(result)


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
	if absf(pos.x) > _play_half or absf(pos.z) > _play_half or pos.y < -50.0:
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
	if _river.size() < 2:
		return -INF
	var best := INF
	var h := -INF
	for k in range(0, _river.size() - 1, 2):
		var a := _river[k]
		var b := _river[mini(k + 2, _river.size() - 1)]
		var ab := Vector2(b.x - a.x, b.z - a.z)
		var t := clampf((p2 - Vector2(a.x, a.z)).dot(ab) / maxf(ab.length_squared(), 1e-4), 0.0, 1.0)
		var d := p2.distance_squared_to(Vector2(a.x, a.z) + ab * t)
		if d < best:
			best = d
			h = lerpf(a.y, b.y, t)
	return h if best < _river_half * _river_half else -INF


func _notice(text: String) -> void:
	if _game():
		_game().post_notice(text)


func _format(t: float) -> String:
	return _game().format_time(t) if _game() else "%.3f" % t


func _game() -> Node:
	return get_node_or_null(^"/root/Game")
