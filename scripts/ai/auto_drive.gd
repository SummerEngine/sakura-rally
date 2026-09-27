class_name AutoDrive
extends Node
## The trained neural driver in the game (docs/RL.md). Lives under Main (one line in
## Main._ready) and reads Main's `car`, `map` and `chase`:
##
##   I  auto-drive: the driver (a NeuralPilot with DRIVER) takes the player's car on a stage, the
##      liaison or free roam and gives it back when pressed again. The game's own takeovers
##      (the finish stop, the liaison arrival) still win.
##   G  ghosts: the training generations (GENERATIONS_DIR, one DrivePolicy file each, oldest
##      first) join as ghost cars side by side just behind the player: no collisions (cars never
##      collide), their own liveries, a label over each. A new stage brings them back on its grid.
##   V  watch: the chase camera goes to the next ghost, and back to the player's car.
##
## Letters, not F-keys: on a Mac keyboard F7-F12 are media keys that never reach the game.
## Command line (after --): `auto-drive` and `ghosts` switch those on from the start,
## `policy=<file>` drives with another policy file.
## A driven car that leaves the road (or stops making progress) for RESCUE_S is put back on it,
## as the player would with the reset key, which also works while the driver has the car.

## The driver shipped with the game.
const DRIVER := "res://assets/ai/driver.json"
const GENERATIONS_DIR := "res://assets/ai/generations"
const RESCUE_S := 2.5
const OFF_ROAD_M := 3.0
const GHOST_LIVERIES: Array[Color] = [Color("7fc8f8"), Color("f9a03f"), Color("b388eb"), Color("5fd3a2"),
		Color("f25f5c"), Color("ffe066")]

var auto_drive: bool = false
var ghosts_on: bool = false
var policy: DrivePolicy
## The ghost cars on the road now (G), oldest generation first.
var ghosts: Array[Car] = []
## The ghost the chase camera follows (V); -1: the player's car.
var watching: int = -1
## Times the player's car was put back on the road while the driver had it.
var rescues: int = 0

var _pilot: NeuralPilot
var _took_car: bool = false
var _ghosts_for: Car
## Per driven car (instance id): [seconds in trouble, last road distance].
var _trouble: Dictionary = {}
var _state: int = -1


func _init() -> void:
	name = "AutoDrive"


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for arg in args:
		if arg.begins_with("policy="):
			policy = DrivePolicy.load_file(arg.trim_prefix("policy="))
	if policy == null and FileAccess.file_exists(DRIVER):
		policy = DrivePolicy.load_file(DRIVER)
	auto_drive = policy != null and args.has("auto-drive")
	ghosts_on = args.has("ghosts")


func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	match key.physical_keycode:
		KEY_I:
			if policy == null:
				Game.post_notice("No trained driver in this build")
				return
			auto_drive = not auto_drive
			if not auto_drive and _pilot != null:
				_detach(true)
			if auto_drive and _campaign_stage():
				Game.post_notice("The AI driver sits out campaign stages")
			else:
				Game.post_notice("AI driving" if auto_drive else "You drive")
		KEY_G:
			ghosts_on = not ghosts_on
			if not ghosts_on:
				_clear_ghosts()
			Game.post_notice("AI ghosts on" if ghosts_on else "AI ghosts off")
		KEY_V:
			watch_next()
		_:
			return
	get_viewport().set_input_as_handled()


func _physics_process(delta: float) -> void:
	if Game.state != _state:
		_state = Game.state
		if _state == Game.State.COUNTDOWN:
			Game.ai_drove = false # a new run
	var main := get_parent()
	var car: Car = main.car if main.car != null and is_instance_valid(main.car) else null
	var track: Track = main.map.track if main.map != null else null
	var drivable := car != null and track != null and _drivable_state() and not car.has_node(^"ArrivalStop")

	if auto_drive and drivable and not _campaign_stage():
		if _pilot == null or _pilot.car != car:
			_detach(false)
			_pilot = _make_pilot(policy, track, 0)
			car.add_child(_pilot)
		elif _pilot.track != track:
			_pilot.track = track
		if car.controlled_by_player:
			car.controlled_by_player = false
			_took_car = true
		if Game.state in [Game.State.COUNTDOWN, Game.State.RACING]:
			Game.ai_drove = true # this run sets no record or medal (Game.notify_finished)
		if Input.is_action_just_pressed(&"reset_car") and not car.launch_hold:
			car.reset_to_track()
		if _rescue(car, _pilot, delta):
			rescues += 1
	elif _pilot != null:
		_detach(false)

	if _ghosts_for != null and (car != _ghosts_for or not is_instance_valid(_ghosts_for)):
		_clear_ghosts()
	if ghosts_on and drivable and ghosts.is_empty():
		_spawn_ghosts(car, track)
	for ghost in ghosts:
		var pilot := ghost.get_node(^"NeuralPilot") as NeuralPilot
		if pilot.track != track:
			pilot.track = track
		_rescue(ghost, pilot, delta)


func _drivable_state() -> bool:
	return Game.state in [Game.State.COUNTDOWN, Game.State.RACING, Game.State.FREE_ROAM, Game.State.LIAISON]


## A timed campaign stage: its result feeds the rally classification, so the AI never drives it.
func _campaign_stage() -> bool:
	return Game.campaign_current_leg().get("kind", "") == "stage"


## `phase`: the player's pilot 0, the ghosts 1, 2, ... (NeuralPilot.phase).
func _make_pilot(p: DrivePolicy, track: Track, phase: int) -> NeuralPilot:
	var pilot := NeuralPilot.new()
	pilot.name = "NeuralPilot"
	pilot.policy = p
	pilot.track = track
	pilot.phase = phase
	return pilot


## Hands the car back: to the player when auto-drive was switched off with the car on the road,
## to nobody when the game is taking it over (finish stop, arrival) or it is gone.
func _detach(to_player: bool) -> void:
	if _pilot != null and is_instance_valid(_pilot):
		var car := _pilot.car
		_pilot.queue_free()
		if to_player and _took_car and car != null and is_instance_valid(car) and not car.has_node(^"ArrivalStop"):
			car.controlled_by_player = true
	_pilot = null
	_took_car = false


## Puts a driven car back on the road after RESCUE_S off it (OFF_ROAD_M beyond the verge) or
## without progress; true when it did.
func _rescue(car: Car, pilot: NeuralPilot, delta: float) -> bool:
	if pilot == null or pilot.sense == null or pilot.sense.hint < 0 or car.launch_hold:
		return false
	var sense := pilot.sense
	var id := car.get_instance_id()
	var st: Array = _trouble.get(id, [0.0, NAN])
	var pos := car.global_position
	var s := sense.road_s(pos)
	var ds := 0.0 if is_nan(st[1]) else s - float(st[1])
	if sense.track.closed:
		ds = wrapf(ds, -sense.track.length * 0.5, sense.track.length * 0.5)
	st[1] = s
	var off := absf(sense.road_lateral(pos)) > sense.road_edge() + OFF_ROAD_M
	var stuck := ds < 0.05 * delta * 60.0 and Game.state != Game.State.COUNTDOWN
	st[0] = st[0] + delta if off or stuck else 0.0
	var rescued: bool = st[0] > RESCUE_S
	if rescued:
		st[0] = 0.0
		st[1] = NAN
		car.reset_to_track()
	_trouble[id] = st
	return rescued


## One ghost per generation file, side by side across the road 12 m behind `car`.
func _spawn_ghosts(car: Car, track: Track) -> void:
	_ghosts_for = car
	var files := _generation_files()
	if files.is_empty():
		Game.post_notice("No AI generations in this build")
		ghosts_on = false
		return
	var s := track.abs_s(track.nearest(car.global_position), car.global_position) - 12.0
	var scene := load(str(Game.current_car()["scene"])) as PackedScene
	for i in files.size():
		var p := DrivePolicy.load_file(files[i])
		if p == null:
			continue
		var ghost := scene.instantiate() as Car
		ghost.name = "Ghost%d" % i
		ghost.controlled_by_player = false
		var mute := Node.new()
		mute.name = "CarAudio"
		ghost.add_child(mute)
		ghost.add_child(_make_pilot(p, track, i + 1))
		var label := Label3D.new()
		label.name = "Label3D"
		label.text = _generation_label(p, i)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.fixed_size = true
		label.pixel_size = 0.0012
		label.font_size = 28
		label.outline_size = 8
		label.position = Vector3(0.0, 2.1, 0.0)
		label.no_depth_test = true
		ghost.add_child(label)
		get_parent().add_child(ghost)
		var c := GHOST_LIVERIES[i % GHOST_LIVERIES.size()]
		ghost.set_livery(c, c.darkened(0.45))
		CarLook.apply(ghost)
		var lat := (float(i) - (files.size() - 1) * 0.5) * 1.7
		ghost.place_at_rest(track.transform_at_abs(s, clampf(lat, -3.0, 3.0)))
		ghosts.append(ghost)


func _generation_files() -> PackedStringArray:
	var out := PackedStringArray()
	for f in DirAccess.get_files_at(GENERATIONS_DIR):
		if f.ends_with(".json"):
			out.append(GENERATIONS_DIR.path_join(f))
	out.sort()
	return out


func _generation_label(p: DrivePolicy, i: int) -> String:
	var steps := float(p.meta.get("steps", 0))
	return "AI gen %d · %s" % [i + 1, ("%.1fM" % (steps / 1e6)) if steps >= 1e6 else ("%dk" % int(steps / 1e3))]


func _clear_ghosts() -> void:
	var main := get_parent()
	if main.chase.target in ghosts and main.car != null and is_instance_valid(main.car):
		main.chase.target = main.car
	for ghost in ghosts:
		if is_instance_valid(ghost):
			_trouble.erase(ghost.get_instance_id())
			ghost.queue_free()
	ghosts.clear()
	_ghosts_for = null
	watching = -1


## Chase camera to the next ghost, after the last one back to the player's car.
func watch_next() -> void:
	var main := get_parent()
	if ghosts.is_empty() or main.car == null:
		watching = -1
		return
	watching = watching + 1 if watching + 1 < ghosts.size() else -1
	main.chase.target = main.car if watching < 0 else ghosts[watching]
	main.chase.snap()
	var label := ghosts[watching].get_node(^"Label3D") as Label3D if watching >= 0 else null
	Game.post_notice("Watching %s" % (label.text if label != null else "your car"))
