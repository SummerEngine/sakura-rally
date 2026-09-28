extends SceneTree
## The AI's practice recorded as replays, for the video (tools/rl/film.gd). Per policy, `cars`
## stripped cars (tools/rl/rl_car.gd) set off together from a route's start line and drive the
## way they did in training (tools/rl/train_env.gd): the same senses and hands, each option
## sampled from the policy's odds with the car's own dice. A run ends by the training rules
## (TrainEnv.end_reason: rolled over, a crash, off the road, the wrong way, stalled) or after a
## full lap; the car then brakes to a stop (at most STOP_S) and its file closes. A car that
## finished drives on under the policy for DRIVE_ON_S first, so on film the finishers cross the
## line at speed instead of braking in a heap behind it. Every run is a
## replay file in the player's format (ReplayWriter), so ReplayGhost plays it back and
## tools/replay/review.gd reads it. The cars never touch each other (car layer 2 masks only the
## world and props), as in training.
##
##   timeout -k 10 1800 nice -n 10 $S --headless --disable-crash-handler --fixed-fps 120 \
##       --audio-driver Dummy --path . -s res://tools/rl/swarm.gd -- \
##       policies=demo_0,demo_100032,gen1_1000000 route=hanami cars=64 dest=/tmp/sakura_swarm
##
## Options: policies (comma-separated exported policies: a path to a .json, or a name looked up
## in tools/rl/runs/<run>/policies/ with the run the part before its last "_"), route, cars, car
## (car ids dealt round robin), seed, dest, limit (s of driving before a run is cut).
## Writes <dest>/<route>/<policy name>/NN.srr, one per car, and runs.json there:
##   {policy, run, steps, route, length, closed, cars, seed, limit,
##    runs: [{file, car, reason, metres, end_t, stop_t}]}
## reason: a TrainEnv.REASONS name ("finish": a full lap); metres: the furthest it got along the
## route; end_t: when the run ended; stop_t: its last frame.

const RLCar := preload("res://tools/rl/rl_car.gd")
const TrainEnv := preload("res://tools/rl/train_env.gd")
const F := preload("res://scripts/game/replay_format.gd")

## The start: every car on the start line, spread up to START_LAT m either side of the centre.
const START_LAT := 1.5
## After its run ends a car brakes with the wheel straight; its file closes once the car is
## slower than STOP_KMH (from STOP_MIN_S after braking starts) or STOP_S after it. A car that
## finished drives on for DRIVE_ON_S before it brakes.
const STOP_KMH := 3.0
const STOP_MIN_S := 0.5
const STOP_S := 3.0
const DRIVE_ON_S := 4.0
const DRIVE := 0
const STOP := 1
const DONE := 2
## Finished, still driving (DRIVE_ON_S).
const ON := 3
const FINISH := 6

var opts := {"policies": "", "route": "hanami", "cars": "64", "car": "sakura,hayate", "seed": "1",
		"dest": "/tmp/sakura_swarm", "limit": "150"}
var game: Node
var map: MapWorld
var state_names: Array[String] = []
var time: float = 0.0


## One car's run.
class Run:
	var index: int
	var car: Car
	var car_id: String
	var sense: DriveSense
	var hands := DriveHands.new()
	var dice := RandomNumberGenerator.new()
	var writer: ReplayWriter
	var header: Dictionary
	var obs := PackedFloat32Array()
	var phase: int = DRIVE
	## Car.impact strength since the last decision.
	var hit: float = 0.0
	var last_s: float = 0.0
	var metres: float = 0.0
	var best: float = 0.0
	var since: float = 0.0
	var reason: int = 0
	var end_t: float = 0.0
	## When it started braking.
	var brake_t: float = 0.0
	var stop_t: float = 0.0


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	_run.call_deferred()


func _run() -> void:
	game = root.get_node("Game")
	var states: Dictionary = game.State
	for key in states:
		while state_names.size() <= int(states[key]):
			state_names.append("")
		state_names[int(states[key])] = str(key)
	var route := str(opts["route"])
	map = MapWorld.new()
	map.name = "Map"
	map.map_id = route
	root.add_child(map)
	await map.build()
	if not map.routes.has(route):
		printerr("swarm: no route '%s' (have %s)" % [route, map.routes.keys()])
		_quit(2)
		return
	for gate: RoadGate in map.gates.values():
		gate.set_open(true, false)
	var t: Track = map.routes[route]["track"]
	for spec in str(opts["policies"]).split(",", false):
		var path := _policy_path(spec.strip_edges())
		var policy := DrivePolicy.load_file(path)
		if policy == null:
			printerr("swarm: cannot load policy '%s' (%s)" % [spec, path])
			_quit(2)
			return
		await _record(policy, path.get_file().get_basename(), t, route)
	_quit(0)


## A .json path as given; a bare name from its training run's policies.
func _policy_path(spec: String) -> String:
	if spec.ends_with(".json"):
		return spec
	return "res://tools/rl/runs/%s/policies/%s.json" % [spec.rsplit("_", true, 1)[0], spec]


func _record(policy: DrivePolicy, policy_name: String, t: Track, route: String) -> void:
	var wall0 := Time.get_ticks_msec()
	var dir := str(opts["dest"]).path_join(route).path_join(policy_name)
	DirAccess.make_dir_recursive_absolute(dir)
	var n := int(opts["cars"])
	var limit := float(opts["limit"])
	var car_ids: PackedStringArray = str(opts["car"]).split(",", false)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(opts["seed"])
	var runs: Array[Run] = []
	for k in n:
		var r := Run.new()
		r.index = k
		r.car_id = car_ids[k % car_ids.size()]
		r.car = RLCar.spawn(root, str(game.get_car(r.car_id)["scene"]), false)
		r.car.place_at_rest(t.transform_at_abs(t.start_s, rng.randf_range(-START_LAT, START_LAT)))
		r.hands.release(r.car)
		r.dice.seed = rng.randi()
		r.sense = DriveSense.new(t)
		r.sense.reset(t.start_s)
		r.writer = ReplayWriter.new(t)
		r.obs.resize(DriveSense.OBS_SIZE)
		r.car.impact.connect(_on_impact.bind(r))
		runs.append(r)
	await physics_frame
	time = 0.0
	var state: int = game.State.FREE_ROAM
	for r in runs:
		r.header = _header(r, policy, policy_name, route, t)
		r.sense.observe(r.car, r.obs)
		r.last_s = r.sense.road_s(r.car.global_position)
		r.writer.frame(0.0, r.car, state, 0, 0, 0.0, true)
	var dt := 1.0 / Engine.physics_ticks_per_second
	var step := dt * DriveHands.DECISION_TICKS
	var tick := 0
	var live := n
	while live > 0:
		for r in runs:
			if r.phase == DRIVE or r.phase == ON:
				var a := policy.act(r.obs, r.dice)
				r.hands.set_action(a[0], a[1], a[2])
				r.hit = 0.0
		for i in DriveHands.DECISION_TICKS:
			for r in runs:
				if r.phase != DONE:
					r.hands.apply(r.car, dt)
			await physics_frame
			tick += 1
			time = tick * dt
			if tick % F.TICKS_PER_FRAME == 0:
				for r in runs:
					if r.phase != DONE:
						r.writer.frame(time, r.car, state, 0, 0, time, r.phase == DRIVE or r.phase == ON)
		for r in runs:
			if r.phase == DRIVE:
				_judge(r, t, step, limit)
			elif r.phase == ON:
				r.sense.observe(r.car, r.obs)
				if time - r.end_t >= DRIVE_ON_S:
					_brake(r)
			elif r.phase == STOP and (time - r.brake_t >= STOP_S
					or (time - r.brake_t >= STOP_MIN_S and absf(r.car.speed_kmh) < STOP_KMH)):
				_close(r, dir)
				live -= 1
	var out := {"policy": policy_name, "run": str(policy.meta.get("run", "")), "steps": int(policy.meta.get("steps", 0)),
			"route": route, "length": t.length, "closed": t.closed, "cars": n, "seed": int(opts["seed"]),
			"limit": limit, "runs": []}
	var metres := PackedFloat32Array()
	var reasons := {}
	for r in runs:
		var why: String = TrainEnv.REASONS[r.reason] if r.reason != FINISH else "finish"
		out["runs"].append({"file": "%02d.%s" % [r.index, F.EXTENSION], "car": r.car_id, "reason": why,
				"metres": snappedf(r.best, 0.1), "end_t": snappedf(r.end_t, 0.01), "stop_t": snappedf(r.stop_t, 0.01)})
		metres.append(r.best)
		reasons[why] = int(reasons.get(why, 0)) + 1
	var f := FileAccess.open(dir.path_join("runs.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "  "))
	f.close()
	metres.sort()
	print("SWARM %s route=%s cars=%d median_m=%.0f best_m=%.0f longest_s=%.1f reasons=%s wall=%.0fs" % [
			policy_name, route, n, metres[n / 2], metres[n - 1], time, JSON.stringify(reasons),
			(Time.get_ticks_msec() - wall0) / 1000.0])
	await process_frame


## Progress and the training rules after one decision; a run that ends starts braking (a finish
## drives on first).
func _judge(r: Run, t: Track, step: float, limit: float) -> void:
	r.sense.observe(r.car, r.obs)
	var pos := r.car.global_position
	var s := r.sense.road_s(pos)
	var ds := s - r.last_s
	if t.closed:
		ds = wrapf(ds, -t.length * 0.5, t.length * 0.5)
	ds = clampf(ds, -20.0, 20.0)
	r.last_s = s
	r.metres += ds
	if r.metres > r.best + 0.5:
		r.best = r.metres
		r.since = 0.0
	else:
		r.since += step
	var reason := TrainEnv.end_reason(r.car, t, s, r.sense.road_lateral(pos), r.sense.road_edge(), r.hit,
			r.metres, r.best, r.since, time, limit)
	if reason == 0 and t.closed and r.metres >= t.length:
		reason = FINISH
	if reason == 0:
		return
	r.reason = reason
	r.end_t = time
	r.writer.event(time, {"type": "ai_end", "reason": TrainEnv.REASONS[reason] if reason != FINISH else "finish",
			"metres": r.best})
	if reason == FINISH:
		r.phase = ON
	else:
		_brake(r)


func _brake(r: Run) -> void:
	r.phase = STOP
	r.brake_t = time
	r.hands.set_action(3, 0, 0) # wheel straight, brakes on


func _close(r: Run, dir: String) -> void:
	r.phase = DONE
	r.stop_t = time
	r.writer.event(time, {"type": "end", "reason": TrainEnv.REASONS[r.reason] if r.reason != FINISH else "finish",
			"metres": r.best, "ended": r.end_t, "frames": r.writer.frames_written, "seconds": time})
	var block := r.writer.take_block()
	var bytes := F.header_bytes(r.header)
	bytes.append_array(F.block_bytes(block["frames"], block["count"], block["events"]))
	var f := FileAccess.open(dir.path_join("%02d.%s" % [r.index, F.EXTENSION]), FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()
	r.car.queue_free()


func _on_impact(strength: float, point: Vector3, r: Run) -> void:
	r.hit += strength
	if r.phase != DONE:
		r.writer.event(time, {"type": "impact", "strength": strength, "point": point, "kmh": r.car.speed_kmh})


## The replay header, with the keys the Replays autoload writes (ReplayData, ReplayGhost and the
## review tools read them) plus "ai": the policy and the car's place in the swarm.
func _header(r: Run, policy: DrivePolicy, policy_name: String, route: String, t: Track) -> Dictionary:
	var gates := {}
	for id: String in map.gates:
		gates[id] = true
	return {
		"game": ProjectSettings.get_setting("application/config/name", ""),
		"engine": Engine.get_version_info().get("string", ""),
		"date": Time.get_datetime_string_from_system(false, true),
		"date_utc": Time.get_datetime_string_from_system(true, true),
		"unix": Time.get_unix_time_from_system(),
		"route": route,
		"mode": "ai_practice",
		"state": "FREE_ROAM",
		"campaign": {"active": false, "leg": 0},
		"car": r.car_id,
		"car_scene": r.car.scene_file_path,
		"livery": {"index": 0, "primary": r.car.livery_primary, "secondary": r.car.livery_secondary},
		"settings": {},
		"tool_run": true,
		"os": OS.get_name(),
		"tick_rate": Engine.physics_ticks_per_second,
		"ticks_per_frame": F.TICKS_PER_FRAME,
		"frame_size": F.FRAME_SIZE,
		"states": state_names,
		"buttons": F.BUTTONS,
		"surfaces": [],
		"track": {"length": t.length, "closed": t.closed, "checkpoints": []},
		"spawn": {"pos": r.car.global_position, "yaw": r.car.global_rotation.y},
		"gates": gates,
		"ai": {"policy": policy_name, "run": str(policy.meta.get("run", "")), "steps": int(policy.meta.get("steps", 0)),
				"car_index": r.index, "seed": int(opts["seed"])},
	}


func _quit(code: int) -> void:
	for c in root.get_children():
		if c is Car:
			c.queue_free()
	quit(code)
