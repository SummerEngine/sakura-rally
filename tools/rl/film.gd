extends SceneTree
## Footage for the "how the AI learned to drive" video, rendered offline by Movie Maker: run
## tools/rl/render_film.sh, not this script directly (cue times count Movie Maker frames at
## 60 fps). The real game, driven by AutoDrive (docs/RL.md):
##   the title -> free roam on Hanami: every training generation in assets/ai/generations, oldest
##   first, drives the player's car from a standstill at the same spot (CORNER_FROM) into the
##   same corners (a 55 m bend, then the tarmac hairpin) -> the shipped driver there again with
##   what its network sees drawn over the road (DriveSense: 9 rays to the road's edge, 14
##   centre-line points ahead) -> a Hanami Time Attack with every generation as a ghost, the
##   camera on the newest at the back of the grid -> free roam on Momiji, a road no generation
##   trained on.
## Music is muted here: cut_film.py lays the drive theme under the edit. Cues go to
## <footage>/cues.json: video seconds, each clip's policy (file, run, steps) and what the car did
## (where it first left the road and how fast, its speed at each marked corner).
##
## Check the flow without pixels (headless, a few times faster than real time):
##   timeout -k 10 900 $S --headless --disable-crash-handler --audio-driver Dummy --fixed-fps 60 \
##       --path . -s res://tools/rl/film.gd -- footage=/tmp/sakura_film_check
##
## Cue times count main-loop iterations, one per Movie Maker frame; KeepDrawing (as in
## tools/video/demo.gd) draws the frames macOS skips for a covered window.

## Hanami progress (m from the start line) of the standstill every generation starts from:
## 150 m before a kink (479 m), a 55 m-radius bend (559 m) and the tarmac hairpin (669 m).
const CORNER_FROM := 330.0
const CORNER_MARKS := {"bend": 540.0, "hairpin": 665.0}
const CLIP_S := 16.0
const SEES_S := 15.0
## The race: the newest ghost reaches the bend about 17 s after GO.
const RACE_S := 24.0
const RACE_MARKS := {"bend": 520.0}
## Momiji: tarmac (712 m, r 46 m) and gravel (812 m, r 38 m) bends, then the gravel hairpin.
const HELD_OUT := "momiji"
const HELD_OUT_FROM := 560.0
const HELD_OUT_MARKS := {"tarmac": 690.0, "gravel": 790.0}
const HELD_OUT_S := 16.0
const FPS := 60.0

## footage=<dir>: where cues.json goes (not `out=`, which Summer reads as a probe's results folder
## under --summer-offscreen and closes the window ~30 s into the take).
var opts := {"footage": "/tmp/sakura_film"}
var main: Node
var game: Node
var ai: Node # untyped: AutoDrive needs the Game autoload to compile
var entered: Dictionary = {}
var cues: Array[Dictionary] = []
var _frame0 := 0


## Runs last in every iteration; after one that drew nothing (the window covered), renders the
## frame into the viewport texture, which Movie Maker reads (tools/video/demo.gd).
class KeepDrawing extends Node:
	var _drawn := -1

	func _init() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		process_priority = 1 << 30

	func _process(delta: float) -> void:
		var drawn := Engine.get_frames_drawn()
		if drawn == _drawn:
			RenderingServer.force_draw(false, delta)
		_drawn = drawn


## What the network sees, drawn over the road around the car its pilot drives: the rays to the edge
## of the drivable road and the centre-line points ahead (DriveSense), nothing else. Drawn through
## everything, the car included.
class SenseView extends MeshInstance3D:
	const RAY_COLOUR := Color(0.91, 0.32, 0.49, 0.8)
	const HIT_COLOUR := Color(1.0, 1.0, 1.0, 0.95)
	const ROAD_COLOUR := Color(0.37, 0.83, 0.64, 0.95)
	const LIFT := 0.5 # m above the car's origin
	const RAY_HALF_WIDTH := 0.06
	var pilot: NeuralPilot
	var _mesh := ImmediateMesh.new()

	func _init() -> void:
		mesh = _mesh
		cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.vertex_color_use_as_albedo = true
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.no_depth_test = true
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		material_override = m

	func _process(_delta: float) -> void:
		_mesh.clear_surfaces()
		if pilot == null or not is_instance_valid(pilot) or pilot.sense == null or pilot.sense.hint < 0:
			return
		var sense := pilot.sense
		var base := pilot.car.global_position + Vector3.UP * LIFT
		var fwd := -pilot.car.global_basis.z
		fwd.y = 0.0
		fwd = fwd.normalized()
		var right := Vector3(-fwd.z, 0.0, fwd.x)
		_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
		for k in DriveSense.RAY_COUNT:
			var a := deg_to_rad(DriveSense.RAY_ANGLES_DEG[k])
			var hit := base + (fwd * cos(a) + right * sin(a)) * sense.rays[k]
			_ribbon(base, hit, RAY_HALF_WIDTH, RAY_COLOUR)
			_diamond(hit, 0.22, HIT_COLOUR)
		var t := sense.track
		var s := t.abs_s(sense.hint, pilot.car.global_position)
		for d: float in DriveSense.AHEAD_M:
			_diamond(t.position_at_abs(s + d, 0.0) + Vector3.UP * LIFT, 0.3 + d * 0.004, ROAD_COLOUR)
		_mesh.surface_end()

	func _ribbon(a: Vector3, b: Vector3, w: float, c: Color) -> void:
		var side := (b - a).cross(Vector3.UP).normalized() * w
		for v: Vector3 in [a + side, b + side, b - side, a + side, b - side, a - side]:
			_mesh.surface_set_color(c)
			_mesh.surface_add_vertex(v)

	func _diamond(p: Vector3, r: float, c: Color) -> void:
		var x := Vector3(r, 0.0, 0.0)
		var z := Vector3(0.0, 0.0, r)
		for v: Vector3 in [p + x, p + z, p - x, p + x, p - x, p - z]:
			_mesh.surface_set_color(c)
			_mesh.surface_add_vertex(v)


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	DirAccess.make_dir_recursive_absolute(opts["footage"])
	game = root.get_node("Game")
	game.set_setting("music_volume", 0.0) # a -s harness never saves settings (Game.persistent)
	game.state_changed.connect(func(s: int, _o: int) -> void: entered[s] = int(entered.get(s, 0)) + 1)
	# A window close request quits the game mid-take: say so in the log.
	root.close_requested.connect(func() -> void: print("WINDOW close requested at %.2f s" % _now()))
	_frame0 = Engine.get_process_frames()
	root.add_child(KeepDrawing.new())
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func _run() -> void:
	await _until_entered(game.State.MENU, 90.0)
	ai = main.get_node("AutoDrive")
	var files: PackedStringArray = ai._generation_files()
	if files.is_empty():
		_fail("no generations in %s" % ai.GENERATIONS_DIR)
		return
	await _seconds(4.0) # the title animates in over the flyover
	_cue("title")
	await _seconds(3.0)

	# Free roam on Hanami: each generation from the same standstill into the same corners.
	ai.auto_drive = true
	ai.ghosts_on = false
	game.request_start("hanami", game.MODE_FREE_ROAM)
	await _until_entered(game.State.FREE_ROAM, 90.0)
	await _seconds(1.0)
	_cue("corner_from", {"progress": CORNER_FROM})
	for i in files.size():
		var p := DrivePolicy.load_file(files[i])
		await _drive_from(p, "hanami", CORNER_FROM)
		_cue("gen_%d" % i, {"file": files[i].get_file(), "steps": int(p.meta.get("steps", 0)),
				"run": str(p.meta.get("run", ""))})
		await _watch("gen_%d" % i, main.car, "hanami", CLIP_S, CORNER_MARKS)
	# The shipped driver again, with what its network sees drawn over the road.
	await _drive_from(DrivePolicy.load_file(ai.DRIVER), "hanami", CORNER_FROM)
	var view := SenseView.new()
	view.pilot = ai._pilot
	main.add_child(view)
	_cue("sees")
	await _watch("sees", main.car, "hanami", SEES_S, CORNER_MARKS)
	view.queue_free()

	# A Hanami Time Attack with every generation as a ghost, the newest (at the back) watched.
	ai.ghosts_on = true
	var countdown := int(entered.get(game.State.COUNTDOWN, 0)) + 1
	var race := int(entered.get(game.State.RACING, 0)) + 1
	game.request_menu()
	await _until_entered(game.State.MENU, 60.0, int(entered.get(game.State.MENU, 0)) + 1)
	await _seconds(1.0)
	game.request_start("hanami", game.MODE_TIME_TRIAL)
	await _until_entered(game.State.COUNTDOWN, 90.0, countdown)
	await _until(func() -> bool: return ai.ghosts.size() == files.size(), 10.0)
	var newest: Car = ai.ghosts[ai.ghosts.size() - 1]
	main.chase.target = newest
	main.chase.snap()
	_cue("grid")
	await _until_entered(game.State.RACING, 30.0, race)
	_cue("race")
	await _watch("race", newest, "hanami", RACE_S, RACE_MARKS)

	# Free roam on a road no generation trained on.
	ai.ghosts_on = false
	game.request_menu()
	await _until_entered(game.State.MENU, 60.0, int(entered.get(game.State.MENU, 0)) + 1)
	await _seconds(1.0)
	var roam := int(entered.get(game.State.FREE_ROAM, 0)) + 1
	game.request_start(HELD_OUT, game.MODE_FREE_ROAM)
	await _until_entered(game.State.FREE_ROAM, 90.0, roam)
	await _seconds(1.0)
	await _drive_from(DrivePolicy.load_file(ai.DRIVER), HELD_OUT, HELD_OUT_FROM)
	_cue("held_out")
	await _watch("held_out", main.car, HELD_OUT, HELD_OUT_S, HELD_OUT_MARKS)

	_cue("end")
	var f := FileAccess.open("%s/cues.json" % opts["footage"], FileAccess.WRITE)
	f.store_string(JSON.stringify(cues, "  "))
	f.close()
	print("FILM done: %d cues, %.1f s of footage" % [cues.size(), _now()])
	game.request_quit()


## The player's car at rest on `route` at `progress` (m from its start line), driven by `policy`
## (a new NeuralPilot: AutoDrive attaches one to a car without a pilot), the camera behind it.
func _drive_from(policy: DrivePolicy, route: String, progress: float) -> void:
	ai.policy = policy
	ai._detach(false)
	var t: Track = main.map.routes[route]["track"]
	(main.car as Car).place_at_rest(t.transform_at_abs(t.start_s + progress, 0.0))
	await physics_frame
	await physics_frame
	ai._trouble.clear()
	main.chase.snap()


## Films `car` for `seconds`, cueing `<tag>_off` where it first leaves the road (progress, km/h)
## and `<tag>_<mark>` as it passes each mark (km/h).
func _watch(tag: String, car: Car, route: String, seconds: float, marks: Dictionary) -> void:
	var t: Track = main.map.routes[route]["track"]
	var sense := DriveSense.new(t)
	var logged := {}
	var end := _now() + seconds
	while _now() < end:
		await process_frame
		if not is_instance_valid(car):
			return
		var pos := car.global_position
		sense.hint = t.nearest(pos, sense.hint, DriveSense.SEARCH_WINDOW)
		var p := wrapf(sense.road_s(pos) - t.start_s, 0.0, t.length)
		if not logged.has("off") and absf(sense.road_lateral(pos)) > sense.road_edge() + 1.0:
			logged["off"] = true
			_cue(tag + "_off", {"progress": snappedf(p, 0.1), "kmh": roundi(car.speed_kmh)})
		for m: String in marks:
			if not logged.has(m) and not logged.has("off") and p >= float(marks[m]) and p < float(marks[m]) + 40.0:
				logged[m] = true
				_cue(tag + "_" + m, {"kmh": roundi(car.speed_kmh)})


func _now() -> float:
	return (Engine.get_process_frames() - _frame0) / FPS


func _cue(cue_name: String, extra: Dictionary = {}) -> void:
	var cue := {"name": cue_name, "t": snappedf(_now(), 0.001)}
	cue.merge(extra)
	cues.append(cue)
	print("CUE %8.3f %s %s" % [cue["t"], cue_name, JSON.stringify(extra) if not extra.is_empty() else ""])


func _fail(why: String) -> void:
	printerr("film: " + why)
	game.request_quit(3)


func _seconds(s: float) -> void:
	var end := _now() + s
	while _now() < end:
		await process_frame


## Until `state` has been entered `count` times (default: at least once).
func _until_entered(state: int, limit: float, count: int = 1) -> void:
	await _until(func() -> bool: return int(entered.get(state, 0)) >= count, limit)


func _until(ok: Callable, limit: float) -> void:
	var end := _now() + limit
	while not ok.call():
		if _now() > end:
			_fail("timed out at %.1f s" % _now())
			return
		await process_frame
