extends SceneTree
## Windowed preview of rally_car.glb as imported by Godot (stock StandardMaterial3D, no toon
## conversion) — catches import problems Blender renders cannot: flipped normals, culled faces,
## wrong axes, material slots. Steers the front wheels to verify the wheel rest bases.
## Run (NOT headless): $S --disable-crash-handler --path . -s res://tools/car_check/preview_car.gd
## Writes docs/renders/car_godot_front34.png and docs/renders/car_godot_rear34.png.

const CAR_PATH := "res://assets/models/car/rally_car.glb"
const STEER_ANGLE := 0.35
const VIEWS := {
	"front34": [Vector3(-4.2, 1.6, -4.8), Vector3(0.0, 0.55, -0.2)],
	"rear34": [Vector3(4.4, 2.2, 5.2), Vector3(0.0, 0.6, 0.2)],
}


func _initialize() -> void:
	var scene_root := Node3D.new()
	root.add_child(scene_root)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("dce8f0")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("c9c4e6")
	env.ambient_light_energy = 0.8
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	scene_root.add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, 35.0, 0.0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	scene_root.add_child(sun)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(40.0, 40.0)
	ground.mesh = plane
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color("cfd6c4")
	ground.material_override = ground_mat
	scene_root.add_child(ground)

	var car := (load(CAR_PATH) as PackedScene).instantiate() as Node3D
	scene_root.add_child(car)
	for wheel_name in ["Wheel_FL", "Wheel_FR", "Caliper_FL", "Caliper_FR"]:
		var w := car.get_node(wheel_name) as Node3D
		w.basis = Basis(Vector3.UP, STEER_ANGLE) * w.basis

	var cam := Camera3D.new()
	cam.fov = 40.0
	scene_root.add_child(cam)
	cam.make_current()

	var out_dir := ProjectSettings.globalize_path("res://docs/renders")
	for view_name: String in VIEWS:
		var v: Array = VIEWS[view_name]
		cam.look_at_from_position(v[0], v[1], Vector3.UP)
		for i in 12:
			await process_frame
		var img := root.get_viewport().get_texture().get_image()
		var path := out_dir.path_join("car_godot_%s.png" % view_name)
		img.save_png(path)
		print("saved ", path)
	quit()
