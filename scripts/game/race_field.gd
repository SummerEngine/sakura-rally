class_name RaceField
extends Node
## The race of Game.MODE_RACE: several cars from a standing start over `laps` laps of the selected
## loop. Main builds it with the grid (add() for every car, the player's included) and calls
## start() at GO. Per car: the distance along the route, the laps, the checkpoint crossings and
## the finish; for the race: the running order and the time gaps between the cars.
##
## Distance counts as in a time trial: road progress on the route only (the nearest road sample is
## searched in a window around the last one, so dropping onto a lower stretch of a switchback
## counts nothing), and a car put back on the road (the player's reset, a rival's rescue) carries
## on from where it lands. The clock starts at GO for every car wherever it stands on the grid; a
## lap ends on the start line.
##
## The player's own RaceSession (mode "race") keeps the reset point, the notices and the hazards;
## the player's checkpoints and finish come from here: Game.notify_race_checkpoint at each
## checkpoint (the interval to the car ahead in place of a split delta) and
## RaceSession.finish_race() at the flag. Every finisher emits car_finished (Main brings it to rest
## past the line). A rival that finishes after the player updates the results through
## Game.notify_race_classification.
##
## Order: finished cars by finish time, then the others by distance. Gaps: every car leaves a trace
## of its race time every TRACE_STEP metres; the gap between two cars is how long ago the car
## ahead was where the other one is now.

## A car took the flag; `position` is its finishing position.
signal car_finished(car: Car, position: int)

## Nearest-sample search window (samples, 2 m each) per physics tick.
const SEARCH_WINDOW := 10
## The window after a teleport (a reset, a rescue puts a car tens of metres back).
const JUMP_WINDOW := 80
## Metres beyond the road edge that still count as on the route (RaceSession.ROUTE_MARGIN).
const ROUTE_MARGIN := 16.0
## Metres between the points of a car's time trace.
const TRACE_STEP := 10.0


## One car of the race.
class Entrant:
	var car: Car
	## "name", "name_jp", "team", "player" (bool), "car_id", "colors" ([primary, secondary]).
	var info: Dictionary
	var player: bool = false
	## Nearest road sample the car legitimately reached, its lap progress and the car's position.
	var idx: int = 0
	var last_p: float = 0.0
	var last_pos: Vector3
	## Metres from the start line, unwrapped over the laps (negative on the grid).
	var dist: float = 0.0
	var next_cp: int = 0
	var laps_done: int = 0
	var lap_start: float = 0.0
	var lap_times: Array[float] = []
	var finished: bool = false
	var time: float = INF
	## In the running order, from 1.
	var position: int = 0
	## Race time at every TRACE_STEP metres from the start line, the first `traced` of them.
	var trace := PackedFloat32Array()
	var traced: int = 0


var map: MapWorld
var track: Track
var session: RaceSession
var laps: int = 2
## Lap progress (m) of each checkpoint; the last one is the lap line.
var checkpoints := PackedFloat32Array()
var entrants: Array[Entrant] = []
## The entrants in running order (kept up to date every physics tick).
var order: Array[Entrant] = []
var player: Entrant
var running: bool = false
var elapsed: float = 0.0
var finishers: int = 0


func setup(new_map: MapWorld, player_session: RaceSession, lap_count: int) -> void:
	map = new_map
	track = new_map.track
	session = player_session
	laps = lap_count
	checkpoints.clear()
	for cp: Dictionary in map.checkpoints:
		checkpoints.append(float(cp["progress"]))


## Enters a car standing on the grid. `info` as Entrant.info.
func add(car: Car, info: Dictionary) -> void:
	var e := Entrant.new()
	e.car = car
	e.info = info
	e.player = bool(info.get("player", false))
	e.last_pos = car.global_position
	e.idx = track.nearest(e.last_pos)
	e.last_p = track.progress_of(e.idx, e.last_pos)
	e.dist = e.last_p - track.length if e.last_p > track.length * 0.5 else e.last_p
	e.trace.resize(int(ceilf(laps * track.length / TRACE_STEP)) + 2)
	entrants.append(e)
	if e.player:
		player = e
	_sort()


## GO: the clock runs for every car.
func start() -> void:
	running = true
	elapsed = 0.0


func _physics_process(delta: float) -> void:
	if track == null:
		return
	if running:
		elapsed += delta
	for e in entrants:
		if is_instance_valid(e.car):
			_advance(e, delta)
	_sort()


func _advance(e: Entrant, delta: float) -> void:
	var pos := e.car.global_position
	var jumped := pos.distance_to(e.last_pos) > 1.5 + e.car.linear_velocity.length() * delta * 2.0
	e.last_pos = pos
	var i := track.nearest(pos, e.idx, JUMP_WINDOW if jumped else SEARCH_WINDOW)
	if absf(track.lateral(i, pos)) > track.half_width(i) + track.verge + ROUTE_MARGIN:
		return
	var p := track.progress_of(i, pos)
	var before := e.dist
	e.dist += wrapf(p - e.last_p, -track.length * 0.5, track.length * 0.5)
	e.idx = i
	e.last_p = p
	if running and not e.finished and e.dist > before:
		_trace(e, before, delta)
		_crossings(e, before, delta)


## Race time within this tick at which a car that went from `before` to `after` metres passed `at`.
func _time_at(before: float, after: float, at: float, delta: float) -> float:
	return elapsed - delta * clampf((after - at) / maxf(after - before, 1e-5), 0.0, 1.0)


## Race time at each trace point the car reached for the first time this tick.
func _trace(e: Entrant, before: float, delta: float) -> void:
	while e.traced < e.trace.size() and e.traced * TRACE_STEP <= e.dist:
		e.trace[e.traced] = _time_at(before, e.dist, e.traced * TRACE_STEP, delta)
		e.traced += 1


func _crossings(e: Entrant, before: float, delta: float) -> void:
	while not e.finished:
		var at := e.laps_done * track.length + checkpoints[e.next_cp]
		if e.dist < at:
			return
		var t := _time_at(before, e.dist, at, delta)
		var index := e.next_cp
		e.next_cp += 1
		if e.next_cp >= checkpoints.size():
			e.next_cp = 0
			e.laps_done += 1
			e.lap_times.append(t - e.lap_start)
			e.lap_start = t
			if e.laps_done >= laps:
				_finish(e, t)
				return
		if e.player:
			_player_checkpoint(index, t)


func _player_checkpoint(index: int, t: float) -> void:
	_sort()
	var interval := NAN
	if player.position > 1:
		interval = gap(order[player.position - 2], player)
	elif order.size() > 1:
		interval = -gap(player, order[1])
	var game := _game()
	if game != null:
		game.notify_race_checkpoint(index, checkpoints.size(), t, interval)


func _finish(e: Entrant, t: float) -> void:
	e.finished = true
	e.time = t
	finishers += 1
	_sort()
	car_finished.emit(e.car, e.position)
	if e.player:
		var best := INF
		for lt in e.lap_times:
			best = minf(best, lt)
		session.finish_race({"time": t, "laps": e.lap_times.duplicate(), "best_lap": best,
				"position": e.position, "field": entrants.size(), "classification": classification()})
	elif player != null and player.finished and _game() != null:
		_game().notify_race_classification(classification())


func _sort() -> void:
	order = entrants.duplicate()
	order.sort_custom(func(a: Entrant, b: Entrant) -> bool:
		if a.finished != b.finished:
			return a.finished
		if a.finished:
			return a.time < b.time
		return a.dist > b.dist)
	for k in order.size():
		order[k].position = k + 1


# ---------------------------------------------------------------- queries

## The player's place in the running order (from 1; 0 without a player).
func player_position() -> int:
	return player.position if player != null else 0


## Seconds between two cars at the point of the road `behind` has reached: how long ago `ahead`
## was there. Two finishers: the difference of their times. NAN before `behind` passes the start
## line.
func gap(ahead: Entrant, behind: Entrant) -> float:
	if ahead.finished and behind.finished:
		return behind.time - ahead.time
	var k := behind.dist / TRACE_STEP
	var i := int(floor(k))
	if k < 0.0 or i + 1 >= ahead.traced:
		return NAN
	return (behind.time if behind.finished else elapsed) - lerpf(ahead.trace[i], ahead.trace[i + 1], k - i)


## The lap the player is on (1 .. laps).
func player_lap() -> int:
	return mini(player.laps_done + 1, laps) if player != null else 1


## The player's time for lap `n` (from 1), NAN if not driven yet.
func player_lap_time(n: int) -> float:
	return player.lap_times[n - 1] if player != null and n >= 1 and n <= player.lap_times.size() else NAN


## The car `offset` places from the player in the running order (-1: the one ahead, +1: the one
## behind) as {"name", "gap"} (gap: seconds between the two, NAN when not known yet), or {}.
func player_neighbour(offset: int) -> Dictionary:
	if player == null:
		return {}
	var k := player.position - 1 + offset
	if k < 0 or k >= order.size():
		return {}
	var other := order[k]
	var g := gap(other, player) if offset < 0 else gap(player, other)
	return {"name": str(other.info.get("name", "")), "gap": g}


## Rows in running order: "name", "name_jp", "team", "player", "car_id", "colors", "finished",
## "time" (INF until finished), "best_lap" (INF before a lap), "laps_done", "gap" (to the winner,
## NAN until both finished).
func classification() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for e in order:
		var best := INF
		for lt in e.lap_times:
			best = minf(best, lt)
		var row := e.info.duplicate()
		row["player"] = e.player
		row["finished"] = e.finished
		row["time"] = e.time
		row["best_lap"] = best
		row["laps_done"] = e.laps_done
		row["gap"] = e.time - order[0].time if e.finished and order[0].finished else NAN
		rows.append(row)
	return rows


func _game() -> Node:
	return get_node_or_null(^"/root/Game")
