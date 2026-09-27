extends SceneTree
## Missed corners: for every corner of a route of the world (map.json `routes.<id>.corners`,
## written by mapgen's lib/roadside.py), a car arrives on the road and stops turning - once at turn-in and once
## halfway from turn-in to the apex - at the corner's plausible entry speed, its approach speed
## (no braking at all) and 1.2 x that, then coasts straight on with the wheel centred. The
## probe reports where it ends up: kept on the road by a rail (`rail`), held by the ground
## (`ground`: it left the road but stopped at most DROP m below it, inside the play area), or
## `FLYOFF` (ended more than DROP m below the road - the corner's own stretch, or the stretch it
## came to rest beside -, fell more than DROP m below the road's level in one jump, ended outside
## the play area - the pack's `bounds` rectangle -, or on its roof).
##
##   S=/Applications/Summer.app/Contents/MacOS/Summer
##   timeout 1800 nice -n 5 $S --headless --disable-crash-handler --fixed-fps 60 --path . \
##       -s res://tools/physics/flyoff_probe.gd -- map=hanami|momiji|liaison [car=sakura] [corners=/abs/path.json] \
##       [only=0,3] [json=/tmp/flyoff_momiji.json] [trace=1]
##
## map= is a route id. corners= reads the corner list from a file instead of the pack (the
## same `corners` array; lets the probe judge a pack built without the road safety pass). only= limits the run to corner indices;
## trace=1 prints the car every 0.125 s after the release.
## Each run: 60 m of run-up on the road holding the speed (lane-kept on the centre line), the
## release, then at most 10 s coasting (stops early once the car is still or clearly gone).
## Prints one line per run, one per corner (worst run) and a summary line:
##   FLYOFF_SUMMARY map=.. corners=N runs=N flyoffs=N rail=N ground=N road=N

const MapLapRunner := preload("res://tools/physics/map_lap_runner.gd")
const DT := 1.0 / 120.0
const RUN_UP := 60.0
const DROP := 3.0
const LIMIT := 10.0
const SPEED_FACTORS := [["entry", 0.0], ["approach", 1.0], ["over", 1.2]]
const V_CAP_KMH := 185.0

var opts := {"map": "hanami", "car": "sakura", "corners": "", "only": "", "json": "", "trace": ""}
var map: MapWorld
var car: Car
## The world pack's play area [x0, z0, x1, z1] (map.json `bounds`).
var bounds := Rect2(-800.0, -800.0, 1600.0, 1600.0)


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	_run.call_deferred()


func _run() -> void:
	var game := root.get_node("Game")
	map = await MapLapRunner.build_map(self, opts["map"])
	var b: Array = map.info.get("bounds", [-800.0, -800.0, 800.0, 800.0])
	bounds = Rect2(b[0], b[1], b[2] - b[0], b[3] - b[1])
	var corners: Array = ((map.info.get("routes", {}) as Dictionary).get(map.route_id, {}) as Dictionary).get("corners", [])
	if opts["corners"] != "":
		corners = JSON.parse_string(FileAccess.get_file_as_string(opts["corners"]))
	var only := {}
	for s in str(opts["only"]).split(",", false):
		only[int(s)] = true
	car = (load(str(game.get_car(opts["car"])["scene"])) as PackedScene).instantiate() as Car
	car.auto_reset_time = 1.0e9
	root.add_child(car)
	car.controlled_by_player = false
	await physics_frame
	var totals := {"runs": 0, "flyoffs": 0, "rail": 0, "ground": 0, "road": 0}
	var report: Array = []
	for ci in corners.size():
		if not only.is_empty() and not only.has(ci):
			continue
		var c: Dictionary = corners[ci]
		var worst := {}
		var outcomes := []
		for start_key in ["turn_in", "mid"]:
			for f: Array in SPEED_FACTORS:
				var kmh: float = c["v_entry"] if f[1] == 0.0 else minf(float(c["v_approach"]) * f[1], V_CAP_KMH)
				var r := await _miss(c, c[start_key], kmh)
				r["start"] = start_key
				r["speed"] = f[0]
				outcomes.append(r)
				totals["runs"] += 1
				totals[r["outcome"] if r["outcome"] != "FLYOFF" else "flyoffs"] += 1
				print("RUN corner=%d %s %s start=%s speed=%s %.0f km/h -> %s drop=%.1f m fall=%.1f m off=%.1f m rail=%s air=%.2f s end=(%.0f, %.0f)%s" % [
						ci, c["kind"], c["dir"], start_key, f[0], kmh, r["outcome"], r["drop"], r["fall"], r["off"], r["rail"],
						r["air"], r["end"].x, r["end"].z, "" if not r["rail"] else " scrape: loss %.0f%% yaw %.0f deg/s turned %.0f deg" % [
						r["loss"] * 100.0, r["yaw"], rad_to_deg(r["turned"])]])
				if worst.is_empty() or _rank(r) > _rank(worst):
					worst = r
		var ti: Dictionary = c["turn_in"]
		print("CORNER %d %s %s R=%.0f s=%.0f (%.0f, %.0f) v_entry=%.0f v_approach=%.0f -> %s (worst drop %.1f m)" % [
				ci, c["kind"], c["dir"], c["radius"], ti["s"], ti["pos"][0], ti["pos"][2], c["v_entry"],
				c["v_approach"], worst["outcome"], worst["drop"]])
		report.append({"corner": ci, "kind": c["kind"], "dir": c["dir"], "s": ti["s"], "worst": worst["outcome"],
				"drop": worst["drop"], "runs": outcomes.map(func(o: Dictionary) -> Dictionary:
					return {"start": o["start"], "speed": o["speed"], "kmh": o["kmh"], "outcome": o["outcome"],
							"drop": o["drop"], "fall": o["fall"], "off": o["off"], "rail": o["rail"], "end": [o["end"].x, o["end"].y, o["end"].z],
							"loss": o["loss"], "yaw": o["yaw"], "turned": rad_to_deg(o["turned"])})})
	print("FLYOFF_SUMMARY map=%s car=%s corners=%d runs=%d flyoffs=%d rail=%d ground=%d road=%d" % [
			opts["map"], opts["car"], report.size(), totals["runs"], totals["flyoffs"], totals["rail"], totals["ground"],
			totals["road"]])
	if opts["json"] != "":
		var fa := FileAccess.open(opts["json"], FileAccess.WRITE)
		fa.store_string(JSON.stringify({"map": opts["map"], "car": opts["car"], "totals": totals, "corners": report}, " "))
		fa.close()
	game.request_quit(0)


func _rank(r: Dictionary) -> float:
	var base := {"road": 0.0, "rail": 1.0, "ground": 2.0, "FLYOFF": 3.0}
	return base[r["outcome"]] * 1000.0 + r["drop"]


## One missed corner: run-up to `pose` at `kmh`, release, coast. Returns {outcome, drop (m below
## the road at the end), off (farthest beyond the road edge), rail (touched Barriers), air
## (longest airborne spell), end, kmh, and after a rail contact: loss (speed share lost in 0.5 s),
## yaw (peak heading rate, deg/s over 0.1 s) and turned (total heading change, rad)}.
func _miss(c: Dictionary, pose: Dictionary, kmh: float) -> Dictionary:
	var track := map.track
	var p0 := Vector3(pose["pos"][0], pose["pos"][1], pose["pos"][2])
	var i0 := track.nearest(p0)
	var s_rel := track.abs_s(i0, p0)
	var s0 := s_rel - RUN_UP
	if not track.closed:
		s0 = maxf(s0, track.first_s)
	car.input_throttle = 0.0
	car.input_brake = 0.0
	car.input_steer = 0.0
	car.input_handbrake = false
	car.place_at_rest(track.transform_at_abs(s0))
	await physics_frame
	var v := kmh / 3.6
	car.linear_velocity = -car.global_basis.z * v
	for w: WheelState in car.wheels:
		w.spin_speed = v / 0.33
	await physics_frame
	# run-up: lane keeping on the centre line, holding the speed, until the release point
	var hint := track.nearest(car.global_position)
	var t := 0.0
	while t < 12.0:
		var pos := car.global_position
		hint = track.nearest(pos, hint, 20)
		var along := wrapf(track.abs_s(hint, pos) - s_rel, -track.length * 0.5, track.length * 0.5) if track.closed \
				else track.abs_s(hint, pos) - s_rel
		if along >= 0.0:
			break
		var look := maxf(8.0, car.linear_velocity.length() * 0.45)
		var target := track.position_at_abs(track.abs_s(hint, pos) + look)
		var local := car.global_transform.affine_inverse() * target
		var want := atan2(local.x, -local.z)
		car.input_steer = clampf(want / maxf(car.steer_lock_at(car.speed_kmh), 0.05), -1.0, 1.0)
		var err := kmh - car.speed_kmh
		car.input_throttle = clampf(err * 0.3, 0.0, 1.0)
		car.input_brake = clampf(-err * 0.2, 0.0, 1.0)
		await physics_frame
		t += DT
	# release: wheel centred, off the pedals
	car.input_steer = 0.0
	car.input_throttle = 0.0
	car.input_brake = 0.0
	var path: Array = c["path"]
	var res := {"outcome": "road", "drop": 0.0, "off": 0.0, "rail": false, "air": 0.0, "end": car.global_position,
			"kmh": car.speed_kmh, "loss": 0.0, "yaw": 0.0, "turned": 0.0, "fall": 0.0}
	var still := 0.0
	var air := 0.0
	var take_off_y := NAN
	var hit_t := -1.0
	var hit_kmh := 0.0
	var headings: Array[float] = []
	t = 0.0
	while t < LIMIT:
		await physics_frame
		t += DT
		var pos := car.global_position
		for b in car.get_colliding_bodies():
			if (b as Node).name == &"Barriers" and hit_t < 0.0:
				res["rail"] = true
				hit_t = t
				hit_kmh = car.speed_kmh
		if hit_t >= 0.0:
			# the wall scrape (docs/PHYSICS.md "Crashes and walls"): speed lost in the 0.5 s after
			# the first rail contact, the heading rate over 0.1 s windows and how far it turned
			var fwd := -car.global_basis.z
			headings.append(atan2(-fwd.x, -fwd.z))
			var k := headings.size() - 1
			if k > 0:
				res["turned"] += absf(wrapf(headings[k] - headings[k - 1], -PI, PI))
			if k >= 12:
				res["yaw"] = maxf(res["yaw"], rad_to_deg(absf(wrapf(headings[k] - headings[k - 12], -PI, PI))) / (12.0 * DT))
			if t - hit_t <= 0.5:
				res["loss"] = maxf(res["loss"], 1.0 - car.speed_kmh / maxf(hit_kmh, 1.0))
		air = air + DT if car.airborne_time > 0.0 else 0.0
		res["air"] = maxf(res["air"], air)
		var ref := _nearest_path(path, pos)
		res["off"] = maxf(res["off"], ref[1])
		# a fall: height lost below the road between leaving the ground and landing again (a car
		# that ran up a bank and jumps off its crest back down to the road's level has not fallen)
		if car.airborne_time > 0.0 and is_nan(take_off_y):
			take_off_y = minf(pos.y, ref[0])
		elif car.airborne_time <= 0.0 and not is_nan(take_off_y):
			res["fall"] = maxf(res["fall"], take_off_y - pos.y)
			take_off_y = NAN
		if opts["trace"] != "" and int(t / DT) % 15 == 0:
			var ti := track.nearest(pos)
			print("  TRACE t=%.2f s=%.0f lat=%.1f pos=(%.0f, %.1f, %.0f) kmh=%.0f drop=%.1f rail=%s air=%.2f" % [
					t, track.abs_s(ti, pos), track.lateral(ti, pos), pos.x, pos.y, pos.z, car.speed_kmh, ref[0] - pos.y,
					res["rail"], car.airborne_time])
		var drop: float = ref[0] - pos.y
		if drop > DROP + 5.0 or not bounds.grow(20.0).has_point(Vector2(pos.x, pos.z)):
			break # clearly gone
		still = still + DT if car.linear_velocity.length() < 1.0 else 0.0
		if still > 0.5:
			break
	var end := car.global_position
	var ref_end := _nearest_path(path, end)
	res["end"] = end
	# below the corner's road, or below whatever stretch of the road it came to rest beside (a car
	# that ran straight on down to the road's next loop is back on the road, unless it fell there)
	var ti_end := track.nearest(end)
	var beside := track.point(ti_end).y if absf(track.lateral(ti_end, end)) < track.half_width(ti_end) + 8.0 else INF
	res["drop"] = maxf(minf(ref_end[0], beside) - end.y, 0.0)
	if not is_nan(take_off_y):
		res["fall"] = maxf(res["fall"], take_off_y - end.y)
	var outside := not bounds.has_point(Vector2(end.x, end.z))
	var on_roof := car.global_basis.y.y < 0.3
	if res["drop"] > DROP or res["fall"] > DROP or outside or on_roof:
		res["outcome"] = "FLYOFF"
	elif res["rail"]:
		res["outcome"] = "rail"
	elif res["off"] > 0.5:
		res["outcome"] = "ground"
	return res


## [road height of the nearest centreline point (XZ), metres beyond the road edge there].
func _nearest_path(path: Array, pos: Vector3) -> Array:
	var best := INF
	var bi := 0
	for k in path.size():
		var q: Array = path[k]
		var d := Vector2(q[0] - pos.x, q[2] - pos.z).length_squared()
		if d < best:
			best = d
			bi = k
	var q: Array = path[bi]
	return [float(q[1]), sqrt(best) - float(q[3])]
