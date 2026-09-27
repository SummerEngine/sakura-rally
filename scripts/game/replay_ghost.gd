class_name ReplayGhost
extends RefCounted
## A recorded car played back: the real car scene (model, livery, cel look) as a posed ghost -
## no physics, collision, sound or driving code (the body is PROCESS_MODE_DISABLED, which
## takes it out of the physics space) - posed from ReplayData.car_at(): body transform, wheels
## turning, steering and on their springs, body lean and pop-up lights from the car's own
## CarVisuals.

var car: Car
var visuals: CarVisuals


## Spawns the replay's car (header "car_scene", else the scene of header "car") under `parent`
## with the recorded livery. Returns null when no car scene can be found.
static func spawn(parent: Node, header: Dictionary) -> ReplayGhost:
	var scene_path := str(header.get("car_scene", ""))
	if not ResourceLoader.exists(scene_path):
		var game := parent.get_node_or_null(^"/root/Game")
		scene_path = str(game.get_car(str(header.get("car", ""))).get("scene", "")) if game != null else ""
	if not ResourceLoader.exists(scene_path):
		return null
	var g := ReplayGhost.new()
	g.car = (load(scene_path) as PackedScene).instantiate() as Car
	g.car.name = "ReplayGhost"
	g.car.controlled_by_player = false
	g.car.process_mode = Node.PROCESS_MODE_DISABLED
	g.car.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	g.car.collision_layer = 0
	g.car.collision_mask = 0
	var livery: Dictionary = header.get("livery", {})
	g.car.livery_primary = Color(str(livery.get("primary", "#f6f1e8")))
	g.car.livery_secondary = Color(str(livery.get("secondary", "#e8517c")))
	parent.add_child(g.car)
	g.visuals = g.car.get_node_or_null(^"Visuals") as CarVisuals
	CarLook.apply(g.car)
	return g


## Poses the ghost from a ReplayData.car_at() sample; `dt` (s) since the previous pose drives
## the body lean and the pop-up spring.
func pose(sample: Dictionary, dt: float) -> void:
	var xf: Transform3D = sample["xform"]
	car.global_transform = xf
	car.linear_velocity = sample["lin"]
	car.speed_kmh = sample["kmh"]
	car.grounded_wheels = sample["grounded"]
	car.input_throttle = sample["input_throttle"]
	car.input_brake = sample["input_brake"]
	car.launch_hold = sample["launch_hold"]
	for i in 4:
		var w: WheelState = car.wheels[i]
		w.steer_angle = sample["steer_angles"][i]
		w.spin_angle = sample["spin_angles"][i]
		w.offset_y = sample["offsets"][i]
		w.contact = sample["contacts"][i]
		w.surface_roughness = 0.0
	if visuals != null:
		visuals._physics_process(maxf(dt, 1e-4))
