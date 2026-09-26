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
## map: hanami | momiji. mode: time_trial | free_roam (free roam drives `lap_s` seconds) |
## campaign (a fresh campaign from the title in one continuous drive: SS1, results Continue,
## the gate opening, the liaison, the arrival on Momiji's grid, SS2's start card and countdown
## on the spot, SS2, the finale and its end card, back to the title; every leg is driven by the
## autopilot, `map` is ignored, FPS is reported per leg).
## speed: Engine.time_scale while the autopilot drives (the flow itself runs in real time).
## record=1: capture the end of the Master bus to <out>/playthrough.wav with
## <out>/playthrough_events.json (states, gears, surfaces, checkpoints) for
## tools/audio/render_test.py, and <out>/playthrough_trace.json: 20 Hz rows of
## [t, throttle, brake, gear, rpm, km/h, lateral m/s^2, forward m/s^2] for gearbox tuning.
## Use with speed=1 shots=0 and --audio-driver Dummy (mixes silently in real time).

var opts := {"map": "hanami", "mode": "time_trial", "out": "/tmp/playthrough", "speed": "2", "shots": "8", "lap_s": "40", "record": ""}
var main: Node
var game: Node
var t0 := 0
var fps_samples: Array[float] = []
## How many times each state was entered, and the counts at the last _mark().
var reached: Dictionary = {}
var marked: Dictionary = {}
var _record: AudioEffectRecord
var _events: Array[Dictionary] = []
var _rec_t0 := 0
var _last_gear := -99
var _last_surface: StringName = &""
var _watched: Car
var _trace: Array[PackedFloat32Array] = []
var _trace_next := 0.0


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
		_log("STATE %s" % (game.State as Dictionary).find_key(s))
		_event(str((game.State as Dictionary).find_key(s)).to_lower()))
	game.race_finished.connect(func(r: Dictionary) -> void:
		_log("FINISHED time=%.3f medal=%s record=%s top=%.0f" % [r["time"], r["medal"], r["is_record"], r.get("top_speed_kmh", 0.0)]))
	game.checkpoint_passed.connect(func(i: int, n: int, t: float, _d: float) -> void:
		_log("CHECKPOINT %d/%d %.2f" % [i + 1, n, t])
		_event("cp%d" % (i + 1)))
	game.notice.connect(func(text: String) -> void: _log("NOTICE %s" % text))
	t0 = Time.get_ticks_msec()
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func _run() -> void:
	# Here, not in _initialize: Sound only builds the Master compressor/limiter on an
	# empty Master bus, so the recorder must be appended after the autoloads are ready.
	if opts["record"] != "":
		_record = AudioEffectRecord.new()
		AudioServer.add_bus_effect(0, _record, -1) # after the Master limiter: what the player hears
		_record.set_recording_active(true)
		_rec_t0 = Time.get_ticks_msec()
		physics_frame.connect(_watch_car)
	await _until_state(&"MENU", 60.0)
	_log("title up")
	await _seconds(3.0)
	await _shot("title_a")
	await _seconds(5.0)
	await _shot("title_b")
	_mark()
	if opts["mode"] == "campaign":
		await _run_campaign()
		return
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
	_drive(car)
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
	_log_fps("drive")
	_log("PLAYTHROUGH DONE")
	_save_recording()
	game.request_quit()


func _run_campaign() -> void:
	var ui: CanvasLayer = main.ui
	game.request_campaign(true)
	for li in game.CAMPAIGN.size():
		var leg: Dictionary = game.CAMPAIGN[li]
		var driving: int
		if leg["kind"] == "stage":
			await _until_state(&"INTRO", 60.0)
			await _seconds(1.6)
			await _shot("intro_%d" % li)
			await _until_state(&"RACING", 30.0)
			driving = game.State.RACING
		else:
			# Results Continue: the gate opens over the resting car, then the drive on.
			await _seconds(1.4)
			await _shot("gate_%d" % li)
			await _until_state(&"LIAISON", 30.0)
			driving = game.State.LIAISON
			await _seconds(1.5)
			await _shot("liaison_%d" % li)
		var car: Car = game.player_car
		_drive(car)
		Engine.time_scale = float(opts["speed"])
		fps_samples.clear()
		while game.state == driving:
			await process_frame
			fps_samples.append(Engine.get_frames_per_second())
		Engine.time_scale = 1.0
		_log_fps(str(leg["code"]))
		_mark()
		if leg["kind"] == "stage":
			await _seconds(5.5)
			await _shot("results_%d" % li)
			ui.results._continue.pressed.emit()
		else:
			await _seconds(1.5)
			await _shot("arrival_%d" % li)
	await _until_state(&"FINALE", 60.0)
	await _seconds(5.5)
	await _shot("finale_board")
	ui.finale._continue.pressed.emit()
	await _seconds(4.5)
	await _shot("finale_end")
	_mark()
	ui.finale._back.pressed.emit()
	await _until_state(&"MENU", 60.0)
	await _seconds(2.5)
	await _shot("title_finished")
	_log("PLAYTHROUGH DONE")
	_save_recording()
	game.request_quit()


## The autopilot takes the player car (Main drops it at the liaison's arrival and the finish).
func _drive(car: Car) -> void:
	car.controlled_by_player = false
	var ap := Autopilot.new()
	ap.curve = main.drive_curve()
	ap.closed = main.map.track.closed
	car.add_child(ap)
	main.autopilot = ap


func _log_fps(what: String) -> void:
	fps_samples.sort()
	var n := fps_samples.size()
	if n > 0:
		_log("FPS %s: min=%.0f p10=%.0f median=%.0f" % [what, fps_samples[0], fps_samples[n / 10], fps_samples[n / 2]])


## Gear and rear-wheel surface changes of the player car plus its one-shot events
## (backfire, impact, landing), for the spectrogram marks.
func _watch_car() -> void:
	var car: Car = game.player_car
	if car == null or not is_instance_valid(car):
		_last_gear = -99
		return
	if car != _watched:
		_watched = car
		car.backfire.connect(_event.bind("bf"))
		car.impact.connect(func(s: float, _p: Vector3) -> void: _event("hit%.1f" % s))
		car.landed.connect(func(s: float) -> void: _event("land%.1f" % s))
	if car.gear != _last_gear:
		_last_gear = car.gear
		_event("g%d" % car.gear)
	var t := (Time.get_ticks_msec() - _rec_t0) / 1000.0
	if t >= _trace_next:
		_trace_next = t + 0.05
		var v := car.linear_velocity
		var fwd := -car.global_basis.z
		_trace.append(PackedFloat32Array([snappedf(t, 0.001), car.input_throttle, car.input_brake, car.gear,
				car.drivetrain.rpm, v.dot(fwd) * 3.6, car.angular_velocity.y * v.length(), car.drivetrain._accel]))
	var s: StringName = car.wheels[2].surface if car.wheels[2].contact else &"air"
	if s != _last_surface:
		_last_surface = s
		_event(str(s))


func _event(label: String) -> void:
	if _record != null:
		_events.append({"t": snappedf((Time.get_ticks_msec() - _rec_t0) / 1000.0, 0.001), "label": label})


func _save_recording() -> void:
	if _record == null:
		return
	_event("end")
	_record.set_recording_active(false)
	var wav := _record.get_recording()
	var path := "%s/playthrough.wav" % opts["out"]
	wav.save_to_wav(path)
	var f := FileAccess.open("%s/playthrough_events.json" % opts["out"], FileAccess.WRITE)
	f.store_string(JSON.stringify(_events))
	f.close()
	f = FileAccess.open("%s/playthrough_trace.json" % opts["out"], FileAccess.WRITE)
	f.store_string(JSON.stringify(_trace))
	f.close()
	_log("RECORDING %s (%.1f s, %d events)" % [path, wav.get_length(), _events.size()])


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
