extends SceneTree
## Demo reel footage, rendered offline by Movie Maker: run tools/video/render_demo.sh, not this
## script directly (cue times count Movie Maker frames at 60 fps). The real game, driven by real
## key / pad presses through the real UI and the autopilot:
##   title hub over the drifting flyover -> Down, Down, Enter: the garage (the menu car stands
##   at the roadside workshop under the garage orbit) -> Up, Right: the next livery brushes on
##   -> Esc -> Up, Enter: Time Attack with the Hanami card focused -> Up to Time Trial and back
##   -> Enter: intro swoop, countdown with throttle blips, launch under the chase camera with
##   the HUD -> the showoff lap under directed cinematic cuts (HUD hidden): a fabric checkpoint
##   gate, the tarmac hairpin where the car runs wide through the hay bales, slow motion
##   through the gravel esses -> chase camera + HUD over the last bridge to the finish ->
##   results card -> Right, A: Next map -> Momiji at golden hour, slow motion through the
##   gravel hairpin -> pause -> Main menu (lands on the Time Attack page) -> Esc: the title over
##   the Hanami flyover.
## Music is muted here: cut_demo.py lays one continuous track under the edit. Cues (video
## seconds + lap progress) go to <footage>/cues.json: every state entry, every cut and pass, every
## menu step, each fabric gate the car passes (<map>_gate_<i>) and the first smash of soft
## dressing per map (<map>_smash).
##
## Check the flow without Movie Maker (real time, nothing on screen, no sound):
##   timeout 600 $S --summer-offscreen --audio-driver Dummy --disable-crash-handler --path . \
##       -s res://tools/video/demo.gd -- footage=/tmp/sakura_demo_check stills=/tmp/sakura_demo_check/stills
## (stills=<dir> saves the frame at every cue, and two more after each smash and gate.)
##
## Cue times count main-loop iterations, one per Movie Maker frame. macOS stops drawing a covered
## window, the offscreen one too, while Movie Maker still writes a frame per iteration; KeepDrawing
## draws those frames itself, so the footage never freezes and the cues stay on the footage clock.

const SLOWMO := 0.3
## Seconds between menu key presses: slow enough to read each focus move on video.
const MENU_STEP := 0.55

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
## Designed runs through soft roadside dressing (the showoff style never touches anything on its
## own): [lap progress of the peak, half length (m), lead (m), peak lateral offset (m, + right)].
## The autopilot's line bends out along a cosine bump; the car answers about `lead` metres late
## and swings a little past the peak. Hanami: the left-hand tarmac hairpin under the roadside
## camera (cut 3) - the car slides wide into the round hay bales lining the outside (lat +9.9,
## 655-703 m) and ploughs out at ~30 km/h; nothing rigid stands within 9 m of the line there.
## Headless (Sakura, demo pace) it smashes a dozen bales and never touches anything rigid.
const SWERVES := {
	"hanami": [[672.0, 30.0, 4.0, 6.5]],
	"momiji": [],
}
## Lap progress where the chase camera and HUD come back on Momiji (before the pause).
const MOMIJI_END := 1760.0

## footage=<dir>: where cues.json goes. (Not `out=`: under --summer-offscreen Summer reads an
## `out=` user argument as a probe's results folder and closes the window ~30 s into the take.)
var opts := {"footage": "/tmp/sakura_demo"}
var main: Node
var game: Node
var reached: Dictionary = {}
var marked: Dictionary = {}
var cues: Array[Dictionary] = []
var _frame0 := 0
var _keep: KeepDrawing


## Runs last in every iteration; after one that drew nothing (the window covered), renders the
## frame into the viewport texture, which Movie Maker and the stills read.
class KeepDrawing extends Node:
	var forced := 0
	var _drawn := -1

	func _init() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		process_priority = 1 << 30

	func _process(delta: float) -> void:
		var drawn := Engine.get_frames_drawn()
		if drawn == _drawn:
			RenderingServer.force_draw(false, delta)
			forced += 1
		_drawn = drawn


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	DirAccess.make_dir_recursive_absolute(opts["footage"])
	if opts.has("stills"):
		DirAccess.make_dir_recursive_absolute(opts["stills"])
	game = root.get_node("Game")
	game.set_setting("music_volume", 0.0) # a -s harness never saves settings (Game.persistent)
	game.state_changed.connect(func(s: int, _o: int) -> void:
		reached[s] = int(reached.get(s, 0)) + 1
		_cue("%s_%d" % [str((game.State as Dictionary).find_key(s)).to_lower(), reached[s]]))
	# A window close request quits the game mid-take: say so in the log.
	root.close_requested.connect(func() -> void: print("WINDOW close requested at %.2f s" % _now()))
	_frame0 = Engine.get_process_frames()
	_keep = KeepDrawing.new()
	root.add_child(_keep)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func _run() -> void:
	await _until_state(&"MENU", 60.0)
	await _seconds(7.0) # the title animates in over the flyover
	await _menu_run()

	var car := await _race_start()
	await _montage(car, "hanami")
	await _until_progress(car, main.map.track.length - 160.0)
	_chase(car)
	_cue("hanami_last_bridge", car)
	_mark()
	await _until_state(&"FINISHED", 60.0)
	await _seconds(8.5) # finish slam, slow-motion orbit, results count-up and medal stamp
	await _pad(JOY_BUTTON_DPAD_RIGHT) # Retry -> Next map
	await _seconds(0.6)
	_mark()
	_cue("results_next")
	await _pad(JOY_BUTTON_A)

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
	# Back from a Time Attack drive the hub lands on the Time Attack page: Esc to the title.
	await _until(func() -> bool: return str(game.menu_view) == "time_attack", 10.0)
	await _seconds(2.2)
	await _key(KEY_ESCAPE)
	await _until(func() -> bool: return str(game.menu_view) == "title", 5.0)
	_cue("title_end")
	await _seconds(9.0)
	_cue("end")
	print("KEEP_DRAWING %d frames drawn by the tool (window covered)" % _keep.forced)
	var f := FileAccess.open("%s/cues.json" % opts["footage"], FileAccess.WRITE)
	f.store_string(JSON.stringify(cues, "  "))
	f.close()
	game.request_quit()


## Title hub -> garage (one livery change) -> back -> Time Attack -> Hanami, Time Trial -> start.
## Arrow keys, Enter and Esc through the real InputMap, one step every MENU_STEP seconds.
func _menu_run() -> void:
	for i in 2: # Campaign -> Time Attack -> Garage
		await _key(KEY_DOWN)
		await _seconds(MENU_STEP)
	_cue("hub_garage")
	await _key(KEY_ENTER)
	await _until(func() -> bool: return str(game.menu_view) == "garage", 5.0)
	_cue("garage")
	await _seconds(2.6) # the garage orbit's establishing view eases in
	await _key(KEY_UP) # car strip -> livery picker
	await _seconds(MENU_STEP)
	var colour := int(game.get_setting("car_color"))
	_cue("garage_livery")
	await _key(KEY_RIGHT) # the next livery brushes on
	await _seconds(2.4)
	if int(game.get_setting("car_color")) == colour:
		print("MENU livery did not change")
	await _key(KEY_ESCAPE)
	await _until(func() -> bool: return str(game.menu_view) == "title", 5.0)
	await _seconds(1.6) # the flyover picks the car up again
	await _key(KEY_UP) # Garage -> Time Attack
	await _seconds(MENU_STEP)
	_cue("hub_time_attack")
	await _key(KEY_ENTER)
	await _until(func() -> bool: return str(game.menu_view) == "time_attack", 5.0)
	_cue("time_attack")
	await _seconds(1.4) # the cards rise in
	for i in 3:
		if _focused_map() == "hanami":
			break
		await _key(KEY_LEFT)
		await _seconds(MENU_STEP)
	if _focused_map() != "hanami":
		print("MENU Hanami card not focused (%s)" % _focused_map())
	await _key(KEY_UP) # the mode picker: Time Trial
	await _seconds(0.8)
	await _key(KEY_DOWN) # back onto the Hanami card
	await _seconds(MENU_STEP)
	_mark()
	_cue("time_attack_start")
	await _key(KEY_ENTER)


## Map id of the focused Time Attack card ("" when the focus is elsewhere).
func _focused_map() -> String:
	var f := root.gui_get_focus_owner()
	if f != null and "map" in f and f.map is Dictionary:
		return str(f.map.get("id", ""))
	return ""


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
	# On show: committed braking and every real corner sideways (see Autopilot `style`).
	ap.style = &"showoff"
	car.add_child(ap)
	var map_id := str(main.map.route_id)
	for s: Array in SWERVES.get(map_id, []):
		_swerve(car, ap, map_id, s)
	_watch_gates(car, map_id)
	var smashed := [false]
	main.map.soft_course.smashed.connect(func(_prop: String, _p: Vector3, _v: float, _loss: float) -> void:
		if not smashed[0] and is_instance_valid(car):
			smashed[0] = true
			_cue(map_id + "_smash", car))
	return car


## Bends the autopilot's line out along the SWERVES cosine bump `s` while the car passes it.
func _swerve(car: Car, ap: Autopilot, map_id: String, s: Array) -> void:
	var track: Track = main.map.track
	var peak: float = s[0]
	var half: float = s[1]
	var lead: float = s[2]
	var amount: float = s[3]
	await _until_progress(car, peak - half - lead)
	_cue(map_id + "_swerve", car)
	var hint := -1
	while is_instance_valid(ap):
		hint = track.nearest(car.global_position, hint)
		var x := (track.progress_of(hint, car.global_position) + lead - peak) / half
		if x >= 1.0:
			break
		ap.lateral_offset = amount * 0.5 * (1.0 + cos(PI * clampf(x, -1.0, 1.0)))
		await physics_frame
	if is_instance_valid(ap):
		ap.lateral_offset = 0.0


## Cues each fabric checkpoint gate as the car reaches it.
func _watch_gates(car: Car, map_id: String) -> void:
	var track: Track = main.map.track
	var marks: Array[float] = []
	for c: Dictionary in main.map.checkpoints:
		var p: Vector3 = c["position"]
		marks.append(track.progress_of(track.nearest(p), p))
	marks.sort()
	for i in marks.size():
		if marks[i] < 1.0 or marks[i] > track.length - 1.0:
			continue # the start / finish line
		await _until_progress(car, marks[i])
		if not is_instance_valid(car) or main.map == null or str(main.map.route_id) != map_id:
			return
		_cue("%s_gate_%d" % [map_id, i], car)


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


## Returns once the car reaches a lap progress (at once when the car is gone).
func _until_progress(car: Car, progress: float) -> void:
	var track: Track = main.map.track
	var hint := -1
	while is_instance_valid(car):
		hint = track.nearest(car.global_position, hint)
		var p := track.progress_of(hint, car.global_position)
		if p >= progress and p < progress + 200.0:
			return
		await process_frame


## Waits (real seconds) until `cond` holds; prints a TIMEOUT line when it never does.
func _until(cond: Callable, timeout: float) -> void:
	var start := Time.get_ticks_msec()
	while not cond.call():
		if (Time.get_ticks_msec() - start) / 1000.0 > timeout * 20.0:
			print("TIMEOUT waiting for %s" % cond)
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
	var t := _now()
	var cue := {"name": cue_name, "t": snappedf(t, 0.001)}
	if car != null and main.map != null and main.map.track != null:
		var track: Track = main.map.track
		cue["progress"] = snappedf(track.progress_of(track.nearest(car.global_position), car.global_position), 0.1)
	cues.append(cue)
	print("CUE %8.3f %s" % [t, cue_name])
	if opts.has("stills"):
		_stills(cue_name)


## Check runs (-- stills=<dir>): the frame at each cue, plus two more after a smash or a gate.
func _stills(cue_name: String) -> void:
	var delays: Array[float] = [0.0]
	if cue_name.ends_with("_smash") or cue_name.contains("_gate_"):
		delays.append_array([0.5, 1.0])
	for d in delays:
		if d > 0.0:
			await _seconds(0.5)
		await RenderingServer.frame_post_draw
		var img := root.get_texture().get_image()
		img.save_jpg("%s/%07.2f_%s_%.1f.jpg" % [opts["stills"], _now(), cue_name, d], 0.85)


## Seconds of footage since the start (60 fps).
func _now() -> float:
	return (Engine.get_process_frames() - _frame0) / 60.0


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
