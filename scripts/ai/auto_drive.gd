class_name AutoDrive
extends Node
## The trained neural driver in the game (docs/RL.md). Lives under Main (one line in
## Main._ready) and reads Main's `car`, `map`, `chase`, `ui` and, in a race, `race` and `rivals`:
##
##   I  auto-drive: the driver (a NeuralPilot with DRIVER) takes the player's car in Time Attack,
##      the liaison or free roam and gives it back when pressed again. A Time Attack run it drove
##      any part of sets no record or medal (Game.ai_drove); campaign stages, which count for the
##      rally classification, it sits out. The game's own takeovers (the finish stop, the liaison
##      arrival) still win. In free roam it keeps to the road the car is on, the way the car goes
##      (below). In a race (Main.race) it is a RaceBot among the rivals instead: it sees their
##      cars, passes them and rescues itself, at the free driver's own speed (RACE_PACE).
##   G  ghosts: the training generations (GENERATIONS_DIR, one DrivePolicy file each, oldest
##      first) join as ghost cars on a staggered grid behind the player, held on the line with the
##      player's car through the countdown: on no collision layer (a car with `car_contacts` on
##      drives through them too), their own
##      liveries, a label over each. They leave the soft course alone (group `ghost_car`: no
##      smashed tape or cones, no knocked spectators, no course restore in the player's run),
##      park at the end of an open road, and every new run (a new car or a countdown) puts them
##      back on its grid.
##   V  watch: the chase camera goes to the next ghost, and back to the player's car.
##   O  the pixel driver (docs/PIXELS.md): a PixelPilot, which drives from the picture of a hood
##      camera (PIXEL_DRIVER, a PixelPolicy on the GPU), takes the car as I's driver does and
##      under the same rules; I or O while the other drives swaps drivers. In a race, where the
##      pixel driver would meet cars it never saw, I's RaceBot drives instead.
##
## Letters, not F-keys: on a Mac keyboard F7-F12 are media keys that never reach the game.
## Command line (after --): `auto-drive`, `pixel-drive` and `ghosts` switch those on from the
## start, `policy=<file>` drives with another policy file.
## A driven car that leaves the road (or stops making progress) for RESCUE_S is put back on it:
## the player's car as with the reset key (which also works while the driver has it), a ghost on
## its own road; a RaceBot does this itself, clear of the other cars.
## Free roam has no wrong way. The driver takes a road the way the car goes, when it takes the car
## and when the car reaches another road (the route's track, or the same road reversed:
## DriveSense.reversed_road), and a car that travels against its road for FLIP_S (after a spin,
## the pixel driver turning onto a loop the other way round) drives it the other way from then on.
## Progress, the rescue and the reset key follow that way; the car's own reset (RaceSession's,
## which faces the route's way) waits while the driver has the car.

## The driver shipped with the game.
const DRIVER := "res://assets/ai/driver.json"
const GENERATIONS_DIR := "res://assets/ai/generations"
## The pixel driver: tools/rl_pixels/train_pixels.py's export, loaded on first use (O).
const PIXEL_DRIVER := "res://assets/ai/pixel_driver.json"
const RESCUE_S := 2.5
const OFF_ROAD_M := 3.0
## Free roam: a car moving faster than FLIP_MPS against its road for FLIP_S drives it the other way.
const FLIP_MPS := 3.0
const FLIP_S := 0.5
## Pace of the player's RaceBot in a race: no limit, the free driver's own speed.
const RACE_PACE := INF
## The last stretch of an open road: the road ahead a car sees shrinks onto the end there and it
## only creeps, so a ghost parks and the player's car in free roam looks for the next road.
const ROAD_END_M := 15.0
const GHOST_LIVERIES: Array[Color] = [Color("7fc8f8"), Color("f9a03f"), Color("b388eb"), Color("5fd3a2"),
		Color("f25f5c"), Color("ffe066")]
## Ghost grid (_spawn_ghosts): first slot GRID_BACK_M behind the car, each next one GRID_GAP_M
## further, alternating GRID_LAT_M left and right of the centre line.
const GRID_BACK_M := 12.0
const GRID_GAP_M := 7.0
const GRID_LAT_M := 1.6
## A ghost's label fades out beyond LABEL_RANGE_M from the camera: the labels keep their size and
## draw through hills, so the tags of ghosts far down the road piled up into one smear.
const LABEL_RANGE_M := 80.0
## While the pixel driver has the player's car, its view in the bottom-left corner (the HUD leaves
## it free): the eyes' picture VIEW_SCALE times, nearest-neighbour, redrawn at every decision, on
## a canvas layer under the HUD and the menus and above the colour grade, so it shows the frame
## as the network gets it. It hides with the UI (F1, Main's `ui`).
const VIEW_SCALE := 3
const VIEW_LAYER := 9
const VIEW_EDGE := Vector2(56, 44)
const UITheme := preload("res://scripts/ui/ui_theme.gd")

var auto_drive: bool = false
var ghosts_on: bool = false
var policy: DrivePolicy
## The pixel driver once loaded (null: not yet, or it cannot run here); auto-drive uses it when
## `pixels`.
var pixel_driver: PixelPolicy
var pixels: bool = false
## The ghost cars on the road now (G), oldest generation first.
var ghosts: Array[Car] = []
## The ghost the chase camera follows (V); -1: the player's car.
var watching: int = -1
## Times the player's car was put back on the road while the driver had it.
var rescues: int = 0

var _pilot: NeuralPilot
var _took_car: bool = false
var _ghosts_for: Car
## Per driven car (instance id): [seconds in trouble, last road distance, seconds against its road].
var _trouble: Dictionary = {}
## Free roam's reversed roads: a route's track -> the same road reversed (made once), and back.
var _reversed: Dictionary = {}
var _route_of: Dictionary = {}
## The player's car's auto_reset_time while the driver holds it in free roam (NAN: not held).
var _car_reset: float = NAN
## Game.state at the last physics tick: entering COUNTDOWN starts a new run (clears ai_drove).
var _state: int = -1
var _pixel_tried: bool = false
var _view: CanvasLayer


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
	if args.has("pixel-drive") and _load_pixel_driver() != null:
		auto_drive = true
		pixels = true
	ghosts_on = args.has("ghosts")


## The pixel driver's GPU buffers go with the node that owns them (PixelPolicy.release). The car
## and its PixelPilot are Main's later children and leave the tree first.
func _exit_tree() -> void:
	if pixel_driver != null:
		pixel_driver.release()
		pixel_driver = null
	_pixel_tried = false


func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	match key.physical_keycode:
		KEY_I:
			_toggle(false)
		KEY_O:
			_toggle(true)
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
	var new_run := false
	if Game.state != _state:
		_state = Game.state
		if _state == Game.State.COUNTDOWN:
			Game.ai_drove = false # a new run
			new_run = true
	var main := get_parent()
	var car: Car = main.car if main.car != null and is_instance_valid(main.car) else null
	var track: Track = main.map.track if main.map != null else null
	var drivable := car != null and track != null and _drivable_state() and not car.has_node(^"ArrivalStop")
	var free_roam := Game.state == Game.State.FREE_ROAM
	if _view != null:
		_view.visible = main.ui == null or main.ui.visible

	if auto_drive and drivable and not _campaign_stage():
		var race: Variant = main.get(&"race") # Main's RaceField, null outside a race
		var from_pixels := pixels and race == null
		if _pilot == null or _pilot.car != car or (_pilot is RaceBot) != (race != null) \
				or (_pilot is PixelPilot) != from_pixels:
			# another driver for the same car keeps it taken: switching off still hands it back
			var took := _took_car and _pilot != null and _pilot.car == car
			_detach(false)
			_took_car = took
			if race != null:
				_pilot = _make_race_bot(race, track, main.rivals.size())
			else:
				var road := _free_road(car, _road_under(car, track)) if free_roam else track
				_pilot = _make_pixel_pilot(road) if from_pixels else _make_pilot(policy, road, 0)
			car.add_child(_pilot)
			if _pilot is PixelPilot:
				_show_view(_pilot as PixelPilot)
		elif not free_roam and _pilot.track != track:
			_pilot.track = track
		if car.controlled_by_player:
			car.controlled_by_player = false
			_took_car = true
		_hold_car_reset(car, free_roam)
		if Game.state in [Game.State.COUNTDOWN, Game.State.RACING]:
			Game.ai_drove = true # this run sets no record or medal (Game.notify_finished)
		if Input.is_action_just_pressed(&"reset_car") and not car.launch_hold:
			_reset_player(car, _pilot)
		if _rescue(car, _pilot, delta):
			rescues += 1
	elif _pilot != null:
		_detach(false)

	# Ghosts belong to one car and one run: a new car (retry, next map, the title, the finale) or
	# a new countdown (the campaign's next stage keeps the car) clears them, and they come back on
	# the new grid. `_ghosts_for != null` is no test: a freed car compares equal to null.
	if not ghosts.is_empty() and (new_run or car != _ghosts_for or not is_instance_valid(_ghosts_for)):
		_clear_ghosts()
	if ghosts_on and drivable and ghosts.is_empty():
		var road := track
		if _pilot != null:
			road = _pilot.track
		elif free_roam:
			road = _free_road(car, _road_under(car, track))
		_spawn_ghosts(car, road)
	for ghost in ghosts: # ghosts exist only for a live `car` (_ghosts_for)
		var pilot := ghost.get_node(^"NeuralPilot") as NeuralPilot
		# on the line with the player through the countdown, parked at the end of an open road
		ghost.launch_hold = car.launch_hold or _road_done(ghost, pilot)
		_rescue(ghost, pilot, delta)


## I (the driver) and O (the pixel driver): a key takes the car, the same key again gives it back,
## the other key hands it to the other driver.
func _toggle(from_pixels: bool) -> void:
	if from_pixels and _load_pixel_driver() == null:
		Game.post_notice("No pixel driver in this build" if not FileAccess.file_exists(PIXEL_DRIVER)
				else "The pixel driver needs the Forward+ or Mobile renderer")
		return
	if not from_pixels and policy == null:
		Game.post_notice("No trained driver in this build")
		return
	var on := not (auto_drive and pixels == from_pixels)
	auto_drive = on
	pixels = from_pixels
	if not on and _pilot != null:
		_detach(true)
	var who := "AI driving from pixels" if pixels else "AI driving"
	if on and _campaign_stage():
		Game.post_notice("The AI driver sits out campaign stages")
	elif on and pixels and get_parent().get(&"race") != null:
		Game.post_notice("The pixel driver does not race: the AI driver takes the car")
	elif on and Game.mode == Game.MODE_TIME_TRIAL:
		Game.post_notice(who + ": this run sets no record")
	else:
		Game.post_notice(who if on else "You drive")


## The pixel driver, loaded the first time it is asked for; null when this build has none or
## cannot run it (it needs a RenderingDevice).
func _load_pixel_driver() -> PixelPolicy:
	if pixel_driver == null and not _pixel_tried:
		_pixel_tried = true
		if FileAccess.file_exists(PIXEL_DRIVER):
			pixel_driver = PixelPolicy.load_file(PIXEL_DRIVER)
		if pixel_driver != null and not pixel_driver.check_error <= 1e-3:
			push_warning("AutoDrive: the pixel driver's GPU logits differ from torch's by %s" % pixel_driver.check_error)
	return pixel_driver


func _drivable_state() -> bool:
	return Game.state in [Game.State.COUNTDOWN, Game.State.RACING, Game.State.FREE_ROAM, Game.State.LIAISON]


## A timed campaign stage: its result feeds the rally classification, so the AI never drives it.
func _campaign_stage() -> bool:
	return Game.campaign_current_leg().get("kind", "") == "stage"


## Free roam, where every road of the world is open: the route whose road is nearest the car
## (as RaceSession finds it for a reset), other than `exclude`; `fallback` when there is none.
func _road_under(car: Car, fallback: Track, exclude: Track = null) -> Track:
	var pos := car.global_position
	var best := fallback
	var best_d := INF
	for r: Dictionary in get_parent().map.routes.values():
		var t: Track = r["track"]
		if t == exclude:
			continue
		var d := pos.distance_squared_to(t.point(t.nearest(pos)))
		if d < best_d:
			best_d = d
			best = t
	return best


## Free roam: road `route` (a route's track) the way the car goes: that track, or the same road
## reversed when the car moves (nearly still: points) against it.
func _free_road(car: Car, route: Track) -> Track:
	var v := car.linear_velocity
	var dir := v if v.length() > FLIP_MPS else -car.global_basis.z
	return route if route.forward(route.nearest(car.global_position)).dot(dir) >= 0.0 else _twin(route)


## The same road the other way: a route's track reversed, or a reversed road's route track.
func _twin(t: Track) -> Track:
	if _route_of.has(t):
		return _route_of[t]
	if not _reversed.has(t):
		var r := DriveSense.reversed_road(t)
		_reversed[t] = r
		_route_of[r] = t
	return _reversed[t]


## The route track of road `t` (itself unless it is a reversed road).
func _route_road(t: Track) -> Track:
	return _route_of.get(t, t)


## Free roam: the car's own reset (RaceSession's, facing the route's way) waits while the driver
## has the car; the rescue, which knows the way the car drives, puts it back instead.
func _hold_car_reset(car: Car, hold: bool) -> void:
	if hold and is_nan(_car_reset):
		_car_reset = car.auto_reset_time
		car.auto_reset_time = INF
	elif not hold and not is_nan(_car_reset):
		car.auto_reset_time = _car_reset
		_car_reset = NAN


## The player's car back on the road as the reset key puts it (RaceSession: in a time trial the
## last point legitimately reached, facing the route's way); in free roam on the driver's own
## road, facing the way it drives.
func _reset_player(car: Car, pilot: NeuralPilot) -> void:
	var sense := pilot.sense
	if Game.state == Game.State.FREE_ROAM and not (pilot is RaceBot) and sense != null and sense.hint >= 0:
		car.reset_to(sense.track.transform_at_abs(sense.road_s(car.global_position) - 4.0, 0.0, 0.35))
	else:
		car.reset_to_track()


## A ghost at the end of an open road has no road left to drive: it parks there.
func _road_done(ghost: Car, pilot: NeuralPilot) -> bool:
	var t := pilot.track
	return not t.closed and pilot.sense != null and pilot.sense.hint >= 0 \
			and pilot.sense.road_s(ghost.global_position) >= t.length - ROAD_END_M


## True when `pos` is on road t: within its drivable half width plus OFF_ROAD_M, near its height.
func _on_road(t: Track, pos: Vector3) -> bool:
	var i := t.nearest(pos)
	return absf(t.lateral(i, pos)) < t.half_width(i) + t.verge + OFF_ROAD_M and absf(pos.y - t.point(i).y) < 4.0


## `phase`: the player's pilot 0, the ghosts 1, 2, ... (NeuralPilot.phase).
func _make_pilot(p: DrivePolicy, track: Track, phase: int) -> NeuralPilot:
	var pilot := NeuralPilot.new()
	pilot.name = "NeuralPilot"
	pilot.policy = p
	pilot.track = track
	pilot.phase = phase
	return pilot


func _make_pixel_pilot(track: Track) -> PixelPilot:
	var pilot := PixelPilot.new()
	pilot.name = "PixelPilot"
	pilot.pixels = pixel_driver
	pilot.track = track
	return pilot


## The pixel driver's view in its corner (VIEW_SCALE and the rest above).
func _show_view(pilot: PixelPilot) -> void:
	_hide_view()
	var caption := Label.new()
	caption.text = "What the AI sees: %d×%d pixels" % [DriveEyes.SIZE.x, DriveEyes.SIZE.y]
	caption.add_theme_font_override(&"font", UITheme.FONT_UI_BOLD)
	caption.add_theme_font_size_override(&"font_size", 17)
	caption.add_theme_color_override(&"font_color", UITheme.INK)
	var pic := TextureRect.new()
	pic.texture = pilot.eyes.viewport.get_texture()
	pic.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pic.custom_minimum_size = Vector2(DriveEyes.SIZE * VIEW_SCALE)
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 6)
	box.add_child(caption)
	box.add_child(pic)
	var style := StyleBoxFlat.new()
	style.bg_color = UITheme.PAPER
	style.set_corner_radius_all(10)
	style.set_content_margin_all(8.0)
	style.shadow_color = Color(UITheme.INK, 0.18)
	style.shadow_size = 6
	var card := PanelContainer.new()
	card.add_theme_stylebox_override(&"panel", style)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(box)
	# pinned by its bottom-left corner: it grows up and right to its content
	card.anchor_top = 1.0
	card.anchor_bottom = 1.0
	card.offset_left = VIEW_EDGE.x
	card.offset_right = VIEW_EDGE.x
	card.offset_top = -VIEW_EDGE.y
	card.offset_bottom = -VIEW_EDGE.y
	card.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_view = CanvasLayer.new()
	_view.name = "PixelView"
	_view.layer = VIEW_LAYER
	_view.add_child(card)
	add_child(_view)


func _hide_view() -> void:
	if _view != null and is_instance_valid(_view):
		remove_child(_view) # at once: the picture's viewport leaves with its pilot
		_view.queue_free()
	_view = null


## The player's driver in a race: a RaceBot among every entrant's car (the player's first), on
## a phase of its own after the rivals' (0 .. rivals - 1).
func _make_race_bot(race: Variant, track: Track, phase: int) -> RaceBot:
	var bot := RaceBot.new()
	bot.name = "RaceBot"
	bot.policy = policy
	bot.track = track
	bot.pace = RACE_PACE
	bot.phase = phase
	var field: Array[Car] = []
	for e in race.entrants:
		field.append(e.car)
	bot.field = field
	return bot


## Hands the car back: to the player when auto-drive was switched off with the car on the road,
## to nobody when the game is taking it over (finish stop, arrival) or it is gone.
func _detach(to_player: bool) -> void:
	if _pilot != null and is_instance_valid(_pilot):
		var car := _pilot.car
		# out of the tree at once: it lets go of the car (NeuralPilot._exit_tree) before the next
		# pilot takes it, not at the end of the frame
		if _pilot.get_parent() != null:
			_pilot.get_parent().remove_child(_pilot)
		_pilot.queue_free()
		if to_player and _took_car and car != null and is_instance_valid(car) and not car.has_node(^"ArrivalStop"):
			car.controlled_by_player = true
		if car != null and is_instance_valid(car):
			_hold_car_reset(car, false)
	_car_reset = NAN
	_pilot = null
	_took_car = false
	_hide_view()


## Puts a driven car back on the road after RESCUE_S off it (OFF_ROAD_M beyond the verge) or
## without progress; true when it did. The player's car goes where the reset key would put it
## (_reset_player); a ghost goes back on its own road, so it neither lands next to the player nor
## touches the player's session. A RaceBot rescues its car itself.
func _rescue(car: Car, pilot: NeuralPilot, delta: float) -> bool:
	if pilot == null or pilot is RaceBot or pilot.sense == null or pilot.sense.hint < 0 or car.launch_hold:
		return false
	var sense := pilot.sense
	var id := car.get_instance_id()
	var st: Array = _trouble.get(id, [0.0, NAN, 0.0])
	var pos := car.global_position
	var s := sense.road_s(pos)
	var ds := 0.0 if is_nan(st[1]) else s - float(st[1])
	if sense.track.closed:
		ds = wrapf(ds, -sense.track.length * 0.5, sense.track.length * 0.5)
	st[1] = s
	var off := absf(sense.road_lateral(pos)) > sense.road_edge() + OFF_ROAD_M
	var players: bool = car == get_parent().car
	if players and Game.state == Game.State.FREE_ROAM:
		# Every road of the world is open: once the player's car is on another road (off this one,
		# or at the end of an open road) it drives that one, the way the car goes. A ghost keeps to
		# its own road and parks at its end.
		var here := _route_road(sense.track)
		if off or (not sense.track.closed and s >= sense.track.length - ROAD_END_M):
			var road := _road_under(car, here, here)
			if road != here and _on_road(road, pos):
				pilot.track = _free_road(car, road)
				_trouble.erase(id)
				return false
		# No wrong way either: a car travelling against its road drives it the other way.
		var v := car.linear_velocity
		var against := v.length() > FLIP_MPS and sense.track.forward(sense.hint).dot(v.normalized()) < -0.5
		st[2] = st[2] + delta if against else 0.0
		if st[2] > FLIP_S:
			pilot.track = _twin(sense.track)
			_trouble.erase(id)
			return false
	var stuck := ds < 0.05 * delta * 60.0 and Game.state != Game.State.COUNTDOWN
	st[0] = st[0] + delta if off or stuck else 0.0
	var rescued: bool = st[0] > RESCUE_S
	if rescued:
		st[0] = 0.0
		st[1] = NAN
		if players:
			_reset_player(car, pilot)
		else:
			car.reset_to(sense.track.transform_at_abs(s - 4.0, 0.0, 0.35))
	_trouble[id] = st
	return rescued


## One ghost per generation file on a staggered two-column grid behind `car` on `track`, oldest
## nearest (cars never collide, the grid only keeps them apart on screen). At the start of an
## open road, where there is no road behind, the grid lines up ahead instead.
func _spawn_ghosts(car: Car, track: Track) -> void:
	_ghosts_for = car
	var files := _generation_files()
	if files.is_empty():
		Game.post_notice("No AI generations in this build")
		ghosts_on = false
		return
	var s := track.abs_s(track.nearest(car.global_position), car.global_position)
	var scene := load(str(Game.current_car()["scene"])) as PackedScene
	for i in files.size():
		var p := DrivePolicy.load_file(files[i])
		if p == null:
			continue
		var ghost := scene.instantiate() as Car
		ghost.name = "Ghost%d" % i
		ghost.controlled_by_player = false
		ghost.auto_reset_time = INF # AutoDrive rescues ghosts; the car's own reset asks the player's session
		ghost.add_to_group(&"ghost_car") # before add_child: SoftCourse looks when the car is ready
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
		label.layers = DriveEyes.GAME_ONLY_LAYER
		label.visibility_range_end = LABEL_RANGE_M
		label.visibility_range_end_margin = 20.0
		label.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		ghost.add_child(label)
		get_parent().add_child(ghost)
		ghost.collision_layer = 0 # after _ready (which puts every car on layer 2): nothing hits a ghost
		var c := GHOST_LIVERIES[i % GHOST_LIVERIES.size()]
		ghost.set_livery(c, c.darkened(0.45))
		CarLook.apply(ghost)
		var back := GRID_BACK_M + i * GRID_GAP_M
		var gs := s - back if track.closed or s - back >= track.first_s else s + back
		ghost.place_at_rest(track.transform_at_abs(gs, -GRID_LAT_M if i % 2 == 0 else GRID_LAT_M))
		ghosts.append(ghost)
	if ghosts.is_empty():
		Game.post_notice("The AI generations in this build do not load")
		ghosts_on = false


func _generation_files() -> PackedStringArray:
	var out := PackedStringArray()
	for f in DirAccess.get_files_at(GENERATIONS_DIR):
		if f.ends_with(".json"):
			out.append(GENERATIONS_DIR.path_join(f))
	out.sort()
	return out


func _generation_label(p: DrivePolicy, i: int) -> String:
	var steps := float(p.meta.get("steps", 0))
	var age := "untrained" if steps <= 0.0 else ("%.1fM" % (steps / 1e6)) if steps >= 1e6 else ("%dk" % int(steps / 1e3))
	return "AI gen %d · %s" % [i + 1, age]


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
