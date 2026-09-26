extends SceneTree
## Replay round trip. The keyboard bot (tools/physics/keyboard_bot.gd) drives a timed lap of a
## real map through the real input path, set up and signalled the way Main runs a time trial
## (session_started, INTRO -> COUNTDOWN with its ticks -> RACING -> FINISHED -> MENU), while the
## Replays autoload records it into `<out>/replays/` (Replays.record_to). The file is then read
## back and summarised (tools/replay/analysis.gd), with the recording cost per physics tick and
## the file size per minute.
##
## With a renderer (--summer-offscreen) it also saves the live frame at each time in `at`
## (seconds of replay time), and after the lap, in the same run and on the same map, renders
## the replay at exactly those times through ReplayView (ghost car, recorded camera): live,
## replay and side-by-side pairs with their pixel difference in `<out>/`, all pairs in
## `<out>/pairs.png`.
##
##   S=/Applications/Summer.app/Contents/MacOS/Summer
##   timeout 900 nice -n 5 $S --summer-offscreen --audio-driver Dummy --fixed-fps 60 \
##       --disable-crash-handler --path . -s res://tools/replay/record_lap.gd -- \
##       map=hanami car=sakura at=15,40,70 dest=/tmp/ep3/replays/lap
##   timeout 600 nice -n 5 $S --headless --disable-crash-handler --path . \
##       -s res://tools/replay/record_lap.gd -- map=momiji   (recording and summary only)
##
## Prints CHECK lines and exits non-zero when one fails.

const MapLapRunner := preload("res://tools/physics/map_lap_runner.gd")
const KeyboardBot := preload("res://tools/physics/keyboard_bot.gd")
const Analysis := preload("res://tools/replay/analysis.gd")

var opts := {"map": "hanami", "car": "sakura", "dest": "/tmp/ep3/replays/lap", "at": "15,40,70", "limit": "240"}
var game: Node
var replays: Node
var failures: Array[String] = []


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	print("CHECK %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		failures.append(what)


func _run() -> void:
	game = root.get_node("Game")
	replays = root.get_node("Replays")
	var headless := DisplayServer.get_name() == "headless"
	var out := str(opts["dest"])
	var rep_dir := out.path_join("replays")
	DirAccess.make_dir_recursive_absolute(rep_dir)
	for f in DirAccess.get_files_at(rep_dir):
		DirAccess.remove_absolute(rep_dir.path_join(f))
	_check(not replays.enabled, "a tool run does not record until asked")
	replays.record_to(rep_dir)
	game.set_setting("car_id", opts["car"])
	game.set_setting("quality", "high")
	game.set_setting("camera", "chase")
	root.size = Vector2i(1600, 900)

	# ---- the drive, set up as Main sets up a time trial
	var map: MapWorld = await MapLapRunner.build_map(self, opts["map"])
	var post := PostFX.new()
	post.name = "PostFX"
	root.add_child(post)
	post.apply_preset(map.atmosphere.preset, map.sun_dir)
	Quality.apply("high", root, map)
	post.apply_quality("high")
	var car := (load(str(game.current_car()["scene"])) as PackedScene).instantiate() as Car
	car.name = "PlayerCar"
	car.controlled_by_player = true
	root.add_child(car)
	var colours: Dictionary = game.car_colors()
	car.set_livery(colours["primary"], colours["secondary"])
	car.place_at_rest(map.spawn)
	CarLook.apply(car)
	var chase := ChaseCamera.new()
	chase.name = "ChaseCamera"
	root.add_child(chase)
	chase.target = car
	chase.make_current()
	chase.snap()
	var session := RaceSession.new()
	session.name = "Session"
	root.add_child(session)
	session.setup(map, car, game.MODE_TIME_TRIAL)
	session.reset_needed.connect(func(_reason: String) -> void: car.reset_to_track())
	var done := [false]
	session.finished.connect(func(_r: Dictionary) -> void: done[0] = true)
	game.player_car = car
	game.session = session
	car.launch_hold = true
	game.notify_session_started(opts["map"], game.MODE_TIME_TRIAL)
	game.set_state(game.State.INTRO)
	await physics_frame
	var captures: Array[Dictionary] = []
	var wanted: Array[float] = []
	if not headless:
		for a in str(opts["at"]).split(","):
			wanted.append(float(a))
	game.set_state(game.State.COUNTDOWN)
	_check(replays.is_recording(), "recording opens on COUNTDOWN")
	var bot := KeyboardBot.new()
	bot.curve = map.track.to_curve()
	car.add_child(bot)
	for v in [3, 2, 1]:
		game.notify_countdown(v)
		await _drive(1.0, post, car, wanted, captures)
	game.notify_countdown(0)
	car.launch_hold = false
	session.start_timer()
	game.set_state(game.State.RACING)
	game.notify_race_started()
	var limit := float(opts["limit"])
	var t := 0.0
	while not done[0] and t < limit:
		t += await _drive(0.0, post, car, wanted, captures)
	_check(done[0], "the bot finished the lap (%.1f s)" % session.elapsed)
	game.set_state(game.State.FINISHED)
	car.remove_child(bot)
	bot.free()
	# As Main does after the line: the autopilot cruises on.
	car.controlled_by_player = false
	var cruise := Autopilot.new()
	cruise.curve = map.track.to_curve()
	cruise.speed_scale = 0.5
	cruise.max_speed_kmh = 75.0
	car.add_child(cruise)
	await _drive(1.5, post, car, wanted, captures)
	_check(replays.is_recording(), "the FINISHED tail is recorded")
	game.set_state(game.State.MENU)
	_check(not replays.is_recording(), "recording closes on MENU")
	replays.flush()

	# ---- the file
	var files := DirAccess.get_files_at(rep_dir)
	_check(files.size() == 1, "one replay file in %s (%d)" % [rep_dir, files.size()])
	var path: String = replays.last_path
	var data := ReplayData.load_file(path)
	_check(data.error == "" and data.complete, "the replay reads back complete (%s)" % data.error)
	var bytes := FileAccess.get_file_as_bytes(path).size()
	var st: Dictionary = replays.stats
	print("FILE %s  %d bytes  %.1f s  %d frames  %d events  raw %d bytes" % [path, bytes, data.duration(),
			data.count, data.events.size(), int(st.get("bytes_raw", 0))])
	print("SIZE %.1f KB per minute (raw %.1f KB per minute)" % [bytes / 1024.0 / (data.duration() / 60.0),
			float(st.get("bytes_raw", 0)) / 1024.0 / (data.duration() / 60.0)])
	print("COST recording %.1f us per physics tick (mean over %d ticks), %d ticks over 1 ms, max %d us at t=%.2f s" % [
			float(st.get("mean_us", 0.0)), int(st.get("ticks", 0)), int(st.get("over_1ms", 0)), int(st.get("max_us", 0)),
			float(st.get("max_at", 0.0))])
	var summary := Analysis.analyze(data, map.track)
	print(Analysis.report(summary))
	var types := {}
	for e in data.events:
		types[e["type"]] = int(types.get(e["type"], 0)) + 1
	print("EVENTS ", types)
	for need in ["state", "countdown", "start", "checkpoint", "finish", "camera", "surface", "end"]:
		_check(types.has(need), "event '%s' recorded" % need)
	_check(absf(float(summary["result"].get("time", 0.0)) - session.elapsed) < 0.01, "finish time in the replay matches the session")
	var last := data.frame(data.count - 1)
	_check(data.pos(data.count - 1).distance_to(car.global_position) < 5.0, "last frame is where the car is")
	_check(str(last["state"]) == "FINISHED", "last frame in the FINISHED tail")

	# ---- live frames against the replay rendered at the same times
	if not captures.is_empty():
		for n in [car, chase, post, session]:
			n.queue_free()
		game.player_car = null
		game.session = null
		await process_frame
		var view := ReplayView.new()
		view.name = "ReplayView"
		root.add_child(view)
		await view.setup(data, map)
		var sheet_rows: Array[Image] = []
		for k in captures.size():
			var cap: Dictionary = captures[k]
			var ct: float = cap["t"]
			for w in 40:
				await process_frame
				view.show_at(ct - (40 - w) / 60.0)
			await process_frame
			view.show_at(ct)
			await RenderingServer.frame_post_draw
			var img := root.get_texture().get_image()
			var live: Image = cap["image"]
			live.save_png(out.path_join("live_%d.png" % k))
			img.save_png(out.path_join("replay_%d.png" % k))
			var diff := _diff(live, img)
			var pair := _pair(live, img)
			pair.save_png(out.path_join("pair_%d.png" % k))
			sheet_rows.append(pair)
			print("PAIR %d t=%.3f s  mean abs diff %.1f/255  pixels off by >32: %.1f%%  -> %s" % [k, ct, diff.x, diff.y * 100.0,
					out.path_join("pair_%d.png" % k)])
			_check(diff.x < 20.0, "replay frame %d matches the live frame" % k)
		_stack(sheet_rows).save_png(out.path_join("pairs.png"))
		print("SHEET ", out.path_join("pairs.png"))
	print("RESULT %s (%d failures)" % ["PASS" if failures.is_empty() else "FAIL", failures.size()])
	for f in failures:
		print("  FAILED ", f)
	game.request_quit(0 if failures.is_empty() else 1)


## Runs `seconds` of game time (at least one frame), mirroring Main's per-frame screen passes,
## and grabs a live frame whenever replay time passes the next wanted capture time. Returns the
## game time that passed.
func _drive(seconds: float, post: PostFX, car: Car, wanted: Array[float], captures: Array[Dictionary]) -> float:
	var passed := 0.0
	while true:
		await process_frame
		var dt := root.get_process_delta_time()
		passed += dt
		post.speed_target = smoothstep(115.0, 175.0, car.speed_kmh) * 0.8 if game.state == game.State.RACING else 0.0
		if not wanted.is_empty() and float(replays.frame_time()) >= wanted[0]:
			wanted.pop_front()
			await RenderingServer.frame_post_draw
			captures.append({"t": float(replays.frame_time()), "image": root.get_texture().get_image()})
			print("LIVE capture at t=%.3f s (%d km/h)" % [captures[-1]["t"], roundi(car.speed_kmh)])
		if passed >= seconds:
			return passed
	return passed


## (mean absolute difference 0..255, share of pixels off by more than 32), at 320 x 180.
static func _diff(a: Image, b: Image) -> Vector2:
	var x := a.duplicate() as Image
	var y := b.duplicate() as Image
	x.convert(Image.FORMAT_RGB8)
	y.convert(Image.FORMAT_RGB8)
	x.resize(320, 180, Image.INTERPOLATE_BILINEAR)
	y.resize(320, 180, Image.INTERPOLATE_BILINEAR)
	var da := x.get_data()
	var db := y.get_data()
	var total := 0
	var off := 0
	for i in range(0, da.size(), 3):
		var d := maxi(maxi(absi(da[i] - db[i]), absi(da[i + 1] - db[i + 1])), absi(da[i + 2] - db[i + 2]))
		total += absi(da[i] - db[i]) + absi(da[i + 1] - db[i + 1]) + absi(da[i + 2] - db[i + 2])
		if d > 32:
			off += 1
	return Vector2(total / float(da.size()), off / float(da.size() / 3))


## Live (left) and replay (right) at half size, side by side.
static func _pair(a: Image, b: Image) -> Image:
	var w := a.get_width() / 2
	var h := a.get_height() / 2
	var out := Image.create(w * 2 + 8, h, false, Image.FORMAT_RGB8)
	out.fill(Color.WHITE)
	for k in 2:
		var src := (a if k == 0 else b).duplicate() as Image
		src.convert(Image.FORMAT_RGB8)
		src.resize(w, h, Image.INTERPOLATE_BILINEAR)
		out.blit_rect(src, Rect2i(0, 0, w, h), Vector2i(k * (w + 8), 0))
	return out


static func _stack(rows: Array[Image]) -> Image:
	var w := rows[0].get_width()
	var h := rows[0].get_height()
	var out := Image.create(w, (h + 8) * rows.size(), false, Image.FORMAT_RGB8)
	out.fill(Color.WHITE)
	for k in rows.size():
		out.blit_rect(rows[k], Rect2i(0, 0, w, h), Vector2i(0, k * (h + 8)))
	return out
