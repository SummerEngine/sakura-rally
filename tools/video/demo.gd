extends SceneTree
## Demo reel footage, rendered offline by Movie Maker: run tools/video/render_demo.sh, not this
## script directly (cue times count Movie Maker frames at 60 fps). The real game, driven by real
## key / pad presses and the autopilot:
##   title -> Enter on Hanami -> intro swoop, countdown with throttle blips, launch under the
##   chase camera with the HUD -> the lap under directed cinematic cuts (HUD hidden), slow motion
##   through the gravel esses -> chase camera + HUD over the last bridge to the finish -> results
##   card -> Next map -> Momiji at golden hour, slow motion through the gravel hairpin -> pause ->
##   Main menu -> the title over Momiji.
## Music is muted here: cut_demo.py lays one continuous track under the edit. Cues (video
## seconds + lap progress) go to <out>/cues.json.

const SLOWMO := 0.3

## Directed cuts per map: [lap progress (m) to cut at, shot, side (+1 right), lap progress of the
## roadside / scenic anchor or NAN, slow motion through the anchor]. Corners were measured from
## the track (heading change over 30 m); on a bend CineCamera puts the roadside camera on the
## inside (the outside carries the marker posts), so those sides are listed as the inside.
const CUTS := {
	"hanami": [
		[150.0, "tracking", 1.0, NAN, false],
		[330.0, "wheel", -1.0, NAN, false],
		[450.0, "front", 1.0, NAN, false],
		[560.0, "roadside", -1.0, 680.8, false], # tarmac left-hander
		[720.0, "drone", 1.0, NAN, false],
		[850.0, "roadside", 1.0, 960.8, false], # tightest corner, right-hander
		[1000.0, "tracking", -1.0, NAN, false],
		[1120.0, "scenic", 1.0, 1240.9, false],
		[1300.0, "wheel", 1.0, NAN, false],
		[1450.0, "front", -1.0, NAN, false],
		[1620.0, "scenic", -1.0, 1748.0, false], # the river bridge
		[1880.0, "tracking", 1.0, NAN, false], # onto gravel
		[2050.0, "wheel", -1.0, NAN, false],
		[2200.0, "front", 1.0, NAN, false],
		[2290.0, "roadside", 1.0, 2380.9, true], # gravel esses, right-hander
		[2480.0, "scenic", 1.0, 2612.9, false],
	],
	"momiji": [
		[120.0, "drone", 1.0, NAN, false],
		[330.0, "tracking", -1.0, NAN, false],
		[480.0, "wheel", 1.0, NAN, false],
		[620.0, "scenic", -1.0, 762.0, false], # the bridge
		[840.0, "tracking", 1.0, NAN, false], # onto gravel
		[990.0, "roadside", 1.0, 1087.9, true], # gravel hairpin, right-hander
		[1140.0, "front", 1.0, NAN, false],
		[1280.0, "roadside", -1.0, 1381.8, false], # gravel hairpin, left-hander
		[1420.0, "wheel", -1.0, NAN, false],
		[1560.0, "drone", -1.0, NAN, false],
	],
}
## Lap progress where the chase camera and HUD come back on Momiji (before the pause).
const MOMIJI_END := 1760.0

var opts := {"out": "/tmp/sakura_demo"}
var main: Node
var game: Node
var reached: Dictionary = {}
var marked: Dictionary = {}
var cues: Array[Dictionary] = []
var _frame0 := 0


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	DirAccess.make_dir_recursive_absolute(opts["out"])
	game = root.get_node("Game")
	game.set_setting("music_volume", 0.0) # a -s harness never saves settings (Game.persistent)
	game.state_changed.connect(func(s: int, _o: int) -> void:
		reached[s] = int(reached.get(s, 0)) + 1
		_cue("%s_%d" % [str((game.State as Dictionary).find_key(s)).to_lower(), reached[s]]))
	_frame0 = Engine.get_frames_drawn()
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func _run() -> void:
	await _until_state(&"MENU", 60.0)
	await _seconds(7.0) # the title animates in over the flyover
	_mark()
	await _key(KEY_ENTER) # the Hanami card has focus

	var car := await _race_start()
	await _montage(car, "hanami")
	await _until_progress(car, main.map.track.length - 160.0)
	_chase(car)
	_cue("hanami_last_bridge", car)
	_mark()
	await _until_state(&"FINISHED", 60.0)
	await _seconds(8.5) # finish slam, slow-motion orbit, results count-up and medal stamp
	await _pad(JOY_BUTTON_DPAD_RIGHT)
	await _seconds(0.6)
	_mark()
	await _pad(JOY_BUTTON_A) # Next map

	car = await _race_start()
	await _montage(car, "momiji")
	await _until_progress(car, MOMIJI_END)
	_chase(car)
	_cue("momiji_chase", car)
	await _seconds(4.0)
	await _key(KEY_ESCAPE)
	await _seconds(1.4)
	for i in 3: # Resume -> Restart -> Settings -> Main menu
		await _pad(JOY_BUTTON_DPAD_DOWN)
		await _seconds(0.3)
	_mark()
	await _pad(JOY_BUTTON_A)
	await _until_state(&"MENU", 60.0)
	await _seconds(9.0)
	_cue("end")
	var f := FileAccess.open("%s/cues.json" % opts["out"], FileAccess.WRITE)
	f.store_string(JSON.stringify(cues, "  "))
	f.close()
	game.request_quit()


## From the start request to one second after GO: throttle blips on the line (each lift pops),
## held revs into GO, a full-throttle launch, then the autopilot takes the car.
func _race_start() -> Car:
	await _until_state(&"COUNTDOWN", 60.0)
	_mark()
	await _seconds(0.4)
	await _blip(0.28)
	await _seconds(0.45)
	await _blip(0.34)
	await _seconds(0.3)
	Input.action_press(&"throttle", 0.8)
	await _until_state(&"RACING", 10.0)
	Input.action_press(&"throttle", 1.0)
	await _seconds(1.0)
	Input.action_release(&"throttle")
	var car: Car = game.player_car
	car.controlled_by_player = false
	var ap := Autopilot.new()
	ap.curve = main.map.track.to_curve()
	car.add_child(ap)
	return car


func _montage(car: Car, map_id: String) -> void:
	var track: Track = main.map.track
	var cuts: Array = CUTS[map_id]
	for i in cuts.size():
		var c: Array = cuts[i]
		await _until_progress(car, c[0])
		if i == 0:
			main.ui.set_ui_visible(false)
		var anchor: float = c[3]
		main.cine.cut_to(car, track, c[1], c[2], NAN if is_nan(anchor) else track.start_s + anchor)
		var tag := "%s_%02d" % [map_id, i]
		_cue("%s_%s" % [tag, c[1]], car)
		if not is_nan(anchor):
			_watch_pass(car, tag, anchor, c[4])


## Cues the moment the car passes a roadside / scenic anchor; optionally slows time around it.
func _watch_pass(car: Car, tag: String, anchor: float, slow: bool) -> void:
	if slow:
		await _until_progress(car, anchor - 20.0)
		_slowmo(SLOWMO, 0.3)
		_cue(tag + "_slow", car)
	await _until_progress(car, anchor)
	_cue(tag + "_pass", car)
	if slow:
		await _until_progress(car, anchor + 22.0)
		_slowmo(1.0, 0.8)
		_cue(tag + "_fast", car)


func _chase(car: Car) -> void:
	main.cine.stop()
	main.chase.make_current()
	main.chase.snap()
	main.ui.set_ui_visible(true)
	car.controlled_by_player = false


func _slowmo(to: float, ramp: float) -> void:
	root.get_node("Sound").set_slowmo(to)
	var tw := create_tween().set_ignore_time_scale(true)
	tw.tween_method(func(v: float) -> void: Engine.time_scale = v, Engine.time_scale, to, ramp)


func _until_progress(car: Car, progress: float) -> void:
	var track: Track = main.map.track
	var hint := -1
	while true:
		hint = track.nearest(car.global_position, hint)
		var p := track.progress_of(hint, car.global_position)
		if p >= progress and p < progress + 200.0:
			return
		await process_frame


# ---------------------------------------------------------------- input

func _blip(hold: float) -> void:
	Input.action_press(&"throttle", 1.0)
	await _seconds(hold)
	Input.action_release(&"throttle")


func _key(code: Key) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	await _send(ev)


func _pad(button: JoyButton) -> void:
	var ev := InputEventJoypadButton.new()
	ev.button_index = button
	await _send(ev)


func _send(ev: InputEvent) -> void:
	ev.set("pressed", true)
	Input.parse_input_event(ev)
	await process_frame
	await process_frame
	var up := ev.duplicate() as InputEvent
	up.set("pressed", false)
	Input.parse_input_event(up)
	await process_frame


# ---------------------------------------------------------------- helpers

func _cue(cue_name: String, car: Car = null) -> void:
	var t := (Engine.get_frames_drawn() - _frame0) / 60.0
	var cue := {"name": cue_name, "t": snappedf(t, 0.001)}
	if car != null and main.map != null and main.map.track != null:
		var track: Track = main.map.track
		cue["progress"] = snappedf(track.progress_of(track.nearest(car.global_position), car.global_position), 0.1)
	cues.append(cue)
	print("CUE %8.3f %s" % [t, cue_name])


func _seconds(s: float) -> void:
	await create_timer(s, true, false, true).timeout


func _mark() -> void:
	marked = reached.duplicate()


## Waits for the next entry into a state after the last _mark(). Timeouts are in real seconds,
## generous because Movie Maker renders slower than real time.
func _until_state(state_name: StringName, timeout: float) -> void:
	var s: int = game.State[state_name]
	var start := Time.get_ticks_msec()
	while int(reached.get(s, 0)) <= int(marked.get(s, 0)):
		if (Time.get_ticks_msec() - start) / 1000.0 > timeout * 20.0:
			print("TIMEOUT waiting for %s" % state_name)
			return
		await process_frame
