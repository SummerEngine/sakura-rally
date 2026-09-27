class_name MenuStage
extends Node
## The car behind the title hub. Main calls `enter()` once the menu map is loaded (screen
## covered); from then on this node follows Game.menu_view and the car settings:
##   "title" / "time_attack"  the menu car laps the map under the autopilot, cine flyover
##   "garage"                 the car parks on the start grid (brakes on, engine idling) under
##                            the cine camera's low showroom orbit
## A livery change paints over the parked car with a brush sweep (shaders/ui/paint_sweep);
## a car change drops the other car onto the grid. Outside the garage both apply at once.
##
## Uses Main's car building blocks (`_spawn_car`, `_attach_autopilot`, `_clear_car`) so the
## menu car is Main's `car` like any other, and Main's race flows clear it as usual.

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
## A switched-in car lands on the grid from this height, settling on its springs.
const DROP := 0.45

var main: Node

var _garage := false
var _car_scene := ""
var _primary := Color.WHITE
var _secondary := Color.WHITE
var _sweep_mats: Array[ShaderMaterial] = []
var _sweep_tween: Tween


## Spawns the menu car on Main's loaded map for the current Game.menu_view.
func enter(p_main: Node) -> void:
	main = p_main
	_finish_sweep()
	_spawn()
	_garage = str(Game.menu_view) == "garage"
	if _garage:
		_park(false)
	else:
		_fly()


func set_view(view: String) -> void:
	var garage := view == "garage"
	if garage == _garage or main == null or main.car == null:
		return
	_garage = garage
	_finish_sweep()
	if garage:
		_park(false)
	else:
		_fly()


## Game.settings_changed while the menu shows: another car respawns, another livery repaints.
func apply_car_settings() -> void:
	if main == null or main.car == null:
		return
	if str(Game.current_car()["scene"]) != _car_scene:
		_finish_sweep()
		main._clear_car()
		_spawn()
		if _garage:
			_park(true)
		else:
			_fly()
		return
	var c: Dictionary = Game.car_colors()
	if c["primary"] == _primary and c["secondary"] == _secondary:
		return
	if _garage:
		_sweep(c["primary"], c["secondary"])
	else:
		main.car.set_livery(c["primary"], c["secondary"])
	_primary = c["primary"]
	_secondary = c["secondary"]


# ---------------------------------------------------------------- car

func _spawn() -> void:
	main._spawn_car(false, Game.MODE_FREE_ROAM)
	_car_scene = str(Game.current_car()["scene"])
	var c: Dictionary = Game.car_colors()
	_primary = c["primary"]
	_secondary = c["secondary"]


## Start grid, brakes on, no autopilot; `drop` lands the car from a little height.
func _park(drop: bool) -> void:
	var car: Car = main.car
	if main.autopilot != null and is_instance_valid(main.autopilot):
		main.autopilot.queue_free()
	main.autopilot = null
	car.input_throttle = 0.0
	car.input_brake = 0.0
	car.input_steer = 0.0
	car.input_handbrake = false
	var at: Transform3D = main.map.spawn
	if drop:
		at.origin += Vector3.UP * DROP
	car.reset_to(at)
	car.launch_hold = true
	main.cine.start_garage(car)
	if not drop:
		_prewarm_sweep()


func _fly() -> void:
	var car: Car = main.car
	car.launch_hold = false
	if main.autopilot == null or not is_instance_valid(main.autopilot):
		main._attach_autopilot(FLYOVER_SCALE, FLYOVER_KMH, FLYOVER_STYLE)
	main.cine.start_menu(car, main.map.track)


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
