extends SceneTree
## "How the AI learned to drive": the footage, rendered offline by Movie Maker from the AI's
## recorded practice (tools/rl/swarm.gd). Run tools/rl/render_film.sh, not this script directly
## (cue times count Movie Maker frames at 60 fps). Nothing here drives: every car is a
## ReplayGhost posed from its replay file, so a whole generation is on the road at once and the
## clock runs at any speed.
##   Every generation in GENERATIONS, oldest first: its cars leave the Hanami start line
##   together, the clock eases up to several times real speed, and a drone behind and above keeps
##   the cars still driving in frame. A car turns grey where its run ended the way a training
##   episode ends (off the road, crashed, stalled, the wrong way); the card counts the cars still
##   driving, and the strip along the bottom shows where every car is on the stage.
##   -> The shipped driver's fastest run at real speed from above and behind, with what its
##   network sees drawn over the road.
##   -> The shipped driver's cars on Momiji, a road no generation trained on.
## Reads <swarm>/<route>/<generation>/ (swarm.gd) and <swarm>/practice.json (cut_film.py
## practice: each generation's training time as a caption). Cues go to <footage>/cues.json:
## each shot's start and end (video seconds) and what it shows.
##
## Check the flow without pixels (headless):
##   timeout -k 10 900 $S --headless --disable-crash-handler --audio-driver Dummy --fixed-fps 60 \
##       --path . -s res://tools/rl/film.gd -- swarm=/tmp/sakura_swarm footage=/tmp/sakura_film_check
##
## KeepDrawing (as in tools/video/demo.gd) draws the frames macOS skips for a covered window.

const UITheme := preload("res://scripts/ui/ui_theme.gd")

const FPS := 60.0
## The generations shown, oldest first, as swarm.gd names their folders: the gen1 recipe's
## practice, from the untrained network (the demo run repeats it from scratch with a save every
## 100k steps) to 6M, the last gen1 checkpoint.
const GENERATIONS: Array[String] = ["demo_0", "demo_100032", "demo_300032", "gen1_1000000",
		"gen1_2000000", "gen1_3000000", "gen1_6000000"]
## The shipped driver (assets/ai/driver.json: gen1 6M fine-tuned to steer calmly), shown seeing
## the road and on Momiji.
const SHIPPED := "gen2_7000000"
const ROUTE := "hanami"
const HELD_OUT := "momiji"
## A generation's shot: its cars wait HOLD_S on the line (FIRST_HOLD_S in the first shot, under
## the title), then the clock eases from real speed (over RAMP_S of screen time) to the speed
## that shows the whole practice (until the last car stops, at most LAP_S) in about SHOT_S,
## never faster than MAX_SPEED. The last frame holds END_HOLD_S.
const HOLD_S := 0.5
const FIRST_HOLD_S := 2.5
const RAMP_S := 0.8
const SHOT_S := 5.0
const MAX_SPEED := 10.0
const LAP_S := 125.0
const END_HOLD_S := 0.6
## What it sees: the shipped driver's fastest run from SEES_FROM m of Hanami, SEES_S at real speed.
const SEES_FROM := 440.0
const SEES_S := 7.0
## Momiji: the shipped driver's cars, the first HELD_OUT_S of their practice.
const HELD_OUT_S := 75.0
## Liveries of the cars still driving (by car), and of a car whose run ended.
const LIVERIES: Array[Color] = [Color("7fc8f8"), Color("f9a03f"), Color("b388eb"), Color("5fd3a2"),
		Color("f25f5c"), Color("ffe066"), Color("e8517c"), Color("fbf5ec")]
const ENDED := Color(0.56, 0.56, 0.6)

## swarm=<dir>: the recordings. footage=<dir>: where cues.json goes (not `out=`, which Summer
## reads as a probe's results folder under --summer-offscreen and closes the window mid-take).
## gens=a,b,...: other generations than GENERATIONS.
var opts := {"swarm": "/tmp/sakura_swarm", "footage": "/tmp/sakura_film", "gens": ""}
var view: ReplayView
var hud: Hud
var practice: Dictionary = {}
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

	## Playback seconds until the last car stopped.
	func until() -> float:
		var t := 0.0
		for r: ReplayData in runs:
			t = maxf(t, r.duration())
		return t

	func progress_at(k: int, t: float) -> float:
		return progress[k][runs[k].index_at(t)]

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


## The card top left (the shot, the cars still driving), the clock's speed top right, and a strip
## along the bottom: the stage, each car where it is on it.
class Hud extends CanvasLayer:
	var card := PanelContainer.new()
	var title := Label.new()
	var sub := Label.new()
	var count := Label.new()
	var pill := PanelContainer.new()
	var speed := Label.new()
	var strip := Strip.new()

	func _init() -> void:
		layer = 10
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 2)
		card.add_theme_stylebox_override("panel", _paper(Color(UITheme.PAPER, 0.94)))
		card.add_child(box)
		title.label_settings = _text(UITheme.FONT_TITLE, 46, UITheme.INK)
		sub.label_settings = _text(UITheme.FONT_UI_BOLD, 26, UITheme.INK_SOFT)
		count.label_settings = _text(UITheme.FONT_UI_BLACK, 28, UITheme.SAKURA)
		for l: Label in [title, sub, count]:
			box.add_child(l)
		pill.add_theme_stylebox_override("panel", _paper(UITheme.SAKURA))
		speed.label_settings = _text(UITheme.FONT_TITLE, 34, UITheme.WHITE)
		pill.add_child(speed)
		for c: Control in [card, pill, strip]:
			c.visible = false
			add_child(c)

	func _paper(fill: Color) -> StyleBoxFlat:
		var s := StyleBoxFlat.new()
		s.bg_color = fill
		s.set_corner_radius_all(22)
		s.content_margin_left = 30
		s.content_margin_right = 30
		s.content_margin_top = 16
		s.content_margin_bottom = 18
		s.shadow_color = Color(UITheme.INK, 0.16)
		s.shadow_size = 10
		s.shadow_offset = Vector2(0, 5)
		return s

	func _text(font: Font, size: int, colour: Color) -> LabelSettings:
		var ls := LabelSettings.new()
		ls.font = font
		ls.font_size = size
		ls.font_color = colour
		return ls

	func show_shot(heading: String, caption: String, stage_m: float) -> void:
		var vp := get_viewport().get_visible_rect().size
		var s := vp.y / 1080.0
		title.text = heading
		sub.text = caption
		card.scale = Vector2(s, s)
		card.position = Vector2(56, 48) * s
		pill.scale = Vector2(s, s)
		strip.length = stage_m
		strip.position = Vector2(vp.x * 0.14, vp.y - 96.0 * s)
		strip.size = Vector2(vp.x * 0.72, 56.0 * s)
		card.visible = true
		strip.visible = true

	func hide_all() -> void:
		for c: Control in [card, pill, strip]:
			c.visible = false

	## The cars now: `driving` and `done` (finished) counts, the clock's speed, and every car's
	## distance and colour for the strip.
	func tick(driving: int, done: int, cars: int, clock: float, where: PackedFloat32Array, colours: PackedColorArray) -> void:
		count.text = "%d of %d still driving" % [driving, cars] if done == 0 \
				else "%d of %d finished · %d driving" % [done, cars, driving]
		pill.visible = clock > 1.25
		if pill.visible:
			speed.text = "×%d" % roundi(clock)
			var vp := get_viewport().get_visible_rect().size
			pill.position = Vector2(vp.x - (pill.size.x + 56.0) * pill.scale.x, 48.0 * pill.scale.y)
		strip.where = where
		strip.colours = colours
		strip.queue_redraw()


## The stage as a bar from start to finish, a dot for each car where it is.
class Strip extends Control:
	var length: float = 1.0
	var where := PackedFloat32Array()
	var colours := PackedColorArray()

	func _draw() -> void:
		var h := size.y
		var y := h * 0.5
		var r := h * 0.16
		var bar := StyleBoxFlat.new()
		bar.bg_color = Color(UITheme.PAPER, 0.9)
		bar.set_corner_radius_all(int(h * 0.2))
		bar.shadow_color = Color(UITheme.INK, 0.14)
		bar.shadow_size = 6
		draw_style_box(bar, Rect2(-h * 0.4, y - h * 0.2, size.x + h * 0.8, h * 0.4))
		draw_line(Vector2(0, y - h * 0.3), Vector2(0, y + h * 0.3), UITheme.INK, 3.0)
		draw_line(Vector2(size.x, y - h * 0.3), Vector2(size.x, y + h * 0.3), UITheme.INK, 3.0)
		# the ended cars first, the ones still going drawn over them
		for pass_live in 2:
			for k in where.size():
				var live := colours[k] != ENDED
				if live != (pass_live == 1):
					continue
				var x := clampf(where[k] / length, 0.0, 1.0) * size.x
				draw_circle(Vector2(x, y), r * 1.25, Color(UITheme.INK, 0.55))
				draw_circle(Vector2(x, y), r, colours[k])


## A drone behind and above the pack, looking down PITCH_DEG through a 55° lens: the cars still
## driving, from `back` to `front` (distances from the start line), fill the frame from near its
## bottom (the last car REAR heights ahead of the drone) to past its middle, the road ahead of them
## above. It flies high enough that the pack fits in FIT heights of road, between LOW and HIGH m;
## a pack longer than that is framed from its front. A little to one side (`side`) for depth.
class Drone:
	const PITCH_DEG := 50.0
	const LOW := 24.0
	const HIGH := 140.0
	const REAR := 0.3
	const FIT := 1.3
	var cam: Camera3D
	var track: Track
	var side: float = 1.0
	var height: float = 0.0

	func _init(camera: Camera3D, road: Track, from_side: float) -> void:
		cam = camera
		track = road
		side = from_side
		cam.fov = 55.0
		cam.near = 0.5
		cam.far = 4000.0

	func aim(front: float, back: float, snap: bool) -> void:
		var want := clampf((front - back) / FIT, LOW, HIGH)
		height = want if snap or height == 0.0 else lerpf(height, want, 1.0 - exp(-1.0 / (FPS * 0.8)))
		var rear := maxf(back, front - FIT * height)
		var s := track.start_s + rear - REAR * height
		var at := track.position_at_abs(s, 0.0)
		var look := track.position_at_abs(s + height / tan(deg_to_rad(PITCH_DEG)), 0.0)
		var dir := look - at
		dir.y = 0.0
		dir = dir.normalized()
		var right := Vector3(-dir.z, 0.0, dir.x)
		cam.global_position = at + right * height * 0.25 * side + Vector3.UP * (height + maxf(look.y - at.y, 0.0))
		cam.look_at(look, Vector3.UP)


## What the network sees, drawn over the road around `car`: the rays to the edge of the drivable
## road and the centre-line points ahead (DriveSense), nothing else. Drawn through everything,
## the car included, turned to the camera and one size on screen near and far. Colours as in
## cut_film.py's legend.
class SenseView extends MeshInstance3D:
	const RAY_COLOUR := Color(0.91, 0.32, 0.49, 0.85)
	const HIT_COLOUR := Color(0.91, 0.32, 0.49, 1.0)
	const ROAD_COLOUR := Color(0.25, 0.71, 0.54, 1.0)
	const LIFT := 0.5 # m above the car's origin
	## Half a ray's width and a mark's radius per metre from the camera (1080p, 55° FOV: rays
	## 6 px wide, marks 17 px).
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


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	DirAccess.make_dir_recursive_absolute(opts["footage"])
	var p: Variant = JSON.parse_string(FileAccess.get_file_as_string(str(opts["swarm"]).path_join("practice.json")))
	practice = p if typeof(p) == TYPE_DICTIONARY else {}
	root.close_requested.connect(func() -> void: print("WINDOW close requested at %.2f s" % _now()))
	_frame0 = Engine.get_process_frames()
	root.add_child(KeepDrawing.new())
	_run.call_deferred()


func _run() -> void:
	var gens: PackedStringArray = str(opts["gens"]).split(",", false) if str(opts["gens"]) != "" \
			else PackedStringArray(GENERATIONS)
	hud = Hud.new()
	root.add_child(hud)
	await _world(ROUTE)
	var track: Track = view.map.routes[ROUTE]["track"]
	for i in gens.size():
		var swarm := _load(ROUTE, gens[i])
		if swarm == null:
			return
		await _swarm_shot("gen_%d" % i, swarm, track, "Generation %d" % (i + 1), _practice_label(gens[i]),
				FIRST_HOLD_S if i == 0 else HOLD_S, LAP_S, 1.0 if i % 2 == 0 else -1.0)
	var shipped := _load(ROUTE, SHIPPED)
	if shipped == null:
		return
	await _sees_shot(shipped, track)
	await _world(HELD_OUT)
	var held := _load(HELD_OUT, SHIPPED)
	if held == null:
		return
	await _swarm_shot("held_out", held, view.map.routes[HELD_OUT]["track"], "Momiji Valley",
			"a road it never practised on", HOLD_S, HELD_OUT_S, 1.0)
	_cue("end")
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


## A generation's cars from the start line: the clock eased up, the drone over the pack, the card
## and the strip. `until`: the most playback seconds shown.
func _swarm_shot(tag: String, sw: Swarm, track: Track, heading: String, caption: String, hold: float,
		until: float, side: float) -> void:
	var n := sw.runs.size()
	var end := minf(sw.until(), until)
	var clock := clampf(end / SHOT_S, 1.0, MAX_SPEED)
	var ghosts: Array[ReplayGhost] = []
	var colours := PackedColorArray()
	for k in n:
		var g := ReplayGhost.spawn(view, sw.runs[k].header)
		var c := LIVERIES[k % LIVERIES.size()]
		g.car.set_livery(c, c.darkened(0.45))
		ghosts.append(g)
		colours.append(c)
	var live := colours.duplicate()
	var greyed := PackedByteArray()
	greyed.resize(n)
	var where := PackedFloat32Array()
	where.resize(n)
	var drone := Drone.new(view.camera, track, side)
	hud.show_shot(heading, caption, sw.length)
	_cue(tag, {"generation": sw.name, "steps": int(sw.info.get("steps", 0)), "run": str(sw.info.get("run", "")),
			"practice": caption, "cars": n, "clock": snappedf(clock, 0.01), "until": snappedf(end, 0.01)})
	var t := 0.0
	var tau := -hold
	var first := true
	var ending := 0.0
	var aim := Vector2.ZERO
	# share of the driving cars inside the frame, summed over the frames with any driving
	var framed := 0.0
	var framed_frames := 0
	while true:
		var driving := 0
		var done := 0
		var seen := 0
		for k in n:
			var data := sw.runs[k]
			ghosts[k].pose(data.car_at(t), minf(clock, 3.0) / FPS)
			where[k] = sw.progress_at(k, t)
			if t < sw.ends[k]:
				driving += 1
			elif sw.finished[k] == 1:
				done += 1
			elif greyed[k] == 0:
				greyed[k] = 1
				live[k] = ENDED
				ghosts[k].car.set_livery(ENDED, ENDED.darkened(0.35))
		var pack := _pack(sw, t, clock)
		if not is_nan(pack.x):
			aim = pack # nobody driving: the drone holds where it was
		drone.aim(aim.x, aim.y, first)
		first = false
		for k in n:
			if t < sw.ends[k] and view.camera.is_position_in_frustum(ghosts[k].car.global_position):
				seen += 1
		if driving > 0:
			framed += float(seen) / driving
			framed_frames += 1
		hud.tick(driving, done, n, clock if tau > 0.0 else 1.0, where, live)
		if t >= end:
			ending += 1.0 / FPS
			if ending >= END_HOLD_S:
				break
		await process_frame
		tau += 1.0 / FPS
		if tau > 0.0:
			t = minf(t + lerpf(1.0, clock, smoothstep(0.0, RAMP_S, tau)) / FPS, end)
	var finished := 0
	var furthest := 0.0
	for k in n:
		finished += sw.finished[k]
		furthest = maxf(furthest, where[k])
	_cue(tag + "_end", {"finished": finished, "furthest": snappedf(furthest, 0.1),
			"framed": snappedf(framed / maxi(framed_frames, 1), 0.01)})
	for g in ghosts:
		g.car.queue_free()


## Where the drone looks at playback time t: (front, back) of the cars still driving, each the
## mean over a window around t (a replay knows what comes next: no lag, and a car dropping out of
## the pack does not jolt the camera); NAN when nobody is driving. The window spans about 0.5 s
## on screen.
func _pack(sw: Swarm, t: float, clock: float) -> Vector2:
	var front := 0.0
	var back := 0.0
	var w := 0.25 * clock
	var samples := 0
	for j in range(-4, 5):
		var ts := maxf(t + w * j / 4.0, 0.0)
		var alive := PackedFloat32Array()
		for k in sw.runs.size():
			if ts < sw.ends[k]:
				alive.append(sw.progress_at(k, ts))
		if alive.is_empty():
			continue
		alive.sort()
		var n := alive.size()
		front += alive[n - 1] if n < 6 else alive[int(n * 0.9)]
		back += alive[0] if n < 6 else alive[int(n * 0.1)]
		samples += 1
	if samples == 0:
		return Vector2(NAN, NAN)
	return Vector2(front / samples, back / samples)


## The fastest run of `sw` at real speed from above and behind, with what its network sees drawn
## over the road; the other cars off.
func _sees_shot(sw: Swarm, track: Track) -> void:
	var k := sw.best()
	var data := sw.runs[k]
	var t0 := 0.0
	for i in data.count:
		if sw.progress[k][i] >= SEES_FROM:
			t0 = data.time(i)
			break
	var g := ReplayGhost.spawn(view, data.header)
	g.car.set_livery(UITheme.PAPER, UITheme.SAKURA)
	var eye := SenseView.new()
	eye.car = g.car
	eye.sense = DriveSense.new(track)
	view.add_child(eye)
	var cam := view.camera
	cam.fov = 55.0
	hud.hide_all()
	_cue("sees", {"generation": sw.name, "car": k, "from_m": SEES_FROM})
	var t := t0
	var pos := Vector3.ZERO
	var look := Vector3.ZERO
	while t < t0 + SEES_S:
		g.pose(data.car_at(t), 1.0 / FPS)
		var fwd := -g.car.global_basis.z
		fwd.y = 0.0
		fwd = fwd.normalized()
		var want := g.car.global_position - fwd * 13.0 + Vector3.UP * 8.5
		var ahead := g.car.global_position + fwd * 14.0
		pos = want if t == t0 else pos.lerp(want, 1.0 - exp(-1.0 / (FPS * 0.35)))
		look = ahead if t == t0 else look.lerp(ahead, 1.0 - exp(-1.0 / (FPS * 0.2)))
		cam.global_position = pos
		cam.look_at(look, Vector3.UP)
		await process_frame
		t += 1.0 / FPS
	_cue("sees_end")
	eye.queue_free()
	g.car.queue_free()


func _practice_label(gen: String) -> String:
	return str((practice.get(gen, {}) as Dictionary).get("label", ""))


func _now() -> float:
	return (Engine.get_process_frames() - _frame0) / FPS


func _cue(cue_name: String, extra: Dictionary = {}) -> void:
	var cue := {"name": cue_name, "t": snappedf(_now(), 0.001)}
	cue.merge(extra)
	cues.append(cue)
	print("CUE %8.3f %s %s" % [cue["t"], cue_name, JSON.stringify(extra) if not extra.is_empty() else ""])


func _fail(why: String) -> void:
	printerr("film: " + why)
	quit(3)
