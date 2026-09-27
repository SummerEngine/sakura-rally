extends RefCounted
## Cars for the RL tools: the real Car scene and physics without the parts nobody sees or hears
## headless (the Visuals node and the engine audio), so dozens can share one process.


## Instances `scene_path`, drops its visuals, keeps Car._add_audio() from adding CarAudio (it
## skips a car that already has a child of that name) and adds the car under `parent`.
## `auto_reset` false: the car never teleports itself back to the road when stuck (the trainer
## ends the episode instead).
static func spawn(parent: Node, scene_path: String, auto_reset: bool = true) -> Car:
	var car := (load(scene_path) as PackedScene).instantiate() as Car
	var visuals := car.get_node_or_null(^"Visuals")
	if visuals != null:
		car.remove_child(visuals)
		visuals.free()
	var mute := Node.new()
	mute.name = "CarAudio"
	car.add_child(mute)
	car.controlled_by_player = false
	if not auto_reset:
		car.auto_reset_time = 1e9
	parent.add_child(car)
	return car
