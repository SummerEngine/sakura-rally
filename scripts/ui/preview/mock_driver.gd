extends Node
## UI preview harness (scenes/ui/preview/ui_preview.tscn). Plays the lead's Main-scene role
## against the real Game autoload: answers start / restart / menu requests with the ink
## transition, fakes loading, drives INTRO -> COUNTDOWN -> RACING with a mock car + session, and
## paints a procedural anime landscape behind the UI in place of the 3D world.
##
## Keys (on top of the normal game / ui actions):
##   F2 notice   F3 next checkpoint   F4 finish now (gold)   F5 finish now (slow)
##   F6 cycle window aspect 16:9 / 16:10 / 21:9   F1 hide UI (handled by the UI root)
## Command line (after `--`): --capture[=16x9|16x10|21x9] steps through every screen, saves
## PNGs + animation contact sheets into docs/renders/ and quits. See docs/UI.md.

const MockCar := preload("res://scripts/ui/preview/mock_car.gd")
const MockSession := preload("res://scripts/ui/preview/mock_session.gd")
const CaptureRunner := preload("res://scripts/ui/preview/capture_runner.gd")
const PAINTED := preload("res://shaders/ui/painted_scene.gdshader")

const ASPECTS := {"16x9": Vector2i(1600, 900), "16x10": Vector2i(1440, 900), "21x9": Vector2i(2100, 900)}
const INTRO_TIME := 2.8

@onready var ui: CanvasLayer = $UIRoot
@onready var backdrop: ColorRect = $Backdrop/Painted

var game: Node
var car: MockCar
var session: MockSession
var busy := false

var _run := 0 ## bumps on every flow change so stale coroutines stop
var _mat := ShaderMaterial.new()
var _autumn := 0.0
var _autumn_target := 0.0
var _drive_x := 0.0
var _records_snapshot: Dictionary = {}
var _aspect_keys: Array = ASPECTS.keys()
var _aspect_i := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	game = get_tree().root.get_node("Game")
	# Preview runs must not leave records in the player's save file.
	_records_snapshot = (game.records as Dictionary).duplicate(true)
	_mat.shader = PAINTED
	_mat.set_shader_parameter("time_scale", 0.5)
	backdrop.material = _mat
	backdrop.resized.connect(func() -> void: _mat.set_shader_parameter("rect_size", backdrop.size))
	_mat.set_shader_parameter("rect_size", backdrop.size)

	car = MockCar.new()
	car.name = "MockCar"
	add_child(car)
	session = MockSession.new()
	session.name = "MockSession"
	session.car = car
	add_child(session)

	game.start_requested.connect(_on_start_requested)
	game.restart_requested.connect(_on_restart_requested)
	game.menu_requested.connect(_on_menu_requested)

	var capture_aspect := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--capture"):
			capture_aspect = a.get_slice("=", 1) if a.contains("=") else "16x9"
	if capture_aspect != "":
		game.records = {}
		set_aspect(capture_aspect)
		var runner := CaptureRunner.new()
		runner.name = "CaptureRunner"
		add_child(runner)
		runner.run(self, capture_aspect)
	game.set_state(game.State.MENU)


func _exit_tree() -> void:
	game.records = _records_snapshot
	# Persist the restored records (any setting write saves the whole config).
	game.set_setting("car_color", game.get_setting("car_color"))


func set_aspect(key: String) -> void:
	if not ASPECTS.has(key):
		return
	var win := get_window()
	win.mode = Window.MODE_WINDOWED
	win.size = ASPECTS[key]
	win.move_to_center()


func wait(seconds: float, while_paused: bool = false) -> Signal:
	return get_tree().create_timer(seconds, while_paused, false, true).timeout


# ---------------------------------------------------------------- Main-scene role

func _on_start_requested(map_id: String, mode: String) -> void:
	if busy:
		return
	_run += 1
	var run := _run
	busy = true
	await ui.transition_out(map_id)
	if run != _run:
		return
	_load_session(map_id, mode, run)


func _on_restart_requested() -> void:
	if busy:
		return
	_run += 1
	var run := _run
	busy = true
	var map_id := str(game.map_id)
	var mode := str(game.mode)
	await ui.transition_out(map_id)
	if run != _run:
		return
	_load_session(map_id, mode, run)


func _on_menu_requested() -> void:
	if busy:
		return
	_run += 1
	var run := _run
	busy = true
	await ui.transition_out()
	if run != _run:
		return
	_teardown()
	game.set_state(game.State.LOADING)
	await wait(0.35)
	_autumn_target = 0.0
	game.set_state(game.State.MENU)
	busy = false
	ui.transition_in()


func _teardown() -> void:
	car.running = false
	session.running = false
	game.player_car = null
	game.session = null


func _load_session(map_id: String, mode: String, run: int) -> void:
	_teardown()
	game.set_state(game.State.LOADING)
	await wait(0.9)
	if run != _run:
		return
	var m: Dictionary = game.get_map(map_id)
	_autumn_target = 1.0 if str(m.get("season", "")) == "autumn" else 0.0
	_autumn = _autumn_target
	car.reset()
	session.begin(mode, game.best_time(map_id))
	game.player_car = car
	game.session = session
	game.notify_session_started(map_id, mode)
	game.set_state(game.State.INTRO)
	busy = false
	ui.transition_in()
	await wait(INTRO_TIME)
	if run != _run:
		return
	if mode == str(game.MODE_TIME_TRIAL):
		game.set_state(game.State.COUNTDOWN)
		for v in [3, 2, 1]:
			game.notify_countdown(v)
			await wait(1.0)
			if run != _run:
				return
		game.notify_countdown(0)
		game.set_state(game.State.RACING)
	else:
		game.set_state(game.State.FREE_ROAM)
	game.notify_race_started()
	car.running = true
	session.running = true


# ---------------------------------------------------------------- preview shortcuts

## Finish the lap now with `lap_time` (e.g. 148.4 = gold on both maps).
func finish_now(lap_time: float) -> void:
	if int(game.state) != int(game.State.RACING):
		return
	session.jump_to(0.9995, lap_time - 0.12)


func next_checkpoint() -> void:
	if int(game.state) != int(game.State.RACING):
		return
	var p := float(session.checkpoint_index + 1) / float(session.checkpoint_total + 1)
	session.jump_to(p + 0.001, maxf(session.elapsed, p * 150.0))


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	match key.physical_keycode:
		KEY_F2:
			game.post_notice(["Car reset", "Wrong way", "Handbrake turn!", "Camera: chase"].pick_random())
		KEY_F3:
			next_checkpoint()
		KEY_F4:
			finish_now(148.4)
		KEY_F5:
			finish_now(176.25)
		KEY_F6:
			_aspect_i = (_aspect_i + 1) % _aspect_keys.size()
			set_aspect(str(_aspect_keys[_aspect_i]))
		KEY_R:
			if car.running:
				game.post_notice("Car reset")


func _process(delta: float) -> void:
	_autumn = lerpf(_autumn, _autumn_target, 1.0 - exp(-4.0 * delta))
	_mat.set_shader_parameter("autumn", _autumn)
	if car.running and not bool(game.paused):
		_drive_x += car.speed_kmh * delta * 0.004
	_mat.set_shader_parameter("parallax", sin(_drive_x * 0.35) * 0.8)
