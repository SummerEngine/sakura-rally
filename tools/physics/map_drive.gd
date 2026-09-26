extends SceneTree
## One timed run of a route of the world by the keyboard bot or the analog autopilot, for tuning,
## for checking the chase camera and for frame rates. Headless it prints the run metrics;
## rendered (offscreen) it draws through a ChaseCamera with the ink and grade and saves frames
## whenever the car slides, or every `every` seconds.
##
##   S=/Applications/Summer.app/Contents/MacOS/Summer
##   timeout 600 $S --disable-crash-handler --summer-offscreen --audio-driver Dummy --fixed-fps 60 --path . \
##       -s res://tools/physics/map_drive.gd -- route=hanami car=sakura bot=keyboard out=/tmp/map_drive shots=8
##
## route: hanami | momiji | liaison. car: an id of Game.CARS. bot: keyboard | analog.
## ap.<property>=<float> overrides a driver export for tuning (e.g. ap.corner_grip=0.8).
## Rendered runs save <out>/<route>_<car>_<bot>_NN.png: a frame when the body slip first passes
## slide_deg, then at most every 1.5 s, `shots` frames in total; with every=<s>, a frame every
## s seconds of the run instead (a contact sheet along the route).
## quality=low|medium|high applies that preset and prints the frame rate (median, p10) over the
## run and per tenth of the route (run without --fixed-fps).

const MapLapRunner := preload("res://tools/physics/map_lap_runner.gd")

const PostFXScript := preload("res://scripts/fx/post_fx.gd")

var opts := {"route": "hanami", "car": "sakura", "bot": "keyboard", "out": "/tmp/map_drive", "slide_deg": "10",
		"shots": "8", "every": "0", "quality": ""}
var map: MapWorld
var _shots_left := 0
var _next_shot := 0.0
var _pending_shot := ""
var _progress := 0.0
var _frame_usec := 0
var _fps: Array[PackedFloat32Array] = []


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	_run.call_deferred()


func _run() -> void:
	var game := root.get_node("Game")
	var headless := DisplayServer.get_name() == "headless"
	map = await MapLapRunner.build_map(self, opts["route"])
	print("WORLD built in %d ms (pack %d ms) stats=%s" % [map.stats["build_ms"], map.stats["pack_ms"], map.stats])
	var car := (load(str(game.get_car(opts["car"])["scene"])) as PackedScene).instantiate() as Car
	root.add_child(car)
	var runner := MapLapRunner.new()
	for key in opts:
		if str(key).begins_with("ap."):
			runner.driver_props[str(key).substr(3)] = float(opts[key])
	if not headless:
		root.size = Vector2i(1600, 900)
		DirAccess.make_dir_recursive_absolute(opts["out"])
		CarLook.apply(car)
		var cam := ChaseCamera.new()
		cam.player_camera = false
		cam.target = car
		root.add_child(cam)
		cam.make_current()
		root.add_child(PostFXScript.new())
		_shots_left = int(opts["shots"])
		runner.on_tick = _watch
		if opts["quality"] != "":
			Quality.apply(opts["quality"], root, map)
			for i in 10:
				_fps.append(PackedFloat32Array())
			process_frame.connect(_count_frame)
	await physics_frame
	var r: Dictionary = await runner.lap(self, map, car, opts["bot"] == "keyboard")
	print("LAP route=%s car=%s bot=%s finished=%s time=%.2f resets=%d impacts=%d hard=%d max_impact=%.2f max_slip=%.1f top=%.0f off=%.1fs/%.1fm" % [
			opts["route"], opts["car"], opts["bot"], r["finished"], r["time"], r["resets"], r["impacts"],
			r["hard_impacts"], r["max_impact"], r["max_slip_deg"], r["top_kmh"], r["off_road_s"], r["max_off_m"]])
	if not _fps.is_empty():
		_print_fps()
	game.request_quit()


func _watch(car: Car, elapsed: float) -> void:
	var t := map.track
	_progress = clampf(t.progress_of(t.nearest(car.global_position), car.global_position) / t.length, 0.0, 0.999)
	if _pending_shot != "" or elapsed < _next_shot:
		return
	var every := float(opts["every"])
	if every > 0.0:
		_next_shot = elapsed + every
		_pending_shot = "%s/%s_%s_%s_%03d.png" % [opts["out"], opts["route"], opts["car"], opts["bot"], int(elapsed / every)]
		var w := map.season_weights
		print("SHOT t=%.1f progress=%.3f season=(%.2f %.2f %.2f) -> %s" % [elapsed, _progress, w.x, w.y, w.z, _pending_shot])
		_save_shot.call_deferred()
		return
	if _shots_left <= 0 or rad_to_deg(absf(car.body_slip)) < float(opts["slide_deg"]) or car.speed_kmh < 30.0:
		return
	_next_shot = elapsed + 1.5
	_shots_left -= 1
	_pending_shot = "%s/%s_%s_%s_%02d.png" % [opts["out"], opts["route"], opts["car"], opts["bot"], int(opts["shots"]) - _shots_left]
	print("SLIDE t=%.2f slip=%.1f kmh=%.0f -> %s" % [elapsed, rad_to_deg(car.body_slip), car.speed_kmh, _pending_shot])
	_save_shot.call_deferred()


func _count_frame() -> void:
	var now := Time.get_ticks_usec()
	if _frame_usec > 0 and _pending_shot == "":
		_fps[int(_progress * 10.0)].append(1e6 / maxf(now - _frame_usec, 1.0))
	_frame_usec = now


func _print_fps() -> void:
	var all := PackedFloat32Array()
	var along := []
	for k in _fps.size():
		var b := _fps[k]
		all.append_array(b)
		b.sort()
		along.append("%d%%: %.0f" % [k * 10, b[b.size() / 2]] if b.size() > 0 else "%d%%: -" % (k * 10))
	all.sort()
	print("FPS route=%s quality=%s median=%.0f p10=%.0f frames=%d" % [opts["route"], opts["quality"],
			all[all.size() / 2], all[all.size() / 10], all.size()])
	print("FPS along %s: %s" % [opts["route"], ", ".join(along)])


func _save_shot() -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(_pending_shot)
	_pending_shot = ""
