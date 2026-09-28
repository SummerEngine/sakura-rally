extends Node
## Main scene: owns the world, the car, the cameras, the screen passes and the UI layer, and
## drives the game state (docs/CONTRACTS.md, docs/UI.md). The world (MapWorld, one pack) is
## built once behind the boot cover and kept; every drive selects a route of it
## (`MapWorld.select_route`: `hanami`, `momiji`, `liaison`).
##
##   BOOT -> MENU        an autopilot car laps the Hanami loop under the flyover camera behind
##                       the title screen
##   start -> LOADING    ink covers the screen while the car is placed at rest on the grid
##   -> INTRO            camera swoop onto the car, letterboxed
##   -> COUNTDOWN        (time trial, race) the car is held in neutral, throttle revs it
##   -> RACING / FREE_ROAM
##   -> FINISHED         slow-motion beat; the car is brought to rest at the route's finish
##                       stop while the camera orbits it behind the results card
##
## A race (Game.MODE_RACE) puts the six rivals (Game.RIVALS) on a grid ahead of the player's car,
## slowest on pole, each driven by a RaceBot at its lap time for the stage; every car collides with
## the others (Car.car_contacts) and a RaceField times them all. Past the line the finishers come
## to rest one behind the other in finishing order (the winner on the finish stop).
##
## Time trials and races keep the branch gates closed; free roam opens them. The campaign
## (Game.CAMPAIGN) is one continuous drive with no cover between legs:
##
##   SS1 (INTRO, COUNTDOWN, RACING, FINISHED at Hanami's finish stop, results)
##   -> Continue         the hanami_branch gate opens in view over the resting car (short beat)
##   -> LIAISON          the player drives on from where he stopped, route `liaison`
##   -> ARRIVED          near Momiji's grid the car is taken over and brought to rest there; the
##                       arrival card asks to start SS2 (or quit to the title)
##   -> Start SS2        INTRO, COUNTDOWN: SS2's start card and countdown on the spot
##   -> SS2 ... FINISHED at Momiji's finish stop, results
##   -> Continue         (ink) FINALE: classification over a flyover of the Momiji loop
##
## The title's Campaign resumes at the saved leg: SS1 on the Hanami grid, the liaison at Hanami's
## finish stop with the gate open, SS2 on the Momiji grid.
##
## Every flow captures `_run`; a newer request bumps it and older flows stop at their
## next await.

signal world_ready

const UI_ROOT := preload("res://scenes/ui/ui_root.tscn")
const UITheme := preload("res://scripts/ui/ui_theme.gd")
const INTRO_TIME := 3.4
## Route of the title flyover (a closed loop) and the route the world is built with.
const MENU_MAP := "hanami"
const FINISH_SLOWMO := 0.3
## Minimum time the loading card stays up: its brush animation plays, first-use shaders
## compile and the placed car settles on its springs behind the ink.
const MIN_COVER := 0.75
## The gate beat after results Continue: the car rests, the gate opens over it, then the drive.
const GATE_LEAD := 0.5
const GATE_BEAT := 2.1
## Where the gate shot's camera ends up: this many metres short of the gate.
const GATE_CLOSE := 20.0
## Longest wait for a car still rolling to its stop (a finish stop, the next stage's grid) before
## the next leg starts anyway.
const REST_WAIT := 8.0
## Race grid: slot 0 (pole) on the route's spawn, each next slot RACE_GRID_GAP metres further
## back, alternating RACE_GRID_LAT metres left and right of the centre line.
const RACE_GRID_GAP := 5.0
const RACE_GRID_LAT := 2.2
## Race finishers come to rest PARC_GAP metres apart behind the winner on the finish stop.
const PARC_GAP := 8.0
## A rival's name tag shows within NAME_TAG_RANGE metres of the camera: the cars around you, not
## a pack further up the road, whose tags would pile up into one smear.
const NAME_TAG_RANGE := 40.0

var ui: CanvasLayer
var post: PostFX
var chase: ChaseCamera
var cine: CineCamera
## Static shot over the car at a branch gate as it opens (the Continue beat).
var gate_cam: Camera3D
var map: MapWorld
var car: Car
var fx: CarFX
var session: RaceSession
var autopilot: Autopilot
var menu_stage: MenuStage
## A race: its timing, the rivals' cars and their wheel effects (empty outside a race).
var race: RaceField
var rivals: Array[Car] = []
var rival_fx: Array[CarFX] = []

var _run: int = 0
var _busy: bool = false
var _world_built := false
var _time_tween: Tween
var _cam_tween: Tween


func _ready() -> void:
	ui = UI_ROOT.instantiate()
	add_child(ui)
	post = PostFX.new()
	post.name = "PostFX"
	add_child(post)
	chase = ChaseCamera.new()
	chase.name = "ChaseCamera"
	add_child(chase)
	cine = CineCamera.new()
	cine.name = "CineCamera"
	add_child(cine)
	gate_cam = Camera3D.new()
	gate_cam.name = "GateCamera"
	gate_cam.fov = 52.0
	gate_cam.near = 0.1
	add_child(gate_cam)
	Game.start_requested.connect(_on_start_requested)
	Game.restart_requested.connect(_on_restart_requested)
	Game.menu_requested.connect(_on_menu_requested)
	menu_stage = MenuStage.new()
	menu_stage.name = "MenuStage"
	add_child(menu_stage)
	add_child(AutoDrive.new()) # the trained AI driver: I auto-drive, G ghosts, V watch (docs/RL.md)
	Game.menu_view_changed.connect(_on_menu_view_changed)
	Game.settings_changed.connect(_on_settings_changed)
	get_window().size_changed.connect(func() -> void:
		Quality.apply_render_scale(str(Game.get_setting("quality")), get_window()))
	Game.campaign_requested.connect(_on_campaign_requested)
	Game.campaign_continue_requested.connect(_on_campaign_continue)
	ui.transition.set_loading_label("桜", "Sakura Rally")
	ui.transition.cover(0.01)
	_busy = true
	_enter_menu(MENU_MAP, _run)


func _process(_delta: float) -> void:
	var driving := car != null and (Game.state == Game.State.RACING or Game.state == Game.State.FREE_ROAM \
			or Game.state == Game.State.LIAISON)
	post.speed_target = smoothstep(115.0, 175.0, car.speed_kmh) * 0.8 if driving else 0.0
	# Liaison: within braking distance of the next stage's grid the player lets go and the car
	# is brought in to rest on it, whatever speed it arrives at.
	if Game.state == Game.State.LIAISON and not car.has_node(^"ArrivalStop") \
			and session.distance_left <= ArrivalStop.stopping_distance(car.linear_velocity.length()):
		_stop_at(map.arrival)
		var nxt := Game.campaign_leg + 1
		Game.post_notice("%s start ahead" % (Game.CAMPAIGN[nxt]["code"] if nxt > 0 and nxt < Game.CAMPAIGN.size() else "Stage"))


# ------------------------------------------------------------------ requests

func _on_start_requested(map_id: String, mode: String) -> void:
	if _busy:
		return
	Game.end_campaign_session()
	_run += 1
	var run := _run
	_busy = true
	await ui.transition_out(map_id)
	if run == _run:
		_start_race(map_id, mode, run)


func _on_restart_requested() -> void:
	if _busy or map == null:
		return
	_run += 1
	var run := _run
	_busy = true
	var route := map.route_id
	await ui.transition_out(route)
	if run == _run:
		_start_race(route, str(Game.mode), run)


func _on_menu_requested() -> void:
	if _busy:
		return
	Game.end_campaign_session()
	_run += 1
	var run := _run
	_busy = true
	await ui.transition_out()
	if run == _run:
		_enter_menu(MENU_MAP, run)


## Title "Campaign": the saved leg from its resume point (or the finale if only that is left).
func _on_campaign_requested() -> void:
	if _busy:
		return
	_run += 1
	var run := _run
	_busy = true
	var index := int(Game.campaign_status()["leg"])
	var legs := Game.CAMPAIGN
	await ui.transition_out(str(legs[index]["map"]) if index < legs.size() else "")
	if run != _run:
		return
	if index >= legs.size():
		_finale(run)
		return
	Game.notify_campaign_leg(index)
	var leg: Dictionary = legs[index]
	_start_race(leg["map"], Game.MODE_LIAISON if leg["kind"] == "liaison" else Game.MODE_TIME_TRIAL, run)


## Campaign "Continue": after a stage's results, straight on into the next leg from where the car
## stands, or (ink) into the finale after the last stage; at the arrival card on the next stage's
## grid, that stage.
func _on_campaign_continue() -> void:
	if _busy or car == null or Game.state not in [Game.State.FINISHED, Game.State.ARRIVED]:
		return
	_run += 1
	var run := _run
	_busy = true
	var index := int(Game.campaign_status()["leg"])
	if index >= Game.CAMPAIGN.size():
		await ui.transition_out()
		if run == _run:
			_finale(run)
		return
	var leg: Dictionary = Game.CAMPAIGN[index]
	if leg["kind"] == "liaison":
		_drive_on(index, run)
	else:
		_stage_here(index, run)


func _on_settings_changed() -> void:
	if Game.state == Game.State.MENU:
		menu_stage.apply_car_settings()
	elif car != null:
		var c := Game.car_colors()
		car.set_livery(c["primary"], c["secondary"])
	_apply_quality()


## Title hub pages: the garage parks the menu car on the workshop's display spot under a showroom
## orbit (MenuStage; the car switch drives cars off and in there).
func _on_menu_view_changed(view: String) -> void:
	if Game.state == Game.State.MENU:
		menu_stage.set_view(view)


# ------------------------------------------------------------------ flows

func _enter_menu(map_id: String, run: int) -> void:
	var covered_at := Time.get_ticks_msec()
	_restore_time()
	Game.set_state(Game.State.LOADING)
	_clear_car()
	cine.stop()
	await _ensure_world()
	if run != _run:
		return
	map.select_route(map_id)
	_set_gates(false, false)
	menu_stage.enter(self)
	post.letterbox_target = 0.0
	post.snap()
	await _hold_cover(covered_at)
	if run != _run:
		return
	Sound.play_music(&"menu")
	Sound.play_ambience()
	Sound.set_backdrop_mix(true, 0.01)
	Game.set_state(Game.State.MENU)
	_busy = false
	ui.transition_in()


## A drive from a route's spawn, placed at rest under the cover (screen covered on entry):
## Time Attack, a race (its grid), free roam, a retry, a campaign leg resumed from the title (a
## liaison starts at its spawn, Hanami's finish stop, with the gates open).
func _start_race(route: String, mode: String, run: int) -> void:
	var covered_at := Time.get_ticks_msec()
	_restore_time()
	Game.set_state(Game.State.LOADING)
	_clear_car()
	cine.stop()
	await _ensure_world()
	if run != _run:
		return
	map.select_route(route)
	var timed := mode == Game.MODE_TIME_TRIAL or mode == Game.MODE_RACE
	_set_gates(not timed, false)
	var liaison := mode == Game.MODE_LIAISON
	_spawn_car(true, mode)
	if mode == Game.MODE_RACE:
		_spawn_race(route)
	Game.player_car = car
	Game.session = session
	Game.race = race
	chase.target = car
	car.launch_hold = true
	await _hold_cover(covered_at)
	if run != _run:
		return
	Game.notify_session_started(route, mode)
	Sound.set_backdrop_mix(false, 0.01)
	Sound.play_music(&"liaison" if liaison else &"drive", 3.0 if liaison else 2.5)
	Sound.play_ambience()
	Game.set_state(Game.State.INTRO)
	post.letterbox_target = 1.0
	post.snap()
	cine.play_intro(car, INTRO_TIME)
	_busy = false
	ui.transition_in()
	await cine.intro_finished
	if run != _run:
		return
	post.letterbox_target = 0.0
	chase.make_current()
	chase.snap()
	if timed:
		await _countdown(run)
		return
	car.launch_hold = false
	Game.set_state(Game.State.LIAISON if liaison else Game.State.FREE_ROAM)
	Game.notify_race_started()


## COUNTDOWN on the spot (the cars are held on the line), then RACING.
func _countdown(run: int) -> void:
	Game.set_state(Game.State.COUNTDOWN)
	for v in [3, 2, 1]:
		Game.notify_countdown(v)
		await get_tree().create_timer(1.0, false).timeout
		if run != _run:
			return
	Game.notify_countdown(0)
	car.launch_hold = false
	for rival in rivals:
		rival.launch_hold = false
	session.start_timer()
	if race != null:
		race.start()
	Game.set_state(Game.State.RACING)
	Game.notify_race_started()


## Continue after a stage: the car rests at the finish stop, the branch gate ahead opens under a
## short shot over the car, and the player drives off from exactly there on the liaison route.
func _drive_on(index: int, run: int) -> void:
	var from_route := map.route_id
	var leg: Dictionary = Game.CAMPAIGN[index]
	if not await _await_rest(run):
		return
	_restore_time()
	Game.notify_campaign_leg(index)
	var gate: Node3D = map.gates.get("%s_branch" % from_route)
	cine.stop()
	if gate != null:
		_gate_shot(gate)
	post.letterbox_target = 1.0
	await get_tree().create_timer(GATE_LEAD, false).timeout
	if run != _run:
		return
	# Every gate on the road ahead opens; the one in view animates.
	for id: String in map.gates:
		map.gates[id].set_open(true, map.gates[id] == gate)
	Sound.play_music(&"liaison", 3.0)
	await get_tree().create_timer(GATE_BEAT, false).timeout
	if run != _run:
		return
	map.select_route(leg["map"])
	session.setup(map, car, Game.MODE_LIAISON)
	Game.notify_session_started(leg["map"], Game.MODE_LIAISON)
	_release_stop()
	car.controlled_by_player = true
	post.letterbox_target = 0.0
	chase.make_current()
	chase.snap()
	Game.set_state(Game.State.LIAISON)
	Game.notify_race_started()
	_busy = false


## Liaison arrival: the car rolls to rest on the next stage's grid under a roadside shot while the
## arrival card plays, then waits for the player: Start (Game.request_campaign_continue, into
## _stage_here) or Quit to title.
func _on_session_arrived() -> void:
	if Game.state != Game.State.LIAISON:
		return
	Game.set_state(Game.State.ARRIVED)
	_run += 1
	_stop_at(map.arrival)
	post.letterbox_target = 1.0
	var side := -1.0 if map.track.lateral(map.track.nearest(car.global_position), car.global_position) < 0.0 else 1.0
	cine.cut_to(car, map.track, "roadside", side, map.arrival_progress)


## A campaign stage from where the car stands (on its grid after the liaison), once it is at rest:
## the stage's start card over the intro swoop, then the countdown on the spot. The gates close
## behind.
func _stage_here(index: int, run: int) -> void:
	if not await _await_rest(run):
		return
	var leg: Dictionary = Game.CAMPAIGN[index]
	_restore_time()
	Game.notify_campaign_leg(index)
	map.select_route(leg["map"])
	_set_gates(false, true)
	_release_stop()
	car.controlled_by_player = true
	car.launch_hold = true
	session.setup(map, car, Game.MODE_TIME_TRIAL)
	Game.notify_session_started(leg["map"], Game.MODE_TIME_TRIAL)
	Sound.play_music(&"drive", 2.5)
	Sound.play_ambience()
	Game.set_state(Game.State.INTRO)
	post.letterbox_target = 1.0
	cine.play_intro(car, INTRO_TIME)
	_busy = false
	await cine.intro_finished
	if run != _run:
		return
	post.letterbox_target = 0.0
	chase.make_current()
	chase.snap()
	await _countdown(run)


## The player lets go; an ArrivalStop driver brings the car to rest at `target` on the road.
func _stop_at(target: Transform3D) -> void:
	car.controlled_by_player = false
	if autopilot != null:
		autopilot.queue_free()
		autopilot = null
	_release_stop()
	var stop := ArrivalStop.new()
	stop.name = "ArrivalStop"
	stop.track = map.track
	stop.target = target
	car.add_child(stop)


func _release_stop() -> void:
	var stop := car.get_node_or_null(^"ArrivalStop")
	if stop != null:
		car.remove_child(stop)
		stop.queue_free()
		car.input_throttle = 0.0
		car.input_brake = 0.0
		car.input_handbrake = false
		car.input_steer = 0.0


## Waits for the car to come to rest (REST_WAIT at most); false if a newer flow took over.
func _await_rest(run: int) -> bool:
	var until := Time.get_ticks_msec() + int(REST_WAIT * 1000.0)
	while car.linear_velocity.length() > 0.5 and Time.get_ticks_msec() < until:
		await get_tree().physics_frame
		if run != _run:
			return false
	return true


## Camera behind and above the resting car, looking over it at the gate, then flying up the road
## to GATE_CLOSE metres short of the gate while it opens (the gate stands tens of metres ahead
## of the finish stop; from behind the car it would only be a speck).
func _gate_shot(gate: Node3D) -> void:
	var xf := car.global_transform
	var fwd := Vector3(-xf.basis.z.x, 0.0, -xf.basis.z.z).normalized()
	var right := fwd.cross(Vector3.UP)
	var g := gate.global_position + Vector3.UP * 1.2
	var side := signf(right.dot(g - xf.origin))
	var from := xf.origin - fwd * 7.0 - right * side * 1.6 + Vector3.UP * 2.6
	var to_gate := g - from
	to_gate.y = 0.0
	var reach := maxf(to_gate.length() - GATE_CLOSE, 0.0)
	var to := from + to_gate.normalized() * reach + Vector3.UP * 1.0
	var look_from := xf.origin.lerp(g, 0.7)
	var move := func(t: float) -> void:
		gate_cam.global_position = from.lerp(to, t)
		gate_cam.look_at(look_from.lerp(g, t), Vector3.UP)
	move.call(0.0)
	gate_cam.make_current()
	if _cam_tween != null and _cam_tween.is_valid():
		_cam_tween.kill()
	_cam_tween = create_tween()
	_cam_tween.tween_method(move, 0.0, 1.0, GATE_LEAD + GATE_BEAT).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


## After the last leg (screen covered): the classification over a flyover of the current loop.
func _finale(run: int) -> void:
	var covered_at := Time.get_ticks_msec()
	_restore_time()
	Game.set_state(Game.State.LOADING)
	_clear_car()
	cine.stop()
	await _ensure_world()
	if run != _run:
		return
	var last := Game.CAMPAIGN[Game.CAMPAIGN.size() - 1]
	map.select_route(last["map"])
	_set_gates(false, false)
	_spawn_car(false, Game.MODE_FREE_ROAM)
	_attach_autopilot(0.7, 110.0)
	post.letterbox_target = 0.0
	post.snap()
	cine.start_menu(car, map.track)
	await _hold_cover(covered_at)
	if run != _run:
		return
	Sound.play_music(&"results", 2.0)
	Sound.play_ambience()
	Sound.set_backdrop_mix(true, 0.01)
	Game.set_state(Game.State.FINALE)
	Game.notify_campaign_finished()
	_busy = false
	ui.transition_in()


func _on_session_finished(result: Dictionary) -> void:
	if Game.state != Game.State.RACING:
		return
	Game.set_state(Game.State.FINISHED)
	var run := _run
	# The car is brought to rest at the finish stop (in a race: its place in the queue of
	# finishers); the camera holds the chase view through the slow-motion beat, then swings out
	# into an orbit behind the results card.
	_stop_at(map.finish_stop if race == null else _parc_slot(int(result["position"])))
	Engine.time_scale = FINISH_SLOWMO
	Sound.set_slowmo(FINISH_SLOWMO)
	post.letterbox_target = 1.0
	await get_tree().create_timer(0.9, true, false, true).timeout
	if run != _run:
		return
	cine.start_finish(car)
	_time_tween = create_tween().set_ignore_time_scale(true)
	_time_tween.tween_method(func(v: float) -> void: Engine.time_scale = v, FINISH_SLOWMO, 1.0, 1.4) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	Sound.set_slowmo(1.0)
	await get_tree().create_timer(1.6, true, false, true).timeout
	if run == _run:
		Sound.play_music(&"results", 2.0)


# ------------------------------------------------------------------ building blocks

## Builds the world once (behind the boot cover); later calls return at once, or wait for a
## build in progress.
func _ensure_world() -> void:
	if _world_built:
		return
	if map != null:
		await world_ready
		return
	map = MapWorld.new()
	map.name = "Map"
	map.map_id = MENU_MAP
	add_child(map)
	await map.build(true)
	post.apply_preset(map.atmosphere.preset, map.sun_dir)
	_world_built = true
	world_ready.emit()


## All branch gates open or closed (`animate`: the barrier moves instead of snapping).
func _set_gates(open: bool, animate: bool) -> void:
	for id: String in map.gates:
		map.gates[id].set_open(open, animate)


## New car at the route's spawn (in a race: the last slot of the grid), placed at rest,
## cel-converted, with wheel effects and a route follower (the session also supplies reset points
## for the menu car).
func _spawn_car(player: bool, mode: String) -> void:
	car = (load(str(Game.current_car()["scene"])) as PackedScene).instantiate() as Car
	car.name = "PlayerCar" if player else "MenuCar"
	car.controlled_by_player = player
	add_child(car)
	var c := Game.car_colors()
	car.set_livery(c["primary"], c["secondary"])
	car.place_at_rest(_grid_slot(Game.RIVALS.size()) if mode == Game.MODE_RACE else map.spawn)
	var lights := CarLook.apply(car)
	fx = CarFX.new()
	fx.name = "CarFX"
	add_child(fx)
	fx.setup(car, lights, map.sun_dir)
	session = RaceSession.new()
	session.name = "Session"
	add_child(session)
	session.setup(map, car, mode)
	session.finished.connect(_on_session_finished)
	session.arrived.connect(_on_session_arrived)
	session.reset_needed.connect(func(_reason: String) -> void: car.reset_to_track())
	_apply_quality()


## A race: the rivals on the grid ahead of the player's car (slowest on pole), each in its own car
## and colours, held on the line and driven from GO by a RaceBot set to its lap time for the stage;
## every car of the race collides with the others; the RaceField enters them all.
func _spawn_race(route: String) -> void:
	var grid := Game.RIVALS.duplicate()
	grid.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return Game.rival_lap_time(a, route) > Game.rival_lap_time(b, route))
	var field: Array[Car] = [car]
	for g in grid.size():
		var r: Dictionary = grid[g]
		var rival := (load(str(Game.get_car(str(r["car"]))["scene"])) as PackedScene).instantiate() as Car
		rival.name = "Rival%d" % g
		rival.controlled_by_player = false
		rival.add_to_group(&"race_rival") # before add_child: SoftCourse looks when the car is ready
		rival.add_child(_name_tag(str(r["name"])))
		add_child(rival)
		rival.set_livery(r["colors"][0], r["colors"][1])
		rival.place_at_rest(_grid_slot(g))
		rival.launch_hold = true
		var rfx := CarFX.new()
		rfx.name = "RivalFX%d" % g
		add_child(rfx)
		rfx.setup(rival, CarLook.apply(rival), map.sun_dir)
		rivals.append(rival)
		rival_fx.append(rfx)
		field.append(rival)
	race = RaceField.new()
	race.name = "Race"
	add_child(race)
	race.setup(map, session, Game.RACE_LAPS)
	race.car_finished.connect(_on_race_car_finished)
	var you := Game.current_car()
	race.add(car, {"name": "You", "name_jp": you["name_jp"], "team": "%s · %s" % [you["name"], Game.car_colors()["name"]],
			"player": true, "car_id": you["id"], "colors": [car.livery_primary, car.livery_secondary]})
	for g in grid.size():
		var r: Dictionary = grid[g]
		race.add(rivals[g], {"name": r["name"], "name_jp": r["name_jp"], "team": r["team"], "player": false,
				"car_id": r["car"], "colors": r["colors"]})
		var bot := RaceBot.new()
		bot.name = "RaceBot"
		bot.track = map.track
		bot.pace = RaceBot.pace_for_lap(route, Game.rival_lap_time(r, route), str(r["car"]))
		bot.field = field
		bot.phase = g % DriveHands.DECISION_TICKS
		rivals[g].add_child(bot)
	for c in field:
		c.car_contacts = true


## A car took the flag: its RaceBot lets go (a rival's; a test harness may drive the player's car
## with one too) and a rival's ArrivalStop brings it to rest at its place in the queue of finishers
## (the player's car stops in _on_session_finished).
func _on_race_car_finished(c: Car, position: int) -> void:
	var bot := c.get_node_or_null(^"RaceBot")
	if bot != null:
		c.remove_child(bot)
		bot.queue_free()
	if c == car:
		return
	var stop := ArrivalStop.new()
	stop.name = "ArrivalStop"
	stop.track = map.track
	stop.target = _parc_slot(position)
	c.add_child(stop)


## Race grid slot `g` (0: pole) on the selected route, facing along the road.
func _grid_slot(g: int) -> Transform3D:
	var t := map.track
	var s := t.abs_s(t.nearest(map.spawn.origin), map.spawn.origin) - RACE_GRID_GAP * g
	return t.transform_at_abs(s, -RACE_GRID_LAT if g % 2 == 0 else RACE_GRID_LAT)


## Where the race finisher in `position` (from 1) comes to rest: the winner on the finish stop,
## each next one PARC_GAP metres behind on the road.
func _parc_slot(position: int) -> Transform3D:
	var t := map.track
	var stop := map.finish_stop.origin
	return t.transform_at_abs(t.abs_s(t.nearest(stop), stop) - PARC_GAP * (position - 1), 0.0)


## The name over a rival's car, drawn at a fixed size, fading out beyond NAME_TAG_RANGE.
func _name_tag(text: String) -> Label3D:
	var label := Label3D.new()
	label.name = "NameTag"
	label.text = text
	label.font = UITheme.FONT_UI_BLACK
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.fixed_size = true
	label.pixel_size = 0.0011
	label.font_size = 26
	label.outline_size = 8
	label.position = Vector3(0.0, 2.0, 0.0)
	label.visibility_range_end = NAME_TAG_RANGE
	label.visibility_range_end_margin = 10.0
	label.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	return label


## Autopilot on the route (replacing any earlier one). An open route's line runs on 45 m past
## the arrival along its heading, so the lookahead never ends at the car.
## `style`: &"tidy" for the calm drives (tool flows), &"showoff" for driving on show (the title
## flyover, see Autopilot).
func _attach_autopilot(speed_scale: float, max_kmh: float, style: StringName = &"tidy") -> void:
	if autopilot != null and is_instance_valid(autopilot):
		autopilot.queue_free()
	autopilot = Autopilot.new()
	autopilot.curve = drive_curve()
	autopilot.closed = map.track.closed
	autopilot.speed_scale = speed_scale
	autopilot.max_speed_kmh = max_kmh
	autopilot.style = style
	car.add_child(autopilot)


## The selected route as an autopilot line (tools use it too).
func drive_curve() -> Curve3D:
	var c := map.track.to_curve()
	if not map.track.closed:
		var fwd := -map.arrival.basis.z
		for k in range(1, 6):
			c.add_point(map.arrival.origin + fwd * (9.0 * k) + Vector3.UP * 0.3)
	return c


func _clear_car() -> void:
	Game.player_car = null
	Game.session = null
	Game.race = null
	chase.target = null
	for n: Node in [autopilot, car, fx, session, race] + rivals + rival_fx:
		if n != null and is_instance_valid(n):
			n.queue_free()
	autopilot = null
	car = null
	fx = null
	session = null
	race = null
	rivals.clear()
	rival_fx.clear()


func _hold_cover(since_ms: int) -> void:
	var left := MIN_COVER - (Time.get_ticks_msec() - since_ms) / 1000.0
	if left > 0.0:
		await get_tree().create_timer(left, true, false, true).timeout


func _restore_time() -> void:
	if _time_tween != null and _time_tween.is_valid():
		_time_tween.kill()
	Engine.time_scale = 1.0
	Sound.set_slowmo(1.0)


func _apply_quality() -> void:
	var q := str(Game.get_setting("quality"))
	Quality.apply(q, get_window(), map)
	post.apply_quality(q)
	if fx != null:
		fx.set_quality(q)
	for rfx in rival_fx:
		rfx.set_quality(q)
