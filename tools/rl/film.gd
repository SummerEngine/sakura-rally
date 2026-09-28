extends SceneTree
## "How the AI learned to drive": the footage of the narrated vertical video (1080x1920, about a
## minute), rendered offline by Movie Maker from the AI's recorded practice (tools/rl/swarm.gd).
## Run tools/rl/render_film.sh, not this script directly (cue times count Movie Maker frames at
## 60 fps). Nothing here drives: every car is a ReplayGhost posed from its replay file, so a whole
## generation is on the road at once, and since the replays know what comes next every camera and
## every shot's time window is worked out before the shot plays. A car turns grey where its run
## ended the way a training episode ends (off the road, crashed, stalled, the wrong way).
## The shots follow the narration (tools/rl/film.json), each as long as the longest voice keeps
## it on screen (`lengths`, from tools/rl/narrate.py):
##   hook      the untrained network's cars scattering off Hanami's start line, from 3 s after the
##             start (busy from the first frame), seen low from the roadside ahead as they come
##             at the camera and off the road into the cherry trees;
##   tease     the cars after 80 minutes of practice: a column over the first straight, from a
##             drone following the pack;
##   sees      the shipped driver's fastest run chased at its shoulder, with what its network
##             sees drawn over the road (SenseView); brain: the same run on, from higher up;
##   score     1 minute of practice from a drone behind the pack, the points over every eighth
##             car (+1 every 20 m of road, -3 where its run ends: the reward, train_env.gd);
##   loop      16 minutes of practice, the drone behind the pack; scale: on, from high up;
##   corner_N  the right-hander 540-590 m into Hanami, where the early generations fly off the
##             outside, from high behind its approach: 3 minutes of practice, then 31;
##   finish    80 minutes of practice over the finish line (finishers drive on, swarm.gd);
##   momiji    the shipped driver's cars on Momiji, a road no generation practised on, from a
##             drone over the pack at 2.5x speed.
## Nothing here draws text but the points: cut_film.py lays the captions, cards and counters
## over the footage. Reads <swarm>/<route>/<generation>/ (swarm.gd); writes <footage>/cues.json:
## each shot's start (video seconds), frames, playback start (`from`) and speed; after it how
## far the ground moved on screen per frame (pan_max, px of the frame), how big the nearest
## driving car was (hero_px), every run as [when it ended, finished, when it passed the shot's
## `mark` or -1], the runs that ended in frame during the shot as [frame, finished, the car's size
## in px] (`ends`: cut_film.py puts a sound on them) and, for a chase, the car's controls [steer,
## throttle, brake, handbrake] and rays (fractions of their 60 m) every frame.
##
## Check the flow and the camera numbers without pixels (headless):
##   timeout -k 10 600 $S --headless --disable-crash-handler --audio-driver Dummy --fixed-fps 60 \
##       --path . -s res://tools/rl/film.gd -- swarm=/tmp/sakura_film/swarm footage=/tmp/x
## Stills to judge the framing (pixels: offscreen, dev build, under the render lock): stills=N
## saves N frames of every shot to <footage>/stills/<shot>_<i>.png instead of playing it.
##
## KeepDrawing (as in tools/video/demo.gd) draws the frames macOS skips for a covered window.

const FPS := 60.0
## The output frame: vertical, for Shorts.
const ROWS := 1920.0
const COLS := 1080.0
const ROUTE := "hanami"
const HELD_OUT := "momiji"
## The shipped driver (assets/ai/driver.json: gen1 6M fine-tuned to steer calmly).
const SHIPPED := "gen2_7000000"
## Footage rendered past each shot's length, so the cut never runs short.
const TAIL_S := 0.25
## Liveries of the cars still driving (by car), and of a car whose run ended.
const LIVERIES: Array[Color] = [Color("7fc8f8"), Color("f9a03f"), Color("b388eb"), Color("5fd3a2"),
		Color("f25f5c"), Color("ffe066"), Color("e8517c"), Color("fbf5ec")]
const ENDED := Color(0.56, 0.56, 0.6)
const UITheme := preload("res://scripts/ui/ui_theme.gd")
## The points over a car in the score shot: +1 per SCORE_M m of road while its run lasts, then
## -3 rising and fading where it ended. Colours as cut_film.py's chips.
const SCORE_M := 20.0
const PLUS := Color("3fb489")
const MINUS := Color("e8517c")
const SCORE_FONT := preload("res://assets/fonts/DelaGothicOne-Regular.ttf")

## swarm=<dir>: the recordings. footage=<dir>: where cues.json goes (not `out=`, which Summer
## reads as a probe's results folder under --summer-offscreen and closes the window mid-take).
## lengths=<file>: each shot's seconds (tools/rl/narrate.py; a shot missing there: its `secs`).
## stills=N: see above. shots=a,b: only those shots.
var opts := {"swarm": "/tmp/sakura_film/swarm", "footage": "/tmp/sakura_film", "lengths": "", "stills": "0",
		"shots": ""}
var view: ReplayView
var cues: Array[Dictionary] = []
var _frame0 := 0
var _route := ""
## <swarm>/practice.json (cut_film.py practice): each generation's training time and caption.
var practice := {}
## Each shot's seconds, from `lengths`.
var lengths := {}
## Where each shot played so far ended (playback seconds), for a shot that goes on `after` it.
var _ends := {}


## Runs last in every _process: when the engine will not draw this iteration (macOS reports the
## window covered, as it does under a fullscreen video), renders the frame into the viewport
## texture that Movie Maker reads, in this iteration (tools/video/demo.gd). Noticing the skipped
## draw one iteration late held one frame and doubled the next at every covered/visible switch.
## The frame drawn here is the engine's own: the shots pose the cars and the camera at
## process_frame, before the tree pushes transforms to the renderer.
class KeepDrawing extends Node:
	func _init() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		process_priority = 1 << 30

	func _process(delta: float) -> void:
		if not DisplayServer.window_can_draw() or not RenderingServer.render_loop_enabled:
			RenderingServer.force_draw(false, delta)


## One generation's recorded practice: runs.json, every run's replay, when each run ended and
## whether it finished, and each run's distance from the start line per frame (unwrapped across
## the line on a loop, so a finisher reads past the stage's length).
class Swarm:
	var name: String
	var info: Dictionary
	var length: float = 1.0
	var runs: Array[ReplayData] = []
	var ends := PackedFloat32Array()
	var finished := PackedByteArray()
	var progress: Array[PackedFloat32Array] = []

	func progress_at(k: int, t: float) -> float:
		return progress[k][runs[k].index_at(t)]

	func finishers() -> int:
		var n := 0
		for f in finished:
			n += f
		return n

	## The first time run k is `s` m from the start line, INF if it never gets there.
	func time_at(k: int, s: float) -> float:
		var p := progress[k]
		for i in p.size():
			if p[i] >= s:
				return runs[k].time(i)
		return INF

	## The run of the car that finished first, else of the one that got furthest.
	func best() -> int:
		var pick := 0
		for k in runs.size():
			var a := finished[k] == 1
			var b := finished[pick] == 1
			var further := progress[k][progress[k].size() - 1] > progress[pick][progress[pick].size() - 1]
			if a and not b or a == b and (ends[k] < ends[pick] if a else further):
				pick = k
		return pick


## A shot's camera, one transform and vertical FOV per frame, worked out before it plays.
## `pan_max`, `pan_p95`: how far the ground at the aim moves on screen from one frame to the next
## (px of the output frame, the worst of five points around the aim).
class CameraPath:
	var xf: Array[Transform3D] = []
	var fov := PackedFloat32Array()
	var aim := PackedVector3Array()
	var pan_max := 0.0
	var pan_p95 := 0.0

	## `rows`: the output frame's height in px (its focal length follows from the FOV).
	func measure(rows: float, cols: float) -> void:
		var pans := PackedFloat32Array([0.0])
		for f in range(1, xf.size()):
			var was := xf[f - 1].affine_inverse()
			var now := xf[f].affine_inverse()
			var d := xf[f - 1].origin.distance_to(aim[f - 1])
			var r := xf[f - 1].basis.x * d * 0.3
			var u := xf[f - 1].basis.y * d * 0.2
			var worst := 0.0
			var focal := rows * 0.5 / tan(deg_to_rad(fov[f] * 0.5))
			for p: Vector3 in [aim[f - 1], aim[f - 1] + r, aim[f - 1] - r, aim[f - 1] + u, aim[f - 1] - u]:
				worst = maxf(worst, (CameraPath.px(now * p, focal) - CameraPath.px(was * p, focal)).length())
			pans.append(worst)
		var sorted := pans.duplicate()
		sorted.sort()
		pan_max = sorted[sorted.size() - 1]
		pan_p95 = sorted[int(0.95 * (sorted.size() - 1))]

	## Screen position (px from the centre) of a point in camera space.
	static func px(q: Vector3, focal: float) -> Vector2:
		return Vector2(q.x, -q.y) / maxf(-q.z, 0.01) * focal


## What the network sees, drawn over the road around `car`: the rays to the edge of the drivable
## road and the centre-line points ahead (DriveSense), nothing else. Drawn through everything,
## the car included, turned to the camera and one size on screen near and far. Colours as in
## cut_film.py's cards.
class SenseView extends MeshInstance3D:
	const RAY_COLOUR := Color(0.91, 0.32, 0.49, 0.85)
	const HIT_COLOUR := Color(0.91, 0.32, 0.49, 1.0)
	const ROAD_COLOUR := Color(0.25, 0.71, 0.54, 1.0)
	const LIFT := 0.5 # m above the car's origin
	## Half a ray's width and a mark's radius per metre from the camera.
	const RAY_HALF := 0.004
	const MARK_R := 0.011
	var car: Car
	var sense: DriveSense
	var _mesh := ImmediateMesh.new()
	var _eye := Vector3.ZERO
	var _right := Vector3.RIGHT
	var _up := Vector3.UP

	func _init() -> void:
		mesh = _mesh
		cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.vertex_color_use_as_albedo = true
		m.vertex_color_is_srgb = true
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.no_depth_test = true
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		material_override = m

	func _process(_delta: float) -> void:
		_mesh.clear_surfaces()
		var cam := get_viewport().get_camera_3d()
		if cam == null or car == null or not is_instance_valid(car):
			return
		_eye = cam.global_position
		_right = cam.global_basis.x
		_up = cam.global_basis.y
		var pos := car.global_position
		var fwd := -car.global_basis.z
		fwd.y = 0.0
		fwd = fwd.normalized()
		var right := Vector3(-fwd.z, 0.0, fwd.x)
		sense.look(pos, fwd, right)
		var base := pos + Vector3.UP * LIFT
		_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
		for k in DriveSense.RAY_COUNT:
			var a := deg_to_rad(DriveSense.RAY_ANGLES_DEG[k])
			var hit := base + (fwd * cos(a) + right * sin(a)) * sense.rays[k]
			_ray(base, hit, RAY_COLOUR)
			_mark(hit, HIT_COLOUR)
		var t := sense.track
		var s := t.abs_s(sense.hint, pos)
		for d: float in DriveSense.AHEAD_M:
			_mark(t.position_at_abs(s + d, 0.0) + Vector3.UP * LIFT, ROAD_COLOUR)
		_mesh.surface_end()

	## A band from a to b, turned to the camera, RAY_HALF per metre from it either side.
	func _ray(a: Vector3, b: Vector3, c: Color) -> void:
		var dir := b - a
		var sa := dir.cross(_eye - a).normalized() * (_eye.distance_to(a) * RAY_HALF)
		var sb := dir.cross(_eye - b).normalized() * (_eye.distance_to(b) * RAY_HALF)
		for v: Vector3 in [a + sa, b + sb, b - sb, a + sa, b - sb, a - sa]:
			_mesh.surface_set_color(c)
			_mesh.surface_add_vertex(v)

	## A diamond facing the camera, MARK_R per metre from it.
	func _mark(p: Vector3, c: Color) -> void:
		var r := _eye.distance_to(p) * MARK_R
		var x := _right * r
		var y := _up * r
		for v: Vector3 in [p + x, p + y, p - x, p + x, p - x, p - y]:
			_mesh.surface_set_color(c)
			_mesh.surface_add_vertex(v)


## The shots in order. Each: `tag` (its name in film.json), `route`, `gen`, `secs` (its length
## when `lengths` has none), `speed` (playback seconds per screen second), where its window
## starts (`from`: a playback time; `at`: the median time the cars reach `at` m, "finish" the end
## of the lap, centred in the shot and shifted by `lead` screen seconds; `after`: where that shot
## ended), `mark` (m: cues.json says when each car got there), `scores` (the points over every
## Nth car), `car` (best: the fastest run, alone) and its camera `cam`:
##   roadside: `pos` [m from the start line, m right of the centre line, m over the ground], to
##   `pos1` over the shot when given (a crane or a dolly, eased); looking at `aim` (same
##   coordinates, to `aim1`) pulled `follow` of the way towards the cars inside `zone` [m, m from
##   the start line; on a loop, before it is negative]; `fov` vertical degrees.
##   chase: the `car` run from `back` m behind, `side` m right and `up` m over it, looking
##   `ahead` m in front of it.
##   drone: over the pack, holding one heading (the road's at `yaw_at` m, turned `yaw`° to the
##   right): `dist` m from a point `lead` of that ahead of the middle of the cars still driving
##   within `band` m of the front, looking down `pitch`°, `side` of `dist` to the right, at
##   least `clear` m over the ground.
func _plan() -> Array[Dictionary]:
	# The start: low by the road 36-42 m past the line, clear of the 10 m carriageway, looking
	# back at the cars coming off the line and scattering towards it.
	var start := {"kind": "roadside", "zone": [-10.0, 60.0], "pos": [42.0, -7.0, 3.2], "pos1": [36.0, -7.5, 2.6],
			"aim": [8.0, 0.0, 0.8], "follow": 0.3, "fov": 56.0}
	# The corner from high behind the approach, looking down into it: the cars come up the frame
	# and either turn with the road or fly straight on into the trees off its outside.
	var corner := {"kind": "roadside", "zone": [470.0, 640.0], "pos": [505.0, 8.0, 42.0], "pos1": [510.0, 8.0, 41.0],
			"aim": [565.0, -4.0, 0.0], "follow": 0.2, "fov": 52.0}
	var behind := {"kind": "drone", "yaw_at": 60.0, "yaw": 0.0, "dist": 42.0, "pitch": 38.0, "lead": 0.2, "side": 0.0,
			"band": 120.0, "clear": 8.0, "fov": 58.0}
	var shots: Array[Dictionary] = [
		# from 3 s after the start, when the cars are already spreading over the road (the hook's
		# first frame must be busy)
		{"tag": "hook", "route": ROUTE, "gen": "demo_0", "secs": 3.0, "speed": 1.0, "from": 3.0, "cam": start},
		# the same cars after 80 minutes: the column over the first straight, from the drone that
		# follows the pack (a camera by the road sees them pass in a second)
		{"tag": "tease", "route": ROUTE, "gen": "gen1_6000000", "secs": 4.0, "speed": 1.0, "from": 2.0,
			"cam": {"kind": "drone", "yaw_at": 60.0, "yaw": 0.0, "dist": 36.0, "pitch": 30.0, "lead": 0.25, "side": 0.12,
				"band": 160.0, "clear": 6.0, "fov": 56.0}},
		{"tag": "sees", "route": ROUTE, "gen": SHIPPED, "secs": 16.0, "speed": 1.0, "at": 420.0, "car": "best",
			"cam": {"kind": "chase", "back": 8.5, "side": -1.8, "up": 3.4, "ahead": 16.0, "fov": 64.0}},
		{"tag": "brain", "route": ROUTE, "gen": SHIPPED, "secs": 7.0, "speed": 1.0, "after": "sees", "car": "best",
			"cam": {"kind": "chase", "back": 12.0, "side": -2.0, "up": 6.0, "ahead": 14.0, "fov": 62.0}},
		{"tag": "score", "route": ROUTE, "gen": "demo_100032", "secs": 9.0, "speed": 1.0, "from": 2.0, "scores": 8,
			"cam": behind},
		# how it learns, over 16 minutes of practice: the pack from behind, then from high up
		{"tag": "loop", "route": ROUTE, "gen": "gen1_1000000", "secs": 10.0, "speed": 1.0, "from": 3.0, "cam": behind},
		{"tag": "scale", "route": ROUTE, "gen": "gen1_1000000", "secs": 6.0, "speed": 1.0, "after": "loop",
			"cam": {"kind": "drone", "yaw_at": 300.0, "yaw": 0.0, "dist": 95.0, "pitch": 60.0, "lead": 0.1, "side": 0.0,
				"band": 250.0, "clear": 20.0, "fov": 60.0}},
		# the pack reaching the corner a second in, flying off it over the next two
		{"tag": "corner_0", "route": ROUTE, "gen": "demo_300032", "secs": 3.5, "speed": 1.0, "at": 545.0, "lead": 0.4,
			"mark": 620.0, "cam": corner},
		{"tag": "corner_1", "route": ROUTE, "gen": "gen1_2000000", "secs": 4.5, "speed": 1.0, "at": 555.0, "lead": 0.3,
			"mark": 620.0, "cam": corner},
		# The finish: 30 m before the line and to the right, looking along the road over it.
		{"tag": "finish", "route": ROUTE, "gen": "gen1_6000000", "secs": 5.5, "speed": 1.5, "at": "finish",
			"cam": {"kind": "roadside", "zone": [-60.0, 40.0], "pos": [-30.0, 10.0, 3.2], "pos1": [-26.0, 10.5, 3.4],
				"aim": [6.0, 0.0, 1.0], "follow": 0.35, "fov": 50.0}},
		# Momiji from above, sped up: the whole pack through the S-bend into the hairpin under the
		# maples, the drone looking down the road into the hairpin, so the cars run away up the
		# frame, turn and come back towards it.
		{"tag": "momiji", "route": HELD_OUT, "gen": SHIPPED, "secs": 15.0, "speed": 2.5, "at": 1060.0, "lead": 0.0,
			"cam": {"kind": "drone", "yaw_at": 990.0, "yaw": 0.0, "dist": 70.0, "pitch": 54.0, "lead": 0.12, "side": 0.0,
				"band": 90.0, "clear": 14.0, "fov": 66.0}},
	]
	var only := str(opts["shots"]).split(",", false)
	if only.is_empty():
		return shots
	var picked: Array[Dictionary] = []
	for s in shots:
		if str(s["tag"]) in only:
			picked.append(s)
	return picked


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	DirAccess.make_dir_recursive_absolute(opts["footage"])
	var prac: Variant = JSON.parse_string(FileAccess.get_file_as_string(str(opts["swarm"]).path_join("practice.json")))
	if typeof(prac) == TYPE_DICTIONARY:
		practice = prac
	if str(opts["lengths"]) != "":
		var ls: Variant = JSON.parse_string(FileAccess.get_file_as_string(str(opts["lengths"])))
		if typeof(ls) != TYPE_DICTIONARY:
			_fail("no shot lengths in %s (tools/rl/narrate.py)" % opts["lengths"])
			return
		lengths = ls
	root.close_requested.connect(func() -> void: print("WINDOW close requested at %.2f s" % _now()))
	_frame0 = Engine.get_process_frames()
	root.add_child(KeepDrawing.new())
	_run.call_deferred()


func _run() -> void:
	var stills := int(opts["stills"])
	print("FILM window %s" % str(root.size))
	for shot in _plan():
		if str(shot["route"]) != _route:
			await _world(str(shot["route"]))
		var sw := _load(str(shot["route"]), str(shot["gen"]))
		if sw == null:
			return
		await _shot(shot, sw, stills)
	_cue("end")
	if stills == 0:
		var f := FileAccess.open("%s/cues.json" % opts["footage"], FileAccess.WRITE)
		f.store_string(JSON.stringify(cues, "  "))
		f.close()
	print("FILM done: %d cues, %.1f s of footage" % [cues.size(), _now()])
	quit()


## A fresh world for `route` (the old one freed), its road gates open as swarm.gd drove them.
func _world(route: String) -> void:
	if view != null:
		view.queue_free()
		await process_frame
	view = ReplayView.new()
	view.name = "FilmView"
	root.add_child(view)
	await view.build_world(route, "high")
	for gate: RoadGate in view.map.gates.values():
		gate.set_open(true, false)
	# let the fresh world settle (streaming, the gates' props) before a shot's first frame
	for i in 30:
		await process_frame
	_route = route
	print("FILM world %s: sun %s" % [route, str(view.map.sun_dir)])


func _load(route: String, gen: String) -> Swarm:
	var dir := str(opts["swarm"]).path_join(route).path_join(gen)
	var info: Variant = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("runs.json")))
	if typeof(info) != TYPE_DICTIONARY:
		_fail("no recording in %s (tools/rl/swarm.gd)" % dir)
		return null
	var sw := Swarm.new()
	sw.name = gen
	sw.info = info
	sw.length = float(info["length"])
	var closed := bool(info["closed"])
	for r: Dictionary in info["runs"]:
		var data := ReplayData.load_file(dir.path_join(str(r["file"])))
		if data.error != "" or data.count == 0:
			_fail("%s/%s: %s" % [dir, r["file"], data.error if data.error != "" else "no frames"])
			return null
		sw.runs.append(data)
		sw.ends.append(float(r["end_t"]))
		sw.finished.append(1 if str(r["reason"]) == "finish" else 0)
		var prog := PackedFloat32Array()
		prog.resize(data.count)
		var last := data.route_s(0)
		var off := -sw.length if closed and last > sw.length * 0.5 else 0.0
		for i in data.count:
			var p := data.route_s(i)
			if closed:
				if p - last > sw.length * 0.5:
					off -= sw.length
				elif last - p > sw.length * 0.5:
					off += sw.length
			last = p
			prog[i] = p + off
		sw.progress.append(prog)
	return sw


## Plays one shot: its window of the practice, every car posed each frame (grey once its run has
## ended), the camera on its path. With `stills` > 0, only that many frames, each saved as a PNG.
func _shot(shot: Dictionary, sw: Swarm, stills: int) -> void:
	var track: Track = view.map.routes[str(shot["route"])]["track"]
	var tag := str(shot["tag"])
	var n_edit := roundi(float(lengths.get(tag, shot["secs"])) * FPS)
	var n := n_edit + roundi(TAIL_S * FPS)
	var speed := float(shot["speed"])
	var t0 := float(shot.get("from", 0.0))
	if shot.has("after"):
		t0 = float(_ends.get(str(shot["after"]), t0))
	elif shot.has("at"):
		var at := sw.length if str(shot["at"]) == "finish" else float(shot["at"])
		var arrive := PackedFloat32Array()
		for k in sw.runs.size():
			var t := sw.time_at(k, at)
			if t < INF:
				arrive.append(t)
		arrive.sort()
		var mid := arrive[arrive.size() / 2] if not arrive.is_empty() else 0.0
		t0 = maxf(mid - (n_edit / FPS * 0.5 - float(shot.get("lead", 0.0))) * speed, 0.0)
	_ends[tag] = t0 + n_edit / FPS * speed
	var times := PackedFloat32Array()
	for f in n:
		times.append(t0 + f / FPS * speed)
	var cam: Dictionary = shot["cam"]
	var car := sw.best() if str(shot.get("car", "")) == "best" else -1
	var path: CameraPath
	match str(cam["kind"]):
		"chase":
			path = _chase(sw, car, times, cam)
		"drone":
			path = _drone(sw, track, times, cam)
		_:
			path = _roadside(sw, track, times, cam, cam["zone"])
	path.measure(ROWS, COLS)

	var ghosts: Array[ReplayGhost] = []
	var eye: SenseView = null
	for k in sw.runs.size():
		if car >= 0 and k != car:
			ghosts.append(null)
			continue
		var g := ReplayGhost.spawn(view, sw.runs[k].header)
		var c := LIVERIES[k % LIVERIES.size()] if car < 0 else UITheme.PAPER
		g.car.set_livery(c, c.darkened(0.45) if car < 0 else UITheme.SAKURA)
		ghosts.append(g)
	if car >= 0:
		eye = SenseView.new()
		eye.car = ghosts[car].car
		eye.sense = DriveSense.new(track)
		view.add_child(eye)
	var every := int(shot.get("scores", 0))
	var scores: Array[Label3D] = []
	for k in sw.runs.size():
		scores.append(_score_tag() if every > 0 and k % every == 0 and ghosts[k] != null else null)
	var ended := PackedByteArray()
	ended.resize(sw.runs.size())
	# runs that end inside the shot with the car in frame: [frame, finished, the car's size in px]
	var events := []
	_cue(tag, {"generation": sw.name, "route": str(shot["route"]), "steps": int(sw.info.get("steps", 0)),
			"cars": sw.runs.size(), "finished": sw.finishers(), "frames": n_edit, "speed": speed,
			"from": snappedf(t0, 0.01), "practice": str((practice.get(sw.name, {}) as Dictionary).get("label", ""))})
	var pick := PackedInt32Array()
	if stills > 0:
		for i in stills:
			pick.append(roundi(i * (n_edit - 1) / maxf(stills - 1, 1)))
	var hero := PackedFloat32Array()
	var in_frame := PackedFloat32Array()
	var obs := []
	var one := PackedFloat32Array()
	one.resize(DriveSense.OBS_SIZE)
	var focal := ROWS * 0.5 / tan(deg_to_rad(path.fov[0] * 0.5))
	for f in n:
		if stills > 0 and not (f in pick):
			continue
		var t := times[f]
		var dt := speed / FPS if f > 0 and stills == 0 else 1.0 / FPS
		var inv := path.xf[f].affine_inverse()
		var big := 0.0
		var seen := 0
		for k in sw.runs.size():
			if ghosts[k] == null:
				continue
			ghosts[k].pose(sw.runs[k].car_at(t), dt)
			var q := inv * ghosts[k].car.global_position
			var sp := CameraPath.px(q, focal)
			var on := q.z < -1.0 and absf(sp.x) < COLS * 0.5 and absf(sp.y) < ROWS * 0.5
			if t >= sw.ends[k] and ended[k] == 0:
				ended[k] = 1
				if sw.finished[k] == 0 and car < 0:
					ghosts[k].car.set_livery(ENDED, ENDED.darkened(0.35))
				if on and f < n_edit and sw.ends[k] >= times[0]:
					events.append([f, int(sw.finished[k]), snappedf(4.2 * focal / -q.z, 1.0)])
			if on and (t < sw.ends[k] or sw.finished[k] == 1):
				seen += 1
				big = maxf(big, 4.2 * focal / -q.z)
		hero.append(big)
		in_frame.append(seen)
		if every > 0:
			_score_tags(scores, sw, ghosts, t)
		# what the network gets at this pose: DriveSense.observe on the ghost, given from the replay
		# what posing leaves out (yaw rate, steering, handbrake, the surface under each wheel)
		if eye != null and stills == 0 and f < n_edit:
			var fr := sw.runs[car].frame(sw.runs[car].index_at(t))
			var gc := ghosts[car].car
			gc.angular_velocity = fr["ang"]
			gc.input_steer = float(fr["input_steer"])
			gc.input_handbrake = float(fr["handbrake"]) > 0.5
			for w in 4:
				gc.wheels[w].surface = StringName(fr["wheels"][w]["surface"])
			eye.sense.observe(gc, one)
			var row := []
			for x in one:
				row.append(snappedf(x, 0.001))
			obs.append(row)
		view.camera.global_transform = path.xf[f]
		view.camera.fov = path.fov[f]
		view.camera.near = 0.1
		view.camera.far = 4000.0
		if stills > 0:
			await process_frame
			await process_frame
			await process_frame
			var img := root.get_texture().get_image()
			var file := "%s/stills/%s_%d.png" % [opts["footage"], tag, pick.find(f)]
			DirAccess.make_dir_recursive_absolute(file.get_base_dir())
			img.save_png(file)
			print("STILL %s t=%.2f %dx%d cars in frame %d, nearest %.0f px" % [file, t, img.get_width(), img.get_height(), seen, big])
		else:
			await process_frame
	var hs := hero.duplicate()
	hs.sort()
	var fs := in_frame.duplicate()
	fs.sort()
	var mark := float(shot.get("mark", -1.0))
	var runs := []
	for k in sw.runs.size():
		var mt := sw.time_at(k, mark) if mark >= 0.0 else INF
		runs.append([snappedf(sw.ends[k], 0.01), int(sw.finished[k]), snappedf(mt, 0.01) if mt < INF else -1.0])
	var end := {"pan_max": snappedf(path.pan_max, 0.1), "pan_p95": snappedf(path.pan_p95, 0.1),
			"hero_px_p50": snappedf(hs[hs.size() / 2], 1.0), "hero_px_max": snappedf(hs[hs.size() - 1], 1.0),
			"in_frame_p50": fs[fs.size() / 2], "in_frame_max": fs[fs.size() - 1], "runs": runs, "ends": events}
	if car >= 0:
		end["obs"] = obs
	_cue(tag + "_end", end)
	if eye != null:
		eye.queue_free()
	for g in ghosts:
		if g != null:
			g.car.queue_free()
	for lab in scores:
		if lab != null:
			lab.queue_free()


## A car's points in the score shot (_score_tags sets them).
func _score_tag() -> Label3D:
	var lab := Label3D.new()
	lab.font = SCORE_FONT
	lab.font_size = 96
	lab.outline_size = 28
	lab.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lab.no_depth_test = true
	lab.fixed_size = true
	lab.pixel_size = 0.0007
	lab.shaded = false
	lab.render_priority = 2
	lab.outline_render_priority = 1
	lab.visible = false
	view.add_child(lab)
	return lab


## Over each scored car: +1 per SCORE_M m of road while its run lasts; where it ended, -3 rising
## off it and fading out.
func _score_tags(tags: Array[Label3D], sw: Swarm, ghosts: Array[ReplayGhost], t: float) -> void:
	var ink := Color(0.16, 0.14, 0.2, 0.9)
	for k in tags.size():
		var lab := tags[k]
		if lab == null:
			continue
		var p := ghosts[k].car.global_position + Vector3.UP * 2.2
		var age := t - sw.ends[k]
		if age < 0.0 or sw.finished[k] == 1:
			lab.text = "+%d" % floori(maxf(sw.progress_at(k, t), 0.0) / SCORE_M)
			lab.modulate = PLUS
			lab.outline_modulate = ink
			lab.position = p
			lab.visible = true
		else:
			var fade := 1.0 - clampf((age - 0.8) / 0.5, 0.0, 1.0)
			lab.text = "-3"
			lab.modulate = Color(MINUS, fade)
			lab.outline_modulate = Color(ink, ink.a * fade)
			lab.position = p + Vector3.UP * minf(age, 1.3)
			lab.visible = fade > 0.0


## A point [m from the start line, m right of the centre line, m over the ground] on `track`.
func _spot(track: Track, v: Array) -> Vector3:
	var p := track.position_at_abs(track.start_s + float(v[0]), float(v[1]))
	p.y = view.map.ground_height(p.x, p.z) + float(v[2])
	return p


## A camera standing by the road (moving from `pos` to `pos1` when given, eased), looking at
## `aim` pulled `follow` of the way towards the middle of the cars inside `zone` (those still
## driving, or ended less than a second ago; with none there, the nearest time there were),
## smoothed with no lag.
func _roadside(sw: Swarm, track: Track, times: PackedFloat32Array, lens: Dictionary, zone: Array) -> CameraPath:
	var n := times.size()
	var p0 := _spot(track, lens["pos"])
	var p1 := _spot(track, lens.get("pos1", lens["pos"]))
	var a0 := _spot(track, lens["aim"])
	var a1 := _spot(track, lens.get("aim1", lens["aim"]))
	var follow := float(lens.get("follow", 0.0))
	var cx := PackedFloat32Array()
	var cy := PackedFloat32Array()
	var cz := PackedFloat32Array()
	var seen := PackedByteArray()
	for f in n:
		var c := Vector3.ZERO
		var m := 0
		for k in sw.runs.size():
			if times[f] > sw.ends[k] + 1.0 and sw.finished[k] == 0:
				continue
			var s := sw.progress_at(k, times[f])
			if bool(sw.info["closed"]):
				s = wrapf(s, -sw.length * 0.5, sw.length * 0.5)
			if s >= float(zone[0]) and s <= float(zone[1]):
				c += sw.runs[k].pos(sw.runs[k].index_at(times[f]))
				m += 1
		if m > 0:
			c /= m
			c.y = view.map.ground_height(c.x, c.z) + 1.0
		cx.append(c.x)
		cy.append(c.y)
		cz.append(c.z)
		seen.append(1 if m > 0 else 0)
	# frames with nobody in the zone hold the nearest frame that had someone (before, else after),
	# so the aim never swings back to the bare `aim` when the pack has passed
	var last := -1
	for f in n:
		if seen[f] == 1:
			last = f
		elif last >= 0:
			cx[f] = cx[last]
			cy[f] = cy[last]
			cz[f] = cz[last]
	var first := seen.find(1)
	var w := 1.0 if first >= 0 else 0.0
	for f in range(0, maxi(first, 0)):
		cx[f] = cx[first]
		cy[f] = cy[first]
		cz[f] = cz[first]
	var sigma := 0.6 * FPS
	cx = _smooth(cx, sigma)
	cy = _smooth(cy, sigma)
	cz = _smooth(cz, sigma)
	var path := CameraPath.new()
	for f in n:
		var u := smoothstep(0.0, 1.0, f / maxf(n - 1, 1))
		var aim := a0.lerp(a1, u)
		var pack := Vector3(cx[f], cy[f], cz[f])
		var look := aim.lerp(pack, follow * w)
		var pos := p0.lerp(p1, u)
		path.xf.append(Transform3D(Basis(), pos).looking_at(look, Vector3.UP))
		path.fov.append(float(lens["fov"]))
		path.aim.append(look)
	return path


## A camera at the shoulder of run `k`: `back` m behind, `side` m right, `up` m over it, looking
## `ahead` m in front, the car's path smoothed with no lag so the camera floats. The path is
## worked out PAD_S beyond the shot at both ends, so the smoothing at its first and last frames
## sees where the car really was (held ends put the camera ahead of the car at a shot's start).
func _chase(sw: Swarm, k: int, times: PackedFloat32Array, lens: Dictionary) -> CameraPath:
	const PAD_S := 1.5
	var data := sw.runs[k]
	var n := times.size()
	var step := (times[n - 1] - times[0]) / maxf(n - 1, 1)
	var pad := roundi(PAD_S * FPS)
	var px := PackedFloat32Array()
	var py := PackedFloat32Array()
	var pz := PackedFloat32Array()
	var lx := PackedFloat32Array()
	var ly := PackedFloat32Array()
	var lz := PackedFloat32Array()
	for f in range(-pad, n + pad):
		var s: Dictionary = data.car_at(maxf(times[0] + f * step, 0.0))
		var xf: Transform3D = s["xform"]
		var fwd := -xf.basis.z
		fwd.y = 0.0
		fwd = fwd.normalized()
		var right := Vector3(-fwd.z, 0.0, fwd.x)
		var p := xf.origin - fwd * float(lens["back"]) + right * float(lens["side"]) + Vector3.UP * float(lens["up"])
		var l := xf.origin + fwd * float(lens["ahead"]) + Vector3.UP * 0.5
		px.append(p.x)
		py.append(p.y)
		pz.append(p.z)
		lx.append(l.x)
		ly.append(l.y)
		lz.append(l.z)
	var sp := 0.25 * FPS
	var sl := 0.35 * FPS
	px = _smooth(px, sp)
	py = _smooth(py, sp)
	pz = _smooth(pz, sp)
	lx = _smooth(lx, sl)
	ly = _smooth(ly, sl)
	lz = _smooth(lz, sl)
	var path := CameraPath.new()
	for f in range(pad, n + pad):
		var look := Vector3(lx[f], ly[f], lz[f])
		path.xf.append(Transform3D(Basis(), Vector3(px[f], py[f], pz[f])).looking_at(look, Vector3.UP))
		path.fov.append(float(lens["fov"]))
		path.aim.append(look)
	return path


## A drone over the pack that never turns, so the ground only slides under it: the middle of
## the cars still driving within `band` m of the front (their 90th percentile, all of them when
## fewer than 6), taken on the centre line at their distance along the road and smoothed with no
## lag; the camera `dist` m from a point `lead` of that ahead of the middle, looking down `pitch`°
## along the road's heading at `yaw_at` m turned `yaw`° to the right, `side` of `dist` to the
## right, raised where the ground comes within `clear` m.
func _drone(sw: Swarm, track: Track, times: PackedFloat32Array, lens: Dictionary) -> CameraPath:
	var n := times.size()
	var band := float(lens["band"])
	var cx := PackedFloat32Array()
	var cy := PackedFloat32Array()
	var cz := PackedFloat32Array()
	cx.resize(n)
	cy.resize(n)
	cz.resize(n)
	var seen := PackedByteArray()
	seen.resize(n)
	for f in n:
		var alive := PackedFloat32Array()
		for k in sw.runs.size():
			if times[f] < sw.ends[k]:
				alive.append(sw.progress_at(k, times[f]))
		if alive.is_empty():
			continue
		alive.sort()
		var front := alive[alive.size() - 1] if alive.size() < 6 else alive[int(alive.size() * 0.9)]
		var c := Vector3.ZERO
		var m := 0
		for p in alive:
			if p >= front - band and p <= front:
				c += track.position_at_abs(track.start_s + p, 0.0)
				m += 1
		c /= maxi(m, 1)
		cx[f] = c.x
		cy[f] = c.y
		cz[f] = c.z
		seen[f] = 1
	# nobody driving: hold the middle from before (at the start, the first one after)
	var first := seen.find(1)
	if first < 0:
		_fail("drone: no car drives during the shot")
		first = 0
	var last := first
	for f in n:
		if seen[f] == 1:
			last = f
		else:
			cx[f] = cx[last]
			cy[f] = cy[last]
			cz[f] = cz[last]
	var sigma := 0.5 * FPS
	cx = _smooth(cx, sigma)
	cy = _smooth(cy, sigma)
	cz = _smooth(cz, sigma)
	var fwd := track.forward_at_abs(track.start_s + float(lens["yaw_at"]))
	var heading := atan2(fwd.x, fwd.z) - deg_to_rad(float(lens["yaw"]))
	var dir := Vector3(sin(heading), 0.0, cos(heading))
	var right := Vector3(-dir.z, 0.0, dir.x)
	var d := float(lens["dist"])
	var pitch := deg_to_rad(float(lens["pitch"]))
	var back := -dir * d * cos(pitch) + right * d * float(lens["side"]) + Vector3.UP * d * sin(pitch)
	var aims := PackedVector3Array()
	var spots := PackedVector3Array()
	var raise := PackedFloat32Array()
	for f in n:
		var aim := Vector3(cx[f], cy[f], cz[f]) + dir * d * float(lens["lead"])
		var pos := aim + back
		aims.append(aim)
		spots.append(pos)
		raise.append(maxf(view.map.ground_height(pos.x, pos.z) + float(lens["clear"]) - pos.y, 0.0))
	raise = _smooth(_dilate(raise, roundi(0.5 * FPS)), 0.5 * FPS)
	var path := CameraPath.new()
	for f in n:
		path.xf.append(Transform3D(Basis(), spots[f] + Vector3.UP * raise[f]).looking_at(aims[f], Vector3.UP))
		path.fov.append(float(lens["fov"]))
		path.aim.append(aims[f])
	return path


## Close to a Gaussian of `sigma` samples (three box passes), with the ends held.
static func _smooth(a: PackedFloat32Array, sigma: float) -> PackedFloat32Array:
	var r := maxi(int(roundf(sigma)), 1)
	var out := a
	for i in 3:
		var n := out.size()
		var box := PackedFloat32Array()
		box.resize(n)
		var sum := 0.0
		for j in range(-r, r + 1):
			sum += out[clampi(j, 0, n - 1)]
		for j in n:
			box[j] = sum / (2 * r + 1)
			sum += out[clampi(j + r + 1, 0, n - 1)] - out[clampi(j - r, 0, n - 1)]
		out = box
	return out


## The largest value within `r` samples (so smoothing after it never dips under a peak).
static func _dilate(a: PackedFloat32Array, r: int) -> PackedFloat32Array:
	var n := a.size()
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var m := a[i]
		for j in range(maxi(i - r, 0), mini(i + r, n - 1) + 1):
			m = maxf(m, a[j])
		out[i] = m
	return out


func _now() -> float:
	return (Engine.get_process_frames() - _frame0) / FPS


func _cue(cue_name: String, extra: Dictionary = {}) -> void:
	var cue := {"name": cue_name, "t": snappedf(_now(), 0.001)}
	cue.merge(extra)
	cues.append(cue)
	var shown := {}
	for key in extra:
		if typeof(extra[key]) != TYPE_ARRAY:
			shown[key] = extra[key]
	print("CUE %8.3f %s %s" % [cue["t"], cue_name, JSON.stringify(shown) if not shown.is_empty() else ""])


func _fail(why: String) -> void:
	printerr("film: " + why)
	quit(3)
