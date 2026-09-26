extends Node
## Main scene: owns the loaded map, the car, the cameras, the screen passes and the
## UI layer, and drives the game state (docs/CONTRACTS.md, docs/UI.md):
##
##   BOOT -> MENU        the last map stays loaded; an autopilot car laps it under the
##                       flyover camera behind the title screen
##   start -> LOADING    ink covers the screen while the map builds
##   -> INTRO            camera swoop onto the car, letterboxed
##   -> COUNTDOWN        (time trial) the car is held in neutral, throttle revs it
##   -> RACING / FREE_ROAM
##   -> FINISHED         slow-motion beat, the car cruises on under the autopilot while
##                       the camera orbits it behind the results card
##
## Campaign (Game.CAMPAIGN):
##
##   -> JOURNEY          the painted journey map; the next leg's map loads behind it
##   -> LOADING, INTRO   as above; a stage then runs COUNTDOWN, RACING, FINISHED
##   -> LIAISON          (liaison leg) the car rolls off the start, no timer
##   -> ARRIVED          arrival zone reached: the car eases to a stop, roadside shot,
##                       then back to JOURNEY
##   -> FINALE           after the last leg: classification over a flyover of the last map
##
## Every flow captures `_run`; a newer request bumps it and older flows stop at their
## next await.

const UI_ROOT := preload("res://scenes/ui/ui_root.tscn")
const INTRO_TIME := 3.4
const MENU_MAP := "hanami"
const FINISH_SLOWMO := 0.3
## Minimum time the loading card stays up: its brush animation plays, first-use shaders
## compile and the new car settles on its springs behind the ink.
const MIN_COVER := 0.75
## Seconds of the arrival beat before the journey map.
const ARRIVAL_HOLD := 4.6
## Liaison: the autopilot rolls the car off the start under the intro swoop, then hands over.
const LIAISON_ROLL_KMH := 38.0

var ui: CanvasLayer
var post: PostFX
var chase: ChaseCamera
var cine: CineCamera
var map: MapWorld
var car: Car
var fx: CarFX
var session: RaceSession
var autopilot: Autopilot
var menu_stage: MenuStage

var _run: int = 0
var _busy: bool = false
var _time_tween: Tween


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
	Game.start_requested.connect(_on_start_requested)
	Game.restart_requested.connect(_on_restart_requested)
	Game.menu_requested.connect(_on_menu_requested)
	menu_stage = MenuStage.new()
	menu_stage.name = "MenuStage"
	add_child(menu_stage)
	Game.menu_view_changed.connect(_on_menu_view_changed)
	Game.settings_changed.connect(_on_settings_changed)
	get_window().size_changed.connect(func() -> void:
		Quality.apply_render_scale(str(Game.get_setting("quality")), get_window()))
	Game.campaign_requested.connect(_on_campaign_requested)
	Game.campaign_continue_requested.connect(_on_campaign_requested)
	ui.transition.set_loading_label("桜", "Sakura Rally")
	ui.transition.cover(0.01)
	_busy = true
	_enter_menu(MENU_MAP, _run)


func _process(_delta: float) -> void:
	var driving := car != null and (Game.state == Game.State.RACING or Game.state == Game.State.FREE_ROAM \
			or Game.state == Game.State.LIAISON)
	post.speed_target = smoothstep(115.0, 175.0, car.speed_kmh) * 0.8 if driving else 0.0
	# Liaison: within braking distance of the time control the player lets go and the car is
	# brought in to stop there, whatever speed it arrives at.
	if Game.state == Game.State.LIAISON and not car.has_node(^"ArrivalStop") \
			and session.distance_left <= ArrivalStop.stopping_distance(car.linear_velocity.length()):
		_stop_at_arrival()
		Game.post_notice("Time control ahead")


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
	await ui.transition_out(map.map_id)
	if run == _run:
		_start_race(map.map_id, str(Game.mode), run)


func _on_menu_requested() -> void:
	if _busy:
		return
	Game.end_campaign_session()
	_run += 1
	var run := _run
	_busy = true
	await ui.transition_out()
	if run == _run:
		_enter_menu(map.map_id if map != null else MENU_MAP, run)


## Title "Campaign", results "Continue", the end of an arrival: the journey map for the
## next leg, or the finale once every leg is done.
func _on_campaign_requested() -> void:
	if _busy:
		return
	_run += 1
	var run := _run
	_busy = true
	await ui.transition_out()
	if run == _run:
		_journey(run)


func _on_settings_changed() -> void:
	if Game.state == Game.State.MENU:
		menu_stage.apply_car_settings()
	elif car != null:
		var c := Game.car_colors()
		car.set_livery(c["primary"], c["secondary"])
	_apply_quality()


## Title hub pages: the garage parks the menu car under a showroom orbit (MenuStage).
func _on_menu_view_changed(view: String) -> void:
	if Game.state == Game.State.MENU:
		menu_stage.set_view(view)


# ------------------------------------------------------------------ flows (screen covered on entry)

func _enter_menu(map_id: String, run: int) -> void:
	var covered_at := Time.get_ticks_msec()
	_restore_time()
	Game.set_state(Game.State.LOADING)
	_clear_car()
	cine.stop()
	if map == null or map.map_id != map_id:
		await _load_map(map_id)
		if run != _run:
			return
	menu_stage.enter(self)
	post.letterbox_target = 0.0
	post.snap()
	await _hold_cover(covered_at)
	if run != _run:
		return
	Sound.play_music(&"menu")
	Sound.play_ambience(map.map_id)
	Sound.set_backdrop_mix(true, 0.01)
	Game.set_state(Game.State.MENU)
	_busy = false
	ui.transition_in()


## The campaign journey map (screen covered on entry). The UI shows it on JOURNEY; the next
## leg's map loads behind it while the car marker travels there, then ink covers it again and
## the leg starts. After the last leg the marker drives to the goal and the finale follows.
func _journey(run: int) -> void:
	var covered_at := Time.get_ticks_msec()
	_restore_time()
	_clear_car()
	cine.stop()
	var index := int(Game.campaign_status()["leg"])
	Sound.stop_ambience(1.0)
	Sound.set_backdrop_mix(true, 0.01)
	Sound.play_music(&"menu", 2.0)
	Game.set_state(Game.State.JOURNEY)
	await _hold_cover(covered_at)
	if run != _run:
		return
	ui.transition_in()
	if index < Game.CAMPAIGN.size():
		Game.notify_campaign_leg(index)
		var leg: Dictionary = Game.CAMPAIGN[index]
		if map == null or map.map_id != leg["map"]:
			await _load_map(leg["map"])
			if run != _run:
				return
	if ui.journey.traveling:
		await ui.journey.travel_done
		if run != _run:
			return
	await ui.transition_out(Game.CAMPAIGN[index]["map"] if index < Game.CAMPAIGN.size() else "")
	if run != _run:
		return
	if index < Game.CAMPAIGN.size():
		var leg: Dictionary = Game.CAMPAIGN[index]
		_start_race(leg["map"], Game.MODE_LIAISON if leg["kind"] == "liaison" else Game.MODE_TIME_TRIAL, run)
	else:
		_finale(run)


func _start_race(map_id: String, mode: String, run: int) -> void:
	var covered_at := Time.get_ticks_msec()
	_restore_time()
	Game.set_state(Game.State.LOADING)
	_clear_car()
	cine.stop()
	if map == null or map.map_id != map_id:
		await _load_map(map_id)
		if run != _run:
			return
	var liaison := mode == Game.MODE_LIAISON
	_spawn_car(true, mode)
	Game.player_car = car
	Game.session = session
	chase.target = car
	if liaison:
		# The car rolls off the start under the intro swoop and is handed over on the move.
		car.controlled_by_player = false
		_attach_autopilot(0.5, LIAISON_ROLL_KMH)
	else:
		car.launch_hold = true
	await _hold_cover(covered_at)
	if run != _run:
		return
	Game.notify_session_started(map_id, mode)
	Sound.set_backdrop_mix(false, 0.01)
	Sound.play_music(&"liaison" if liaison else &"drive", 3.0 if liaison else 2.5)
	Sound.play_ambience(map_id)
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
	if mode == Game.MODE_TIME_TRIAL:
		Game.set_state(Game.State.COUNTDOWN)
		for v in [3, 2, 1]:
			Game.notify_countdown(v)
			await get_tree().create_timer(1.0, false).timeout
			if run != _run:
				return
		Game.notify_countdown(0)
		car.launch_hold = false
		session.start_timer()
		Game.set_state(Game.State.RACING)
	elif liaison:
		autopilot.queue_free()
		autopilot = null
		car.controlled_by_player = true
		Game.set_state(Game.State.LIAISON)
	else:
		car.launch_hold = false
		Game.set_state(Game.State.FREE_ROAM)
	Game.notify_race_started()


## Liaison arrival: the car rolls to rest at the time control under a roadside shot while the
## UI shows the arrival card, then the journey map.
func _on_session_arrived() -> void:
	if Game.state != Game.State.LIAISON:
		return
	Game.set_state(Game.State.ARRIVED)
	var run := _run
	_stop_at_arrival()
	post.letterbox_target = 1.0
	var side := -1.0 if map.track.lateral(map.track.nearest(car.global_position), car.global_position) < 0.0 else 1.0
	cine.cut_to(car, map.track, "roadside", side, map.arrival_progress)
	await get_tree().create_timer(ARRIVAL_HOLD, true, false, true).timeout
	if run == _run and Game.state == Game.State.ARRIVED:
		Game.request_campaign_continue()


## The player lets go; an ArrivalStop driver (once) brings the car to rest at the time control.
func _stop_at_arrival() -> void:
	car.controlled_by_player = false
	if autopilot != null:
		autopilot.queue_free()
		autopilot = null
	if car.has_node(^"ArrivalStop"):
		return
	var stop := ArrivalStop.new()
	stop.name = "ArrivalStop"
	stop.track = map.track
	stop.target = map.arrival
	stop.target_s = map.arrival_progress
	car.add_child(stop)


## After the last leg (screen covered): the classification over a flyover of the loaded map.
func _finale(run: int) -> void:
	var covered_at := Time.get_ticks_msec()
	_restore_time()
	Game.set_state(Game.State.LOADING)
	_clear_car()
	cine.stop()
	if map == null:
		await _load_map(Game.CAMPAIGN[Game.CAMPAIGN.size() - 1]["map"])
		if run != _run:
			return
	_spawn_car(false, Game.MODE_FREE_ROAM)
	_attach_autopilot(0.7, 110.0)
	post.letterbox_target = 0.0
	post.snap()
	cine.start_menu(car, map.track)
	await _hold_cover(covered_at)
	if run != _run:
		return
	Sound.play_music(&"results", 2.0)
	Sound.play_ambience(map.map_id)
	Sound.set_backdrop_mix(true, 0.01)
	Game.set_state(Game.State.FINALE)
	Game.notify_campaign_finished()
	_busy = false
	ui.transition_in()


func _on_session_finished(_result: Dictionary) -> void:
	if Game.state != Game.State.RACING:
		return
	Game.set_state(Game.State.FINISHED)
	var run := _run
	# The car cruises on under the autopilot; the camera holds the chase view through the
	# slow-motion beat, then swings out into an orbit behind the results card.
	car.controlled_by_player = false
	_attach_autopilot(0.5, 75.0)
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

func _load_map(map_id: String) -> void:
	if map != null:
		map.queue_free()
		map = null
		await get_tree().process_frame
	map = MapWorld.new()
	map.name = "Map"
	map.map_id = map_id
	add_child(map)
	await map.build(true)
	post.apply_preset(map.atmosphere.preset, map.sun_dir)


## New car at the map's spawn, cel-converted, with wheel effects and a route follower
## (the session also supplies reset points for the menu car).
func _spawn_car(player: bool, mode: String) -> void:
	car = (load(str(Game.current_car()["scene"])) as PackedScene).instantiate() as Car
	car.name = "PlayerCar" if player else "MenuCar"
	car.controlled_by_player = player
	add_child(car)
	var c := Game.car_colors()
	car.set_livery(c["primary"], c["secondary"])
	car.reset_to(map.spawn)
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


## Autopilot on the road (replacing any earlier one). An open road's line runs on 45 m past the
## arrival along its heading (into the service park), so the lookahead never ends at the car.
func _attach_autopilot(speed_scale: float, max_kmh: float) -> void:
	if autopilot != null and is_instance_valid(autopilot):
		autopilot.queue_free()
	autopilot = Autopilot.new()
	autopilot.curve = drive_curve()
	autopilot.closed = map.track.closed
	autopilot.speed_scale = speed_scale
	autopilot.max_speed_kmh = max_kmh
	car.add_child(autopilot)


## The loaded road as an autopilot line (tools use it too).
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
	chase.target = null
	for n: Node in [autopilot, car, fx, session]:
		if n != null and is_instance_valid(n):
			n.queue_free()
	autopilot = null
	car = null
	fx = null
	session = null


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
