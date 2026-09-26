extends Node
## Autoload `Game`: game state, event bus, settings, input map and saved records.
##
## Ownership: UI calls the request_* / set_* methods; the Main scene listens to
## the *_requested signals and does the actual loading; the race session calls
## the notify_* methods, which re-emit as signals for the UI. See docs/CONTRACTS.md.

signal state_changed(new_state: int, old_state: int)
signal start_requested(map_id: String, mode: String)
signal restart_requested
signal menu_requested
signal session_started(map_id: String, mode: String)
signal countdown_tick(value: int) ## 3, 2, 1, then 0 = GO
signal race_started
signal checkpoint_passed(index: int, total: int, split_time: float, delta_to_best: float)
signal race_finished(result: Dictionary)
signal paused_changed(paused: bool)
signal settings_changed
signal notice(text: String) ## short transient message for the HUD ("Car reset", "Wrong way")

enum State { BOOT, MENU, LOADING, INTRO, COUNTDOWN, RACING, FINISHED, FREE_ROAM }

const MODE_TIME_TRIAL := "time_trial"
const MODE_FREE_ROAM := "free_roam"

const SAVE_PATH := "user://sakura_rally.cfg"

## Map catalogue. Medal times are in seconds for one lap in time trial.
const MAPS: Array[Dictionary] = [
	{
		"id": "hanami",
		"name": "Hanami Pass",
		"name_jp": "花見峠",
		"tagline": "Spring noon. Gravel and tarmac under the blossom.",
		"scene": "res://scenes/maps/hanami.tscn",
		"preview": "res://assets/textures/previews/hanami.png",
		"season": "spring",
		"medals": {"gold": 150.0, "silver": 170.0, "bronze": 195.0},
	},
	{
		"id": "momiji",
		"name": "Momiji Valley",
		"name_jp": "紅葉谷",
		"tagline": "Autumn, golden hour. Loose dirt through the maples.",
		"scene": "res://scenes/maps/momiji.tscn",
		"preview": "res://assets/textures/previews/momiji.png",
		"season": "autumn",
		"medals": {"gold": 150.0, "silver": 170.0, "bronze": 195.0},
	},
]

## Liveries: primary body paint, secondary stripe colour.
const CAR_COLORS: Array[Dictionary] = [
	{"name": "Sakura", "primary": Color("f6f1e8"), "secondary": Color("e8517c")},
	{"name": "Momiji", "primary": Color("d9452b"), "secondary": Color("2b2a35")},
	{"name": "Sora", "primary": Color("3f7fc4"), "secondary": Color("f4cf47")},
	{"name": "Matcha", "primary": Color("6c9a58"), "secondary": Color("f3eee2")},
	{"name": "Sumi", "primary": Color("2c2a33"), "secondary": Color("f29a38")},
]

const DEFAULT_SETTINGS := {
	"master_volume": 0.9,
	"music_volume": 0.6,
	"sfx_volume": 0.9,
	"quality": "high", ## "low" | "medium" | "high"
	"transmission": "auto", ## "auto" | "manual"
	"camera": "chase", ## "chase" | "chase_far" | "hood" | "bumper"
	"units": "kmh", ## "kmh" | "mph"
	"car_color": 0,
	"fullscreen": false,
}

var state: int = State.BOOT
var mode: String = MODE_FREE_ROAM
var map_id: String = ""
var paused: bool = false
var settings: Dictionary = DEFAULT_SETTINGS.duplicate(true)
## map_id -> {"time": float, "splits": Array[float]}
var records: Dictionary = {}

## Set by the Main scene / race session while a map is loaded.
var player_car: Node = null ## RigidBody3D with scripts/vehicle/car.gd
var session: Node = null ## scripts/game/race_session.gd


func _enter_tree() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_setup_input_map()
	_load()


func _ready() -> void:
	_apply_window_settings()


# ---------------------------------------------------------------- requests (UI)

func request_start(new_map_id: String, new_mode: String) -> void:
	start_requested.emit(new_map_id, new_mode)


func request_restart() -> void:
	set_paused(false)
	restart_requested.emit()


func request_menu() -> void:
	set_paused(false)
	menu_requested.emit()


func request_quit() -> void:
	_save()
	get_tree().quit()


func set_paused(value: bool) -> void:
	if value == paused:
		return
	if value and not (state == State.RACING or state == State.FREE_ROAM or state == State.COUNTDOWN):
		return
	paused = value
	get_tree().paused = value
	paused_changed.emit(value)


func set_setting(key: String, value: Variant) -> void:
	if not DEFAULT_SETTINGS.has(key):
		push_warning("Unknown setting: %s" % key)
		return
	settings[key] = value
	if key == "fullscreen":
		_apply_window_settings()
	_save()
	settings_changed.emit()


func get_setting(key: String) -> Variant:
	return settings.get(key, DEFAULT_SETTINGS.get(key))


# ---------------------------------------------------------------- notifications (Main / session)

func set_state(new_state: int) -> void:
	if new_state == state:
		return
	var old := state
	state = new_state
	state_changed.emit(new_state, old)


func notify_session_started(new_map_id: String, new_mode: String) -> void:
	map_id = new_map_id
	mode = new_mode
	session_started.emit(new_map_id, new_mode)


func notify_countdown(value: int) -> void:
	countdown_tick.emit(value)


func notify_race_started() -> void:
	race_started.emit()


func notify_checkpoint(index: int, total: int, split_time: float) -> void:
	var delta := NAN
	var rec: Dictionary = records.get(map_id, {})
	var splits: Array = rec.get("splits", [])
	if index < splits.size():
		delta = split_time - float(splits[index])
	checkpoint_passed.emit(index, total, split_time, delta)


## result must contain "time" (float) and "splits" (Array[float]); extra keys pass through.
## Adds "best_time", "previous_best", "is_record", "medal" ("gold"/"silver"/"bronze"/"").
func notify_finished(result: Dictionary) -> void:
	var t: float = result.get("time", 0.0)
	var rec: Dictionary = records.get(map_id, {})
	var previous: float = rec.get("time", INF)
	var is_record := t < previous
	if is_record:
		records[map_id] = {"time": t, "splits": result.get("splits", [])}
		_save()
	result["previous_best"] = previous
	result["best_time"] = minf(t, previous)
	result["is_record"] = is_record
	result["medal"] = medal_for(map_id, t)
	result["map_id"] = map_id
	race_finished.emit(result)


func post_notice(text: String) -> void:
	notice.emit(text)


# ---------------------------------------------------------------- queries

func get_map(id: String) -> Dictionary:
	for m in MAPS:
		if m["id"] == id:
			return m
	return {}


func best_time(id: String) -> float:
	var rec: Dictionary = records.get(id, {})
	return rec.get("time", INF)


func medal_for(id: String, t: float) -> String:
	var m := get_map(id)
	if m.is_empty():
		return ""
	var medals: Dictionary = m["medals"]
	if t <= medals["gold"]:
		return "gold"
	if t <= medals["silver"]:
		return "silver"
	if t <= medals["bronze"]:
		return "bronze"
	return ""


func car_colors() -> Dictionary:
	return CAR_COLORS[clampi(int(settings["car_color"]), 0, CAR_COLORS.size() - 1)]


static func format_time(t: float) -> String:
	if is_inf(t) or is_nan(t):
		return "--:--.---"
	var total_ms := int(round(t * 1000.0))
	var m := total_ms / 60000
	var s := (total_ms / 1000) % 60
	var ms := total_ms % 1000
	return "%d:%02d.%03d" % [m, s, ms]


static func format_delta(d: float) -> String:
	if is_nan(d):
		return ""
	var sign_str := "+" if d >= 0.0 else "−"
	return "%s%.2f" % [sign_str, absf(d)]


# ---------------------------------------------------------------- input map

func _setup_input_map() -> void:
	_action("throttle", [KEY_W, KEY_UP], [], [[JOY_AXIS_TRIGGER_RIGHT, 1.0]])
	_action("brake", [KEY_S, KEY_DOWN], [], [[JOY_AXIS_TRIGGER_LEFT, 1.0]])
	_action("steer_left", [KEY_A, KEY_LEFT], [], [[JOY_AXIS_LEFT_X, -1.0]])
	_action("steer_right", [KEY_D, KEY_RIGHT], [], [[JOY_AXIS_LEFT_X, 1.0]])
	_action("handbrake", [KEY_SPACE], [JOY_BUTTON_A], [])
	_action("shift_up", [KEY_E], [JOY_BUTTON_RIGHT_SHOULDER], [])
	_action("shift_down", [KEY_Q], [JOY_BUTTON_LEFT_SHOULDER], [])
	_action("camera_next", [KEY_C], [JOY_BUTTON_Y], [])
	_action("reset_car", [KEY_R], [JOY_BUTTON_BACK], [])
	_action("pause", [KEY_ESCAPE, KEY_P], [JOY_BUTTON_START], [])
	_action("horn", [KEY_H], [JOY_BUTTON_LEFT_STICK], [])


func _action(action_name: String, keys: Array, buttons: Array, axes: Array) -> void:
	if InputMap.has_action(action_name):
		InputMap.erase_action(action_name)
	InputMap.add_action(action_name, 0.15)
	for k in keys:
		var ev := InputEventKey.new()
		ev.physical_keycode = k
		InputMap.action_add_event(action_name, ev)
	for b in buttons:
		var jb := InputEventJoypadButton.new()
		jb.button_index = b
		InputMap.action_add_event(action_name, jb)
	for a in axes:
		var jm := InputEventJoypadMotion.new()
		jm.axis = a[0]
		jm.axis_value = a[1]
		InputMap.action_add_event(action_name, jm)


# ---------------------------------------------------------------- persistence

func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	for key in DEFAULT_SETTINGS.keys():
		settings[key] = cfg.get_value("settings", key, DEFAULT_SETTINGS[key])
	for id in cfg.get_section_keys("records") if cfg.has_section("records") else PackedStringArray():
		records[id] = cfg.get_value("records", id)


func _save() -> void:
	var cfg := ConfigFile.new()
	for key in settings.keys():
		cfg.set_value("settings", key, settings[key])
	for id in records.keys():
		cfg.set_value("records", id, records[id])
	cfg.save(SAVE_PATH)


func _apply_window_settings() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var fs: bool = settings.get("fullscreen", false)
	var want := DisplayServer.WINDOW_MODE_FULLSCREEN if fs else DisplayServer.WINDOW_MODE_WINDOWED
	if DisplayServer.window_get_mode() != want:
		DisplayServer.window_set_mode(want)
