extends "res://tools/rl/train_env.gd"
## Pixel observations for tools/rl_pixels/train_pixels.py (docs/PIXELS.md): train_env.gd's cars,
## rewards and episodes, and every car also looks at the road through its own DriveEyes hood
## camera. Rendering happens on demand: the render loop is off; every reply poses the cameras,
## marks each car's viewport and the atlas (all cars' frames tiled `cols` per row) for one update,
## calls RenderingServer.force_draw() once and reads the atlas with one get_image(). With
## --fixed-fps 10 one main-loop iteration runs a decision's 12 physics ticks (the project's
## max_physics_steps_per_frame is 12); the hands move in a _physics_process node. Pixels, so the
## agents' dev build offscreen (never the installed Summer, never windowed):
##
##   D=~/opt/summer-dev/SummerDev.app/Contents/MacOS/Summer
##   $D --summer-offscreen --audio-driver Dummy --disable-crash-handler --fixed-fps 10 --path . \
##       -s res://tools/rl_pixels/pixel_env.gd -- port=5555 id=0 cars=16 routes=hanami,hanami:rev look=lean
##
## Options, besides train_env.gd's:
##   look          lean: the low preset without sun shadows; shade: with them (the sun's shadows
##                 cannot be left out of one viewport, so the game's AI view has them whenever the
##                 player's preset does). Neither draws the ink lines or antialiases.
##   seasons       random: a new season look (atmosphere, sky, sun) every season_every decisions,
##                 spring, autumn, summer or a blend; or fixed weights, e.g. 0,0,1. The ground and
##                 the trees keep their own season (the world's season grid).
##   mode          train, or eval: eval_cars cars per route start side by side on its start line
##                 and drive one lap (or to the end of an open road) by eval.gd's rules: a car off
##                 the road, stalled or rolled over is put back on the centre line where it was.
##   replays       (eval mode) a folder: every car's lap becomes a replay file there,
##                 <route>_<car>.<ext> (":rev" as "_rev"), written when the next eval starts or at
##                 quit, with an eased chase camera in every frame, so tools/replay/review.gd's
##                 render films it (train_pixels.py film).
## The branch gates stay closed, as in a timed stage (Main._set_gates), unless the worker drives the
## liaison: both gates stand on that road (s 75 and 1740 m), open in the game's liaison mode.
##
## Protocol: train_env.gd's. The hello adds "image" [H, W, 3] and "atlas" [rows, cols]; every
## reply is followed by the atlas, rows * H x cols * W RGB8 pixels, car k at row k / cols, column
## k % cols. eval mode: rewards are 0, flags 1 once a car has finished (it then stands frozen) and
## the info per car is EVAL_INFO floats: route index, metres, km/h, finish time (-1 until then),
## resets, of them off the road / stalled / rolled, steering-target travel, summed km/h and
## decisions driven (for the means).

const Eval := preload("res://tools/rl/eval.gd")
const Swarm := preload("res://tools/rl/swarm.gd")
const F := preload("res://scripts/game/replay_format.gd")
const EVAL_INFO := 11
const EVAL_LAT := 1.6
## The chase camera stored in eval replays: behind and above the car, eased towards it.
const CHASE_BACK := 6.5
const CHASE_UP := 2.4
const CHASE_RATE := 6.0

var eyes: Array[DriveEyes] = []
var atlas: SubViewport
var cols: int = 1
var eval_mode: bool = false
var eval_cars: int = 2
var season_every: int = 600
var decisions: int = 0
var clock: float = 0.0
## eval mode: per car {last_s, dist, best, since, resets, off, stall, roll, time, steer, last_steer,
## speed, samples}.
var runs: Array[Dictionary] = []
## eval replays (option `replays`): per car its writer (null: none open), header and chase camera
## position; physics ticks since the eval started.
var writers: Array = []
var headers: Array[Dictionary] = []
var chase: Array[Vector3] = []
var rec_tick: int = 0


## Moves every car's controls towards its hands before the car's own physics, every tick.
class Hands extends Node:
	var env

	func _physics_process(dt: float) -> void:
		for k in env.cars.size():
			env.hands[k].apply(env.cars[k], dt)


## eval replays: one frame of every open replay every ReplayFormat.TICKS_PER_FRAME ticks.
class Recorder extends Node:
	var env

	func _physics_process(_dt: float) -> void:
		env._record()


func _initialize() -> void:
	opts.merge({"look": "lean", "seasons": "random", "season_every": "600", "mode": "train",
			"eval_cars": "2"}, false)
	super()


func _build() -> bool:
	eval_mode = opts["mode"] == "eval"
	eval_cars = int(opts["eval_cars"])
	season_every = maxi(int(opts["season_every"]), 1)
	open_gates = "liaison" in str(opts["routes"])
	root.disable_3d = true
	RenderingServer.render_loop_enabled = false
	if eval_mode:
		info_size = EVAL_INFO
		opts["cars"] = str(eval_cars * str(opts["routes"]).split(",").size())
	var built: bool = await super()
	if not built:
		return false

	Quality.apply("low", root, map)
	map.atmosphere.sun.shadow_enabled = opts["look"] == "shade"
	if opts["seasons"] == "random":
		_draw_season()
	else:
		var w: PackedStringArray = str(opts["seasons"]).split(",")
		map._apply_season(Vector3(float(w[0]), float(w[1]), float(w[2])))

	var n := cars.size()
	cols = int(ceil(sqrt(float(n))))
	var size := DriveEyes.SIZE
	atlas = SubViewport.new()
	atlas.disable_3d = true
	atlas.size = Vector2i(size.x * cols, size.y * int(ceil(float(n) / cols)))
	atlas.render_target_update_mode = SubViewport.UPDATE_DISABLED
	root.add_child(atlas)
	for k in n:
		var e := DriveEyes.new(size)
		atlas.add_child(e.viewport)
		var tile := TextureRect.new()
		tile.texture = e.viewport.get_texture()
		tile.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		tile.position = Vector2(size.x * (k % cols), size.y * (k / cols))
		tile.size = Vector2(size)
		atlas.add_child(tile)
		eyes.append(e)
	var h := Hands.new()
	h.env = self
	h.process_physics_priority = -100
	root.add_child(h)
	runs.resize(n)
	for k in n:
		runs[k] = _fresh_run(0.0)
	if eval_mode and str(opts.get("replays", "")) != "":
		DirAccess.make_dir_recursive_absolute(str(opts["replays"]))
		writers.resize(n)
		headers.resize(n)
		chase.resize(n)
		var rec := Recorder.new()
		rec.env = self
		rec.process_physics_priority = 100
		root.add_child(rec)
	return true


func _hello() -> Dictionary:
	var hello := super()
	hello["image"] = [DriveEyes.SIZE.y, DriveEyes.SIZE.x, 3]
	hello["atlas"] = [atlas.size.y / DriveEyes.SIZE.y, cols]
	hello["mode"] = opts["mode"]
	hello["look"] = opts["look"]
	return hello


## One decision: --fixed-fps 10 runs its 12 physics ticks in the next main-loop iteration.
func _drive() -> void:
	await process_frame
	clock += DriveHands.DECISION_TICKS / float(Engine.physics_ticks_per_second)


func _send() -> void:
	var frame := _render()
	super()
	peer.put_data(frame)


## Every car's frame, tiled in the atlas, as RGB8 bytes.
func _render() -> PackedByteArray:
	decisions += 1
	if opts["seasons"] == "random" and not eval_mode and decisions % season_every == 0:
		_draw_season()
	for k in cars.size():
		eyes[k].look(cars[k].global_transform)
	RenderingServer.viewport_set_update_mode(atlas.get_viewport_rid(), RenderingServer.VIEWPORT_UPDATE_ONCE)
	RenderingServer.force_draw(false)
	var img := atlas.get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	return img.get_data()


## A season look: spring (Hanami's own), autumn (Momiji's), summer, or a blend of the three.
func _draw_season() -> void:
	var r := rng.randf()
	var w := Vector3(1.0, 0.0, 0.0)
	if r >= 0.35 and r < 0.7:
		w = Vector3(0.0, 0.0, 1.0)
	elif r >= 0.7 and r < 0.85:
		w = Vector3(0.0, 1.0, 0.0)
	elif r >= 0.85:
		w = Vector3(rng.randf(), rng.randf(), rng.randf())
		w /= maxf(w.x + w.y + w.z, 1e-3)
	map._apply_season(w)


# ------------------------------------------------------------------ eval mode

func _fresh_run(start_s: float) -> Dictionary:
	return {"last_s": start_s, "dist": 0.0, "best": 0.0, "since": 0.0, "resets": 0, "off": 0,
			"stall": 0, "roll": 0, "time": -1.0, "steer": 0.0, "last_steer": 0.0, "speed": 0.0,
			"samples": 0}


## eval mode: car k on its route's start line, standing, beside the route's other cars.
func _restart(k: int) -> void:
	if not eval_mode:
		super(k)
		return
	if k == 0:
		_close_replays()
		rec_tick = 0
	var ri := k / eval_cars
	var t: Track = routes[ri]["track"]
	var car := cars[k]
	car.freeze = false
	car.place_at_rest(t.transform_at_abs(t.start_s, (k % eval_cars - (eval_cars - 1) * 0.5) * EVAL_LAT))
	hands[k].release(car)
	route_of[k] = ri
	var sense := senses[k]
	sense.track = t
	sense.reset(t.start_s)
	sense.observe(car, obs, k * DriveSense.OBS_SIZE)
	runs[k] = _fresh_run(t.start_s)
	clock = 0.0
	if not writers.is_empty():
		var spec: String = routes[ri]["id"]
		var car_ids: PackedStringArray = str(opts["car"]).split(",")
		writers[k] = ReplayWriter.new(t)
		headers[k] = Swarm.tool_header(game, map, car, car_ids[k % car_ids.size()], spec.split(":")[0], t,
				{"policy": str(opts.get("policy_name", "")), "route": spec, "car_index": k})
		chase[k] = Vector3.INF
		_frame(k, 0.0)


## eval mode: eval.gd's bookkeeping for car k after one decision.
func _score(k: int, step: float) -> void:
	if not eval_mode:
		super(k, step)
		return
	var car := cars[k]
	var sense := senses[k]
	var t := sense.track
	var r: Dictionary = runs[k]
	rewards[k] = 0.0
	sense.observe(car, obs, k * DriveSense.OBS_SIZE)
	if r["time"] >= 0.0:
		flags[k] = 1
		_fill_info(k, 0)
		return
	flags[k] = 0
	var pos := car.global_position
	var s := sense.road_s(pos)
	var ds: float = s - r["last_s"]
	if t.closed:
		ds = wrapf(ds, -t.length * 0.5, t.length * 0.5)
	r["last_s"] = s
	r["dist"] += ds
	r["speed"] += absf(car.speed_kmh)
	r["samples"] += 1
	var steer := hands[k].steer_target
	r["steer"] += absf(steer - float(r["last_steer"]))
	r["last_steer"] = steer
	if r["dist"] > r["best"] + 0.5:
		r["best"] = r["dist"]
		r["since"] = 0.0
	else:
		r["since"] += step
	if (t.closed and r["dist"] >= t.length) or (not t.closed and s >= t.last_s - Eval.FINISH_MARGIN):
		r["time"] = clock
		car.freeze = true
		flags[k] = 1
	else:
		var why := ""
		if absf(sense.road_lateral(pos)) > sense.road_edge() + Eval.OFF_MARGIN:
			why = "off"
		elif r["since"] > Eval.STALL_S:
			why = "stall"
		elif car.global_basis.y.y < 0.2:
			why = "roll"
		if why != "":
			car.reset_to(t.transform_at_abs(s, 0.0))
			r["resets"] += 1
			r[why] += 1
			r["since"] = 0.0
			sense.observe(car, obs, k * DriveSense.OBS_SIZE)
			if not writers.is_empty() and writers[k] != null:
				(writers[k] as ReplayWriter).hint = -1
				(writers[k] as ReplayWriter).event(clock, {"type": "ai_reset", "why": why})
	if r["time"] >= 0.0 and not writers.is_empty() and writers[k] != null:
		(writers[k] as ReplayWriter).event(clock, {"type": "ai_end", "reason": "finish", "metres": r["dist"]})
	_fill_info(k, 0)


func _fill_info(k: int, reason: int) -> void:
	if not eval_mode:
		super(k, reason)
		return
	var r: Dictionary = runs[k]
	var o := k * EVAL_INFO
	info[o] = route_of[k]
	info[o + 1] = r["dist"]
	info[o + 2] = cars[k].speed_kmh
	info[o + 3] = r["time"]
	info[o + 4] = r["resets"]
	info[o + 5] = r["off"]
	info[o + 6] = r["stall"]
	info[o + 7] = r["roll"]
	info[o + 8] = r["steer"]
	info[o + 9] = r["speed"]
	info[o + 10] = r["samples"]


# ------------------------------------------------------------------ eval replays

func _record() -> void:
	rec_tick += 1
	if rec_tick % F.TICKS_PER_FRAME != 0:
		return
	var t := rec_tick / float(Engine.physics_ticks_per_second)
	for k in writers.size():
		if writers[k] != null and runs[k]["time"] < 0.0:
			_frame(k, t)


## Appends car k's frame at replay time t, the chase camera eased towards its place behind it.
func _frame(k: int, t: float) -> void:
	var w: ReplayWriter = writers[k]
	var xf := cars[k].global_transform
	var fwd := -xf.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length_squared() > 1e-6 else Vector3.FORWARD
	var want := xf.origin - fwd * CHASE_BACK + Vector3.UP * CHASE_UP
	var p: Vector3 = chase[k]
	if not p.is_finite() or p.distance_to(want) > 20.0:
		p = want
	else:
		p = p.lerp(want, 1.0 - exp(-CHASE_RATE * F.TICKS_PER_FRAME / float(Engine.physics_ticks_per_second)))
	chase[k] = p
	w.cam_id = 0
	w.cam_xf = Transform3D(Basis.looking_at(xf.origin + fwd * 3.0 + Vector3.UP * 0.8 - p, Vector3.UP), p)
	w.cam_fov = 70.0
	w.cam_t = t
	w.frame(t, cars[k], game.State.FREE_ROAM, 0, 0, t, runs[k]["time"] < 0.0)


## Writes every open replay to the `replays` folder.
func _close_replays() -> void:
	for k in writers.size():
		var w: ReplayWriter = writers[k]
		if w == null or w.frames_written == 0:
			continue
		var r: Dictionary = runs[k]
		w.event(rec_tick / float(Engine.physics_ticks_per_second), {"type": "end",
				"reason": "finish" if r["time"] >= 0.0 else "time", "metres": r["dist"], "resets": r["resets"],
				"frames": w.frames_written})
		var block := w.take_block()
		var bytes := F.header_bytes(headers[k])
		bytes.append_array(F.block_bytes(block["frames"], block["count"], block["events"]))
		var name := "%s_%d.%s" % [str(routes[route_of[k]]["id"]).replace(":", "_"), k, F.EXTENSION]
		var f := FileAccess.open(str(opts["replays"]).path_join(name), FileAccess.WRITE)
		f.store_buffer(bytes)
		f.close()
		writers[k] = null


func _quit(code: int) -> void:
	_close_replays()
	super(code)
