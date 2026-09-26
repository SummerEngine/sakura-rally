extends SceneTree
## Plays the real game end to end: boots Main, waits on the title, starts a map, revs
## through the countdown, lets the autopilot drive the player car to the finish, waits
## on the results, then returns to the title. Logs every state change with timings and
## FPS, and saves frames at the key moments.
##
##   S=/Applications/Summer.app/Contents/MacOS/Summer
##   timeout 600 $S --disable-crash-handler --path . -s res://tools/game/playthrough.gd -- \
##       map=hanami mode=time_trial out=/tmp/playthrough speed=2 shots=8
##
## map: hanami | momiji. mode: time_trial | free_roam (free roam drives `lap_s` seconds).
## speed: Engine.time_scale while the autopilot drives (the flow itself runs in real time).

var opts := {"map": "hanami", "mode": "time_trial", "out": "/tmp/playthrough", "speed": "2", "shots": "8", "lap_s": "40"}
var main: Node
var game: Node
var t0 := 0
var fps_samples: Array[float] = []
## How many times each state was entered, and the counts at the last _mark().
var reached: Dictionary = {}
var marked: Dictionary = {}


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	DirAccess.make_dir_recursive_absolute(opts["out"])
	root.size = Vector2i(1920, 1080)
	game = root.get_node("Game")
	game.state_changed.connect(func(s: int, _o: int) -> void:
		reached[s] = int(reached.get(s, 0)) + 1
		_log("STATE %s" % (game.State as Dictionary).find_key(s)))
	game.race_finished.connect(func(r: Dictionary) -> void:
		_log("FINISHED time=%.3f medal=%s record=%s top=%.0f" % [r["time"], r["medal"], r["is_record"], r.get("top_speed_kmh", 0.0)]))
	game.checkpoint_passed.connect(func(i: int, n: int, t: float, _d: float) -> void:
		_log("CHECKPOINT %d/%d %.2f" % [i + 1, n, t]))
	game.notice.connect(func(text: String) -> void: _log("NOTICE %s" % text))
	t0 = Time.get_ticks_msec()
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func _run() -> void:
	await _until_state(&"MENU", 60.0)
	_log("title up")
	await _seconds(3.0)
	await _shot("title_a")
	await _seconds(5.0)
	await _shot("title_b")
	_mark()
	game.request_start(opts["map"], opts["mode"])
	await _until_state(&"LOADING", 10.0)
	await _seconds(0.3)
	await _shot("loading")
	await _until_state(&"INTRO", 60.0)
	await _seconds(0.6)
	await _shot("intro_a")
	await _seconds(1.4)
	await _shot("intro_b")
	var car: Car = game.player_car
	if opts["mode"] == "time_trial":
		await _until_state(&"COUNTDOWN", 10.0)
		# rev on the line: throttle while the car is held
		Input.action_press(&"throttle", 0.75)
		await _seconds(1.2)
		_log("countdown rpm=%.0f gear=%d speed=%.2f" % [car.rpm, car.gear, car.speed_kmh])
		await _shot("countdown")
		await _until_state(&"RACING", 10.0)
		Input.action_press(&"throttle", 1.0)
		await _seconds(1.0)
		_log("launch speed=%.1f gear=%d" % [car.speed_kmh, car.gear])
		await _shot("launch")
		Input.action_release(&"throttle")
	else:
		await _until_state(&"FREE_ROAM", 20.0)
	# autopilot takes the player car
	car.controlled_by_player = false
	var ap := Autopilot.new()
	ap.curve = main.map.track.to_curve()
	car.add_child(ap)
	Engine.time_scale = float(opts["speed"])
	var shots := int(opts["shots"])
	var shot_every := 150.0 / shots
	var next_shot := shot_every
	var drive_t := 0.0
	var limit := 400.0 if opts["mode"] == "time_trial" else float(opts["lap_s"])
	while drive_t < limit:
		await process_frame
		drive_t += root.get_process_delta_time()
		fps_samples.append(Engine.get_frames_per_second())
		if opts["mode"] == "time_trial" and game.state != game.State.RACING:
			break
		if drive_t > next_shot:
			next_shot += shot_every
			var ts := Engine.time_scale
			Engine.time_scale = 0.0001
			await _shot("drive_%03d" % int(drive_t))
			Engine.time_scale = ts
	Engine.time_scale = 1.0
	if opts["mode"] == "time_trial":
		await _until_state(&"FINISHED", 30.0)
		await _seconds(0.25)
		await _shot("finish_a")
		await _seconds(1.5)
		await _shot("finish_b")
		await _seconds(3.5)
		await _shot("results")
	else:
		await _shot("free_roam_end")
	_mark()
	game.request_menu()
	await _until_state(&"MENU", 60.0)
	await _seconds(2.5)
	await _shot("title_return")
	fps_samples.sort()
	var n := fps_samples.size()
	if n > 0:
		_log("FPS drive: min=%.0f p10=%.0f median=%.0f" % [fps_samples[0], fps_samples[n / 10], fps_samples[n / 2]])
	_log("PLAYTHROUGH DONE")
	quit()


func _log(msg: String) -> void:
	print("[%7.2f] %s" % [(Time.get_ticks_msec() - t0) / 1000.0, msg])


func _seconds(s: float) -> void:
	await create_timer(s, true, false, true).timeout


## Snapshot the entry counts; _until_state then waits for an entry after this point,
## even one that happened (and passed) between two frames.
func _mark() -> void:
	marked = reached.duplicate()


func _until_state(state_name: StringName, timeout: float) -> void:
	var s: int = game.State[state_name]
	var start := Time.get_ticks_msec()
	while int(reached.get(s, 0)) <= int(marked.get(s, 0)):
		if (Time.get_ticks_msec() - start) / 1000.0 > timeout:
			_log("TIMEOUT waiting for %s (state=%s)" % [state_name, (game.State as Dictionary).find_key(game.state)])
			return
		await process_frame


func _shot(name_: String) -> void:
	await RenderingServer.frame_post_draw
	var path := "%s/%s.png" % [opts["out"], name_]
	root.get_texture().get_image().save_png(path)
	_log("SHOT %s fps=%d" % [path, Engine.get_frames_per_second()])
