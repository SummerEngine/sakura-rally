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
## delta_to_best: in a time trial the split against the record's (NAN: no record); in a race the
## interval to the car ahead, negative when leading (minus the lead over the second car).
signal checkpoint_passed(index: int, total: int, split_time: float, delta_to_best: float)
signal race_finished(result: Dictionary)
signal paused_changed(paused: bool)
signal settings_changed
signal notice(text: String) ## short transient message for the HUD ("Car reset", "Wrong way")
signal menu_view_changed(view: String) ## "title" | "time_attack" | "garage" (Main parks the car in the garage)
## Campaign (docs/CONTRACTS.md, "Campaign in one world"). Main listens to the *_requested ones.
signal campaign_requested
signal campaign_continue_requested
signal campaign_leg_started(index: int, leg: Dictionary)
signal arrived ## the liaison car reached Momiji's grid (re-emitted from RaceSession.arrived)
signal campaign_finished(summary: Dictionary)
## Race: the classification changed after the player finished (a rival crossed the line); rows as
## in RaceField.classification().
signal race_classification_changed(rows: Array)

## LIAISON: the untimed drive from Hanami's finish on to Momiji's grid. ARRIVED: the car comes to
## rest there and the arrival card waits for the player to start the stage
## (request_campaign_continue) or quit. FINALE: the rally classification and end card after the
## last stage.
enum State { BOOT, MENU, LOADING, INTRO, COUNTDOWN, RACING, FINISHED, FREE_ROAM, LIAISON, ARRIVED, FINALE }

const MODE_TIME_TRIAL := "time_trial"
const MODE_FREE_ROAM := "free_roam"
## Untimed drive between two campaign stages along the world's `liaison` route (open road, ends
## at the next stage's grid).
const MODE_LIAISON := "liaison"
## Two laps of a stage loop from a standing start against the campaign's rivals (RIVALS, at their
## pace on that stage), cars colliding (Car.car_contacts); Main builds the grid and the RaceField.
const MODE_RACE := "race"
const RACE_LAPS := 2

const SAVE_PATH := "user://sakura_rally.cfg"

## Stage catalogue: the two stage routes of the world (the ids are MapWorld route ids and the
## keys of records and campaign results). Medal times are in seconds for one lap in time trial, set against the
## autopilot's clean reference lap in the default car, the Sakura (ep2 handling: hanami 113.3 s,
## momiji 99.5 s; tools/physics/run_tests.gd only=maps): gold 1.1x, silver 1.22x, bronze 1.42x,
## rounded to 0.5 s.
const MAPS: Array[Dictionary] = [
	{
		"id": "hanami",
		"name": "Hanami Pass",
		"name_jp": "花見峠",
		"tagline": "Spring noon. Gravel and tarmac under the blossom.",
		"season": "spring",
		"medals": {"gold": 124.5, "silver": 138.0, "bronze": 161.0},
	},
	{
		"id": "momiji",
		"name": "Momiji Valley",
		"name_jp": "紅葉谷",
		"tagline": "Autumn, golden hour. Loose dirt through the maples.",
		"season": "autumn",
		"medals": {"gold": 109.5, "silver": 121.5, "bronze": 141.5},
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

## Garage catalogue. "scene" is a car scene whose root runs scripts/vehicle/car.gd; "stats" are
## 0..1 bars for the garage, set from the tuned cars' telemetry (docs/PHYSICS.md).
const CARS: Array[Dictionary] = [
	{
		"id": "sakura",
		"name": "Sakura",
		"name_jp": "桜",
		"tagline": "Turbo four, all-wheel drive. Grips, forgives, flies.",
		"spec": "2.0 turbo · AWD · 0-100 3.5 s · 189 km/h",
		"scene": "res://scenes/car/car.tscn",
		"stats": {"speed": 0.79, "acceleration": 0.83, "grip": 0.88, "drift": 0.81},
	},
	{
		"id": "hayate",
		"name": "Hayate",
		"name_jp": "疾風",
		"tagline": "Rev-happy coupe, rear-wheel drive. Slides when you ask it to.",
		"spec": "1.6 twin-cam · RWD · 0-100 5.0 s · 188 km/h",
		"scene": "res://scenes/car/car_hayate.tscn",
		"stats": {"speed": 0.78, "acceleration": 0.59, "grip": 0.9, "drift": 0.88},
	},
]

## The campaign: one continuous drive through the world's seasons. "map" is the MapWorld route
## the leg drives. Stages are timed ("SS"; "kanji" is the season on their stamps); the liaison is
## the untimed road from one stage's finish to the next stage's grid, not a level of its own (no
## code on screen). After the last leg comes the finale (classification against RIVALS).
const CAMPAIGN: Array[Dictionary] = [
	{"map": "hanami", "kind": "stage", "code": "SS1", "title": "Hanami Pass", "title_jp": "花見峠", "kanji": "春"},
	{"map": "liaison", "kind": "liaison", "code": "L1", "title": "On to Momiji Valley", "title_jp": "紅葉谷", "kanji": "夏"},
	{"map": "momiji", "kind": "stage", "code": "SS2", "title": "Momiji Valley", "title_jp": "紅葉谷", "kanji": "秋"},
]

## Fictional rivals of the campaign classification, who are also the field of a race. "pace": one
## factor per campaign stage (in CAMPAIGN order) applied to that map's gold time: the campaign's
## stage times and, in a race on that stage, the lap time their driver is set to. "car" and
## "colors" (primary, secondary): what they race in.
const RIVALS: Array[Dictionary] = [
	{"name": "Ren Takeda", "name_jp": "武田蓮", "team": "Kitsune Works", "pace": [0.97, 0.99],
			"car": "hayate", "colors": [Color("e8742c"), Color("f5f0e6")]},
	{"name": "Aoi Fujimura", "name_jp": "藤村葵", "team": "Team Hotaru", "pace": [1.00, 0.97],
			"car": "sakura", "colors": [Color("1f5f5b"), Color("c9e265")]},
	{"name": "Kenji Hayashi", "name_jp": "林健二", "team": "Shirakaba Racing", "pace": [1.03, 1.05],
			"car": "hayate", "colors": [Color("5b3f99"), Color("d9d9de")]},
	{"name": "Mei Sakamoto", "name_jp": "坂本芽衣", "team": "Tsubame Motorsport", "pace": [1.08, 1.04],
			"car": "sakura", "colors": [Color("1e2a5a"), Color("d8342c")]},
	{"name": "Daichi Ono", "name_jp": "小野大地", "team": "Ono Garage", "pace": [1.13, 1.16],
			"car": "hayate", "colors": [Color("f2c230"), Color("2b2a33")]},
	{"name": "Hana Kobayashi", "name_jp": "小林花", "team": "Team Tanpopo", "pace": [1.22, 1.25],
			"car": "sakura", "colors": [Color("8fd3c1"), Color("f7d64a")]},
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
	"car_id": "sakura",
	"fullscreen": false,
}

var state: int = State.BOOT
var mode: String = MODE_FREE_ROAM
var map_id: String = ""
var paused: bool = false
var menu_view: String = "title"
var settings: Dictionary = DEFAULT_SETTINGS.duplicate(true)
## map_id -> {"time": float, "splits": Array[float]}
var records: Dictionary = {}
## False for tool runs (`-s` scripts: the SceneTree has a script) and the UI preview:
## they start from defaults and never read or write the player's save file.
var persistent := true

## Set by the Main scene / race session while a map is loaded.
var player_car: Node = null ## RigidBody3D with scripts/vehicle/car.gd
var session: Node = null ## scripts/game/race_session.gd
## The race in progress (scripts/game/race_field.gd; Main, MODE_RACE only).
var race: Node = null
## True once the AI driver (scripts/ai/auto_drive.gd) has had the player's car in the run in
## progress; AutoDrive clears it at each countdown. Such a finish sets no record and no medal.
var ai_drove: bool = false
var _quitting := false

## Campaign: true from request_campaign() until the player is back on the title (or starts a
## Time Attack run). campaign_leg: the leg being played or loaded, -1 outside a leg.
var campaign_active := false
var campaign_leg := -1
## Saved progress: "leg" = next leg to play (CAMPAIGN.size() once every leg is done),
## "results" = map_id -> {"time", "medal"} of the stages, "finished" = the finale was reached.
var _campaign: Dictionary = {"leg": 0, "results": {}, "finished": false}


func _enter_tree() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().auto_accept_quit = false
	persistent = get_tree().get_script() == null
	_setup_input_map()
	if persistent:
		_load()


func _ready() -> void:
	if persistent:
		_fit_window()
	_apply_window_settings()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		request_quit()


# ---------------------------------------------------------------- requests (UI)

func request_start(new_map_id: String, new_mode: String) -> void:
	start_requested.emit(new_map_id, new_mode)


func request_restart() -> void:
	set_paused(false)
	restart_requested.emit()


func request_menu() -> void:
	set_paused(false)
	menu_requested.emit()


## Which part of the title hub is showing. "garage" parks the menu car on the start grid under a
## showroom orbit; the other views keep the flyover.
func set_menu_view(view: String) -> void:
	if view == menu_view:
		return
	menu_view = view
	menu_view_changed.emit(view)


## Every quit comes through here: the title's Quit button, closing the window, Cmd+Q, and the
## tools that run the game. A player still playing when the tree is torn down leaks its
## stream: the AudioServer releases a stopped playback only after its audio thread has mixed
## the fade-out. So stop them all and give that thread 100 ms of wall-clock time (frames run
## faster than real time under --fixed-fps), then quit.
func request_quit(exit_code: int = 0) -> void:
	if _quitting:
		return
	_quitting = true
	_save()
	for node in get_tree().root.find_children("*", "", true, false):
		if node is AudioStreamPlayer or node is AudioStreamPlayer2D or node is AudioStreamPlayer3D:
			node.stop()
	var until := Time.get_ticks_msec() + 100
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame
	get_tree().quit(exit_code)


func set_paused(value: bool) -> void:
	if value == paused:
		return
	if value and not (state == State.RACING or state == State.FREE_ROAM or state == State.COUNTDOWN \
			or state == State.LIAISON):
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


## Race: the player's car passed checkpoint `index` of the lap (the last is the lap line) at race
## time `split_time`; `interval` as checkpoint_passed's delta_to_best.
func notify_race_checkpoint(index: int, total: int, split_time: float, interval: float) -> void:
	checkpoint_passed.emit(index, total, split_time, interval)


## Race: a rival finished after the player (the results card fills in its row).
func notify_race_classification(rows: Array) -> void:
	race_classification_changed.emit(rows)


## result must contain "time" (float) and "splits" (Array[float]); extra keys pass through.
## Adds "map_id" and "ai_drove" (the AI driver had the car).
## A race (MODE_RACE; RaceField's "position", "field", "laps", "best_lap", "classification" pass
## through) adds "race": true and sets no record and no medal: its laps are driven in traffic.
## A time trial adds "best_time", "previous_best", "is_record", "medal"
## ("gold"/"silver"/"bronze"/""); a run the AI driver had sets no record and no medal.
## A campaign stage also records the time in the campaign progress and adds "campaign": true,
## "leg" (index), "standing" and "field" (rally position after this stage, of how many).
func notify_finished(result: Dictionary) -> void:
	result["map_id"] = map_id
	result["ai_drove"] = ai_drove
	if mode == MODE_RACE:
		result["race"] = true
		race_finished.emit(result)
		return
	var t: float = result.get("time", 0.0)
	var rec: Dictionary = records.get(map_id, {})
	var previous: float = rec.get("time", INF)
	var is_record := t < previous and not ai_drove
	if is_record:
		records[map_id] = {"time": t, "splits": result.get("splits", [])}
	result["previous_best"] = previous
	result["best_time"] = previous if ai_drove else minf(t, previous)
	result["is_record"] = is_record
	result["medal"] = "" if ai_drove else medal_for(map_id, t)
	var leg := campaign_current_leg()
	result["campaign"] = leg.get("kind", "") == "stage" and leg["map"] == map_id
	if result["campaign"]:
		(_campaign["results"] as Dictionary)[map_id] = {"time": t, "medal": result["medal"]}
		_campaign["leg"] = maxi(int(_campaign["leg"]), campaign_leg + 1)
		result["leg"] = campaign_leg
		var table := campaign_classification()
		result["field"] = table.size()
		for i in table.size():
			if table[i]["player"]:
				result["standing"] = i + 1
	_save()
	race_finished.emit(result)


## Called by the race session when the liaison car reaches the next stage's grid.
func notify_arrived() -> void:
	if campaign_current_leg().get("kind", "") == "liaison":
		_campaign["leg"] = maxi(int(_campaign["leg"]), campaign_leg + 1)
		_save()
	arrived.emit()


func post_notice(text: String) -> void:
	notice.emit(text)


# ---------------------------------------------------------------- campaign

## Title: start the journey (fresh) or resume it at the saved leg (SS1: Hanami grid; the liaison:
## Hanami's finish stop with the branch open; SS2: Momiji grid). A finished campaign always
## starts afresh.
func request_campaign(fresh: bool) -> void:
	if fresh or bool(_campaign["finished"]):
		_campaign = {"leg": 0, "results": {}, "finished": false}
		_save()
	campaign_active = true
	campaign_requested.emit()


## Results "Continue" and the arrival card's "Start SS2": Main goes straight on into the next leg
## from where the car stands (or into the finale once every leg is done).
func request_campaign_continue() -> void:
	set_paused(false)
	campaign_active = true
	campaign_continue_requested.emit()


func campaign_status() -> Dictionary:
	var leg := int(_campaign["leg"])
	var results: Dictionary = _campaign["results"]
	return {
		"started": leg > 0 or not results.is_empty(),
		"finished": bool(_campaign["finished"]),
		"leg": leg,
		"legs": CAMPAIGN.size(),
		"next": CAMPAIGN[leg] if leg < CAMPAIGN.size() else {},
		"results": results.duplicate(true),
	}


## The leg being played or loaded ({} outside the campaign).
func campaign_current_leg() -> Dictionary:
	if not campaign_active or campaign_leg < 0 or campaign_leg >= CAMPAIGN.size():
		return {}
	return CAMPAIGN[campaign_leg]


## Main: leg `index` starts (at the title's resume point or on from the previous leg).
func notify_campaign_leg(index: int) -> void:
	campaign_leg = index
	campaign_leg_started.emit(index, CAMPAIGN[index])


## Main: the finale is showing. Marks the campaign finished and emits the summary:
## {"classification": campaign_classification(), "results", "position", "field"}.
func notify_campaign_finished() -> void:
	campaign_leg = -1
	_campaign["finished"] = true
	_save()
	var table := campaign_classification()
	var pos := 0
	for i in table.size():
		if table[i]["player"]:
			pos = i + 1
	campaign_finished.emit({"classification": table, "results": (_campaign["results"] as Dictionary).duplicate(true),
			"position": pos, "field": table.size()})


## Main: back on the title or into a Time Attack run.
func end_campaign_session() -> void:
	campaign_active = false
	campaign_leg = -1


## Rally classification over the stages the player has finished, fastest total first. Rows:
## {"name", "name_jp", "team", "player": bool, "times": Array[float] (per finished stage, in
## CAMPAIGN order), "total": float, "gap": float (to the leader)}.
func campaign_classification() -> Array[Dictionary]:
	var results: Dictionary = _campaign["results"]
	var stage_maps_done: Array[String] = []
	var stage_index: Array[int] = []
	var k := 0
	for leg in CAMPAIGN:
		if leg["kind"] == "stage":
			if results.has(leg["map"]):
				stage_maps_done.append(leg["map"])
				stage_index.append(k)
			k += 1
	var rows: Array[Dictionary] = []
	var car := current_car()
	var player_times: Array[float] = []
	for id in stage_maps_done:
		player_times.append(float((results[id] as Dictionary)["time"]))
	rows.append({"name": "You", "name_jp": str(car["name_jp"]), "team": "%s · %s" % [car["name"], car_colors()["name"]],
			"player": true, "times": player_times})
	for r in RIVALS:
		var times: Array[float] = []
		for j in stage_maps_done.size():
			var gold := float((get_map(stage_maps_done[j])["medals"] as Dictionary)["gold"])
			times.append(snappedf(gold * float(r["pace"][stage_index[j]]), 0.001))
		rows.append({"name": r["name"], "name_jp": r["name_jp"], "team": r["team"], "player": false, "times": times})
	for row in rows:
		var total := 0.0
		for t in row["times"]:
			total += t
		row["total"] = total
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["total"] < b["total"])
	for row in rows:
		row["gap"] = float(row["total"]) - float(rows[0]["total"])
	return rows


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
	if m.is_empty() or not m.has("medals"):
		return ""
	var medals: Dictionary = m["medals"]
	if t <= medals["gold"]:
		return "gold"
	if t <= medals["silver"]:
		return "silver"
	if t <= medals["bronze"]:
		return "bronze"
	return ""


## Lap time a rival is set to on a stage: its "pace" on that campaign stage times the stage's gold
## (a race's field).
func rival_lap_time(rival: Dictionary, stage_id: String) -> float:
	var k := 0
	for leg in CAMPAIGN:
		if leg["kind"] == "stage":
			if leg["map"] == stage_id:
				return float((get_map(stage_id)["medals"] as Dictionary)["gold"]) * float(rival["pace"][k])
			k += 1
	return INF


func car_colors() -> Dictionary:
	return CAR_COLORS[clampi(int(settings["car_color"]), 0, CAR_COLORS.size() - 1)]


func get_car(id: String) -> Dictionary:
	for c in CARS:
		if c["id"] == id:
			return c
	return CARS[0]


func current_car() -> Dictionary:
	return get_car(str(get_setting("car_id")))


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
	# The engine's built-in ui_accept / ui_cancel are keyboard-only (Enter/Space, Escape):
	# without these a gamepad moves menu focus but cannot press a button or back out.
	for pair: Array in [["ui_accept", JOY_BUTTON_A], ["ui_cancel", JOY_BUTTON_B]]:
		var jb := InputEventJoypadButton.new()
		jb.button_index = pair[1]
		if not InputMap.action_has_event(pair[0], jb):
			InputMap.action_add_event(pair[0], jb)


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
	var results: Variant = cfg.get_value("campaign", "results", {})
	_campaign = {
		"leg": clampi(int(cfg.get_value("campaign", "leg", 0)), 0, CAMPAIGN.size()),
		"results": results if results is Dictionary else {},
		"finished": bool(cfg.get_value("campaign", "finished", false)),
	}


func _save() -> void:
	if not persistent:
		return
	var cfg := ConfigFile.new()
	for key in settings.keys():
		cfg.set_value("settings", key, settings[key])
	for id in records.keys():
		cfg.set_value("records", id, records[id])
	for key in _campaign.keys():
		cfg.set_value("campaign", key, _campaign[key])
	cfg.save(SAVE_PATH)


## A player launch opens a 16:9 window on 80 % of the usable screen: the project's 1600x900
## window size is in pixels, which is a small window on a Retina display. Tool runs and the
## UI preview keep the sizes they set.
func _fit_window() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var area := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen())
	var k := minf(area.size.x / 16.0, area.size.y / 9.0) * 0.8
	var win_size := Vector2i(roundi(16.0 * k), roundi(9.0 * k))
	DisplayServer.window_set_size(win_size)
	DisplayServer.window_set_position(area.position + (area.size - win_size) / 2)


func _apply_window_settings() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var fs: bool = settings.get("fullscreen", false)
	var want := DisplayServer.WINDOW_MODE_FULLSCREEN if fs else DisplayServer.WINDOW_MODE_WINDOWED
	if DisplayServer.window_get_mode() != want:
		DisplayServer.window_set_mode(want)
