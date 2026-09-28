extends SceneTree
## Races RaceBots headless (docs/RL.md, Racing) and builds their pace calibration.
##
##   $S --headless --disable-crash-handler --fixed-fps 120 --audio-driver Dummy --path . \
##       -s res://tools/rl/race_probe.gd -- route=hanami runs=3
##
## mode=race (default): the race mode's field and grid (Main): the campaign rivals (Game.RIVALS)
## at their pace on this stage (lap target = gold x pace, turned into a bot pace by
## RaceBot.pace_for_lap), the car models alternating, slowest on pole, and a seventh bot in the
## player's slot (last) at `player` x gold. Slot g stands GRID_GAP_M x g behind the route's spawn,
## GRID_LAT_M left (even g) or right. `laps` laps with car-to-car collisions on, `runs` times (each
## run shifts the decision phases and jitters the grid by up to 0.1 m). A finished car is handed
## to an ArrivalStop as in the game and stays in the field. `gold` (multiples of gold) or `pace`
## (paces), in grid order, replace the rivals; `car` lists the car ids dealt out in turn.
## Prints a BOT line per car and a RACE line per run: lap times against the calibration (lap 1
## from the grid: the standing lap plus the grid slot's distance at the flying speed over the
## line), finish order, overtakes (places gained on track: a pair swapping order by more than a
## metre with neither just rescued), car-to-car contacts while racing (events, worst impulse and
## the speed change it means; contacts between two finished cars at the finish stop are counted
## apart), rescues, flips, seconds off the road, wander (the furthest the car got from the centre
## of the road it sees); then a SUMMARY over the runs (lap errors split into lap 1, which pays for
## the traffic ahead of a car started from the back, and the flying laps) and COST: the physics
## tick time and the script cost of one decision.
##
## mode=record: RECORD_CARS unlimited bots (pace INF) in lane 0 drive `laps` (default 3) laps
## alone; their speed along the road on the flying laps becomes v_ref in
## assets/ai/pace/<route>.json (any old calibration dropped: it belongs to the old v_ref).
## mode=calibrate: one car per pace in `paces` and car in `car` (default sakura,hayate), all at
## once without collisions, `laps` (default 3) laps: lap 1 is the standing lap, the others the
## flying laps; writes the `laps` table of assets/ai/pace/<route>.json.
##
## Options: mode, route, gold, pace, player, paces, car, laps, runs, contacts (0: cars pass
## through each other), seconds (time limit per run), verbose (1: a RESCUE line per rescue with
## the car's state and contacts the tick before, an OFF line per spell past the verge).

const RLCar := preload("res://tools/rl/rl_car.gd")

const GRID_GAP_M := 5.0
const GRID_LAT_M := 2.2
const COUNTDOWN_S := 2.0
const RECORD_CARS := 3
## v_ref smoothing: bins either side averaged.
const SMOOTH_BINS := 2
## Overtake hysteresis (m) and how long a rescue keeps a car out of the count (s).
const SWAP_M := 1.0
const RESCUE_QUIET_S := 3.0
## A new contact event between two cars once they were apart this many ticks.
const CONTACT_GAP_TICKS := 12
const CAR_MASS := 1250.0

var opts := {"mode": "race", "route": "hanami", "gold": "", "pace": "", "player": "1.05",
		"paces": "0.5,0.55,0.6,0.65,0.7,0.75,0.8,0.85,0.9,0.95,1.0",
		"car": "", "laps": "", "runs": "1", "contacts": "1", "seconds": "600", "verbose": "0"}
var game: Node
var map: MapWorld
var track: Track


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	_run.call_deferred()


func _run() -> void:
	game = root.get_node("Game")
	map = MapWorld.new()
	map.name = "Map"
	map.map_id = opts["route"]
	root.add_child(map)
	await map.build()
	for gate: RoadGate in map.gates.values():
		gate.set_open(true, false)
	if not map.routes.has(opts["route"]):
		printerr("race_probe: no route '%s'" % opts["route"])
		game.request_quit(2)
		return
	track = map.routes[opts["route"]]["track"]
	var hw_lo := INF
	var hw_hi := 0.0
	for i in track.count:
		hw_lo = minf(hw_lo, track.half_width(i))
		hw_hi = maxf(hw_hi, track.half_width(i))
	print("ROAD route=%s length=%.1f closed=%s half_width=%.2f..%.2f verge=%.2f" % [opts["route"], track.length,
			track.closed, hw_lo, hw_hi, track.verge])
	match opts["mode"]:
		"record":
			await _record()
		"calibrate":
			await _calibrate()
		_:
			await _races()
	game.request_quit(0)


# ---------------------------------------------------------------- shared

## Spawns a stripped car of `car_id` with a RaceBot at `pace` and `phase`; the field is set later.
func _spawn(car_id: String, pace: float, phase: int, contacts: bool) -> Dictionary:
	var car := RLCar.spawn(root, str(game.get_car(car_id)["scene"]), false)
	car.car_contacts = contacts
	var bot := RaceBot.new()
	bot.name = "RaceBot"
	bot.track = track
	bot.pace = pace
	bot.phase = phase
	return {"car": car, "bot": bot, "car_id": car_id, "pace": pace}


## Adds the bots (with `field`: all the cars, or with `solo` each car alone, as the cars of a
## recording or a calibration pass through each other) and puts every car at rest at its grid
## spot, held.
func _line_up(entries: Array[Dictionary], solo: bool = false) -> void:
	var field: Array[Car] = []
	for e in entries:
		field.append(e["car"])
	for e in entries:
		var bot: RaceBot = e["bot"]
		if solo:
			var own: Array[Car] = [e["car"]]
			bot.field = own
		else:
			bot.field = field
		(e["car"] as Car).add_child(bot)
	await physics_frame
	for e in entries:
		var car: Car = e["car"]
		car.place_at_rest(track.transform_at_abs(e["grid_s"], e["grid_lat"]))
		car.launch_hold = true
		(e["bot"] as RaceBot).sense.reset(e["grid_s"])
		e["last_s"] = float(e["grid_s"])
		var d: float = track.start_s - float(e["grid_s"])
		e["prog"] = -(wrapf(d, -track.length * 0.5, track.length * 0.5) if track.closed else d)
		e["laps"] = []
		e["lap_t0"] = 0.0
	for i in int(COUNTDOWN_S * Engine.physics_ticks_per_second):
		await physics_frame
	for e in entries:
		(e["car"] as Car).launch_hold = false


## Road progress since the start line for every car still racing (updates e["prog"], e["laps"]);
## `clock` is seconds since GO.
func _track_progress(entries: Array[Dictionary], clock: float, laps: int) -> void:
	for e in entries:
		if e.get("finish_t", -1.0) >= 0.0:
			continue # handed over: its RaceBot is gone
		var car: Car = e["car"]
		var bot: RaceBot = e["bot"]
		var s := bot.sense.road_s(car.global_position)
		var ds: float = s - float(e["last_s"])
		if track.closed:
			ds = wrapf(ds, -track.length * 0.5, track.length * 0.5)
		e["last_s"] = s
		e["prog"] = float(e["prog"]) + ds
		var done: Array = e["laps"]
		var goal := track.length if track.closed else track.last_s - 8.0 - track.start_s
		if done.size() < laps and float(e["prog"]) >= goal * (done.size() + 1):
			done.append(clock - float(e["lap_t0"]))
			e["lap_t0"] = clock
		_watch(e, s, clock)


## Rescues (e["rescues"], e["rescued_at"]) and, with verbose=1, a RESCUE line with the car's state
## the tick before and an OFF line per spell beyond the verge.
func _watch(e: Dictionary, s: float, clock: float) -> void:
	var car: Car = e["car"]
	var bot: RaceBot = e["bot"]
	var i := bot.sense.hint
	var lat := track.lateral(i, car.global_position)
	var edge := track.half_width(i) + track.verge
	var v := car.linear_velocity.dot(track.forward(i))
	var verbose: bool = opts["verbose"] == "1"
	if bot.rescues != int(e.get("rescues", 0)):
		e["rescues"] = bot.rescues
		e["rescued_at"] = clock
		if verbose:
			var p: Array = e.get("prev", [s, lat, v, 1.0, ""])
			print("RESCUE %s pace=%.2f t=%.1f s=%.0f, the tick before: lat=%.1f m (edge %.1f) lane=%.1f speed=%.1f m/s up=%.2f touching %s" % [
					e.get("who", e["car_id"]), e["pace"], clock, p[0], p[1], edge, bot.lane, p[2], p[3], p[4]])
	if not verbose:
		return
	var touching := PackedStringArray()
	var state := PhysicsServer3D.body_get_direct_state(car.get_rid())
	for c in state.get_contact_count():
		var o := state.get_contact_collider_object(c) as Node
		touching.append(str(o.get_path()).get_file() if o != null else "?")
	e["prev"] = [s, lat, v, car.global_basis.y.y, ",".join(touching)]
	var spell: Array = e.get("spell", [])
	if absf(lat) > edge:
		if spell.is_empty():
			e["spell"] = [s, absf(lat) - edge, v, clock, lat - bot.lane]
		else:
			spell[1] = maxf(spell[1], absf(lat) - edge)
	elif not spell.is_empty():
		print("OFF %s pace=%.2f t=%.1f s=%.0f..%.0f %.1f s, up to %.1f m past the verge, %.1f m/s, lat-lane %.1f" % [
				e.get("who", e["car_id"]), e["pace"], spell[3], spell[0], s, clock - float(spell[3]), spell[1], spell[2], spell[4]])
		e["spell"] = []


func _free(entries: Array[Dictionary]) -> void:
	for e in entries:
		(e["car"] as Car).queue_free()
	await physics_frame
	await physics_frame


func _pace_path() -> String:
	return "res://assets/ai/pace/%s.json" % opts["route"]


func _pace_data() -> Dictionary:
	var path := _pace_path()
	if not FileAccess.file_exists(path):
		return {}
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return d if d is Dictionary else {}


func _save(d: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://assets/ai/pace"))
	var f := FileAccess.open(_pace_path(), FileAccess.WRITE)
	f.store_string(JSON.stringify(d, "", false) + "\n")
	f.close()
	print("WROTE %s" % _pace_path())


# ---------------------------------------------------------------- record

func _record() -> void:
	var laps := int(opts["laps"]) if opts["laps"] != "" else 3
	var entries: Array[Dictionary] = []
	for k in RECORD_CARS:
		var e := _spawn("sakura", INF, k * 4, false)
		e["grid_s"] = track.start_s
		e["grid_lat"] = 0.0
		e["lap_samples"] = [] # [bin, speed] of the lap in progress, kept when it had no rescue
		e["lap_rescues"] = 0
		entries.append(e)
	await _line_up(entries, true)
	var step := 2.0
	var bins := int(ceil((track.length if track.closed else track.last_s - track.first_s) / step))
	var sum := PackedFloat64Array()
	var cnt := PackedInt32Array()
	sum.resize(bins)
	cnt.resize(bins)
	var clock := 0.0
	var dt := 1.0 / Engine.physics_ticks_per_second
	var rescues := 0
	var kept := 0
	while clock < float(opts["seconds"]):
		await physics_frame
		clock += dt
		var before := []
		for e in entries:
			before.append((e["laps"] as Array).size())
		_track_progress(entries, clock, laps)
		var left := 0
		for k in entries.size():
			var e := entries[k]
			var done: Array = e["laps"]
			var bot: RaceBot = e["bot"]
			var samples: Array = e["lap_samples"]
			if done.size() > before[k]:
				# a lap ended: flying laps only on a loop (an open road is one standing run),
				# and none the car was put back during
				if (not track.closed or before[k] > 0) and bot.rescues == e["lap_rescues"]:
					for sv: Array in samples:
						sum[sv[0]] += sv[1]
						cnt[sv[0]] += 1
					kept += 1
				samples.clear()
				e["lap_rescues"] = bot.rescues
			if done.size() >= laps:
				continue
			left += 1
			var car: Car = e["car"]
			var i := bot.sense.hint
			var s := track.abs_s(i, car.global_position)
			var b := int(fposmod(s, track.length) / step) if track.closed else int((s - track.first_s) / step)
			samples.append([clampi(b, 0, bins - 1), car.linear_velocity.dot(track.forward(i))])
		if left == 0:
			break
	for e in entries:
		rescues += (e["bot"] as RaceBot).rescues
		print("RECORD laps=%s rescues=%d" % [", ".join((e["laps"] as Array).map(func(t: float) -> String: return "%.2f" % t)),
				(e["bot"] as RaceBot).rescues])
	print("RECORD kept %d laps without a rescue" % kept)
	# gaps (never driven over, e.g. the lead-in of an open road) take the nearest recorded speed
	var raw := PackedFloat32Array()
	raw.resize(bins)
	var last := -1.0
	for b in bins:
		raw[b] = float(sum[b] / cnt[b]) if cnt[b] > 0 else -1.0
	for b in bins:
		if raw[b] >= 0.0:
			last = raw[b]
		elif last >= 0.0:
			raw[b] = last
	for b in range(bins - 1, -1, -1):
		if raw[b] >= 0.0:
			last = raw[b]
		else:
			raw[b] = last
	var v_ref := []
	for b in bins:
		var total := 0.0
		for k in range(-SMOOTH_BINS, SMOOTH_BINS + 1):
			total += raw[wrapi(b + k, 0, bins) if track.closed else clampi(b + k, 0, bins - 1)]
		v_ref.append(snappedf(total / (2 * SMOOTH_BINS + 1), 0.01))
	var p0 := track.point(0)
	_save({"route": opts["route"], "closed": track.closed, "length": snappedf(track.length, 0.01),
			"origin": [snappedf(p0.x, 0.01), snappedf(p0.z, 0.01)], "half_width": snappedf(track.half_width(0), 0.01),
			"step": step, "car": "sakura",
			"laps_recorded": kept, "v_ref": v_ref})
	await _free(entries)


# ---------------------------------------------------------------- calibrate

func _calibrate() -> void:
	var d := _pace_data()
	if not d.has("v_ref"):
		printerr("race_probe: record v_ref first (mode=record)")
		return
	var laps := int(opts["laps"]) if opts["laps"] != "" else 3
	var cars: PackedStringArray = (opts["car"] if opts["car"] != "" else "sakura,hayate").split(",")
	var paces: PackedFloat64Array = []
	for p in str(opts["paces"]).split(","):
		paces.append(float(p))
	var entries: Array[Dictionary] = []
	for c in cars:
		for p in paces:
			var e := _spawn(c, p, entries.size() % DriveHands.DECISION_TICKS, false)
			e["grid_s"] = track.start_s
			e["grid_lat"] = 0.0
			e["line_v"] = []
			entries.append(e)
	await _line_up(entries, true)
	var clock := 0.0
	var dt := 1.0 / Engine.physics_ticks_per_second
	while clock < float(opts["seconds"]):
		await physics_frame
		clock += dt
		var before := []
		for e in entries:
			before.append((e["laps"] as Array).size())
		_track_progress(entries, clock, laps)
		var left := 0
		for k in entries.size():
			var e := entries[k]
			var done: Array = e["laps"]
			if done.size() > before[k] and done.size() < laps:
				(e["line_v"] as Array).append((e["car"] as Car).linear_velocity.length())
			if done.size() < laps:
				left += 1
		if left == 0:
			break
	var table := {}
	for c in cars:
		var rows := []
		for e in entries:
			if e["car_id"] != c:
				continue
			var done: Array = e["laps"]
			var bot: RaceBot = e["bot"]
			if done.size() < laps:
				print("CAL car=%s pace=%.2f unfinished rescues=%d" % [c, e["pace"], bot.rescues])
				continue
			var flying := 0.0
			for k in range(1, laps):
				flying += float(done[k])
			flying /= laps - 1
			var line_v := 0.0
			for v: float in e["line_v"]:
				line_v += v
			line_v /= maxf((e["line_v"] as Array).size(), 1)
			rows.append({"pace": e["pace"], "standing": snappedf(done[0], 0.01), "flying": snappedf(flying, 0.01),
					"line_mps": snappedf(line_v, 0.01), "rescues": bot.rescues})
			print("CAL car=%s pace=%.2f standing=%.2f flying=%.2f (%s) line=%.1f km/h rescues=%d" % [c, e["pace"],
					done[0], flying, ", ".join(done.slice(1).map(func(t: float) -> String: return "%.2f" % t)),
					line_v * 3.6, bot.rescues])
		table[c] = rows
	d["laps"] = table
	_save(d)
	await _free(entries)


# ---------------------------------------------------------------- race

func _races() -> void:
	var laps := int(opts["laps"]) if opts["laps"] != "" else 2
	var runs := int(opts["runs"])
	var d := _pace_data()
	var medals: Dictionary = game.get_map(opts["route"]).get("medals", {})
	var field := _field()
	var n := field.size()
	var route: Dictionary = map.routes[opts["route"]]
	var spawn: Transform3D = route["spawn"]
	var s_spawn := track.abs_s(track.nearest(spawn.origin), spawn.origin)
	var totals := {"races": 0, "flips": 0, "rescues": 0, "overtakes": 0, "contacts": 0, "worst": 0.0, "bump": 0.0,
			"finish_contacts": 0, "grid_err": [], "flying_err": [], "off": 0.0, "finished": 0, "cars": 0}
	var cost := {"tick_usec": 0.0, "ticks": 0, "tick_max": 0.0}
	for run in runs:
		var rng := RandomNumberGenerator.new()
		rng.seed = run + 1
		var entries: Array[Dictionary] = []
		for g in n:
			var f: Dictionary = field[g]
			var pace: float = f["pace"] if f.has("pace") else RaceBot.pace_for_lap(opts["route"], float(medals["gold"]) * float(f["gold"]), f["car"])
			var e := _spawn(f["car"], pace, (g * 5 + run) % DriveHands.DECISION_TICKS, opts["contacts"] == "1")
			e["grid_s"] = s_spawn - GRID_GAP_M * g
			e["grid_lat"] = (-GRID_LAT_M if g % 2 == 0 else GRID_LAT_M) + rng.randf_range(-0.1, 0.1)
			e["grid"] = g + 1
			e["who"] = f["who"]
			e["cal"] = _cal_row(d, f["car"], pace)
			e.merge({"contacts": 0, "worst": 0.0, "flips": 0, "rolled": false, "off": 0.0, "overtakes": 0,
					"rescued_at": -INF, "rescues": 0, "finish_t": -1.0, "finish_pos": 0, "wander": 0.0, "bump": 0.0, "held": 0.0})
			(e["car"] as Car).bumped.connect(func(strength: float, _point: Vector3, _other: Car) -> void:
				if e["finish_t"] < 0.0:
					e["bump"] = maxf(e["bump"], strength))
			entries.append(e)
		await _line_up(entries)
		var ids := {}
		for k in n:
			ids[(entries[k]["car"] as Car).get_instance_id()] = k
		var order := {} # "i,j" -> +1 when i ahead of j
		for i in n:
			for j in range(i + 1, n):
				order["%d,%d" % [i, j]] = signf(float(entries[i]["prog"]) - float(entries[j]["prog"]))
		var touch := {"last": {}, "worst": {}, "finish": 0} # per pair: tick of the last contact, worst impulse
		var clock := 0.0
		var tick := 0
		var dt := 1.0 / Engine.physics_ticks_per_second
		var finished := 0
		var timed := false
		while finished < n and clock < float(opts["seconds"]):
			await physics_frame
			clock += dt
			tick += 1
			var ft := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1e6
			cost["tick_usec"] += ft
			cost["ticks"] += 1
			cost["tick_max"] = maxf(cost["tick_max"], ft)
			_contacts(entries, ids, tick, touch)
			_track_progress(entries, clock, laps)
			for k in n:
				var e := entries[k]
				var car: Car = e["car"]
				var rolled := car.global_basis.y.y < 0.2
				if rolled and not e["rolled"]:
					e["flips"] += 1
				e["rolled"] = rolled
				if e["finish_t"] >= 0.0:
					continue
				var bot: RaceBot = e["bot"]
				var i := bot.sense.hint
				var lat := track.lateral(i, car.global_position)
				if absf(lat) > track.half_width(i) + track.verge:
					e["off"] += dt
				e["wander"] = maxf(e["wander"], absf(lat - bot.lane))
				if bot.held:
					e["held"] += dt
				if (e["laps"] as Array).size() >= laps:
					finished += 1
					e["finish_t"] = clock
					e["finish_pos"] = finished
					_finish(e, route)
			if tick % DriveHands.DECISION_TICKS == 0:
				_overtakes(entries, order, clock)
			if not timed and clock > 30.0 and entries[n - 1]["finish_t"] < 0.0:
				timed = true
				_time_decision(entries[n - 1]["bot"], n)
		totals["finish_contacts"] += touch["finish"]
		_report(run, entries, laps, totals)
		await _free(entries)
	var r := maxf(totals["races"], 1)
	print("SUMMARY route=%s runs=%d laps=%d finished=%d/%d flips=%d rescues/race=%.2f overtakes/race=%.1f contacts/race=%.1f worst=%.0f Ns (%.2f m/s, bumped %.2f) finish_area_contacts/race=%.1f lap_err lap1 %s flying %s off=%.1f s/race" % [
			opts["route"], runs, laps, totals["finished"], totals["cars"], totals["flips"], totals["rescues"] / r,
			totals["overtakes"] / r, totals["contacts"] / r, totals["worst"], totals["worst"] / CAR_MASS, totals["bump"],
			totals["finish_contacts"] / r, _err_stats(totals["grid_err"]), _err_stats(totals["flying_err"]), totals["off"] / r])
	print("COST physics tick mean=%.0f us max=%.0f us over %d ticks" % [cost["tick_usec"] / maxf(cost["ticks"], 1),
			cost["tick_max"], cost["ticks"]])


## Lap time errors against the calibration: median, mean, max and the share within 2 s.
func _err_stats(errs: Array) -> String:
	if errs.is_empty():
		return "-"
	var sorted := errs.duplicate()
	sorted.sort()
	var within := sorted.filter(func(e: float) -> bool: return e <= 2.0).size()
	var total := 0.0
	for e: float in sorted:
		total += e
	return "median=%.2f mean=%.2f max=%.2f s within_2s=%d/%d" % [sorted[sorted.size() / 2], total / sorted.size(),
			sorted[sorted.size() - 1], within, sorted.size()]


## The race field in grid order (slot 0 = pole): the campaign rivals (Game.RIVALS) at their pace
## on this stage as multiples of gold, slowest first, the car models alternating, then the player's
## stand-in (`player` x gold, the last slot). `gold` (multiples) or `pace` (paces) in grid order
## replace the rivals.
func _field() -> Array[Dictionary]:
	var cars: PackedStringArray = (opts["car"] if opts["car"] != "" else "sakura,hayate").split(",")
	var out: Array[Dictionary] = []
	if opts["pace"] != "":
		var paces: PackedStringArray = str(opts["pace"]).split(",")
		for k in paces.size():
			out.append({"who": "bot%d" % (k + 1), "pace": float(paces[k]), "car": cars[k % cars.size()]})
		return out
	if opts["gold"] != "":
		var golds: PackedStringArray = str(opts["gold"]).split(",")
		for k in golds.size():
			out.append({"who": "bot%d" % (k + 1), "gold": float(golds[k]), "car": cars[k % cars.size()]})
		return out
	var stage := 0
	for leg: Dictionary in game.CAMPAIGN:
		if leg["kind"] != "stage":
			continue
		if leg["map"] == opts["route"]:
			break
		stage += 1
	var rivals: Array = game.RIVALS
	for k in rivals.size():
		out.append({"who": str(rivals[k]["name"]).split(" ")[0], "gold": float(rivals[k]["pace"][stage]),
				"car": cars[k % cars.size()]})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["gold"] > b["gold"])
	if float(opts["player"]) > 0.0:
		out.append({"who": "player", "gold": float(opts["player"]), "car": "sakura"})
	return out


## A finished car is handed over as Main does: its RaceBot goes, an ArrivalStop brings it to rest
## at the route's finish stop. It stays in the other bots' field.
func _finish(e: Dictionary, route: Dictionary) -> void:
	var car: Car = e["car"]
	(e["bot"] as RaceBot).queue_free()
	if not route.has("finish_stop"):
		return
	var stop := ArrivalStop.new()
	stop.name = "ArrivalStop"
	stop.track = track
	stop.target = route["finish_stop"]
	car.add_child(stop)


## Script cost of one bot decision (the network, then the racing on top), on a bot mid-race.
func _time_decision(bot: RaceBot, n: int) -> void:
	var t0 := Time.get_ticks_usec()
	for k in 100:
		bot.decide(0.0)
	var decide_us := (Time.get_ticks_usec() - t0) / 100.0
	t0 = Time.get_ticks_usec()
	for k in 100:
		bot._race(0.0)
	var race_us := (Time.get_ticks_usec() - t0) / 100.0
	print("COST decision: network %.0f us + racing %.0f us per bot; %d bots on %d phases -> %.0f us per tick on average" % [
			decide_us, race_us, n, mini(n, DriveHands.DECISION_TICKS), (decide_us + race_us) * n / DriveHands.DECISION_TICKS])


## Car-to-car contacts this tick: a new event per pair after CONTACT_GAP_TICKS apart, its worst
## impulse kept; an event between two finished cars only counts in touch["finish"].
func _contacts(entries: Array[Dictionary], ids: Dictionary, tick: int, touch: Dictionary) -> void:
	var last_touch: Dictionary = touch["last"]
	var event_worst: Dictionary = touch["worst"]
	for k in entries.size():
		var car: Car = entries[k]["car"]
		var state := PhysicsServer3D.body_get_direct_state(car.get_rid())
		if state == null:
			continue
		for c in state.get_contact_count():
			var j: int = ids.get(state.get_contact_collider_id(c), -1)
			if j < 0:
				continue
			var key := "%d,%d" % [mini(k, j), maxi(k, j)]
			var racing: bool = entries[k]["finish_t"] < 0.0 or entries[j]["finish_t"] < 0.0
			var imp := state.get_contact_impulse(c).length()
			if tick - int(last_touch.get(key, -1000)) > CONTACT_GAP_TICKS:
				event_worst[key] = 0.0
				if racing:
					for m: int in [k, j]:
						entries[m]["contacts"] += 1
				else:
					touch["finish"] += 1
			last_touch[key] = tick
			if racing and imp > float(event_worst[key]):
				event_worst[key] = imp
				for m: int in [k, j]:
					entries[m]["worst"] = maxf(entries[m]["worst"], imp)


## Places gained on track: pair order flips by more than SWAP_M, neither car just rescued nor done.
func _overtakes(entries: Array[Dictionary], order: Dictionary, clock: float) -> void:
	for i in entries.size():
		for j in range(i + 1, entries.size()):
			var a := entries[i]
			var b := entries[j]
			var diff: float = float(a["prog"]) - float(b["prog"])
			var key := "%d,%d" % [i, j]
			if absf(diff) < SWAP_M or signf(diff) == order[key]:
				continue
			order[key] = signf(diff)
			if a["finish_t"] >= 0.0 or b["finish_t"] >= 0.0:
				continue
			if clock - float(a["rescued_at"]) < RESCUE_QUIET_S or clock - float(b["rescued_at"]) < RESCUE_QUIET_S:
				continue
			entries[i if diff > 0.0 else j]["overtakes"] += 1


## The calibration row at `pace` for `car_id`, interpolated: standing, flying, line_mps.
func _cal_row(d: Dictionary, car_id: String, pace: float) -> Dictionary:
	var rows: Array = (d.get("laps", {}) as Dictionary).get(car_id, [])
	if rows.is_empty():
		return {}
	if pace <= float(rows[0]["pace"]):
		return rows[0]
	for k in range(1, rows.size()):
		var a: Dictionary = rows[k - 1]
		var b: Dictionary = rows[k]
		if pace <= float(b["pace"]):
			var t := (pace - float(a["pace"])) / (float(b["pace"]) - float(a["pace"]))
			var out := {}
			for key: String in ["standing", "flying", "line_mps"]:
				out[key] = lerpf(float(a[key]), float(b[key]), t)
			return out
	return rows[rows.size() - 1]


func _report(run: int, entries: Array[Dictionary], laps: int, totals: Dictionary) -> void:
	var race := {"flips": 0, "rescues": 0, "overtakes": 0, "contacts": 0, "worst": 0.0, "bump": 0.0, "off": 0.0, "finished": 0}
	for e in entries:
		var done: Array = e["laps"]
		var cal: Dictionary = e["cal"]
		var want := []
		if not cal.is_empty():
			var grid_d: float = track.start_s - float(e["grid_s"])
			want.append(float(cal["standing"]) + grid_d / maxf(float(cal["line_mps"]), 1.0))
			for k in range(1, laps):
				want.append(float(cal["flying"]))
		for k in done.size():
			if k < want.size():
				(totals["grid_err" if k == 0 else "flying_err"] as Array).append(absf(float(done[k]) - float(want[k])))
		print("BOT run=%d grid=%d %s car=%s pace=%.3f finish=%s laps=%s cal=%s overtakes=%d contacts=%d worst=%.0f Ns (%.2f m/s, bumped %.2f) rescues=%d flips=%d off=%.1f s wander=%.1f m held=%.1f s" % [
				run + 1, e["grid"], e["who"], e["car_id"], e["pace"], str(e["finish_pos"]) if e["finish_pos"] > 0 else "-",
				",".join(done.map(func(t: float) -> String: return "%.2f" % t)),
				",".join(want.map(func(t: float) -> String: return "%.2f" % t)),
				e["overtakes"], e["contacts"], e["worst"], float(e["worst"]) / CAR_MASS, e["bump"], e["rescues"], e["flips"],
				e["off"], e["wander"], e["held"]])
		race["flips"] += e["flips"]
		race["rescues"] += e["rescues"]
		race["overtakes"] += e["overtakes"]
		race["contacts"] += e["contacts"]
		race["worst"] = maxf(race["worst"], e["worst"])
		race["bump"] = maxf(race["bump"], e["bump"])
		race["off"] += e["off"]
		race["finished"] += 1 if e["finish_pos"] > 0 else 0
	race["contacts"] /= 2 # each event counted for both cars
	print("RACE run=%d route=%s laps=%d finished=%d/%d flips=%d rescues=%d overtakes=%d contacts=%d worst=%.0f Ns (%.2f m/s, bumped %.2f) off=%.1f s" % [
			run + 1, opts["route"], laps, race["finished"], entries.size(), race["flips"], race["rescues"],
			race["overtakes"], race["contacts"], race["worst"], race["worst"] / CAR_MASS, race["bump"], race["off"]])
	totals["races"] += 1
	totals["cars"] += entries.size()
	for key: String in ["flips", "rescues", "overtakes", "contacts", "off", "finished"]:
		totals[key] += race[key]
	totals["worst"] = maxf(totals["worst"], race["worst"])
	totals["bump"] = maxf(totals["bump"], race["bump"])
