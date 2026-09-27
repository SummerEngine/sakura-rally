extends SceneTree
## Car-to-car contacts (docs/PHYSICS.md "Car contacts"): scripted scenarios on the real world pack
## with `Car.car_contacts` on for every car, on a straight and at a braking corner of a stage loop.
## Every car is driven by a lane keeper of its own (pure pursuit to a point `lat` metres right of
## the centre line, throttle/brake to a speed), so each run is the same run every time.
##
##   S=/Applications/Summer.app/Contents/MacOS/Summer
##   timeout -k 10 1800 nice -n 10 $S --headless --disable-crash-handler --fixed-fps 120 --path . \
##       -s res://tools/physics/contact_probe.gd -- [map=hanami] [sets=sakura,hayate,mixed,mixed2] \
##       [only=swipe,rear20,rear40,brake,punt,tbone,wreck,tbone100,squeeze,rest_side,rest_nose,tangle,grid] \
##       [trace=1] [raw=1]
##
## raw=1 lifts the car-contact limits (`Car.bump_*` = INF): the solver's own answer, for comparison.
##
## Scenarios (A = the car that does it, B = the car it is done to):
##   swipe      straight, both at 100 km/h side by side (±1.25 m), A's nose beside B's rear door; at
##              1 s A is shoved 3 m/s sideways towards B and steers into B's lane until 0.6 s after
##              the first touch, then back to its own.
##   rear20/40  straight, B ahead at 80 km/h; A comes from 7.8 m behind at 100 / 120 km/h and backs
##              off to 70 at the first touch.
##   brake      straight, both at 100 km/h, A 7.8 m behind B; B brakes to a stop at 0.5 s, A only
##              at 1 s: A runs into B with both noses down.
##   punt       corner entry, B on the centre line at 85 % of the corner's entry speed; A 0.8 m to
##              the outside of the corner, 25 km/h faster, backs off to 10 km/h under B's speed at
##              the first touch.
##   tbone      straight, B stopped across the road (turned 90°); A at 60 km/h into its side, then
##              brakes.
##   wreck      straight, B stopped on the centre line (a stalled or rescued car); A at 100 km/h,
##              0.5 m off-centre, into its tail, then brakes.
##   tbone100   tbone at 100 km/h.
##   squeeze    corner entry, three abreast (±2.2 m, or the road's room) at the entry speed + 10;
##              the lanes close to 45 % of their offset from 30 m before the turn-in to 20 m after
##              it, and are open again 40 m after it.
##   rest_side  straight, two cars parked touching side by side (1 cm overlap), no input, 10 s.
##   rest_nose  straight, two cars parked nose to tail (1 cm overlap), no input, 10 s.
##   tangle     straight, two cars parked with their hulls 0.35 m into each other, no input.
##   grid       the route's grid, 2 x 3 (rows 8 m apart, lanes ±2.4 m, swapped every row): 1.2 s
##              start-line hold, then everyone floors it in their lane for 5 s. Nobody lets go, so
##              a Sakura behind a Hayate pushes it for the rest of the run: here the contact time
##              is reported as "pushed" and separation is judged by the overlap alone.
## Car sets: pairs sakura/sakura, hayate/hayate, sakura A with hayate B (mixed) and the reverse
## (mixed2); three- and six-car runs alternate the two cars.
##
## Per car: max roll and pitch to the road, longest airborne spell, max heading rate against the
## road (over 0.1 s windows), how far the heading turned from where it started, lift (origin above
## the road), speed lost after the first touch (the speed before it minus the lowest in the next
## 1.5 s), time to separate (the longest car contact after the scenario lets go - the pusher backs
## off or steers back - where a spell that ends with every car still is a resting contact, not a
## tangle), the deepest hull overlap with another car and the longest time it stayed over
## DEPTH_SLOP (a tangle: Jolt leaves resting hulls about 2 cm into each other), farthest beyond the
## road edge, flips
## and resets, and the `bumped` / `impact` signals it sent. The resting runs report the drift
## (largest 0.5 s average speed after 1 s of settling).
## Prints RUN lines per car, one CHECK line per run and car (PASS/FAIL with each threshold) and
##   CONTACT_SUMMARY map=.. runs=N checks=N failed=N

const MapLapRunner := preload("res://tools/physics/map_lap_runner.gd")
const DT := 1.0 / 120.0
const CAR_HALF_LEN := 2.1
const CAR_HALF_WIDTH := 0.9
## CHECK thresholds.
const MAX_ROLL_DEG := 35.0
const MAX_AIR_S := 0.25
const MAX_SEPARATE_S := 1.5
const MAX_REST_DRIFT := 0.05
const MAX_LIFT_M := 0.3
const MAX_TURN_DEG := 45.0
## Hull overlap (m) above which two cars are tangled.
const DEPTH_SLOP := 0.05
## Contact spells closer together than this merge into one (s).
const SPELL_GAP := 0.1
## Below this speed (m/s) a car counts as still.
const STILL := 0.3

var opts := {"map": "hanami", "sets": "sakura,hayate,mixed,mixed2", "only": "", "trace": "", "raw": ""}
var game: Node
var map: MapWorld
var track: Track
var straight_s := 0.0
var corner: Dictionary = {}
var totals := {"runs": 0, "checks": 0, "failed": 0}


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	_run.call_deferred()


func _run() -> void:
	game = root.get_node("Game")
	map = await MapLapRunner.build_map(self, opts["map"])
	track = map.track
	straight_s = _find_straight(400.0)
	corner = _find_corner()
	print("CONTACT map=%s road half width %.1f m, straight s=%.0f, corner %s %s R=%.0f s=%.0f entry %.0f km/h" % [
			opts["map"], track.half_width(track.index_at_abs(straight_s)), straight_s, corner["kind"], corner["dir"],
			corner["radius"], corner["turn_in"]["s"], corner["v_entry"]])
	var only := {}
	for s in str(opts["only"]).split(",", false):
		only[s] = true
	var scenarios := ["swipe", "rear20", "rear40", "brake", "punt", "tbone", "wreck", "tbone100", "squeeze", "rest_side", "rest_nose", "tangle", "grid"]
	for set_name in str(opts["sets"]).split(",", false):
		for sc: String in scenarios:
			if only.is_empty() or only.has(sc):
				await _scenario(sc, set_name)
	print("CONTACT_SUMMARY map=%s runs=%d checks=%d failed=%d" % [opts["map"], totals["runs"], totals["checks"], totals["failed"]])
	game.request_quit(0)


## Car ids for `n` cars of a set: A first.
func _ids(set_name: String, n: int) -> Array[String]:
	var out: Array[String] = []
	for k in n:
		match set_name:
			"sakura", "hayate":
				out.append(set_name)
			"mixed":
				out.append("sakura" if k % 2 == 0 else "hayate")
			_:
				out.append("hayate" if k % 2 == 0 else "sakura")
	return out


## Start of the straightest `span` metres of the route (least total turning).
func _find_straight(span: float) -> float:
	var best := INF
	var best_s := 0.0
	var s := 0.0
	while s < track.length - (0.0 if track.closed else span):
		var turn := 0.0
		var prev := track.forward_at_abs(s)
		var d := 10.0
		while d <= span:
			var f := track.forward_at_abs(s + d)
			turn += absf(Vector2(prev.x, prev.z).angle_to(Vector2(f.x, f.z)))
			prev = f
			d += 10.0
		if turn < best:
			best = turn
			best_s = s
		s += 10.0
	return best_s


## The first sharp corner of the route with a braking zone (approach at least 30 km/h over entry).
func _find_corner() -> Dictionary:
	var corners: Array = ((map.info.get("routes", {}) as Dictionary).get(map.route_id, {}) as Dictionary).get("corners", [])
	for c: Dictionary in corners:
		if c["kind"] == "sharp" and float(c["v_approach"]) - float(c["v_entry"]) >= 30.0:
			return c
	return corners[0]


# ---------------------------------------------------------------- scenarios

func _scenario(sc: String, set_name: String) -> void:
	var st := straight_s
	var c_s: float = corner["turn_in"]["s"]
	var outside := 1.0 if corner["dir"] == "left" else -1.0
	var v_e: float = float(corner["v_entry"]) * 0.85
	var room := track.half_width(track.index_at_abs(c_s)) - CAR_HALF_WIDTH - 0.2
	# ctx: shared state the plans read and write (first touch time, release time, ...)
	var ctx := {"first": -1.0, "release": -1.0, "rest": false, "hold": 0.0, "floored": false}
	var specs: Array = []
	var duration := 6.0
	match sc:
		"swipe":
			# A's nose alongside B's rear door; at 1 s A is shoved 3 m/s sideways towards B and
			# steers into B's lane until 0.6 s after the touch
			specs = [
				{"s": st + 97.2, "lat": -1.25, "kmh": 100.0, "kick": [1.0, 3.0], "plan": func(t: float) -> Array:
					var push: bool = t > 1.0 and (ctx["first"] < 0.0 or t < ctx["first"] + 0.6)
					if not push and ctx["first"] >= 0.0 and ctx["release"] < 0.0:
						ctx["release"] = t
					return [1.25 if push else -1.25, 100.0]},
				{"s": st + 100.0, "lat": 1.25, "kmh": 100.0, "plan": func(_t: float) -> Array: return [1.25, 100.0]},
			]
		"rear20", "rear40":
			var dv := 20.0 if sc == "rear20" else 40.0
			specs = [
				{"s": st + 48.0, "lat": 0.0, "kmh": 80.0 + dv, "plan": func(_t: float) -> Array:
					return [0.0, 70.0 if ctx["first"] >= 0.0 else 80.0 + dv]},
				{"s": st + 60.0, "lat": 0.0, "kmh": 80.0, "plan": func(_t: float) -> Array: return [0.0, 80.0]},
			]
		"brake":
			specs = [
				{"s": st + 48.0, "lat": 0.0, "kmh": 100.0, "plan": func(t: float) -> Array:
					return [0.0, 100.0 if t < 1.0 else 0.0]},
				{"s": st + 60.0, "lat": 0.0, "kmh": 100.0, "plan": func(t: float) -> Array:
					return [0.0, 100.0 if t < 0.5 else 0.0]},
			]
			duration = 5.0
		"wreck":
			specs = [
				{"s": st + 40.0, "lat": 0.5, "kmh": 100.0, "plan": func(_t: float) -> Array:
					return [0.5, 0.0 if ctx["first"] >= 0.0 else 100.0]},
				{"s": st + 80.0, "lat": 0.0, "kmh": 0.0, "plan": func(_t: float) -> Array: return [0.0, -1.0]},
			]
		"tbone100":
			specs = [
				{"s": st + 40.0, "lat": 0.0, "kmh": 100.0, "plan": func(_t: float) -> Array:
					return [0.0, 0.0 if ctx["first"] >= 0.0 else 100.0]},
				{"s": st + 80.0, "lat": 0.0, "kmh": 0.0, "yaw": -PI * 0.5, "plan": func(_t: float) -> Array: return [0.0, -1.0]},
			]
		"punt":
			specs = [
				{"s": c_s - 37.0, "lat": 0.8 * outside, "kmh": v_e + 25.0, "plan": func(_t: float) -> Array:
					return [0.8 * outside, v_e - 10.0 if ctx["first"] >= 0.0 else v_e + 25.0]},
				{"s": c_s - 25.0, "lat": 0.0, "kmh": v_e, "plan": func(_t: float) -> Array: return [0.0, v_e]},
			]
		"tbone":
			specs = [
				{"s": st + 60.0, "lat": 0.0, "kmh": 60.0, "plan": func(_t: float) -> Array:
					return [0.0, 0.0 if ctx["first"] >= 0.0 else 60.0]},
				{"s": st + 80.0, "lat": 0.0, "kmh": 0.0, "yaw": -PI * 0.5, "plan": func(_t: float) -> Array: return [0.0, -1.0]},
			]
		"squeeze":
			var lane := minf(2.2, room)
			for k in 3:
				var home := [-lane, 0.0, lane][k] as float
				specs.append({"s": c_s - 60.0, "lat": home, "kmh": v_e + 10.0, "plan": func(t: float) -> Array:
					var car_s: float = ctx["s%d" % k]
					var along: float = wrapf(car_s - c_s, -track.length * 0.5, track.length * 0.5)
					var close: float = smoothstep(-30.0, 0.0, along) * (1.0 - smoothstep(20.0, 40.0, along))
					if along > 40.0 and ctx["release"] < 0.0:
						ctx["release"] = t
					return [home * (1.0 - 0.55 * close), v_e + 10.0 if along < -30.0 else v_e]})
			duration = 7.0
		"rest_side", "rest_nose":
			ctx["rest"] = true
			duration = 10.0
			var side := sc == "rest_side"
			var gap := CAR_HALF_WIDTH if side else CAR_HALF_LEN
			var ds := 0.0 if side else gap - 0.005
			var dl := gap - 0.005 if side else 0.0
			specs = [
				{"s": st + 200.0 - ds, "lat": -dl, "kmh": 0.0, "plan": func(_t: float) -> Array: return [0.0, -1.0]},
				{"s": st + 200.0 + ds, "lat": dl, "kmh": 0.0, "plan": func(_t: float) -> Array: return [0.0, -1.0]},
			]
			ctx["release"] = 0.0
		"tangle":
			ctx["release"] = 0.0
			duration = 4.0
			specs = [
				{"s": st + 200.0, "lat": -(CAR_HALF_WIDTH - 0.175), "kmh": 0.0, "plan": func(_t: float) -> Array: return [0.0, -1.0]},
				{"s": st + 200.3, "lat": CAR_HALF_WIDTH - 0.175, "kmh": 0.0, "plan": func(_t: float) -> Array: return [0.0, -1.0]},
			]
		"grid":
			ctx["hold"] = 1.2
			ctx["release"] = 0.0
			ctx["floored"] = true
			duration = 6.2
			var s0 := track.abs_s(track.nearest(map.spawn.origin), map.spawn.origin)
			for k in 6:
				# lanes swap every row, so a mixed set has both cars in each lane
				var lat := -2.4 if (k + k / 2) % 2 == 0 else 2.4
				specs.append({"s": s0 - 8.0 * (k / 2), "lat": lat, "kmh": 0.0, "plan": func(t: float) -> Array:
					return [lat, 999.0 if t >= ctx["hold"] else 0.0]})
	var ids := _ids(set_name, specs.size())
	await _run_specs(sc, set_name, ids, specs, ctx, duration)


func _run_specs(sc: String, set_name: String, ids: Array[String], specs: Array, ctx: Dictionary, duration: float) -> void:
	var cars: Array[Car] = []
	var recs: Array[Dictionary] = []
	for k in specs.size():
		var car := (load(str(game.get_car(ids[k])["scene"])) as PackedScene).instantiate() as Car
		car.name = "Car%d" % k
		car.controlled_by_player = false
		root.add_child(car)
		car.car_contacts = true
		if opts["raw"] != "":
			car.bump_yaw_accel = INF
			car.bump_tilt_limit = INF
			car.bump_rise_accel = INF
		cars.append(car)
	await physics_frame
	for k in specs.size():
		var sp: Dictionary = specs[k]
		var xf := track.transform_at_abs(sp["s"], sp["lat"])
		if sp.has("yaw"):
			xf.basis = xf.basis.rotated(Vector3.UP, sp["yaw"])
		cars[k].place_at_rest(xf)
		cars[k].launch_hold = ctx["hold"] > 0.0
	await physics_frame
	for k in specs.size():
		var car := cars[k]
		var v: float = specs[k]["kmh"] / 3.6
		if v > 0.0:
			car.linear_velocity = -car.global_basis.z * v
			for w: WheelState in car.wheels:
				w.spin_speed = v / Car.WHEEL_RADIUS
		var rec := _new_rec(car, ids[k])
		recs.append(rec)
		car.impact.connect(func(s: float, _p: Vector3) -> void: rec["impacts"].append(s))
		if car.has_signal(&"bumped"):
			car.connect(&"bumped", func(s: float, _p: Vector3, _o: Node) -> void:
				rec["bumps"].append(s)
				_log_sound(sc, set_name, rec, s))
	var t := 0.0
	while t < duration:
		for k in cars.size():
			if specs[k].has("kick") and absf(t - specs[k]["kick"][0]) < DT * 0.5:
				cars[k].linear_velocity += track.right(recs[k]["hint"]) * float(specs[k]["kick"][1])
			ctx["s%d" % k] = track.abs_s(recs[k]["hint"], cars[k].global_position) if recs[k]["hint"] >= 0 else specs[k]["s"]
			var plan: Array = specs[k]["plan"].call(t)
			_drive(cars[k], recs[k], plan[0], plan[1])
			if ctx["hold"] > 0.0 and t >= ctx["hold"]:
				cars[k].launch_hold = false
		await physics_frame
		t += DT
		for k in cars.size():
			_record(cars[k], recs[k], t, ctx)
		if ctx["first"] < 0.0:
			for r: Dictionary in recs:
				if r["touch"]:
					ctx["first"] = t
					break
		if ctx["release"] < 0.0 and ctx["first"] >= 0.0 and sc in ["rear20", "rear40", "brake", "punt", "tbone", "wreck", "tbone100"]:
			ctx["release"] = ctx["first"]
		if opts["trace"] != "" and int(round(t / DT)) % 12 == 0:
			var line := "  TRACE %s t=%.2f" % [sc, t]
			for k in cars.size():
				var r: Dictionary = recs[k]
				line += " | %d %s lat=%.2f kmh=%.0f touch=%s head=%.0f" % [k, ids[k], r["lat"], cars[k].speed_kmh, r["touch"], r["herr"]]
			print(line)
	_report(sc, set_name, ids, cars, recs, ctx, t)
	for car in cars:
		car.queue_free()
	await physics_frame
	await physics_frame


## What the car's CarAudio fired for a `bumped` signal (its handler runs first): the contact
## one-shots (knock, thump, crash) that are playing, then stopped so the next bump shows only its
## own (the headless audio driver never finishes a sound).
func _log_sound(sc: String, set_name: String, rec: Dictionary, s: float) -> void:
	var car: Car = rec["car"]
	var audio := car.get_node_or_null(^"CarAudio")
	var played := []
	if audio != null:
		for p in audio.get_children():
			var a := p as AudioStreamPlayer3D
			if a == null or not a.playing or not a.stream is AudioStreamRandomizer:
				continue
			var n := _stream_name(a)
			if n in ["impact_light", "impact_heavy", "thump"]:
				played.append("%s %.1f dB x%.2f" % [n, a.volume_db, a.pitch_scale])
				a.stop()
	rec["sounds"].append("%.2f->%s" % [s, ",".join(played) if not played.is_empty() else "-"])


## The one-shot's sound files, e.g. "impact_light".
func _stream_name(p: AudioStreamPlayer3D) -> String:
	var rnd := p.stream as AudioStreamRandomizer
	if rnd.streams_count == 0 or rnd.get_stream(0) == null:
		return str(p.name)
	return rnd.get_stream(0).resource_path.get_file().get_basename().trim_suffix("_1")


func _new_rec(car: Car, id: String) -> Dictionary:
	return {"car": car, "id": id, "roll": 0.0, "pitch": 0.0, "air": 0.0, "yaw": 0.0, "turn": 0.0, "lift": 0.0,
			"off": -INF, "flipped": false, "resets": 0, "hint": -1, "prev": car.global_position, "herr": 0.0,
			"herr0": NAN, "heads": PackedFloat32Array(), "spells": [], "touch": false, "kmh_prev": [],
			"kmh_before": NAN, "kmh_min": INF, "first": -1.0, "positions": [], "drift": 0.0, "bumps": [],
			"impacts": [], "sounds": [], "lat": 0.0, "depth": 0.0, "tangled": 0.0, "tangle_cur": 0.0}


## Lane keeper: pure pursuit to `lat` m right of the centre line; kmh < 0 = hands off, 0 = brake
## to a stop, above the car's reach = floored.
func _drive(car: Car, rec: Dictionary, lat: float, kmh: float) -> void:
	if kmh < 0.0:
		car.input_steer = 0.0
		car.input_throttle = 0.0
		car.input_brake = 0.0
		return
	var pos := car.global_position
	var i := track.nearest(pos, rec["hint"], 20) if rec["hint"] >= 0 else track.nearest(pos)
	var s := track.abs_s(i, pos)
	var look := maxf(8.0, car.linear_velocity.length() * 0.45)
	var target := track.position_at_abs(s + look, lat)
	var local := car.global_transform.affine_inverse() * target
	var want := atan2(local.x, -local.z)
	car.input_steer = clampf(want / maxf(car.steer_lock_at(car.speed_kmh), 0.05), -1.0, 1.0)
	if car.launch_hold:
		car.input_throttle = 1.0 if kmh > 0.0 else 0.0
		car.input_brake = 0.0
		return
	var err := kmh - car.speed_kmh
	car.input_throttle = clampf(err * 0.3, 0.0, 1.0)
	car.input_brake = clampf(-err * 0.2, 0.0, 1.0) if kmh > 0.0 else 1.0


func _road_normal(s: float, lat: float) -> Vector3:
	var p0 := track.position_at_abs(s, lat - 1.0)
	var p1 := track.position_at_abs(s, lat + 1.0)
	var pf := track.position_at_abs(s + 1.0, lat)
	var pb := track.position_at_abs(s - 1.0, lat)
	return (p1 - p0).cross(pf - pb).normalized()


func _record(car: Car, rec: Dictionary, t: float, ctx: Dictionary) -> void:
	var pos := car.global_position
	var i := track.nearest(pos, rec["hint"], 20) if rec["hint"] >= 0 else track.nearest(pos)
	rec["hint"] = i
	var s := track.abs_s(i, pos)
	var lat := track.lateral(i, pos)
	rec["lat"] = lat
	var n := _road_normal(s, lat)
	var b := car.global_basis
	var fwd := -b.z
	rec["roll"] = maxf(rec["roll"], rad_to_deg(absf(asin(clampf(b.x.dot(n), -1.0, 1.0)))))
	rec["pitch"] = maxf(rec["pitch"], rad_to_deg(absf(asin(clampf(fwd.dot(n), -1.0, 1.0)))))
	if b.y.dot(n) < 0.3:
		rec["flipped"] = true
	rec["air"] = maxf(rec["air"], car.airborne_time)
	rec["lift"] = maxf(rec["lift"], (pos - track.position_at_abs(s, lat)).dot(n))
	rec["off"] = maxf(rec["off"], absf(lat) - track.half_width(i))
	if pos.distance_to(rec["prev"]) > 5.0:
		rec["resets"] += 1
	rec["prev"] = pos
	var road_f := track.forward_at_abs(s)
	var herr := rad_to_deg(atan2(fwd.dot(track.right(i)), fwd.dot(road_f)))
	if is_nan(rec["herr0"]):
		rec["herr0"] = herr
	rec["herr"] = herr
	var heads: PackedFloat32Array = rec["heads"]
	heads.append(herr)
	rec["heads"] = heads
	var k := heads.size() - 1
	if k >= 12:
		rec["yaw"] = maxf(rec["yaw"], absf(wrapf(heads[k] - heads[k - 12], -180.0, 180.0)) / (12.0 * DT))
	rec["turn"] = maxf(rec["turn"], absf(wrapf(herr - rec["herr0"], -180.0, 180.0)))
	# car contacts and their spells
	var touch := false
	for body in car.get_colliding_bodies():
		if body is Car:
			touch = true
			break
	rec["touch"] = touch
	var spells: Array = rec["spells"]
	if touch:
		if spells.is_empty() or t - spells[-1][1] > SPELL_GAP:
			spells.append([t, t])
		else:
			spells[-1][1] = t
	# hull overlap: the contact points on the two hulls are this far apart along the normal
	var depth := 0.0
	var st := PhysicsServer3D.body_get_direct_state(car.get_rid())
	for c in st.get_contact_count():
		if st.get_contact_collider_object(c) is Car:
			depth = maxf(depth, (st.get_contact_collider_position(c) - st.get_contact_local_position(c)).dot(st.get_contact_local_normal(c)))
	rec["depth"] = maxf(rec["depth"], depth)
	if depth > DEPTH_SLOP and t >= ctx["release"] and ctx["release"] >= 0.0:
		rec["tangle_cur"] += DT
		rec["tangled"] = maxf(rec["tangled"], rec["tangle_cur"])
	else:
		rec["tangle_cur"] = 0.0
	var kmh := car.linear_velocity.length() * 3.6
	var hist: Array = rec["kmh_prev"]
	hist.append(kmh)
	if hist.size() > 4:
		hist.pop_front()
	if touch and rec["first"] < 0.0:
		rec["first"] = t
		rec["kmh_before"] = hist[0]
	if rec["first"] >= 0.0 and t - rec["first"] <= 1.5:
		rec["kmh_min"] = minf(rec["kmh_min"], kmh)
	if ctx["rest"]:
		var ps: Array = rec["positions"]
		ps.append(pos)
		var w := int(round(0.5 / DT))
		if t > 1.0 and ps.size() > w:
			rec["drift"] = maxf(rec["drift"], pos.distance_to(ps[-1 - w]) / 0.5)


## Longest contact after the release: [seconds, how it ended ("apart", "still", "open")].
func _separation(rec: Dictionary, cars: Array[Car], ctx: Dictionary, t_end: float) -> Array:
	var release: float = ctx["release"] if ctx["release"] >= 0.0 else t_end
	var worst := 0.0
	var how := "apart"
	var spells: Array = rec["spells"]
	for k in spells.size():
		var sp: Array = spells[k]
		var open: bool = k == spells.size() - 1 and t_end - sp[1] <= SPELL_GAP
		if sp[1] < release and not open:
			continue
		var d: float = (t_end if open else sp[1]) - maxf(sp[0], release)
		if d > worst:
			worst = d
			how = "open" if open else "apart"
	if how == "open":
		var all_still := true
		for c in cars:
			if c.linear_velocity.length() > STILL:
				all_still = false
		if all_still:
			how = "still"
	return [worst, how]


func _report(sc: String, set_name: String, ids: Array[String], cars: Array[Car], recs: Array[Dictionary], ctx: Dictionary, t_end: float) -> void:
	totals["runs"] += 1
	var tag := "%s[%s]" % [sc, ",".join(ids)]
	for k in recs.size():
		var r: Dictionary = recs[k]
		var sep := _separation(r, cars, ctx, t_end)
		var lost: float = r["kmh_before"] - r["kmh_min"] if r["first"] >= 0.0 else 0.0
		var max_bump := 0.0
		for s: float in r["bumps"]:
			max_bump = maxf(max_bump, s)
		var max_imp := 0.0
		for s: float in r["impacts"]:
			max_imp = maxf(max_imp, s)
		print("RUN %s car=%d %s roll %.1f pitch %.1f air %.2f s yaw %.0f deg/s turned %.0f deg lift %.2f m lost %.0f km/h sep %.2f s (%s) overlap %.2f m tangled %.2f s off %.1f m flip %s resets %d bumps %d (max %.2f) impacts %d (max %.2f)%s" % [
				tag, k, r["id"], r["roll"], r["pitch"], r["air"], r["yaw"], r["turn"], r["lift"], lost, sep[0], sep[1], r["depth"], r["tangled"],
				r["off"], r["flipped"], r["resets"], r["bumps"].size(), max_bump, r["impacts"].size(), max_imp,
				(" drift %.3f m/s" % r["drift"]) if ctx["rest"] else ""])
		if not r["sounds"].is_empty():
			print("SOUND %s car=%d %s %s" % [tag, k, r["id"], " ".join(r["sounds"])])
		var fails := []
		var parts := []
		parts.append("flip %s" % r["flipped"])
		if r["flipped"]:
			fails.append("flip")
		parts.append("roll %.1f < %.0f" % [r["roll"], MAX_ROLL_DEG])
		if r["roll"] >= MAX_ROLL_DEG:
			fails.append("roll")
		parts.append("air %.2f < %.2f" % [r["air"], MAX_AIR_S])
		if r["air"] >= MAX_AIR_S:
			fails.append("air")
		parts.append("lift %.2f < %.2f" % [r["lift"], MAX_LIFT_M])
		if r["lift"] >= MAX_LIFT_M:
			fails.append("lift")
		parts.append("resets %d" % r["resets"])
		if r["resets"] > 0:
			fails.append("reset")
		if ctx["floored"]:
			# nobody lets go: a faster car floored behind a slower one pushes it, which is no
			# tangle; the overlap check below is the separation check here
			parts.append("pushed %.2f s" % sep[0])
		elif not ctx["rest"]:
			parts.append("sep %.2f < %.1f (%s)" % [sep[0], MAX_SEPARATE_S, sep[1]])
			if sep[0] >= MAX_SEPARATE_S and sep[1] != "still":
				fails.append("separation")
		parts.append("tangled %.2f < %.1f" % [r["tangled"], MAX_SEPARATE_S])
		if r["tangled"] >= MAX_SEPARATE_S:
			fails.append("tangle")
		if sc != "tbone" and sc != "tangle":
			parts.append("turned %.0f < %.0f" % [r["turn"], MAX_TURN_DEG])
			if r["turn"] >= MAX_TURN_DEG:
				fails.append("spin")
		if ctx["rest"]:
			parts.append("drift %.3f < %.2f" % [r["drift"], MAX_REST_DRIFT])
			if r["drift"] >= MAX_REST_DRIFT:
				fails.append("drift")
		if sc not in ["rest_side", "rest_nose", "tangle", "grid"] and r["first"] < 0.0:
			fails.append("no contact")
		totals["checks"] += 1
		if not fails.is_empty():
			totals["failed"] += 1
		print("CHECK %s car=%d %s %s: %s%s" % [tag, k, r["id"], "PASS" if fails.is_empty() else "FAIL", ", ".join(parts),
				"" if fails.is_empty() else " -> " + ",".join(fails)])
