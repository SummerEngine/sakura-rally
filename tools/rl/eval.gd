extends SceneTree
## Races trained drivers (DrivePolicy JSON files) headless and reports what they manage. For
## every policy and route, `cars` cars with a NeuralPilot each start side by side on the start
## line at rest and drive one lap (a loop) or to the end of the road (an open route). A car off
## the road (centre OFF_MARGIN beyond the verge) or without progress for STALL_S is put back on
## the centre line where it was, like the game's reset, and the reset is counted.
##
##   $S --headless --disable-crash-handler --fixed-fps 120 --audio-driver Dummy --path . \
##       -s res://tools/rl/eval.gd -- policy=tools/rl/runs/hanami/policies/latest.json routes=hanami,momiji
##
## Options: policy (comma list; project-relative, res:// or absolute paths), routes (":rev"
## drives one backwards), cars (per policy and route), seconds (time limit), sample (1: sampled
## choices instead of the likeliest), car (car id).
## Prints a CHECK line per policy (GDScript logits against the torch ones train.py stored) and an
## EVAL line per policy and route: cars finished, best and median time, resets per car (and how
## many were off the road / stalled / rolled), mean km/h, and steer: how far the steering target
## travels per second (full lock to full lock is 2; a driver sawing at the wheel scores high).

const RLCar := preload("res://tools/rl/rl_car.gd")
const TrainEnv := preload("res://tools/rl/train_env.gd")

const OFF_MARGIN := 1.0
const STALL_S := 3.0
const FINISH_MARGIN := 8.0

var opts := {"policy": "", "routes": "hanami", "cars": "4", "seconds": "300", "sample": "0", "car": "sakura"}


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	_run.call_deferred()


func _run() -> void:
	var game := root.get_node("Game")
	var policies: Array[DrivePolicy] = []
	for p: String in str(opts["policy"]).split(",", false):
		var policy := DrivePolicy.load_file(p)
		if policy == null:
			game.request_quit(2)
			return
		policies.append(policy)
		var test: Array = policy.meta.get("test_obs", [])
		if not test.is_empty():
			var z := policy.logits(PackedFloat32Array(test))
			var want: Array = policy.meta["test_logits"]
			var worst := 0.0
			for i in z.size():
				worst = maxf(worst, absf(z[i] - float(want[i])))
			var t0 := Time.get_ticks_usec()
			for i in 200:
				policy.act(PackedFloat32Array(test))
			print("CHECK policy=%s max_logit_error=%.6f %s act_usec=%d" % [policy.path.get_file(), worst,
					"ok" if worst < 1e-3 else "MISMATCH", (Time.get_ticks_usec() - t0) / 200])
	if policies.is_empty():
		printerr("eval: no policy= given")
		game.request_quit(2)
		return

	var map := MapWorld.new()
	map.name = "Map"
	map.map_id = opts["routes"].split(",")[0].split(":")[0]
	root.add_child(map)
	await map.build()
	for gate: RoadGate in map.gates.values():
		gate.set_open(true, false)

	var k_cars := int(opts["cars"])
	var runs: Array[Dictionary] = []
	for pi in policies.size():
		for spec: String in str(opts["routes"]).split(","):
			var parts: PackedStringArray = spec.split(":")
			var t: Track = map.routes[parts[0]]["track"]
			if parts.size() > 1 and parts[1] == "rev":
				t = TrainEnv.reversed_track(t)
			for k in k_cars:
				var car := RLCar.spawn(root, str(game.get_car(opts["car"])["scene"]), false)
				var pilot := NeuralPilot.new()
				pilot.policy = policies[pi]
				pilot.track = t
				pilot.sample = opts["sample"] == "1"
				pilot.sample_seed = runs.size()
				car.add_child(pilot)
				runs.append({"policy": pi, "route": spec, "track": t, "car": car, "pilot": pilot,
						"lat": (k - (k_cars - 1) * 0.5) * 1.6, "dist": 0.0, "last_s": 0.0, "best": 0.0,
						"since_best": 0.0, "resets": 0, "off": 0, "stall": 0, "roll": 0, "time": -1.0,
						"speed_sum": 0.0, "samples": 0, "steer_travel": 0.0, "last_steer": 0.0})
	await physics_frame
	for r in runs:
		var t: Track = r["track"]
		var car: Car = r["car"]
		car.place_at_rest(t.transform_at_abs(t.start_s, r["lat"]))
		r["last_s"] = t.start_s
		(r["pilot"] as NeuralPilot).sense.reset(t.start_s)

	var step := DriveHands.DECISION_TICKS / float(Engine.physics_ticks_per_second)
	var limit := float(opts["seconds"])
	var clock := 0.0
	var left := runs.size()
	while left > 0 and clock < limit:
		for i in DriveHands.DECISION_TICKS:
			await physics_frame
		clock += step
		for r in runs:
			if r["time"] >= 0.0:
				continue
			var car: Car = r["car"]
			var t: Track = r["track"]
			var sense: DriveSense = (r["pilot"] as NeuralPilot).sense
			var pos := car.global_position
			var s := sense.road_s(pos)
			var ds: float = s - r["last_s"]
			if t.closed:
				ds = wrapf(ds, -t.length * 0.5, t.length * 0.5)
			r["last_s"] = s
			r["dist"] += ds
			r["speed_sum"] += absf(car.speed_kmh)
			r["samples"] += 1
			var steer: float = (r["pilot"] as NeuralPilot).hands.steer_target
			r["steer_travel"] += absf(steer - float(r["last_steer"]))
			r["last_steer"] = steer
			if r["dist"] > r["best"] + 0.5:
				r["best"] = r["dist"]
				r["since_best"] = 0.0
			else:
				r["since_best"] += step
			if (t.closed and r["dist"] >= t.length) or (not t.closed and s >= t.last_s - FINISH_MARGIN):
				r["time"] = clock
				left -= 1
				car.freeze = true
				continue
			var why := ""
			if absf(sense.road_lateral(pos)) > sense.road_edge() + OFF_MARGIN:
				why = "off"
			elif r["since_best"] > STALL_S:
				why = "stall"
			elif car.global_basis.y.y < 0.2:
				why = "roll"
			if why != "":
				car.reset_to(t.transform_at_abs(s, 0.0))
				r["resets"] += 1
				r[why] += 1
				r["since_best"] = 0.0

	for pi in policies.size():
		for spec: String in str(opts["routes"]).split(","):
			var times: Array[float] = []
			var resets := {"resets": 0, "off": 0, "stall": 0, "roll": 0}
			var speed := 0.0
			var dist := 0.0
			var n := 0
			var steer := 0.0
			for r in runs:
				if r["policy"] != pi or r["route"] != spec:
					continue
				n += 1
				for key: String in resets:
					resets[key] += r[key]
				speed += r["speed_sum"] / maxf(r["samples"], 1.0)
				steer += r["steer_travel"] / maxf(r["samples"] * step, step)
				dist += r["dist"]
				if r["time"] >= 0.0:
					times.append(r["time"])
			times.sort()
			print("EVAL policy=%s route=%s finished=%d/%d best=%s median=%s resets=%.1f (off %.1f stall %.1f roll %.1f) kmh=%.0f steer=%.2f/s dist=%.0f length=%.0f" % [
					policies[pi].path.get_file(), spec, times.size(), n,
					"%.1f" % times[0] if not times.is_empty() else "-",
					"%.1f" % times[times.size() / 2] if not times.is_empty() else "-",
					float(resets["resets"]) / n, float(resets["off"]) / n, float(resets["stall"]) / n,
					float(resets["roll"]) / n, speed / n, steer / n, dist / n, _length_of(runs, pi, spec)])
	game.request_quit(0)


func _length_of(runs: Array[Dictionary], pi: int, spec: String) -> float:
	for r in runs:
		if r["policy"] == pi and r["route"] == spec:
			return (r["track"] as Track).length
	return 0.0
