extends SceneTree
## RL training server for tools/rl/train.py: one headless process drives `cars` stripped cars
## (tools/rl/rl_car.gd) on MapWorld routes and trades observations for actions over TCP.
## The cars never collide with each other (car layer 2 masks only the world and props), so they
## all share one world. Each car sees through its own DriveSense and drives through DriveHands,
## the same classes the in-game NeuralPilot uses.
##
##   $S --headless --disable-crash-handler --fixed-fps 120 --audio-driver Dummy --path . \
##       -s res://tools/rl/train_env.gd -- port=5555 id=0 cars=16 routes=hanami,hanami:rev seed=1
##
## Options: port, id (echoed in the hello), cars, routes (route ids, ":rev" drives one backwards;
## every episode starts on a random one), car (car ids, dealt round-robin), seed, episode_s
## (episode length before a time-limit cut; the car drives on into the next episode).
##
## Protocol, little-endian. The process connects to 127.0.0.1:port and sends a hello (u32 byte
## length + UTF-8 JSON: id, cars, obs_size, info_size, action_dims, sense_version,
## decision_ticks, routes with their lengths), then serves commands:
##   u8 1, then cars x len(action_dims) u8 option indices   step every car one decision
##   u8 2                                                    every car to a new random start
##   u8 0                                                    quit
## Each step/reset reply: cars x obs_size f32 observations | cars f32 rewards |
## cars u8 flags (1 terminated, 2 truncated) | cars x INFO_SIZE f32 info. A car whose episode
## ended already stands at its next start: its observation is the next episode's first.
## info: route index, episode metres, km/h, end reason (REASONS index), episode seconds,
## lateral offset / drivable half width.
##
## Episode (docs/RL.md): reward REWARD_PER_M per metre of progress along the route, minus
## IMPACT_COST per unit of Car.impact strength and STEER_COST per unit the steering target moves;
## it ends off the road (centre OFF_MARGIN beyond the verge), in a crash (IMPACT_CRASH in one
## decision), rolled over, STALL_S without new progress, WRONG_WAY_M behind its best, at the end
## of an open route, or after episode_s (a cut, not an end).
##
## tools/rl_pixels/pixel_env.gd extends this script (pixel observations): it overrides _build,
## _hello, _drive and _send, and _restart, _score and _fill_info in its eval mode.

const RLCar := preload("res://tools/rl/rl_car.gd")

const INFO_SIZE := 6
const REASONS: Array[String] = ["", "off_road", "crash", "stall", "wrong_way", "rolled", "finish", "time"]
const REWARD_PER_M := 0.05
const IMPACT_COST := 1.0
const IMPACT_CRASH := 0.6
## Per unit of steering-target travel in one decision (full lock to full lock is 2): the turn-in
## and unwind a corner needs cost little, sawing at the wheel every decision costs a sixth of the
## progress reward at speed, so the driver steers smoothly.
const STEER_COST := 0.1
## Cost of an episode that ends badly: off the road, crashed, rolled, the wrong way, or stalled
## (standing still must never be the safe choice).
const FAIL_COST := 3.0
const OFF_MARGIN := 1.0
const STALL_S := 3.0
const WRONG_WAY_M := 15.0
const FINISH_MARGIN := 8.0
## Random starts: lateral offset (m), heading error (rad); open routes keep this much road ahead.
const START_LAT := 2.0
const START_YAW := 0.2
const START_ROOM := 150.0

var opts := {"port": "5555", "id": "0", "cars": "16", "routes": "hanami", "car": "sakura",
		"seed": "1", "episode_s": "90"}
var game: Node
var map: MapWorld
var peer := StreamPeerTCP.new()
var rng := RandomNumberGenerator.new()
## Per route slot: {"id", "reverse", "track"}.
var routes: Array[Dictionary] = []
var cars: Array[Car] = []
var senses: Array[DriveSense] = []
var hands: Array[DriveHands] = []
var route_of := PackedInt32Array()
var last_s := PackedFloat32Array()
var ep_m := PackedFloat32Array()
var best_m := PackedFloat32Array()
var since_best := PackedFloat32Array()
var ep_time := PackedFloat32Array()
var impact := PackedFloat32Array()
var steer_moved := PackedFloat32Array()
var obs := PackedFloat32Array()
var rewards := PackedFloat32Array()
var flags := PackedByteArray()
var info := PackedFloat32Array()
var episode_s: float = 90.0
## Floats of info per car (tools/rl_pixels/pixel_env.gd's eval mode sends more).
var info_size: int = INFO_SIZE
## Every branch gate open (the liaison needs them); pixel_env.gd keeps them closed as a timed
## stage does.
var open_gates: bool = true


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	_run.call_deferred()


func _run() -> void:
	game = root.get_node("Game")
	rng.seed = int(opts["seed"])
	episode_s = float(opts["episode_s"])
	var built: bool = await _build()
	if not built:
		return
	await physics_frame

	if peer.connect_to_host("127.0.0.1", int(opts["port"])) != OK or not _await_connection():
		printerr("train_env: cannot connect to 127.0.0.1:%s" % opts["port"])
		_quit(3)
		return
	peer.set_no_delay(true)
	var hello := JSON.stringify(_hello()).to_utf8_buffer()
	var head := PackedByteArray()
	head.resize(4)
	head.encode_u32(0, hello.size())
	peer.put_data(head + hello)
	print("READY id=%s cars=%d routes=%s" % [opts["id"], cars.size(), opts["routes"]])
	await _serve()
	_quit(0)


## The world, the routes and the cars; false (quitting) when a route is unknown.
func _build() -> bool:
	map = MapWorld.new()
	map.name = "Map"
	map.map_id = opts["routes"].split(",")[0].split(":")[0]
	root.add_child(map)
	await map.build()
	if open_gates:
		for gate: RoadGate in map.gates.values():
			gate.set_open(true, false)
	for spec: String in str(opts["routes"]).split(","):
		var parts: PackedStringArray = spec.split(":")
		if not map.routes.has(parts[0]):
			printerr("train_env: no route '%s' (have %s)" % [parts[0], map.routes.keys()])
			_quit(2)
			return false
		var reverse := parts.size() > 1 and parts[1] == "rev"
		var t: Track = map.routes[parts[0]]["track"]
		routes.append({"id": spec, "reverse": reverse, "track": reversed_track(t) if reverse else t})

	var n := int(opts["cars"])
	var car_ids: PackedStringArray = str(opts["car"]).split(",")
	for k in n:
		var car := RLCar.spawn(root, str(game.get_car(car_ids[k % car_ids.size()])["scene"]), false)
		car.impact.connect(_on_impact.bind(k))
		cars.append(car)
		senses.append(DriveSense.new(routes[0]["track"]))
		hands.append(DriveHands.new())
	route_of.resize(n)
	last_s.resize(n)
	ep_m.resize(n)
	best_m.resize(n)
	since_best.resize(n)
	ep_time.resize(n)
	impact.resize(n)
	rewards.resize(n)
	steer_moved.resize(n)
	flags.resize(n)
	obs.resize(n * DriveSense.OBS_SIZE)
	info.resize(n * info_size)
	return true


func _hello() -> Dictionary:
	var route_info := []
	for r in routes:
		route_info.append({"id": r["id"], "length": (r["track"] as Track).length, "closed": (r["track"] as Track).closed})
	return {
		"id": int(opts["id"]), "cars": cars.size(), "obs_size": DriveSense.OBS_SIZE, "info_size": info_size,
		"action_dims": DriveHands.ACTION_DIMS, "sense_version": DriveSense.VERSION,
		"decision_ticks": DriveHands.DECISION_TICKS, "routes": route_info, "reasons": REASONS,
	}


## Serves the trainer's commands until it quits or goes.
func _serve() -> void:
	var n := cars.size()
	var groups := DriveHands.ACTION_DIMS.size()
	var step := DriveHands.DECISION_TICKS / float(Engine.physics_ticks_per_second)
	while true:
		var cmd := _read(1)
		if cmd.is_empty() or cmd[0] == 0:
			return
		if cmd[0] == 2:
			for k in n:
				_restart(k)
				rewards[k] = 0.0
				flags[k] = 0
				_fill_info(k, 0)
			_send()
			continue
		var acts := _read(n * groups)
		if acts.is_empty():
			return
		for k in n:
			var a := k * groups
			var before := hands[k].steer_target
			hands[k].set_action(acts[a], acts[a + 1], acts[a + 2])
			steer_moved[k] = absf(hands[k].steer_target - before)
			impact[k] = 0.0
		await _drive()
		for k in n:
			_score(k, step)
		_send()


## One decision's physics ticks, the hands working the controls before every tick.
func _drive() -> void:
	var dt := 1.0 / Engine.physics_ticks_per_second
	for t in DriveHands.DECISION_TICKS:
		for k in cars.size():
			hands[k].apply(cars[k], dt)
		await physics_frame


## The route driven the other way: samples in reverse order (index j is sample count - j on a
## loop, so distances still start at 0), forward and bank negated, distances mirrored.
static func reversed_track(t: Track) -> Track:
	var cols := Track.COLS
	var src := t.data
	var out := PackedFloat32Array()
	out.resize(src.size())
	for j in t.count:
		var i := (t.count - j) % t.count if t.closed else t.count - 1 - j
		for c in cols:
			out[j * cols + c] = src[i * cols + c]
		var o := j * cols
		out[o + 3] = -out[o + 3]
		out[o + 4] = -out[o + 4]
		out[o + 9] = -out[o + 9]
		out[o + 8] = fposmod(t.length - src[i * cols + 8], t.length) if t.closed \
				else t.first_s + t.last_s - src[i * cols + 8]
	var start := fposmod(t.length - t.start_s, t.length) if t.closed else t.first_s + t.last_s - t.start_s
	var surfaces: Array[String] = []
	for s in t.surface_names:
		surfaces.append(str(s))
	var r := Track.new()
	r.setup(out, {"length": t.length, "start_s": start, "verge": t.verge, "surfaces": surfaces}, t.closed)
	return r


## New episode for car k on a random route at a random point of it, standing still.
func _restart(k: int) -> void:
	var ri := rng.randi_range(0, routes.size() - 1)
	var t: Track = routes[ri]["track"]
	var s: float
	if t.closed:
		s = rng.randf() * t.length
	else:
		s = t.first_s + rng.randf() * maxf(t.last_s - t.first_s - START_ROOM, 1.0)
	var xf := t.transform_at_abs(s, rng.randf_range(-START_LAT, START_LAT))
	xf.basis = xf.basis.rotated(Vector3.UP, rng.randf_range(-START_YAW, START_YAW))
	var car := cars[k]
	car.place_at_rest(xf)
	hands[k].release(car)
	route_of[k] = ri
	var sense := senses[k]
	sense.track = t
	sense.reset(s)
	sense.observe(car, obs, k * DriveSense.OBS_SIZE)
	last_s[k] = sense.road_s(car.global_position)
	ep_m[k] = 0.0
	best_m[k] = 0.0
	since_best[k] = 0.0
	ep_time[k] = 0.0


## Reward and episode end for car k after one decision of `step` seconds.
func _score(k: int, step: float) -> void:
	var car := cars[k]
	var sense := senses[k]
	var t := sense.track
	sense.observe(car, obs, k * DriveSense.OBS_SIZE)
	var pos := car.global_position
	var s := sense.road_s(pos)
	var ds := s - last_s[k]
	if t.closed:
		ds = wrapf(ds, -t.length * 0.5, t.length * 0.5)
	ds = clampf(ds, -20.0, 20.0)
	last_s[k] = s
	ep_m[k] += ds
	ep_time[k] += step
	if ep_m[k] > best_m[k] + 0.5:
		best_m[k] = ep_m[k]
		since_best[k] = 0.0
	else:
		since_best[k] += step
	var r := ds * REWARD_PER_M - impact[k] * IMPACT_COST - steer_moved[k] * STEER_COST
	var lat := sense.road_lateral(pos)
	var edge := sense.road_edge()
	var reason := end_reason(car, t, s, lat, edge, impact[k], ep_m[k], best_m[k], since_best[k], ep_time[k], episode_s)
	if reason in [1, 2, 3, 4, 5]:
		r -= FAIL_COST
	rewards[k] = r
	flags[k] = 0 if reason == 0 else (2 if reason == 7 else 1)
	info[k * info_size + 5] = lat / edge
	_fill_info(k, reason)
	if reason == 7:
		# a time cut: the car drives on, the next episode starts where it is
		ep_m[k] = 0.0
		best_m[k] = 0.0
		since_best[k] = 0.0
		ep_time[k] = 0.0
	elif reason != 0:
		_restart(k)


## Why an episode ends after a decision, as a REASONS index (0: it goes on): rolled over, a crash
## (`hit`, the decision's Car.impact strength), off the road (`lat` from the centre line beyond the
## drivable half width `edge` plus OFF_MARGIN), the wrong way or stalled (the episode's `metres`,
## its `best` and the seconds `since` that best), the end of an open track (`s` along it), or
## `seconds` reaching `limit`. tools/rl/swarm.gd ends its recorded runs by the same rules.
static func end_reason(car: Car, t: Track, s: float, lat: float, edge: float, hit: float, metres: float,
		best: float, since: float, seconds: float, limit: float) -> int:
	if car.global_basis.y.y < 0.2:
		return 5
	if hit >= IMPACT_CRASH:
		return 2
	if absf(lat) > edge + OFF_MARGIN:
		return 1
	if metres < best - WRONG_WAY_M:
		return 4
	if since > STALL_S:
		return 3
	if not t.closed and s > t.last_s - FINISH_MARGIN:
		return 6
	if seconds >= limit:
		return 7
	return 0


func _fill_info(k: int, reason: int) -> void:
	var o := k * info_size
	info[o] = route_of[k]
	info[o + 1] = ep_m[k]
	info[o + 2] = cars[k].speed_kmh
	info[o + 3] = reason
	info[o + 4] = ep_time[k]


func _on_impact(strength: float, _point: Vector3, k: int) -> void:
	impact[k] += strength


func _send() -> void:
	var out := obs.to_byte_array()
	out.append_array(rewards.to_byte_array())
	out.append_array(flags)
	out.append_array(info.to_byte_array())
	peer.put_data(out)


## Blocks for exactly `bytes` bytes; empty when the trainer has gone.
func _read(bytes: int) -> PackedByteArray:
	var got := peer.get_data(bytes)
	if got[0] != OK:
		return PackedByteArray()
	return got[1]


func _await_connection() -> bool:
	for i in 1000:
		peer.poll()
		match peer.get_status():
			StreamPeerTCP.STATUS_CONNECTED:
				return true
			StreamPeerTCP.STATUS_ERROR, StreamPeerTCP.STATUS_NONE:
				return false
		OS.delay_msec(10)
	return false


func _quit(code: int) -> void:
	if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		peer.disconnect_from_host()
	game.request_quit(code)
