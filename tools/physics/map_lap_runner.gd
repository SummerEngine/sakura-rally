extends RefCounted
## One timed standing-start run of a route of the world by the analog Autopilot or the
## KeyboardBot, timed like a time trial (RaceSession): the clock starts when the start-line hold
## is released and stops where the route crosses its last checkpoint (a stage lap) or reaches
## its arrival (the open liaison, from Hanami's finish stop to Momiji's grid, gates open).
## Shared by tools/physics/run_tests.gd and tools/physics/map_drive.gd.

const KeyboardBot := preload("res://tools/physics/keyboard_bot.gd")
const DT := 1.0 / 120.0
## Samples searched around the last one, as RaceSession does.
const SEARCH_WINDOW := 10
## A tick in which the car moves farther than this (m) was a reset.
const RESET_JUMP := 5.0
## Impacts stronger than this count as hard (the loop test's crash threshold).
const HARD_IMPACT := 0.25

## Called every physics tick during the lap with (car, elapsed seconds).
var on_tick: Callable
## Property overrides for the driver (Autopilot / KeyboardBot exports), for tuning runs.
var driver_props: Dictionary = {}


## Builds the world with route `route_id` selected. Returns it with the build time in
## `stats["build_ms"]`.
static func build_map(tree: SceneTree, route_id: String) -> MapWorld:
	var map := MapWorld.new()
	map.name = "Map"
	map.map_id = route_id
	tree.root.add_child(map)
	await map.build()
	return map


## Drives the selected route once and returns {finished, time, resets, impacts, hard_impacts,
## max_impact, max_slip_deg, top_kmh, off_road_s (time with the car's centre beyond the road
## edge), max_off_m (farthest beyond it)}. The bot is removed afterwards and every key released.
## An open route opens every gate first.
func lap(tree: SceneTree, map: MapWorld, car: Car, keyboard: bool, limit: float = 300.0) -> Dictionary:
	var track := map.track
	if not map.closed:
		for g: RoadGate in map.gates.values():
			g.set_open(true, false)
	var ap: Autopilot = KeyboardBot.new() if keyboard else Autopilot.new()
	ap.curve = track.to_curve()
	ap.closed = map.closed
	if not map.closed:
		# as Main.drive_curve: the line runs on past the arrival, so the car stops there itself
		var fwd := -map.arrival.basis.z
		for k in range(1, 6):
			ap.curve.add_point(map.arrival.origin + fwd * (9.0 * k) + Vector3.UP * 0.3)
	for key in driver_props:
		ap.set(key, driver_props[key])
	car.controlled_by_player = false
	car.input_throttle = 0.0
	car.input_brake = 0.0
	car.input_steer = 0.0
	car.place_at_rest(map.spawn)
	car.launch_hold = true
	car.add_child(ap)
	var impacts: Array[float] = []
	var on_impact := func(s: float, _p: Vector3) -> void: impacts.append(s)
	car.impact.connect(on_impact)
	# Start-line hold: the bot revs against the brakes, as in the countdown.
	for i in int(1.2 / DT):
		await tree.physics_frame
	car.launch_hold = false
	impacts.clear()

	var idx := track.nearest(car.global_position)
	var last_p := track.progress_of(idx, car.global_position)
	var dist := last_p - track.length if last_p > track.length * 0.5 else last_p
	var finish_s: float = map.checkpoints[map.checkpoints.size() - 1]["progress"] if map.closed \
			else map.arrival_progress - map.arrival_radius
	var result := {"finished": false, "time": limit, "resets": 0, "impacts": 0, "hard_impacts": 0,
			"max_impact": 0.0, "max_slip_deg": 0.0, "top_kmh": 0.0, "off_road_s": 0.0, "max_off_m": 0.0}
	var elapsed := 0.0
	var prev_pos := car.global_position
	while elapsed < limit:
		await tree.physics_frame
		elapsed += DT
		var pos := car.global_position
		if pos.distance_to(prev_pos) > RESET_JUMP:
			result["resets"] += 1
		prev_pos = pos
		var v := car.linear_velocity
		result["top_kmh"] = maxf(result["top_kmh"], v.length() * 3.6)
		var lv := car.global_basis.inverse() * v
		if Vector2(lv.x, lv.z).length() > 5.0:
			result["max_slip_deg"] = maxf(result["max_slip_deg"], rad_to_deg(absf(atan2(lv.x, -lv.z))))
		if on_tick.is_valid():
			on_tick.call(car, elapsed)
		var i := track.nearest(pos, idx, SEARCH_WINDOW)
		var off := absf(track.lateral(i, pos)) - track.half_width(i)
		if off > 0.0:
			result["off_road_s"] += DT
			result["max_off_m"] = maxf(result["max_off_m"], off)
		if off < track.verge + 16.0:
			var p := track.progress_of(i, pos)
			var before := dist
			dist += wrapf(p - last_p, -track.length * 0.5, track.length * 0.5)
			idx = i
			last_p = p
			if before < finish_s and dist >= finish_s:
				result["finished"] = true
				result["time"] = elapsed - DT * (dist - finish_s) / maxf(dist - before, 1e-5)
				break
	car.impact.disconnect(on_impact)
	for s in impacts:
		result["max_impact"] = maxf(result["max_impact"], s)
		if s > HARD_IMPACT:
			result["hard_impacts"] += 1
	result["impacts"] = impacts.size()
	car.remove_child(ap)
	ap.free()
	car.controlled_by_player = false
	car.input_throttle = 0.0
	car.input_brake = 0.0
	car.input_steer = 0.0
	return result
