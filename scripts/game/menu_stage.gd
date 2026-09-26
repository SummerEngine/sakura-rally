class_name MenuStage
extends Node
## The car behind the title hub. Main calls `enter()` once the menu map is loaded (screen
## covered); from then on this node follows Game.menu_view and the car settings:
##   "title" / "time_attack"  the menu car laps the map under the autopilot, cine flyover
##   "garage"                 the car stands on the garage's display spot (MapWorld's GarageSet,
##                            the workshop by the Hanami start straight), placed at rest, brakes
##                            on, engine idling, under the cine camera's showroom orbit
## A livery change paints over the parked car with a brush sweep (shaders/ui/paint_sweep). A car
## change in the garage sends the old car off under its own engine (out of the lay-by and away
## down the road) while the new one comes up the road and parks on the spot (GarageDriver).
## Outside the garage both apply at once. A map without a garage parks on its start grid and
## swaps cars in place.
##
## Uses Main's car building blocks (`_spawn_car`, `_attach_autopilot`, `_clear_car`) so the
## menu car is Main's `car` like any other, and Main's race flows clear it as usual. A leaving
## car is detached from Main (its car and fx) and belongs to this node until it is gone.

const SWEEP_SHADER := preload("res://shaders/ui/paint_sweep.gdshader")
const TOON_SHADER := preload("res://shaders/toon.gdshader")
## Autopilot of the flyover car: style, speed scale, top speed (km/h). The showoff style drives
## every real corner sideways (tools/showoff/drift_probe.gd measures it).
const FLYOVER_STYLE := &"showoff"
const FLYOVER_SCALE := 1.0
const FLYOVER_KMH := 150.0
## Livery sweep: duration and the stretch it runs along the car (metres from the origin).
const SWEEP_TIME := 0.8
const SWEEP_FROM := -2.7
const SWEEP_TO := 2.7
## Car switch: arriving car speeds (m/s) on the road and in the lay-by (the last metres before
## the spot), leaving car in the lay-by and on the road.
const ARRIVE_CRUISE := 13.0
const ARRIVE_SLOW := 7.5
const LEAVE_SLOW := 8.0
const LEAVE_CRUISE := 24.0
## A leaving car is gone at the end of its line or after this long (s); at most this many drive
## off at once (fast switching frees the oldest, far down the road by then).
const LEAVE_TIME := 11.0
const MAX_LEAVING := 3
## The switch camera watches the leaving car until it is this far (m) from the display spot.
const FOLLOW_LEAVING := 26.0

var main: Node

var _garage := false
var _car_scene := ""
var _primary := Color.WHITE
var _secondary := Color.WHITE
var _sweep_mats: Array[ShaderMaterial] = []
var _sweep_tween: Tween
## Cars driving off: {car: Car, fx: CarFX, driver: GarageDriver, t: float}.
var _leaving: Array[Dictionary] = []
## Brings Main's car in to the display spot; null when it stands there (or outside the garage).
var _arrival: GarageDriver


func _ready() -> void:
	Game.state_changed.connect(_on_state_changed)


## Spawns the menu car on Main's loaded map for the current Game.menu_view.
func enter(p_main: Node) -> void:
	main = p_main
	_finish_sweep()
	_clear_switch()
	_spawn()
	_garage = str(Game.menu_view) == "garage"
	if _garage:
		_park()
		_prewarm_sweep()
	else:
		_fly()


func set_view(view: String) -> void:
	var garage := view == "garage"
	if garage == _garage or main == null or main.car == null:
		return
	_garage = garage
	_finish_sweep()
	# Under the ink wipe: the drive-off / drive-in ends, the car stands where the next view wants it.
	_clear_switch()
	if garage:
		_park()
		_prewarm_sweep()
	else:
		(main.car as Car).place_at_rest(main.map.spawn)
		_fly()


## Game.settings_changed while the menu shows: another car drives in (garage) or respawns,
## another livery repaints.
func apply_car_settings() -> void:
	if main == null or main.car == null:
		return
	if str(Game.current_car()["scene"]) != _car_scene:
		_finish_sweep()
		if _garage and garage_set() != null:
			_send_off()
			_spawn()
			_bring_in()
			return
		main._clear_car()
		_spawn()
		if _garage:
			_park()
		else:
			_fly()
		return
	var c: Dictionary = Game.car_colors()
	if c["primary"] == _primary and c["secondary"] == _secondary:
		return
	# The sweep paints a standing car; a car on its way in just wears the new colours.
	if _garage and not arriving():
		_sweep(c["primary"], c["secondary"])
	else:
		main.car.set_livery(c["primary"], c["secondary"])
	_primary = c["primary"]
	_secondary = c["secondary"]


## The loaded map's garage (null when the map has none).
func garage_set() -> GarageSet:
	if main == null or main.map == null:
		return null
	return main.map.get_node_or_null(^"GarageSet") as GarageSet


## Where the garage car stands: the garage's display spot, else the start grid.
func display_spot() -> Transform3D:
	var g := garage_set()
	return g.display if g != null else main.map.spawn


## True while Main's car is on its way in to the display spot.
func arriving() -> bool:
	return _arrival != null and is_instance_valid(_arrival)


## Cars currently driving off (tools read them).
func leaving_cars() -> Array[Car]:
	var out: Array[Car] = []
	for l in _leaving:
		if is_instance_valid(l["car"]):
			out.append(l["car"])
	return out


# ---------------------------------------------------------------- car

func _spawn() -> void:
	main._spawn_car(false, Game.MODE_FREE_ROAM)
	_car_scene = str(Game.current_car()["scene"])
	var c: Dictionary = Game.car_colors()
	_primary = c["primary"]
	_secondary = c["secondary"]


## Display spot, placed at rest (nothing drops), brakes on, no autopilot.
func _park() -> void:
	var car: Car = main.car
	_drop_autopilot()
	_idle(car)
	car.place_at_rest(display_spot())
	car.launch_hold = true
	main.cine.start_garage(car, display_spot())


func _fly() -> void:
	var car: Car = main.car
	car.launch_hold = false
	if main.autopilot == null or not is_instance_valid(main.autopilot):
		main._attach_autopilot(FLYOVER_SCALE, FLYOVER_KMH, FLYOVER_STYLE)
	main.cine.start_menu(car, main.map.track)


func _drop_autopilot() -> void:
	if main.autopilot != null and is_instance_valid(main.autopilot):
		main.autopilot.queue_free()
	main.autopilot = null


static func _idle(car: Car) -> void:
	car.input_throttle = 0.0
	car.input_brake = 0.0
	car.input_steer = 0.0
	car.input_handbrake = false


# ---------------------------------------------------------------- car switch (garage)

## Detaches Main's car and drives it off: out of the lay-by, into the lane and away.
func _send_off() -> void:
	var car: Car = main.car
	var fx: Node = main.fx
	_drop_autopilot()
	if arriving():
		_arrival.queue_free()
	_arrival = null
	if main.session != null and is_instance_valid(main.session):
		main.session.queue_free()
	main.session = null
	main.car = null
	main.fx = null
	car.name = "LeavingCar"
	car.launch_hold = false
	var d := GarageDriver.new()
	d.points = garage_set().leave_path(car.global_position)
	d.stop_at_end = false
	d.first_speed = LEAVE_SLOW
	d.first_until = 18.0
	d.then_speed = LEAVE_CRUISE
	d.max_throttle = 0.8
	car.add_child(d)
	# Cars that pass each other on the apron go through each other (a quick re-pick).
	for l in _leaving:
		if is_instance_valid(l["car"]):
			car.add_collision_exception_with(l["car"])
	_leaving.append({"car": car, "fx": fx, "driver": d, "t": 0.0})
	while _leaving.size() > MAX_LEAVING:
		_free_leaver(0)


## Main's new car comes up the road from behind the spot and parks on it.
func _bring_in() -> void:
	var car: Car = main.car
	var g := garage_set()
	_drop_autopilot()
	_idle(car)
	car.launch_hold = false
	car.place_at_rest(g.arrive_start())
	for l in _leaving:
		if is_instance_valid(l["car"]):
			car.add_collision_exception_with(l["car"])
	_arrival = GarageDriver.new()
	_arrival.points = g.arrive_path()
	_arrival.first_speed = ARRIVE_CRUISE
	_arrival.then_speed = ARRIVE_SLOW
	_arrival.first_until = _arrival_slow_from(_arrival.points)
	_arrival.max_throttle = 0.7
	_arrival.decel = 4.5
	_arrival.finished.connect(_on_arrived.bind(_arrival))
	car.add_child(_arrival)
	main.cine.start_garage(car, g.display)
	main.cine.garage_wide = true


## Line distance where the arrival leaves the road for the lay-by (it slows from there).
func _arrival_slow_from(pts: PackedVector3Array) -> float:
	var total := 0.0
	for i in range(1, pts.size()):
		total += pts[i].distance_to(pts[i - 1])
	return total - 22.0


func _on_arrived(driver: GarageDriver) -> void:
	if driver != _arrival:
		return
	_arrival.queue_free()
	_arrival = null
	var car: Car = main.car
	if car == null:
		return
	_idle(car)
	car.launch_hold = true
	main.cine.garage_wide = false
	main.cine.garage_follow = null


func _process(delta: float) -> void:
	var k := 0
	while k < _leaving.size():
		var l: Dictionary = _leaving[k]
		l["t"] += delta
		var d: GarageDriver = l["driver"]
		if not is_instance_valid(l["car"]) or l["t"] > LEAVE_TIME or (is_instance_valid(d) and d.done):
			_free_leaver(k)
		else:
			k += 1
	if arriving():
		main.cine.garage_follow = _follow_target()


## Who the switch camera watches: the newest leaving car while it is still close to the spot
## (pulling out of the lay-by), then the arriving car.
func _follow_target() -> Node3D:
	var spot := display_spot().origin
	if not _leaving.is_empty():
		var l: Car = _leaving[_leaving.size() - 1]["car"]
		if is_instance_valid(l) and l.global_position.distance_to(spot) < FOLLOW_LEAVING:
			return l
	return main.car


func _free_leaver(k: int) -> void:
	var l: Dictionary = _leaving[k]
	_leaving.remove_at(k)
	for key in ["fx", "car"]:
		var n: Node = l[key]
		if n != null and is_instance_valid(n):
			n.queue_free()


## Ends a switch in progress: the leaving cars go, an arriving car stops where it is.
func _clear_switch() -> void:
	while not _leaving.is_empty():
		_free_leaver(0)
	if arriving():
		_arrival.queue_free()
	_arrival = null
	if main != null and main.cine != null:
		main.cine.garage_wide = false
		main.cine.garage_follow = null


## Leaving the menu (a race, the campaign): the cars this node drove off go with Main's.
func _on_state_changed(new_state: int, _old_state: int) -> void:
	if new_state != Game.State.MENU:
		_clear_switch()


# ---------------------------------------------------------------- livery sweep

func _sweep(primary: Color, secondary: Color) -> void:
	_finish_sweep()
	if not _swap_to_sweep():
		main.car.set_livery(primary, secondary)
		return
	# The car's own livery path sets the new "albedo" on the same materials.
	main.car.set_livery(primary, secondary)
	_sweep_tween = create_tween().set_ignore_time_scale(true)
	_sweep_tween.tween_method(_set_front, SWEEP_FROM, SWEEP_TO, SWEEP_TIME) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_sweep_tween.tween_callback(_finish_sweep)


func _set_front(front: float) -> void:
	for m in _sweep_mats:
		m.set_shader_parameter("sweep_front", front)


## Puts the car's paint materials on the sweep shader, front at the nose (none of the new colour
## shows yet). Returns false when the car has no toon paint to sweep.
func _swap_to_sweep() -> bool:
	var car: Car = main.car
	var visuals := car.get_node_or_null(^"Visuals") as CarVisuals
	if visuals == null or visuals.model == null:
		return false
	var xf := car.global_transform
	for node in visuals.model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		for s in mi.get_surface_override_material_count():
			var m := mi.get_surface_override_material(s) as ShaderMaterial
			if m == null or m.shader != TOON_SHADER or not m.resource_name.to_lower().contains("paint"):
				continue
			m.shader = SWEEP_SHADER
			m.set_shader_parameter("albedo_from", m.get_shader_parameter("albedo"))
			m.set_shader_parameter("sweep_origin", xf.origin)
			m.set_shader_parameter("sweep_axis", xf.basis.z.normalized())
			m.set_shader_parameter("sweep_front", SWEEP_FROM)
			_sweep_mats.append(m)
	return not _sweep_mats.is_empty()


## Draws the paint with the sweep shader for a couple of frames while the garage switch is under
## the ink, so its first real use (the first livery pick) doesn't stall on the shader compile and
## swallow the sweep.
func _prewarm_sweep() -> void:
	_finish_sweep()
	if not _swap_to_sweep():
		return
	# Front past the tail: the whole body shows the (unchanged) colour, no ink line.
	_set_front(SWEEP_TO + 1.0)
	var warm := _sweep_mats.duplicate()
	for i in 2:
		await RenderingServer.frame_post_draw
	if _sweep_tween == null and _sweep_mats == warm:
		_finish_sweep()


## Puts every swept material back on the toon shader (the new colour stays).
func _finish_sweep() -> void:
	if _sweep_tween != null and _sweep_tween.is_valid():
		_sweep_tween.kill()
	_sweep_tween = null
	for m in _sweep_mats:
		m.shader = TOON_SHADER
	_sweep_mats.clear()
